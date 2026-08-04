"""Deterministic Unicode-aware chunk construction for Knowledge ingestion."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass

from app.rag.parser import ParsedDocument


TOKEN_PATTERN = re.compile(r"[A-Za-z0-9]+(?:['._-][A-Za-z0-9]+)*|[^\s]", re.UNICODE)


class ChunkingError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class ChunkerConfig:
    max_tokens: int = 160
    overlap_tokens: int = 24
    max_chunks: int = 512

    def __post_init__(self) -> None:
        if not 8 <= self.max_tokens <= 2_048:
            raise ValueError("max_tokens must be between 8 and 2048")
        if not 0 <= self.overlap_tokens < self.max_tokens:
            raise ValueError("overlap_tokens must be smaller than max_tokens")
        if not 1 <= self.max_chunks <= 4_096:
            raise ValueError("max_chunks must be between 1 and 4096")


@dataclass(frozen=True, slots=True)
class ChunkDraft:
    ordinal: int
    text: str
    chunk_digest: str
    token_count: int
    start_character: int
    end_character: int

    def metadata_payload(self) -> dict[str, int]:
        return {
            "end_character": self.end_character,
            "start_character": self.start_character,
        }


class DeterministicChunker:
    """Split by stable token spans while retaining original normalized text."""

    CHUNKER_ID = "gonow.unicode-window"
    CHUNKER_VERSION = "1"

    def __init__(self, config: ChunkerConfig | None = None) -> None:
        self.config = config or ChunkerConfig()
        contract = {
            "chunker_id": self.CHUNKER_ID,
            "chunker_version": self.CHUNKER_VERSION,
            "max_chunks": self.config.max_chunks,
            "max_tokens": self.config.max_tokens,
            "overlap_tokens": self.config.overlap_tokens,
            "token_pattern": TOKEN_PATTERN.pattern,
        }
        self._config_digest = hashlib.sha256(
            json.dumps(contract, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

    @property
    def config_digest(self) -> str:
        return self._config_digest

    def chunk(self, document: ParsedDocument) -> tuple[ChunkDraft, ...]:
        spans = tuple(match.span() for match in TOKEN_PATTERN.finditer(document.text))
        if not spans:
            raise ChunkingError("ingestion.chunker.no_tokens")

        chunks: list[ChunkDraft] = []
        token_start = 0
        while token_start < len(spans):
            token_end = min(token_start + self.config.max_tokens, len(spans))
            start_character = spans[token_start][0]
            end_character = spans[token_end - 1][1]
            chunk_text = document.text[start_character:end_character].strip()
            if not chunk_text:
                raise ChunkingError("ingestion.chunker.empty_chunk")
            ordinal = len(chunks)
            chunk_digest = hashlib.sha256(
                f"{ordinal}\x00{chunk_text}".encode("utf-8")
            ).hexdigest()
            chunks.append(
                ChunkDraft(
                    ordinal=ordinal,
                    text=chunk_text,
                    chunk_digest=chunk_digest,
                    token_count=token_end - token_start,
                    start_character=start_character,
                    end_character=end_character,
                )
            )
            if len(chunks) > self.config.max_chunks:
                raise ChunkingError("ingestion.chunker.too_many_chunks")
            if token_end == len(spans):
                break
            next_start = token_end - self.config.overlap_tokens
            token_start = token_end if next_start <= token_start else next_start

        return tuple(chunks)
