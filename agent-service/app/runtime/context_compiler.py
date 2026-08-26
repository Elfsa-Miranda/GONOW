"""Deterministic, bounded context compilation without implicit memory."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from enum import StrEnum


MAX_CONTEXT_SLICES = 64
MAX_SLICE_CHARACTERS = 8_192
MAX_TOTAL_CHARACTERS = 32_768


class ContextCompilerError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


class ContextKind(StrEnum):
    HARD_CONSTRAINT = "hard_constraint"
    REQUEST = "request"
    ITINERARY = "itinerary"
    TOOL_EVIDENCE = "tool_evidence"


DEFAULT_REQUIRED_KINDS = frozenset({ContextKind.REQUEST, ContextKind.ITINERARY})


KIND_ORDER = {
    ContextKind.HARD_CONSTRAINT: 0,
    ContextKind.REQUEST: 1,
    ContextKind.ITINERARY: 2,
    ContextKind.TOOL_EVIDENCE: 3,
}


@dataclass(frozen=True, slots=True)
class ContextSlice:
    slice_id: str
    kind: ContextKind
    content: str
    priority: int
    required: bool = False


@dataclass(frozen=True, slots=True)
class CompiledSlice:
    slice_id: str
    kind: ContextKind
    content: str
    priority: int
    required: bool
    tokens: int


@dataclass(frozen=True, slots=True)
class TransformRecord:
    slice_id: str
    action: str
    reason: str
    tokens: int


@dataclass(frozen=True, slots=True)
class CompiledContext:
    schema_version: str
    slices: tuple[CompiledSlice, ...]
    transform_log: tuple[TransformRecord, ...]
    token_count: int
    token_limit: int
    digest: str


TokenCounter = Callable[[str], int]


class ContextCompiler:
    """Compile explicit request/itinerary/evidence slices under one token limit."""

    def __init__(self, token_counter: TokenCounter) -> None:
        if not callable(token_counter):
            raise ContextCompilerError("context.tokenizer_unavailable")
        self._token_counter = token_counter

    def compile(
        self,
        slices: Iterable[ContextSlice],
        *,
        token_limit: int,
        required_kinds: frozenset[ContextKind] | None = None,
    ) -> CompiledContext:
        materialized = tuple(slices)
        required = (
            DEFAULT_REQUIRED_KINDS
            if required_kinds is None
            else required_kinds
        )
        self._validate_input(
            materialized,
            token_limit=token_limit,
            required_kinds=required,
        )
        ranked = tuple(
            sorted(
                materialized,
                key=lambda item: (
                    not self._is_required(item, required),
                    -item.priority,
                    KIND_ORDER[item.kind],
                    item.slice_id,
                ),
            )
        )
        measured = tuple((item, self._count_tokens(item)) for item in ranked)
        required_tokens = sum(
            tokens for item, tokens in measured if self._is_required(item, required)
        )
        if required_tokens > token_limit:
            raise ContextCompilerError("context.required_slice_missing")

        included: list[CompiledSlice] = []
        transformations: list[TransformRecord] = []
        token_count = 0
        for item, tokens in measured:
            item_required = self._is_required(item, required)
            if item_required or token_count + tokens <= token_limit:
                included.append(
                    CompiledSlice(
                        slice_id=item.slice_id,
                        kind=item.kind,
                        content=item.content,
                        priority=item.priority,
                        required=item_required,
                        tokens=tokens,
                    )
                )
                token_count += tokens
                transformations.append(
                    TransformRecord(item.slice_id, "included", "priority_order", tokens)
                )
            else:
                transformations.append(
                    TransformRecord(item.slice_id, "omitted", "optional_overflow", tokens)
                )

        required_ids = {
            item.slice_id
            for item in materialized
            if self._is_required(item, required)
        }
        included_ids = {item.slice_id for item in included}
        if not required_ids.issubset(included_ids):
            raise ContextCompilerError("context.required_slice_missing")
        payload = {
            "schema_version": "1.0",
            "slices": [
                {
                    "slice_id": item.slice_id,
                    "kind": item.kind.value,
                    "content": item.content,
                    "priority": item.priority,
                    "required": item.required,
                    "tokens": item.tokens,
                }
                for item in included
            ],
            "transform_log": [
                {
                    "slice_id": item.slice_id,
                    "action": item.action,
                    "reason": item.reason,
                    "tokens": item.tokens,
                }
                for item in transformations
            ],
            "token_count": token_count,
            "token_limit": token_limit,
        }
        canonical = json.dumps(
            payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        return CompiledContext(
            schema_version="1.0",
            slices=tuple(included),
            transform_log=tuple(transformations),
            token_count=token_count,
            token_limit=token_limit,
            digest=hashlib.sha256(canonical).hexdigest(),
        )

    @staticmethod
    def _is_required(
        item: ContextSlice,
        required_kinds: frozenset[ContextKind],
    ) -> bool:
        return (
            item.required
            or item.kind is ContextKind.HARD_CONSTRAINT
            or item.kind in required_kinds
        )

    @staticmethod
    def _validate_input(
        slices: tuple[ContextSlice, ...],
        *,
        token_limit: int,
        required_kinds: frozenset[ContextKind],
    ) -> None:
        ids = [item.slice_id for item in slices]
        if (
            token_limit < 1
            or not slices
            or len(slices) > MAX_CONTEXT_SLICES
            or len(ids) != len(set(ids))
            or any(
                not item.slice_id
                or not item.content
                or len(item.content) > MAX_SLICE_CHARACTERS
                or item.priority < 0
                or item.priority > 100
                for item in slices
            )
            or sum(len(item.content) for item in slices) > MAX_TOTAL_CHARACTERS
        ):
            raise ContextCompilerError("context.input_invalid")
        kinds = {item.kind for item in slices}
        if not required_kinds or not required_kinds.issubset(kinds):
            raise ContextCompilerError("context.required_slice_missing")
        if any(
            item.kind in required_kinds
            and not item.required
            for item in slices
        ):
            raise ContextCompilerError("context.required_slice_missing")

    def _count_tokens(self, item: ContextSlice) -> int:
        segment = json.dumps(
            {
                "slice_id": item.slice_id,
                "kind": item.kind.value,
                "content": item.content,
            },
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        )
        try:
            count = self._token_counter(segment)
        except Exception as error:
            raise ContextCompilerError("context.tokenizer_unavailable") from error
        if isinstance(count, bool) or not isinstance(count, int) or count < 1:
            raise ContextCompilerError("context.tokenizer_unavailable")
        return count
