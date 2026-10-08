-- Delivery, 4% of the deck. Delivers the oldest undelivered order in each of
-- the warehouse's ten districts.
\set w_id (:client_id % :warehouses) + 1
\set carrier random(1, 10)
SELECT tpcc.delivery(:w_id, :carrier);
