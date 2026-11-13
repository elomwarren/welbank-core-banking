"""The WEL Bank web API.

Run (development):  cd backend && uv run uvicorn app.main:app --reload
Docs:               http://127.0.0.1:8000/api/docs
"""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import oracledb
from fastapi import FastAPI, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.base import RequestResponseEndpoint
from starlette.responses import Response

from .config import get_settings
from .db import PoolRegistry
from .errors import ApiError, from_oracle
from .routers import (
    accounts,
    admin,
    approvals,
    auth,
    customers,
    dashboard,
    loans,
    reference,
    reports,
    transactions,
)
from .sessions import SessionStore

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Create the pool registry and the session store; close every pool at shutdown."""
    settings = get_settings()
    app.state.settings = settings
    app.state.pools = PoolRegistry(settings)
    app.state.sessions = SessionStore(
        idle_seconds=settings.session_idle_minutes * 60,
        max_seconds=settings.session_max_hours * 3600,
    )
    yield
    app.state.pools.close_all()


app = FastAPI(
    title="WEL Bank API",
    version="1.0.0",
    description=(
        "Internal banking API. Every request runs in Oracle as the logged-in employee "
        "(proxy authentication through WB_APP); the PL/SQL packages hold the business rules."
    ),
    lifespan=lifespan,
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
    redoc_url=None,
)

for module in (
    auth,
    reference,
    dashboard,
    customers,
    accounts,
    transactions,
    approvals,
    loans,
    reports,
    admin,
):
    app.include_router(module.router)


@app.exception_handler(ApiError)
async def api_error(_request: Request, exc: ApiError) -> JSONResponse:
    """Answer with the error's status, code and message."""
    return JSONResponse({"code": exc.code, "message": exc.message}, status_code=exc.status_code)


@app.exception_handler(oracledb.Error)
async def oracle_error(_request: Request, exc: oracledb.Error) -> JSONResponse:
    """Turn an Oracle error into a clear answer (business rules keep their message)."""
    error = from_oracle(exc)
    return JSONResponse(
        {"code": error.code, "message": error.message}, status_code=error.status_code
    )


@app.exception_handler(RequestValidationError)
async def invalid_input(_request: Request, exc: RequestValidationError) -> JSONResponse:
    """Explain the first problem in the request, and list them all for forms."""
    errors = jsonable_encoder(exc.errors())
    first = errors[0] if errors else {}
    field = ".".join(str(part) for part in first.get("loc", [])[1:]) or "request"
    return JSONResponse(
        {
            "code": "INVALID_INPUT",
            "message": f"{field}: {first.get('msg', 'invalid')}",
            "errors": errors,
        },
        status_code=422,
    )


@app.middleware("http")
async def security_headers(request: Request, call_next: RequestResponseEndpoint) -> Response:
    """Add security headers; API answers are never cached."""
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "same-origin"
    if request.url.path.startswith("/api/") and "Cache-Control" not in response.headers:
        response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/api/health", tags=["health"])
def health() -> dict[str, str]:
    """Liveness check for Docker and the reverse proxy."""
    return {"status": "ok"}
