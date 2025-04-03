$HOME/bcc/tools/wakeuptime.py -f $2 > wakeuptime.out.stacks
$HOME/FlameGraph/flamegraph.pl --color=wakeup --title="Wakeup Time Flame Graph" --countname=us < wakeuptime.out.stacks > wakeuptime.$1.svg
