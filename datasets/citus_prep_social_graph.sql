-- =============================================================================
-- citus_prep_social_graph.sql — Distribute social_graph (Strategy A)
-- =============================================================================
--
-- Strategy A (the recommended one from the schema's audit):
--
--   DISTRIBUTED on user_id            users          (PK already user_id)
--                                     likes          (PK already includes user_id)
--                                     notifications  (PK rewritten)
--   DISTRIBUTED on author_id          posts          (PK rewritten)
--                                                    colocated with users
--   DISTRIBUTED on follower_id        follows        (PK already includes
--                                                     follower_id)
--                                                    colocated with users
--   DISTRIBUTED on conversation_id    conversations
--                                     conversation_participants
--                                     messages       (PK rewritten)
--                                                    (own colocation group)
--
-- All of "user-centric" tables (users, posts, follows, likes, notifications)
-- live in the user_id colocation group, so JOINs that filter by user_id (or
-- follower_id, or author_id, etc.) route as single-shard.
--
-- Six inter-table FKs are PERMANENTLY DROPPED because they have no valid
-- composite rewrite under any single-column distribution:
--
--   follows.followee_id → users.user_id
--     -- opposite direction of the distribution; can't be colocated.
--   posts.parent_post_id → posts.post_id   (self-FK)
--     -- parent post's author is unknown at insert time, so the composite
--        target (author_of_parent, parent_post_id) is unknowable.
--   likes.post_id → posts.post_id
--     -- post's author is unknown at like-time + likes is distributed by
--        user_id while posts is distributed by author_id → cross-shard.
--   conversation_participants.user_id → users.user_id
--   messages.sender_id → users.user_id
--   notifications.actor_id → users.user_id
--     -- all three reference users from a non-user-centric table; integrity
--        must be enforced at the application layer.
--
-- These are exactly the cross-shard FKs the advisor should flag for this
-- schema. They are the cost of distributing a graph by a single key.
--
-- Idempotent. Usage:
--   psql -d <db> -f tmp/advisor_demo/social_graph.sql
--   psql -d <db> -f tmp/advisor_demo/citus_prep_social_graph.sql
-- =============================================================================

\set ON_ERROR_STOP on

SET search_path = social_graph, public;

-- ---------------------------------------------------------------------------
-- STEP 1 — drop every inter-table FK (kept and to-be-dropped alike).
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
-- STEP 3 — rewrite PKs that don't include the chosen distribution column.
--   users.pkey (user_id)                        -- IS dist col, keep
--   follows.pkey (follower_id, followee_id)     -- includes follower_id, keep
--   likes.pkey (user_id, post_id)               -- includes user_id, keep
--   conversations.pkey (conversation_id)        -- IS dist col, keep
--   conversation_participants.pkey
--       (conversation_id, user_id)              -- includes conv_id, keep
--   posts.pkey (post_id)                        -- REWRITE as (author_id, post_id)
--   messages.pkey (message_id)                  -- REWRITE as (conv_id, message_id)
--   notifications.pkey (notification_id)        -- REWRITE as (user_id, notif_id)
-- ---------------------------------------------------------------------------
ALTER TABLE posts         DROP CONSTRAINT IF EXISTS posts_pkey;
ALTER TABLE posts         ADD  PRIMARY KEY (author_id, post_id);

ALTER TABLE messages      DROP CONSTRAINT IF EXISTS messages_pkey;
ALTER TABLE messages      ADD  PRIMARY KEY (conversation_id, message_id);

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_pkey;
ALTER TABLE notifications ADD  PRIMARY KEY (user_id, notification_id);

-- ---------------------------------------------------------------------------
-- STEP 4 — no reference tables in this schema (all are distributed).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- STEP 5 — distribute. Two colocation groups:
--   GROUP A (user_id):  users, posts (author_id), follows (follower_id),
--                       likes (user_id), notifications (user_id)
--   GROUP B (conv_id):  conversations, conversation_participants, messages
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.users', 'user_id',
                                     shard_count => 32);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'users: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.posts', 'author_id',
                                     colocate_with => 'social_graph.users');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'posts: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.follows', 'follower_id',
                                     colocate_with => 'social_graph.users');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'follows: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.likes', 'user_id',
                                     colocate_with => 'social_graph.users');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'likes: %', SQLERRM; END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('social_graph.notifications', 'user_id',
                                     colocate_with => 'social_graph.users');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'notifications: %', SQLERRM; END $$;

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
-- STEP 6 — re-add the FKs that CAN survive distribution (8 of the original
-- 14). The other 6 are documented in the file header as permanent drops.
-- ---------------------------------------------------------------------------

-- follower side of follows colocates with users.user_id.
ALTER TABLE follows
    ADD CONSTRAINT follows_follower_fkey
    FOREIGN KEY (follower_id) REFERENCES users (user_id);

-- posts colocate with users (posts.author_id = users.user_id).
ALTER TABLE posts
    ADD CONSTRAINT posts_author_fkey
    FOREIGN KEY (author_id) REFERENCES users (user_id);

-- likes colocate with users on user_id.
ALTER TABLE likes
    ADD CONSTRAINT likes_user_fkey
    FOREIGN KEY (user_id) REFERENCES users (user_id);

-- notifications.user_id (recipient) colocates with users.
ALTER TABLE notifications
    ADD CONSTRAINT notifications_user_fkey
    FOREIGN KEY (user_id) REFERENCES users (user_id);

-- conv_participants ↔ conversations on conversation_id.
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
