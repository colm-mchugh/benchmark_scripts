-- =============================================================================
-- oltp_shop_read.sql  —  100% read OLTP workload (pgbench script)
-- =============================================================================
--
-- Mirrors a typical e-commerce read path: lots of single-row lookups and
-- short customer-scoped index scans, sprinkled with the kind of multi-table
-- joins a product page or order-history view would issue.
--
-- ALL queries except the small "product lookup" branch are tenant-scoped
-- (filter by customer_id). With Citus distributing oltp_shop by customer_id,
-- every such query is a single-shard router query; without that distribution
-- (or with a wrong distribution column) the same queries fan out.
--
-- The customer pick is Zipfian (s=1.2) so the request distribution roughly
-- mirrors the data distribution: whales are accessed more often than the
-- long tail. That makes hot-shard / data-skew issues observable.
--
-- Usage:
--   pgbench -n -f tmp/advisor_demo/workloads/oltp_shop_read.sql \
--           -T 60 -c 8 -j 4 -P 5 -M prepared <db>
--
-- Suggested comparison plan:
--   1. Run on plain Postgres (or on Citus with single-node setup) → baseline.
--   2. Distribute by customer_id, ANALYZE, re-run.
--   3. Undistribute, distribute by order_id (the "bad" key), re-run.
--   4. Compare tps / p95 between the three runs.
-- =============================================================================

\set cid  random_zipfian(1, 20000, 1.2)
\set pid  random(1, 500)
\set op   random(1, 100)

\if :op <= 30
  -- 30%  point lookup by customer PK
  SELECT customer_id, email, full_name, country_code, status, signup_at
    FROM oltp_shop.customers
   WHERE customer_id = :cid;

\elif :op <= 60
  -- 30%  recent orders for a customer (colocated index scan)
  SELECT order_id, placed_at, status, total_cents, currency
    FROM oltp_shop.orders
   WHERE customer_id = :cid
   ORDER BY placed_at DESC
   LIMIT 10;

\elif :op <= 75
  -- 15%  order details + line items + product info (3-way join).
  --      JOIN to order_items is on (customer_id, order_id) so Citus can see
  --      it's colocated under customer_id distribution. JOIN to products is
  --      free because products is a reference table.
  SELECT o.order_id, o.placed_at, o.status,
         oi.quantity, oi.unit_price_cents,
         p.sku, p.name, p.price_cents
    FROM oltp_shop.orders o
    JOIN oltp_shop.order_items oi
      ON oi.customer_id = o.customer_id AND oi.order_id = o.order_id
    JOIN oltp_shop.products p
      ON p.product_id = oi.product_id
   WHERE o.customer_id = :cid
   ORDER BY o.placed_at DESC
   LIMIT 20;

\elif :op <= 85
  -- 10%  customer's address book
  SELECT address_id, label, street, city, postal_code, country_code
    FROM oltp_shop.addresses
   WHERE customer_id = :cid;

\elif :op <= 95
  -- 10%  customer lifetime spend (aggregate, colocated)
  SELECT count(*)                          AS num_orders,
         coalesce(sum(total_cents), 0)     AS lifetime_cents,
         max(placed_at)                    AS last_order_at
    FROM oltp_shop.orders
   WHERE customer_id = :cid
     AND status IN ('paid', 'shipped');

\else
  -- 5%   reference-table lookup (product by id)
  SELECT product_id, sku, name, price_cents, category_id
    FROM oltp_shop.products
   WHERE product_id = :pid;
\endif
