"""Management reports: customers, deposits, the loan book with provisions, the ledger check."""

from typing import Any

from fastapi import APIRouter

from ..db import row, rows
from ..deps import Db, require_role

router = APIRouter(prefix="/api/reports", tags=["reports"])

_SQL = {
    "customers_by_kyc": """
        SELECT kyc_status, COUNT(*) AS customers
          FROM customers GROUP BY kyc_status ORDER BY 2 DESC""",
    "deposits_by_product": """
        SELECT p.product_code, p.product_name, a.currency_code, COUNT(*) AS accounts,
               SUM(a.ledger_balance) AS balance
          FROM accounts a JOIN account_products p ON p.product_id = a.product_id
         WHERE a.account_class = 'CUSTOMER' AND a.status = 'ACTIVE'
         GROUP BY p.product_code, p.product_name, a.currency_code ORDER BY 5 DESC""",
    "loan_book": """
        SELECT k.class_code, k.class_name, k.provision_pct, k.is_non_performing,
               COUNT(l.loan_id) AS loans, NVL(SUM(l.principal), 0) AS principal,
               NVL(SUM(la.ledger_balance), 0) AS outstanding,
               ROUND(NVL(SUM(la.ledger_balance), 0) * k.provision_pct / 100, 2) AS provision
          FROM loan_classes k
          LEFT JOIN loans l ON l.classification = k.class_code AND l.status = 'ACTIVE'
          LEFT JOIN accounts la ON la.account_id = l.loan_account_id
         GROUP BY k.class_code, k.class_name, k.provision_pct, k.is_non_performing,
                  k.min_days_past_due
         ORDER BY k.min_days_past_due""",
    "monthly_volume": """
        SELECT TO_CHAR(TRUNC(value_date, 'MM'), 'YYYY-MM') AS month, txn_type,
               COUNT(*) AS transactions, SUM(amount) AS amount
          FROM transactions
         WHERE status = 'POSTED' AND currency_code = 'GHS'
           AND value_date >= ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -11)
         GROUP BY TRUNC(value_date, 'MM'), txn_type ORDER BY 1, 2""",
    "branches": """
        SELECT b.branch_code, b.branch_name, r.region_name,
               (SELECT COUNT(*) FROM customers c WHERE c.home_branch_id = b.branch_id) AS customers,
               (SELECT NVL(SUM(a.ledger_balance), 0) FROM accounts a
                 WHERE a.branch_id = b.branch_id AND a.account_class = 'CUSTOMER'
                   AND a.currency_code = 'GHS') AS deposits_ghs,
               (SELECT COUNT(*) FROM loans l JOIN loan_applications ap
                    ON ap.application_id = l.application_id
                 WHERE ap.branch_id = b.branch_id AND l.status = 'ACTIVE') AS active_loans
          FROM branches b JOIN regions r ON r.region_id = b.region_id
         ORDER BY deposits_ghs DESC""",
}

_LEDGER_SQL = """
SELECT (SELECT COUNT(*) FROM v_ledger_balance_check
         WHERE difference <> 0) AS accounts_out_of_balance,
       (SELECT COUNT(*) FROM v_ledger_balance_check) AS accounts_checked,
       (SELECT SUM(CASE WHEN direction = 'DR' THEN amount END) FROM ledger_entries) AS total_debits,
       (SELECT SUM(CASE WHEN direction = 'CR' THEN amount END) FROM ledger_entries) AS total_credits
  FROM dual"""


@router.get("/summary", dependencies=[require_role("WB_REPORTS", "WB_AUDITOR")])
def summary(db: Db) -> dict[str, Any]:
    """Every management figure in one call, with the ledger's integrity check."""
    report: dict[str, Any] = {key: rows(db, sql) for key, sql in _SQL.items()}
    report["ledger_check"] = row(db, _LEDGER_SQL)
    book = report["loan_book"]
    gross = sum(line["outstanding"] for line in book)
    non_performing = sum(line["outstanding"] for line in book if line["is_non_performing"])
    report["npl_ratio_pct"] = round(non_performing * 100 / gross, 2) if gross else 0
    return report
