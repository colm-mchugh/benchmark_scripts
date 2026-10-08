#!/usr/bin/env bash
#
# TPC-C style benchmark for Citus, shaped like HammerDB's PostgreSQL driver:
# the same nine tables, the same five stored procedures, and the same
# 45/43/4/4/4 transaction deck. pgbench supplies the terminals.
#
# Connection settings come from the usual libpq environment variables, so
# pointing this at a remote cluster is just:
#
#   export PGHOST=coordinator.internal PGPORT=5432 PGUSER=citus PGDATABASE=citus
#
# Build once, then measure:
#
#   ./run_tpcc.sh --build --warehouses 100 --jobs 16
#   ./run_tpcc.sh --clients 1,8,32,64 --duration 300 --iterations 5
#
# Modes separate the two halves of the feature, which are independent:
#
#   off    citus.enable_prepared_statement_caching = off
#   part1  caching on, fast path off -- worker-side prepared statements only,
#          on tasks built by normal planning
#   both   caching on, fast path on  -- also builds the task straight from the
#          bound parameters on the coordinator
#
# Run the driver on a separate host from the coordinator. Results land in
# bench_results/tpcc_<timestamp>/ with a summary.csv and an env.txt.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

WAREHOUSES=10
SHARDS=32
CLIENTS=1,8,32
DURATION=60
ITERATIONS=3
MODES="off both"
PROTOCOL=prepared
JOBS=8
WARMUP=30
BUILD=0
RELOAD=0
RESET_BETWEEN_MODES=0
VACUUM_BEFORE_RUN=0
COOLDOWN=0
DIAGNOSTICS=0
OUTDIR=""
LABEL=""
WORKER_PLAN_CACHE_MODE=""
COORDINATOR_PORT=5432

usage() {
        cat <<'EOF'
TPC-C style benchmark for Citus.

Usage: run_tpcc.sh [OPTIONS]

    --build                     Recreate and load the data set before running
    --warehouses N              Warehouses to load (default: 10)
    --shards N                  Shards to create (default: 32)
    --jobs N                    Parallel loader jobs (default: 8)
    --clients LIST              Comma-separated client counts (default: 1,8,32)
    --duration SECONDS          Measured duration per run (default: 60)
    --iterations N              Iterations per client count (default: 3)
    --modes LIST                Comma-separated modes (default: off,both)
    --protocol MODE             pgbench protocol (default: prepared)
    --warmup SECONDS            Warmup before each run (default: 30)
    --reload                    Rebuild at startup and each subsequent iteration
    --reset-between-modes       Rebuild at startup and each subsequent mode
    --vacuum-before-run         VACUUM (ANALYZE) before every mode's warmup
    --cooldown SECONDS          Pause before every mode's warmup (default: 0)
    --diagnostics               Capture database diagnostics before and after each run
    --outdir PATH               Results directory
    --label TEXT                Label appended to the default results directory
    --worker-plan-cache-mode M  Persistently set plan_cache_mode on workers
    -h, --help                  Show this help
EOF
        exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)        BUILD=1; shift ;;
        --warehouses)   WAREHOUSES=$2; shift 2 ;;
        --shards)       SHARDS=$2; shift 2 ;;
        --jobs)         JOBS=$2; shift 2 ;;
        --clients)      CLIENTS=$2; shift 2 ;;
        --duration)     DURATION=$2; shift 2 ;;
        --iterations)   ITERATIONS=$2; shift 2 ;;
        --modes)        MODES=$(tr ',' ' ' <<< "$2"); shift 2 ;;
        --protocol)     PROTOCOL=$2; shift 2 ;;
        --warmup)       WARMUP=$2; shift 2 ;;
        --reload)       RELOAD=1; shift ;;
        --reset-between-modes) RESET_BETWEEN_MODES=1; shift ;;
        --vacuum-before-run) VACUUM_BEFORE_RUN=1; shift ;;
        --cooldown)     COOLDOWN=$2; shift 2 ;;
        --diagnostics)  DIAGNOSTICS=1; shift ;;
        --outdir)       OUTDIR=$2; shift 2 ;;
        --label)        LABEL=$2; shift 2 ;;
        --worker-plan-cache-mode) WORKER_PLAN_CACHE_MODE=$2; shift 2 ;;
        -h|--help)      usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ $RELOAD -eq 1 && $RESET_BETWEEN_MODES -eq 1 ]]; then
    echo "--reload and --reset-between-modes are mutually exclusive" >&2
    exit 1
fi

if ! [[ $COOLDOWN =~ ^[0-9]+$ ]]; then
    echo "--cooldown must be a non-negative integer" >&2
    exit 1
fi

mode_options() {
    case "$1" in
        off)   echo "-c citus.enable_prepared_statement_caching=off" ;;
        part1) echo "mode 'part1' needs citus.enable_prepared_statement_fast_path," \
                    "which is not in this build" >&2; exit 1 ;;
        both)  echo "-c citus.enable_prepared_statement_caching=on" ;;
        *) echo "unknown mode: $1" >&2; exit 1 ;;
    esac
}

load_data() {
    psql -X -q -p "$COORDINATOR_PORT" -v ON_ERROR_STOP=1 \
        -v shards="$SHARDS" -f "$HERE/01_schema.sql"
    psql -X -q -v ON_ERROR_STOP=1 -f "$HERE/02_load_items.sql"

    # warehouses are independent, so load disjoint ranges concurrently
    local per=$(( (WAREHOUSES + JOBS - 1) / JOBS ))
    local w=1
    while [[ $w -le $WAREHOUSES ]]; do
        local hi=$(( w + per - 1 ))
        [[ $hi -gt $WAREHOUSES ]] && hi=$WAREHOUSES
        echo "$w $hi"
        w=$(( hi + 1 ))
    done | xargs -P "$JOBS" -n 2 bash -c \
        'psql -X -q -v ON_ERROR_STOP=1 -v w_from="$0" -v w_to="$1" -f '"$HERE"'/02_load_warehouses.sql'

    psql -X -q -p "$COORDINATOR_PORT" -v ON_ERROR_STOP=1 -f "$HERE/03_procs.sql"
    psql -X -q -c "ANALYZE" > /dev/null
}

vacuum_analyze() {
    psql -X -q -v ON_ERROR_STOP=1 -c "VACUUM (ANALYZE)
        tpcc.warehouse, tpcc.district, tpcc.customer, tpcc.history,
        tpcc.new_order, tpcc.orders, tpcc.order_line, tpcc.stock, tpcc.item" \
        > /dev/null
}

capture_diagnostics() {
    local phase=$1
    local clients=$2
    local mode=$3
    local iteration=$4
    local file="$OUTDIR/diagnostics_c${clients}_${mode}_iter${iteration}_${phase}.txt"

    {
        echo "timestamp: $(date -Is)"
        echo "phase: $phase"
        echo "clients: $clients"
        echo "mode: $mode"
        echo "iteration: $iteration"
        echo
        psql -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL'
    SET statement_timeout = '30s';

SELECT citus_backend_gpid() AS collector_gpid,
       inet_server_addr() AS server_addr,
       inet_server_port() AS server_port;

SELECT table_name,
       count(*) AS placements,
       pg_size_pretty(COALESCE(sum(shard_size), 0)::bigint) AS total_size,
       COALESCE(sum(shard_size), 0)::bigint AS total_bytes
FROM citus_shards
WHERE table_name::text LIKE 'tpcc.%'
GROUP BY table_name
ORDER BY total_bytes DESC;

SELECT xact_commit, xact_rollback, blks_read, blks_hit,
       tup_inserted, tup_updated, tup_deleted,
       temp_files, temp_bytes, deadlocks
FROM pg_stat_database
WHERE datname = current_database();

SELECT nodeid, success, result
FROM run_command_on_all_nodes($command$
    SELECT row_to_json(stats)::text
    FROM (
        SELECT COALESCE(sum(n_live_tup), 0)::bigint AS live_tuples,
               COALESCE(sum(n_dead_tup), 0)::bigint AS dead_tuples,
               COALESCE(sum(autovacuum_count), 0)::bigint AS autovacuums,
               COALESCE(sum(autoanalyze_count), 0)::bigint AS autoanalyzes
        FROM pg_stat_user_tables
        WHERE schemaname = 'tpcc'
    ) stats
$command$)
ORDER BY nodeid;

SELECT nodeid, success, result
FROM run_command_on_all_nodes($command$
    SELECT row_to_json(wal_stats)::text FROM pg_stat_wal wal_stats
$command$)
ORDER BY nodeid;

SELECT nodeid, success, result
FROM run_command_on_all_nodes($command$
    SELECT row_to_json(bgwriter_stats)::text
    FROM pg_stat_bgwriter bgwriter_stats
$command$)
ORDER BY nodeid;
SQL
    } > "$file" 2>&1 || echo "WARNING: diagnostics failed (see $file)" >&2
}

if [[ $BUILD -eq 1 || $RELOAD -eq 1 || $RESET_BETWEEN_MODES -eq 1 ]]; then
    if [[ $BUILD -eq 1 ]]; then
        echo "== building: $WAREHOUSES warehouses, $SHARDS shards, $JOBS loader jobs"
    else
        echo "== resetting at startup: $WAREHOUSES warehouses, $SHARDS shards, $JOBS loader jobs"
    fi
    time load_data

fi

if [[ $BUILD -eq 1 ]]; then
    psql -X -c "SELECT 'warehouse' AS t, count(*) FROM tpcc.warehouse
          UNION ALL SELECT 'customer', count(*) FROM tpcc.customer
          UNION ALL SELECT 'orders', count(*) FROM tpcc.orders
          UNION ALL SELECT 'order_line', count(*) FROM tpcc.order_line
          UNION ALL SELECT 'stock', count(*) FROM tpcc.stock ORDER BY 1"
fi

if [[ -n "$WORKER_PLAN_CACHE_MODE" ]]; then
    echo "== setting plan_cache_mode=$WORKER_PLAN_CACHE_MODE on workers"
    db=$(psql -X -tAc 'SELECT current_database()')
    psql -X -q -p "$COORDINATOR_PORT" \
        -c "SELECT run_command_on_workers(\$\$ALTER DATABASE \"$db\" SET plan_cache_mode = '$WORKER_PLAN_CACHE_MODE'\$\$)" \
        > /dev/null
fi

WAREHOUSES=$(psql -X -tAc "SELECT count(*) FROM tpcc.warehouse")
if [[ "$WAREHOUSES" -lt 1 ]]; then
    echo "tpcc schema is empty; run with --build first" >&2
    exit 1
fi

[[ -n "$OUTDIR" ]] || OUTDIR="$REPO/bench_results/tpcc_$(date +%Y%m%d_%H%M%S)${LABEL:+_$LABEL}"
mkdir -p "$OUTDIR"

# record enough context to tell two runs apart later
{
    echo "date:        $(date -Is)"
    echo "label:       ${LABEL:-none}"
    echo "target:      ${PGHOST:-local}:${PGPORT:-5432} db=${PGDATABASE:-default}"
    echo "driver:      $(hostname), $(nproc) cpus"
    echo "warehouses:  $WAREHOUSES   shards: $SHARDS"
    echo "clients:     $CLIENTS   duration: ${DURATION}s   iterations: $ITERATIONS"
    echo "modes:       $MODES   protocol: $PROTOCOL   warmup: ${WARMUP}s"
    echo "reset:       reload=$RELOAD between_modes=$RESET_BETWEEN_MODES"
    echo "maintenance: vacuum=$VACUUM_BEFORE_RUN cooldown=${COOLDOWN}s diagnostics=$DIAGNOSTICS"
    echo "pgbench:     $(pgbench --version)"
    echo
    psql -X -c "SELECT version()" || true
    psql -X -c "SELECT extversion FROM pg_extension WHERE extname='citus'" || true
    psql -X -c "SELECT nodename, nodeport, noderole, isactive FROM pg_dist_node ORDER BY nodeid" || true
    psql -X -c "SELECT name, setting FROM pg_settings WHERE name IN
                ('citus.max_cached_conns_per_worker','citus.max_adaptive_executor_pool_size',
                 'citus.shard_count','citus.stat_tenants_track','plan_cache_mode',
                 'max_connections','shared_buffers') ORDER BY name" || true
} > "$OUTDIR/env.txt" 2>&1

SUMMARY="$OUTDIR/summary.csv"
echo "workload,warehouses,clients,mode,iter,tps,lat_avg_ms,nopm" > "$SUMMARY"

DECK=(
    -f "$HERE/scripts/neword.sql@45"
    -f "$HERE/scripts/payment.sql@43"
    -f "$HERE/scripts/ostat.sql@4"
    -f "$HERE/scripts/delivery.sql@4"
    -f "$HERE/scripts/slev.sql@4"
)

echo "== tpcc: warehouses=$WAREHOUSES clients=$CLIENTS duration=${DURATION}s iterations=$ITERATIONS"
echo "== modes: $MODES"
echo "== results: $OUTDIR"

IFS=',' read -ra CLIENT_LIST <<< "$CLIENTS"
FIRST_ITERATION=1
FIRST_MODE=1

for c in "${CLIENT_LIST[@]}"; do
    threads=$(( c < 16 ? c : 16 ))

    for ((i = 1; i <= ITERATIONS; i++)); do
        if [[ $RELOAD -eq 1 ]]; then
            if [[ $FIRST_ITERATION -eq 1 ]]; then
                FIRST_ITERATION=0
            else
                echo "  reloading dataset"
                load_data > /dev/null
            fi
        fi

        # New-Order grows the dataset much faster than Delivery drains it, so a
        # later run always sees a bigger database. Rotate the mode order between
        # iterations so that drift cannot line up with any one mode.
        order=($MODES)
        shift_by=$(( (i - 1) % ${#order[@]} ))
        order=("${order[@]:shift_by}" "${order[@]:0:shift_by}")

        for mode in "${order[@]}"; do
            opts=$(mode_options "$mode")

            if [[ $RESET_BETWEEN_MODES -eq 1 ]]; then
                if [[ $FIRST_MODE -eq 1 ]]; then
                    FIRST_MODE=0
                else
                    echo "  resetting dataset before c=$c mode=$mode iter=$i"
                    load_data > "$OUTDIR/reset_c${c}_${mode}_iter${i}.txt" 2>&1
                fi
            fi

            if [[ $VACUUM_BEFORE_RUN -eq 1 ]]; then
                echo "  vacuuming before c=$c mode=$mode iter=$i"
                vacuum_analyze
            fi

            if [[ $DIAGNOSTICS -eq 1 ]]; then
                capture_diagnostics before_warmup "$c" "$mode" "$i"
            fi

            if [[ $COOLDOWN -gt 0 ]]; then
                echo "  cooling down for ${COOLDOWN}s"
                sleep "$COOLDOWN"
            fi

            if [[ $WARMUP -gt 0 ]]; then
                PGOPTIONS="$opts" pgbench -n -M "$PROTOCOL" -c "$c" -j "$threads" \
                    -T "$WARMUP" -D warehouses="$WAREHOUSES" "${DECK[@]}" \
                    > /dev/null 2>&1 || true
            fi

            out="$OUTDIR/tpcc_c${c}_${mode}_iter${i}.txt"
            PGOPTIONS="$opts" pgbench -n -M "$PROTOCOL" -c "$c" -j "$threads" \
                -T "$DURATION" -D warehouses="$WAREHOUSES" "${DECK[@]}" \
                > "$out" 2>&1 || {
                    echo "FAILED c=$c mode=$mode iter=$i (see $out)" >&2
                    tail -5 "$out" >&2
                    if [[ $DIAGNOSTICS -eq 1 ]]; then
                        capture_diagnostics after_failure "$c" "$mode" "$i"
                    fi
                    continue
                }

            if [[ $DIAGNOSTICS -eq 1 ]]; then
                capture_diagnostics after_measurement "$c" "$mode" "$i"
            fi

            tps=$(grep -oE 'tps = [0-9.]+' "$out" | head -1 | awk '{print $3}')
            lat=$(grep -oE 'latency average = [0-9.]+' "$out" | head -1 | awk '{print $4}')
            # tpmC counts New-Order only, which is 45% of the deck
            nopm=$(awk -v t="$tps" 'BEGIN { printf "%.1f", t * 0.45 * 60 }')

            echo "tpcc,$WAREHOUSES,$c,$mode,$i,$tps,$lat,$nopm" >> "$SUMMARY"
            printf '  c=%-4s %-6s iter=%s  tps=%-10s lat=%-9s nopm=%s\n' \
                   "$c" "$mode" "$i" "$tps" "$lat" "$nopm"
        done
    done
done

echo
python3 "$HERE/analyze.py" "$SUMMARY" | tee "$OUTDIR/report.txt"
