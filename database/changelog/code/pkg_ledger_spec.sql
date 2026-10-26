--liquibase formatted sql

--changeset elomwarren:code-pkg-ledger-spec runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE pkg_ledger
  -- ACCESSIBLE BY (Oracle 12.2+): only these two packages may call pkg_ledger.
  -- Nobody else can, not a role with EXECUTE on it, not even an anonymous
  -- block run as WELBANK itself (PLS-00904). Every posting therefore goes
  -- through the checks of pkg_posting or pkg_loan.
  ACCESSIBLE BY (PACKAGE pkg_posting, PACKAGE pkg_loan)
AS
  -- ===========================================================================
  -- The posting core: the one place that writes ledger lines and balances.
  -- Moved here from pkg_posting (commit 9) so pkg_loan can post too.
  -- ===========================================================================

  -- One ledger line to write.
  TYPE t_line IS RECORD (
    account_id  accounts.account_id%TYPE,
    direction   ledger_entries.direction%TYPE,
    amount      ledger_entries.amount%TYPE);
  TYPE t_lines IS TABLE OF t_line INDEX BY PLS_INTEGER;

  FUNCTION new_line (p_account_id IN NUMBER, p_direction IN VARCHAR2, p_amount IN NUMBER) RETURN t_line;

  -- Positive, and no more decimals than the currency has (pkg_errors.e_invalid_amount).
  PROCEDURE check_amount (p_amount IN NUMBER, p_currency IN VARCHAR2);

  -- The branch's internal account for a purpose and currency (VAULT_CASH,
  -- INTEREST_INCOME, ...). A missing vault is pkg_errors.e_no_vault; any
  -- other missing account is a set-up error (e_internal_error).
  FUNCTION internal_account_id (p_branch_id IN NUMBER, p_purpose IN VARCHAR2, p_currency IN VARCHAR2) RETURN accounts.account_id%TYPE;

  -- A new PENDING transaction. Channel BRANCH: at p_branch_id (default: the
  -- caller's branch), keyed in by p_initiated_by. Channel SYSTEM: a batch job,
  -- nobody initiates it.
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
    p_value_date   IN  DATE     DEFAULT NULL);

  -- Checks the lines against the accounts and, with p_write, writes them
  -- (locks in ascending account_id, checks under the lock, then POSTED,
  -- lines with balance_after, new balances). p_correction skips the account
  -- status checks (reversals), never the balance floors.
  PROCEDURE apply_lines (
    p_txn_id     IN NUMBER,
    p_lines      IN t_lines,
    p_write      IN BOOLEAN,
    p_correction IN BOOLEAN DEFAULT FALSE);

  -- A small JSON summary of a transaction, for the audit trail.
  FUNCTION txn_json (p_txn_id IN NUMBER) RETURN VARCHAR2;
END pkg_ledger;
/
--rollback DROP PACKAGE pkg_ledger
