-- Order-Status, 4% of the deck. 60% of customers are selected by last name.
\set w_id (:client_id % :warehouses) + 1
\set d_id random(1, 10)
\set byname CASE WHEN random(1, 100) <= 60 THEN 1 ELSE 0 END
\set c_id (((random(0, 1023) | random(1, 3000)) + 123) % 3000) + 1
\set c_last_n (((random(0, 255) | random(0, 999)) + 123) % 1000)
SELECT tpcc.ostat(:w_id, :d_id, :c_id, :byname, tpcc.cust_last(:c_last_n));
