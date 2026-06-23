-- =============================================================================
-- analytics_events_mixed.sql  —  50% read / 50% write (live ingest + dashboard)
-- =============================================================================
--
-- A realistic analytics mix:
--
--   * 50% of operations are WRITES dominated by single-row event ingest.
--     Each event is one INSERT carrying user_id + session_id; with user_id
--     distribution that's a single-shard write. New-session and
--     session-counter UPDATEs are also single-shard when colocated.
--   * 50% of operations are reads — same shape as analytics_events_read.sql
--     (mostly per-user, ~20% of the read share is cross-cutting analytics).
--
-- The marquee colocation demo here is the "INSERT event" path:
--   INSERT INTO events SELECT :uid, s.session_id, :etid, ...
--   FROM sessions s WHERE s.user_id = :uid ORDER BY started_at DESC LIMIT 1;
-- With users + sessions + events distributed by user_id, both the session
-- lookup (the SELECT) and the event insert happen on the SAME shard in a
-- single round trip. With a wrong distribution it's a cross-shard SELECT
-- followed by a cross-shard INSERT.
--
-- Notes on data integrity:
--   * The insert path picks the user's most recent session via subquery,
--     so the FK events(session_id) -> sessions(session_id) is satisfied
--     AND session.user_id == event.user_id (required for colocation under
--     Citus FK rules: FKs between distributed tables must align on the
--     distribution column).
--   * Long-tail users with zero sessions (~12% of users) produce no-op
--     inserts. That's realistic — an SDK with no active session drops
--     the event — and the Zipfian pick steers most traffic to power
--     users that *do* have sessions.
--
-- Usage:
--   pgbench -n -f tmp/advisor_demo/workloads/analytics_events_mixed.sql \
--           -T 60 -c 8 -j 4 -P 5 -M prepared <db>
-- =============================================================================

\set uid   random_zipfian(1, 50000, 1.2)
\set sid   random(1, 200000)
\set pid   random_zipfian(1, 500, 1.5)
\set etid  random_zipfian(1, 50, 1.3)
\set dur   random(50, 10000)
\set dt    random(1, 10)
\set br    random(1, 20)
\set op    random(1, 100)

-- ============================== READS (50%) =================================

\if :op <= 7
  -- 7%  user profile
  SELECT user_id, external_id, email, plan, country_code, signed_up_at
    FROM analytics_events.users
   WHERE user_id = :uid;

\elif :op <= 15
  -- 8%  user's recent sessions
  SELECT session_id, started_at, ended_at, device_type_id, browser_id, event_count
    FROM analytics_events.sessions
   WHERE user_id = :uid
   ORDER BY started_at DESC
   LIMIT 20;

\elif :op <= 25
  -- 10% user's recent events
  SELECT event_id, session_id, event_type_id, page_id, occurred_at, duration_ms
    FROM analytics_events.events
   WHERE user_id = :uid
     AND occurred_at > now() - interval '30 days'
   ORDER BY occurred_at DESC
   LIMIT 50;

\elif :op <= 33
  -- 8%  single session detail (user_id co-filter -> router query)
  SELECT event_id, event_type_id, page_id, occurred_at, duration_ms
    FROM analytics_events.events
   WHERE user_id = :uid AND session_id = :sid
   ORDER BY occurred_at;

\elif :op <= 39
  -- 6%  per-user top event types last 60 days
  SELECT et.name, count(*) AS n
    FROM analytics_events.events e
    JOIN analytics_events.event_types et USING (event_type_id)
   WHERE e.user_id = :uid
     AND e.occurred_at > now() - interval '60 days'
   GROUP BY et.name
   ORDER BY n DESC LIMIT 10;

\elif :op <= 42
  -- 3%  global top event types (cross-shard)
  SELECT et.name, count(*) AS n
    FROM analytics_events.events e
    JOIN analytics_events.event_types et USING (event_type_id)
   WHERE e.occurred_at > now() - interval '7 days'
   GROUP BY et.name
   ORDER BY n DESC LIMIT 10;

\elif :op <= 45
  -- 3%  top pages (cross-shard)
  SELECT p.url_path, count(*) AS n
    FROM analytics_events.events e
    JOIN analytics_events.pages p USING (page_id)
   WHERE e.occurred_at > now() - interval '7 days'
     AND e.page_id IS NOT NULL
   GROUP BY p.url_path
   ORDER BY n DESC LIMIT 20;

\elif :op <= 47
  -- 2%  hourly time series (cross-shard)
  SELECT date_trunc('hour', occurred_at) AS hour, count(*) AS n
    FROM analytics_events.events
   WHERE occurred_at > now() - interval '7 days'
   GROUP BY hour
   ORDER BY hour;

\elif :op <= 50
  -- 3%  active users by country (cross-shard distinct)
  SELECT u.country_code, count(DISTINCT s.user_id) AS active
    FROM analytics_events.sessions s
    JOIN analytics_events.users u USING (user_id)
   WHERE s.started_at > now() - interval '30 days'
   GROUP BY u.country_code
   ORDER BY active DESC LIMIT 10;

-- ============================== WRITES (50%) ================================

\elif :op <= 85
  -- 35% INSERT EVENT (the marquee colocation path)
  --     Reuses the user's most recent session so:
  --       (a) FK to sessions is satisfied
  --       (b) under user_id distribution, the whole statement is single-shard
  --     A long-tail user with no sessions yields a 0-row no-op (realistic).
  INSERT INTO analytics_events.events
       (user_id, session_id, event_type_id, page_id,
        occurred_at, duration_ms, properties)
  SELECT :uid, s.session_id, :etid, :pid, now(), :dur, NULL
    FROM analytics_events.sessions s
   WHERE s.user_id = :uid
   ORDER BY s.started_at DESC
   LIMIT 1;

\elif :op <= 90
  -- 5%  INSERT NEW SESSION (a brand-new session starts). Country is pulled
  --     from the owning user so the row stays consistent.
  INSERT INTO analytics_events.sessions
       (user_id, started_at, device_type_id, browser_id, country_code)
  SELECT :uid, now(), :dt, :br, country_code
    FROM analytics_events.users
   WHERE user_id = :uid;

\else
  -- 10% UPDATE session counter (end-of-event-batch heartbeat from the SDK)
  UPDATE analytics_events.sessions
     SET event_count = event_count + 1,
         ended_at    = now()
   WHERE user_id = :uid
     AND session_id = (
        SELECT session_id
          FROM analytics_events.sessions
         WHERE user_id = :uid
         ORDER BY started_at DESC
         LIMIT 1
     );
\endif
