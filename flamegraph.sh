export FG=`pwd`FlameGraph
perf record -F 999 -p 1 --call-graph dwarf sleep $2
echo "Finished perf record"
perf script | $FG/stackcollapse-perf.pl > out.perf-folded
echo "Finished stackcollapse"
cat out.perf-folded | $FG/flamegraph.pl > cpu.$1.svg
ls -ltrh perf.$1.svg
