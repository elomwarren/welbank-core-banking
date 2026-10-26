-- =============================================================================
-- 0005_ledger_commit_test.sql — the "debits = credits" rule (changelog 0005),
-- which Oracle checks when a transaction COMMITs.
--
-- Unlike the other test files, this one MUST commit to reach the rule:
--   1. an unbalanced transaction: its COMMIT must fail, and the failed COMMIT
--      rolls everything back by itself;
--   2. a balanced transaction: its COMMIT must succeed;
--   3. changing a committed line so the transaction no longer balances: that
--      COMMIT must fail too, leaving the line as it was;
--   4. clean-up: the rows of step 2 are deleted and the deletion committed.
-- Fixtures use the ISO 4217 test currency XTS and the branch code T-CMT;
-- leftovers of an interrupted earlier run are removed first. Identity and
-- sequence numbers used by the test are not given back (gaps are harmless).
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v_vault   NUMBER; v_capital NUMBER; v_txn NUMBER;
  v_count   PLS_INTEGER;
  v_amount  NUMBER;

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

  -- COMMIT, expecting the balance rule to refuse it: ORA-12008 (refresh of the
  -- totals view failed) caused by ledger_txn_balanced_ck.
  PROCEDURE commit_rejected(p_name VARCHAR2) IS
  BEGIN
    COMMIT;
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> COMMIT succeeded');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -12008 AND INSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 'LEDGER_TXN_BALANCED_CK') > 0 THEN
      passed := passed + 1;
      DBMS_OUTPUT.PUT_LINE('PASS  rejects  ' || p_name);
    ELSE
      failed := failed + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> expected ORA-12008 + LEDGER_TXN_BALANCED_CK, got ' || SQLERRM);
    END IF;
  END;

  -- Removes every row this file creates, and commits.
  PROCEDURE clean_up IS
  BEGIN
    DELETE FROM ledger_entries WHERE txn_id IN (SELECT txn_id FROM transactions WHERE currency_code = 'XTS');
    DELETE FROM transactions WHERE currency_code = 'XTS';
    DELETE FROM accounts     WHERE currency_code = 'XTS';
    DELETE FROM branches     WHERE branch_code = 'T-CMT';
    DELETE FROM regions      WHERE region_name = 'Test region (commit test)';
    DELETE FROM currencies   WHERE currency_code = 'XTS';
    COMMIT;
  END;

  -- A branch with a vault and a capital account, and a posted transaction
  -- (lines added by the caller). Internal accounts only: no customer needed.
  PROCEDURE create_fixtures IS
    v_region NUMBER; v_branch NUMBER;
  BEGIN
    INSERT INTO currencies (currency_code, currency_name) VALUES ('XTS', 'Test currency XTS');
    INSERT INTO regions (region_name) VALUES ('Test region (commit test)') RETURNING region_id INTO v_region;
    INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
      VALUES ('T-CMT', 'Test branch (commit test)', v_region, '+233200000901', DATE '2020-01-01') RETURNING branch_id INTO v_branch;
    INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit)
      VALUES ('INTERNAL', 'VAULT_CASH', v_branch, 'XTS', 'Vault cash (commit test)', 'ACTIVE', FALSE) RETURNING account_id INTO v_vault;
    INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit)
      VALUES ('INTERNAL', 'CAPITAL', v_branch, 'XTS', 'Share capital (commit test)', 'ACTIVE', FALSE) RETURNING account_id INTO v_capital;
    -- Money paid in by the bank's owners: it goes into the vault (debit) and
    -- is owed to them as capital (credit).
    INSERT INTO transactions (txn_type, channel, currency_code, amount, narration, status, posted_at)
      VALUES ('TRANSFER', 'SYSTEM', 'XTS', 100, 'Capital paid into the vault (commit test)', 'POSTED', SYSTIMESTAMP)
      RETURNING txn_id INTO v_txn;
  END;
BEGIN
  clean_up;

  -- 1. Unbalanced: debit 100, credit 90.
  create_fixtures;
  INSERT INTO ledger_entries (txn_id, line_no, account_id, direction, amount, balance_after) VALUES (v_txn, 1, v_vault,   'DR', 100, 100);
  INSERT INTO ledger_entries (txn_id, line_no, account_id, direction, amount, balance_after) VALUES (v_txn, 2, v_capital, 'CR',  90,  90);
  commit_rejected('COMMIT of an unbalanced transaction (debit 100, credit 90)');
  SELECT COUNT(*) INTO v_count FROM branches WHERE branch_code = 'T-CMT';
  check_that('the failed COMMIT rolled back the whole transaction (no fixture left)', v_count = 0);

  -- 2. Balanced: debit 100, credit 100.
  create_fixtures;
  INSERT INTO ledger_entries (txn_id, line_no, account_id, direction, amount, balance_after) VALUES (v_txn, 1, v_vault,   'DR', 100, 100);
  INSERT INTO ledger_entries (txn_id, line_no, account_id, direction, amount, balance_after) VALUES (v_txn, 2, v_capital, 'CR', 100, 100);
  BEGIN
    COMMIT;
    check_that('COMMIT of a balanced transaction (debit 100, credit 100)', TRUE);
  EXCEPTION WHEN OTHERS THEN
    check_that('COMMIT of a balanced transaction (debit 100, credit 100)  -> ' || SQLERRM, FALSE);
  END;
  SELECT COUNT(*) INTO v_count FROM ledger_txn_totals_mv WHERE txn_id = v_txn AND net_amount = 0 AND line_count = 2;
  check_that('totals view refreshed by the COMMIT: net 0 over 2 lines', v_count = 1);

  -- 3. Editing history: change the committed debit to 150.
  UPDATE ledger_entries SET amount = 150 WHERE txn_id = v_txn AND line_no = 1;
  commit_rejected('COMMIT of a change that unbalances a committed transaction');
  SELECT amount INTO v_amount FROM ledger_entries WHERE txn_id = v_txn AND line_no = 1;
  check_that('the committed line is unchanged (still 100)', v_amount = 100);

  -- 4. Clean-up (a whole balanced transaction may be removed: still 0).
  clean_up;
  SELECT COUNT(*) INTO v_count FROM ledger_txn_totals_mv WHERE txn_id = v_txn;
  check_that('clean-up committed; the totals view dropped the transaction', v_count = 0);

  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
EXCEPTION WHEN OTHERS THEN
  -- An unexpected error: undo the current work, remove committed fixtures,
  -- and re-raise so run_tests.sh reports the file as BROKEN.
  ROLLBACK;
  clean_up;
  RAISE;
END;
/
