\set scale 3000
\set naccounts 100000 * :scale
\set aid random(1, :naccounts)
BEGIN;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
END;
