-- Loads the 100k item rows. Item is a reference table and warehouse
-- independent, so this runs once, before the parallel warehouse load.

\set ON_ERROR_STOP on
SET search_path TO tpcc;
SET client_min_messages TO warning;

SELECT setseed(0.42);

INSERT INTO item (i_id, i_im_id, i_name, i_price, i_data)
SELECT i,
       1 + (random() * 9999)::int,
       rndstr(14 + (random() * 10)::int),
       1.00 + (random() * 99)::numeric(5,2),
       maybe_original(rndstr(26 + (random() * 24)::int))
FROM generate_series(1, 100000) i;
