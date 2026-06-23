-- =============================================================================
-- Social Graph  -  the HARD dataset for the "Distribute Table" advisor demo
-- =============================================================================
--
-- A miniature social-network / direct-messaging schema. Designed to be
-- *deliberately painful* to distribute, so the advisor has to either hedge,
-- recommend trade-offs, or flag the schema as graph-shaped.
--
-- Every classical Citus pitfall is represented:
--
--   1. SELF-REFERENCING EDGES with no winning side.
--      `follows(follower_id, followee_id)` and `messages(sender_id,...)`
--      both reference users. Whichever column you distribute on, the reverse
--      direction shuffles. The advisor will see *two* high-cardinality
--      bigint columns on the same table both pointing at users.user_id.
--
--   2. CELEBRITY SKEW.
--      followee_id is Zipfian (α=4). A handful of "verified" users have
--      thousands of followers each; most users have a handful. Distributing
--      `follows` by followee_id puts ~10% of the table on one shard.
--
--   3. M:N JUNCTION WITH COMPETING KEYS.
--      `likes(user_id, post_id)` is the textbook "you can colocate with users
--      OR with posts, but not both" problem. Both sides are high-cardinality
--      and both are read often.
--
--   4. POLYMORPHIC FK.
--      `notifications(target_type, target_id)` is a generic pointer that can
--      reference `posts`, `users`, or `messages` depending on `target_type`.
--      There IS no single foreign-key relationship, and `target_id` overlaps
--      the primary-key spaces of three unrelated tables. The advisor should
--      flag this explicitly.
--
--   5. SAME REFERENCED TABLE UNDER MANY NAMES.
--      users.user_id is referenced as follower_id, followee_id, author_id,
--      user_id (in likes), sender_id, recipient (user_id in notifications),
--      and actor_id. The naive "find columns whose name matches a PK column"
--      heuristic misses most of them.
--
--   6. HIERARCHICAL DATA.
--      `posts.parent_post_id` (reply threads) is a self-FK on posts; recursive
--      queries against it have no clean distribution.
--
--   7. SHARED ENTITY WITH UNEVEN OUTBOUND CARDINALITY.
--      Some users post a lot, some post nothing, some like a lot — three
--      independent power-laws over the *same* dimension. user_id is skewed
--      differently in every fact table.
--
-- Run with:
--     psql -d <db> -f social_graph.sql
--
-- Total runtime: ~60-90 s on a dev box. Idempotent (DROP SCHEMA IF EXISTS).
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

DROP SCHEMA IF EXISTS social_graph CASCADE;
CREATE SCHEMA social_graph;
SET search_path = social_graph;

SET default_statistics_target = 200;

-- -----------------------------------------------------------------------------
-- users  (the only "node" type in the graph)
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    user_id        bigserial PRIMARY KEY,
    handle         text UNIQUE NOT NULL,
    display_name   text,
    bio            text,
    created_at     timestamptz NOT NULL,
    verified       boolean NOT NULL DEFAULT false,   -- top-20 = "celebrities"
    followers_cnt  int NOT NULL DEFAULT 0,           -- denormalized later
    following_cnt  int NOT NULL DEFAULT 0,
    posts_cnt      int NOT NULL DEFAULT 0
);
CREATE INDEX users_verified_idx ON users(verified) WHERE verified;

-- -----------------------------------------------------------------------------
-- follows  (directed graph edges, the canonical "hard" table)
-- Two bigint columns both referencing users.user_id; the advisor must pick
-- one and accept that the other direction shuffles.
-- -----------------------------------------------------------------------------
CREATE TABLE follows (
    follower_id    bigint NOT NULL REFERENCES users(user_id),
    followee_id    bigint NOT NULL REFERENCES users(user_id),
    followed_at    timestamptz NOT NULL,
    PRIMARY KEY (follower_id, followee_id),
    CHECK (follower_id <> followee_id)
);
CREATE INDEX follows_followee_idx ON follows(followee_id);

-- -----------------------------------------------------------------------------
-- posts  (authored content; supports reply threads via parent_post_id)
-- -----------------------------------------------------------------------------
CREATE TABLE posts (
    post_id        bigserial PRIMARY KEY,
    author_id      bigint NOT NULL REFERENCES users(user_id),
    parent_post_id bigint REFERENCES posts(post_id),   -- self-FK = hierarchy
    body           text NOT NULL,
    created_at     timestamptz NOT NULL,
    like_count     int NOT NULL DEFAULT 0,
    reply_count    int NOT NULL DEFAULT 0
);
CREATE INDEX posts_author_idx  ON posts(author_id);
CREATE INDEX posts_parent_idx  ON posts(parent_post_id) WHERE parent_post_id IS NOT NULL;
CREATE INDEX posts_created_idx ON posts(created_at);

-- -----------------------------------------------------------------------------
-- likes  (M:N between users and posts; symmetric distribution dilemma)
-- -----------------------------------------------------------------------------
CREATE TABLE likes (
    user_id        bigint NOT NULL REFERENCES users(user_id),
    post_id        bigint NOT NULL REFERENCES posts(post_id),
    liked_at       timestamptz NOT NULL,
    PRIMARY KEY (user_id, post_id)
);
CREATE INDEX likes_post_idx ON likes(post_id);

-- -----------------------------------------------------------------------------
-- conversations / participants / messages  (group DMs)
-- -----------------------------------------------------------------------------
CREATE TABLE conversations (
    conversation_id  bigserial PRIMARY KEY,
    created_at       timestamptz NOT NULL,
    last_message_at  timestamptz
);

CREATE TABLE conversation_participants (
    conversation_id  bigint NOT NULL REFERENCES conversations(conversation_id),
    user_id          bigint NOT NULL REFERENCES users(user_id),
    joined_at        timestamptz NOT NULL,
    PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX cp_user_idx ON conversation_participants(user_id);

CREATE TABLE messages (
    message_id       bigserial PRIMARY KEY,
    conversation_id  bigint NOT NULL REFERENCES conversations(conversation_id),
    sender_id        bigint NOT NULL REFERENCES users(user_id),
    body             text NOT NULL,
    sent_at          timestamptz NOT NULL
);
CREATE INDEX messages_conv_idx   ON messages(conversation_id);
CREATE INDEX messages_sender_idx ON messages(sender_id);

-- -----------------------------------------------------------------------------
-- notifications  (the polymorphic-FK table)
--   target_type tells you which table target_id "would" reference; the same
--   integer value can point at a user, a post or a message depending on row.
--   There is no FK to enforce this, and the advisor cannot infer it.
-- -----------------------------------------------------------------------------
CREATE TABLE notifications (
    notification_id  bigserial PRIMARY KEY,
    user_id          bigint NOT NULL REFERENCES users(user_id),  -- recipient
    actor_id         bigint NOT NULL REFERENCES users(user_id),  -- who triggered
    verb             text   NOT NULL,        -- followed/liked/replied/mentioned
    target_type      text   NOT NULL,        -- 'user' | 'post' | 'message'
    target_id        bigint NOT NULL,        -- POLYMORPHIC: no FK!
    created_at       timestamptz NOT NULL,
    read_at          timestamptz
);
CREATE INDEX notif_user_idx    ON notifications(user_id);
CREATE INDEX notif_target_idx  ON notifications(target_type, target_id);
CREATE INDEX notif_actor_idx   ON notifications(actor_id);

-- =============================================================================
-- DATA GENERATION
-- =============================================================================
--
-- Sizing:
--     users                       30,000
--     follows                  ~300,000  (Zipfian α=4 over followee_id)
--     posts                       80,000  (Zipfian α=3 over author_id)
--     likes                    ~400,000  (Zipfian on both user_id and post_id)
--     conversations               40,000
--     conversation_participants  ~80,000  (mostly DMs, 2-4 participants)
--     messages                 ~240,000  (Zipfian per-conversation event count)
--     notifications              400,000  (polymorphic targets)
--
-- =============================================================================

SELECT setseed(0.42);

-- ---- users ----------------------------------------------------------------
INSERT INTO users (handle, display_name, bio, created_at, verified)
SELECT
    'user_' || g,
    'User ' || g,
    CASE WHEN random() < 0.3 THEN 'I post about thing #' || (1 + (random()*49)::int) END,
    now() - (random() * interval '1500 days'),
    (g <= 20)    -- first 20 users are "celebrities"
FROM generate_series(1, 30000) g;

-- ---- follows --------------------------------------------------------------
-- follower_id is uniform (everyone follows ~10 people). followee_id is
-- Zipfian (celebrities dominate). Overshoot 400k → ~300k after dedup +
-- self-follow removal.
WITH raw AS (
    SELECT 1 + (random() * 29999)::bigint                  AS follower,
           1 + floor(30000 * power(random(), 4))::bigint   AS followee,
           now() - (random() * interval '730 days')        AS t
    FROM generate_series(1, 400000)
)
INSERT INTO follows (follower_id, followee_id, followed_at)
SELECT follower, followee, t
FROM raw
WHERE follower <> followee
ON CONFLICT DO NOTHING;

-- ---- posts ----------------------------------------------------------------
-- author_id is Zipfian (a few power-posters write most posts).
INSERT INTO posts (author_id, parent_post_id, body, created_at)
SELECT
    1 + floor(30000 * power(random(), 3))::bigint,
    NULL,                       -- replies wired up in a second pass below
    'Post body ' || g || ' — ' || md5(g::text),
    now() - (random() * interval '365 days')
FROM generate_series(1, 80000) g;

-- Turn ~20% of posts into replies to a (probably popular) earlier post.
UPDATE posts
SET parent_post_id = 1 + floor(post_id * power(random(), 2))::bigint
WHERE random() < 0.20
  AND post_id > 100;   -- the first 100 posts stay as roots

-- ---- likes ----------------------------------------------------------------
-- Each like: user_id Zipfian (active likers), post_id Zipfian (viral posts).
-- Overshoot 500k → ~400k after dedup.
WITH raw AS (
    SELECT 1 + floor(30000 * power(random(), 2))::bigint AS uid,
           1 + floor(80000 * power(random(), 3))::bigint AS pid,
           now() - (random() * interval '365 days')      AS t
    FROM generate_series(1, 500000)
)
INSERT INTO likes (user_id, post_id, liked_at)
SELECT uid, pid, t
FROM raw
ON CONFLICT DO NOTHING;

-- ---- conversations + participants ----------------------------------------
INSERT INTO conversations (created_at, last_message_at)
SELECT now() - (random() * interval '365 days'),
       now() - (random() * interval '7 days')
FROM generate_series(1, 40000);

-- 2-4 participants per conversation; materialize the count first so
-- generate_series varies per row.
WITH conv_sizes AS (
    SELECT conversation_id,
           created_at,
           2 + floor(power(random(), 3) * 3)::int AS n_participants
    FROM conversations
)
INSERT INTO conversation_participants (conversation_id, user_id, joined_at)
SELECT cs.conversation_id,
       1 + (random() * 29999)::bigint,
       cs.created_at
FROM conv_sizes cs
CROSS JOIN LATERAL generate_series(1, cs.n_participants) AS s
ON CONFLICT DO NOTHING;

-- ---- messages -------------------------------------------------------------
-- Per conversation: pick a Zipfian message count, then pick a sender from
-- that conversation's participants (via array_agg).
WITH participants AS (
    SELECT conversation_id, array_agg(user_id) AS uids
    FROM conversation_participants
    GROUP BY conversation_id
),
conv_msgs AS (
    SELECT p.conversation_id,
           p.uids,
           greatest(1, floor(15 * power(random(), 3))::int) AS n_msgs
    FROM participants p
)
INSERT INTO messages (conversation_id, sender_id, body, sent_at)
SELECT cm.conversation_id,
       cm.uids[1 + (random() * (array_length(cm.uids, 1) - 1))::int],
       'msg ' || s || ' in conv ' || cm.conversation_id,
       now() - (random() * interval '180 days')
FROM conv_msgs cm
CROSS JOIN LATERAL generate_series(1, cm.n_msgs) AS s;

-- ---- notifications --------------------------------------------------------
-- Recipient is Zipfian (active users get lots of notifications). target_type
-- and target_id are polymorphic.
WITH raw AS (
    SELECT 1 + floor(30000 * power(random(), 2))::bigint  AS recipient,
           1 + (random() * 29999)::bigint                  AS actor,
           (ARRAY['followed','liked','replied','mentioned'])
               [1 + (random() * 3)::int]                   AS verb,
           random()                                        AS r_read,
           now() - (random() * interval '60 days')         AS t
    FROM generate_series(1, 400000)
)
INSERT INTO notifications
    (user_id, actor_id, verb, target_type, target_id, created_at, read_at)
SELECT recipient,
       actor,
       verb,
       CASE verb WHEN 'followed' THEN 'user' ELSE 'post' END,
       CASE verb
           WHEN 'followed' THEN 1 + (random() * 29999)::bigint   -- user_id space
           ELSE                 1 + (random() * 79999)::bigint   -- post_id space
       END,
       t,
       CASE WHEN r_read < 0.6 THEN t + interval '1 hour' END
FROM raw;

-- =============================================================================
-- Denormalized counters on users (so demos can see the "celebrity" pattern).
-- =============================================================================

WITH fc AS (
    SELECT followee_id AS uid, count(*) AS n
    FROM follows GROUP BY followee_id
)
UPDATE users u SET followers_cnt = fc.n FROM fc WHERE fc.uid = u.user_id;

WITH foc AS (
    SELECT follower_id AS uid, count(*) AS n
    FROM follows GROUP BY follower_id
)
UPDATE users u SET following_cnt = foc.n FROM foc WHERE foc.uid = u.user_id;

WITH pc AS (
    SELECT author_id AS uid, count(*) AS n
    FROM posts GROUP BY author_id
)
UPDATE users u SET posts_cnt = pc.n FROM pc WHERE pc.uid = u.user_id;

-- =============================================================================
-- Stats refresh
-- =============================================================================

ANALYZE social_graph.users;
ANALYZE social_graph.follows;
ANALYZE social_graph.posts;
ANALYZE social_graph.likes;
ANALYZE social_graph.conversations;
ANALYZE social_graph.conversation_participants;
ANALYZE social_graph.messages;
ANALYZE social_graph.notifications;

-- =============================================================================
-- Sanity / demo queries (uncomment to confirm the painful shape)
-- =============================================================================
--
-- -- Row counts:
-- SELECT relname, reltuples::bigint
-- FROM pg_class
-- WHERE relnamespace='social_graph'::regnamespace AND relkind='r'
-- ORDER BY reltuples DESC;
--
-- -- The celebrity skew:
-- SELECT u.user_id, u.verified, u.followers_cnt
-- FROM social_graph.users u
-- ORDER BY u.followers_cnt DESC LIMIT 10;
--
-- -- The same dimension (user_id) under many names — the advisor must
-- -- recognize all of these as references to users.user_id:
-- SELECT table_name, column_name
-- FROM information_schema.columns
-- WHERE table_schema = 'social_graph'
--   AND column_name IN ('user_id','follower_id','followee_id','author_id',
--                       'sender_id','actor_id','recipient')
-- ORDER BY table_name, column_name;
--
-- -- The two-key dilemma: both columns on `follows` are equally "valid":
-- SELECT attname, n_distinct,
--        round(most_common_freqs[1]::numeric, 4) AS top_value_freq
-- FROM pg_stats
-- WHERE schemaname='social_graph' AND tablename='follows'
--   AND attname IN ('follower_id','followee_id');
--
-- -- The polymorphic FK has no real referenced table:
-- SELECT target_type, count(*), min(target_id), max(target_id)
-- FROM social_graph.notifications
-- GROUP BY target_type;
