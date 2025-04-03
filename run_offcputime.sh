export BCC=`pwd`bcc
export FG=`pwd`FlameGraph
$BCC/tools/offcputime.py -df -p 1 $2 > offcputime.out.stacks
echo "Finished offcputime tracing"
$FG/flamegraph.pl --color=io --title="Off-CPU Time Flame Graph" --countname=us < offcputime.out.stacks > offcputime.$1.svg
echo "Finished FlameGraph generation"
