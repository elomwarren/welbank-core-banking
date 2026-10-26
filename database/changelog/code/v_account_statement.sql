--liquibase formatted sql

--changeset elomwarren:code-v-account-statement runOnChange:true
--comment: Account statement lines with a running balance computed by an analytic function.
-- running_balance is computed (SUM ... OVER, an analytic function: a total
-- that runs along the rows of each account, in posting order) and must equal
-- balance_after, which pkg_posting stored when it posted the line. Query it
-- with WHERE account_no = ...; Oracle pushes that filter inside the analytic
-- function because account is its partition key.
CREATE OR REPLACE VIEW v_account_statement AS
SELECT a.account_id,
       a.account_no,
       a.currency_code,
       e.entry_id,
       t.txn_ref,
       t.txn_type,
       t.value_date,
       t.posted_at,
       t.narration,
       CASE e.direction WHEN 'DR' THEN e.amount END AS debit,
       CASE e.direction WHEN 'CR' THEN e.amount END AS credit,
       e.balance_after,
       SUM(CASE WHEN (e.direction = 'DR' AND a.normal_side = 'DEBIT')
                  OR (e.direction = 'CR' AND a.normal_side = 'CREDIT')
                THEN e.amount ELSE -e.amount END)
         OVER (PARTITION BY e.account_id ORDER BY e.entry_id) AS running_balance
  FROM ledger_entries e
  JOIN accounts a     ON a.account_id = e.account_id
  JOIN transactions t ON t.txn_id = e.txn_id;
COMMENT ON TABLE v_account_statement IS 'Statement lines per account, oldest first, with a computed running balance (must equal balance_after).';
--rollback DROP VIEW v_account_statement;
