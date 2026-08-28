from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.context_compiler import (  # noqa: E402
    ContextCompiler,
    ContextCompilerError,
    ContextKind,
    ContextSlice,
)


def _tokens(value: str) -> int:
    return len(value.encode("utf-8"))


def _required() -> tuple[ContextSlice, ...]:
    return (
        ContextSlice("request", ContextKind.REQUEST, "request", 80, required=True),
        ContextSlice("itinerary", ContextKind.ITINERARY, "{}", 70, required=True),
        ContextSlice("hard", ContextKind.HARD_CONSTRAINT, "never omit", 100),
    )


def test_12_context_compiler_s_is_deterministic() -> None:
    compiler = ContextCompiler(_tokens)
    assert compiler.compile(_required(), token_limit=10_000).digest == compiler.compile(
        reversed(_required()), token_limit=10_000
    ).digest


def test_12_context_compiler_i_refuses_hard_constraint_overflow() -> None:
    with pytest.raises(ContextCompilerError, match="context.required_slice_missing"):
        ContextCompiler(_tokens).compile(_required(), token_limit=1)


def test_12_context_compiler_i_rejects_unbounded_input() -> None:
    with pytest.raises(ContextCompilerError, match="context.input_invalid"):
        ContextCompiler(_tokens).compile((), token_limit=10)


def test_12_context_compiler_d_fails_closed_without_tokenizer() -> None:
    with pytest.raises(ContextCompilerError, match="context.tokenizer_unavailable"):
        ContextCompiler(lambda _: 0).compile(_required(), token_limit=10_000)
