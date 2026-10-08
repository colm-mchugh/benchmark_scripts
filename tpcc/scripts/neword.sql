-- New-Order, 45% of the deck. Inputs per clause 2.4.1.2.
-- Each client is pinned to a home warehouse, the way a TPC-C terminal is.
\set w_id (:client_id % :warehouses) + 1
\set d_id random(1, 10)
\set c_id (((random(0, 1023) | random(1, 3000)) + 123) % 3000) + 1
\set ol_cnt random(5, 15)
SELECT tpcc.neword(:w_id, :warehouses, :d_id, :c_id, :ol_cnt);
