-- =============================================================================
-- citus_prep_analytics_events.sql — Distribute analytics_events by user_id
-- =============================================================================
--
-- Distribution plan:
--   REFERENCE  event_types, device_types, browsers, countries, pages
--   DISTRIBUTED  users, sessions, events   (all colocated on user_id)
--
-- Constraint changes required:
--   * users.external_id UNIQUE doesn't include user_id → drop (app-level).
--   * sessions.pkey rewritten as composite (user_id, session_id).
--   * events.pkey rewritten as composite (user_id, event_id).
--   * events.session_id FK → sessions(session_id) rewritten as composite
--     (user_id, session_id) → sessions(user_id, session_id).
--   * All other FKs either land on the distribution column between colocated
--     distributed tables (sessions.user_id, events.user_id is denormalized
--     with no FK) or land on a reference table — kept after re-add.
--
-- Steps (same pattern as citus_prep_oltp_shop.sql):
--   1. Drop every inter-table FK.
--   2. Drop the external_id UNIQUE.
--   3. Rewrite per-tenant PKs as composite (user_id, ...).
--   4. Declare the 5 dimensions as reference tables.
--   5. Distribute users + sessions + events colocated on user_id.
--   6. Re-add FKs.
--   7. ANALYZE.
--
-- Idempotent (IF EXISTS guards + DO/EXCEPTION wrappers on create_*_table).
--
-- Usage:
--   psql -d <db> -f tmp/advisor_demo/analytics_events.sql
--   psql -d <db> -f tmp/advisor_demo/citus_prep_analytics_events.sql
-- =============================================================================

\set ON_ERROR_STOP on

SET search_path = analytics_events, public;

-- ---------------------------------------------------------------------------
-- STEP 1 — drop every inter-table FK.
-- ---------------------------------------------------------------------------
ALTER TABLE users    DROP CONSTRAINT IF EXISTS users_country_code_fkey;
ALTER TABLE users    DROP CONSTRAINT IF EXISTS users_country_fkey;

ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_user_id_fkey;
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_user_fkey;
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_device_type_id_fkey;
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_device_type_fkey;
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_browser_id_fkey;
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_browser_fkey;
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_country_code_fkey;
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_country_fkey;

ALTER TABLE events   DROP CONSTRAINT IF EXISTS events_session_id_fkey;
ALTER TABLE events   DROP CONSTRAINT IF EXISTS events_session_fkey;
ALTER TABLE events   DROP CONSTRAINT IF EXISTS events_event_type_id_fkey;
ALTER TABLE events   DROP CONSTRAINT IF EXISTS events_event_type_fkey;
ALTER TABLE events   DROP CONSTRAINT IF EXISTS events_page_id_fkey;
ALTER TABLE events   DROP CONSTRAINT IF EXISTS events_page_fkey;

-- ---------------------------------------------------------------------------
-- STEP 2 — drop the external_id UNIQUE on users (doesn't include user_id).
-- ---------------------------------------------------------------------------
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_external_id_key;

-- ---------------------------------------------------------------------------
-- STEP 3 — rewrite per-tenant PKs as composite (user_id, ...).
-- ---------------------------------------------------------------------------
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_pkey;
ALTER TABLE sessions ADD  PRIMARY KEY (user_id, session_id);

ALTER TABLE events   DROP CONSTRAINT IF EXISTS events_pkey;
ALTER TABLE events   ADD  PRIMARY KEY (user_id, event_id);

-- ---------------------------------------------------------------------------
-- STEP 4 — declare reference tables (idempotent).
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    PERFORM create_reference_table('analytics_events.event_types');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'event_types: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_reference_table('analytics_events.device_types');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'device_types: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_reference_table('analytics_events.browsers');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'browsers: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_reference_table('analytics_events.countries');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'countries: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_reference_table('analytics_events.pages');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pages: %', SQLERRM; END $$;

-- ---------------------------------------------------------------------------
-- STEP 5 — distribute the fact tables colocated on user_id.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    PERFORM create_distributed_table('analytics_events.users', 'user_id',
                                     shard_count => 32);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'users: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('analytics_events.sessions', 'user_id',
                                     colocate_with => 'analytics_events.users');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'sessions: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('analytics_events.events', 'user_id',
                                     colocate_with => 'analytics_events.users');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'events: %', SQLERRM; END $$;

-- ---------------------------------------------------------------------------
-- STEP 6 — re-add FKs.
--   * users.country_code → countries (reference)
--   * sessions.user_id → users.user_id (colocated, single-col on dist col)
--   * sessions.{device_type_id, browser_id, country_code} → reference tables
--   * events.(user_id, session_id) → sessions (composite; sessions PK is now
--     composite, events carries user_id denormalized so the FK is valid AND
--     colocated)
--   * events.{event_type_id, page_id} → reference tables
-- ---------------------------------------------------------------------------
ALTER TABLE users
    ADD CONSTRAINT users_country_fkey
    FOREIGN KEY (country_code) REFERENCES countries (country_code);

ALTER TABLE sessions
    ADD CONSTRAINT sessions_user_fkey
    FOREIGN KEY (user_id) REFERENCES users (user_id);

ALTER TABLE sessions
    ADD CONSTRAINT sessions_device_type_fkey
    FOREIGN KEY (device_type_id) REFERENCES device_types (device_type_id);

ALTER TABLE sessions
    ADD CONSTRAINT sessions_browser_fkey
    FOREIGN KEY (browser_id) REFERENCES browsers (browser_id);

ALTER TABLE sessions
    ADD CONSTRAINT sessions_country_fkey
    FOREIGN KEY (country_code) REFERENCES countries (country_code);

ALTER TABLE events
    ADD CONSTRAINT events_session_fkey
    FOREIGN KEY (user_id, session_id)
    REFERENCES sessions (user_id, session_id);

ALTER TABLE events
    ADD CONSTRAINT events_event_type_fkey
    FOREIGN KEY (event_type_id) REFERENCES event_types (event_type_id);

ALTER TABLE events
    ADD CONSTRAINT events_page_fkey
    FOREIGN KEY (page_id) REFERENCES pages (page_id);

-- ---------------------------------------------------------------------------
-- STEP 7 — refresh stats.
-- ---------------------------------------------------------------------------
ANALYZE users;
ANALYZE sessions;
ANALYZE events;
