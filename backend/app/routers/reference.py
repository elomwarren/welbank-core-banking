"""Reference data for forms and filters, and the staff directory."""

from typing import Any

from fastapi import APIRouter, Query

from ..db import rows
from ..deps import Db
from ..schemas import ENUMS

router = APIRouter(tags=["reference"])


@router.get("/api/reference")
def reference(db: Db) -> dict[str, Any]:
    """Products, branches, regions, countries, currencies and the allowed values of every list."""
    return {
        "account_products": rows(
            db,
            """SELECT product_code, product_name, account_type, currency_code, interest_rate,
                      min_opening_balance, monthly_fee, overdraft_allowed, term_months
                 FROM account_products WHERE is_active ORDER BY product_code""",
        ),
        "loan_products": rows(
            db,
            """SELECT product_code, product_name, currency_code, interest_rate, min_amount,
                      max_amount, max_term_months
                 FROM loan_products WHERE is_active ORDER BY product_code""",
        ),
        "branches": rows(
            db,
            """SELECT b.branch_id, b.branch_code, b.branch_name, r.region_name, b.status
                 FROM branches b JOIN regions r ON r.region_id = b.region_id
                ORDER BY r.region_name, b.branch_name""",
        ),
        "regions": rows(db, "SELECT region_id, region_name FROM regions ORDER BY region_name"),
        "countries": rows(
            db, "SELECT country_code, country_name FROM countries ORDER BY country_name"
        ),
        "currencies": rows(
            db, "SELECT currency_code, currency_name, symbol FROM currencies ORDER BY 1"
        ),
        "enums": ENUMS,
    }


@router.get("/api/staff")
def staff(
    db: Db,
    q: str | None = Query(default=None, max_length=60),
    branch: str | None = Query(default=None, max_length=12),
    take: int = Query(default=50, ge=1, le=200),
) -> list[dict[str, Any]]:
    """Search the staff directory (names, jobs, branches; no salaries)."""
    return rows(
        db,
        """SELECT employee_id, full_name, job_title, department_name, branch_code, branch_name,
                  work_email, phone, hire_date, status, db_username
             FROM v_staff_directory
            WHERE (:q IS NULL OR UPPER(full_name || ' ' || job_title || ' ' || db_username)
                                 LIKE '%' || UPPER(:q) || '%')
              AND (:branch IS NULL OR branch_code = :branch)
            ORDER BY branch_code, job_title, full_name
            FETCH FIRST :take ROWS ONLY""",
        q=q,
        branch=branch,
        take=take,
    )
