
pgbench -i -I "dt" 
 
-- Distribute tables - connect to 5432 
export PGPORT=5432
psql -c "SELECT create_distributed_table('pgbench_history', 'aid');" 
psql -c "SELECT create_distributed_table('pgbench_accounts', 'aid');" 
#psql -c "SELECT create_distributed_table('pgbench_tellers', 'tid');" 
#psql -c "SELECT create_distributed_table('pgbench_branches', 'bid');" 

 
-- Populate tables – scale factor 3000  
pgbench -i -I "gvp" -s 3000 
 

