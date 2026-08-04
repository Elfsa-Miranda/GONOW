from pathlib import Path


def _source() -> str:
    return Path("migrations/versions/p12a_001_structured_memory.py").read_text(encoding="utf-8")


def test_every_memory_table_has_forced_rls() -> None:
    source = _source()
    assert "for table in TABLES" in source
    assert "ENABLE ROW LEVEL SECURITY" in source
    assert "FORCE ROW LEVEL SECURITY" in source


def test_rls_binds_tenant_and_principal() -> None:
    source = _source()
    assert "tenant_id = agent_runtime.current_tenant_id()" in source
    assert "principal_id = {SCHEMA}.current_principal_id()" in source
    assert "WITH CHECK" in source


def test_worker_cannot_update_formal_memory() -> None:
    source = _source()
    assert "GRANT SELECT, INSERT ON {SCHEMA}.candidates, {SCHEMA}.outbox_events TO agent_worker" in source
    assert "GRANT UPDATE ON ALL TABLES IN SCHEMA agent_memory TO agent_worker" not in source


def test_service_role_or_public_bypass_is_not_granted() -> None:
    source = _source()
    assert "TO service_role" not in source
    assert "TO PUBLIC" not in source.replace("REVOKE ALL", "")
