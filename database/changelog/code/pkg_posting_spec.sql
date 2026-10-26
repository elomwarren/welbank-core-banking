--liquibase formatted sql

--changeset elomwarren:code-pkg-posting-spec runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE pkg_posting AS
  -- ===========================================================================
  -- Moving money. The ONLY way balances change.
  --
  -- Every call writes, together: a transactions row, its balanced debit and
  -- credit lines (ledger_entries), the accounts' new balances and an
  -- audit_trail event. The caller is the employee identified by pkg_session.
  --
  -- Maker-checker: an amount above the employee's job limit is not posted. It
  -- waits as a PENDING transaction with a TXN_APPROVAL request, until another
  -- employee whose own limit covers it approves (or rejects) it. Funds are
  -- checked when the request is made AND again when it is posted.
  --
  -- Nothing here COMMITs: the caller (the web API) commits or rolls back the
  -- whole unit of work. Errors are raised with the codes in pkg_errors.
  -- ===========================================================================

  -- Cash paid in at the counter: debit the teller's branch vault, credit the
  -- account. Allowed on deposits-only (post_no_debit) accounts. Returns the
  -- transaction reference (TXN...); see transaction_status.
  FUNCTION cash_deposit (
    p_account_no IN VARCHAR2,
    p_amount     IN NUMBER,
    p_narration  IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;

  -- Cash paid out at the counter: debit the account, credit the branch vault.
  FUNCTION cash_withdrawal (
    p_account_no IN VARCHAR2,
    p_amount     IN NUMBER,
    p_narration  IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;

  -- Between two customer accounts in the same currency.
  FUNCTION transfer (
    p_from_account_no IN VARCHAR2,
    p_to_account_no   IN VARCHAR2,
    p_amount          IN NUMBER,
    p_narration       IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;

  -- POSTED, PENDING (waiting for a checker), REJECTED or REVERSED.
  FUNCTION transaction_status (p_txn_ref IN VARCHAR2) RETURN VARCHAR2;

  -- The checker's decision on a PENDING transaction.
  PROCEDURE approve_transaction (p_txn_ref IN VARCHAR2);
  PROCEDURE reject_transaction (p_txn_ref IN VARCHAR2, p_reason IN VARCHAR2);

  -- Mistakes are never edited away: a reversal posts the opposite lines.
  -- One employee asks (returns the approval request id), another approves
  -- (returns the reference of the REVERSAL transaction).
  FUNCTION request_reversal (p_txn_ref IN VARCHAR2, p_reason IN VARCHAR2) RETURN NUMBER;
  FUNCTION approve_reversal (p_request_id IN NUMBER) RETURN VARCHAR2;
END pkg_posting;
/
--rollback DROP PACKAGE pkg_posting
