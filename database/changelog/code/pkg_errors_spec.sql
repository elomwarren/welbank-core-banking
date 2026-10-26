--liquibase formatted sql

--changeset elomwarren:code-pkg-errors-spec runOnChange:true endDelimiter:/
--comment: Business error codes of the WEL Bank packages (a specification only: no body needed).
CREATE OR REPLACE PACKAGE pkg_errors AS
  -- ===========================================================================
  -- The business errors the packages raise, in one place.
  --
  -- Each error has a stable number (the range -20000 to -20999 is reserved for
  -- applications by RAISE_APPLICATION_ERROR) and a named exception, so callers
  -- can write:   EXCEPTION WHEN pkg_errors.e_insufficient_funds THEN ...
  -- The web API maps the numbers to messages and HTTP status codes; never
  -- change a number once it is in use, only add new ones.
  --
  -- PRAGMA EXCEPTION_INIT needs a literal, so each number appears twice: as a
  -- constant (for RAISE_APPLICATION_ERROR) and in its exception's pragma.
  -- ===========================================================================

  -- Who is calling.
  c_not_an_employee       CONSTANT PLS_INTEGER := -20001;
  e_not_an_employee       EXCEPTION; PRAGMA EXCEPTION_INIT(e_not_an_employee, -20001);

  -- Accounts.
  c_account_not_found     CONSTANT PLS_INTEGER := -20002;
  e_account_not_found     EXCEPTION; PRAGMA EXCEPTION_INIT(e_account_not_found, -20002);
  c_account_not_open      CONSTANT PLS_INTEGER := -20003;  -- pending approval, closed or rejected
  e_account_not_open      EXCEPTION; PRAGMA EXCEPTION_INIT(e_account_not_open, -20003);
  c_debits_blocked        CONSTANT PLS_INTEGER := -20004;  -- not ACTIVE, or post_no_debit
  e_debits_blocked        EXCEPTION; PRAGMA EXCEPTION_INIT(e_debits_blocked, -20004);
  c_insufficient_funds    CONSTANT PLS_INTEGER := -20005;
  e_insufficient_funds    EXCEPTION; PRAGMA EXCEPTION_INIT(e_insufficient_funds, -20005);
  c_insufficient_vault    CONSTANT PLS_INTEGER := -20006;  -- not enough cash in the branch vault
  e_insufficient_vault    EXCEPTION; PRAGMA EXCEPTION_INIT(e_insufficient_vault, -20006);
  c_currency_mismatch     CONSTANT PLS_INTEGER := -20007;
  e_currency_mismatch     EXCEPTION; PRAGMA EXCEPTION_INIT(e_currency_mismatch, -20007);
  c_same_account          CONSTANT PLS_INTEGER := -20008;
  e_same_account          EXCEPTION; PRAGMA EXCEPTION_INIT(e_same_account, -20008);
  c_invalid_amount        CONSTANT PLS_INTEGER := -20009;  -- not positive, or too many decimals
  e_invalid_amount        EXCEPTION; PRAGMA EXCEPTION_INIT(e_invalid_amount, -20009);
  c_no_vault              CONSTANT PLS_INTEGER := -20010;  -- the branch holds no cash in that currency
  e_no_vault              EXCEPTION; PRAGMA EXCEPTION_INIT(e_no_vault, -20010);

  -- Transactions and approvals.
  c_txn_not_found         CONSTANT PLS_INTEGER := -20011;
  e_txn_not_found         EXCEPTION; PRAGMA EXCEPTION_INIT(e_txn_not_found, -20011);
  c_txn_not_pending       CONSTANT PLS_INTEGER := -20012;
  e_txn_not_pending       EXCEPTION; PRAGMA EXCEPTION_INIT(e_txn_not_pending, -20012);
  c_own_approval          CONSTANT PLS_INTEGER := -20013;  -- maker-checker: nobody checks their own work
  e_own_approval          EXCEPTION; PRAGMA EXCEPTION_INIT(e_own_approval, -20013);
  c_over_your_limit       CONSTANT PLS_INTEGER := -20014;  -- the checker's own limit is too low
  e_over_your_limit       EXCEPTION; PRAGMA EXCEPTION_INIT(e_over_your_limit, -20014);
  c_cannot_reverse        CONSTANT PLS_INTEGER := -20015;
  e_cannot_reverse        EXCEPTION; PRAGMA EXCEPTION_INIT(e_cannot_reverse, -20015);
  c_request_not_found     CONSTANT PLS_INTEGER := -20016;  -- no such pending approval request
  e_request_not_found     EXCEPTION; PRAGMA EXCEPTION_INIT(e_request_not_found, -20016);
  c_reason_required       CONSTANT PLS_INTEGER := -20017;  -- rejections and reversals must say why
  e_reason_required       EXCEPTION; PRAGMA EXCEPTION_INIT(e_reason_required, -20017);

  -- Customers, KYC and account opening.
  c_customer_not_found    CONSTANT PLS_INTEGER := -20018;
  e_customer_not_found    EXCEPTION; PRAGMA EXCEPTION_INIT(e_customer_not_found, -20018);
  c_underage              CONSTANT PLS_INTEGER := -20019;
  e_underage              EXCEPTION; PRAGMA EXCEPTION_INIT(e_underage, -20019);
  c_consent_required      CONSTANT PLS_INTEGER := -20020;  -- Data Protection Act, 2012 (Act 843)
  e_consent_required      EXCEPTION; PRAGMA EXCEPTION_INIT(e_consent_required, -20020);
  c_kyc_incomplete        CONSTANT PLS_INTEGER := -20021;  -- the message lists what is missing
  e_kyc_incomplete        EXCEPTION; PRAGMA EXCEPTION_INIT(e_kyc_incomplete, -20021);
  c_invalid_state         CONSTANT PLS_INTEGER := -20022;  -- the customer or account is not in a state that allows this
  e_invalid_state         EXCEPTION; PRAGMA EXCEPTION_INIT(e_invalid_state, -20022);
  c_invalid_file          CONSTANT PLS_INTEGER := -20023;  -- not the image it claims to be, empty or too large
  e_invalid_file          EXCEPTION; PRAGMA EXCEPTION_INIT(e_invalid_file, -20023);
  c_method_not_allowed    CONSTANT PLS_INTEGER := -20024;  -- e.g. a manual check of a Ghana Card (L.I. 2111)
  e_method_not_allowed    EXCEPTION; PRAGMA EXCEPTION_INIT(e_method_not_allowed, -20024);
  c_product_not_found     CONSTANT PLS_INTEGER := -20025;  -- unknown or no longer sold
  e_product_not_found     EXCEPTION; PRAGMA EXCEPTION_INIT(e_product_not_found, -20025);
  c_holder_kyc            CONSTANT PLS_INTEGER := -20026;  -- a holder's identity does not allow this yet
  e_holder_kyc            EXCEPTION; PRAGMA EXCEPTION_INIT(e_holder_kyc, -20026);

  -- Loans.
  c_outside_product       CONSTANT PLS_INTEGER := -20027;  -- amount or term outside the loan product's range
  e_outside_product       EXCEPTION; PRAGMA EXCEPTION_INIT(e_outside_product, -20027);
  c_not_affordable        CONSTANT PLS_INTEGER := -20028;  -- repayments above the debt-service limit
  e_not_affordable        EXCEPTION; PRAGMA EXCEPTION_INIT(e_not_affordable, -20028);
  c_more_than_due         CONSTANT PLS_INTEGER := -20029;  -- repayment larger than what is due now
  e_more_than_due         EXCEPTION; PRAGMA EXCEPTION_INIT(e_more_than_due, -20029);
  c_loan_not_found        CONSTANT PLS_INTEGER := -20030;  -- no such loan or loan application
  e_loan_not_found        EXCEPTION; PRAGMA EXCEPTION_INIT(e_loan_not_found, -20030);

  -- A bug in the packages themselves (for example unbalanced lines). Never
  -- caused by user input; report it.
  c_internal_error        CONSTANT PLS_INTEGER := -20999;
  e_internal_error        EXCEPTION; PRAGMA EXCEPTION_INIT(e_internal_error, -20999);
END pkg_errors;
/
--rollback DROP PACKAGE pkg_errors
