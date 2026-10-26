--liquibase formatted sql

--changeset elomwarren:code-pkg-account-spec runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE pkg_account AS
  -- ===========================================================================
  -- Opening customer accounts (maker-checker) and keeping their debit status
  -- in line with the holders' KYC.
  --
  -- An account is opened PENDING_APPROVAL, deposits only. A checker approves
  -- it when every holder's identity is VERIFIED, or DEFERRED (failed NIA
  -- check, 90 days to fix it: the Bank of Ghana allows deposits but no debits,
  -- Ghana Card note s.10 and s.23.3). Debits are switched on only when EVERY
  -- holder is VERIFIED, and switched off again when one is not.
  --
  -- The caller is identified by pkg_session; nothing here COMMITs.
  -- ===========================================================================

  -- Opens an account of a product for a customer (the primary holder).
  -- For a joint mandate, add the JOINT holder in the same transaction, before
  -- COMMIT (assertion accounts_joint_mandate_as). Returns the account number.
  FUNCTION open_account (
    p_customer_no  IN VARCHAR2,
    p_product_code IN VARCHAR2,
    p_mandate      IN VARCHAR2 DEFAULT 'SOLE',
    p_account_name IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;

  -- Adds a JOINT holder (co-owner) or a SIGNATORY (may sign, does not own).
  PROCEDURE add_holder (p_account_no IN VARCHAR2, p_customer_no IN VARCHAR2, p_holder_role IN VARCHAR2);

  -- The checker's decision on an account waiting for approval.
  PROCEDURE approve_account (p_account_no IN VARCHAR2);
  PROCEDURE reject_account (p_account_no IN VARCHAR2, p_reason IN VARCHAR2);

  -- Recomputes post_no_debit on the active accounts a customer holds: debits
  -- on only if every holder is VERIFIED. Called by pkg_customer when a KYC
  -- decision changes.
  PROCEDURE refresh_debits (p_customer_id IN NUMBER);
END pkg_account;
/
--rollback DROP PACKAGE pkg_account
