"""Counter transactions through pkg_posting: deposits, withdrawals, transfers, reversals.

The package decides everything: the teller's limit for the job (above it, the
transaction waits for a supervisor), funds, KYC state, the double-entry lines.
The API passes the request on and reports the outcome.
"""

from typing import Any, Literal

import oracledb
from fastapi import APIRouter, Query
from pydantic import BaseModel

from ..db import row, rows
from ..deps import CurrentEmployee, Db, require_role
from ..errors import ApiError
from ..schemas import AccountNo, Money, Narration, Reason

router = APIRouter(prefix="/api/transactions", tags=["transactions"])

TELLER = require_role("WB_TELLER")


class CashIn(BaseModel):
    """A cash deposit or withdrawal at the counter."""

    account_no: AccountNo
    amount: Money
    narration: Narration = None


class TransferIn(BaseModel):
    """A transfer between two accounts in the same currency."""

    from_account_no: AccountNo
    to_account_no: AccountNo
    amount: Money
    narration: Narration = None


class ReversalIn(BaseModel):
    """Why a posted transaction must be reversed."""

    reason: Reason


def _outcome(db: oracledb.Connection, txn_ref: str) -> dict[str, Any]:
    with db.cursor() as cursor:
        status = cursor.callfunc("pkg_posting.transaction_status", str, [txn_ref])
    db.commit()
    message = (
        "Posted."
        if status == "POSTED"
        else "Above your limit: sent to a supervisor for approval."
        if status == "PENDING"
        else status
    )
    return {"txn_ref": txn_ref, "status": status, "message": message}


@router.post("/deposits", status_code=201, dependencies=[TELLER])
def cash_deposit(body: CashIn, db: Db) -> dict[str, Any]:
    """Pay cash into an account."""
    with db.cursor() as cursor:
        ref = cursor.callfunc(
            "pkg_posting.cash_deposit", str, [body.account_no, body.amount, body.narration]
        )
    return _outcome(db, ref)


@router.post("/withdrawals", status_code=201, dependencies=[TELLER])
def cash_withdrawal(body: CashIn, db: Db) -> dict[str, Any]:
    """Pay cash out of an account."""
    with db.cursor() as cursor:
        ref = cursor.callfunc(
            "pkg_posting.cash_withdrawal", str, [body.account_no, body.amount, body.narration]
        )
    return _outcome(db, ref)


@router.post("/transfers", status_code=201, dependencies=[TELLER])
def transfer(body: TransferIn, db: Db) -> dict[str, Any]:
    """Move money between two accounts."""
    with db.cursor() as cursor:
        ref = cursor.callfunc(
            "pkg_posting.transfer",
            str,
            [body.from_account_no, body.to_account_no, body.amount, body.narration],
        )
    return _outcome(db, ref)


@router.get("")
def list_transactions(
    db: Db,
    employee: CurrentEmployee,
    scope: Literal["branch", "mine"] = "branch",
    status: str | None = Query(default=None, max_length=12),
    skip: int = Query(default=0, ge=0),
    take: int = Query(default=50, ge=1, le=200),
) -> list[dict[str, Any]]:
    """The branch's (or my own) latest transactions."""
    return rows(
        db,
        """SELECT t.txn_ref, t.txn_type, t.channel, t.amount, t.currency_code, t.status,
                  t.value_date, t.posted_at, t.narration, s.full_name AS initiated_by,
                  k.full_name AS checked_by, t.rejection_reason
             FROM transactions t
             LEFT JOIN v_staff_directory s ON s.employee_id = t.initiated_by
             LEFT JOIN v_staff_directory k ON k.employee_id = t.checked_by
            WHERE ((:scope = 'branch' AND t.branch_id = :branch)
                   OR (:scope = 'mine' AND t.initiated_by = :me))
              AND (:status IS NULL OR t.status = :status)
            ORDER BY t.txn_id DESC
            OFFSET :skip ROWS FETCH NEXT :take ROWS ONLY""",
        scope=scope,
        branch=employee.branch_id,
        me=employee.employee_id,
        status=status,
        skip=skip,
        take=take,
    )


@router.get("/{txn_ref}")
def get_transaction(txn_ref: str, db: Db) -> dict[str, Any]:
    """A transaction and its double-entry lines (debits always equal credits)."""
    txn = row(
        db,
        """SELECT t.txn_id, t.txn_ref, t.txn_type, t.channel, t.amount, t.currency_code, t.status,
                  t.value_date, t.posted_at, t.narration, t.rejection_reason, b.branch_code,
                  s.full_name AS initiated_by, k.full_name AS checked_by, t.checked_at,
                  r.txn_ref AS reverses_txn_ref
             FROM transactions t
             LEFT JOIN branches b ON b.branch_id = t.branch_id
             LEFT JOIN v_staff_directory s ON s.employee_id = t.initiated_by
             LEFT JOIN v_staff_directory k ON k.employee_id = t.checked_by
             LEFT JOIN transactions r ON r.txn_id = t.reverses_txn_id
            WHERE t.txn_ref = :ref""",
        ref=txn_ref,
    )
    if txn is None:
        raise ApiError(404, "NOT_FOUND", f"No transaction {txn_ref}.")
    lines = rows(
        db,
        """SELECT a.account_no, a.account_name, a.account_class, e.direction, e.amount
             FROM ledger_entries e JOIN accounts a ON a.account_id = e.account_id
            WHERE e.txn_id = :id ORDER BY e.direction DESC, e.entry_id""",
        id=txn.pop("txn_id"),
    )
    return {"transaction": txn, "lines": lines}


@router.post(
    "/{txn_ref}/reversal-requests",
    status_code=201,
    dependencies=[require_role("WB_TELLER", "WB_SUPERVISOR")],
)
def request_reversal(txn_ref: str, body: ReversalIn, db: Db) -> dict[str, Any]:
    """Ask for a posted transaction to be reversed; a supervisor approves the reversal."""
    with db.cursor() as cursor:
        request_id = cursor.callfunc("pkg_posting.request_reversal", int, [txn_ref, body.reason])
    db.commit()
    return {"request_id": request_id, "message": "Reversal requested: waiting for a supervisor."}
