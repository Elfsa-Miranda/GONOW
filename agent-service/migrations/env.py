from __future__ import annotations

import os
import re
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool
from sqlalchemy.engine import Connection


DATABASE_URL_ENV = "GONOW_DATABASE_URL"
VERSION_SCHEMA_ENV = "GONOW_ALEMBIC_VERSION_SCHEMA"
SCHEMA_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,62}$")

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = None


def _database_url() -> str:
    value = os.environ.get(DATABASE_URL_ENV, "").strip()
    if not value:
        raise RuntimeError(f"{DATABASE_URL_ENV} is required for database migrations")
    return value


def _version_table_schema() -> str | None:
    value = os.environ.get(VERSION_SCHEMA_ENV, "").strip()
    if not value:
        return None
    if SCHEMA_PATTERN.fullmatch(value) is None:
        raise RuntimeError(f"{VERSION_SCHEMA_ENV} must be a lowercase PostgreSQL identifier")
    return value


def _configure(connection: Connection | None = None) -> None:
    options = {
        "target_metadata": target_metadata,
        "version_table_schema": _version_table_schema(),
        "compare_type": True,
        "compare_server_default": True,
    }
    if connection is None:
        context.configure(
            url=_database_url(),
            literal_binds=True,
            dialect_opts={"paramstyle": "named"},
            **options,
        )
        return
    context.configure(connection=connection, **options)


def run_migrations_offline() -> None:
    _configure()
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    escaped_url = _database_url().replace("%", "%%")
    config.set_main_option("sqlalchemy.url", escaped_url)
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        _configure(connection)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
