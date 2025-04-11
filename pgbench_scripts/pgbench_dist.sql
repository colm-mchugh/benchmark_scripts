
-- Add citus support to pgbench tables

select create_distributed_table('pgbench_accounts', 'aid');
select create_distributed_table('pgbench_history', 'aid');
