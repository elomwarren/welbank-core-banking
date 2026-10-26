-- =============================================================================
-- 0005_accounts_ledger_test.sql — rules of accounts, account holders,
-- transactions and ledger lines (changelog 0005).
--
-- Run by database/tests/run_tests.sh as SYSDBA inside WELBANK. Everything runs
-- in one transaction that is rolled back at the end: no data is left behind.
-- Deferred assertions are normally checked at COMMIT; here SET CONSTRAINTS ALL
-- IMMEDIATE checks them earlier, without committing. The "debits = credits"
-- rule can only be reached by a real COMMIT: see 0005_ledger_commit_test.sql.
--
-- Fixtures use the ISO 4217 test currency XTS and the "no currency" code XXX,
-- so they can never clash with real data.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v_region  NUMBER; v_branch NUMBER; v_dept NUMBER; v_job NUMBER;
  v_maker   NUMBER; v_checker NUMBER;
  v_cust_ok NUMBER; v_cust_ok2 NUMBER; v_cust_def NUMBER;
  v_sav     NUMBER; v_cur NUMBER;
  v_vault   NUMBER; v_fee NUMBER; v_vault_xxx NUMBER;
  v_acc     NUMBER; v_cur_acc NUMBER; v_joint NUMBER; v_def_acc NUMBER;
  v_txn     NUMBER; v_txn2 NUMBER; v_rev NUMBER;
  v_acc_no  accounts.account_no%TYPE;
  v_ref     transactions.txn_ref%TYPE;
  v_text    VARCHAR2(400);
  v_count   PLS_INTEGER;
  -- Columns of an approved account that allows debits (values: approved_vals).
  c_approved_cols CONSTANT VARCHAR2(60) := 'status, checked_by, checked_at, post_no_debit';

  PROCEDURE accepts(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  accepts  ' || p_name);
  EXCEPTION WHEN OTHERS THEN
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  accepts  ' || p_name || '  -> ' || SQLERRM);
  END;

  -- Runs p_sql and expects it to fail. p_expect (usually the name of the
  -- constraint or assertion) must appear in the error stack: that proves the
  -- RIGHT rule refused the row, not some unrelated error.
  PROCEDURE rejects(p_name VARCHAR2, p_sql VARCHAR2, p_expect VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF INSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, p_expect) > 0 THEN
      passed := passed + 1;
      DBMS_OUTPUT.PUT_LINE('PASS  rejects  ' || p_name);
    ELSE
      failed := failed + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> expected ' || p_expect || ', got ' || SQLERRM);
    END IF;
  END;

  -- Puts the DEFERRABLE assertions back to deferred, one by one, by name.
  -- Not "SET CONSTRAINTS ALL DEFERRED": in 23.26.3 that also defers the NOT
  -- DEFERRABLE assertions until COMMIT, so the checks after it would no longer
  -- see them fire after each statement.
  PROCEDURE defer_again IS
  BEGIN
    FOR a IN (SELECT assertion_name FROM dba_assertions
               WHERE owner = 'WELBANK' AND deferrable = 'DEFERRABLE') LOOP
      EXECUTE IMMEDIATE 'SET CONSTRAINT welbank.' || a.assertion_name || ' DEFERRED';
    END LOOP;
  END;

  -- Deferred assertions: check them now, as COMMIT would, then defer them again.
  PROCEDURE rejects_at_commit(p_name VARCHAR2, p_expect VARCHAR2) IS
  BEGIN
    rejects(p_name || ' (checked at COMMIT)', 'SET CONSTRAINTS ALL IMMEDIATE', p_expect);
    defer_again;
  END;

  PROCEDURE accepts_at_commit(p_name VARCHAR2) IS
  BEGIN
    accepts(p_name || ' (checked at COMMIT)', 'SET CONSTRAINTS ALL IMMEDIATE');
    defer_again;
  END;

  -- A plain true/false check on data.
  PROCEDURE check_that(p_name VARCHAR2, p_ok BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      passed := passed + 1;
      DBMS_OUTPUT.PUT_LINE('PASS  checks   ' || p_name);
    ELSE
      failed := failed + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  checks   ' || p_name);
    END IF;
  END;

  -- INSERT for a customer account (opened by v_maker, still PENDING_APPROVAL);
  -- p_extra_cols / p_extra_vals add or override columns for one check.
  FUNCTION account_sql(p_product NUMBER, p_currency VARCHAR2, p_mandate VARCHAR2 DEFAULT 'SOLE',
                       p_extra_cols VARCHAR2 DEFAULT NULL, p_extra_vals VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'INSERT INTO accounts (account_class, product_id, branch_id, currency_code, account_name, mandate, opened_by'
        || CASE WHEN p_extra_cols IS NOT NULL THEN ', ' || p_extra_cols END || ') VALUES ('
        || q'['CUSTOMER', ]' || NVL(TO_CHAR(p_product), 'NULL') || ', ' || v_branch
        || ', ''' || p_currency || q'[', 'Test account', ']' || p_mandate || ''', ' || v_maker
        || CASE WHEN p_extra_vals IS NOT NULL THEN ', ' || p_extra_vals END || ')';
  END;

  -- Values for c_approved_cols.
  FUNCTION approved_vals RETURN VARCHAR2 IS
  BEGIN
    RETURN q'['ACTIVE', ]' || v_checker || ', SYSTIMESTAMP, FALSE';
  END;

  -- INSERT for a ledger line.
  FUNCTION line_sql(p_txn NUMBER, p_line NUMBER, p_account NUMBER, p_direction VARCHAR2, p_amount NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'INSERT INTO ledger_entries (txn_id, line_no, account_id, direction, amount, balance_after) VALUES ('
        || p_txn || ', ' || p_line || ', ' || p_account || ', ''' || p_direction || ''', ' || p_amount || ', 0)';
  END;
BEGIN
  -- ---------------------------------------------------------------- fixtures
  MERGE INTO countries c USING (SELECT 'ZZA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('ZZA', 'Testland', 'Testlander');
  -- customers.country_of_residence defaults to GHA.
  MERGE INTO countries c USING (SELECT 'GHA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('GHA', 'Ghana', 'Ghanaian');
  INSERT INTO currencies (currency_code, currency_name) VALUES ('XTS', 'Test currency XTS');
  INSERT INTO currencies (currency_code, currency_name) VALUES ('XXX', 'Test currency XXX');
  INSERT INTO regions (region_name) VALUES ('Test region 5') RETURNING region_id INTO v_region;
  INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
    VALUES ('T-BR5', 'Test branch 5', v_region, '+233200000501', DATE '2020-01-01') RETURNING branch_id INTO v_branch;
  INSERT INTO departments (department_name) VALUES ('Test department 5') RETURNING department_id INTO v_dept;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary)
    VALUES ('Test officer 5', v_dept, 20000, 60000) RETURNING job_id INTO v_job;
  INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date, db_username)
    VALUES ('Esi', 'Maker', 'FEMALE', DATE '1993-01-10', 'ZZA', 'esi.maker.t5@example.com', '+233200000510',
            v_job, v_branch, 30000, DATE '2021-01-04', 'T5_MAKER') RETURNING employee_id INTO v_maker;
  INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date, db_username)
    VALUES ('Yaw', 'Checker', 'MALE', DATE '1988-07-21', 'ZZA', 'yaw.checker.t5@example.com', '+233200000511',
            v_job, v_branch, 50000, DATE '2019-03-01', 'T5_CHECKER') RETURNING employee_id INTO v_checker;
  INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, employment_status, income_band,
                         source_of_funds, account_purpose, expected_monthly_volume, data_consent_at,
                         kyc_status, kyc_approved_by, kyc_approved_at, risk_rating)
    VALUES ('Kofi', 'Verified', 'MALE', DATE '1985-02-01', 'ZZA', v_branch, 'EMPLOYED', '1K_5K',
            'SALARY', 'SAVINGS', 2000, SYSTIMESTAMP, 'VERIFIED', v_checker, SYSTIMESTAMP, 'LOW') RETURNING customer_id INTO v_cust_ok;
  INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, employment_status, income_band,
                         source_of_funds, account_purpose, expected_monthly_volume, data_consent_at,
                         kyc_status, kyc_approved_by, kyc_approved_at, risk_rating)
    VALUES ('Abena', 'Verified', 'FEMALE', DATE '1987-09-12', 'ZZA', v_branch, 'SELF_EMPLOYED', '5K_10K',
            'BUSINESS', 'BUSINESS', 8000, SYSTIMESTAMP, 'VERIFIED', v_checker, SYSTIMESTAMP, 'MEDIUM') RETURNING customer_id INTO v_cust_ok2;
  INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, employment_status, income_band,
                         source_of_funds, account_purpose, expected_monthly_volume, data_consent_at,
                         kyc_status, kyc_deferral_until)
    VALUES ('Kwesi', 'Deferred', 'MALE', DATE '1999-11-30', 'ZZA', v_branch, 'STUDENT', 'UNDER_1K',
            'GIFT', 'SAVINGS', 300, SYSTIMESTAMP, 'DEFERRED', TRUNC(SYSDATE) + 90) RETURNING customer_id INTO v_cust_def;
  INSERT INTO account_products (product_code, product_name, account_type, currency_code)
    VALUES ('T5-SAV', 'Test savings 5', 'SAVINGS', 'XTS') RETURNING product_id INTO v_sav;
  INSERT INTO account_products (product_code, product_name, account_type, currency_code, overdraft_allowed)
    VALUES ('T5-CUR', 'Test current 5', 'CURRENT', 'XTS', TRUE) RETURNING product_id INTO v_cur;
  INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit)
    VALUES ('INTERNAL', 'VAULT_CASH', v_branch, 'XTS', 'Vault cash XTS', 'ACTIVE', FALSE) RETURNING account_id INTO v_vault;
  INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit)
    VALUES ('INTERNAL', 'FEE_INCOME', v_branch, 'XTS', 'Fee income XTS', 'ACTIVE', FALSE) RETURNING account_id INTO v_fee;
  -- The customer account most checks use: SOLE, approved, debits allowed, Kofi as primary holder.
  EXECUTE IMMEDIATE account_sql(v_sav, 'XTS', 'SOLE', c_approved_cols, approved_vals)
    || ' RETURNING account_id, account_no INTO :1, :2' RETURNING INTO v_acc, v_acc_no;
  INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_acc, v_cust_ok, 'PRIMARY');

  -- ---------------------------------------------------------------- accounts
  check_that('account number generated from the sequence (' || v_acc_no || ')', REGEXP_LIKE(v_acc_no, '^[0-9]{13}$'));
  SELECT COUNT(*) INTO v_count FROM accounts
   WHERE (account_id = v_acc AND normal_side = 'CREDIT')
      OR (account_id = v_vault AND normal_side = 'DEBIT')
      OR (account_id = v_fee AND normal_side = 'CREDIT');
  check_that('virtual column normal_side: customer CREDIT, vault DEBIT, fee income CREDIT', v_count = 3);

  rejects('account in a currency other than its product''s (composite foreign key)',
    account_sql(v_sav, 'XXX'), 'ACCOUNTS_PRODUCT_FK');
  rejects('customer account without a product', account_sql(NULL, 'XTS'), 'ACCOUNTS_PRODUCT_CK');
  rejects('internal account with a product',
    'INSERT INTO accounts (account_class, internal_purpose, product_id, branch_id, currency_code, account_name) VALUES '
    || q'[('INTERNAL', 'SUSPENSE', ]' || v_sav || ', ' || v_branch || q'[, 'XTS', 'X')]', 'ACCOUNTS_PRODUCT_CK');
  rejects('internal account without a purpose',
    'INSERT INTO accounts (account_class, branch_id, currency_code, account_name) VALUES '
    || q'[('INTERNAL', ]' || v_branch || q'[, 'XTS', 'X')]', 'ACCOUNTS_PURPOSE_CK');
  rejects('customer account with an internal purpose',
    account_sql(v_sav, 'XTS', 'SOLE', 'internal_purpose', q'['VAULT_CASH']'), 'ACCOUNTS_PURPOSE_CK');
  rejects('internal account with a mandate',
    'INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, mandate) VALUES '
    || q'[('INTERNAL', 'SUSPENSE', ]' || v_branch || q'[, 'XTS', 'X', 'SOLE')]', 'ACCOUNTS_MANDATE_CK');
  rejects('customer account without a mandate',
    REPLACE(account_sql(v_sav, 'XTS'), q'['SOLE']', 'NULL'), 'ACCOUNTS_MANDATE_CK');
  rejects('second XTS vault at the same branch',
    'INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name) VALUES '
    || q'[('INTERNAL', 'VAULT_CASH', ]' || v_branch || q'[, 'XTS', 'X')]', 'ACCOUNTS_INTERNAL_UX');
  accepts('vault in another currency (XXX) at the same branch',
    'INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name) VALUES '
    || q'[('INTERNAL', 'VAULT_CASH', ]' || v_branch || q'[, 'XXX', 'Vault cash XXX')]');
  SELECT account_id INTO v_vault_xxx FROM accounts WHERE branch_id = v_branch AND internal_purpose = 'VAULT_CASH' AND currency_code = 'XXX';
  rejects('account number with letters',
    account_sql(v_sav, 'XTS', 'SOLE', 'account_no', q'['10000000000AB']'), 'ACCOUNTS_NO_CK');

  rejects('overdraft limit on a savings product (assertion)',
    'UPDATE accounts SET overdraft_limit = 100 WHERE account_id = ' || v_acc, 'ACCOUNTS_OVERDRAFT_PRODUCT_AS');
  rejects('overdraft limit on an internal account',
    'UPDATE accounts SET overdraft_limit = 100 WHERE account_id = ' || v_fee, 'ACCOUNTS_OVERDRAFT_CK');
  EXECUTE IMMEDIATE account_sql(v_cur, 'XTS', 'SOLE', c_approved_cols || ', overdraft_limit', approved_vals || ', 500')
    || ' RETURNING account_id INTO :1' RETURNING INTO v_cur_acc;
  INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_cur_acc, v_cust_ok2, 'PRIMARY');
  check_that('current account (product allows overdrafts) with a 500 overdraft limit', v_cur_acc IS NOT NULL);
  accepts('current account at -300, within its 500 overdraft',
    'UPDATE accounts SET ledger_balance = -300, available_balance = -300 WHERE account_id = ' || v_cur_acc);
  rejects('current account at -600, beyond its 500 overdraft',
    'UPDATE accounts SET ledger_balance = -600, available_balance = -600 WHERE account_id = ' || v_cur_acc, 'ACCOUNTS_BALANCE_CK');
  rejects('savings account below zero',
    'UPDATE accounts SET ledger_balance = -1, available_balance = -1 WHERE account_id = ' || v_acc, 'ACCOUNTS_BALANCE_CK');
  rejects('vault holding less than no cash',
    'UPDATE accounts SET ledger_balance = -1, available_balance = -1 WHERE account_id = ' || v_vault, 'ACCOUNTS_BALANCE_CK');
  rejects('available balance above the ledger balance',
    'UPDATE accounts SET available_balance = 10 WHERE account_id = ' || v_acc, 'ACCOUNTS_AVAILABLE_CK');

  rejects('ACTIVE customer account nobody approved',
    account_sql(v_sav, 'XTS', 'SOLE', 'status', q'['ACTIVE']'), 'ACCOUNTS_APPROVED_CK');
  rejects('opener approving their own account',
    account_sql(v_sav, 'XTS', 'SOLE', 'checked_by, checked_at', v_maker || ', SYSTIMESTAMP'), 'ACCOUNTS_CHECKER_CK');
  rejects('checker without the time of the check',
    account_sql(v_sav, 'XTS', 'SOLE', 'checked_by', TO_CHAR(v_checker)), 'ACCOUNTS_CHECKED_PAIR_CK');
  rejects('customer account without the employee who opened it',
    REPLACE(account_sql(v_sav, 'XTS'), ', ' || v_maker || ')', ', NULL)'), 'ACCOUNTS_OPENER_CK');
  rejects('debits allowed on an account waiting for approval',
    account_sql(v_sav, 'XTS', 'SOLE', 'post_no_debit', 'FALSE'), 'ACCOUNTS_DEBIT_STATUS_CK');
  rejects('freezing an account but leaving debits allowed',
    'UPDATE accounts SET status = ''FROZEN'' WHERE account_id = ' || v_acc, 'ACCOUNTS_DEBIT_STATUS_CK');
  SAVEPOINT before_freeze;
  accepts('freezing an account and stopping debits',
    'UPDATE accounts SET status = ''FROZEN'', post_no_debit = TRUE WHERE account_id = ' || v_acc);
  ROLLBACK TO before_freeze;
  rejects('closing an account that still holds money',
    'UPDATE accounts SET status = ''CLOSED'', closed_on = TRUNC(SYSDATE), post_no_debit = TRUE, ledger_balance = 50, available_balance = 50 WHERE account_id = ' || v_acc,
    'ACCOUNTS_CLOSED_CK');
  rejects('closing date before the opening date',
    'UPDATE accounts SET status = ''CLOSED'', closed_on = opened_on - 1, post_no_debit = TRUE WHERE account_id = ' || v_acc,
    'ACCOUNTS_CLOSED_DATE_CK');
  UPDATE accounts SET account_name = 'Kofi Verified - savings' WHERE account_id = v_acc;
  SELECT updated_by INTO v_text FROM accounts WHERE account_id = v_acc;
  check_that('update trigger filled updated_by (' || v_text || ')', v_text IS NOT NULL);

  -- ------------------------------------------------------------ account holders
  rejects('second primary holder on one account',
    'INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (' || v_acc || ', ' || v_cust_ok2 || q'[, 'PRIMARY')]',
    'ACCOUNT_HOLDERS_PRIMARY_UX');
  rejects('same customer twice on one account',
    'INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (' || v_acc || ', ' || v_cust_ok || q'[, 'SIGNATORY')]',
    'ACCOUNT_HOLDERS_PK');
  rejects('holder role OWNER',
    'INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (' || v_acc || ', ' || v_cust_ok2 || q'[, 'OWNER')]',
    'ACCOUNT_HOLDERS_ROLE_CK');
  rejects('a customer holding the bank''s vault (assertion)',
    'INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (' || v_vault || ', ' || v_cust_ok || q'[, 'PRIMARY')]',
    'ACCOUNT_HOLDERS_CLASS_AS');
  rejects('joint holder on a SOLE account (assertion)',
    'INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (' || v_acc || ', ' || v_cust_ok2 || q'[, 'JOINT')]',
    'ACCOUNT_HOLDERS_SOLE_AS');

  SAVEPOINT before_no_holder;
  EXECUTE IMMEDIATE account_sql(v_sav, 'XTS');
  rejects_at_commit('customer account without a primary holder', 'ACCOUNTS_PRIMARY_HOLDER_AS');
  ROLLBACK TO before_no_holder;

  SAVEPOINT before_joint;
  EXECUTE IMMEDIATE account_sql(v_sav, 'XTS', 'EITHER_TO_SIGN') || ' RETURNING account_id INTO :1' RETURNING INTO v_joint;
  INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_joint, v_cust_ok, 'PRIMARY');
  rejects_at_commit('EITHER_TO_SIGN account with no joint holder', 'ACCOUNTS_JOINT_MANDATE_AS');
  INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_joint, v_cust_def, 'JOINT');
  accepts_at_commit('EITHER_TO_SIGN account with its joint holder');

  -- --------------------------------------------- KYC: no debits until verified
  rejects('approving the joint account for debits while its joint holder is DEFERRED (assertion)',
    'UPDATE accounts SET status = ''ACTIVE'', checked_by = ' || v_checker || ', checked_at = SYSTIMESTAMP, post_no_debit = FALSE WHERE account_id = ' || v_joint,
    'ACCOUNTS_DEBIT_KYC_AS');
  ROLLBACK TO before_joint;
  EXECUTE IMMEDIATE account_sql(v_sav, 'XTS', 'SOLE', 'status, checked_by, checked_at', q'['ACTIVE', ]' || v_checker || ', SYSTIMESTAMP')
    || ' RETURNING account_id INTO :1' RETURNING INTO v_def_acc;
  INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_def_acc, v_cust_def, 'PRIMARY');
  check_that('deposits-only account (post_no_debit) for a DEFERRED customer', v_def_acc IS NOT NULL);
  rejects('allowing debits for the DEFERRED customer (assertion)',
    'UPDATE accounts SET post_no_debit = FALSE WHERE account_id = ' || v_def_acc, 'ACCOUNTS_DEBIT_KYC_AS');
  rejects('a DEFERRED signatory on an account that allows debits (assertion)',
    'INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (' || v_acc || ', ' || v_cust_def || q'[, 'SIGNATORY')]',
    'ACCOUNTS_DEBIT_KYC_AS');
  rejects('KYC leaving VERIFIED while the customer''s account allows debits (assertion)',
    'UPDATE customers SET kyc_status = ''REVIEW_DUE'' WHERE customer_id = ' || v_cust_ok, 'ACCOUNTS_DEBIT_KYC_AS');
  SAVEPOINT before_review;
  UPDATE accounts SET post_no_debit = TRUE WHERE account_id = v_acc;
  accepts('KYC review after stopping debits first',
    'UPDATE customers SET kyc_status = ''REVIEW_DUE'' WHERE customer_id = ' || v_cust_ok);
  ROLLBACK TO before_review;

  -- ------------------------------------------------------------- transactions
  INSERT INTO transactions (txn_type, channel, branch_id, currency_code, amount, narration, initiated_by)
    VALUES ('CASH_DEPOSIT', 'BRANCH', v_branch, 'XTS', 500, 'Test cash deposit', v_maker)
    RETURNING txn_id, txn_ref INTO v_txn, v_ref;
  check_that('pending branch deposit; reference generated (' || v_ref || ')', REGEXP_LIKE(v_ref, '^TXN[0-9]{12}$'));
  rejects('branch transaction without a branch',
    q'[INSERT INTO transactions (txn_type, channel, currency_code, amount, initiated_by) VALUES ('CASH_DEPOSIT', 'BRANCH', 'XTS', 10, ]' || v_maker || ')',
    'TRANSACTIONS_BRANCH_CK');
  rejects('branch transaction without the employee who keyed it in',
    q'[INSERT INTO transactions (txn_type, channel, branch_id, currency_code, amount) VALUES ('CASH_DEPOSIT', 'BRANCH', ]' || v_branch || q'[, 'XTS', 10)]',
    'TRANSACTIONS_BRANCH_CK');
  accepts('SYSTEM transaction (interest) with no employee',
    q'[INSERT INTO transactions (txn_type, channel, currency_code, amount) VALUES ('INTEREST', 'SYSTEM', 'XTS', 1.25)]');
  rejects('amount of 0 (domain positive_money_d)',
    q'[INSERT INTO transactions (txn_type, channel, currency_code, amount) VALUES ('INTEREST', 'SYSTEM', 'XTS', 0)]',
    'POSITIVE_MONEY_D_CK');
  rejects('transaction type not in the list (domain txn_type_d)',
    q'[INSERT INTO transactions (txn_type, channel, currency_code, amount) VALUES ('GIFT', 'SYSTEM', 'XTS', 10)]',
    'TXN_TYPE_D_LIST_CK');
  rejects('maker approving their own transaction',
    'UPDATE transactions SET checked_by = ' || v_maker || ', checked_at = SYSTIMESTAMP WHERE txn_id = ' || v_txn,
    'TRANSACTIONS_CHECKER_CK');
  rejects('REJECTED without a reason',
    'UPDATE transactions SET status = ''REJECTED'', checked_by = ' || v_checker || ', checked_at = SYSTIMESTAMP WHERE txn_id = ' || v_txn,
    'TRANSACTIONS_REJECTED_CK');
  rejects('REJECTED without the checker who rejected it',
    'UPDATE transactions SET status = ''REJECTED'', rejection_reason = ''Signature mismatch'' WHERE txn_id = ' || v_txn,
    'TRANSACTIONS_REJECTED_CK');
  rejects('POSTED without a posting time',
    'UPDATE transactions SET status = ''POSTED'' WHERE txn_id = ' || v_txn, 'TRANSACTIONS_POSTED_CK');
  rejects('PENDING with a posting time',
    'UPDATE transactions SET posted_at = SYSTIMESTAMP WHERE txn_id = ' || v_txn, 'TRANSACTIONS_POSTED_CK');
  rejects('REVERSAL that names no transaction',
    q'[INSERT INTO transactions (txn_type, channel, currency_code, amount) VALUES ('REVERSAL', 'SYSTEM', 'XTS', 10)]',
    'TRANSACTIONS_REVERSAL_CK');
  rejects('deposit that claims to reverse another transaction',
    q'[INSERT INTO transactions (txn_type, channel, currency_code, amount, reverses_txn_id) VALUES ('FEE', 'SYSTEM', 'XTS', 10, ]' || v_txn || ')',
    'TRANSACTIONS_REVERSAL_CK');
  rejects('transaction reversing itself',
    'UPDATE transactions SET txn_type = ''REVERSAL'', reverses_txn_id = txn_id WHERE txn_id = ' || v_txn,
    'TRANSACTIONS_NOT_SELF_CK');

  -- ------------------------------------------------------------ ledger lines
  rejects('ledger line on a PENDING transaction (assertion)',
    line_sql(v_txn, 1, v_vault, 'DR', 500), 'LEDGER_ENTRIES_POSTED_AS');
  -- Post the deposit: the cash goes into the vault (debit), the customer is owed it (credit).
  UPDATE transactions SET status = 'POSTED', posted_at = SYSTIMESTAMP WHERE txn_id = v_txn;
  accepts('line 1: debit the vault 500',    line_sql(v_txn, 1, v_vault, 'DR', 500));
  accepts('line 2: credit the customer 500', line_sql(v_txn, 2, v_acc, 'CR', 500));
  accepts_at_commit('posted deposit with its two lines');
  rejects('line with direction XX', line_sql(v_txn, 3, v_fee, 'XX', 1), 'LEDGER_ENTRIES_DIRECTION_CK');
  rejects('line with a negative amount', line_sql(v_txn, 3, v_fee, 'CR', -1), 'POSITIVE_MONEY_D_CK');
  rejects('two lines with the same line number', line_sql(v_txn, 2, v_fee, 'CR', 1), 'LEDGER_ENTRIES_LINE_UK');
  rejects('line on an account in another currency (assertion)',
    line_sql(v_txn, 3, v_vault_xxx, 'DR', 1), 'LEDGER_ENTRIES_CURRENCY_AS');
  rejects('putting a transaction that has lines back to PENDING (assertion)',
    'UPDATE transactions SET status = ''PENDING'', posted_at = NULL WHERE txn_id = ' || v_txn, 'LEDGER_ENTRIES_POSTED_AS');

  SAVEPOINT before_no_lines;
  INSERT INTO transactions (txn_type, channel, currency_code, amount, status, posted_at)
    VALUES ('FEE', 'SYSTEM', 'XTS', 5, 'POSTED', SYSTIMESTAMP) RETURNING txn_id INTO v_txn2;
  rejects_at_commit('POSTED transaction with no ledger lines', 'TRANSACTIONS_LINES_AS');
  ROLLBACK TO before_no_lines;

  -- Reversal: mistakes are never edited away; a REVERSAL posts the opposite lines.
  UPDATE transactions SET status = 'REVERSED' WHERE txn_id = v_txn;
  rejects_at_commit('REVERSED transaction with no reversal', 'TRANSACTIONS_REVERSAL_AS');
  INSERT INTO transactions (txn_type, channel, branch_id, currency_code, amount, narration, initiated_by, checked_by, checked_at,
                            status, posted_at, reverses_txn_id)
    VALUES ('REVERSAL', 'BRANCH', v_branch, 'XTS', 500, 'Reversal: wrong account', v_maker, v_checker, SYSTIMESTAMP,
            'POSTED', SYSTIMESTAMP, v_txn) RETURNING txn_id INTO v_rev;
  EXECUTE IMMEDIATE line_sql(v_rev, 1, v_acc, 'DR', 500);
  EXECUTE IMMEDIATE line_sql(v_rev, 2, v_vault, 'CR', 500);
  accepts_at_commit('REVERSED transaction with its posted reversal');
  rejects('reversing the same transaction twice',
    q'[INSERT INTO transactions (txn_type, channel, currency_code, amount, reverses_txn_id) VALUES ('REVERSAL', 'SYSTEM', 'XTS', 500, ]' || v_txn || ')',
    'TRANSACTIONS_REVERSES_UK');

  -- ------------------------------------------------------- dictionary checks
  SELECT COUNT(*) INTO v_count FROM dba_mviews m
   WHERE m.owner = 'WELBANK' AND m.mview_name = 'LEDGER_TXN_TOTALS_MV'
     AND m.refresh_mode = 'COMMIT' AND m.refresh_method = 'FAST'
     AND EXISTS (SELECT 1 FROM dba_constraints c
                  WHERE c.owner = m.owner AND c.table_name = m.mview_name
                    AND c.constraint_name = 'LEDGER_TXN_BALANCED_CK' AND c.status = 'ENABLED');
  check_that('debits = credits: ledger_txn_totals_mv refreshes FAST ON COMMIT and has ledger_txn_balanced_ck', v_count = 1);
  SELECT COUNT(*) INTO v_count FROM dba_assertions
   WHERE owner = 'WELBANK' AND status = 'ENABLED' AND validated = 'VALIDATED';
  check_that('10 assertions enabled and validated (found ' || v_count || ')', v_count = 10);

  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
  ROLLBACK;
END;
/
