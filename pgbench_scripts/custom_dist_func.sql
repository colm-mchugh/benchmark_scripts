\set scale 3000
\set naccounts 100000 * :scale
\set aid random(1, :naccounts)
\set bid random(1, 1 * :scale)
\set tid random(1, 10 * :scale)
\set delta random(-5000, 5000)

SELECT pgbench_account_update(:aid, :delta, :tid, :bid);
