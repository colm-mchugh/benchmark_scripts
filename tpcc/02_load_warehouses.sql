-- Loads warehouses :w_from .. :w_to, per clause 4.3.3.
--
-- Everything here is partitioned by warehouse, so disjoint ranges can be
-- loaded concurrently by separate sessions. The runner fans these out.

\set ON_ERROR_STOP on
SET search_path TO tpcc;
SET client_min_messages TO warning;

-- a per-range seed keeps a given range reproducible without making every
-- range identical
SELECT setseed(least(0.99, :w_from / 1000.0));

INSERT INTO warehouse (w_id, w_ytd, w_tax, w_name, w_street_1, w_street_2,
                       w_city, w_state, w_zip)
SELECT w, 300000.00, (random() * 0.2)::numeric(4,4),
       rndstr(6 + (random() * 4)::int),
       rndstr(10 + (random() * 10)::int), rndstr(10 + (random() * 10)::int),
       rndstr(10 + (random() * 10)::int), upper(rndstr(2)), rndstr(4) || '11111'
FROM generate_series(:w_from, :w_to) w;

INSERT INTO district (d_w_id, d_id, d_ytd, d_tax, d_next_o_id, d_name,
                      d_street_1, d_street_2, d_city, d_state, d_zip)
SELECT w, d, 30000.00, (random() * 0.2)::numeric(4,4), 3001,
       rndstr(6 + (random() * 4)::int),
       rndstr(10 + (random() * 10)::int), rndstr(10 + (random() * 10)::int),
       rndstr(10 + (random() * 10)::int), upper(rndstr(2)), rndstr(4) || '11111'
FROM generate_series(:w_from, :w_to) w, generate_series(1, 10) d;

INSERT INTO stock (s_w_id, s_i_id, s_quantity, s_ytd, s_order_cnt, s_remote_cnt,
                   s_data, s_dist_01, s_dist_02, s_dist_03, s_dist_04, s_dist_05,
                   s_dist_06, s_dist_07, s_dist_08, s_dist_09, s_dist_10)
SELECT w, i, 10 + (random() * 90)::int, 0, 0, 0,
       maybe_original(rndstr(26 + (random() * 24)::int)),
       rndstr(24), rndstr(24), rndstr(24), rndstr(24), rndstr(24),
       rndstr(24), rndstr(24), rndstr(24), rndstr(24), rndstr(24)
FROM generate_series(:w_from, :w_to) w, generate_series(1, 100000) i;

INSERT INTO customer (c_w_id, c_d_id, c_id, c_discount, c_credit, c_last, c_first,
                      c_credit_lim, c_balance, c_ytd_payment, c_payment_cnt,
                      c_delivery_cnt, c_street_1, c_street_2, c_city, c_state,
                      c_zip, c_phone, c_since, c_middle, c_data)
SELECT w, d, c,
       (random() * 0.5)::numeric(4,4),
       CASE WHEN random() < 0.1 THEN 'BC' ELSE 'GC' END,
       -- the first 1000 customers per district cover every syllable triple,
       -- the rest are drawn non-uniformly, so c_last lookups find 1..n rows
       CASE WHEN c <= 1000 THEN cust_last(c - 1) ELSE cust_last(nurand(255, 0, 999)) END,
       rndstr(8 + (random() * 8)::int),
       50000.00, -10.00, 10.00, 1, 0,
       rndstr(10 + (random() * 10)::int), rndstr(10 + (random() * 10)::int),
       rndstr(10 + (random() * 10)::int), upper(rndstr(2)), rndstr(4) || '11111',
     rndstr(16), timestamp with time zone '2020-01-01 00:00:00+00', 'OE',
       rndstr(300 + (random() * 200)::int)
FROM generate_series(:w_from, :w_to) w,
     generate_series(1, 10) d,
     generate_series(1, 3000) c;

INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date,
                     h_amount, h_data)
SELECT c, d, w, d, w, timestamp with time zone '2020-01-01 00:00:00+00',
       10.00, rndstr(12 + (random() * 12)::int)
FROM generate_series(:w_from, :w_to) w,
     generate_series(1, 10) d,
     generate_series(1, 3000) c;

INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_carrier_id, o_ol_cnt,
                    o_all_local, o_entry_d)
SELECT w, d, o,
       row_number() OVER (PARTITION BY w, d ORDER BY random())::int,
       CASE WHEN o < 2101 THEN 1 + (random() * 9)::int ELSE NULL END,
       5 + (random() * 10)::int,
       1,
     timestamp with time zone '2020-01-01 00:00:00+00'
FROM generate_series(:w_from, :w_to) w,
     generate_series(1, 10) d,
     generate_series(1, 3000) o;

INSERT INTO new_order (no_w_id, no_d_id, no_o_id)
SELECT o_w_id, o_d_id, o_id FROM orders
 WHERE o_w_id BETWEEN :w_from AND :w_to AND o_id >= 2101;

INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id,
                        ol_supply_w_id, ol_quantity, ol_amount, ol_dist_info,
                        ol_delivery_d)
SELECT o.o_w_id, o.o_d_id, o.o_id, n,
       1 + (random() * 99999)::int,
       o.o_w_id,
       5,
       CASE WHEN o.o_id < 2101 THEN 0.00
            ELSE (0.01 + random() * 9999.98)::numeric(6,2) END,
       rndstr(24),
       CASE WHEN o.o_id < 2101 THEN o.o_entry_d ELSE NULL END
FROM orders o, LATERAL generate_series(1, o.o_ol_cnt) n
WHERE o.o_w_id BETWEEN :w_from AND :w_to;
