"""Allow sjv_collector to set ingest_receipts.status for R20.

Revision ID: 0004_receipt_status_update
Revises: 0003_retention
Create Date: 2026-11-27
"""

from pathlib import Path

from alembic import op

from sjv_db.sql_script import sql_statements

revision = "0004_receipt_status_update"
down_revision = "0003_retention"
branch_labels = None
depends_on = None

_HERE = Path(__file__).resolve().parent


def _execute_script(name: str) -> None:
    script = _HERE.joinpath(name).read_text(encoding="utf-8")
    for statement in sql_statements(script):
        op.execute(statement)


def upgrade() -> None:
    _execute_script("0004_post.sql")


def downgrade() -> None:
    raise RuntimeError(
        "This migration is forward-only. Restore the database from backup instead of downgrade."
    )
