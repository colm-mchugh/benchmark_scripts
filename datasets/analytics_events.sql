-- =============================================================================
-- Analytics Events  -  sample dataset for the "Distribute Table" advisor demo
-- =============================================================================
--
-- A product-analytics / event-tracking workload (think: a tiny Mixpanel or
-- Amplitude). One huge fact table (events), one medium fact (sessions), a
-- mid-sized user dimension, plus a handful of obvious reference tables.
--
-- Data is heavily non-uniform:
--
--   * sessions per user      — Zipfian (α=3): a few power users own most
--                              sessions; a long tail visits once.
--   * events per session     — Zipfian: most sessions have 1-2 events,
--                              a few have 30-60.
--   * events per event_type  — Zipfian (α=2.5) ordered so event_type_id=1
--                              (page_view) is ~17% of all events, click ~5%,
--                              etc., trailing off into 25 rare 'custom_*'
--                              event types.
--   * events per page        — Zipfian (α=2.5) ordered so page_id=1 (homepage)
--                              gets ~8% of page hits.
--
-- What the advisor should see when it inspects this schema:
--
--   * user_id appears in 3 tables (users, sessions, events) with high
--     cardinality (~50k distinct values) and moderate, realistic skew
--     -> the natural distribution column. sessions and events should colocate
--     on user_id (events carries user_id denormalized for exactly that).
--   * session_id appears in 2 tables (sessions, events), also high cardinality
--     -> secondary candidate, but loses on the "matching join keys" signal.
--   * event_type_id, device_type_id, browser_id, country_code: very low
--     cardinality + very high skew  ->  the advisor should *reject* these,
--     and the referenced tables (event_types, device_types, browsers,
--     countries) are obvious reference-table candidates.
--   * pages (~500 rows) is a small dimension and another reference candidate.
--
-- Run with:
--     psql -d <db> -f analytics_events.sql
--
-- Total runtime: ~60-90 s on a dev box. All objects live in schema
-- analytics_events; the script is idempotent (DROP SCHEMA IF EXISTS).
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

DROP SCHEMA IF EXISTS analytics_events CASCADE;
CREATE SCHEMA analytics_events;
SET search_path = analytics_events;

SET default_statistics_target = 200;

-- -----------------------------------------------------------------------------
-- Reference tables  (small, obvious "distribute as reference" candidates)
-- -----------------------------------------------------------------------------

CREATE TABLE event_types (
    event_type_id   smallserial PRIMARY KEY,
    name            text UNIQUE NOT NULL,
    category        text NOT NULL,           -- page / interaction / commerce / ...
    is_conversion   boolean NOT NULL DEFAULT false
);

CREATE TABLE device_types (
    device_type_id  smallserial PRIMARY KEY,
    name            text UNIQUE NOT NULL
);

CREATE TABLE browsers (
    browser_id      smallserial PRIMARY KEY,
    name            text UNIQUE NOT NULL,
    engine          text NOT NULL
);

CREATE TABLE countries (
    country_code    char(2) PRIMARY KEY,
    name            text NOT NULL,
    region          text NOT NULL            -- NA / EU / APAC / LATAM / MEA
);

CREATE TABLE pages (
    page_id         serial PRIMARY KEY,
    url_path        text UNIQUE NOT NULL,
    title           text,
    section         text NOT NULL            -- home / blog / product / docs / checkout
);
CREATE INDEX pages_section_idx ON pages(section);

-- -----------------------------------------------------------------------------
-- Dimension: users  (mid-sized)
-- -----------------------------------------------------------------------------

CREATE TABLE users (
    user_id         bigserial PRIMARY KEY,
    external_id     text UNIQUE NOT NULL,    -- SDK-assigned anon id
    email           text,                    -- null for anonymous visitors
    plan            text NOT NULL,           -- free / pro / enterprise
    country_code    char(2) NOT NULL REFERENCES countries(country_code),
    signed_up_at    timestamptz NOT NULL
);
CREATE INDEX users_plan_idx     ON users(plan);
CREATE INDEX users_country_idx  ON users(country_code);

-- -----------------------------------------------------------------------------
-- Fact: sessions  (medium, power-law over users)
-- -----------------------------------------------------------------------------

CREATE TABLE sessions (
    session_id      bigserial PRIMARY KEY,
    user_id         bigint NOT NULL REFERENCES users(user_id),
    started_at      timestamptz NOT NULL,
    ended_at        timestamptz,
    device_type_id  smallint NOT NULL REFERENCES device_types(device_type_id),
    browser_id      smallint NOT NULL REFERENCES browsers(browser_id),
    country_code    char(2)  NOT NULL REFERENCES countries(country_code),
    event_count     int NOT NULL DEFAULT 0   -- filled in after events insert
);
CREATE INDEX sessions_user_idx        ON sessions(user_id);
CREATE INDEX sessions_started_at_idx  ON sessions(started_at);
CREATE INDEX sessions_country_idx     ON sessions(country_code);

-- -----------------------------------------------------------------------------
-- Big fact: events  (~1M rows; user_id is denormalized for colocation)
-- -----------------------------------------------------------------------------

CREATE TABLE events (
    event_id        bigserial PRIMARY KEY,
    user_id         bigint   NOT NULL,                       -- denormalized
    session_id      bigint   NOT NULL REFERENCES sessions(session_id),
    event_type_id   smallint NOT NULL REFERENCES event_types(event_type_id),
    page_id         int      REFERENCES pages(page_id),
    occurred_at     timestamptz NOT NULL,
    duration_ms     int,
    properties      jsonb
);
CREATE INDEX events_user_idx        ON events(user_id);
CREATE INDEX events_session_idx     ON events(session_id);
CREATE INDEX events_event_type_idx  ON events(event_type_id);
CREATE INDEX events_occurred_at_idx ON events(occurred_at);

-- =============================================================================
-- DATA GENERATION
-- =============================================================================
--
-- Sizing:
--     event_types               50      (1 page, 6 interaction, 4 media,
--                                        5 commerce, 4 auth, 3 error,
--                                        2 experiment, 25 'custom_*')
--     device_types              10
--     browsers                  20
--     countries                 30
--     pages                    500
--     users                 50,000
--     sessions             200,000      (power-law over user_id, α=3)
--     events            ~1,200,000      (power-law over event_type, page,
--                                        and events-per-session)
--
-- =============================================================================

SELECT setseed(0.42);

-- ---- event_types (ordered so id=1 is the most common = page_view) ----------
INSERT INTO event_types (name, category, is_conversion) VALUES
    ('page_view',          'page',        false),
    ('click',              'interaction', false),
    ('scroll',             'interaction', false),
    ('form_focus',         'interaction', false),
    ('search',             'interaction', false),
    ('tab_visible',        'interaction', false),
    ('tab_hidden',         'interaction', false),
    ('video_play',         'media',       false),
    ('video_pause',        'media',       false),
    ('audio_play',         'media',       false),
    ('share',              'media',       false),
    ('add_to_cart',        'commerce',    false),
    ('remove_from_cart',   'commerce',    false),
    ('checkout_start',     'commerce',    false),
    ('checkout_complete',  'commerce',    true),
    ('refund_requested',   'commerce',    false),
    ('login',              'auth',        false),
    ('logout',             'auth',        false),
    ('signup',             'auth',        true),
    ('password_reset',     'auth',        false),
    ('js_error',           'error',       false),
    ('network_error',      'error',       false),
    ('api_timeout',        'error',       false),
    ('ab_test_view',       'experiment',  false),
    ('feature_flag_eval',  'experiment',  false);

-- Plus 25 long-tail 'custom_*' types (50 total).
INSERT INTO event_types (name, category, is_conversion)
SELECT 'custom_event_' || g, 'custom', false
FROM generate_series(1, 25) g;

-- ---- device_types ----------------------------------------------------------
INSERT INTO device_types (name) VALUES
    ('desktop'), ('mobile_phone'), ('tablet'), ('smart_tv'), ('console'),
    ('e_reader'), ('watch'), ('bot'), ('unknown'), ('other');

-- ---- browsers --------------------------------------------------------------
INSERT INTO browsers (name, engine) VALUES
    ('Chrome',           'Blink'),
    ('Safari',           'WebKit'),
    ('Firefox',          'Gecko'),
    ('Edge',             'Blink'),
    ('Opera',            'Blink'),
    ('Chrome Mobile',    'Blink'),
    ('Safari Mobile',    'WebKit'),
    ('Samsung Internet', 'Blink'),
    ('Brave',            'Blink'),
    ('Vivaldi',          'Blink'),
    ('DuckDuckGo',       'WebKit'),
    ('Tor Browser',      'Gecko'),
    ('Yandex Browser',   'Blink'),
    ('UC Browser',       'Blink'),
    ('IE 11',            'Trident'),
    ('Edge Legacy',      'EdgeHTML'),
    ('Firefox Mobile',   'Gecko'),
    ('Opera Mini',       'Presto'),
    ('Arc',              'Blink'),
    ('Other',            'Unknown');

-- ---- countries -------------------------------------------------------------
INSERT INTO countries (country_code, name, region) VALUES
    ('US','United States','NA'),     ('CA','Canada','NA'),
    ('MX','Mexico','NA'),            ('GB','United Kingdom','EU'),
    ('DE','Germany','EU'),           ('FR','France','EU'),
    ('NL','Netherlands','EU'),       ('IT','Italy','EU'),
    ('ES','Spain','EU'),             ('SE','Sweden','EU'),
    ('PL','Poland','EU'),            ('IE','Ireland','EU'),
    ('CH','Switzerland','EU'),       ('TR','Turkey','EU'),
    ('JP','Japan','APAC'),           ('CN','China','APAC'),
    ('IN','India','APAC'),           ('AU','Australia','APAC'),
    ('NZ','New Zealand','APAC'),     ('SG','Singapore','APAC'),
    ('KR','South Korea','APAC'),     ('ID','Indonesia','APAC'),
    ('BR','Brazil','LATAM'),         ('AR','Argentina','LATAM'),
    ('CL','Chile','LATAM'),          ('CO','Colombia','LATAM'),
    ('ZA','South Africa','MEA'),     ('EG','Egypt','MEA'),
    ('AE','United Arab Emirates','MEA'),
    ('NG','Nigeria','MEA');

-- ---- pages (500 URLs across 5 sections) ------------------------------------
-- page_id=1 is the homepage so the Zipfian over pages makes it the hottest.
INSERT INTO pages (url_path, title, section) VALUES
    ('/', 'Home', 'home');

INSERT INTO pages (url_path, title, section)
SELECT
    CASE (g % 5)
        WHEN 0 THEN '/blog/post-'    || g
        WHEN 1 THEN '/product/'      || g
        WHEN 2 THEN '/docs/page-'    || g
        WHEN 3 THEN '/checkout/step-'|| g
        ELSE        '/help/article-' || g
    END,
    'Page ' || g,
    (ARRAY['blog','product','docs','checkout','help'])[1 + (g % 5)]
FROM generate_series(2, 500) g;

-- ---- users (50,000) --------------------------------------------------------
-- Pick a random country per row by indexing into an aggregated array; this is
-- the simplest way to avoid the planner folding the subquery when it doesn't
-- correlate with the outer row.
WITH cc AS (
    SELECT array_agg(country_code ORDER BY country_code) AS codes,
           count(*)::int AS n
    FROM countries
)
INSERT INTO users (external_id, email, plan, country_code, signed_up_at)
SELECT
    'anon_' || md5(g::text),
    CASE WHEN random() < 0.55 THEN 'user' || g || '@example.com' END,
    CASE WHEN random() < 0.80 THEN 'free'
         WHEN random() < 0.75 THEN 'pro'
         ELSE 'enterprise' END,
    cc.codes[1 + (random() * (cc.n - 1))::int],
    now() - (random() * interval '730 days')
FROM generate_series(1, 50000) g, cc;

-- ---- sessions (power-law over user_id) -------------------------------------
-- Sessions inherit country from the owning user so the join stays consistent.
WITH raw AS (
    SELECT 1 + floor(50000 * power(random(), 3))::bigint AS uid,
           now() - (random() * interval '90 days')        AS started,
           1 + (random() * 9)::smallint                   AS dt,
           1 + (random() * 19)::smallint                  AS br
    FROM generate_series(1, 200000)
)
INSERT INTO sessions (user_id, started_at, ended_at,
                      device_type_id, browser_id, country_code)
SELECT r.uid,
       r.started,
       r.started + (10 + (random() * 1790)::int) * interval '1 second',
       r.dt,
       r.br,
       u.country_code
FROM raw r
JOIN users u ON u.user_id = r.uid;

-- ---- events (~1.2M; power-law over event_type, page, and per-session) ------
-- n_events per session is materialized first so generate_series can vary the
-- count per row (volatile arguments to generate_series otherwise get folded).
WITH ss AS (
    SELECT session_id,
           user_id,
           started_at,
           greatest(1, floor(20 * power(random(), 3))::int) AS n_events
    FROM sessions
)
INSERT INTO events (user_id, session_id, event_type_id, page_id,
                    occurred_at, duration_ms, properties)
SELECT
    ss.user_id,
    ss.session_id,
    -- Zipfian over event_type_id with α=2.5  -> page_view (id=1) ~17%, click ~5%
    (1 + floor(50  * power(random(), 2.5))::int)::smallint,
    -- Zipfian over page_id with α=2.5         -> homepage (id=1) dominates
    1 + floor(500 * power(random(), 2.5))::int,
    ss.started_at + (i * interval '15 seconds') + (random() * interval '5 seconds'),
    50 + (random() * 9950)::int,
    CASE WHEN random() < 0.10
         THEN jsonb_build_object('val', (random() * 100)::int)
         ELSE NULL END
FROM ss
CROSS JOIN LATERAL generate_series(1, ss.n_events) AS i;

-- ---- Fix-ups --------------------------------------------------------------
UPDATE sessions s
SET event_count = sub.n,
    ended_at    = sub.last_evt
FROM (
    SELECT session_id,
           count(*)        AS n,
           max(occurred_at) AS last_evt
    FROM events
    GROUP BY session_id
) sub
WHERE sub.session_id = s.session_id;

-- =============================================================================
-- Stats refresh so the advisor sees up-to-date pg_class / pg_stats data.
-- =============================================================================

ANALYZE analytics_events.event_types;
ANALYZE analytics_events.device_types;
ANALYZE analytics_events.browsers;
ANALYZE analytics_events.countries;
ANALYZE analytics_events.pages;
ANALYZE analytics_events.users;
ANALYZE analytics_events.sessions;
ANALYZE analytics_events.events;

-- =============================================================================
-- Sanity / demo queries  (run by hand to confirm the power-law is visible)
-- =============================================================================
--
-- -- Row counts:
-- SELECT relname, reltuples::bigint
-- FROM pg_class
-- WHERE relnamespace = 'analytics_events'::regnamespace AND relkind = 'r'
-- ORDER BY reltuples DESC;
--
-- -- Top event_types: page_view should dominate, custom_event_* should be rare.
-- SELECT et.name, count(*)
-- FROM analytics_events.events e
-- JOIN analytics_events.event_types et USING (event_type_id)
-- GROUP BY et.name ORDER BY 2 DESC LIMIT 10;
--
-- -- Top users by event volume (power-law shape):
-- SELECT user_id, count(*) AS events
-- FROM analytics_events.events
-- GROUP BY user_id ORDER BY 2 DESC LIMIT 10;
--
-- -- Long-tail check on sessions per user:
-- WITH s AS (
--     SELECT u.user_id, count(se.*) AS sessions
--     FROM analytics_events.users u
--     LEFT JOIN analytics_events.sessions se ON se.user_id = u.user_id
--     GROUP BY u.user_id
-- )
-- SELECT count(*) FILTER (WHERE sessions = 0)        AS never_visited,
--        count(*) FILTER (WHERE sessions BETWEEN 1 AND 2) AS small_tail,
--        count(*) FILTER (WHERE sessions > 100)      AS power_users,
--        max(sessions)                               AS top_user_sessions
-- FROM s;
--
-- -- What the advisor should see in pg_stats for user_id:
-- SELECT tablename, attname, n_distinct,
--        round(most_common_freqs[1]::numeric, 4) AS top_value_freq
-- FROM pg_stats
-- WHERE schemaname='analytics_events' AND attname='user_id'
-- ORDER BY tablename;
--
-- -- ... and for the skewed enum-like columns it should reject:
-- SELECT tablename, attname, n_distinct,
--        round(most_common_freqs[1]::numeric, 4) AS top_value_freq
-- FROM pg_stats
-- WHERE schemaname='analytics_events'
--   AND attname IN ('event_type_id','device_type_id','browser_id','country_code')
-- ORDER BY tablename, attname;
