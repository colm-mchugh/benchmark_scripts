
$BCC/tools/offwaketime.py -f $2> offwaketime.out.stacks
echo "Generated offwaketime stacks"
$FG/flamegraph.pl --color=wakeup --title="Off Wakeup Time Flame Graph" --countname=us < offwaketime.out.stacks > offwaketime.$1.svg
ls -ltrh offwaketime.$1.svg
