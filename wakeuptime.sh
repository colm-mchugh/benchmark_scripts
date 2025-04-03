export BCC=`pwd`bcc
export FG=`pwd`FlameGraph
$BCC/tools/wakeuptime.py -f $2 > wakeuptime.out.stacks
echo "Generated wakeup stacks"
$FG/flamegraph.pl --color=wakeup --title="Wakeup Time Flame Graph" --countname=us < wakeuptime.out.stacks > wakeuptime.$1.svg
echo "Created wakeup Flame Graph"
