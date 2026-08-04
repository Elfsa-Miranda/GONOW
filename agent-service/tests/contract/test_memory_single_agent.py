from pathlib import Path

import pytest

from app.memory.single_agent import MemoryReadPortConfig, SingleAgentMemoryReadPort
from tests.contract.test_memory_delete import NOW, delete_command, ready_record


def test_memory_package_has_no_multi_agent_coordinator_or_specialist() -> None:
    source = "\n".join(path.read_text(encoding="utf-8") for path in Path("app/memory").glob("*.py"))
    assert "coordinator" not in source.lower()
    assert "specialist" not in source.lower()
    assert "parallel branch" not in source.lower()


def test_memory_contract_contains_no_tool_or_model_execution_port() -> None:
    source = Path("app/memory/contracts.py").read_text(encoding="utf-8")
    assert "tool_call" not in source
    assert "model_client" not in source
    assert "prompt" not in source.lower()


def test_read_port_is_default_off_and_returns_no_memory() -> None:
    _, repo, context, consent, _ = ready_record()
    result = SingleAgentMemoryReadPort(repo).read(consent=consent, context=context, now=NOW)
    assert result.status == "disabled" and result.facts == () and result.materialized_count == 0


def test_enabled_port_returns_only_authorized_typed_fact() -> None:
    _, repo, context, consent, _ = ready_record()
    result = SingleAgentMemoryReadPort(repo, MemoryReadPortConfig(enabled=True, generation=1)).read(consent=consent, context=context, now=NOW)
    assert [(fact.memory_type.value, fact.value) for fact in result.facts] == [("dietary_requirement", "vegan")]


def test_missing_consent_denies_enabled_read() -> None:
    _, repo, context, _, _ = ready_record()
    with pytest.raises(PermissionError):
        SingleAgentMemoryReadPort(repo, MemoryReadPortConfig(enabled=True)).read(consent=None, context=context, now=NOW)


def test_cross_principal_read_materializes_nothing() -> None:
    _, repo, context, consent, _ = ready_record()
    intruder = context.model_copy(update={"principal_id": "user-b"})
    result = SingleAgentMemoryReadPort(repo, MemoryReadPortConfig(enabled=True)).read(consent=consent, context=intruder, now=NOW)
    assert result.facts == ()


def test_delete_and_conflict_are_not_materialized() -> None:
    service, repo, context, consent, memory_id = ready_record()
    service.delete_memory(command=delete_command(memory_id), context=context, now=NOW)
    result = SingleAgentMemoryReadPort(repo, MemoryReadPortConfig(enabled=True)).read(consent=consent, context=context, now=NOW)
    assert result.facts == ()


def test_kill_switch_restores_default_behavior_without_deleting_audit_state() -> None:
    _, repo, context, consent, memory_id = ready_record()
    port = SingleAgentMemoryReadPort(repo, MemoryReadPortConfig(enabled=True, generation=2))
    assert port.read(consent=consent, context=context, now=NOW).materialized_count == 1
    port.reconfigure(enabled=False, kill_switch=True)
    assert port.read(consent=consent, context=context, now=NOW).facts == ()
    assert repo.surface_status(memory_id)["record"] is False
