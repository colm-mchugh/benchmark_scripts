-- =============================================================================
-- analytics_events_read.sql  —  100% read analytics workload (pgbench script)
-- =============================================================================
--
-- A realistic dashboard / user-explorer read mix over analytics_events:
--
--   * 80% of queries are PER-USER ("router queries" iff the schema is
--     distributed by user_id) — user profile, that user's sessions, that
--     user's recent events, a single session's events, per-user funnels.
--   * 20% are CROSS-CUTTING analytics that fan out regardless of
--     distribution — global top event types, top pages, hourly time series,
--     active-users-by-country. These exist on purpose: they give a baseline
--     for what cross-shard performance looks like under each strategy.
--
-- User pick is Zipfian (s=1.2) so request skew mirrors data skew: power
-- users get hit harder, which is what makes hot-shard issues visible when
-- distributing by a column with celebrity skew.
--
-- Time windows are intentionally long (7-60 days) so the workload still
-- produces matching rows even if the dataset was loaded a while ago.
--
-- Usage:
--   pgbench -n -f tmp/advisor_demo/workloads/analytics_events_read.sql \
--           -T 60 -c 8 -j 4 -P 5 -M prepared <db>
--
-- Suggested comparison plan:
--   1. Baseline: undistributed (or single-node Citus) → tps / p95.
--   2. distribute_table('users'/'sessions'/'events', 'user_id'),
--      reference tables for event_types/device_types/browsers/countries/pages,
--      ANALYZE, re-run.
--   3. distribute_table by session_id, by event_type_id (the skewed enum),
--      etc. → re-run to show the failure modes.
-- =============================================================================

\set uid   random_zipfian(1, 50000, 1.2)
\set sid   random(1, 200000)
\set pid   random_zipfian(1, 500, 1.5)
\set etid  random_zipfian(1, 50, 1.3)
\set op    random(1, 100)

-- =========== ROUTER QUERIES (per user, 80%) =================================

\if :op <= 15
  -- 15%  user profile lookup
  SELECT user_id, external_id, email, plan, country_code, signed_up_at
    FROM analytics_events.users
   WHERE user_id = :uid;

\elif :op <= 30
  -- 15%  user's recent sessions
  SELECT session_id, started_at, ended_at,
         device_type_id, browser_id, country_code, event_count
    FROM analytics_events.sessions
   WHERE user_id = :uid
   ORDER BY started_at DESC
   LIMIT 20;

\elif :op <= 50
  -- 20%  user's recent events (timeline)
  SELECT event_id, session_id, event_type_id, page_id,
         occurred_at, duration_ms
    FROM analytics_events.events
   WHERE user_id = :uid
     AND occurred_at > now() - interval '30 days'
   ORDER BY occurred_at DESC
   LIMIT 50;

\elif :op <= 65
  -- 15%  one session's events. user_id is included in the filter on purpose:
  --      with user_id distribution this routes to a single shard; without
  --      it (or with session_id distribution) the user_id filter would be
  --      a residual and Citus would have to query every shard for :sid.
  SELECT event_id, event_type_id, page_id, occurred_at, duration_ms
    FROM analytics_events.events
   WHERE user_id = :uid
     AND session_id = :sid
   ORDER BY occurred_at;

\elif :op <= 80
  -- 15%  user's top event types last 60 days (per-user funnel-ish)
  SELECT et.name, count(*) AS n
    FROM analytics_events.events e
    JOIN analytics_events.event_types et USING (event_type_id)
   WHERE e.user_id = :uid
     AND e.occurred_at > now() - interval '60 days'
   GROUP BY et.name
   ORDER BY n DESC
   LIMIT 10;

-- =========== CROSS-CUTTING DASHBOARD AGGREGATES (20%) =======================

\elif :op <= 85
  -- 5%   global top event types last 7 days (cross-shard aggregate)
  SELECT et.name, count(*) AS n
    FROM analytics_events.events e
    JOIN analytics_events.event_types et USING (event_type_id)
   WHERE e.occurred_at > now() - interval '7 days'
   GROUP BY et.name
   ORDER BY n DESC
   LIMIT 10;

\elif :op <= 90
  -- 5%   top pages last 7 days (cross-shard, joins to reference table)
  SELECT p.url_path, p.section, count(*) AS n
    FROM analytics_events.events e
    JOIN analytics_events.pages p USING (page_id)
   WHERE e.occurred_at > now() - interval '7 days'
     AND e.page_id IS NOT NULL
   GROUP BY p.url_path, p.section
   ORDER BY n DESC
   LIMIT 20;

\elif :op <= 95
  -- 5%   hourly event volume last 7 days (time-series, cross-shard)
  SELECT date_trunc('hour', occurred_at) AS hour, count(*) AS n
    FROM analytics_events.events
   WHERE occurred_at > now() - interval '7 days'
   GROUP BY hour
   ORDER BY hour;

\else
  -- 5%   active users by country last 30 days (cross-shard COUNT DISTINCT)
  SELECT u.country_code, count(DISTINCT s.user_id) AS active_users
    FROM analytics_events.sessions s
    JOIN analytics_events.users u USING (user_id)
   WHERE s.started_at > now() - interval '30 days'
   GROUP BY u.country_code
   ORDER BY active_users DESC
   LIMIT 10;
\endif
