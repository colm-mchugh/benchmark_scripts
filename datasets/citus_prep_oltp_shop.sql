-- =============================================================================
-- citus_prep_oltp_shop.sql  —  Distribute oltp_shop by customer_id (idempotent)
-- =============================================================================
--
-- Citus requires:
--   1.  Every UNIQUE / PRIMARY KEY / EXCLUDE constraint on a distributed
--       table must include the distribution column.
--   2.  An FK between two distributed tables must be on the distribution
--       column AND the two tables must be colocated.
--   3.  A reference table cannot FK into a distributed table.
--
-- The base oltp_shop.sql schema follows ordinary OLTP conventions (serial
-- per-table PKs, FK on shipping_address_id, UNIQUE on email) and so violates
-- all three rules. This script transforms the schema, distributes the
-- tables, and re-adds the FKs in composite form.
--
-- The ordering matters and the script enforces it:
--
--   STEP 1  Drop every inter-table FK.
--   STEP 2  Drop the email UNIQUE on customers (cannot include dist column).
--   STEP 3  Rewrite per-tenant PKs as composite (customer_id, ...).
--   STEP 4  Declare products + product_categories as reference tables.
--   STEP 5  Distribute customers + the four fact tables, all colocated on
--           customer_id.
--   STEP 6  Re-add FKs (single-column where they hit a reference table /
--           the distribution column, composite where they hit a per-tenant
--           PK).
--   STEP 7  ANALYZE so the advisor sees fresh stats on the distributed tables.
--
-- Safe to re-run: every step uses IF EXISTS guards, the create_*_table
-- calls are wrapped so already-Citus tables are skipped, and the FK
-- re-adds tolerate prior existence.
--
-- Usage:
--   psql -d <db> -f tmp/advisor_demo/oltp_shop.sql            # base schema + data
--   psql -d <db> -f tmp/advisor_demo/citus_prep_oltp_shop.sql # distribute it
-- =============================================================================

\set ON_ERROR_STOP on

SET search_path = oltp_shop, public;

-- ---------------------------------------------------------------------------
-- STEP 1 — drop every inter-table FK so PKs can be rewritten and tables can
--          be distributed without Citus rejecting cross-table FKs.
-- ---------------------------------------------------------------------------
ALTER TABLE addresses   DROP CONSTRAINT IF EXISTS addresses_customer_id_fkey;
ALTER TABLE addresses   DROP CONSTRAINT IF EXISTS addresses_customer_fkey;
ALTER TABLE orders      DROP CONSTRAINT IF EXISTS orders_customer_id_fkey;
ALTER TABLE orders      DROP CONSTRAINT IF EXISTS orders_customer_fkey;
ALTER TABLE orders      DROP CONSTRAINT IF EXISTS orders_shipping_address_id_fkey;
ALTER TABLE orders      DROP CONSTRAINT IF EXISTS orders_shipping_address_fkey;
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_order_id_fkey;
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_order_fkey;
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_product_id_fkey;
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_product_fkey;
ALTER TABLE payments    DROP CONSTRAINT IF EXISTS payments_order_id_fkey;
ALTER TABLE payments    DROP CONSTRAINT IF EXISTS payments_order_fkey;

-- ---------------------------------------------------------------------------
-- STEP 2 — customers.email UNIQUE doesn't include customer_id and can't be
--          made to include it without losing its meaning. Drop it; enforce
--          email uniqueness at the application layer.
-- ---------------------------------------------------------------------------
ALTER TABLE customers DROP CONSTRAINT IF EXISTS customers_email_key;

-- ---------------------------------------------------------------------------
-- STEP 3 — rewrite per-tenant PKs as composite (customer_id, <id>).
--          customers.pkey is already (customer_id) so no change there.
-- ---------------------------------------------------------------------------
ALTER TABLE addresses   DROP CONSTRAINT IF EXISTS addresses_pkey;
ALTER TABLE addresses   ADD  PRIMARY KEY (customer_id, address_id);

ALTER TABLE orders      DROP CONSTRAINT IF EXISTS orders_pkey;
ALTER TABLE orders      ADD  PRIMARY KEY (customer_id, order_id);

ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_pkey;
ALTER TABLE order_items ADD  PRIMARY KEY (customer_id, order_item_id);

ALTER TABLE payments    DROP CONSTRAINT IF EXISTS payments_pkey;
ALTER TABLE payments    ADD  PRIMARY KEY (customer_id, payment_id);

-- ---------------------------------------------------------------------------
-- STEP 4 — declare reference tables (idempotent via DO blocks).
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    PERFORM create_reference_table('oltp_shop.product_categories');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'product_categories already a Citus table: %', SQLERRM;
END $$;

DO $$ BEGIN
    PERFORM create_reference_table('oltp_shop.products');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'products already a Citus table: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- STEP 5 — distribute customers + fact tables, all colocated.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    PERFORM create_distributed_table('oltp_shop.customers', 'customer_id',
                                     shard_count => 32);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'customers already a Citus table: %', SQLERRM;
END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('oltp_shop.addresses', 'customer_id',
                                     colocate_with => 'oltp_shop.customers');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'addresses already a Citus table: %', SQLERRM;
END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('oltp_shop.orders', 'customer_id',
                                     colocate_with => 'oltp_shop.customers');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'orders already a Citus table: %', SQLERRM;
END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('oltp_shop.order_items', 'customer_id',
                                     colocate_with => 'oltp_shop.customers');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'order_items already a Citus table: %', SQLERRM;
END $$;

DO $$ BEGIN
    PERFORM create_distributed_table('oltp_shop.payments', 'customer_id',
                                     colocate_with => 'oltp_shop.customers');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'payments already a Citus table: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- STEP 6 — re-add FKs.
--   * Single-column on the dist column between colocated distributed tables.
--   * Single-column FK to a reference table.
--   * Composite FK where the referenced PK is now composite.
-- ---------------------------------------------------------------------------
ALTER TABLE addresses
    ADD CONSTRAINT addresses_customer_fkey
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id);

ALTER TABLE orders
    ADD CONSTRAINT orders_customer_fkey
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id);

ALTER TABLE orders
    ADD CONSTRAINT orders_shipping_address_fkey
    FOREIGN KEY (customer_id, shipping_address_id)
    REFERENCES addresses (customer_id, address_id);

ALTER TABLE order_items
    ADD CONSTRAINT order_items_order_fkey
    FOREIGN KEY (customer_id, order_id)
    REFERENCES orders (customer_id, order_id);

ALTER TABLE order_items
    ADD CONSTRAINT order_items_product_fkey
    FOREIGN KEY (product_id) REFERENCES products (product_id);

ALTER TABLE payments
    ADD CONSTRAINT payments_order_fkey
    FOREIGN KEY (customer_id, order_id)
    REFERENCES orders (customer_id, order_id);

-- ---------------------------------------------------------------------------
-- STEP 7 — refresh stats on the now-distributed tables.
-- ---------------------------------------------------------------------------
ANALYZE customers;
ANALYZE addresses;
ANALYZE orders;
ANALYZE order_items;
ANALYZE payments;
