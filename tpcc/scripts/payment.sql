-- Payment, 43% of the deck. Inputs per clause 2.5.1.2:
-- 60% of customers are selected by last name, and 15% belong to a remote
-- warehouse.
\set w_id (:client_id % :warehouses) + 1
\set d_id random(1, 10)
\set byname CASE WHEN random(1, 100) <= 60 THEN 1 ELSE 0 END
\set remote CASE WHEN random(1, 100) <= 15 THEN 1 ELSE 0 END
\set c_w_id CASE WHEN :remote = 1 THEN ((:w_id + random(1, :warehouses)) % :warehouses) + 1 ELSE :w_id END
\set c_d_id CASE WHEN :remote = 1 THEN random(1, 10) ELSE :d_id END
\set c_id (((random(0, 1023) | random(1, 3000)) + 123) % 3000) + 1
\set c_last_n (((random(0, 255) | random(0, 999)) + 123) % 1000)
\set amount random(100, 500000) / 100.0
SELECT tpcc.payment(:w_id, :d_id, :c_w_id, :c_d_id, :c_id, :byname, :amount,
                    tpcc.cust_last(:c_last_n));
