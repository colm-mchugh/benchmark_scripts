-- =============================================================================
-- social_graph_mixed.sql  —  60% read / 40% write social-graph workload
-- =============================================================================
--
-- Same symmetric read mix as social_graph_read.sql (scaled to 60%), plus a
-- write mix specifically designed to expose distribution trade-offs:
--
--   15%  FOLLOW          INSERT INTO follows (:uid → :target)
--                        :target is Zipfian (α=4) so writes pile onto
--                        celebrities — DEMONSTRATES the followee_id hot shard.
--                        Under  follows.follower_id  : balanced, single shard.
--                        Under  follows.followee_id  : single shard, but the
--                        top-20 shards take ~5% of all follow writes.
--
--   12%  LIKE            INSERT INTO likes (:uid → :vpost)
--                        :vpost is Zipfian (α=3) so writes pile onto viral
--                        posts — DEMONSTRATES the post_id hot shard.
--                        Under  likes.user_id  : balanced.
--                        Under  likes.post_id  : viral posts saturate one shard.
--
--    6%  POST            INSERT INTO posts (:uid)
--                        Author-side write. Single shard under author_id.
--
--    4%  MARK READ       UPDATE notifications WHERE user_id = :uid (bulk)
--                        Single-shard under notifications.user_id.
--
--    2%  SEND DM         INSERT INTO messages (:conv, :uid)
--                        Single-shard under messages.conversation_id.
--                        Note: the FK messages.sender_id → users(user_id) is
--                        cross-shard under any reasonable distribution; Citus
--                        will require users to be a reference table OR the FK
--                        to be dropped. The advisor should flag this.
--
--    1%  UPDATE BIO      UPDATE users WHERE user_id = :uid.
--
-- Variable picks mirror the data generator's skew so the workload exercises
-- the SAME hot rows the data is concentrated on — this is what makes
-- hot-shard / data-skew issues observable in pgbench output.
--
-- Usage:
--   pgbench -n -f tmp/advisor_demo/workloads/social_graph_mixed.sql \
--           -T 60 -c 8 -j 4 -P 5 -M prepared <db>
-- =============================================================================

-- The timeline-build, who-I-follow, my-likes and post-likers branches are
-- intentional cross-key joins (the workload's whole point: expose what does
-- NOT colocate). Enable repartition joins so Citus executes them slowly
-- rather than aborting — the resulting tps drop is exactly the demo signal.
SET citus.enable_repartition_joins = on;

-- :target is Zipfian (α=4) so FOLLOW writes pile onto celebrities
\set uid     random_zipfian(1, 30000, 1.2)
\set celeb   random(1, 20)
\set vpost   random_zipfian(1, 80000, 3)
\set conv    random(1, 40000)
\set target  random_zipfian(1, 30000, 4)
\set rnd     random(1, 1000000000)
\set op      random(1, 100)

-- ============================== READS (60%) =================================

\if :op <= 9
  -- 9%   user profile
  SELECT user_id, handle, display_name, verified,
         followers_cnt, following_cnt, posts_cnt
    FROM social_graph.users
   WHERE user_id = :uid;

\elif :op <= 16
  -- 7%   who I follow
  SELECT f.followee_id, u.handle, u.verified, f.followed_at
    FROM social_graph.follows f
    JOIN social_graph.users   u ON u.user_id = f.followee_id
   WHERE f.follower_id = :uid
   ORDER BY f.followed_at DESC
   LIMIT 50;

\elif :op <= 23
  -- 7%   who follows me
  SELECT f.follower_id, u.handle, u.verified, f.followed_at
    FROM social_graph.follows f
    JOIN social_graph.users   u ON u.user_id = f.follower_id
   WHERE f.followee_id = :uid
   ORDER BY f.followed_at DESC
   LIMIT 50;

\elif :op <= 29
  -- 6%   my posts (last 90d)
  SELECT post_id, body, created_at, like_count
    FROM social_graph.posts
   WHERE author_id = :uid
     AND created_at > now() - interval '90 days'
   ORDER BY created_at DESC
   LIMIT 50;

\elif :op <= 34
  -- 5%   my likes (last 90d)
  SELECT l.post_id, l.liked_at, p.body, p.author_id
    FROM social_graph.likes l
    JOIN social_graph.posts p USING (post_id)
   WHERE l.user_id = :uid
     AND l.liked_at > now() - interval '90 days'
   ORDER BY l.liked_at DESC
   LIMIT 50;

\elif :op <= 39
  -- 5%   notifications inbox (last 30d)
  SELECT notification_id, actor_id, verb, target_type, target_id,
         created_at, read_at
    FROM social_graph.notifications
   WHERE user_id = :uid
     AND created_at > now() - interval '30 days'
   ORDER BY (read_at IS NULL) DESC, created_at DESC
   LIMIT 50;

\elif :op <= 44
  -- 5%   post detail + author
  SELECT p.post_id, p.body, p.like_count, p.reply_count,
         u.handle, u.verified
    FROM social_graph.posts p
    JOIN social_graph.users u ON u.user_id = p.author_id
   WHERE p.post_id = :vpost;

\elif :op <= 48
  -- 4%   post's recent likers
  SELECT l.user_id, u.handle, u.verified, l.liked_at
    FROM social_graph.likes l
    JOIN social_graph.users u USING (user_id)
   WHERE l.post_id = :vpost
   ORDER BY l.liked_at DESC
   LIMIT 30;

\elif :op <= 52
  -- 4%   conversations list + last message preview
  SELECT cp.conversation_id,
         c.last_message_at,
         (SELECT body FROM social_graph.messages m
           WHERE m.conversation_id = cp.conversation_id
           ORDER BY sent_at DESC
           LIMIT 1) AS last_body
    FROM social_graph.conversation_participants cp
    JOIN social_graph.conversations c USING (conversation_id)
   WHERE cp.user_id = :uid
   ORDER BY c.last_message_at DESC NULLS LAST
   LIMIT 20;

\elif :op <= 56
  -- 4%   celebrity follower fan-in (hot-shard probe under followee_id)
  SELECT count(*) AS followers
    FROM social_graph.follows
   WHERE followee_id = :celeb;

\elif :op <= 58
  -- 2%   timeline build (cross-key join, painful regardless)
  SELECT p.post_id, p.author_id, p.body, p.created_at, p.like_count
    FROM social_graph.follows f
    JOIN social_graph.posts   p ON p.author_id = f.followee_id
   WHERE f.follower_id = :uid
     AND p.created_at > now() - interval '30 days'
   ORDER BY p.created_at DESC
   LIMIT 50;

\elif :op <= 60
  -- 2%   global trending (fan-out baseline)
  SELECT post_id, author_id, like_count, created_at
    FROM social_graph.posts
   WHERE created_at > now() - interval '7 days'
   ORDER BY like_count DESC, post_id
   LIMIT 20;

-- ============================== WRITES (40%) ================================

\elif :op <= 75
  -- 15%  FOLLOW  — Zipfian target (celebrities dominate) demonstrates the
  --      followee_id hot-shard write path. Guarded against self-follow by
  --      the WHERE :uid <> :target clause (matches the CHECK constraint).
  --      ON CONFLICT for the dedup'd (follower_id, followee_id) PK.
  INSERT INTO social_graph.follows (follower_id, followee_id, followed_at)
  SELECT :uid, :target, now()
   WHERE :uid <> :target
      ON CONFLICT DO NOTHING;

\elif :op <= 87
  -- 12%  LIKE  — Zipfian post (viral posts dominate) demonstrates the
  --      post_id hot-shard write path.
  INSERT INTO social_graph.likes (user_id, post_id, liked_at)
  VALUES (:uid, :vpost, now())
      ON CONFLICT DO NOTHING;

\elif :op <= 93
  -- 6%   POST  — author-side single-shard write under posts.author_id.
  INSERT INTO social_graph.posts (author_id, body, created_at)
  VALUES (:uid, 'pgbench post ' || :rnd, now());

\elif :op <= 97
  -- 4%   MARK NOTIFICATIONS READ  — bulk single-shard UPDATE under
  --      notifications.user_id distribution.
  UPDATE social_graph.notifications
     SET read_at = now()
   WHERE user_id = :uid
     AND read_at IS NULL
     AND created_at > now() - interval '7 days';

\elif :op <= 99
  -- 2%   SEND DM  — single-shard INSERT under messages.conversation_id.
  --      Note: messages.sender_id FK → users.user_id is the cross-shard FK
  --      Citus will refuse unless users is a reference table.
  INSERT INTO social_graph.messages (conversation_id, sender_id, body, sent_at)
  VALUES (:conv, :uid, 'pgbench dm ' || :rnd, now());

\else
  -- 1%   UPDATE BIO  — single-shard write on users.user_id.
  UPDATE social_graph.users
     SET bio = 'updated bio ' || :rnd
   WHERE user_id = :uid;
\endif
