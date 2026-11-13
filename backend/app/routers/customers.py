"""Customers: search, the full record, and onboarding through pkg_customer.

Onboarding follows the Bank of Ghana's customer due diligence steps, each one a
package call: register (with address, mobile number and next of kin), capture
the photo and signature, verify the Ghana Card with the NIA (simulated here),
screen against sanctions lists (simulated), then submit for a branch manager's
approval (see approvals.py). Identity data is readable only by customer
service, approvers and auditors, and every read of it is audited by Oracle.
"""

import hashlib
import json
import secrets
from datetime import date
from decimal import Decimal
from typing import Annotated, Any, Literal

import oracledb
from fastapi import APIRouter, File, Form, Query, Response, UploadFile
from pydantic import BaseModel, Field, model_validator

from ..db import row, rows
from ..deps import Db, require_role
from ..errors import ApiError, oracle_code
from ..schemas import (
    AccountPurpose,
    AddressType,
    DocType,
    Employment,
    FileKind,
    IncomeBand,
    ProofType,
    Relationship,
    Sex,
    SourceOfFunds,
    Title,
    VerificationMethod,
)

router = APIRouter(prefix="/api/customers", tags=["customers"])

CUSTOMER_SERVICE = require_role("WB_CUSTOMER_SERVICE")
MAX_FILE_BYTES = 2 * 1024 * 1024
_MAGIC = {
    "image/png": (b"\x89PNG\r\n\x1a\n",),
    "image/jpeg": (b"\xff\xd8\xff",),
}

_SEARCH_SQL = """
SELECT c.customer_no, c.title, c.first_name, c.middle_name, c.last_name, c.sex, c.date_of_birth,
       c.nationality, c.kyc_status, c.status, c.risk_rating, b.branch_code, b.branch_name,
       c.created_at,
       (SELECT cc.phone FROM customer_contacts cc
         WHERE cc.customer_id = c.customer_id AND cc.contact_type = 'MOBILE'
         ORDER BY cc.is_primary DESC, cc.contact_id FETCH FIRST 1 ROW ONLY) AS mobile
  FROM customers c
  JOIN branches b ON b.branch_id = c.home_branch_id
 WHERE (:q IS NULL
        OR c.customer_no = UPPER(:q)
        OR UPPER(c.first_name || ' ' || c.last_name) LIKE '%' || UPPER(:q) || '%'
        OR EXISTS (SELECT 1 FROM customer_contacts cc
                    WHERE cc.customer_id = c.customer_id AND cc.phone LIKE '%' || :q || '%'))
   AND (:kyc IS NULL OR c.kyc_status = :kyc)
   AND (:branch IS NULL OR b.branch_code = :branch)
 ORDER BY c.customer_id DESC
 OFFSET :skip ROWS FETCH NEXT :take ROWS ONLY"""

_CUSTOMER_SQL = """
SELECT c.customer_id, c.customer_no, c.title, c.first_name, c.middle_name, c.last_name,
       c.previous_names, c.sex, c.date_of_birth, c.place_of_birth, c.nationality,
       c.country_of_residence, c.marital_status, c.employment_status, c.occupation,
       c.employer_name, c.income_band, c.source_of_funds, c.account_purpose,
       c.expected_monthly_volume, c.is_pep, c.pep_details, c.sanctions_status, c.risk_rating,
       c.due_diligence_level, c.kyc_status, c.kyc_deferral_until, c.kyc_approved_at,
       c.next_kyc_review_on, c.status, c.data_consent_at, c.marketing_consent, c.created_at,
       b.branch_code, b.branch_name, ap.full_name AS kyc_approved_by
  FROM customers c
  JOIN branches b ON b.branch_id = c.home_branch_id
  LEFT JOIN v_staff_directory ap ON ap.employee_id = c.kyc_approved_by
 WHERE c.customer_no = :no"""

_DETAIL_SQL = {
    "addresses": """
        SELECT a.address_type, a.address_line, a.town, r.region_name, a.country_code,
               a.digital_address, a.landmark, a.resident_since, a.proof_type, a.is_current
          FROM customer_addresses a LEFT JOIN regions r ON r.region_id = a.region_id
         WHERE a.customer_id = :id ORDER BY a.is_current DESC, a.address_id DESC""",
    "contacts": """
        SELECT contact_type, phone, email, is_primary, is_verified
          FROM customer_contacts WHERE customer_id = :id ORDER BY is_primary DESC, contact_id""",
    "next_of_kin": """
        SELECT full_name, relationship, phone, address FROM next_of_kin WHERE customer_id = :id""",
    "accounts": """
        SELECT a.account_no, a.account_name, p.product_code, p.product_name, a.currency_code,
               a.status, a.post_no_debit, a.ledger_balance, a.available_balance, h.holder_role,
               a.opened_on
          FROM account_holders h
          JOIN accounts a ON a.account_id = h.account_id
          LEFT JOIN account_products p ON p.product_id = a.product_id
         WHERE h.customer_id = :id AND a.account_class = 'CUSTOMER'
         ORDER BY a.account_id""",
    "loans": """
        SELECT l.loan_no, l.principal, l.interest_rate, l.term_months, l.disbursed_on,
               l.maturity_date, l.days_past_due, l.classification, l.status,
               la.ledger_balance AS outstanding
          FROM loans l
          JOIN loan_applications ap ON ap.application_id = l.application_id
          JOIN accounts la ON la.account_id = l.loan_account_id
         WHERE ap.customer_id = :id ORDER BY l.loan_id DESC""",
    "loan_applications": """
        SELECT application_no, requested_amount, requested_term_months, purpose, status,
               submitted_at, approved_amount, decision_note
          FROM loan_applications WHERE customer_id = :id ORDER BY application_id DESC""",
    "cards": """
        SELECT masked_pan, card_scheme, card_type, status, block_reason, expires_on
          FROM cards WHERE customer_id = :id ORDER BY card_id""",
}

_IDENTITY_SQL = {
    "documents": """
        SELECT doc_type, doc_number, issuing_country, expiry_date, is_primary
          FROM identity_documents WHERE customer_id = :id ORDER BY is_primary DESC""",
    "verifications": """
        SELECT purpose, method, result, nia_reference, error_code, is_simulated, performed_at
          FROM identity_verifications WHERE customer_id = :id ORDER BY verification_id DESC""",
    "files": """
        SELECT file_kind, mime_type, byte_size, captured_at
          FROM customer_files WHERE customer_id = :id AND is_current ORDER BY file_kind""",
}


class AddressIn(BaseModel):
    """The customer's current address."""

    address_type: AddressType = "RESIDENTIAL"
    address_line: str = Field(min_length=3, max_length=200)
    town: str = Field(min_length=2, max_length=80)
    region_id: int | None = None
    country: str = Field(default="GHA", min_length=3, max_length=3)
    digital_address: str | None = Field(default=None, max_length=20)
    landmark: str | None = Field(default=None, max_length=120)
    proof_type: ProofType | None = None
    proof_date: date | None = None

    @model_validator(mode="after")
    def ghana_needs_region(self) -> "AddressIn":
        """An address in Ghana names its region (one of the 16)."""
        if self.country == "GHA" and self.region_id is None:
            raise ValueError("choose the region of an address in Ghana")
        return self


class NextOfKinIn(BaseModel):
    """Who to contact for the customer."""

    full_name: str = Field(min_length=3, max_length=120)
    relationship: Relationship
    phone: str = Field(min_length=7, max_length=20)
    address: str | None = Field(default=None, max_length=200)


class CustomerIn(BaseModel):
    """A new customer, as captured at the counter."""

    title: Title | None = None
    first_name: str = Field(min_length=1, max_length=60)
    middle_name: str | None = Field(default=None, max_length=60)
    last_name: str = Field(min_length=1, max_length=60)
    sex: Sex
    date_of_birth: date
    place_of_birth: str | None = Field(default=None, max_length=80)
    nationality: str = Field(default="GHA", min_length=3, max_length=3)
    country_of_residence: str = Field(default="GHA", min_length=3, max_length=3)
    doc_type: DocType
    doc_number: str = Field(min_length=5, max_length=30)
    doc_country: str = Field(default="GHA", min_length=3, max_length=3)
    doc_expiry: date | None = None
    employment_status: Employment
    occupation: str | None = Field(default=None, max_length=80)
    employer_name: str | None = Field(default=None, max_length=120)
    income_band: IncomeBand
    source_of_funds: SourceOfFunds
    account_purpose: AccountPurpose
    expected_monthly_volume: Decimal = Field(ge=0, max_digits=15, decimal_places=2)
    is_pep: bool = False
    pep_details: str | None = Field(default=None, max_length=400)
    data_consent: bool
    marketing_consent: bool = False
    mobile: str = Field(min_length=7, max_length=20)
    email: str | None = Field(default=None, max_length=120, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    address: AddressIn
    next_of_kin: NextOfKinIn


class VerificationIn(BaseModel):
    """A (simulated) NIA check of the Ghana Card: the officer chooses the outcome to rehearse."""

    method: VerificationMethod = "FACE"
    outcome: Literal["MATCH", "NO_MATCH"] = "MATCH"


class ScreeningIn(BaseModel):
    """The (simulated) result of screening the name against sanctions lists."""

    result: Literal["CLEAR", "POTENTIAL_MATCH"] = "CLEAR"


def _customer(db: oracledb.Connection, customer_no: str) -> dict[str, Any]:
    found = row(db, _CUSTOMER_SQL, no=customer_no.upper())
    if found is None:
        raise ApiError(404, "NOT_FOUND", f"No customer {customer_no}.")
    return found


@router.get("")
def search_customers(
    db: Db,
    q: str | None = Query(default=None, max_length=60, description="number, name or phone"),
    kyc_status: str | None = Query(default=None, max_length=24),
    branch: str | None = Query(default=None, max_length=12),
    skip: int = Query(default=0, ge=0),
    take: int = Query(default=25, ge=1, le=100),
) -> list[dict[str, Any]]:
    """Search customers by number, name or phone, newest first."""
    return rows(db, _SEARCH_SQL, q=q, kyc=kyc_status, branch=branch, skip=skip, take=take)


@router.get("/{customer_no}")
def get_customer(customer_no: str, db: Db) -> dict[str, Any]:
    """The full customer record: KYC, addresses, contacts, accounts, loans, cards.

    Identity documents, NIA checks and files are included only for roles that may
    see them (``identity`` is null otherwise).
    """
    customer = _customer(db, customer_no)
    binds = {"id": customer.pop("customer_id")}
    result: dict[str, Any] = {"customer": customer}
    for key, sql in _DETAIL_SQL.items():
        result[key] = rows(db, sql, **binds)
    try:
        result["identity"] = {key: rows(db, sql, **binds) for key, sql in _IDENTITY_SQL.items()}
    except oracledb.DatabaseError as exc:
        if oracle_code(exc) != 942:
            raise
        result["identity"] = None
    try:
        with db.cursor() as cursor:
            result["kyc_missing"] = cursor.callfunc(
                "pkg_customer.kyc_missing", str, [customer["customer_no"]]
            )
    except oracledb.DatabaseError:
        result["kyc_missing"] = None
    return result


@router.post("", status_code=201, dependencies=[CUSTOMER_SERVICE])
def register_customer(body: CustomerIn, db: Db) -> dict[str, Any]:
    """Register a customer with address, mobile number and next of kin, in one transaction."""
    with db.cursor() as cursor:
        customer_no = cursor.callfunc(
            "pkg_customer.register_customer",
            str,
            keyword_parameters={
                "p_first_name": body.first_name,
                "p_last_name": body.last_name,
                "p_sex": body.sex,
                "p_date_of_birth": body.date_of_birth,
                "p_nationality": body.nationality,
                "p_doc_type": body.doc_type,
                "p_doc_number": body.doc_number,
                "p_employment_status": body.employment_status,
                "p_income_band": body.income_band,
                "p_source_of_funds": body.source_of_funds,
                "p_account_purpose": body.account_purpose,
                "p_expected_monthly_volume": body.expected_monthly_volume,
                "p_data_consent": body.data_consent,
                "p_middle_name": body.middle_name,
                "p_title": body.title,
                "p_place_of_birth": body.place_of_birth,
                "p_occupation": body.occupation,
                "p_employer_name": body.employer_name,
                "p_country_of_residence": body.country_of_residence,
                "p_doc_country": body.doc_country,
                "p_doc_expiry": body.doc_expiry,
                "p_is_pep": body.is_pep,
                "p_pep_details": body.pep_details,
                "p_marketing_consent": body.marketing_consent,
            },
        )
        address = body.address
        cursor.callproc(
            "pkg_customer.add_address",
            keyword_parameters={
                "p_customer_no": customer_no,
                "p_address_type": address.address_type,
                "p_address_line": address.address_line,
                "p_town": address.town,
                "p_region_id": address.region_id,
                "p_country": address.country,
                "p_digital_address": address.digital_address,
                "p_landmark": address.landmark,
                "p_proof_type": address.proof_type,
                "p_proof_date": address.proof_date,
            },
        )
        cursor.callproc("pkg_customer.add_contact", [customer_no, "MOBILE", body.mobile, True])
        if body.email:
            cursor.callproc("pkg_customer.add_contact", [customer_no, "EMAIL", body.email, False])
        kin = body.next_of_kin
        cursor.callproc(
            "pkg_customer.add_next_of_kin",
            [customer_no, kin.full_name, kin.relationship, kin.phone, kin.address],
        )
    db.commit()
    return {"customer_no": customer_no}


@router.post("/{customer_no}/files", status_code=201, dependencies=[CUSTOMER_SERVICE])
async def upload_file(
    customer_no: str,
    db: Db,
    kind: Annotated[FileKind, Form()],
    file: Annotated[UploadFile, File()],
) -> dict[str, Any]:
    """Store the customer's photo, signature or proof of address (PNG or JPEG, up to 2 MB).

    The content is checked, not just the file name: it must start like the image
    type it claims to be. ID cards are never stored (L.I. 2111, 2026).
    """
    content = await file.read(MAX_FILE_BYTES + 1)
    if len(content) > MAX_FILE_BYTES:
        raise ApiError(413, "FILE_TOO_LARGE", "Files are limited to 2 MB.")
    mime = file.content_type or ""
    if mime not in _MAGIC or not content.startswith(_MAGIC[mime]):
        raise ApiError(415, "NOT_AN_IMAGE", "Upload a PNG or JPEG image.")
    blob = db.createlob(oracledb.DB_TYPE_BLOB)
    blob.write(content)
    with db.cursor() as cursor:
        cursor.callproc(
            "pkg_customer.add_file",
            [customer_no.upper(), kind, mime, blob, hashlib.sha256(content).hexdigest()],
        )
    db.commit()
    return {"customer_no": customer_no.upper(), "kind": kind, "bytes": len(content)}


@router.get("/{customer_no}/files/{kind}")
def get_file(customer_no: str, kind: FileKind, db: Db) -> Response:
    """Return the customer's current photo, signature or proof of address."""
    found = row(
        db,
        """SELECT f.mime_type, f.content FROM customer_files f
             JOIN customers c ON c.customer_id = f.customer_id
            WHERE c.customer_no = :no AND f.file_kind = :kind AND f.is_current""",
        no=customer_no.upper(),
        kind=kind,
    )
    if found is None:
        raise ApiError(404, "NOT_FOUND", f"No {kind.lower()} on file.")
    return Response(
        content=found["content"],
        media_type=found["mime_type"],
        headers={"Cache-Control": "private, no-store"},
    )


@router.post("/{customer_no}/verification", dependencies=[CUSTOMER_SERVICE])
def verify_identity(customer_no: str, body: VerificationIn, db: Db) -> dict[str, Any]:
    """Record a Ghana Card check with the NIA (simulated: there is no NIA connection here).

    On a match, the NIA's own data (names, birth date, sex) is passed to the package,
    which takes it as the primary identity data.
    """
    customer = _customer(db, customer_no)
    nia_data = None
    reference = None
    if body.outcome == "MATCH":
        reference = f"NIA-SIM-{secrets.randbelow(10**8):08d}"
        nia_data = json.dumps(
            {
                "first_name": customer["first_name"],
                "last_name": customer["last_name"],
                "date_of_birth": f"{customer['date_of_birth']:%Y-%m-%d}",
                "sex": customer["sex"],
            }
        )
    with db.cursor() as cursor:
        verification_id = cursor.callfunc(
            "pkg_customer.record_verification",
            int,
            keyword_parameters={
                "p_customer_no": customer["customer_no"],
                "p_purpose": "ONBOARDING",
                "p_method": body.method,
                "p_result": body.outcome,
                "p_nia_reference": reference,
                "p_nia_data": nia_data,
                "p_is_simulated": True,
            },
        )
    db.commit()
    return {"verification_id": verification_id, "result": body.outcome, "nia_reference": reference}


@router.post("/{customer_no}/screening", dependencies=[CUSTOMER_SERVICE])
def record_screening(customer_no: str, body: ScreeningIn, db: Db) -> dict[str, Any]:
    """Record the sanctions screening result (simulated)."""
    with db.cursor() as cursor:
        cursor.callproc("pkg_customer.record_screening", [customer_no.upper(), body.result])
    db.commit()
    return {"customer_no": customer_no.upper(), "sanctions_status": body.result}


@router.post("/{customer_no}/submission", dependencies=[CUSTOMER_SERVICE])
def submit_kyc(customer_no: str, db: Db) -> dict[str, Any]:
    """Send the completed KYC to a branch manager for approval (maker-checker)."""
    with db.cursor() as cursor:
        cursor.callproc("pkg_customer.submit_kyc", [customer_no.upper()])
    db.commit()
    return {"customer_no": customer_no.upper(), "submitted": True}
