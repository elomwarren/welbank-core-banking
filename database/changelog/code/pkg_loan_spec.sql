--liquibase formatted sql

--changeset elomwarren:code-pkg-loan-spec runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE pkg_loan AS
  -- ===========================================================================
  -- Loans, from application to closure.
  --
  --   submit_application (loan officer, maker)
  --   -> approve_application / reject_application (credit manager, checker,
  --      within their job's LOAN_DISBURSEMENT limit; decides the margin)
  --   -> disburse (opens the LOAN account, posts the money, writes the schedule;
  --      never by the person who approved)
  --   -> run_end_of_day (charges interest as installments fall due, marks
  --      arrears, days past due, Bank of Ghana class)
  --   -> repay (interest first, then principal, oldest installment first)
  --   -> closed when every installment is paid.
  --
  -- Pricing: Ghana Reference Rate (bank_parameters, updated monthly) plus the
  -- margin. Equal monthly installments (annuity); interest per month on the
  -- outstanding principal at rate / 12.
  -- The caller is identified by pkg_session (run_end_of_day: a system job);
  -- nothing here COMMITs.
  -- ===========================================================================

  -- One row of a repayment schedule.
  TYPE t_installment IS RECORD (
    installment_no  NUMBER,
    due_date        DATE,
    principal_due   NUMBER,
    interest_due    NUMBER,
    total_due       NUMBER,
    balance_after   NUMBER);
  TYPE t_schedule IS TABLE OF t_installment;

  -- The equal monthly installment of an annuity loan:
  --   P * r / (1 - (1 + r)^-n), with r = annual rate / 12 / 100.
  FUNCTION monthly_installment (p_principal IN NUMBER, p_annual_rate IN NUMBER, p_term_months IN NUMBER) RETURN NUMBER;

  -- The full schedule, as a PIPELINED table function: rows are produced one by
  -- one and can be queried like a table, e.g. for a quote:
  --   SELECT * FROM pkg_loan.schedule_preview(5000, 16.54, 12, DATE '2026-11-26');
  -- The last installment absorbs the rounding, so the principal adds up exactly.
  FUNCTION schedule_preview (
    p_principal      IN NUMBER,
    p_annual_rate    IN NUMBER,
    p_term_months    IN NUMBER,
    p_first_due_date IN DATE) RETURN t_schedule PIPELINED;

  -- Loan officer: a new application (checked against the product and the
  -- affordability limit at the product's rate). Returns the application number.
  FUNCTION submit_application (
    p_customer_no         IN VARCHAR2,
    p_product_code        IN VARCHAR2,
    p_amount              IN NUMBER,
    p_term_months         IN NUMBER,
    p_purpose             IN VARCHAR2,
    p_monthly_income      IN NUMBER,
    p_monthly_obligations IN NUMBER   DEFAULT 0,
    p_purpose_details     IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;

  -- Credit manager: approve (possibly less, never more than asked) with the
  -- margin over the GRR, or reject with a reason.
  PROCEDURE approve_application (
    p_application_no IN VARCHAR2,
    p_amount         IN NUMBER,
    p_term_months    IN NUMBER,
    p_margin_pct     IN NUMBER);
  PROCEDURE reject_application (p_application_no IN VARCHAR2, p_reason IN VARCHAR2);

  -- Pays the approved loan into one of the borrower's accounts. Returns the loan number.
  FUNCTION disburse (
    p_application_no          IN VARCHAR2,
    p_disbursement_account_no IN VARCHAR2,
    p_first_due_date          IN DATE     DEFAULT NULL,
    p_rate_type               IN VARCHAR2 DEFAULT 'VARIABLE') RETURN VARCHAR2;

  -- A repayment from one of the borrower's accounts, at most what is due on
  -- p_as_of (early repayment is not supported yet). Returns the transaction reference.
  FUNCTION repay (
    p_loan_no         IN VARCHAR2,
    p_from_account_no IN VARCHAR2,
    p_amount          IN NUMBER,
    p_as_of           IN DATE DEFAULT TRUNC(SYSDATE)) RETURN VARCHAR2;

  -- What the borrower owes on p_as_of: due installments, interest included.
  FUNCTION amount_due (p_loan_no IN VARCHAR2, p_as_of IN DATE DEFAULT TRUNC(SYSDATE)) RETURN NUMBER;

  -- The nightly run for every active loan (a DBMS_SCHEDULER job will call it):
  -- interest charged on installments due by p_as_of, arrears marked, days past
  -- due and the Bank of Ghana class updated (worse only: an upgrade is a
  -- person's decision).
  PROCEDURE run_end_of_day (p_as_of IN DATE DEFAULT TRUNC(SYSDATE));
END pkg_loan;
/
--rollback DROP PACKAGE pkg_loan
