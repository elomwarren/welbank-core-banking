-- =============================================================================
-- 0002_reference_tables_test.sql — rules of the domains and reference tables.
--
-- Run by database/tests/run_tests.sh as SYSDBA inside WELBANK. Everything runs
-- in one transaction that is rolled back at the end: no data is left behind.
-- Prints one line per check and a final "RESULT: <passed> passed, <failed> failed".
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v_region NUMBER;
  v_branch NUMBER;
  v_job    NUMBER;

  -- The statement must succeed.
  PROCEDURE accepts(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  accepts  ' || p_name);
  EXCEPTION WHEN OTHERS THEN
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  accepts  ' || p_name || '  -> ' || SQLERRM);
  END;

  -- The statement must be refused by a constraint.
  PROCEDURE rejects(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> was accepted');
  EXCEPTION WHEN OTHERS THEN
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  rejects  ' || p_name);
  END;
BEGIN
  INSERT INTO currencies (currency_code, currency_name, symbol) VALUES ('ZZA', 'Test currency A', 'ZA');
  INSERT INTO regions (region_name) VALUES ('Test region') RETURNING region_id INTO v_region;
  INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
  VALUES ('T-BR1', 'Test branch', v_region, '+233200000001', DATE '2020-01-01')
  RETURNING branch_id INTO v_branch;
  INSERT INTO departments (department_name) VALUES ('Test operations') RETURNING department_id INTO v_job;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary)
  VALUES ('Test teller', v_job, 20000, 40000) RETURNING job_id INTO v_job;

  rejects('currency code in lower case',
    q'[INSERT INTO currencies (currency_code, currency_name) VALUES ('zzb', 'Lower case')]');
  rejects('branch phone in local form',
    'INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on) VALUES (''T-BR2'', ''B2'', ' || v_region || ', ''0244123456'', SYSDATE)');
  rejects('branch status MAYBE',
    'INSERT INTO branches (branch_code, branch_name, region_id, phone, status, opened_on) VALUES (''T-BR3'', ''B3'', ' || v_region || ', ''+233200000003'', ''MAYBE'', SYSDATE)');
  rejects('branch in a region that does not exist',
    q'[INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on) VALUES ('T-BR4', 'B4', -1, '+233200000004', SYSDATE)]');
  accepts('branch address with digital address GA-123-4567',
    'INSERT INTO locations (branch_id, street_address, town, digital_address) VALUES (' || v_branch || ', ''Test street'', ''Accra'', ''GA-123-4567'')');
  rejects('second address for the same branch',
    'INSERT INTO locations (branch_id, street_address, town, digital_address) VALUES (' || v_branch || ', ''Other street'', ''Accra'', ''GA-123-4568'')');
  rejects('digital address in the old v1 form G4-378-7158',
    q'[INSERT INTO locations (branch_id, street_address, town, digital_address) VALUES (-1, 'x', 'x', 'G4-378-7158')]');
  accepts('fixed deposit with a term',
    q'[INSERT INTO account_products (product_code, product_name, account_type, currency_code, term_months) VALUES ('T-FD12', 'FD', 'FIXED_DEPOSIT', 'ZZA', 12)]');
  rejects('fixed deposit without a term (NULL trap)',
    q'[INSERT INTO account_products (product_code, product_name, account_type, currency_code) VALUES ('T-FD00', 'FD', 'FIXED_DEPOSIT', 'ZZA')]');
  rejects('savings account with a term',
    q'[INSERT INTO account_products (product_code, product_name, account_type, currency_code, term_months) VALUES ('T-SAV6', 'Sav', 'SAVINGS', 'ZZA', 6)]');
  rejects('overdraft on a savings account',
    q'[INSERT INTO account_products (product_code, product_name, account_type, currency_code, overdraft_allowed) VALUES ('T-SAVOD', 'Sav', 'SAVINGS', 'ZZA', TRUE)]');
  rejects('negative monthly fee',
    q'[INSERT INTO account_products (product_code, product_name, account_type, currency_code, monthly_fee) VALUES ('T-CURN', 'Cur', 'CURRENT', 'ZZA', -1)]');
  rejects('loan interest rate above 100 %',
    q'[INSERT INTO loan_products (product_code, product_name, currency_code, interest_rate, min_amount, max_amount, max_term_months) VALUES ('T-PL1', 'PL', 'ZZA', 120, 100, 1000, 12)]');
  rejects('loan minimum above maximum',
    q'[INSERT INTO loan_products (product_code, product_name, currency_code, interest_rate, min_amount, max_amount, max_term_months) VALUES ('T-PL2', 'PL', 'ZZA', 25, 5000, 1000, 12)]');
  -- Limits are set per job (changelog 0007).
  accepts('teller cash-deposit limit',
    'INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES (' || v_job || q'[, 'CASH_DEPOSIT', 'ZZA', 20000)]');
  rejects('second cash-deposit limit for the same job and currency',
    'INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES (' || v_job || q'[, 'CASH_DEPOSIT', 'ZZA', 30000)]');
  rejects('limit for a job that does not exist',
    q'[INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES (-1, 'TRANSFER', 'ZZA', 5000)]');
  rejects('unknown transaction type',
    'INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES (' || v_job || q'[, 'BRIBE', 'ZZA', 5000)]');
  rejects('limit of zero',
    'INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES (' || v_job || q'[, 'TRANSFER', 'ZZA', 0)]');

  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
  ROLLBACK;
END;
/
