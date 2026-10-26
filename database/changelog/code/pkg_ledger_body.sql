--liquibase formatted sql

--changeset elomwarren:code-pkg-ledger-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_ledger AS

  -- The accounts touched by one posting, keyed by account_id padded to 12
  -- digits. An associative array indexed by VARCHAR2 keeps its keys sorted,
  -- so walking it with FIRST/NEXT visits the accounts in ascending account_id.
  TYPE t_account_map IS TABLE OF accounts%ROWTYPE INDEX BY VARCHAR2(12);
  TYPE t_amounts IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  FUNCTION map_key (p_account_id IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN LPAD(p_account_id, 12, '0');
  END map_key;

  -- How a line changes an account's balance: up on the account's normal side
  -- (debit for vault cash, credit for a customer deposit), down on the other.
  FUNCTION balance_change (p_normal_side IN VARCHAR2, p_direction IN VARCHAR2, p_amount IN NUMBER) RETURN NUMBER IS
  BEGIN
    IF (p_direction = 'DR' AND p_normal_side = 'DEBIT') OR (p_direction = 'CR' AND p_normal_side = 'CREDIT') THEN
      RETURN p_amount;
    END IF;
    RETURN -p_amount;
  END balance_change;

  FUNCTION new_line (p_account_id IN NUMBER, p_direction IN VARCHAR2, p_amount IN NUMBER) RETURN t_line IS
    v_line t_line;
  BEGIN
    v_line.account_id := p_account_id;
    v_line.direction  := p_direction;
    v_line.amount     := p_amount;
    RETURN v_line;
  END new_line;

  PROCEDURE check_amount (p_amount IN NUMBER, p_currency IN VARCHAR2) IS
    v_minor_units currencies.minor_units%TYPE;
  BEGIN
    SELECT minor_units INTO v_minor_units FROM currencies WHERE currency_code = p_currency;
    IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> ROUND(p_amount, v_minor_units) THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_amount,
        'Invalid amount ' || NVL(TO_CHAR(p_amount), 'NULL') || ' ' || p_currency
        || ': it must be positive, with at most ' || v_minor_units || ' decimals');
    END IF;
  END check_amount;

  FUNCTION internal_account_id (p_branch_id IN NUMBER, p_purpose IN VARCHAR2, p_currency IN VARCHAR2) RETURN accounts.account_id%TYPE IS
    v_id accounts.account_id%TYPE;
  BEGIN
    SELECT account_id INTO v_id
      FROM accounts
     WHERE account_class = 'INTERNAL' AND internal_purpose = p_purpose
       AND branch_id = p_branch_id AND currency_code = p_currency;
    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      IF p_purpose = 'VAULT_CASH' THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_no_vault, 'Your branch holds no cash in ' || p_currency);
      END IF;
      RAISE_APPLICATION_ERROR(pkg_errors.c_internal_error,
        'Set-up error: branch ' || p_branch_id || ' has no ' || p_purpose || ' account in ' || p_currency);
  END internal_account_id;

  FUNCTION txn_json (p_txn_id IN NUMBER) RETURN VARCHAR2 IS
    v_json VARCHAR2(4000);
  BEGIN
    SELECT JSON_OBJECT('txn_ref' VALUE txn_ref, 'txn_type' VALUE txn_type, 'amount' VALUE amount,
                       'currency' VALUE currency_code, 'status' VALUE status
                       RETURNING VARCHAR2(4000))
      INTO v_json
      FROM transactions WHERE txn_id = p_txn_id;
    RETURN v_json;
  END txn_json;

  PROCEDURE new_transaction (
    p_txn_type     IN  VARCHAR2,
    p_currency     IN  VARCHAR2,
    p_amount       IN  NUMBER,
    p_narration    IN  VARCHAR2,
    p_initiated_by IN  NUMBER,
    p_txn_id       OUT NUMBER,
    p_txn_ref      OUT VARCHAR2,
    p_checked_by   IN  NUMBER   DEFAULT NULL,
    p_reverses     IN  NUMBER   DEFAULT NULL,
    p_channel      IN  VARCHAR2 DEFAULT 'BRANCH',
    p_branch_id    IN  NUMBER   DEFAULT NULL,
    p_value_date   IN  DATE     DEFAULT NULL)
  IS
    v_branch_id branches.branch_id%TYPE := p_branch_id;
  BEGIN
    IF p_channel = 'BRANCH' AND v_branch_id IS NULL THEN
      v_branch_id := pkg_session.branch_id;
    END IF;
    INSERT INTO transactions (txn_type, channel, branch_id, currency_code, amount, narration,
                              initiated_by, checked_by, checked_at, reverses_txn_id, value_date)
    VALUES (p_txn_type, p_channel, v_branch_id, p_currency, p_amount, SUBSTR(p_narration, 1, 140),
            p_initiated_by, p_checked_by, CASE WHEN p_checked_by IS NOT NULL THEN SYSTIMESTAMP END, p_reverses,
            p_value_date)
    RETURNING txn_id, txn_ref INTO p_txn_id, p_txn_ref;
  END new_transaction;

  PROCEDURE apply_lines (
    p_txn_id     IN NUMBER,
    p_lines      IN t_lines,
    p_write      IN BOOLEAN,
    p_correction IN BOOLEAN DEFAULT FALSE)
  IS
    v_accounts t_account_map;
    v_after    t_amounts;
    v_key      VARCHAR2(12);
    v_debits   NUMBER := 0;
    v_credits  NUMBER := 0;
    v_change   NUMBER;
    r          accounts%ROWTYPE;
  BEGIN
    -- 1. Debits must equal credits. The COMMIT-time rule (ledger_txn_totals_mv)
    --    would also refuse it, but later and with a less helpful error.
    FOR i IN 1 .. p_lines.COUNT LOOP
      IF p_lines(i).direction = 'DR' THEN
        v_debits := v_debits + p_lines(i).amount;
      ELSE
        v_credits := v_credits + p_lines(i).amount;
      END IF;
    END LOOP;
    IF p_lines.COUNT < 2 OR v_debits <> v_credits THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_internal_error,
        'Unbalanced posting: debits ' || v_debits || ', credits ' || v_credits);
    END IF;

    -- 2. Read each account once (locked when writing), in ascending account_id,
    --    so two postings on the same accounts can never deadlock.
    FOR i IN 1 .. p_lines.COUNT LOOP
      v_accounts(map_key(p_lines(i).account_id)).account_id := p_lines(i).account_id;
    END LOOP;
    v_key := v_accounts.FIRST;
    WHILE v_key IS NOT NULL LOOP
      IF p_write THEN
        SELECT * INTO v_accounts(v_key) FROM accounts WHERE account_id = TO_NUMBER(v_key) FOR UPDATE;
      ELSE
        SELECT * INTO v_accounts(v_key) FROM accounts WHERE account_id = TO_NUMBER(v_key);
      END IF;
      v_key := v_accounts.NEXT(v_key);
    END LOOP;

    -- 3. Check every line, keeping the new balances in memory. Checking under
    --    the lock is what makes it safe: nobody can spend the same money
    --    between the check and the write.
    FOR i IN 1 .. p_lines.COUNT LOOP
      v_key := map_key(p_lines(i).account_id);
      r := v_accounts(v_key);
      IF r.account_class = 'CUSTOMER' AND NOT p_correction THEN
        IF p_lines(i).direction = 'DR' AND (r.status <> 'ACTIVE' OR r.post_no_debit) THEN
          RAISE_APPLICATION_ERROR(pkg_errors.c_debits_blocked,
            'Account ' || r.account_no || ' does not allow withdrawals or transfers out ('
            || CASE WHEN r.status <> 'ACTIVE' THEN 'it is ' || r.status
                    ELSE 'deposits only until it is approved and every holder''s identity is verified' END
            || ')');
        ELSIF p_lines(i).direction = 'CR' AND r.status NOT IN ('ACTIVE', 'DORMANT', 'FROZEN') THEN
          RAISE_APPLICATION_ERROR(pkg_errors.c_account_not_open,
            'Account ' || r.account_no || ' is ' || r.status || ' and cannot receive money');
        END IF;
      END IF;

      v_change := balance_change(r.normal_side, p_lines(i).direction, p_lines(i).amount);
      r.ledger_balance    := r.ledger_balance + v_change;
      r.available_balance := r.available_balance + v_change;

      IF r.account_class = 'CUSTOMER' AND v_change < 0 AND r.available_balance < -r.overdraft_limit THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_insufficient_funds,
          'Insufficient funds in ' || r.account_no || ': available '
          || TO_CHAR(r.available_balance - v_change, 'FM999999999990.00')
          || CASE WHEN r.overdraft_limit > 0 THEN ' plus overdraft ' || TO_CHAR(r.overdraft_limit, 'FM999999999990.00') END
          || ', needed ' || TO_CHAR(p_lines(i).amount, 'FM999999999990.00'));
      ELSIF r.internal_purpose = 'VAULT_CASH' AND r.ledger_balance < 0 THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_insufficient_vault,
          'Not enough cash in the vault: it holds '
          || TO_CHAR(r.ledger_balance - v_change, 'FM999999999990.00')
          || ', needed ' || TO_CHAR(p_lines(i).amount, 'FM999999999990.00'));
      END IF;

      v_accounts(v_key) := r;
      v_after(i) := r.ledger_balance;
    END LOOP;

    -- 4. Every check passed: write. POSTED first, because ledger lines may only
    --    belong to a posted transaction (assertion ledger_entries_posted_as).
    IF p_write THEN
      UPDATE transactions SET status = 'POSTED', posted_at = SYSTIMESTAMP WHERE txn_id = p_txn_id;
      FOR i IN 1 .. p_lines.COUNT LOOP
        INSERT INTO ledger_entries (txn_id, line_no, account_id, direction, amount, balance_after)
        VALUES (p_txn_id, i, p_lines(i).account_id, p_lines(i).direction, p_lines(i).amount, v_after(i));
      END LOOP;
      v_key := v_accounts.FIRST;
      WHILE v_key IS NOT NULL LOOP
        UPDATE accounts
           SET ledger_balance    = v_accounts(v_key).ledger_balance,
               available_balance = v_accounts(v_key).available_balance,
               last_activity_at  = SYSTIMESTAMP
         WHERE account_id = v_accounts(v_key).account_id;
        v_key := v_accounts.NEXT(v_key);
      END LOOP;
    END IF;
  END apply_lines;

END pkg_ledger;
/
--rollback DROP PACKAGE BODY pkg_ledger
