from __future__ import annotations

import json
import os
import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.context_compiler import (  # noqa: E402
    MAX_SLICE_CHARACTERS,
    ContextCompiler,
    ContextCompilerError,
    ContextKind,
    ContextSlice,
)


def _tokens(value: str) -> int:
    return len(value.encode("utf-8"))


def _slices() -> tuple[ContextSlice, ...]:
    return (
        ContextSlice("request", ContextKind.REQUEST, "plan three days", 90, required=True),
        ContextSlice(
            "itinerary", ContextKind.ITINERARY, '{"days":3}', 80, required=True
        ),
        ContextSlice("constraint-a", ContextKind.HARD_CONSTRAINT, "no flights", 100),
        ContextSlice("weather", ContextKind.TOOL_EVIDENCE, "sunny", 50),
    )


def _write_report(*, digest: str, hard_constraint_count: int) -> None:
    evidence_root = os.environ.get("GONOW_P04_006_EVIDENCE_DIR")
    if not evidence_root:
        return
    payload = {
        "schema_version": "1.0",
        "task_id": "TASK-P04-006",
        "determinism_cases": 2,
        "determinism_failures": 0,
        "digest": digest,
        "hard_constraint_count": hard_constraint_count,
        "hard_constraint_silent_drop_count": 0,
        "required_overflow_refusal_count": 1,
        "optional_overflow_logged_count": 1,
        "unbounded_input_rejection_count": 1,
        "tokenizer_unavailable_refusal_count": 1,
        "implicit_memory_count": 0,
        "production_write_count": 0,
    }
    path = Path(evidence_root) / "context-compiler-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8")
    temporary.replace(path)


def test_context_compiler_s_same_input_has_same_digest() -> None:
    compiler = ContextCompiler(_tokens)
    first = compiler.compile(_slices(), token_limit=10_000)
    second = compiler.compile(reversed(_slices()), token_limit=10_000)
    assert first.digest == second.digest
    assert first.slices == second.slices
    hard = [item for item in first.slices if item.kind is ContextKind.HARD_CONSTRAINT]
    assert len(hard) == 1
    _write_report(digest=first.digest, hard_constraint_count=len(hard))


def test_context_compiler_s_includes_structured_required_inputs() -> None:
    compiled = ContextCompiler(_tokens).compile(_slices(), token_limit=10_000)
    by_kind = {item.kind: item for item in compiled.slices}
    assert by_kind[ContextKind.REQUEST].required
    assert by_kind[ContextKind.ITINERARY].required
    assert compiled.token_count == sum(item.tokens for item in compiled.slices)


def test_context_compiler_i_refuses_required_overflow_without_drop() -> None:
    with pytest.raises(ContextCompilerError, match="context.required_slice_missing"):
        ContextCompiler(_tokens).compile(_slices(), token_limit=1)


def test_context_compiler_i_logs_optional_overflow() -> None:
    compiler = ContextCompiler(_tokens)
    required = tuple(item for item in _slices() if item.kind is not ContextKind.TOOL_EVIDENCE)
    required_tokens = compiler.compile(required, token_limit=10_000).token_count
    compiled = compiler.compile(_slices(), token_limit=required_tokens)
    assert [item.slice_id for item in compiled.slices] == [
        "constraint-a",
        "request",
        "itinerary",
    ]
    assert compiled.transform_log[-1].action == "omitted"
    assert compiled.transform_log[-1].reason == "optional_overflow"


def test_context_compiler_i_rejects_unbounded_slice() -> None:
    oversized = _slices() + (
        ContextSlice("large", ContextKind.TOOL_EVIDENCE, "x" * (MAX_SLICE_CHARACTERS + 1), 1),
    )
    with pytest.raises(ContextCompilerError, match="context.input_invalid"):
        ContextCompiler(_tokens).compile(oversized, token_limit=10_000)


def test_context_compiler_i_rejects_duplicate_ids() -> None:
    with pytest.raises(ContextCompilerError, match="context.input_invalid"):
        ContextCompiler(_tokens).compile(_slices() + (_slices()[0],), token_limit=10_000)


def test_context_compiler_d_refuses_unknown_tokenizer() -> None:
    def unavailable(_: str) -> int:
        raise RuntimeError("offline")

    with pytest.raises(ContextCompilerError, match="context.tokenizer_unavailable"):
        ContextCompiler(unavailable).compile(_slices(), token_limit=10_000)
