-- The five TPC-C transactions as stored procedures, following the shape of
-- HammerDB's PostgreSQL driver (neword, payment, ostat, delivery, slev).
--
-- They deliberately run on the coordinator rather than being delegated with
-- create_distributed_function(): each inner statement is then planned by Citus
-- as its own single-shard query, which is what the router and fast-path
-- executor paths look like under a real OLTP workload.

\set ON_ERROR_STOP on
SET search_path TO tpcc;
SET client_min_messages TO warning;

-- ---------------------------------------------------------------- New-Order
CREATE OR REPLACE FUNCTION neword(no_w_id int, no_max_w_id int, no_d_id int,
                                  no_c_id int, no_o_ol_cnt int)
RETURNS void AS $$
DECLARE
    v_w_tax        numeric(4,4);
    v_c_discount   numeric(4,4);
    v_c_last       varchar(16);
    v_c_credit     char(2);
    v_d_tax        numeric(4,4);
    v_o_id         int;
    v_all_local    int := 1;
    v_supply_w_id  int;
    v_i_id         int;
    v_quantity     int;
    v_i_price      numeric(5,2);
    v_i_name       varchar(24);
    v_i_data       varchar(50);
    v_s_quantity   int;
    v_s_data       varchar(50);
    v_s_dist       char(24);
    v_ol_amount    numeric(6,2);
    n              int;
BEGIN
    SELECT c.c_discount, c.c_last, c.c_credit, w.w_tax
      INTO v_c_discount, v_c_last, v_c_credit, v_w_tax
      FROM customer c, warehouse w
     WHERE w.w_id = no_w_id
       AND c.c_w_id = w.w_id
       AND c.c_d_id = no_d_id
       AND c.c_id = no_c_id;

    SELECT d_next_o_id, d_tax INTO v_o_id, v_d_tax
      FROM district
     WHERE d_w_id = no_w_id AND d_id = no_d_id
       FOR UPDATE;

    UPDATE district SET d_next_o_id = d_next_o_id + 1
     WHERE d_w_id = no_w_id AND d_id = no_d_id;

    INSERT INTO new_order (no_w_id, no_d_id, no_o_id)
    VALUES (no_w_id, no_d_id, v_o_id);

    FOR n IN 1 .. no_o_ol_cnt LOOP
        v_i_id := nurand(8191, 1, 100000);

        -- 1% of lines are supplied by a remote warehouse
        IF no_max_w_id > 1 AND random() < 0.01 THEN
            v_supply_w_id := 1 + (random() * (no_max_w_id - 1))::int;
            IF v_supply_w_id >= no_w_id THEN
                v_supply_w_id := v_supply_w_id + 1;
                IF v_supply_w_id > no_max_w_id THEN
                    v_supply_w_id := 1;
                END IF;
            END IF;
            v_all_local := 0;
        ELSE
            v_supply_w_id := no_w_id;
        END IF;

        v_quantity := 1 + (random() * 9)::int;

        SELECT i_price, i_name, i_data INTO v_i_price, v_i_name, v_i_data
          FROM item WHERE i_id = v_i_id;

        SELECT s_quantity, s_data,
               CASE no_d_id
                   WHEN 1 THEN s_dist_01 WHEN 2 THEN s_dist_02
                   WHEN 3 THEN s_dist_03 WHEN 4 THEN s_dist_04
                   WHEN 5 THEN s_dist_05 WHEN 6 THEN s_dist_06
                   WHEN 7 THEN s_dist_07 WHEN 8 THEN s_dist_08
                   WHEN 9 THEN s_dist_09 ELSE s_dist_10
               END
          INTO v_s_quantity, v_s_data, v_s_dist
          FROM stock
         WHERE s_w_id = v_supply_w_id AND s_i_id = v_i_id
           FOR UPDATE;

        IF v_s_quantity > v_quantity THEN
            v_s_quantity := v_s_quantity - v_quantity;
        ELSE
            v_s_quantity := v_s_quantity - v_quantity + 91;
        END IF;

        UPDATE stock
           SET s_quantity   = v_s_quantity,
               s_ytd        = s_ytd + v_quantity,
               s_order_cnt  = s_order_cnt + 1,
               s_remote_cnt = s_remote_cnt +
                              CASE WHEN v_supply_w_id <> no_w_id THEN 1 ELSE 0 END
         WHERE s_w_id = v_supply_w_id AND s_i_id = v_i_id;

        v_ol_amount := (v_quantity * v_i_price
                        * (1 + v_w_tax + v_d_tax) * (1 - v_c_discount))::numeric(6,2);

        INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id,
                                ol_supply_w_id, ol_quantity, ol_amount, ol_dist_info)
        VALUES (no_w_id, no_d_id, v_o_id, n, v_i_id,
                v_supply_w_id, v_quantity, v_ol_amount, v_s_dist);
    END LOOP;

    INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_carrier_id, o_ol_cnt,
                        o_all_local, o_entry_d)
    VALUES (no_w_id, no_d_id, v_o_id, no_c_id, NULL, no_o_ol_cnt,
            v_all_local, now());
END;
$$ LANGUAGE plpgsql SET search_path = tpcc, pg_catalog;

-- ------------------------------------------------------------------ Payment
CREATE OR REPLACE FUNCTION payment(p_w_id int, p_d_id int, p_c_w_id int,
                                   p_c_d_id int, p_c_id int, p_byname int,
                                   p_h_amount numeric, p_c_last varchar)
RETURNS void AS $$
DECLARE
    v_w_name    varchar(10);
    v_d_name    varchar(10);
    v_c_id      int := p_c_id;
    v_namecnt   int;
    v_c_credit  char(2);
    v_c_data    varchar(500);
    v_c_balance numeric(12,2);
BEGIN
    UPDATE warehouse SET w_ytd = w_ytd + p_h_amount WHERE w_id = p_w_id;
    SELECT w_name INTO v_w_name FROM warehouse WHERE w_id = p_w_id;

    UPDATE district SET d_ytd = d_ytd + p_h_amount
     WHERE d_w_id = p_w_id AND d_id = p_d_id;
    SELECT d_name INTO v_d_name
      FROM district WHERE d_w_id = p_w_id AND d_id = p_d_id;

    IF p_byname = 1 THEN
        -- clause 2.5.2.2: take the middle customer of the sorted namesake set
        SELECT count(*) INTO v_namecnt FROM customer
         WHERE c_w_id = p_c_w_id AND c_d_id = p_c_d_id AND c_last = p_c_last;

        SELECT c_id INTO v_c_id FROM customer
         WHERE c_w_id = p_c_w_id AND c_d_id = p_c_d_id AND c_last = p_c_last
         ORDER BY c_first
         OFFSET GREATEST(v_namecnt - 1, 0) / 2 LIMIT 1;
    END IF;

    SELECT c_credit, c_balance INTO v_c_credit, v_c_balance
      FROM customer
     WHERE c_w_id = p_c_w_id AND c_d_id = p_c_d_id AND c_id = v_c_id
       FOR UPDATE;

    IF v_c_credit = 'BC' THEN
        SELECT c_data INTO v_c_data FROM customer
         WHERE c_w_id = p_c_w_id AND c_d_id = p_c_d_id AND c_id = v_c_id;

        v_c_data := substr(v_c_id || ' ' || p_c_d_id || ' ' || p_c_w_id || ' ' ||
                           p_d_id || ' ' || p_w_id || ' ' || p_h_amount || ' ' ||
                           v_c_data, 1, 500);

        UPDATE customer
           SET c_balance     = c_balance - p_h_amount,
               c_ytd_payment = c_ytd_payment + p_h_amount,
               c_payment_cnt = c_payment_cnt + 1,
               c_data        = v_c_data
         WHERE c_w_id = p_c_w_id AND c_d_id = p_c_d_id AND c_id = v_c_id;
    ELSE
        UPDATE customer
           SET c_balance     = c_balance - p_h_amount,
               c_ytd_payment = c_ytd_payment + p_h_amount,
               c_payment_cnt = c_payment_cnt + 1
         WHERE c_w_id = p_c_w_id AND c_d_id = p_c_d_id AND c_id = v_c_id;
    END IF;

    INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id,
                         h_date, h_amount, h_data)
    VALUES (v_c_id, p_c_d_id, p_c_w_id, p_d_id, p_w_id,
            now(), p_h_amount, v_w_name || ' ' || v_d_name);
END;
$$ LANGUAGE plpgsql SET search_path = tpcc, pg_catalog;

-- ------------------------------------------------------------- Order-Status
CREATE OR REPLACE FUNCTION ostat(os_w_id int, os_d_id int, os_c_id int,
                                 os_byname int, os_c_last varchar)
RETURNS void AS $$
DECLARE
    v_c_id      int := os_c_id;
    v_namecnt   int;
    v_c_balance numeric(12,2);
    v_o_id      int;
    v_lines     int;
BEGIN
    IF os_byname = 1 THEN
        SELECT count(*) INTO v_namecnt FROM customer
         WHERE c_w_id = os_w_id AND c_d_id = os_d_id AND c_last = os_c_last;

        SELECT c_id INTO v_c_id FROM customer
         WHERE c_w_id = os_w_id AND c_d_id = os_d_id AND c_last = os_c_last
         ORDER BY c_first
         OFFSET GREATEST(v_namecnt - 1, 0) / 2 LIMIT 1;
    END IF;

    SELECT c_balance INTO v_c_balance FROM customer
     WHERE c_w_id = os_w_id AND c_d_id = os_d_id AND c_id = v_c_id;

    SELECT o_id INTO v_o_id FROM orders
     WHERE o_w_id = os_w_id AND o_d_id = os_d_id AND o_c_id = v_c_id
     ORDER BY o_id DESC LIMIT 1;

    IF v_o_id IS NOT NULL THEN
        SELECT count(*) INTO v_lines FROM order_line
         WHERE ol_w_id = os_w_id AND ol_d_id = os_d_id AND ol_o_id = v_o_id;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = tpcc, pg_catalog;

-- ----------------------------------------------------------------- Delivery
CREATE OR REPLACE FUNCTION delivery(d_w_id int, d_o_carrier_id int)
RETURNS void AS $$
DECLARE
    v_d_id     int;
    v_o_id     int;
    v_c_id     int;
    v_ol_total numeric(12,2);
BEGIN
    FOR v_d_id IN 1 .. 10 LOOP
        SELECT no_o_id INTO v_o_id FROM new_order
         WHERE no_w_id = d_w_id AND no_d_id = v_d_id
         ORDER BY no_o_id LIMIT 1;

        CONTINUE WHEN v_o_id IS NULL;

        DELETE FROM new_order
         WHERE no_w_id = d_w_id AND no_d_id = v_d_id AND no_o_id = v_o_id;

        SELECT o_c_id INTO v_c_id FROM orders
         WHERE o_w_id = d_w_id AND o_d_id = v_d_id AND o_id = v_o_id;

        UPDATE orders SET o_carrier_id = d_o_carrier_id
         WHERE o_w_id = d_w_id AND o_d_id = v_d_id AND o_id = v_o_id;

        UPDATE order_line SET ol_delivery_d = now()
         WHERE ol_w_id = d_w_id AND ol_d_id = v_d_id AND ol_o_id = v_o_id;

        SELECT sum(ol_amount) INTO v_ol_total FROM order_line
         WHERE ol_w_id = d_w_id AND ol_d_id = v_d_id AND ol_o_id = v_o_id;

        UPDATE customer
           SET c_balance      = c_balance + v_ol_total,
               c_delivery_cnt = c_delivery_cnt + 1
         WHERE c_w_id = d_w_id AND c_d_id = v_d_id AND c_id = v_c_id;

        v_o_id := NULL;
    END LOOP;
END;
$$ LANGUAGE plpgsql SET search_path = tpcc, pg_catalog;

-- -------------------------------------------------------------- Stock-Level
CREATE OR REPLACE FUNCTION slev(st_w_id int, st_d_id int, threshold int)
RETURNS void AS $$
DECLARE
    v_next_o_id int;
    v_low_stock int;
BEGIN
    SELECT d_next_o_id INTO v_next_o_id FROM district
     WHERE d_w_id = st_w_id AND d_id = st_d_id;

    SELECT count(DISTINCT s_i_id) INTO v_low_stock
      FROM order_line, stock
     WHERE ol_w_id = st_w_id
       AND ol_d_id = st_d_id
       AND ol_o_id < v_next_o_id
       AND ol_o_id >= v_next_o_id - 20
       AND s_w_id = st_w_id
       AND s_i_id = ol_i_id
       AND s_quantity < threshold;
END;
$$ LANGUAGE plpgsql SET search_path = tpcc, pg_catalog;
