"""Store envelope items for evaluation after a restart.

Revision ID: 0002_payload_items
Revises: 0001_ingest_schema
Create Date: 2026-11-21
"""

from pathlib import Path

from alembic import op
from sqlalchemy.sql.ddl import SchemaGenerator

from sjv_db.metadata import ingest_payload_items
from sjv_db.sql_script import sql_statements

revision = "0002_payload_items"
down_revision = "0001_ingest_schema"
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
    SchemaGenerator(bind.dialect, bind, checkfirst=True).traverse_single(ingest_payload_items)
    _execute_script("0002_post.sql")


def downgrade() -> None:
    raise RuntimeError(
        "This migration is forward-only. Restore the database from backup instead of downgrade."
    )
