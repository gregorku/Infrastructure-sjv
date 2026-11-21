"""Retention of ingest months older than 24 months.

Revision ID: 0003_retention
Revises: 0002_payload_items
Create Date: 2026-11-21
"""

from pathlib import Path

from alembic import op
from sqlalchemy.sql.ddl import SchemaGenerator

from sjv_db.metadata import retention_log
from sjv_db.sql_script import sql_statements

revision = "0003_retention"
down_revision = "0002_payload_items"
branch_labels = None
depends_on = None

_HERE = Path(__file__).resolve().parent


def _execute_script(name: str) -> None:
    script = _HERE.joinpath(name).read_text(encoding="utf-8")
    for statement in sql_statements(script):
        op.execute(statement)


def upgrade() -> None:
    op.execute("SET ROLE sjv_owner")
    bind = op.get_bind()
    SchemaGenerator(bind.dialect, bind, checkfirst=True).traverse_single(retention_log)
    _execute_script("0003_post.sql")


def downgrade() -> None:
    raise RuntimeError(
        "This migration is forward-only. Restore the database from backup instead of downgrade."
    )
