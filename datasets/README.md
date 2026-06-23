# Distribute Table Advisor — sample datasets

Sample schemas + data used to demo the "Distribute Table" advisor. Each script
creates a self-contained schema in plain PostgreSQL (no Citus required), and
ends with `ANALYZE` so the advisor sees fresh `pg_class` / `pg_stats` data.

| Script | Schema | Workload | Notes |
| --- | --- | --- | --- |
| [oltp_shop.sql](oltp_shop.sql) | `oltp_shop` | E-commerce OLTP | Power-law over `customer_id` (Zipfian, α=3). 7 tables, ~1M rows, 20k customers. |
| [analytics_events.sql](analytics_events.sql) | `analytics_events` | Product analytics / event tracking | Power-law over `user_id` (sessions), `event_type_id` and `page_id` (events). 8 tables, ~1.25M rows. |
| [social_graph.sql](social_graph.sql) | `social_graph` | Social network / DMs — **the hard one** | Self-FKs, polymorphic FKs, celebrity skew, M:N junctions with competing distribution keys. 8 tables, ~1.7M rows. |

## Workload scripts (pgbench)

Per-dataset workload scripts live in [workloads/](workloads/). They use
pgbench's `\if/\elif/\endif` weighted-branch pattern and a Zipfian tenant
pick (`random_zipfian`) so request skew mirrors data skew — i.e. whales get
hit more often, which is what makes hot-shard / data-skew issues observable.

| Dataset | Script | Mix |
| --- | --- | --- |
| `oltp_shop` | [workloads/oltp_shop_read.sql](workloads/oltp_shop_read.sql) | 100% read |
| `oltp_shop` | [workloads/oltp_shop_mixed.sql](workloads/oltp_shop_mixed.sql) | 80% read / 20% write |
| `analytics_events` | [workloads/analytics_events_read.sql](workloads/analytics_events_read.sql) | 100% read — 80% per-user + 20% cross-cutting dashboard aggregates |
| `analytics_events` | [workloads/analytics_events_mixed.sql](workloads/analytics_events_mixed.sql) | 50% read / 50% write — live event ingest + dashboards |
| `social_graph` | [workloads/social_graph_read.sql](workloads/social_graph_read.sql) | 100% read — symmetric pairs for strategy-A vs strategy-B comparison |
| `social_graph` | [workloads/social_graph_mixed.sql](workloads/social_graph_mixed.sql) | 60% read / 40% write — FOLLOW + LIKE writes deliberately hit celebrity / viral hot shards |

## Citus distribution prep scripts

Each dataset has a matching `citus_prep_*.sql` script that turns the plain
Postgres schema into a fully distributed Citus schema in one shot —
including every PK / FK rewrite required by Citus's distribution rules
(distributed PKs must include the dist column; FKs between two distributed
tables must be on the dist column AND colocated). The scripts are
idempotent (`IF EXISTS` guards + `DO/EXCEPTION` wrappers around
`create_*_table`).

| Dataset | Prep script | Notes |
| --- | --- | --- |
| `oltp_shop` | [citus_prep_oltp_shop.sql](citus_prep_oltp_shop.sql) | Reference + distributed mix. Composite PKs on the fact tables. |
| `analytics_events` | [citus_prep_analytics_events.sql](citus_prep_analytics_events.sql) | 5 dimensions as reference tables, 3 facts colocated on `user_id`. |
| `social_graph` | [citus_prep_social_graph.sql](citus_prep_social_graph.sql) | Strategy A. **Permanently drops 6 cross-shard FKs**, documented in the file header — those are the integrity rules the advisor should flag as "app-level only". |

```bash
psql -h <host> -p <port> -d <db> -f tmp/advisor_demo/<dataset>.sql
psql -h <host> -p <port> -d <db> -f tmp/advisor_demo/citus_prep_<dataset>.sql
```


Each script is one pgbench transaction. Run with:

```bash
# Baseline (no distribution / wrong distribution / right distribution — same
# command line, just re-run after each citus distribute_table change).
pgbench -n -h <host> -p <port> -d <db> \
        -f tmp/advisor_demo/workloads/oltp_shop_read.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared

pgbench -n -h <host> -p <port> -d <db> \
        -f tmp/advisor_demo/workloads/oltp_shop_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared
```

Typical comparison sequence (the advisor demo):

1. Run the workload on the bare schema → baseline tps / p95.
2. `SELECT create_distributed_table('oltp_shop.customers', 'customer_id');`
   (and the other tables on the same key, plus `create_reference_table`
   on `products` / `product_categories`), `ANALYZE`, re-run.
3. Undistribute, distribute by a *wrong* key (e.g. `order_id`), re-run.
4. Compare tps / p95 across the three runs.

Why the OLTP scripts demonstrate distribution effectiveness:

- Almost every read is tenant-scoped (`WHERE customer_id = :cid`) → with
  the right distribution they are single-shard router queries; with a
  wrong distribution they fan out across every shard.
- The mixed-workload's `PLACE ORDER` branch is a multi-statement
  transaction touching `orders` + `order_items` + `payments`, all with
  the same `customer_id`. Colocated on `customer_id` it's a single-shard
  write; colocated wrong (or distributed on different keys) it becomes a
  multi-shard distributed transaction (2PC, much slower, more contention).
- The product / category branches (small reference tables) are local on
  every node iff those tables are declared reference tables — another
  thing the workload measures end-to-end.
- The Zipfian customer pick concentrates load on the same whales that the
  data generator concentrates rows on, so any hot-shard issue from
  distributing on a skewed key shows up immediately in tps / p95.

The `social_graph` workloads take this a step further: they include
**symmetric query pairs** (e.g. "who I follow" + "who follows me",
"my likes" + "post's recent likers") so the *same* script reveals different
bottlenecks under different distribution choices — that's the
strategy-A-vs-strategy-B comparison the advisor needs to make visible. The
mixed script's FOLLOW write uses a Zipfian celebrity target (α=4) and the
LIKE write uses a Zipfian viral-post target (α=3), so writes pile onto the
hot shards that would form under `followee_id` / `post_id` distribution —
those branches stay cheap under `follower_id` / `user_id` distribution. Run
the same `pgbench` invocation under each strategy and compare:

```bash
# Strategy A — follows by follower_id, likes by user_id
psql -h <host> -p <port> -d <db> -f tmp/advisor_demo/citus_prep_social_graph.sql
pgbench -n -f tmp/advisor_demo/workloads/social_graph_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared

# Strategy B — flip the symmetric tables (run after Strategy A's prep)
psql -h <host> -p <port> -d <db> <<'SQL'
SELECT undistribute_table('social_graph.follows', cascade_via_foreign_keys => true);
SELECT undistribute_table('social_graph.likes',   cascade_via_foreign_keys => true);
SELECT create_distributed_table('social_graph.follows', 'followee_id');
SELECT create_distributed_table('social_graph.likes',   'post_id');
ANALYZE;
SQL
pgbench -n -f tmp/advisor_demo/workloads/social_graph_mixed.sql \
        -T 60 -c 8 -j 4 -P 5 -M prepared
```

## OLTP Shop

E-commerce / order-processing schema with a realistic power-law: a few "whale"
customers own most of the orders, items and payments; the long tail of
customers has only one or two orders each.

```
product_categories  ──┐
                      ▼
                  products ◄───────────────┐
                                           │
customers ──┬── addresses ◄──┐             │
            ├── orders       │             │
            │     │          │             │
            │     ├── shipping_address_id ─┘
            │     │
            │     ├── order_items ─────────┘
            │     └── payments
```

Run it:

```bash
psql -d postgres -f tmp/advisor_demo/oltp_shop.sql
```

What the advisor should pick up:

* **Natural distribution column:** `customer_id` appears in 5 tables
  (`customers`, `addresses`, `orders`, `order_items`, `payments`) — a strong
  "matching join keys" signal. `order_items` and `payments` carry
  `customer_id` denormalized so they can be colocated with `orders`.
* **Large fact tables:** `order_items` (~600k), `orders` (200k),
  `payments` (~166k). High cardinality on `customer_id` and `order_id`, with
  visible skew in `pg_stats.most_common_freqs` (top customer ≈ 3.5% of rows)
  thanks to the power-law.
* **Reference table candidates:** `products` (~500 rows) and
  `product_categories` (~20 rows) — small, no good distribution column,
  joined by everything.
* **Anti-signals (don't pick these):** `status`, `country_code`, `currency`,
  `method` are deliberately low-cardinality enums.

Quick check after loading:

```sql
-- Top 10 whale customers by order count
SELECT customer_id, count(*) AS orders
FROM oltp_shop.orders
GROUP BY customer_id
ORDER BY orders DESC
LIMIT 10;

-- % of customers in the long tail (<= 3 orders)
SELECT
    count(*) FILTER (WHERE orders <= 3) * 100.0 / count(*) AS pct_small_tail,
    count(*) FILTER (WHERE orders > 100)                   AS num_whales
FROM (
    SELECT customer_id, count(*) AS orders
    FROM oltp_shop.orders GROUP BY customer_id
) s;
```

## Analytics Events

Product-analytics / event-tracking schema (think tiny Mixpanel or Amplitude).
One huge `events` table, a medium-sized `sessions` table, a `users` dimension,
and a handful of small reference tables. Three independent power-laws layered
on top:

* sessions per user (a few power users dominate),
* events per event type (`page_view` ~21%, `click` ~7%, trailing into a long
  tail of 25 `custom_event_*` types),
* events per page (homepage ~8% of all page hits).

```
event_types ──┐
device_types ─┤
browsers ─────┼──► sessions ──┐
countries ────┤       ▲       │
              │       │       ▼
users ────────┴───────┴───► events ◄── pages
```

Run it:

```bash
psql -d postgres -f tmp/advisor_demo/analytics_events.sql
```

What the advisor should pick up:

* **Natural distribution column:** `user_id` appears in 3 tables (`users`,
  `sessions`, `events`) with ~50k distinct values and realistic skew (top
  user ≈ 2.7% of events). `events` carries `user_id` denormalized so it can
  colocate with `sessions` on `user_id`.
* **Secondary candidate:** `session_id` (sessions + events, ~200k distinct).
  Loses on the "matching join keys" count.
* **Big fact tables:** `events` (~1M rows), `sessions` (200k rows).
* **Reference table candidates:** `event_types` (50), `device_types` (10),
  `browsers` (20), `countries` (30), `pages` (500) — all small, all heavily
  joined.
* **Anti-signals (don't pick these):** `event_type_id` has only 50 distinct
  values but its top value owns ~21% of all rows — classic skewed enum that
  the advisor must reject. Same story for `device_type_id` (~11%),
  `browser_id` (~5%), `country_code` (~6%), and even `page_id` (~8%).

Quick check after loading:

```sql
-- Event-type frequency (Zipfian — page_view dominates):
SELECT et.name, count(*) AS n,
       round(100.0*count(*)/sum(count(*)) OVER (), 2) AS pct
FROM analytics_events.events e
JOIN analytics_events.event_types et USING (event_type_id)
GROUP BY et.name ORDER BY n DESC LIMIT 10;

-- Long-tail check on sessions per user:
WITH s AS (
    SELECT u.user_id, count(se.*) AS sessions
    FROM analytics_events.users u
    LEFT JOIN analytics_events.sessions se ON se.user_id = u.user_id
    GROUP BY u.user_id
)
SELECT count(*) FILTER (WHERE sessions = 0)            AS never_visited,
       count(*) FILTER (WHERE sessions BETWEEN 1 AND 2) AS small_tail,
       count(*) FILTER (WHERE sessions > 100)          AS power_users,
       max(sessions)                                   AS top_user_sessions
FROM s;
```

## Social Graph — the hard one

A miniature social network / DM schema, deliberately designed to be painful
to distribute. The advisor doesn't get a clean winning answer here — it has
to either pick a column and accept trade-offs, or flag the schema as
graph-shaped and recommend manual partitioning. Every classical Citus pitfall
is represented:

```
users ◄──┬─ follows  (follower_id, followee_id)   ← two FKs to users
         ├─ posts    (author_id, parent_post_id)  ← author + self-FK hierarchy
         ├─ likes    (user_id, post_id)           ← M:N junction, two keys
         ├─ conversation_participants (user_id)   ← group membership
         ├─ messages (sender_id, conversation_id) ← edge with payload
         └─ notifications (user_id, actor_id,
                           target_type, target_id) ← POLYMORPHIC FK
```

Painful patterns and how they show up in `pg_stats`:

* **Self-referencing edges with no winning side.** `follows` has two bigint
  columns both pointing at `users.user_id`. Whichever one you distribute on,
  the reverse-direction query shuffles.
* **Celebrity skew.** `followee_id` is Zipfian (α=4). User 1 has 18,997
  followers (~5% of all `follows` rows) — distributing by `followee_id`
  concentrates ~10% of the table on a single shard. User 2 has 5,225, user 3
  has 3,530, trailing off into a long tail of users with 1-5 followers.
* **M:N junction with two competing keys.** `likes(user_id, post_id)` — both
  high-cardinality (27k and 47k distinct values), both with mild skew. There
  is no objectively correct answer.
* **Polymorphic FK.** `notifications.(target_type, target_id)` references
  either a user or a post depending on the row. `target_id` keyspaces
  overlap (id=5 means a post in one row, a user in another), so it cannot
  be expressed as a real FK. The advisor must explicitly flag this.
* **Same entity under many aliases.** `users.user_id` is referenced as 8
  different column names across the schema — `follower_id`, `followee_id`,
  `author_id`, `user_id` (in `likes`, `notifications`, `conversation_participants`),
  `sender_id`, `actor_id`. A naive "match by column name" heuristic misses
  most of them; the advisor needs to walk FK metadata.

Run it:

```bash
psql -d postgres -f tmp/advisor_demo/social_graph.sql
```

What a good advisor output looks like on this schema:

* **Distribute `users` by `user_id`.** (PK, no choice to make.)
* **Distribute `posts` by `author_id`** — colocates with `users`. Replies
  cross shards, accept the cost.
* **`follows`: pick `follower_id`** (balanced, ~29k distinct, top-freq
  0.017%) and warn that "who follows celebrity X?" queries will fan out
  across all shards — and that the alternative (`followee_id`) puts ~5% of
  the table on one shard because of celebrity skew.
* **`likes`: pick `user_id`** to colocate with `users` and `posts.author_id`.
  Accept that "who liked post X?" shuffles. (Or distribute by `post_id` and
  accept the opposite — there is no free lunch here.)
* **`messages` / `conversation_participants` / `conversations`:** distribute
  on `conversation_id`. Cross-user-fan-out queries (e.g., "all my DMs")
  shuffle. This is the standard trade-off for group-chat schemas.
* **`notifications`:** distribute by `user_id` (the recipient). Flag
  `(target_type, target_id)` as a polymorphic FK — cannot enforce
  referential integrity, cannot infer colocation.

Quick checks after loading:

```sql
-- Celebrity skew (user 1 is the mega-celeb):
SELECT user_id, verified, followers_cnt, following_cnt, posts_cnt
FROM social_graph.users
ORDER BY followers_cnt DESC LIMIT 10;

-- The two-key dilemma on `follows`: both columns are equally "valid"
-- but radically different in skew:
SELECT attname, n_distinct,
       round(most_common_freqs[1]::numeric, 5) AS top_value_freq
FROM pg_stats
WHERE schemaname='social_graph' AND tablename='follows'
  AND attname IN ('follower_id','followee_id');

-- The polymorphic FK with overlapping keyspaces:
SELECT target_type, count(*), min(target_id), max(target_id)
FROM social_graph.notifications GROUP BY target_type;

-- All 8 names users.user_id is referenced under:
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema='social_graph'
  AND column_name IN ('user_id','follower_id','followee_id','author_id',
                      'sender_id','actor_id')
ORDER BY table_name, column_name;
```
