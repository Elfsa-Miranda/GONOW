from importlib import import_module
from pathlib import Path


def test_memory_migration_is_single_head_after_domain_command() -> None:
    migration = import_module("migrations.versions.p12a_001_structured_memory")
    assert migration.revision == "p12a_001_memory"
    assert migration.down_revision == "p12d_001_commands"
    assert migration.TABLES == ("consent_events", "candidates", "records", "derivatives", "tombstones", "command_attempts", "outbox_events")


def test_restore_contract_replays_consent_and_tombstone_surfaces() -> None:
    source = Path("migrations/versions/p12a_001_structured_memory.py").read_text(encoding="utf-8")
    assert "tombstones" in source
    assert "restore_ledger" in source
    assert "deletion_generation >= 1" in source
    assert "DROP SCHEMA IF EXISTS" in source


def test_schema_is_isolated_and_public_access_is_revoked() -> None:
    migration = import_module("migrations.versions.p12a_001_structured_memory")
    source = Path("migrations/versions/p12a_001_structured_memory.py").read_text(encoding="utf-8")
    assert migration.SCHEMA == "agent_memory"
    assert "CREATE SCHEMA IF NOT EXISTS {SCHEMA}" in source
    assert "REVOKE ALL" in source
    assert "production" not in source.lower()
