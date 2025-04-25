## 1 create benchmark script
This step creates the `run_pgbench.sh` script. This script runs `pgbench` against a set of postgres/citus instances.
If you want to change the instances or the `clients` parameter then edit `gen_pgbench_script.py` and rerun it.

```
$ ./gen_pgbench_script.py
```

## 2 run benchmark script
Use the `launch_pgbench_runs.sh` script to run `run_pgbench.sh` as a system process. It takes 5 arguments: the duration for each `pgbench`
run, the SQL script for each `pgbench`run, the threads parameter for each `pgbench` run, the number of trials
or times to repeat the runs, and the output file. The output file name should be something meaningful to you.
```
$ ./launch_pgbench_runs.sh 900  `pwd`/pgbench_custom 16 5 pgbench_run_xx.txt
```

## 3 analyze benchmark output
Take the output file from step 2 and use `process_pgbench_output.py` to load it into a database table `pgbench_results`.
Requires a `postgres` environment. If the `pgbench_results` table does not exist, run:
```
$ ./process_pgbench_output.py --filename pgbench_run_xx --maketable y
```

If `pgbench_results` does exist, run:
```
$ ./process_pgbench_output.py --filename pgbench_run_xx
```

```
$ psql
postgres=> select cluster, clients, round(avg(transactions), 0) as transactions,
                  round(avg(tps)::numeric, 2) as tps, round(avg(latency_avg)::numeric, 2) as latency_avg,
                  count(1) as ntrials
          from pgbench_results where label = 'pgbench_run_xx'
          group by cluster, clients
          order by clients, cluster;
```
