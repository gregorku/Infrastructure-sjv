"""Ingest schema and sjv_collector privileges.

The SQLAlchemy metadata owns tables, keys, checks and indexes.
Partitions, triggers and grants stay in SQL because they are not ordinary tables.

Revision ID: 0001_ingest_schema
Revises:
Create Date: 2026-11-20
"""

from pathlib import Path

from alembic import op
from sqlalchemy.sql.ddl import SchemaGenerator

from sjv_db.metadata import metadata
from sjv_db.sql_script import sql_statements

revision = "0001_ingest_schema"
down_revision = None
branch_labels = None
depends_on = None

_HERE = Path(__file__).resolve().parent


def _execute_script(name: str) -> None:
    script = _HERE.joinpath(name).read_text(encoding="utf-8")
    for statement in sql_statements(script):
        op.execute(statement)


def upgrade() -> None:
    _execute_script("0001_pre.sql")
    bind = op.get_bind()
    generator = SchemaGenerator(bind.dialect, bind, checkfirst=True)
    # Later revisions add tables this revision did not create.
    for table in metadata.sorted_tables:
        if table.name in ("ingest_payload_items", "retention_log"):
            continue
        generator.traverse_single(table)
    _execute_script("0001_post.sql")


def downgrade() -> None:
    raise RuntimeError(
        "This migration is forward-only. Restore the database from backup instead of downgrade."
    )
