"""The checkers' queue (maker-checker): approve or reject what others prepared.

Each request type has its own package procedure and its own role; the package
also refuses anyone approving their own work (ORA-20013) or above their limit
(ORA-20014).
"""

from decimal import Decimal
from typing import Any, Literal

import oracledb
from fastapi import APIRouter
from pydantic import BaseModel, Field

from ..db import row, rows
from ..deps import CurrentEmployee, Db
from ..errors import ApiError
from ..schemas import Reason, RiskRating

router = APIRouter(prefix="/api/approvals", tags=["approvals"])

# Who may decide each kind of request.
DECIDER_ROLE = {
    "TXN_APPROVAL": "WB_SUPERVISOR",
    "TXN_REVERSAL": "WB_SUPERVISOR",
    "KYC_APPROVAL": "WB_KYC_APPROVER",
    "ACCOUNT_OPENING": "WB_KYC_APPROVER",
    "LOAN_DECISION": "WB_CREDIT",
}

_QUEUE_SQL = """
SELECT p.request_id, p.request_type, p.target_kind, p.target_ref, p.amount, p.currency_code,
       p.reason, p.requested_by, p.requested_by_name, p.requested_at, p.hours_waiting,
       b.branch_code, b.branch_name
  FROM v_pending_approvals p
  LEFT JOIN branches b ON b.branch_id = p.branch_id
 WHERE (:scope = 'all' OR p.branch_id = :branch OR p.request_type = 'LOAN_DECISION')
 ORDER BY p.requested_at"""

_REQUEST_SQL = """
SELECT p.request_id, p.request_type, p.target_ref, p.requested_by
  FROM v_pending_approvals p WHERE p.request_id = :id"""


class ApproveIn(BaseModel):
    """Extra decisions some approvals need.

    KYC approval needs ``risk_rating``; a loan decision needs ``margin_pct`` and may
    change the amount or term (default: as requested).
    """

    risk_rating: RiskRating | None = None
    amount: Decimal | None = Field(default=None, gt=0, max_digits=15, decimal_places=2)
    term_months: int | None = Field(default=None, ge=1, le=360)
    margin_pct: Decimal | None = Field(default=None, ge=0, le=40, max_digits=5, decimal_places=2)


class RejectIn(BaseModel):
    """Why the request is refused (required)."""

    reason: Reason


def _pending(db: oracledb.Connection, request_id: int, employee_roles: list[str]) -> dict[str, Any]:
    request = row(db, _REQUEST_SQL, id=request_id)
    if request is None:
        raise ApiError(404, "NOT_FOUND", f"No pending request {request_id}.")
    role = DECIDER_ROLE.get(request["request_type"])
    if role not in employee_roles:
        raise ApiError(403, "ROLE_REQUIRED", "Your roles do not allow this decision.")
    return request


@router.get("")
def queue(
    db: Db, employee: CurrentEmployee, scope: Literal["branch", "all"] = "branch"
) -> list[dict[str, Any]]:
    """Pending requests (my branch's, plus loan decisions), oldest first.

    ``can_decide`` tells whether this employee may decide it: the right role, and
    not their own request.
    """
    queue_rows = rows(db, _QUEUE_SQL, scope=scope, branch=employee.branch_id)
    for item in queue_rows:
        item["can_decide"] = (
            DECIDER_ROLE.get(item["request_type"]) in employee.roles
            and item["requested_by"] != employee.employee_id
        )
    return queue_rows


@router.post("/{request_id}/approve")
def approve(request_id: int, body: ApproveIn, db: Db, employee: CurrentEmployee) -> dict[str, Any]:
    """Approve a pending request with the package procedure of its type."""
    request = _pending(db, request_id, employee.roles)
    kind, ref = request["request_type"], request["target_ref"]
    result: dict[str, Any] = {
        "request_id": request_id,
        "request_type": kind,
        "decision": "APPROVED",
    }
    with db.cursor() as cursor:
        if kind == "TXN_APPROVAL":
            cursor.callproc("pkg_posting.approve_transaction", [ref])
        elif kind == "TXN_REVERSAL":
            result["reversal_txn_ref"] = cursor.callfunc(
                "pkg_posting.approve_reversal", str, [request_id]
            )
        elif kind == "KYC_APPROVAL":
            if body.risk_rating is None:
                raise ApiError(422, "RISK_RATING_REQUIRED", "Choose the customer's risk rating.")
            cursor.callproc("pkg_customer.approve_kyc", [ref, body.risk_rating])
        elif kind == "ACCOUNT_OPENING":
            cursor.callproc("pkg_account.approve_account", [ref])
        elif kind == "LOAN_DECISION":
            if body.margin_pct is None:
                raise ApiError(422, "MARGIN_REQUIRED", "Set the margin over the reference rate.")
            app = row(
                db,
                """SELECT requested_amount, requested_term_months
                     FROM loan_applications WHERE application_no = :no""",
                no=ref,
            )
            if app is None:
                raise ApiError(404, "NOT_FOUND", f"No loan application {ref}.")
            cursor.callproc(
                "pkg_loan.approve_application",
                [
                    ref,
                    body.amount or Decimal(str(app["requested_amount"])),
                    body.term_months or app["requested_term_months"],
                    body.margin_pct,
                ],
            )
        else:
            raise ApiError(409, "UNKNOWN_REQUEST", f"Cannot approve requests of type {kind}.")
    db.commit()
    return result


@router.post("/{request_id}/reject")
def reject(request_id: int, body: RejectIn, db: Db, employee: CurrentEmployee) -> dict[str, Any]:
    """Reject a pending request; the reason is kept with it."""
    request = _pending(db, request_id, employee.roles)
    kind, ref = request["request_type"], request["target_ref"]
    procedures = {
        "TXN_APPROVAL": "pkg_posting.reject_transaction",
        "KYC_APPROVAL": "pkg_customer.reject_kyc",
        "ACCOUNT_OPENING": "pkg_account.reject_account",
        "LOAN_DECISION": "pkg_loan.reject_application",
    }
    if kind not in procedures:
        raise ApiError(
            409,
            "NOT_REJECTABLE",
            "A reversal request is approved or left to expire; it is not rejected.",
        )
    with db.cursor() as cursor:
        cursor.callproc(procedures[kind], [ref, body.reason])
    db.commit()
    return {"request_id": request_id, "request_type": kind, "decision": "REJECTED"}
