"""Alembic environment. The database URL comes from SJV_DATABASE_URL."""

import os
import re
from logging.config import fileConfig
from pathlib import Path
import sys

from alembic import context
from alembic.operations import ops
from sqlalchemy import engine_from_config, pool
from sqlalchemy.dialects.postgresql.base import PGDialect

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from sjv_db.metadata import metadata

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = metadata
_PARTITION = re.compile(r".+_p\d{6}$")


def include_object(obj, name, type_, reflected, compare_to):
    if type_ == "table" and name is not None and _PARTITION.fullmatch(name):
        return False
    return True


_original_foreign_keys = PGDialect.get_multi_foreign_keys


def _foreign_keys_without_partition_targets(
    self,
    connection,
    schema,
    filter_names,
    scope,
    kind,
    postgresql_ignore_search_path=False,
    **kw,
):
    """PostgreSQL adds one foreign key per partition. The model keeps the parent key."""
    rows = _original_foreign_keys(
        self,
        connection,
        schema,
        filter_names,
        scope,
        kind,
        postgresql_ignore_search_path=postgresql_ignore_search_path,
        **kw,
    )
    if not isinstance(rows, dict):
        rows = dict(rows)
    for key, constraints in rows.items():
        rows[key] = [
            constraint
            for constraint in constraints
            if not _PARTITION.fullmatch(constraint.get("referred_table") or "")
        ]
    return rows


PGDialect.get_multi_foreign_keys = _foreign_keys_without_partition_targets


def _without_partitions(operations):
    kept = []
    for operation in operations:
        table_name = getattr(operation, "table_name", None)
        if table_name and _PARTITION.fullmatch(str(table_name)):
            continue
        if isinstance(operation, ops.ModifyTableOps):
            operation.ops = _without_partitions(operation.ops)
            if not operation.ops:
                continue
        constraint_name = getattr(operation, "constraint_name", None) or ""
        if _PARTITION.search(str(constraint_name)):
            continue
        kept.append(operation)
    return kept


def process_revision_directives(context_, revision, directives):
    script = directives[0]
    if script.upgrade_ops is not None:
        script.upgrade_ops.ops = _without_partitions(script.upgrade_ops.ops)
    if script.downgrade_ops is not None:
        script.downgrade_ops.ops = _without_partitions(script.downgrade_ops.ops)


def _database_url() -> str:
    url = os.environ.get("SJV_DATABASE_URL", "")
    if not url:
        raise RuntimeError("SJV_DATABASE_URL is required and must not be stored in the migration files.")
    return url


def run_migrations_offline() -> None:
    context.configure(
        url=_database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        include_object=include_object,
        compare_type=True,
        compare_server_default=False,
        process_revision_directives=process_revision_directives,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    section = config.get_section(config.config_ini_section, {})
    section["sqlalchemy.url"] = _database_url()
    connectable = engine_from_config(section, prefix="sqlalchemy.", poolclass=pool.NullPool)
    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            include_object=include_object,
            compare_type=True,
            compare_server_default=False,
            process_revision_directives=process_revision_directives,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
