"""Shared field types: the allowed values come from the CHECK constraints of the schema."""

from decimal import Decimal
from typing import Annotated, Literal, get_args

from pydantic import Field

Money = Annotated[Decimal, Field(gt=0, max_digits=15, decimal_places=2)]
AccountNo = Annotated[str, Field(min_length=6, max_length=20, pattern=r"^[0-9A-Z-]+$")]
Reason = Annotated[str, Field(min_length=3, max_length=400)]
Narration = Annotated[str | None, Field(default=None, max_length=140)]

Title = Literal["MR", "MRS", "MS", "MISS", "DR", "PROF", "REV", "HON", "NANA"]
Sex = Literal["FEMALE", "MALE"]
Employment = Literal["EMPLOYED", "SELF_EMPLOYED", "STUDENT", "RETIRED", "UNEMPLOYED"]
IncomeBand = Literal["UNDER_1K", "1K_5K", "5K_10K", "10K_50K", "OVER_50K"]
SourceOfFunds = Literal[
    "SALARY", "BUSINESS", "SAVINGS", "PENSION", "REMITTANCE", "INVESTMENT", "GIFT", "OTHER"
]
AccountPurpose = Literal["SAVINGS", "SALARY", "BUSINESS", "INVESTMENT", "REMITTANCE", "OTHER"]
DocType = Literal[
    "GHANA_CARD", "NON_CITIZEN_CARD", "REFUGEE_CARD", "PASSPORT", "DIPLOMATIC_PASSPORT"
]
AddressType = Literal["RESIDENTIAL", "POSTAL", "WORK"]
ProofType = Literal[
    "UTILITY_BILL", "TENANCY_AGREEMENT", "EMPLOYER_LETTER", "LANDLORD_LETTER", "BANK_STATEMENT"
]
Relationship = Literal["SPOUSE", "PARENT", "CHILD", "SIBLING", "RELATIVE", "FRIEND", "OTHER"]
VerificationMethod = Literal["FACE", "SINGLE_FINGER", "LIVENESS", "NO_CARD_PRESENT"]
FileKind = Literal["PHOTO", "SIGNATURE", "PROOF_OF_ADDRESS"]
RiskRating = Literal["LOW", "MEDIUM", "HIGH"]
LoanPurpose = Literal[
    "PERSONAL", "EDUCATION", "BUSINESS", "HOUSING", "VEHICLE", "MEDICAL", "AGRICULTURE", "OTHER"
]

ENUMS: dict[str, list[str]] = {
    "title": list(get_args(Title)),
    "sex": list(get_args(Sex)),
    "employment_status": list(get_args(Employment)),
    "income_band": list(get_args(IncomeBand)),
    "source_of_funds": list(get_args(SourceOfFunds)),
    "account_purpose": list(get_args(AccountPurpose)),
    "doc_type": list(get_args(DocType)),
    "address_type": list(get_args(AddressType)),
    "proof_type": list(get_args(ProofType)),
    "relationship": list(get_args(Relationship)),
    "verification_method": list(get_args(VerificationMethod)),
    "file_kind": list(get_args(FileKind)),
    "risk_rating": list(get_args(RiskRating)),
    "loan_purpose": list(get_args(LoanPurpose)),
}
