"""Lending through pkg_loan: applications, disbursement, repayment, the loan book.

Interest is reducing-balance (annuity); the rate is the Ghana Reference Rate
plus a margin decided by credit; arrears are classified with the Bank of Ghana
classes (Current, OLEM, Substandard, Doubtful, Loss) by the nightly job.
"""

from datetime import date
from decimal import Decimal
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field

from ..db import row, rows
from ..deps import Db, require_role
from ..errors import ApiError
from ..schemas import AccountNo, LoanPurpose, Money

router = APIRouter(tags=["loans"])

LENDING = require_role("WB_LOAN_OFFICER", "WB_CREDIT")

_LOAN_SQL = """
SELECT l.loan_id, l.loan_no, ap.application_no, c.customer_no,
       c.first_name || ' ' || c.last_name AS customer_name, p.product_code, p.product_name,
       l.principal, l.rate_type, l.reference_rate, l.margin_pct, l.interest_rate, l.term_months,
       l.disbursed_on, l.first_due_date, l.maturity_date, l.days_past_due, l.classification,
       l.status, l.closed_on, la.account_no AS loan_account_no, la.ledger_balance AS outstanding,
       da.account_no AS disbursement_account_no, b.branch_code
  FROM loans l
  JOIN loan_applications ap ON ap.application_id = l.application_id
  JOIN customers c ON c.customer_id = ap.customer_id
  JOIN loan_products p ON p.product_id = ap.product_id
  JOIN accounts la ON la.account_id = l.loan_account_id
  LEFT JOIN accounts da ON da.account_id = l.disbursement_account_id
  JOIN branches b ON b.branch_id = ap.branch_id"""


class ApplicationIn(BaseModel):
    """A loan application, prepared by a loan officer for a verified customer."""

    customer_no: str = Field(min_length=4, max_length=20)
    product_code: str = Field(min_length=3, max_length=20)
    amount: Money
    term_months: int = Field(ge=1, le=360)
    purpose: LoanPurpose
    purpose_details: str | None = Field(default=None, max_length=400)
    monthly_income: Money
    monthly_obligations: Decimal = Field(default=Decimal(0), ge=0, max_digits=15, decimal_places=2)


class DisbursementIn(BaseModel):
    """Pay an approved loan into the customer's account."""

    account_no: AccountNo
    first_due_date: date | None = None
    rate_type: Literal["FIXED", "VARIABLE"] = "VARIABLE"


class RepaymentIn(BaseModel):
    """A repayment taken from the customer's account."""

    account_no: AccountNo
    amount: Money


@router.get("/api/loans")
def list_loans(
    db: Db,
    status: str = Query(
        default="ACTIVE", max_length=12, description="ACTIVE, CLOSED, WRITTEN_OFF or ALL"
    ),
    classification: str | None = Query(default=None, max_length=12),
    branch: str | None = Query(default=None, max_length=12),
    skip: int = Query(default=0, ge=0),
    take: int = Query(default=50, ge=1, le=200),
) -> list[dict[str, Any]]:
    """The loan book, worst arrears first."""
    return rows(
        db,
        _LOAN_SQL
        + """
         WHERE (:status IS NULL OR l.status = :status)
           AND (:cls IS NULL OR l.classification = :cls)
           AND (:branch IS NULL OR b.branch_code = :branch)
         ORDER BY l.days_past_due DESC, l.loan_id DESC
         OFFSET :skip ROWS FETCH NEXT :take ROWS ONLY""",
        status=None if status == "ALL" else status,
        cls=classification,
        branch=branch,
        skip=skip,
        take=take,
    )


@router.get("/api/loans/schedule-preview", dependencies=[LENDING])
def schedule_preview(
    db: Db,
    principal: Annotated[Decimal, Query(gt=0, le=10_000_000)],
    annual_rate: Annotated[Decimal, Query(gt=0, le=100)],
    term_months: int = Query(ge=1, le=360),
    first_due_date: date | None = None,
) -> dict[str, Any]:
    """Quote a loan: the monthly installment and the full schedule (pipelined function)."""
    lines = rows(
        db,
        """SELECT installment_no, due_date, principal_due, interest_due, total_due, balance_after
             FROM TABLE(pkg_loan.schedule_preview(
                    :p, :r, :t, NVL(:d, ADD_MONTHS(TRUNC(SYSDATE), 1))))""",
        p=principal,
        r=annual_rate,
        t=term_months,
        d=first_due_date,
    )
    total = round(sum(line["total_due"] for line in lines), 2)
    return {
        "installment": lines[0]["total_due"] if lines else None,
        "total_repaid": total,
        "total_interest": round(total - float(principal), 2),
        "schedule": lines,
    }


@router.get("/api/loans/{loan_no}")
def get_loan(loan_no: str, db: Db) -> dict[str, Any]:
    """A loan with its schedule, repayments and what is due today."""
    loan = row(db, _LOAN_SQL + " WHERE l.loan_no = :no", no=loan_no)
    if loan is None:
        raise ApiError(404, "NOT_FOUND", f"No loan {loan_no}.")
    loan_id = loan.pop("loan_id")
    schedule = rows(
        db,
        """SELECT installment_no, due_date, principal_due, interest_due, total_due,
                  principal_paid, interest_paid, status, paid_on
             FROM loan_schedule WHERE loan_id = :id ORDER BY installment_no""",
        id=loan_id,
    )
    repayments = rows(
        db,
        """SELECT t.txn_ref, t.value_date, r.installment_no, r.principal_amount, r.interest_amount
             FROM loan_repayments r JOIN transactions t ON t.txn_id = r.txn_id
            WHERE r.loan_id = :id ORDER BY r.repayment_id DESC""",
        id=loan_id,
    )
    due_now = round(
        sum(
            line["total_due"] - line["principal_paid"] - line["interest_paid"]
            for line in schedule
            if line["due_date"].date() <= date.today() and line["status"] != "PAID"
        ),
        2,
    )
    return {"loan": loan, "due_now": due_now, "schedule": schedule, "repayments": repayments}


@router.post("/api/loans/{loan_no}/repayments", status_code=201, dependencies=[LENDING])
def repay(loan_no: str, body: RepaymentIn, db: Db) -> dict[str, Any]:
    """Repay what is due from the customer's account (interest first, then principal)."""
    with db.cursor() as cursor:
        ref = cursor.callfunc("pkg_loan.repay", str, [loan_no, body.account_no, body.amount])
    db.commit()
    return {"txn_ref": ref}


@router.get("/api/loan-applications")
def list_applications(
    db: Db,
    status: str | None = Query(default=None, max_length=16),
    take: int = Query(default=50, ge=1, le=200),
) -> list[dict[str, Any]]:
    """Loan applications, newest first."""
    return rows(
        db,
        """SELECT a.application_no, c.customer_no,
                  c.first_name || ' ' || c.last_name AS customer_name,
                  p.product_code, a.requested_amount, a.requested_term_months, a.purpose,
                  a.monthly_income, a.monthly_obligations, a.status, a.submitted_at,
                  a.approved_amount, a.approved_term_months, a.approved_margin_pct,
                  a.decision_note, o.full_name AS loan_officer, b.branch_code,
                  (SELECT l.loan_no FROM loans l
                    WHERE l.application_id = a.application_id) AS loan_no
             FROM loan_applications a
             JOIN customers c ON c.customer_id = a.customer_id
             JOIN loan_products p ON p.product_id = a.product_id
             JOIN branches b ON b.branch_id = a.branch_id
             LEFT JOIN v_staff_directory o ON o.employee_id = a.loan_officer_id
            WHERE (:status IS NULL OR a.status = :status)
            ORDER BY a.application_id DESC
            FETCH FIRST :take ROWS ONLY""",
        status=status,
        take=take,
    )


@router.post(
    "/api/loan-applications", status_code=201, dependencies=[require_role("WB_LOAN_OFFICER")]
)
def submit_application(body: ApplicationIn, db: Db) -> dict[str, Any]:
    """Submit an application; pkg_loan checks the product range and affordability."""
    with db.cursor() as cursor:
        application_no = cursor.callfunc(
            "pkg_loan.submit_application",
            str,
            keyword_parameters={
                "p_customer_no": body.customer_no.upper(),
                "p_product_code": body.product_code.upper(),
                "p_amount": body.amount,
                "p_term_months": body.term_months,
                "p_purpose": body.purpose,
                "p_monthly_income": body.monthly_income,
                "p_monthly_obligations": body.monthly_obligations,
                "p_purpose_details": body.purpose_details,
            },
        )
    db.commit()
    return {
        "application_no": application_no,
        "message": "Submitted: waiting for a credit decision.",
    }


@router.post(
    "/api/loan-applications/{application_no}/disbursement",
    status_code=201,
    dependencies=[require_role("WB_CREDIT")],
)
def disburse(application_no: str, body: DisbursementIn, db: Db) -> dict[str, Any]:
    """Disburse an approved loan: open the loan account, pay out, build the schedule."""
    with db.cursor() as cursor:
        loan_no = cursor.callfunc(
            "pkg_loan.disburse",
            str,
            [application_no, body.account_no, body.first_due_date, body.rate_type],
        )
    db.commit()
    return {"loan_no": loan_no}
