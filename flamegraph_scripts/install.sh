# Obtain FlameGraph and bcc sources
git clone https://github.com/brendangregg/FlameGraph
git clone https://github.com/iovisor/bcc

export BCC=`pwd`bcc
export FG=`pwd`FlameGraph

export PATH=$PATH:`pwd`
echo $PATH
