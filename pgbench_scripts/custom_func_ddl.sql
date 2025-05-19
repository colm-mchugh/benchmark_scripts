CREATE OR REPLACE FUNCTION pgbench_account_update(IN parm1 int, IN delta int, IN tellid int, IN branchid int)
  RETURNS INTEGER LANGUAGE plpgsql
AS $$
DECLARE
    abalance_local NUMERIC;
BEGIN
    SELECT abalance INTO abalance_local
    FROM pgbench_accounts
    WHERE aid = parm1;

    UPDATE pgbench_accounts
    SET abalance = abalance + delta
    WHERE aid = parm1;

    INSERT INTO pgbench_history (tid, bid, aid, delta, mtime)
    VALUES (tellid, branchid, parm1, delta, CURRENT_TIMESTAMP);

    RETURN abalance_local;
END;
$$;

SELECT create_distributed_function('pgbench_account_update(int,int,int,int)', '$1', colocate_with := 'pgbench_accounts');

