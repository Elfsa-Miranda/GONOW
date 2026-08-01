from __future__ import annotations

import ast
import re
from pathlib import Path


SERVICE_ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = SERVICE_ROOT / "app"
RESEARCH_ROOT = APP_ROOT / "runtime" / "research"
BANNED_DEPENDENCIES = {"anthropic", "langchain", "llama-index", "openai"}
BANNED_RESEARCH_WRITE_IDENTIFIERS = {
    "domain_command",
    "execute_domain_command",
    "production_write",
    "supabase",
}
LOCKED_LANGGRAPH_VERSION = "1.2.9"


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


def _research_write_capability_findings() -> list[tuple[str, int, str]]:
    findings: list[tuple[str, int, str]] = []
    for path in RESEARCH_ROOT.rglob("*.py"):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            names: list[str] = []
            if isinstance(node, ast.Import):
                names.extend(alias.name.lower() for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                names.append(node.module.lower())
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                names.append(node.name.lower())
            elif isinstance(node, ast.Call):
                if isinstance(node.func, ast.Name):
                    names.append(node.func.id.lower())
                elif isinstance(node.func, ast.Attribute):
                    names.append(node.func.attr.lower())
            for name in names:
                normalized = name.replace(".", "_")
                if any(marker in normalized for marker in BANNED_RESEARCH_WRITE_IDENTIFIERS):
                    findings.append((path.name, node.lineno, name))
    return findings


def test_no_model_provider_or_unapproved_framework_imports() -> None:
    assert _imports().isdisjoint(BANNED_DEPENDENCIES)


def test_only_approved_graph_dependency_is_locked() -> None:
    pyproject = (SERVICE_ROOT / "pyproject.toml").read_text(encoding="utf-8").lower()
    lock = (SERVICE_ROOT / "uv.lock").read_text(encoding="utf-8").lower()
    assert all(f'name = "{name}"' not in lock for name in BANNED_DEPENDENCIES)
    assert all(f'"{name}' not in pyproject for name in BANNED_DEPENDENCIES)
    assert f'"langgraph=={LOCKED_LANGGRAPH_VERSION}"' in pyproject
    assert (
        'name = "langgraph"' in lock
        and f'version = "{LOCKED_LANGGRAPH_VERSION}"' in lock
    )


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
    assert "supabase" not in imported
    assert _research_write_capability_findings() == []


def test_no_dynamic_execution_primitives() -> None:
    findings: list[tuple[str, int]] = []
    for path in APP_ROOT.rglob("*.py"):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in {"eval", "exec"}:
                findings.append((path.name, node.lineno))
    assert findings == []
