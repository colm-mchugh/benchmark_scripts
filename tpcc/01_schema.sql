-- TPC-C schema, HammerDB column naming.
--
-- Everything is distributed by warehouse id so a transaction touching a single
-- warehouse stays on one node; item is read-only and small, so it is a
-- reference table. The tables colocate automatically: same key type, same
-- shard count, default colocation group.

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS tpcc CASCADE;
CREATE SCHEMA tpcc;
SET search_path TO tpcc;

SET citus.shard_count TO :shards;
SET citus.shard_replication_factor TO 1;

CREATE TABLE warehouse (
    w_id        int            NOT NULL,
    w_ytd       numeric(12,2)  NOT NULL,
    w_tax       numeric(4,4)   NOT NULL,
    w_name      varchar(10)    NOT NULL,
    w_street_1  varchar(20)    NOT NULL,
    w_street_2  varchar(20)    NOT NULL,
    w_city      varchar(20)    NOT NULL,
    w_state     char(2)        NOT NULL,
    w_zip       char(9)        NOT NULL,
    CONSTRAINT warehouse_pkey PRIMARY KEY (w_id)
);

CREATE TABLE district (
    d_w_id      int            NOT NULL,
    d_id        int            NOT NULL,
    d_ytd       numeric(12,2)  NOT NULL,
    d_tax       numeric(4,4)   NOT NULL,
    d_next_o_id int            NOT NULL,
    d_name      varchar(10)    NOT NULL,
    d_street_1  varchar(20)    NOT NULL,
    d_street_2  varchar(20)    NOT NULL,
    d_city      varchar(20)    NOT NULL,
    d_state     char(2)        NOT NULL,
    d_zip       char(9)        NOT NULL,
    CONSTRAINT district_pkey PRIMARY KEY (d_w_id, d_id)
);

CREATE TABLE customer (
    c_w_id         int            NOT NULL,
    c_d_id         int            NOT NULL,
    c_id           int            NOT NULL,
    c_discount     numeric(4,4)   NOT NULL,
    c_credit       char(2)        NOT NULL,
    c_last         varchar(16)    NOT NULL,
    c_first        varchar(16)    NOT NULL,
    c_credit_lim   numeric(12,2)  NOT NULL,
    c_balance      numeric(12,2)  NOT NULL,
    c_ytd_payment  numeric(12,2)  NOT NULL,
    c_payment_cnt  int            NOT NULL,
    c_delivery_cnt int            NOT NULL,
    c_street_1     varchar(20)    NOT NULL,
    c_street_2     varchar(20)    NOT NULL,
    c_city         varchar(20)    NOT NULL,
    c_state        char(2)        NOT NULL,
    c_zip          char(9)        NOT NULL,
    c_phone        char(16)       NOT NULL,
    c_since        timestamp      NOT NULL,
    c_middle       char(2)        NOT NULL,
    c_data         varchar(500)   NOT NULL,
    CONSTRAINT customer_pkey PRIMARY KEY (c_w_id, c_d_id, c_id)
);

CREATE TABLE history (
    h_c_id   int           NOT NULL,
    h_c_d_id int           NOT NULL,
    h_c_w_id int           NOT NULL,
    h_d_id   int           NOT NULL,
    h_w_id   int           NOT NULL,
    h_date   timestamp     NOT NULL,
    h_amount numeric(6,2)  NOT NULL,
    h_data   varchar(24)   NOT NULL
);

CREATE TABLE new_order (
    no_w_id int NOT NULL,
    no_d_id int NOT NULL,
    no_o_id int NOT NULL,
    CONSTRAINT new_order_pkey PRIMARY KEY (no_w_id, no_d_id, no_o_id)
);

CREATE TABLE orders (
    o_w_id       int       NOT NULL,
    o_d_id       int       NOT NULL,
    o_id         int       NOT NULL,
    o_c_id       int       NOT NULL,
    o_carrier_id int,
    o_ol_cnt     int       NOT NULL,
    o_all_local  int       NOT NULL,
    o_entry_d    timestamp NOT NULL,
    CONSTRAINT orders_pkey PRIMARY KEY (o_w_id, o_d_id, o_id)
);

CREATE TABLE order_line (
    ol_w_id        int            NOT NULL,
    ol_d_id        int            NOT NULL,
    ol_o_id        int            NOT NULL,
    ol_number      int            NOT NULL,
    ol_i_id        int            NOT NULL,
    ol_supply_w_id int            NOT NULL,
    ol_quantity    int            NOT NULL,
    ol_amount      numeric(6,2)   NOT NULL,
    ol_dist_info   char(24)       NOT NULL,
    ol_delivery_d  timestamp,
    CONSTRAINT order_line_pkey PRIMARY KEY (ol_w_id, ol_d_id, ol_o_id, ol_number)
);

CREATE TABLE stock (
    s_w_id       int          NOT NULL,
    s_i_id       int          NOT NULL,
    s_quantity   int          NOT NULL,
    s_ytd        numeric(8,2) NOT NULL,
    s_order_cnt  int          NOT NULL,
    s_remote_cnt int          NOT NULL,
    s_data       varchar(50)  NOT NULL,
    s_dist_01    char(24)     NOT NULL,
    s_dist_02    char(24)     NOT NULL,
    s_dist_03    char(24)     NOT NULL,
    s_dist_04    char(24)     NOT NULL,
    s_dist_05    char(24)     NOT NULL,
    s_dist_06    char(24)     NOT NULL,
    s_dist_07    char(24)     NOT NULL,
    s_dist_08    char(24)     NOT NULL,
    s_dist_09    char(24)     NOT NULL,
    s_dist_10    char(24)     NOT NULL,
    CONSTRAINT stock_pkey PRIMARY KEY (s_w_id, s_i_id)
);

CREATE TABLE item (
    i_id    int          NOT NULL,
    i_im_id int          NOT NULL,
    i_name  varchar(24)  NOT NULL,
    i_price numeric(5,2) NOT NULL,
    i_data  varchar(50)  NOT NULL,
    CONSTRAINT item_pkey PRIMARY KEY (i_id)
);

SELECT create_distributed_table('warehouse',  'w_id');
SELECT create_distributed_table('district',   'd_w_id');
SELECT create_distributed_table('customer',   'c_w_id');
SELECT create_distributed_table('history',    'h_w_id');
SELECT create_distributed_table('new_order',  'no_w_id');
SELECT create_distributed_table('orders',     'o_w_id');
SELECT create_distributed_table('order_line', 'ol_w_id');
SELECT create_distributed_table('stock',      's_w_id');
SELECT create_reference_table('item');

-- payment and order-status look customers up by last name
CREATE INDEX customer_last_idx ON customer (c_w_id, c_d_id, c_last, c_first);

-- order-status finds a customer's most recent order
CREATE INDEX orders_cust_idx ON orders (o_w_id, o_d_id, o_c_id, o_id);

-- data generation helpers, used by the loader
CREATE OR REPLACE FUNCTION rndstr(len int) RETURNS text AS $$
    SELECT substr(repeat(md5(random()::text), (len / 32) + 1), 1, len);
$$ LANGUAGE sql VOLATILE;

-- the C_LAST syllable table from clause 4.3.2.3
CREATE OR REPLACE FUNCTION cust_last(n int) RETURNS text AS $$
    SELECT s[(n / 100) % 10 + 1] || s[(n / 10) % 10 + 1] || s[n % 10 + 1]
    FROM (SELECT ARRAY['BAR', 'OUGHT', 'ABLE', 'PRI', 'PRES',
                       'ESE', 'ANTI', 'CALLY', 'ATION', 'EING'] AS s) t;
$$ LANGUAGE sql IMMUTABLE;

-- non-uniform random, clause 2.1.6
CREATE OR REPLACE FUNCTION nurand(a int, x int, y int) RETURNS int AS $$
    SELECT ((((random() * a)::int | (x + (random() * (y - x))::int)) + 42)
            % (y - x + 1)) + x;
$$ LANGUAGE sql VOLATILE;

-- i_data / s_data carry the literal 'ORIGINAL' in 10% of rows
CREATE OR REPLACE FUNCTION maybe_original(body text) RETURNS text AS $$
    SELECT CASE WHEN random() < 0.1
                THEN overlay(body PLACING 'ORIGINAL'
                             FROM (1 + (random() * (length(body) - 8))::int))
                ELSE body END;
$$ LANGUAGE sql VOLATILE;
