"""The home page: the employee's branch today, their latest work, the last six months."""

from typing import Any

from fastapi import APIRouter

from ..db import row, rows
from ..deps import CurrentEmployee, Db

router = APIRouter(tags=["dashboard"])

_STATS_SQL = """
SELECT (SELECT COUNT(*) FROM customers WHERE home_branch_id = :b) AS customers,
       (SELECT COUNT(*) FROM accounts
         WHERE branch_id = :b AND account_class = 'CUSTOMER'
           AND status = 'ACTIVE') AS active_accounts,
       (SELECT COUNT(*) FROM v_pending_approvals WHERE branch_id = :b) AS pending_approvals,
       (SELECT COUNT(*) FROM transactions
         WHERE branch_id = :b AND value_date = TRUNC(SYSDATE)) AS transactions_today,
       (SELECT NVL(SUM(amount), 0) FROM transactions
         WHERE branch_id = :b AND value_date = TRUNC(SYSDATE)
           AND status = 'POSTED' AND currency_code = 'GHS') AS volume_today_ghs,
       (SELECT NVL(SUM(ledger_balance), 0) FROM accounts
         WHERE branch_id = :b AND account_class = 'CUSTOMER'
           AND currency_code = 'GHS') AS deposits_ghs,
       (SELECT COUNT(*) FROM loans l JOIN loan_applications a ON a.application_id = l.application_id
         WHERE a.branch_id = :b AND l.status = 'ACTIVE' AND l.days_past_due > 0) AS loans_in_arrears
  FROM dual"""

_RECENT_SQL = """
SELECT txn_ref, txn_type, amount, currency_code, status, value_date, posted_at, narration
  FROM transactions
 WHERE initiated_by = :e
 ORDER BY txn_id DESC
 FETCH FIRST 8 ROWS ONLY"""

_MONTHLY_SQL = """
SELECT TO_CHAR(TRUNC(value_date, 'MM'), 'YYYY-MM') AS month, txn_type,
       COUNT(*) AS transactions, SUM(amount) AS amount
  FROM transactions
 WHERE branch_id = :b AND status = 'POSTED' AND currency_code = 'GHS'
   AND txn_type IN ('CASH_DEPOSIT', 'CASH_WITHDRAWAL', 'TRANSFER')
   AND value_date >= ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -5)
 GROUP BY TRUNC(value_date, 'MM'), txn_type
 ORDER BY 1, 2"""


@router.get("/api/dashboard")
def dashboard(db: Db, employee: CurrentEmployee) -> dict[str, Any]:
    """Branch figures for today, the employee's latest transactions and six months of activity."""
    return {
        "employee": employee.model_dump(),
        "stats": row(db, _STATS_SQL, b=employee.branch_id),
        "recent_transactions": rows(db, _RECENT_SQL, e=employee.employee_id),
        "monthly_activity": rows(db, _MONTHLY_SQL, b=employee.branch_id),
    }
