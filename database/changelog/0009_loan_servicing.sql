--liquibase formatted sql

-- =============================================================================
-- 0009_loan_servicing.sql — what pkg_loan needs beyond the tables of 0006:
-- the margin decided at approval, the link from an installment to the
-- transaction that charged its interest, and two policy values.
-- =============================================================================

--changeset elomwarren:0009-loan-applications-margin
--comment: Risk-based pricing: the credit manager decides the margin over the Ghana Reference Rate when approving.
ALTER TABLE loan_applications ADD (approved_margin_pct rate_pct_d);
ALTER TABLE loan_applications ADD CONSTRAINT loan_applications_margin_ck CHECK (
  (status = 'APPROVED' AND approved_margin_pct IS NOT NULL) OR
  (status <> 'APPROVED' AND approved_margin_pct IS NULL));
COMMENT ON COLUMN loan_applications.approved_margin_pct IS 'Margin over the Ghana Reference Rate decided at approval, in percent (risk-based pricing).';
--rollback ALTER TABLE loan_applications DROP CONSTRAINT loan_applications_margin_ck;
--rollback ALTER TABLE loan_applications DROP COLUMN approved_margin_pct;

--changeset elomwarren:0009-loan-schedule-interest-txn
--comment: Interest is charged to the loan account when an installment falls due; this links the installment to that transaction.
ALTER TABLE loan_schedule ADD (interest_txn_id NUMBER(14));
ALTER TABLE loan_schedule ADD CONSTRAINT loan_schedule_interest_txn_fk FOREIGN KEY (interest_txn_id) REFERENCES transactions (txn_id);
ALTER TABLE loan_schedule ADD CONSTRAINT loan_schedule_interest_txn_uk UNIQUE (interest_txn_id);
-- Interest cannot be paid before it has been charged.
ALTER TABLE loan_schedule ADD CONSTRAINT loan_schedule_charged_ck CHECK (interest_paid = 0 OR interest_txn_id IS NOT NULL);
COMMENT ON COLUMN loan_schedule.interest_txn_id IS 'The INTEREST transaction (debit loan account, credit interest income) posted when the installment fell due.';
--rollback ALTER TABLE loan_schedule DROP CONSTRAINT loan_schedule_charged_ck;
--rollback ALTER TABLE loan_schedule DROP CONSTRAINT loan_schedule_interest_txn_uk;
--rollback ALTER TABLE loan_schedule DROP CONSTRAINT loan_schedule_interest_txn_fk;
--rollback ALTER TABLE loan_schedule DROP COLUMN interest_txn_id;

--changeset elomwarren:0009-bank-parameters-loans
INSERT INTO bank_parameters (param_name, num_value, unit, description, source) VALUES
  ('GHANA_REFERENCE_RATE', 10.04, 'PERCENT', 'Benchmark rate loans are priced from (GRR + margin). Update it every month when the new rate is published',
   'Ghana Association of Banks, Ghana Reference Rate for October 2026'),
  ('DEBT_SERVICE_RATIO_MAX', 40, 'PERCENT', 'Monthly loan repayments, existing and new, may take at most this share of the applicant''s monthly income',
   'Bank policy (affordability check, illustrative)');
--rollback DELETE FROM bank_parameters WHERE param_name IN ('GHANA_REFERENCE_RATE', 'DEBT_SERVICE_RATIO_MAX');
