--liquibase formatted sql

--changeset elomwarren:code-pkg-posting-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_posting AS

  -- The posting core (lines, locks, balances) lives in pkg_ledger, which only
  -- this package and pkg_loan may call (ACCESSIBLE BY). This body keeps the
  -- rules of counter transactions: limits, maker-checker, reversals.

  -- ------------------------------------------------------------------ helpers

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

  PROCEDURE check_reason (p_reason IN VARCHAR2) IS
  BEGIN
    IF TRIM(p_reason) IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_reason_required, 'Give a reason');
    END IF;
  END check_reason;

  -- The planned lines of a pending transaction, stored in its approval request
  -- as {"lines": [{"account_id": 7, "direction": "DR", "amount": 500}, ...]}.
  FUNCTION lines_json (p_lines IN pkg_ledger.t_lines) RETURN VARCHAR2 IS
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

  FUNCTION lines_of_request (p_request_id IN NUMBER) RETURN pkg_ledger.t_lines IS
    v_lines pkg_ledger.t_lines;
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

  -- Common path of deposits, withdrawals and transfers: post at once when the
  -- amount is within the maker's limit, otherwise park it for a checker.
  FUNCTION submit (
    p_me        IN NUMBER,
    p_txn_type  IN VARCHAR2,
    p_currency  IN VARCHAR2,
    p_amount    IN NUMBER,
    p_narration IN VARCHAR2,
    p_lines     IN pkg_ledger.t_lines) RETURN VARCHAR2
  IS
    v_txn_id  transactions.txn_id%TYPE;
    v_txn_ref transactions.txn_ref%TYPE;
    v_payload VARCHAR2(4000);
  BEGIN
    pkg_ledger.check_amount(p_amount, p_currency);
    -- Refuse at once what could never be posted (closed account, no funds, ...).
    pkg_ledger.apply_lines(NULL, p_lines, p_write => FALSE);
    pkg_ledger.new_transaction(p_txn_type, p_currency, p_amount, p_narration, p_me, v_txn_id, v_txn_ref);

    IF p_amount <= pkg_session.limit_for(p_txn_type, p_currency) THEN
      pkg_ledger.apply_lines(v_txn_id, p_lines, p_write => TRUE);
      pkg_audit.log_event('TXN_POSTED', 'TRANSACTIONS', v_txn_ref, NULL, pkg_ledger.txn_json(v_txn_id));
    ELSE
      -- A private package function cannot be called inside a SQL statement
      -- (PLS-00231), so its result goes through a variable.
      v_payload := lines_json(p_lines);
      INSERT INTO approval_requests (request_type, txn_id, payload, reason, requested_by)
      VALUES ('TXN_APPROVAL', v_txn_id, v_payload, 'Amount above the maker''s limit', p_me);
      pkg_audit.log_event('TXN_AWAITING_APPROVAL', 'TRANSACTIONS', v_txn_ref, NULL, pkg_ledger.txn_json(v_txn_id));
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
    v_lines    pkg_ledger.t_lines;
  BEGIN
    v_lines(1) := pkg_ledger.new_line(pkg_ledger.internal_account_id(pkg_session.branch_id, 'VAULT_CASH', v_currency), 'DR', p_amount);
    v_lines(2) := pkg_ledger.new_line(v_account, 'CR', p_amount);
    RETURN submit(v_me, 'CASH_DEPOSIT', v_currency, p_amount, NVL(p_narration, 'Cash deposit'), v_lines);
  END cash_deposit;

  FUNCTION cash_withdrawal (p_account_no IN VARCHAR2, p_amount IN NUMBER, p_narration IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    v_me       employees.employee_id%TYPE := pkg_session.employee_id;
    v_account  accounts.account_id%TYPE   := customer_account_id(p_account_no);
    v_currency accounts.currency_code%TYPE := currency_of(v_account);
    v_lines    pkg_ledger.t_lines;
  BEGIN
    v_lines(1) := pkg_ledger.new_line(v_account, 'DR', p_amount);
    v_lines(2) := pkg_ledger.new_line(pkg_ledger.internal_account_id(pkg_session.branch_id, 'VAULT_CASH', v_currency), 'CR', p_amount);
    RETURN submit(v_me, 'CASH_WITHDRAWAL', v_currency, p_amount, NVL(p_narration, 'Cash withdrawal'), v_lines);
  END cash_withdrawal;

  FUNCTION transfer (p_from_account_no IN VARCHAR2, p_to_account_no IN VARCHAR2, p_amount IN NUMBER,
                     p_narration IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    v_me    employees.employee_id%TYPE := pkg_session.employee_id;
    v_from  accounts.account_id%TYPE   := customer_account_id(p_from_account_no);
    v_to    accounts.account_id%TYPE   := customer_account_id(p_to_account_no);
    v_lines pkg_ledger.t_lines;
  BEGIN
    IF v_from = v_to THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_same_account, 'Cannot transfer from an account to itself');
    END IF;
    IF currency_of(v_from) <> currency_of(v_to) THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_currency_mismatch,
        'Accounts are in different currencies (' || currency_of(v_from) || ' and ' || currency_of(v_to) || ')');
    END IF;
    v_lines(1) := pkg_ledger.new_line(v_from, 'DR', p_amount);
    v_lines(2) := pkg_ledger.new_line(v_to, 'CR', p_amount);
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
    pkg_ledger.apply_lines(t.txn_id, lines_of_request(v_request), p_write => TRUE);
    UPDATE approval_requests SET status = 'APPROVED', decided_by = v_me, decided_at = SYSTIMESTAMP
     WHERE request_id = v_request;
    pkg_audit.log_event('TXN_APPROVED', 'TRANSACTIONS', p_txn_ref, '{"status":"PENDING"}', pkg_ledger.txn_json(t.txn_id));
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
    pkg_audit.log_event('TXN_REJECTED', 'TRANSACTIONS', p_txn_ref, '{"status":"PENDING"}', pkg_ledger.txn_json(t.txn_id));
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
    v_lines   pkg_ledger.t_lines;
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

    pkg_ledger.new_transaction('REVERSAL', t.currency_code, t.amount, 'Reversal of ' || t.txn_ref || ': ' || v_request.reason,
                    v_request.requested_by, v_rev_id, v_rev_ref, p_checked_by => v_me, p_reverses => t.txn_id);
    UPDATE transactions SET status = 'REVERSED' WHERE txn_id = t.txn_id;
    pkg_ledger.apply_lines(v_rev_id, v_lines, p_write => TRUE, p_correction => TRUE);
    UPDATE approval_requests SET status = 'APPROVED', decided_by = v_me, decided_at = SYSTIMESTAMP
     WHERE request_id = p_request_id;
    pkg_audit.log_event('TXN_REVERSED', 'TRANSACTIONS', t.txn_ref, '{"status":"POSTED"}',
                        JSON_OBJECT('status' VALUE 'REVERSED', 'reversal_ref' VALUE v_rev_ref RETURNING VARCHAR2(4000)));
    RETURN v_rev_ref;
  END approve_reversal;

END pkg_posting;
/
--rollback DROP PACKAGE BODY pkg_posting
