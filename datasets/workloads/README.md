# Workloads — pgbench scripts for the Distribute Table advisor demo

Each script is a single `pgbench` transaction using the `\if/\elif/\endif`
weighted-branch pattern, with `random_zipfian` tenant picks so request skew
mirrors the data skew built into the matching dataset. Run any script
against plain PostgreSQL first (baseline), then re-run after each
`create_distributed_table` / `undistribute_table` change to compare tps and
latency.

All commands below assume your coordinator is on `localhost:9700` and the
database is `postgres`. Adjust `-h / -p / -d` for your cluster. Run from the
repository root (`/workspaces/citus`) so the `-f` paths resolve.

## Canonical flags

```
-n              # don't VACUUM before the run (we already ANALYZEd at load)
-T 60           # 60-second run; bump to 300+ for stable numbers
-c 8 -j 4       # 8 clients across 4 threads (tune to your box)
-P 5            # progress line every 5s
-M prepared     # use prepared statements (closer to a real app)
```

A 10-second smoke test (`-T 10 -c 4 -j 2 -P 2 -M prepared`) is enough to
confirm a script parses and executes against the data; use 60s+ for any
number you intend to compare.

---

## `oltp_shop` — e-commerce OLTP

Dataset: [../oltp_shop.sql](../oltp_shop.sql). Distribution column: `customer_id`.

### Read-only (100% read)

```bash
pgbench -n -h localhost -p 9700 -d postgres \
        -f tmp/advisor_demo/workloads/oltp_shop_read.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared
```

Mix: 30% customer lookup, 30% recent orders, 15% order+items+products join,
10% addresses, 10% lifetime spend, 5% product lookup. All but the last are
tenant-scoped (`WHERE customer_id = :cid`) → single-shard routers when
distributed by `customer_id`, fan-outs otherwise.

### Mixed (80% read / 20% write)

```bash
pgbench -n -h localhost -p 9700 -d postgres \
        -f tmp/advisor_demo/workloads/oltp_shop_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared
```

Read mix scaled to 80%. Writes: 10% PLACE ORDER (the multi-statement
`orders` + `order_items` + `payments` transaction — single-shard under
`customer_id` colocation, distributed 2PC otherwise), 5% UPDATE order
status, 3% ADD address, 2% UPDATE customer status.

### Comparison plan

The prep script
[../citus_prep_oltp_shop.sql](../citus_prep_oltp_shop.sql) handles every
constraint rewrite (composite PKs on the fact tables, FKs re-added
after distribution, reference tables for `products` /
`product_categories`). It's idempotent.

```bash
# 1. Baseline (plain Postgres) — run both scripts as documented above.
# 2. Distribute and re-run:
psql -h localhost -p 9700 -d postgres -f tmp/advisor_demo/citus_prep_oltp_shop.sql
pgbench -n -f tmp/advisor_demo/workloads/oltp_shop_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared -h localhost -p 9700 -d postgres
# 3. (Optional) `SELECT undistribute_table(..., cascade_via_foreign_keys=>true)`
#    and re-run the prep against a different key to show what a bad
#    recommendation costs.
```

---

## `analytics_events` — product analytics / event ingest

Dataset: [../analytics_events.sql](../analytics_events.sql). Distribution column: `user_id`.

### Read-only (100% read)

```bash
pgbench -n -h localhost -p 9700 -d postgres \
        -f tmp/advisor_demo/workloads/analytics_events_read.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared
```

Mix: 80% per-user router queries (profile, sessions, recent events, session
detail, top event types) + 20% cross-cutting dashboard aggregates (global
top event types, top pages, hourly time series, active users by country).
The 20% aggregates are intentionally fan-out — they're the baseline that
says "even the right distribution can't help these".

### Mixed (50% read / 50% write — live ingest)

```bash
pgbench -n -h localhost -p 9700 -d postgres \
        -f tmp/advisor_demo/workloads/analytics_events_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared
```

50/50 split because analytics ingest is write-heavy. The marquee write is
INSERT EVENT, which uses `INSERT … SELECT FROM sessions WHERE user_id = :uid
LIMIT 1` — single-shard under `user_id` distribution (subquery + insert both
land on the same shard, which also satisfies the cross-table FK without a
distributed transaction).

> **Destructive:** the mixed script inserts events / sessions and updates
> counters. Re-run the loader if you need an identical starting point
> between bench scenarios.

### Comparison plan

The prep script
[../citus_prep_analytics_events.sql](../citus_prep_analytics_events.sql)
drops the `users.external_id` UNIQUE, rewrites `sessions` and `events`
PKs as composite `(user_id, ...)`, declares the five dimensions as
reference tables, then distributes `users` / `sessions` / `events`
colocated on `user_id`. Idempotent.

```bash
# 1. Baseline.
# 2. Distribute and re-run:
psql -h localhost -p 9700 -d postgres -f tmp/advisor_demo/citus_prep_analytics_events.sql
pgbench -n -f tmp/advisor_demo/workloads/analytics_events_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared -h localhost -p 9700 -d postgres
# 3. (Optional) failure modes: undistribute, then re-distribute events by
#    session_id or event_type_id to show fan-outs / hot shards in the same
#    workload.
```

---

## `social_graph` — the strategy-A vs strategy-B demo

Dataset: [../social_graph.sql](../social_graph.sql). No single winning
distribution — every choice trades one query path for another.

### Read-only (100% read)

```bash
pgbench -n -h localhost -p 9700 -d postgres \
        -f tmp/advisor_demo/workloads/social_graph_read.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared
```

The mix includes **symmetric query pairs** ("who I follow" + "who follows
me", "my likes" + "post's recent likers") so the same script reveals
different bottlenecks under different distribution choices. A celebrity
fan-in branch (5%) and a Zipfian viral-post likers branch (7%) deliberately
hit the shards that would form hot under `followee_id` / `post_id`
distribution.

### Mixed (60% read / 40% write — celebrity & viral writes)

```bash
pgbench -n -h localhost -p 9700 -d postgres \
        -f tmp/advisor_demo/workloads/social_graph_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared
```

15% FOLLOW (`:target` Zipfian α=4 → celebrities) and 12% LIKE (`:vpost`
Zipfian α=3 → viral posts) are the strategy-sensitive writes: balanced
under `follower_id` / `user_id` distribution, hot-shard under `followee_id`
/ `post_id`. Plus 6% POST, 4% MARK NOTIFICATIONS READ, 2% SEND DM, 1%
UPDATE bio.

> **Destructive:** inserts follows / likes / posts / messages and updates
> notifications + users. Reload between scenarios for identical starting
> conditions.

### Comparison plan — same workload under two strategies

The prep script
[../citus_prep_social_graph.sql](../citus_prep_social_graph.sql)
implements **Strategy A** end-to-end and documents the six cross-shard
FKs it has to permanently drop (followee_id, parent_post_id, likes.post_id,
conversation_participants.user_id, messages.sender_id, notifications.actor_id)
— those are exactly the integrity rules the advisor should flag as
"Citus can't enforce; app-level only".

The social_graph workloads do a `SET citus.enable_repartition_joins =
on;` at the top because the timeline-build / who-I-follow / my-likes /
post-likers branches are intentional cross-key joins. Without
repartitioning enabled they'd error; the resulting tps drop is the demo
signal that those queries don't colocate.

```bash
# Strategy A
psql -h localhost -p 9700 -d postgres -f tmp/advisor_demo/citus_prep_social_graph.sql
pgbench -n -f tmp/advisor_demo/workloads/social_graph_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared -h localhost -p 9700 -d postgres
```

```sql
-- Strategy B — flip the symmetric tables (run after Strategy A's prep)
SELECT undistribute_table('social_graph.follows', cascade_via_foreign_keys => true);
SELECT undistribute_table('social_graph.likes',   cascade_via_foreign_keys => true);
SELECT create_distributed_table('social_graph.follows', 'followee_id');
SELECT create_distributed_table('social_graph.likes',   'post_id');
ANALYZE;
```
```bash
pgbench -n -f tmp/advisor_demo/workloads/social_graph_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared -h localhost -p 9700 -d postgres
```

Compare tps + p95 + per-shard size between the two runs. Some branches
will get faster, some slower; the "timeline build" branch stays painful
either way (cross-key join with no colocation). That's the demo.

---

## Capturing results

For side-by-side runs, redirect to per-strategy files and grep the summary:

```bash
pgbench -n -f tmp/advisor_demo/workloads/social_graph_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared \
        -h localhost -p 9700 -d postgres \
        > /tmp/sg_strategy_a.out 2>&1
grep -E 'tps|latency' /tmp/sg_strategy_a.out
```

For per-statement timing inside one run (useful for spotting which branch
got expensive after a distribution change), add `-r`:

```bash
pgbench -n -r -f tmp/advisor_demo/workloads/social_graph_read.sql \
        -T 30 -c 4 -j 2 -P 5 -M prepared \
        -h localhost -p 9700 -d postgres
```

`-r` prints a per-statement latency report at the end, which is the easiest
way to see "the celebrity fan-in branch went from 2ms to 45ms" when you
flipped strategies.

---

## Smoke-test results (10s, 4 clients, prepared, plain Postgres baseline)

| Script | tps | avg latency | failed |
| --- | ---: | ---: | ---: |
| `oltp_shop_read.sql`         |  582 |  6.9 ms | 0 |
| `oltp_shop_mixed.sql`        |  689 |  5.8 ms | 0 |
| `analytics_events_read.sql`  |  145 | 27.3 ms | 0 |
| `analytics_events_mixed.sql` |  241 | 16.4 ms | 0 |
| `social_graph_read.sql`      |  555 |  7.2 ms | 0 |
| `social_graph_mixed.sql`     |  885 |  4.5 ms | 0 |

These are baseline numbers on plain PostgreSQL — they're a sanity check
that every script parses and runs, not a target. The whole point of the
demo is watching them change as the distribution strategy changes.

## Smoke-test results (10s, 4 clients, prepared, after Citus prep)

Numbers from a 32-shard, 2-worker dev cluster on the same box. Whether
they're "better" or "worse" than the baseline depends on the workload's
shape — single-shard router queries get faster, fan-outs and repartition
joins get slower. That's what makes the diff interesting.

| Script | tps | avg latency | failed | notes |
| --- | ---: | ---: | ---: | --- |
| `oltp_shop_read.sql`         |  333 | 12.0 ms | 0 | every branch single-shard router |
| `oltp_shop_mixed.sql`        |  397 | 10.1 ms | 0 | PLACE ORDER is colocated, 1-shard txn |
| `analytics_events_read.sql`  |   98 | 40.7 ms | 0 | 20% intentional fan-out aggregates |
| `analytics_events_mixed.sql` |  146 | 27.3 ms | 0 | INSERT EVENT lands on user's shard |
| `social_graph_read.sql`      |   12 | 325 ms  | 0 | repartition joins fire on half the branches — the demo signal |
| `social_graph_mixed.sql`     |   20 | 196 ms  | 0 | same, plus celebrity / viral hot-shard writes |

The social_graph numbers are deliberately bad: that schema has no winning
single-column distribution, and the workload exercises every losing
direction. The advisor's job is to make those losses visible and let you
trade them off against the wins.
