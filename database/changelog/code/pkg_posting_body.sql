--liquibase formatted sql

--changeset elomwarren:code-pkg-posting-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_posting AS

  -- One ledger line to write.
  TYPE t_line IS RECORD (
    account_id  accounts.account_id%TYPE,
    direction   ledger_entries.direction%TYPE,
    amount      ledger_entries.amount%TYPE);
  TYPE t_lines IS TABLE OF t_line INDEX BY PLS_INTEGER;

  -- The accounts touched by one posting, keyed by account_id padded to 12
  -- digits. An associative array indexed by VARCHAR2 keeps its keys sorted,
  -- so walking it with FIRST/NEXT visits the accounts in ascending account_id.
  TYPE t_account_map IS TABLE OF accounts%ROWTYPE INDEX BY VARCHAR2(12);

  TYPE t_amounts IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  -- ------------------------------------------------------------------ helpers

  FUNCTION map_key (p_account_id IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN LPAD(p_account_id, 12, '0');
  END map_key;

  FUNCTION new_line (p_account_id IN NUMBER, p_direction IN VARCHAR2, p_amount IN NUMBER) RETURN t_line IS
    v_line t_line;
  BEGIN
    v_line.account_id := p_account_id;
    v_line.direction  := p_direction;
    v_line.amount     := p_amount;
    RETURN v_line;
  END new_line;

  -- How a line changes an account's balance: up on the account's normal side
  -- (debit for vault cash, credit for a customer deposit), down on the other.
  FUNCTION balance_change (p_normal_side IN VARCHAR2, p_direction IN VARCHAR2, p_amount IN NUMBER) RETURN NUMBER IS
  BEGIN
    IF (p_direction = 'DR' AND p_normal_side = 'DEBIT') OR (p_direction = 'CR' AND p_normal_side = 'CREDIT') THEN
      RETURN p_amount;
    END IF;
    RETURN -p_amount;
  END balance_change;

  FUNCTION customer_account_id (p_account_no IN VARCHAR2) RETURN accounts.account_id%TYPE IS
    v_id accounts.account_id%TYPE;
  BEGIN
    SELECT account_id INTO v_id
      FROM accounts
     WHERE account_no = p_account_no AND account_class = 'CUSTOMER';
    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_account_not_found, 'Customer account ' || p_account_no || ' does not exist');
  END customer_account_id;

  FUNCTION currency_of (p_account_id IN NUMBER) RETURN accounts.currency_code%TYPE IS
    v_currency accounts.currency_code%TYPE;
  BEGIN
    SELECT currency_code INTO v_currency FROM accounts WHERE account_id = p_account_id;
    RETURN v_currency;
  END currency_of;

  -- The vault cash account of a branch, in one currency.
  FUNCTION vault_id (p_branch_id IN NUMBER, p_currency IN VARCHAR2) RETURN accounts.account_id%TYPE IS
    v_id accounts.account_id%TYPE;
  BEGIN
    SELECT account_id INTO v_id
      FROM accounts
     WHERE account_class = 'INTERNAL' AND internal_purpose = 'VAULT_CASH'
       AND branch_id = p_branch_id AND currency_code = p_currency;
    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_no_vault, 'Your branch holds no cash in ' || p_currency);
  END vault_id;

  -- Positive, and no more decimals than the currency has (2 for GHS: pesewas).
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

  PROCEDURE check_reason (p_reason IN VARCHAR2) IS
  BEGIN
    IF TRIM(p_reason) IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_reason_required, 'Give a reason');
    END IF;
  END check_reason;

  -- A small JSON summary of a transaction, for the audit trail.
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

  -- The planned lines of a pending transaction, stored in its approval request
  -- as {"lines": [{"account_id": 7, "direction": "DR", "amount": 500}, ...]}.
  FUNCTION lines_json (p_lines IN t_lines) RETURN VARCHAR2 IS
    v_root  JSON_OBJECT_T := JSON_OBJECT_T();
    v_array JSON_ARRAY_T  := JSON_ARRAY_T();
    v_line  JSON_OBJECT_T;
  BEGIN
    FOR i IN 1 .. p_lines.COUNT LOOP
      v_line := JSON_OBJECT_T();
      v_line.put('account_id', p_lines(i).account_id);
      v_line.put('direction',  p_lines(i).direction);
      v_line.put('amount',     p_lines(i).amount);
      v_array.append(v_line);
    END LOOP;
    v_root.put('lines', v_array);
    RETURN v_root.to_string;
  END lines_json;

  FUNCTION lines_of_request (p_request_id IN NUMBER) RETURN t_lines IS
    v_lines t_lines;
  BEGIN
    SELECT j.account_id, j.direction, j.amount
      BULK COLLECT INTO v_lines
      FROM approval_requests r,
           JSON_TABLE(r.payload, '$.lines[*]'
             COLUMNS (line_no    FOR ORDINALITY,
                      account_id NUMBER(12)    PATH '$.account_id',
                      direction  VARCHAR2(2)   PATH '$.direction',
                      amount     NUMBER(15, 2) PATH '$.amount')) j
     WHERE r.request_id = p_request_id
     ORDER BY j.line_no;
    RETURN v_lines;
  END lines_of_request;

  -- --------------------------------------------------------- the posting core

  -- Checks the lines against the accounts and, with p_write, writes them.
  --
  -- With p_write TRUE: locks every account (SELECT ... FOR UPDATE, ascending
  -- account_id, so two postings on the same accounts can never deadlock),
  -- runs every check BEFORE writing anything, then sets the transaction
  -- POSTED, inserts the lines with their balance_after and updates the
  -- balances. Checking under the lock is what makes it safe: nobody can spend
  -- the same money between the check and the write.
  -- With p_write FALSE: the same checks, without locks or writes (used to
  -- refuse at once a request that could never be posted).
  -- p_correction (reversals) skips the account status checks, so a mistake
  -- can be corrected on a frozen account, but never the balance floors.
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

    -- 2. Read each account once (locked when writing), in ascending account_id.
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

    -- 3. Check every line, keeping the new balances in memory.
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

  -- A new PENDING transaction at the caller's branch.
  PROCEDURE new_transaction (
    p_txn_type     IN  VARCHAR2,
    p_currency     IN  VARCHAR2,
    p_amount       IN  NUMBER,
    p_narration    IN  VARCHAR2,
    p_initiated_by IN  NUMBER,
    p_txn_id       OUT NUMBER,
    p_txn_ref      OUT VARCHAR2,
    p_checked_by   IN  NUMBER DEFAULT NULL,
    p_reverses     IN  NUMBER DEFAULT NULL)
  IS
  BEGIN
    INSERT INTO transactions (txn_type, channel, branch_id, currency_code, amount, narration,
                              initiated_by, checked_by, checked_at, reverses_txn_id)
    VALUES (p_txn_type, 'BRANCH', pkg_session.branch_id, p_currency, p_amount, SUBSTR(p_narration, 1, 140),
            p_initiated_by, p_checked_by, CASE WHEN p_checked_by IS NOT NULL THEN SYSTIMESTAMP END, p_reverses)
    RETURNING txn_id, txn_ref INTO p_txn_id, p_txn_ref;
  END new_transaction;

  -- Common path of deposits, withdrawals and transfers: post at once when the
  -- amount is within the maker's limit, otherwise park it for a checker.
  FUNCTION submit (
    p_me        IN NUMBER,
    p_txn_type  IN VARCHAR2,
    p_currency  IN VARCHAR2,
    p_amount    IN NUMBER,
    p_narration IN VARCHAR2,
    p_lines     IN t_lines) RETURN VARCHAR2
  IS
    v_txn_id  transactions.txn_id%TYPE;
    v_txn_ref transactions.txn_ref%TYPE;
    v_payload VARCHAR2(4000);
  BEGIN
    check_amount(p_amount, p_currency);
    -- Refuse at once what could never be posted (closed account, no funds, ...).
    apply_lines(NULL, p_lines, p_write => FALSE);
    new_transaction(p_txn_type, p_currency, p_amount, p_narration, p_me, v_txn_id, v_txn_ref);

    IF p_amount <= pkg_session.limit_for(p_txn_type, p_currency) THEN
      apply_lines(v_txn_id, p_lines, p_write => TRUE);
      pkg_audit.log_event('TXN_POSTED', 'TRANSACTIONS', v_txn_ref, NULL, txn_json(v_txn_id));
    ELSE
      -- A private package function cannot be called inside a SQL statement
      -- (PLS-00231), so its result goes through a variable.
      v_payload := lines_json(p_lines);
      INSERT INTO approval_requests (request_type, txn_id, payload, reason, requested_by)
      VALUES ('TXN_APPROVAL', v_txn_id, v_payload, 'Amount above the maker''s limit', p_me);
      pkg_audit.log_event('TXN_AWAITING_APPROVAL', 'TRANSACTIONS', v_txn_ref, NULL, txn_json(v_txn_id));
    END IF;
    RETURN v_txn_ref;
  END submit;

  -- The transaction with this reference, locked; it must be PENDING.
  FUNCTION lock_pending (p_txn_ref IN VARCHAR2) RETURN transactions%ROWTYPE IS
    t transactions%ROWTYPE;
  BEGIN
    SELECT * INTO t FROM transactions WHERE txn_ref = p_txn_ref FOR UPDATE;
    IF t.status <> 'PENDING' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_txn_not_pending, 'Transaction ' || p_txn_ref || ' is ' || t.status || ', not PENDING');
    END IF;
    RETURN t;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_txn_not_found, 'Transaction ' || p_txn_ref || ' does not exist');
  END lock_pending;

  -- The PENDING approval request of this type for a transaction, locked.
  FUNCTION pending_request (p_request_type IN VARCHAR2, p_txn_id IN NUMBER) RETURN approval_requests.request_id%TYPE IS
    v_id approval_requests.request_id%TYPE;
  BEGIN
    SELECT request_id INTO v_id
      FROM approval_requests
     WHERE request_type = p_request_type AND txn_id = p_txn_id AND status = 'PENDING'
       FOR UPDATE;
    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_request_not_found, 'No pending ' || p_request_type || ' request for this transaction');
  END pending_request;

  PROCEDURE check_checker (p_me IN NUMBER, p_maker IN NUMBER) IS
  BEGIN
    IF p_me = p_maker THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_own_approval, 'You cannot approve or reject your own request (maker-checker)');
    END IF;
  END check_checker;

  PROCEDURE check_limit (p_txn_type IN VARCHAR2, p_currency IN VARCHAR2, p_amount IN NUMBER) IS
    v_limit NUMBER := pkg_session.limit_for(p_txn_type, p_currency);
  BEGIN
    IF p_amount > v_limit THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_over_your_limit,
        'Your limit for ' || p_txn_type || ' in ' || p_currency || ' is ' || TO_CHAR(v_limit, 'FM999999999990.00')
        || '; this needs ' || TO_CHAR(p_amount, 'FM999999999990.00'));
    END IF;
  END check_limit;

  -- ------------------------------------------------------------ public calls

  FUNCTION cash_deposit (p_account_no IN VARCHAR2, p_amount IN NUMBER, p_narration IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    v_me       employees.employee_id%TYPE := pkg_session.employee_id;   -- first: non-employees learn nothing
    v_account  accounts.account_id%TYPE   := customer_account_id(p_account_no);
    v_currency accounts.currency_code%TYPE := currency_of(v_account);
    v_lines    t_lines;
  BEGIN
    v_lines(1) := new_line(vault_id(pkg_session.branch_id, v_currency), 'DR', p_amount);
    v_lines(2) := new_line(v_account, 'CR', p_amount);
    RETURN submit(v_me, 'CASH_DEPOSIT', v_currency, p_amount, NVL(p_narration, 'Cash deposit'), v_lines);
  END cash_deposit;

  FUNCTION cash_withdrawal (p_account_no IN VARCHAR2, p_amount IN NUMBER, p_narration IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    v_me       employees.employee_id%TYPE := pkg_session.employee_id;
    v_account  accounts.account_id%TYPE   := customer_account_id(p_account_no);
    v_currency accounts.currency_code%TYPE := currency_of(v_account);
    v_lines    t_lines;
  BEGIN
    v_lines(1) := new_line(v_account, 'DR', p_amount);
    v_lines(2) := new_line(vault_id(pkg_session.branch_id, v_currency), 'CR', p_amount);
    RETURN submit(v_me, 'CASH_WITHDRAWAL', v_currency, p_amount, NVL(p_narration, 'Cash withdrawal'), v_lines);
  END cash_withdrawal;

  FUNCTION transfer (p_from_account_no IN VARCHAR2, p_to_account_no IN VARCHAR2, p_amount IN NUMBER,
                     p_narration IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    v_me    employees.employee_id%TYPE := pkg_session.employee_id;
    v_from  accounts.account_id%TYPE   := customer_account_id(p_from_account_no);
    v_to    accounts.account_id%TYPE   := customer_account_id(p_to_account_no);
    v_lines t_lines;
  BEGIN
    IF v_from = v_to THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_same_account, 'Cannot transfer from an account to itself');
    END IF;
    IF currency_of(v_from) <> currency_of(v_to) THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_currency_mismatch,
        'Accounts are in different currencies (' || currency_of(v_from) || ' and ' || currency_of(v_to) || ')');
    END IF;
    v_lines(1) := new_line(v_from, 'DR', p_amount);
    v_lines(2) := new_line(v_to, 'CR', p_amount);
    RETURN submit(v_me, 'TRANSFER', currency_of(v_from), p_amount,
                  NVL(p_narration, 'Transfer to ' || p_to_account_no), v_lines);
  END transfer;

  FUNCTION transaction_status (p_txn_ref IN VARCHAR2) RETURN VARCHAR2 IS
    v_status transactions.status%TYPE;
  BEGIN
    SELECT status INTO v_status FROM transactions WHERE txn_ref = p_txn_ref;
    RETURN v_status;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_txn_not_found, 'Transaction ' || p_txn_ref || ' does not exist');
  END transaction_status;

  PROCEDURE approve_transaction (p_txn_ref IN VARCHAR2) IS
    v_me      employees.employee_id%TYPE := pkg_session.employee_id;
    t         transactions%ROWTYPE;
    v_request approval_requests.request_id%TYPE;
  BEGIN
    t := lock_pending(p_txn_ref);
    check_checker(v_me, t.initiated_by);
    check_limit(t.txn_type, t.currency_code, t.amount);   -- the checker must have authority for the amount
    v_request := pending_request('TXN_APPROVAL', t.txn_id);
    UPDATE transactions SET checked_by = v_me, checked_at = SYSTIMESTAMP WHERE txn_id = t.txn_id;
    -- Funds are checked again now, under lock: they may have changed since the request.
    apply_lines(t.txn_id, lines_of_request(v_request), p_write => TRUE);
    UPDATE approval_requests SET status = 'APPROVED', decided_by = v_me, decided_at = SYSTIMESTAMP
     WHERE request_id = v_request;
    pkg_audit.log_event('TXN_APPROVED', 'TRANSACTIONS', p_txn_ref, '{"status":"PENDING"}', txn_json(t.txn_id));
  END approve_transaction;

  PROCEDURE reject_transaction (p_txn_ref IN VARCHAR2, p_reason IN VARCHAR2) IS
    v_me      employees.employee_id%TYPE := pkg_session.employee_id;
    t         transactions%ROWTYPE;
    v_request approval_requests.request_id%TYPE;
  BEGIN
    check_reason(p_reason);
    t := lock_pending(p_txn_ref);
    check_checker(v_me, t.initiated_by);
    v_request := pending_request('TXN_APPROVAL', t.txn_id);
    UPDATE transactions
       SET status = 'REJECTED', rejection_reason = SUBSTR(p_reason, 1, 200), checked_by = v_me, checked_at = SYSTIMESTAMP
     WHERE txn_id = t.txn_id;
    UPDATE approval_requests
       SET status = 'REJECTED', decided_by = v_me, decided_at = SYSTIMESTAMP, decision_note = SUBSTR(p_reason, 1, 400)
     WHERE request_id = v_request;
    pkg_audit.log_event('TXN_REJECTED', 'TRANSACTIONS', p_txn_ref, '{"status":"PENDING"}', txn_json(t.txn_id));
  END reject_transaction;

  FUNCTION request_reversal (p_txn_ref IN VARCHAR2, p_reason IN VARCHAR2) RETURN NUMBER IS
    v_me      employees.employee_id%TYPE := pkg_session.employee_id;
    t         transactions%ROWTYPE;
    v_request approval_requests.request_id%TYPE;
  BEGIN
    check_reason(p_reason);
    BEGIN
      SELECT * INTO t FROM transactions WHERE txn_ref = p_txn_ref FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_txn_not_found, 'Transaction ' || p_txn_ref || ' does not exist');
    END;
    IF t.status <> 'POSTED' OR t.txn_type = 'REVERSAL' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_cannot_reverse,
        'Only a posted transaction that is not itself a reversal can be reversed ('
        || p_txn_ref || ' is a ' || t.status || ' ' || t.txn_type || ')');
    END IF;
    BEGIN
      INSERT INTO approval_requests (request_type, txn_id, reason, requested_by)
      VALUES ('TXN_REVERSAL', t.txn_id, SUBSTR(p_reason, 1, 400), v_me)
      RETURNING request_id INTO v_request;
    EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN   -- approval_requests_pending_ux: one pending request per target
        RAISE_APPLICATION_ERROR(pkg_errors.c_cannot_reverse, 'A reversal of ' || p_txn_ref || ' is already waiting for approval');
    END;
    pkg_audit.log_event('REVERSAL_REQUESTED', 'TRANSACTIONS', p_txn_ref, NULL,
                        JSON_OBJECT('request_id' VALUE v_request, 'reason' VALUE p_reason RETURNING VARCHAR2(4000)));
    RETURN v_request;
  END request_reversal;

  FUNCTION approve_reversal (p_request_id IN NUMBER) RETURN VARCHAR2 IS
    v_me      employees.employee_id%TYPE := pkg_session.employee_id;
    v_request approval_requests%ROWTYPE;
    t         transactions%ROWTYPE;
    v_lines   t_lines;
    v_rev_id  transactions.txn_id%TYPE;
    v_rev_ref transactions.txn_ref%TYPE;
  BEGIN
    BEGIN
      SELECT * INTO v_request
        FROM approval_requests
       WHERE request_id = p_request_id AND request_type = 'TXN_REVERSAL' AND status = 'PENDING'
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_request_not_found, 'No pending reversal request ' || p_request_id);
    END;
    check_checker(v_me, v_request.requested_by);

    SELECT * INTO t FROM transactions WHERE txn_id = v_request.txn_id FOR UPDATE;
    IF t.status <> 'POSTED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_cannot_reverse, 'Transaction ' || t.txn_ref || ' is ' || t.status || ', not POSTED');
    END IF;
    check_limit('REVERSAL', t.currency_code, t.amount);

    -- The opposite of every original line.
    SELECT account_id, CASE direction WHEN 'DR' THEN 'CR' ELSE 'DR' END, amount
      BULK COLLECT INTO v_lines
      FROM ledger_entries WHERE txn_id = t.txn_id ORDER BY line_no;

    new_transaction('REVERSAL', t.currency_code, t.amount, 'Reversal of ' || t.txn_ref || ': ' || v_request.reason,
                    v_request.requested_by, v_rev_id, v_rev_ref, p_checked_by => v_me, p_reverses => t.txn_id);
    UPDATE transactions SET status = 'REVERSED' WHERE txn_id = t.txn_id;
    apply_lines(v_rev_id, v_lines, p_write => TRUE, p_correction => TRUE);
    UPDATE approval_requests SET status = 'APPROVED', decided_by = v_me, decided_at = SYSTIMESTAMP
     WHERE request_id = p_request_id;
    pkg_audit.log_event('TXN_REVERSED', 'TRANSACTIONS', t.txn_ref, '{"status":"POSTED"}',
                        JSON_OBJECT('status' VALUE 'REVERSED', 'reversal_ref' VALUE v_rev_ref RETURNING VARCHAR2(4000)));
    RETURN v_rev_ref;
  END approve_reversal;

END pkg_posting;
/
--rollback DROP PACKAGE BODY pkg_posting
