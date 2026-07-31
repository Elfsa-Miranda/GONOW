from __future__ import annotations

import ast
import re
from pathlib import Path


SERVICE_ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = SERVICE_ROOT / "app"
BANNED_DEPENDENCIES = {"anthropic", "langchain", "langgraph", "llama-index", "openai"}


def _source() -> str:
    return "\n".join(path.read_text(encoding="utf-8") for path in sorted(APP_ROOT.rglob("*.py")))


def _imports() -> set[str]:
    imported: set[str] = set()
    for path in APP_ROOT.rglob("*.py"):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module.split(".")[0])
    return imported


def test_no_model_or_graph_provider_imports() -> None:
    assert _imports().isdisjoint(BANNED_DEPENDENCIES)


def test_no_model_or_graph_dependencies_are_locked() -> None:
    pyproject = (SERVICE_ROOT / "pyproject.toml").read_text(encoding="utf-8").lower()
    lock = (SERVICE_ROOT / "uv.lock").read_text(encoding="utf-8").lower()
    assert all(f'name = "{name}"' not in lock for name in BANNED_DEPENDENCIES)
    assert all(f'"{name}' not in pyproject for name in BANNED_DEPENDENCIES)


def test_llm_tool_and_graph_execution_call_counts_are_zero() -> None:
    source = _source()
    llm_calls = len(re.findall(r"(?i)\b(?:chat|completion|responses)\.create\s*\(", source))
    tool_calls = len(re.findall(r"(?i)\btool[_ ]?call\s*\(", source))
    graph_runs = len(re.findall(r"(?i)\bgraph\.(?:invoke|ainvoke|stream)\s*\(", source))
    assert {"llm_calls": llm_calls, "tool_calls": tool_calls, "graph_runs": graph_runs} == {
        "llm_calls": 0,
        "tool_calls": 0,
        "graph_runs": 0,
    }


def test_no_supabase_or_domain_write_capability() -> None:
    imported = _imports()
    source = _source().lower()
    assert "supabase" not in imported
    assert "domain_command" not in source
    assert "production_write" not in source


def test_no_dynamic_execution_primitives() -> None:
    findings: list[tuple[str, int]] = []
    for path in APP_ROOT.rglob("*.py"):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in {"eval", "exec"}:
                findings.append((path.name, node.lineno))
    assert findings == []
