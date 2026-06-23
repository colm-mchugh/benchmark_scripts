-- =============================================================================
-- social_graph_read.sql  —  100% read social-graph workload (pgbench script)
-- =============================================================================
--
-- The social_graph dataset is the "hard" one: every key column has a winning
-- direction AND a losing direction depending on which way you distribute. This
-- workload deliberately exercises BOTH directions so the same script reveals
-- different bottlenecks under different distribution choices — the strategy-A
-- vs strategy-B comparison the advisor needs to make visible.
--
-- Symmetric pairs (each strategy is cheap for one, expensive for the other):
--
--   "who I follow"        vs  "who follows me"         (follows: follower_id
--                                                       vs followee_id)
--   "my likes"            vs  "post's recent likers"   (likes:   user_id
--                                                       vs post_id)
--   "my posts"            vs  "post detail by id"      (posts:   author_id
--                                                       vs post_id)
--
-- Skew probes (these stay slow under the "wrong" distribution AND go to a hot
-- shard under the "right" one — both failure modes show up):
--
--   "celebrity follower fan-in"   (followee_id distribution → hot shard for
--                                  the top-20 verified users)
--   "post's recent likers"        (post_id distribution → hot shard for viral
--                                  posts)
--
-- Cross-key joins (always painful, the "no strategy wins" baseline):
--
--   "timeline build"              (follows + posts via follower_id → author_id;
--                                  no colocation possible for both)
--   "global trending posts"       (full fan-out aggregate)
--
-- Variable picks:
--   :uid     Zipfian (s=1.2)  — mirrors the user-side data skew
--   :celeb   uniform 1..20    — always hits a verified celebrity
--   :vpost   Zipfian (s=3)    — mirrors the viral-post skew on likes
--   :conv    uniform 1..40000 — for conversation reads
--
-- Usage:
--   pgbench -n -f tmp/advisor_demo/workloads/social_graph_read.sql \
--           -T 60 -c 8 -j 4 -P 5 -M prepared <db>
--
-- Suggested comparison plan (the demo narrative):
--   1. Baseline on plain Postgres (or single-node Citus).
--   2. Distribute follows by follower_id, ANALYZE, re-run.
--      Expect: "who I follow" fast, "who follows me" + celebrity fan-in slow.
--   3. Undistribute. Distribute follows by followee_id, ANALYZE, re-run.
--      Expect: mirror — fan-in fast but hot-shards, "who I follow" slow.
--   4. Same A/B on likes: user_id vs post_id.
--   5. Compare tps + p95 across runs.
-- =============================================================================

-- The timeline-build, who-I-follow, my-likes and post-likers branches are
-- intentional cross-key joins (the workload's whole point: expose what does
-- NOT colocate). Enable repartition joins so Citus executes them slowly
-- rather than aborting — the resulting tps drop is exactly the demo signal.
SET citus.enable_repartition_joins = on;

\set uid    random_zipfian(1, 30000, 1.2)
\set celeb  random(1, 20)
\set vpost  random_zipfian(1, 80000, 3)
\set conv   random(1, 40000)
\set op     random(1, 100)

\if :op <= 15
  -- 15%  user profile lookup (single-shard under users.user_id, neutral)
  SELECT user_id, handle, display_name, bio, verified,
         followers_cnt, following_cnt, posts_cnt, created_at
    FROM social_graph.users
   WHERE user_id = :uid;

\elif :op <= 27
  -- 12%  WHO I FOLLOW  (outgoing edges)
  --      Favors  follows.follower_id  distribution → single-shard.
  --      Under   follows.followee_id  distribution → fan-out.
  SELECT f.followee_id, u.handle, u.verified, f.followed_at
    FROM social_graph.follows f
    JOIN social_graph.users   u ON u.user_id = f.followee_id
   WHERE f.follower_id = :uid
   ORDER BY f.followed_at DESC
   LIMIT 50;

\elif :op <= 39
  -- 12%  WHO FOLLOWS ME  (incoming edges)
  --      Favors  follows.followee_id  distribution → single-shard.
  --      Under   follows.follower_id  distribution → fan-out.
  SELECT f.follower_id, u.handle, u.verified, f.followed_at
    FROM social_graph.follows f
    JOIN social_graph.users   u ON u.user_id = f.follower_id
   WHERE f.followee_id = :uid
   ORDER BY f.followed_at DESC
   LIMIT 50;

\elif :op <= 49
  -- 10%  MY POSTS (last 90d)
  --      Favors  posts.author_id  distribution.
  SELECT post_id, body, created_at, like_count, reply_count
    FROM social_graph.posts
   WHERE author_id = :uid
     AND created_at > now() - interval '90 days'
   ORDER BY created_at DESC
   LIMIT 50;

\elif :op <= 57
  -- 8%   MY LIKES (last 90d)
  --      Favors  likes.user_id  distribution → single-shard scan.
  --      The JOIN to posts.post_id fans out unless posts is reference (too big)
  --      or colocated by post_id (which conflicts with author_id distribution).
  SELECT l.post_id, l.liked_at, p.body, p.author_id
    FROM social_graph.likes l
    JOIN social_graph.posts p USING (post_id)
   WHERE l.user_id = :uid
     AND l.liked_at > now() - interval '90 days'
   ORDER BY l.liked_at DESC
   LIMIT 50;

\elif :op <= 65
  -- 8%   NOTIFICATIONS INBOX (last 30d, unread first)
  --      Favors  notifications.user_id  distribution → single-shard.
  SELECT notification_id, actor_id, verb, target_type, target_id,
         created_at, read_at
    FROM social_graph.notifications
   WHERE user_id = :uid
     AND created_at > now() - interval '30 days'
   ORDER BY (read_at IS NULL) DESC, created_at DESC
   LIMIT 50;

\elif :op <= 73
  -- 8%   POST DETAIL + AUTHOR + LIKE COUNT
  --      Favors  posts.post_id  distribution (point lookup).
  --      Under   posts.author_id  → router needs author lookup first.
  SELECT p.post_id, p.body, p.created_at, p.like_count, p.reply_count,
         u.user_id, u.handle, u.verified
    FROM social_graph.posts p
    JOIN social_graph.users u ON u.user_id = p.author_id
   WHERE p.post_id = :vpost;

\elif :op <= 80
  -- 7%   POST'S RECENT LIKERS  (the M:N reverse direction)
  --      Favors  likes.post_id  distribution → single-shard, but for viral
  --      :vpost this becomes a hot-shard read.
  --      Under   likes.user_id  → full fan-out.
  SELECT l.user_id, u.handle, u.verified, l.liked_at
    FROM social_graph.likes l
    JOIN social_graph.users u USING (user_id)
   WHERE l.post_id = :vpost
   ORDER BY l.liked_at DESC
   LIMIT 30;

\elif :op <= 85
  -- 5%   CONVERSATIONS LIST + LAST MESSAGE PREVIEW
  --      User-centric entry point; the per-conv subquery is colocated only if
  --      messages is distributed by conversation_id AND conversation_participants
  --      is colocated with it (which competes with sharding cp by user_id for
  --      the WHERE filter). The advisor should surface this trade-off.
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

\elif :op <= 90
  -- 5%   CELEBRITY FOLLOWER FAN-IN  (count followers of a top-20 user)
  --      Under  follows.followee_id  → single shard, but it's a HOT shard
  --             (~5% of all follows land on celebrity ids 1..20).
  --      Under  follows.follower_id  → full fan-out + global aggregation.
  SELECT count(*) AS followers
    FROM social_graph.follows
   WHERE followee_id = :celeb;

\elif :op <= 95
  -- 5%   TIMELINE BUILD  (posts by people I follow, last 30d)
  --      The textbook cross-key join: filters on follows.follower_id but
  --      joins to posts on followee_id = author_id. No single distribution
  --      choice colocates both sides — this branch is the baseline that
  --      stays painful regardless of strategy.
  SELECT p.post_id, p.author_id, p.body, p.created_at, p.like_count
    FROM social_graph.follows f
    JOIN social_graph.posts   p ON p.author_id = f.followee_id
   WHERE f.follower_id = :uid
     AND p.created_at > now() - interval '30 days'
   ORDER BY p.created_at DESC
   LIMIT 50;

\else
  -- 5%   GLOBAL TRENDING POSTS (last 7d, by like_count)
  --      Always a fan-out aggregate; included as the "no distribution helps"
  --      baseline so the demo shows what's intrinsically expensive vs what
  --      the distribution choice actually moves.
  SELECT post_id, author_id, like_count, created_at
    FROM social_graph.posts
   WHERE created_at > now() - interval '7 days'
   ORDER BY like_count DESC, post_id
   LIMIT 20;
\endif
