--liquibase formatted sql

--changeset elomwarren:code-v-pending-approvals runOnChange:true
--comment: The checkers' work queue: every pending maker-checker request, with a readable target.
-- target_ref turns the exclusive arc back into one readable column: whichever
-- target column is filled, its business number is shown.
CREATE OR REPLACE VIEW v_pending_approvals AS
SELECT r.request_id,
       r.request_type,
       CASE
         WHEN r.account_id     IS NOT NULL THEN 'ACCOUNT'
         WHEN r.customer_id    IS NOT NULL THEN 'CUSTOMER'
         WHEN r.txn_id         IS NOT NULL THEN 'TRANSACTION'
         WHEN r.application_id IS NOT NULL THEN 'LOAN_APPLICATION'
         WHEN r.card_id        IS NOT NULL THEN 'CARD'
       END                                                         AS target_kind,
       COALESCE(a.account_no, c.customer_no, t.txn_ref, la.application_no, cd.masked_pan) AS target_ref,
       t.amount,
       t.currency_code,
       r.reason,
       r.requested_by,
       e.first_name || ' ' || e.last_name                          AS requested_by_name,
       e.branch_id,
       r.requested_at,
       ROUND((SYSDATE - CAST(r.requested_at AS DATE)) * 24, 1)    AS hours_waiting
  FROM approval_requests r
  JOIN employees e              ON e.employee_id = r.requested_by
  LEFT JOIN accounts a          ON a.account_id = r.account_id
  LEFT JOIN customers c         ON c.customer_id = r.customer_id
  LEFT JOIN transactions t      ON t.txn_id = r.txn_id
  LEFT JOIN loan_applications la ON la.application_id = r.application_id
  LEFT JOIN cards cd            ON cd.card_id = r.card_id
 WHERE r.status = 'PENDING';
COMMENT ON TABLE v_pending_approvals IS 'Checkers'' queue: pending maker-checker requests, oldest first when ordered by requested_at.';
--rollback DROP VIEW v_pending_approvals;
