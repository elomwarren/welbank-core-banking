"""Accounts: search, details, statements, and opening through pkg_account."""

from typing import Any

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field

from ..db import row, rows
from ..deps import Db, require_role
from ..errors import ApiError

router = APIRouter(prefix="/api/accounts", tags=["accounts"])

_ACCOUNT_SQL = """
SELECT a.account_id, a.account_no, a.account_name, a.account_class, a.currency_code, a.mandate,
       a.status, a.post_no_debit, a.ledger_balance, a.available_balance, a.overdraft_limit,
       a.opened_on, a.closed_on, a.last_activity_at, p.product_code, p.product_name,
       p.account_type, p.interest_rate, b.branch_code, b.branch_name,
       op.full_name AS opened_by, ck.full_name AS checked_by, a.checked_at
  FROM accounts a
  JOIN branches b ON b.branch_id = a.branch_id
  LEFT JOIN account_products p ON p.product_id = a.product_id
  LEFT JOIN v_staff_directory op ON op.employee_id = a.opened_by
  LEFT JOIN v_staff_directory ck ON ck.employee_id = a.checked_by
 WHERE a.account_no = :no"""

_HOLDERS_SQL = """
SELECT c.customer_no, c.first_name || ' ' || c.last_name AS full_name, h.holder_role, c.kyc_status
  FROM account_holders h JOIN customers c ON c.customer_id = h.customer_id
 WHERE h.account_id = :id ORDER BY h.holder_role DESC"""

_STATEMENT_SQL = """
SELECT entry_id, txn_ref, txn_type, value_date, posted_at, narration, debit, credit,
       balance_after
  FROM v_account_statement
 WHERE account_no = :no
   AND (:from_date IS NULL OR value_date >= :from_date)
 ORDER BY entry_id DESC
 OFFSET :skip ROWS FETCH NEXT :take ROWS ONLY"""


class OpenAccountIn(BaseModel):
    """A new account for a customer; it waits for a branch manager's approval."""

    customer_no: str = Field(min_length=4, max_length=20)
    product_code: str = Field(min_length=3, max_length=20)
    account_name: str | None = Field(default=None, max_length=120)


@router.get("")
def search_accounts(
    db: Db,
    q: str | None = Query(default=None, max_length=60, description="account number or name"),
    status: str | None = Query(default=None, max_length=20),
    take: int = Query(default=25, ge=1, le=100),
) -> list[dict[str, Any]]:
    """Find customer accounts by number or name."""
    return rows(
        db,
        """SELECT a.account_no, a.account_name, a.currency_code, a.status, a.ledger_balance,
                  a.available_balance, p.product_code, b.branch_code, a.opened_on
             FROM accounts a
             JOIN branches b ON b.branch_id = a.branch_id
             LEFT JOIN account_products p ON p.product_id = a.product_id
            WHERE a.account_class = 'CUSTOMER'
              AND (:q IS NULL OR a.account_no = :q
                   OR UPPER(a.account_name) LIKE '%' || UPPER(:q) || '%')
              AND (:status IS NULL OR a.status = :status)
            ORDER BY a.account_id DESC
            FETCH FIRST :take ROWS ONLY""",
        q=q,
        status=status,
        take=take,
    )


@router.get("/{account_no}")
def get_account(account_no: str, db: Db) -> dict[str, Any]:
    """Account details, holders and the 20 latest statement lines."""
    account = row(db, _ACCOUNT_SQL, no=account_no)
    if account is None:
        raise ApiError(404, "NOT_FOUND", f"No account {account_no}.")
    holders = rows(db, _HOLDERS_SQL, id=account.pop("account_id"))
    statement = rows(db, _STATEMENT_SQL, no=account_no, from_date=None, skip=0, take=20)
    return {"account": account, "holders": holders, "statement": statement}


@router.get("/{account_no}/statement")
def get_statement(
    account_no: str,
    db: Db,
    skip: int = Query(default=0, ge=0),
    take: int = Query(default=50, ge=1, le=500),
) -> list[dict[str, Any]]:
    """Statement lines, newest first, with the balance after each line."""
    return rows(db, _STATEMENT_SQL, no=account_no, from_date=None, skip=skip, take=take)


@router.post("", status_code=201, dependencies=[require_role("WB_CUSTOMER_SERVICE")])
def open_account(body: OpenAccountIn, db: Db) -> dict[str, Any]:
    """Open an account; it accepts deposits at once and debits after approval and KYC."""
    with db.cursor() as cursor:
        account_no = cursor.callfunc(
            "pkg_account.open_account",
            str,
            keyword_parameters={
                "p_customer_no": body.customer_no.upper(),
                "p_product_code": body.product_code.upper(),
                "p_account_name": body.account_name,
            },
        )
    db.commit()
    return {"account_no": account_no, "status": "PENDING_APPROVAL"}
