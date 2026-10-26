--liquibase formatted sql

--changeset elomwarren:code-v-ledger-balance-check runOnChange:true
--comment: Reconciliation: every account's stored balance against the sum of its ledger lines.
-- A bank runs this check every night (end-of-day reconciliation). pkg_posting
-- keeps the two equal; any row with difference <> 0 means a bug or a change
-- made behind the packages' back.
CREATE OR REPLACE VIEW v_ledger_balance_check AS
SELECT a.account_id,
       a.account_no,
       a.account_class,
       a.currency_code,
       a.ledger_balance                        AS stored_balance,
       NVL(l.lines_balance, 0)                 AS lines_balance,
       a.ledger_balance - NVL(l.lines_balance, 0) AS difference
  FROM accounts a
  LEFT JOIN (SELECT e.account_id,
                    -- up on the account's normal side, down on the other
                    SUM(CASE WHEN (e.direction = 'DR' AND x.normal_side = 'DEBIT')
                               OR (e.direction = 'CR' AND x.normal_side = 'CREDIT')
                             THEN e.amount ELSE -e.amount END) AS lines_balance
               FROM ledger_entries e
               JOIN accounts x ON x.account_id = e.account_id
              GROUP BY e.account_id) l
    ON l.account_id = a.account_id;
COMMENT ON TABLE v_ledger_balance_check IS 'Reconciliation: stored balance against the sum of the ledger lines, per account. difference must be 0 everywhere.';
--rollback DROP VIEW v_ledger_balance_check;
