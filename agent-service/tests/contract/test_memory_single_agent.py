from pathlib import Path


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
