-- =============================================================================
-- citus_prep_social_graph_b.sql — Distribute social_graph (Strategy B)
-- =============================================================================
--
-- Strategy B is the flipped twin of citus_prep_social_graph.sql. Where
-- Strategy A picks the "owning side" of every symmetric pair, Strategy B
-- picks the "incoming / being-acted-on" side, swapping which queries get
-- single-shard router execution and which fan out.
--
--                       Strategy A                 Strategy B
--   follows             follower_id (outgoing)     followee_id (incoming)
--   posts               author_id   (my-posts)     post_id     (point lookup)
--   likes               user_id     (my-likes)     post_id     (post-likers)
--
-- This produces THREE colocation groups instead of Strategy A's two:
--
--   GROUP USERS    (hash domain = user_id):
--                  users, follows (followee_id), notifications (user_id)
--   GROUP POSTS    (hash domain = post_id):
--                  posts, likes (post_id)
--   GROUP CONV     (hash domain = conversation_id):
--                  conversations, conversation_participants, messages
--
-- Posts moves OUT of the user-anchored group: posts/likes joins to users
-- can no longer be colocated under any strategy that keeps posts and likes
-- joinable to each other. That's the price of letting "the post page"
-- (post-likers / post detail) be a single-shard router.
--
-- FK accounting (Strategy B enforces 5 of the original 12 inter-table FKs;
-- Strategy A enforces 6 — a DIFFERENT 6 mostly, with one in common):
--
--   ENFORCED (re-added at the end of this script):
--     follows.followee_id      -> users.user_id          (colocated, dist col)
--     likes.post_id            -> posts.post_id          (colocated, dist col;
--                                                          Strategy A dropped
--                                                          this one)
--     notifications.user_id    -> users.user_id          (colocated, dist col;
--                                                          same as Strategy A)
--     conv_participants.conv_id-> conversations.conv_id  (colocated, dist col;
--                                                          same as Strategy A)
--     messages.conv_id         -> conversations.conv_id  (colocated, dist col;
--                                                          same as Strategy A)
--
--   UNENFORCED (permanently dropped — Citus can't validate cross-shard):
--     follows.follower_id      -> users.user_id   ← Strategy A kept this
--     posts.author_id          -> users.user_id   ← Strategy A kept this
--     posts.parent_post_id     -> posts.post_id   (cross-shard self-FK: only
--                                                  the *referenced* column is
--                                                  the dist col; parent_post_id
--                                                  is just a payload integer
--                                                  and won't hash to the same
--                                                  shard as the child row.
--                                                  Same drop in Strategy A.)
--     likes.user_id            -> users.user_id   ← Strategy A kept this
--     conv_participants.user_id-> users.user_id   (same as Strategy A)
--     messages.sender_id       -> users.user_id   (same as Strategy A)
--     notifications.actor_id   -> users.user_id   (same as Strategy A)
--
-- Strategy B's gain over Strategy A:
--   * `likes.post_id -> posts.post_id` becomes enforceable. Under Strategy A
--     this was the painful drop (a like referencing a non-existent post).
-- Strategy B's losses:
--   * `posts.author_id -> users.user_id` is now app-level. Posts can refer
--     to deleted users without app discipline.
--   * Same for follows.follower_id and likes.user_id.
--
-- Net: Strategy A enforces 6 FKs; Strategy B enforces 5. The choice between
-- them isn't about FK count — it's about WHICH integrity rules matter most
-- in your application AND which read patterns dominate your workload.
--
-- Idempotent. Handles both a fresh-loaded schema and one already in
-- Strategy A state (DROP CONSTRAINT IF EXISTS guards on every constraint
-- name that has ever existed).
--
-- IMPORTANT: if the schema is currently distributed under Strategy A, run
-- this first to reset:
--   SELECT undistribute_table('social_graph.users',                     cascade_via_foreign_keys=>true);
--   SELECT undistribute_table('social_graph.conversations',             cascade_via_foreign_keys=>true);
--
-- Usage (from a freshly loaded schema):
--   psql -d <db> -f tmp/advisor_demo/social_graph.sql
--   psql -d <db> -f tmp/advisor_demo/citus_prep_social_graph_b.sql
-- =============================================================================

\set ON_ERROR_STOP on

SET search_path = social_graph, public;

-- ---------------------------------------------------------------------------
-- STEP 1 — drop every inter-table FK (both Postgres-default names and the
-- short names re-added by Strategy A's prep).
-- ---------------------------------------------------------------------------
ALTER TABLE follows                   DROP CONSTRAINT IF EXISTS follows_follower_id_fkey;
ALTER TABLE follows                   DROP CONSTRAINT IF EXISTS follows_follower_fkey;
ALTER TABLE follows                   DROP CONSTRAINT IF EXISTS follows_followee_id_fkey;
ALTER TABLE follows                   DROP CONSTRAINT IF EXISTS follows_followee_fkey;

ALTER TABLE posts                     DROP CONSTRAINT IF EXISTS posts_author_id_fkey;
ALTER TABLE posts                     DROP CONSTRAINT IF EXISTS posts_author_fkey;
ALTER TABLE posts                     DROP CONSTRAINT IF EXISTS posts_parent_post_id_fkey;
ALTER TABLE posts                     DROP CONSTRAINT IF EXISTS posts_parent_post_fkey;

ALTER TABLE likes                     DROP CONSTRAINT IF EXISTS likes_user_id_fkey;
ALTER TABLE likes                     DROP CONSTRAINT IF EXISTS likes_user_fkey;
ALTER TABLE likes                     DROP CONSTRAINT IF EXISTS likes_post_id_fkey;
ALTER TABLE likes                     DROP CONSTRAINT IF EXISTS likes_post_fkey;

ALTER TABLE conversation_participants DROP CONSTRAINT IF EXISTS conversation_participants_conversation_id_fkey;
ALTER TABLE conversation_participants DROP CONSTRAINT IF EXISTS cp_conversation_fkey;
ALTER TABLE conversation_participants DROP CONSTRAINT IF EXISTS conversation_participants_user_id_fkey;
ALTER TABLE conversation_participants DROP CONSTRAINT IF EXISTS cp_user_fkey;

ALTER TABLE messages                  DROP CONSTRAINT IF EXISTS messages_conversation_id_fkey;
ALTER TABLE messages                  DROP CONSTRAINT IF EXISTS messages_conversation_fkey;
ALTER TABLE messages                  DROP CONSTRAINT IF EXISTS messages_sender_id_fkey;
ALTER TABLE messages                  DROP CONSTRAINT IF EXISTS messages_sender_fkey;

ALTER TABLE notifications             DROP CONSTRAINT IF EXISTS notifications_user_id_fkey;
ALTER TABLE notifications             DROP CONSTRAINT IF EXISTS notifications_user_fkey;
ALTER TABLE notifications             DROP CONSTRAINT IF EXISTS notifications_actor_id_fkey;
ALTER TABLE notifications             DROP CONSTRAINT IF EXISTS notifications_actor_fkey;

-- ---------------------------------------------------------------------------
-- STEP 2 — drop the handle UNIQUE on users (doesn't include user_id).
-- ---------------------------------------------------------------------------
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_handle_key;

-- ---------------------------------------------------------------------------
-- STEP 3 — rewrite PKs for Strategy B.
--   users.pkey (user_id)                         -- IS dist col, keep
--   follows.pkey (follower_id, followee_id)      -- includes followee_id, keep
--   likes.pkey (user_id, post_id)                -- includes post_id, keep
--   conversations.pkey (conversation_id)         -- IS dist col, keep
--   conversation_participants.pkey
--       (conversation_id, user_id)               -- includes conv_id, keep
--   posts.pkey                                   -- REWRITE to (post_id) so
--                                                   it IS the dist col. If
--                                                   coming from Strategy A
--                                                   the current PK is
--                                                   (author_id, post_id);
--                                                   from a fresh load it's
--                                                   (post_id) already — the
--                                                   drop-and-readd is a
--                                                   no-op in that case but
--                                                   safe either way.
--   messages.pkey (message_id)                   -- REWRITE as
--                                                   (conv_id, message_id)
--   notifications.pkey (notification_id)         -- REWRITE as
--                                                   (user_id, notification_id)
-- ---------------------------------------------------------------------------
ALTER TABLE posts         DROP CONSTRAINT IF EXISTS posts_pkey;
ALTER TABLE posts         ADD  PRIMARY KEY (post_id);

ALTER TABLE messages      DROP CONSTRAINT IF EXISTS messages_pkey;
ALTER TABLE messages      ADD  PRIMARY KEY (conversation_id, message_id);

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_pkey;
ALTER TABLE notifications ADD  PRIMARY KEY (user_id, notification_id);

-- ---------------------------------------------------------------------------
-- STEP 4 — no reference tables in this schema.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- STEP 5 — distribute. Three colocation groups:
--   GROUP USERS:  users (user_id), follows (followee_id),
--                 notifications (user_id)
--   GROUP POSTS:  posts (post_id), likes (post_id)
--   GROUP CONV:   conversations, conversation_participants, messages
--                 (all on conversation_id)
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.users', 'user_id',
                                     shard_count => 32);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'users: %', SQLERRM; END $$;

-- follows colocates with users by hashing followee_id (same int hash domain
-- as user_id), so follows.followee_id -> users.user_id is enforceable.
DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.follows', 'followee_id',
                                     colocate_with => 'social_graph.users');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'follows: %', SQLERRM; END $$;

-- notifications stays user-anchored (no symmetric "actor-anchored" variant
-- in the workload — recipient is always the user).
DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.notifications', 'user_id',
                                     colocate_with => 'social_graph.users');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'notifications: %', SQLERRM; END $$;

-- posts opens a new colocation group keyed by post_id.
DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.posts', 'post_id',
                                     shard_count => 32);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'posts: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.likes', 'post_id',
                                     colocate_with => 'social_graph.posts');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'likes: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.conversations',
                                     'conversation_id', shard_count => 32);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'conversations: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.conversation_participants',
                                     'conversation_id',
                                     colocate_with => 'social_graph.conversations');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'conversation_participants: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.messages', 'conversation_id',
                                     colocate_with => 'social_graph.conversations');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'messages: %', SQLERRM; END $$;

-- ---------------------------------------------------------------------------
-- STEP 6 — re-add the 5 enforceable FKs.
-- ---------------------------------------------------------------------------

-- followee side colocates with users.user_id.
ALTER TABLE follows
    ADD CONSTRAINT follows_followee_fkey
    FOREIGN KEY (followee_id) REFERENCES users (user_id);

-- likes ↔ posts on post_id. THIS is the FK Strategy A had to drop; Strategy
-- B recovers it because both tables now share the post_id colocation group.
ALTER TABLE likes
    ADD CONSTRAINT likes_post_fkey
    FOREIGN KEY (post_id) REFERENCES posts (post_id);

-- notifications.user_id (recipient) colocates with users.
ALTER TABLE notifications
    ADD CONSTRAINT notifications_user_fkey
    FOREIGN KEY (user_id) REFERENCES users (user_id);

-- cp ↔ conversations on conversation_id.
ALTER TABLE conversation_participants
    ADD CONSTRAINT cp_conversation_fkey
    FOREIGN KEY (conversation_id) REFERENCES conversations (conversation_id);

-- messages ↔ conversations on conversation_id.
ALTER TABLE messages
    ADD CONSTRAINT messages_conversation_fkey
    FOREIGN KEY (conversation_id) REFERENCES conversations (conversation_id);

-- ---------------------------------------------------------------------------
-- STEP 7 — refresh stats.
-- ---------------------------------------------------------------------------
ANALYZE users;
ANALYZE follows;
ANALYZE posts;
ANALYZE likes;
ANALYZE notifications;
ANALYZE conversations;
ANALYZE conversation_participants;
ANALYZE messages;
