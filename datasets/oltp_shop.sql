-- =============================================================================
-- OLTP Shop  -  sample dataset for the "Distribute Table" advisor demo
-- =============================================================================
--
-- A small e-commerce / order-processing workload, populated with a Zipfian-like
-- power-law distribution over customer_id. A handful of "whale" customers own
-- most of the orders, items and payments; the long tail of customers has only
-- one or two orders each. This mimics what real OLTP / SaaS data looks like.
--
-- What the advisor should see when it inspects this schema:
--
--   * customer_id appears as a column in 5 tables (customers, addresses,
--     orders, order_items, payments)  ->  strong "matching join key" signal,
--     and an obvious natural distribution column.
--   * orders / order_items / payments are large fact tables with very high
--     cardinality on customer_id and order_id, and skewed values per customer
--     (data skew is visible in pg_stats most_common_vals / most_common_freqs).
--   * products (~500 rows) and product_categories (~20 rows) are small,
--     have no good distribution column, and should be flagged as candidate
--     reference tables.
--   * status / country_code / currency / method are deliberately low-cardinality
--     so the advisor learns to *avoid* them as distribution columns.
--
-- Run with:
--     psql -d <db> -f oltp_shop.sql
--
-- Total runtime: ~30-60 s on a dev box.  All objects live in schema oltp_shop
-- and the script is idempotent (DROP SCHEMA IF EXISTS at the top).
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

DROP SCHEMA IF EXISTS oltp_shop CASCADE;
CREATE SCHEMA oltp_shop;
SET search_path = oltp_shop;

-- Make planner stats deterministic-ish so the advisor demo is reproducible.
SET default_statistics_target = 200;

-- -----------------------------------------------------------------------------
-- Reference data  (small, narrow tables -- should be flagged as reference tables)
-- -----------------------------------------------------------------------------

CREATE TABLE product_categories (
    category_id   smallserial PRIMARY KEY,
    name          text NOT NULL,
    description   text
);

CREATE TABLE products (
    product_id    serial PRIMARY KEY,
    sku           text UNIQUE NOT NULL,
    category_id   smallint NOT NULL REFERENCES product_categories(category_id),
    name          text NOT NULL,
    price_cents   int  NOT NULL CHECK (price_cents > 0),
    weight_grams  int,
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX products_category_idx ON products(category_id);

-- -----------------------------------------------------------------------------
-- Tenant entity  (the natural distribution key for every table below)
-- -----------------------------------------------------------------------------

CREATE TABLE customers (
    customer_id   bigserial PRIMARY KEY,
    email         text UNIQUE NOT NULL,
    full_name     text NOT NULL,
    company       text,
    country_code  char(2) NOT NULL,
    signup_at     timestamptz NOT NULL DEFAULT now(),
    status        text NOT NULL DEFAULT 'active'   -- 'active','suspended','closed'
);
CREATE INDEX customers_country_idx ON customers(country_code);
CREATE INDEX customers_status_idx  ON customers(status);

-- -----------------------------------------------------------------------------
-- Per-tenant operational data
-- -----------------------------------------------------------------------------

CREATE TABLE addresses (
    address_id    bigserial PRIMARY KEY,
    customer_id   bigint NOT NULL REFERENCES customers(customer_id),
    label         text   NOT NULL,                 -- 'home','work','billing'
    street        text   NOT NULL,
    city          text   NOT NULL,
    region        text,
    postal_code   text   NOT NULL,
    country_code  char(2) NOT NULL
);
CREATE INDEX addresses_customer_idx ON addresses(customer_id);

CREATE TABLE orders (
    order_id              bigserial PRIMARY KEY,
    customer_id           bigint  NOT NULL REFERENCES customers(customer_id),
    placed_at             timestamptz NOT NULL,
    status                text    NOT NULL,        -- 'pending','paid','shipped','cancelled'
    shipping_address_id   bigint  REFERENCES addresses(address_id),
    total_cents           int     NOT NULL,
    currency              char(3) NOT NULL DEFAULT 'USD'
);
CREATE INDEX orders_customer_idx     ON orders(customer_id);
CREATE INDEX orders_placed_at_idx    ON orders(placed_at);
CREATE INDEX orders_status_idx       ON orders(status);

CREATE TABLE order_items (
    order_item_id      bigserial PRIMARY KEY,
    order_id           bigint   NOT NULL REFERENCES orders(order_id),
    customer_id        bigint   NOT NULL,          -- denormalized for colocation
    product_id         int      NOT NULL REFERENCES products(product_id),
    quantity           smallint NOT NULL CHECK (quantity > 0),
    unit_price_cents   int      NOT NULL
);
CREATE INDEX order_items_order_idx    ON order_items(order_id);
CREATE INDEX order_items_customer_idx ON order_items(customer_id);
CREATE INDEX order_items_product_idx  ON order_items(product_id);

CREATE TABLE payments (
    payment_id     bigserial PRIMARY KEY,
    order_id       bigint NOT NULL REFERENCES orders(order_id),
    customer_id    bigint NOT NULL,                -- denormalized for colocation
    paid_at        timestamptz NOT NULL,
    amount_cents   int    NOT NULL,
    method         text   NOT NULL,                -- 'card','paypal','wire'
    status         text   NOT NULL DEFAULT 'captured'
);
CREATE INDEX payments_order_idx    ON payments(order_id);
CREATE INDEX payments_customer_idx ON payments(customer_id);

-- =============================================================================
-- DATA GENERATION
-- =============================================================================
--
-- Sizing (tweak the row counts in the WITH cte below for bigger / smaller runs):
--
--     product_categories     20
--     products              500
--     customers          20,000
--     addresses          ~40,000  (1-3 per customer)
--     orders            200,000   (power-law over customers, alpha=3)
--     order_items       ~600,000  (1-5 per order)
--     payments         ~165,000   (only for paid / shipped orders)
--
-- Power-law:  customer_id = 1 + floor(N * random()^3)
-- With N=20000 and exponent 3, customer #1 gets ~6% of all orders, the top 10
-- customers ~13%, the top 100 customers ~28%; thousands of customers in the
-- long tail have just 0-3 orders each. Steepen by raising the exponent (4-8
-- = whale-heavy), flatten with exponent 1 (uniform).
-- =============================================================================

-- Make data reproducible across runs.
SELECT setseed(0.42);

-- ---- product_categories -----------------------------------------------------
INSERT INTO product_categories (name, description)
SELECT 'category_' || g,
       'Auto-generated product category ' || g
FROM generate_series(1, 20) g;

-- ---- products ---------------------------------------------------------------
INSERT INTO products (sku, category_id, name, price_cents, weight_grams)
SELECT 'SKU-' || lpad(g::text, 6, '0'),
       1 + (g % 20)::smallint,
       'Product ' || g,
       199  + (random() * 49800)::int,    -- $1.99 .. ~$500
       10   + (random() * 4990)::int
FROM generate_series(1, 500) g;

-- ---- customers --------------------------------------------------------------
INSERT INTO customers (email, full_name, company, country_code, signup_at, status)
SELECT 'user' || g || '@example.com',
       'User ' || g,
       CASE WHEN random() < 0.4 THEN 'Acme #' || g ELSE NULL END,
       (ARRAY['US','US','US','US','GB','DE','FR','CA','AU','BR',
              'IN','JP','NL','SE','MX','ES','IT','PL','TR','ZA'])
           [1 + (random() * 19)::int],
       now() - (random() * interval '730 days'),
       CASE WHEN random() < 0.92 THEN 'active'
            WHEN random() < 0.7  THEN 'suspended'
            ELSE 'closed' END
FROM generate_series(1, 20000) g;

-- ---- addresses (1-3 per customer) ------------------------------------------
-- NOTE: generate_series() folds a volatile argument that doesn't reference the
-- outer row to a single value, so we materialize the per-customer count in a
-- CTE first and reference it from generate_series to force per-row evaluation.
WITH cust_addrs AS (
    SELECT c.customer_id,
           c.country_code,
           1 + (random() * 2)::int AS n_addr   -- 1, 2 or 3 addresses
    FROM customers c
)
INSERT INTO addresses (customer_id, label, street, city, region,
                       postal_code, country_code)
SELECT ca.customer_id,
       (ARRAY['home','work','billing'])[s],
       (10 + (random()*9989)::int) || ' Main St',
       (ARRAY['Springfield','Riverside','Lakeville','Hillcrest','Fairview',
              'Greenfield','Madison','Franklin','Georgetown','Salem'])
           [1 + (random()*9)::int],
       NULL,
       lpad(((random()*99999)::int)::text, 5, '0'),
       ca.country_code
FROM cust_addrs ca
CROSS JOIN LATERAL generate_series(1, ca.n_addr) AS s;

-- ---- orders (power-law over customer_id) -----------------------------------
INSERT INTO orders (customer_id, placed_at, status, total_cents)
SELECT 1 + floor(20000 * power(random(), 3))::bigint,
       now() - (random() * interval '365 days'),
       (ARRAY['paid','paid','paid','paid','paid',
              'shipped','shipped','shipped',
              'pending','cancelled'])[1 + (random()*9)::int],
       1000 + (random()*99000)::int       -- placeholder, fixed up below
FROM generate_series(1, 200000) g;

-- Point each order at one of the owning customer's addresses (if any).
UPDATE orders o
SET shipping_address_id = a.address_id
FROM (
    SELECT DISTINCT ON (customer_id) customer_id, address_id
    FROM addresses
    ORDER BY customer_id, address_id
) a
WHERE a.customer_id = o.customer_id;

-- ---- order_items (1-5 per order; carries customer_id for colocation) -------
-- Same volatile-SRF trick as addresses above: materialize n_items per order in
-- order_sizes, then have generate_series reference it via the LATERAL.
WITH order_sizes AS (
    SELECT o.order_id,
           o.customer_id,
           1 + (random() * 4)::int AS n_items
    FROM orders o
),
item_seed AS (
    SELECT os.order_id,
           os.customer_id,
           1 + (random() * 499)::int           AS pid,
           (1 + (random() * 4)::int)::smallint AS qty
    FROM order_sizes os
    CROSS JOIN LATERAL generate_series(1, os.n_items) AS s
)
INSERT INTO order_items (order_id, customer_id, product_id,
                         quantity, unit_price_cents)
SELECT s.order_id, s.customer_id, s.pid, s.qty, p.price_cents
FROM item_seed s
JOIN products p ON p.product_id = s.pid;

-- Fix up orders.total_cents to actually equal sum(items).
UPDATE orders o
SET total_cents = sub.total
FROM (
    SELECT order_id, sum(quantity * unit_price_cents)::int AS total
    FROM order_items
    GROUP BY order_id
) sub
WHERE sub.order_id = o.order_id;

-- ---- payments (one per paid / shipped order) -------------------------------
INSERT INTO payments (order_id, customer_id, paid_at, amount_cents,
                      method, status)
SELECT order_id,
       customer_id,
       placed_at + (random() * interval '10 minutes'),
       total_cents,
       (ARRAY['card','card','card','card','card',
              'card','paypal','paypal','wire'])[1 + (random()*8)::int],
       'captured'
FROM orders
WHERE status IN ('paid','shipped');

-- =============================================================================
-- Stats refresh so the advisor sees up-to-date pg_class / pg_stats data.
-- =============================================================================

ANALYZE oltp_shop.product_categories;
ANALYZE oltp_shop.products;
ANALYZE oltp_shop.customers;
ANALYZE oltp_shop.addresses;
ANALYZE oltp_shop.orders;
ANALYZE oltp_shop.order_items;
ANALYZE oltp_shop.payments;

-- =============================================================================
-- Sanity / demo queries  (run by hand to confirm the power-law looks right)
-- =============================================================================
--
-- -- Row counts (compare to pg_class.reltuples):
-- SELECT relname, reltuples::bigint
-- FROM pg_class
-- WHERE relnamespace = 'oltp_shop'::regnamespace AND relkind = 'r'
-- ORDER BY reltuples DESC;
--
-- -- Top customers by order count (should show clear whale pattern):
-- SELECT customer_id, count(*) AS orders
-- FROM oltp_shop.orders
-- GROUP BY customer_id
-- ORDER BY orders DESC
-- LIMIT 10;
--
-- -- Long-tail check: what % of customers have <= 3 orders?
-- SELECT
--     count(*) FILTER (WHERE orders <= 3) * 100.0 / count(*) AS pct_small,
--     count(*) FILTER (WHERE orders > 100)                   AS num_whales
-- FROM (
--     SELECT customer_id, count(*) AS orders
--     FROM oltp_shop.orders GROUP BY customer_id
-- ) s;
--
-- -- What the advisor sees: columns named customer_id across the schema.
-- SELECT table_name, column_name, data_type
-- FROM information_schema.columns
-- WHERE table_schema = 'oltp_shop' AND column_name = 'customer_id'
-- ORDER BY table_name;
--
-- -- Cardinality / skew per column (this is the heart of the advisor):
-- SELECT tablename, attname, n_distinct, correlation,
--        array_length(most_common_vals, 1) AS n_mcv
-- FROM pg_stats
-- WHERE schemaname = 'oltp_shop'
-- ORDER BY tablename, attname;
