
# ./launch_pgbench_runs.sh 600 pgbench_custom 48 2 pgbench_custom.48t.out

duration=$1
script=$2
threads=$3
trials=$4
outfile=$5

setsid $HOME/run_pgbench.sh $duration $script $threads $trials > $outfile 2>&1 < /dev/null &
sleep 5
ps -ef |grep pgbench
