-- =============================================================================
-- oltp_shop_mixed.sql  —  80% read / 20% write OLTP workload (pgbench script)
-- =============================================================================
--
-- The same read mix as oltp_shop_read.sql, plus a realistic write mix:
--
--   10%  PLACE ORDER  — multi-statement transaction touching orders +
--                       order_items + payments, all carrying the same
--                       customer_id.  THIS is the marquee Citus colocation
--                       demo: if the three tables are distributed by
--                       customer_id the whole checkout is a single-shard
--                       transaction; otherwise it becomes a multi-shard
--                       distributed transaction (2PC, much slower, more
--                       contention).
--    5%  UPDATE order status (e.g. paid -> shipped)
--    3%  ADD address
--    2%  UPDATE customer status
--
-- Customer pick is Zipfian (s=1.2) so whales get hit more often — both reads
-- and writes concentrate on the same hot tenants, mirroring real workloads
-- and making hot-shard issues observable.
--
-- Usage:
--   pgbench -n -f tmp/advisor_demo/workloads/oltp_shop_mixed.sql \
--           -T 60 -c 8 -j 4 -P 5 -M prepared <db>
-- =============================================================================

\set cid     random_zipfian(1, 20000, 1.2)
\set pid1    random(1, 500)
\set pid2    random(1, 500)
\set qty1    random(1, 3)
\set qty2    random(1, 3)
\set price1  random(199, 49999)
\set price2  random(199, 49999)
\set total   random(2000, 100000)
\set op      random(1, 100)

-- ============================== READS (80%) =================================

\if :op <= 25
  -- 25%  customer lookup
  SELECT customer_id, email, full_name, country_code, status, signup_at
    FROM oltp_shop.customers
   WHERE customer_id = :cid;

\elif :op <= 50
  -- 25%  recent orders
  SELECT order_id, placed_at, status, total_cents, currency
    FROM oltp_shop.orders
   WHERE customer_id = :cid
   ORDER BY placed_at DESC
   LIMIT 10;

\elif :op <= 62
  -- 12%  order + items + products. Join on (customer_id, order_id) so Citus
  --      sees the colocation; products is a reference table.
  SELECT o.order_id, oi.quantity, oi.unit_price_cents, p.sku, p.name
    FROM oltp_shop.orders o
    JOIN oltp_shop.order_items oi
      ON oi.customer_id = o.customer_id AND oi.order_id = o.order_id
    JOIN oltp_shop.products p
      ON p.product_id = oi.product_id
   WHERE o.customer_id = :cid
   ORDER BY o.placed_at DESC
   LIMIT 20;

\elif :op <= 70
  -- 8%   addresses
  SELECT address_id, label, city, postal_code
    FROM oltp_shop.addresses
   WHERE customer_id = :cid;

\elif :op <= 77
  -- 7%   lifetime spend aggregate
  SELECT count(*), coalesce(sum(total_cents), 0)
    FROM oltp_shop.orders
   WHERE customer_id = :cid AND status IN ('paid','shipped');

\elif :op <= 80
  -- 3%   product lookup (reference table)
  SELECT product_id, sku, name, price_cents
    FROM oltp_shop.products
   WHERE product_id = :pid1;

-- ============================== WRITES (20%) ================================

\elif :op <= 90
  -- 10%  PLACE ORDER  (orders + 2 items + payment, all customer_id = :cid)
  --      The single-customer multi-table transaction. Designed to be a
  --      single-shard write when colocated on customer_id.
  INSERT INTO oltp_shop.orders (customer_id, placed_at, status, total_cents)
       VALUES (:cid, now(), 'pending', :total)
    RETURNING order_id \gset
  INSERT INTO oltp_shop.order_items
       (order_id, customer_id, product_id, quantity, unit_price_cents)
       VALUES (:order_id, :cid, :pid1, :qty1, :price1),
              (:order_id, :cid, :pid2, :qty2, :price2);
  INSERT INTO oltp_shop.payments
       (order_id, customer_id, paid_at, amount_cents, method, status)
       VALUES (:order_id, :cid, now(), :total, 'card', 'captured');

\elif :op <= 95
  -- 5%   UPDATE order status: ship the customer's most recent paid order
  --      (no-op if the customer has none, which is fine for the bench).
  UPDATE oltp_shop.orders
     SET status = 'shipped'
   WHERE customer_id = :cid
     AND order_id = (
        SELECT order_id
          FROM oltp_shop.orders
         WHERE customer_id = :cid AND status = 'paid'
         ORDER BY placed_at DESC
         LIMIT 1
     );

\elif :op <= 98
  -- 3%   ADD address
  INSERT INTO oltp_shop.addresses
       (customer_id, label, street, city, postal_code, country_code)
       VALUES (:cid, 'shipping',
               ((random()*9999)::int)::text || ' Pgbench Way',
               'BenchCity',
               lpad(((random()*99999)::int)::text, 5, '0'),
               'US');

\else
  -- 2%   UPDATE customer status
  UPDATE oltp_shop.customers
     SET status = 'active'
   WHERE customer_id = :cid;
\endif
