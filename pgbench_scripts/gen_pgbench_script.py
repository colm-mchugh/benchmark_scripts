#!/usr/bin/python3

import os

clients = ['128', '256', '385', '512']
instances = [ { "PGHOST": "ec1.postgres.database.azure.com", 
               "PGUSER": "myadmin", 
               "PGPORT": "5432", 
               "PGPASSWORD": "Oranje11", 
               "PGDATABASE": "postgres"  }, 
             { "PGHOST": "ec2.postgres.database.azure.com", 
               "PGUSER": "myadmin", 
               "PGPORT": "7432", 
               "PGPASSWORD": "Oranje11", 
               "PGDATABASE": "postgres"  }, 
             { "PGHOST": "ec4.postgres.database.azure.com", 
               "PGUSER": "myadmin", 
               "PGPORT": "7432", 
               "PGPASSWORD": "Oranje11", 
               "PGDATABASE": "postgres"  }, 
              { "PGHOST": "ec8.postgres.database.azure.com", 
               "PGUSER": "myadmin", 
               "PGPORT": "7432", 
               "PGPASSWORD": "Oranje11", 
               "PGDATABASE": "postgres"  },] 

fw = open('run_pgbench.sh', 'w')
fw.write('#!/bin/bash\n')
fw.write('clients=(' + ' '.join(clients) + ')\n')
fw.write('num_trials=$4\n')
fw.write('trial=1\n\n')
fw.write('until [ $trial -gt $num_trials ]\n')
fw.write('do\n')
fw.write('  for c in "${clients[@]}"\n')
fw.write('  do\n')

for instance in instances:
    for env_var, value in instance.items():
        fw.write(f"    export {env_var}={value}\n")
    fw.write('    echo "PGHOST:" `env|grep PGHOST` \n')
    fw.write('    echo "start time:" `date`\n')
    fw.write('    pgbench -T $1 -c $c -j $3 -f $2.sql\n')
    fw.write('    echo "end time:" `date`\n')
    fw.write('    echo ""\n')
    fw.write('\n')

fw.write('  done\n')
fw.write('  ((trial++))\n')
fw.write('done\n')
fw.close()

os.system('chmod +x run_pgbench.sh')
os.system('cat run_pgbench.sh')
