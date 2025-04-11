#!/bin/bash

#conns=(640, 768, 896, 1024)
conns=(128, 256, 384, 512)

num_trials=$4
trial=1

echo "Number of trials is $num_trials"

until [ $trial -gt $num_trials ]
do
    for conn in "${conns[@]}"
    do
        . /home/myadmin/colm_ec1_pgenv.sh
        echo "PGHOST:" `env|grep PGH`
        echo "start time:" `date`
        pgbench -T $1 -c $conn -j $3 -f /home/myadmin/$2.sql
        echo "end time:" `date`
        echo ""
        
        . /home/myadmin/colm_ec2_pgenv.sh
        echo "PGHOST:" `env|grep PGH`
        echo "start time:" `date`
        pgbench -T $1 -c $conn -j $3 -f /home/myadmin/$2.sql
        echo "end time:" `date`
        echo ""
        
        . /home/myadmin/colm_ec4_pgenv.sh
        echo "PGHOST:" `env|grep PGH`
        echo "start time:" `date`
        pgbench -T $1 -c $conn -j $3 -f /home/myadmin/$2.sql
        echo "end time:" `date`
        echo ""
        
        . /home/myadmin/colm_ec8_pgenv.sh
        echo "PGHOST:" `env|grep PGH`
        echo "start time:" `date`
        pgbench -T $1 -c $conn -j $3 -f /home/myadmin/$2.sql
        echo "end time:" `date`
        echo ""
    
    done
    ((trial++))
done
