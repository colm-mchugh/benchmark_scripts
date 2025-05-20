#!/usr/bin/python3

import os
import itertools

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

# Parameters to set in the server. 
server_parameters = [ 
  {"name": "citus.max_adaptive_executor_pool_size", "values": [1, 2]}, 
#  {"name": "citus.max_cached_conns_per_worker", "values": [1, 2, 4, 8, 16, 32]},
  {"name": "pgbouncer", "values": ["on", "off"]}
]


param_names = [param["name"] for param in server_parameters]
param_values = [param["values"] for param in server_parameters]

parameter_combinations = []
for values in itertools.product(*param_values):
  combination = {name: value for name, value in zip(param_names, values)}
  parameter_combinations.append(combination)

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
  for param_combination in parameter_combinations:
    for param_name, param_value in param_combination.items():
      fw.write(f'    az postgres flexible-server parameter set --resource-group XXX --server-name {instance["PGHOST"]} --name {param_name} --value {param_value}\n')
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
