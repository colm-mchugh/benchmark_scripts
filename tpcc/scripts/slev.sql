-- Stock-Level, 4% of the deck. Read-only, and the only transaction that joins
-- across tables, which in Citus is a colocated single-shard join.
\set w_id (:client_id % :warehouses) + 1
\set d_id random(1, 10)
\set threshold random(10, 20)
SELECT tpcc.slev(:w_id, :d_id, :threshold);
