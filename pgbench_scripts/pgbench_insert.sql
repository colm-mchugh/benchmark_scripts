\set scale 3000
\set naccounts 100000 * :scale
\set aid random(1, :naccounts)
\set nbranches :scale
\set ntellers 10 * :scale
\set bid random(1, :nbranches)
\set tid random(1, :ntellers)
\set delta random(-5000, 5000)
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
