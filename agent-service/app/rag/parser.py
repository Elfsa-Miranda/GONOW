"""Deterministic, bounded parsing for approved ingestion inputs.

This module deliberately contains no source-policy decisions.  Callers must finish
authorization before passing document bytes to the parser.
"""

from __future__ import annotations

import hashlib
import json
import unicodedata
from dataclasses import dataclass
from typing import Protocol


class DocumentParseError(ValueError):
    """A stable, non-content-bearing ingestion parse failure."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class ParsedDocument:
    text: str
    media_type: str
    content_digest: str
    parser_digest: str
    character_count: int


class DocumentParser(Protocol):
    @property
    def parser_digest(self) -> str: ...

    def parse(self, *, payload: bytes, media_type: str) -> ParsedDocument: ...


class DeterministicTextParser:
    """Normalize bounded UTF-8 text without network or locale dependencies."""

    PARSER_ID = "gonow.deterministic-text"
    PARSER_VERSION = "1"
    SUPPORTED_MEDIA_TYPES = frozenset(
        {
            "text/plain",
            "text/markdown",
        }
    )

    def __init__(self, *, max_bytes: int = 2_000_000) -> None:
        if not 1 <= max_bytes <= 10_000_000:
            raise ValueError("parser max_bytes must be between 1 and 10000000")
        self._max_bytes = max_bytes
        contract = {
            "max_bytes": max_bytes,
            "normalization": "utf8-sig+nfc+lf+rstrip+outer-strip",
            "parser_id": self.PARSER_ID,
            "parser_version": self.PARSER_VERSION,
            "supported_media_types": sorted(self.SUPPORTED_MEDIA_TYPES),
        }
        self._parser_digest = hashlib.sha256(
            json.dumps(contract, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

    @property
    def parser_digest(self) -> str:
        return self._parser_digest

    def parse(self, *, payload: bytes, media_type: str) -> ParsedDocument:
        if media_type not in self.SUPPORTED_MEDIA_TYPES:
            raise DocumentParseError("ingestion.parser.unsupported_media_type")
        if not isinstance(payload, bytes) or not payload:
            raise DocumentParseError("ingestion.parser.empty_payload")
        if len(payload) > self._max_bytes:
            raise DocumentParseError("ingestion.parser.payload_too_large")
        try:
            decoded = payload.decode("utf-8-sig", errors="strict")
        except UnicodeDecodeError as exc:
            raise DocumentParseError("ingestion.parser.invalid_utf8") from exc

        normalized = unicodedata.normalize("NFC", decoded)
        normalized = normalized.replace("\r\n", "\n").replace("\r", "\n")
        if any(
            unicodedata.category(character) == "Cc"
            and character not in {"\n", "\t"}
            for character in normalized
        ):
            raise DocumentParseError("ingestion.parser.forbidden_control_character")
        normalized = "\n".join(
            line.rstrip(" \t") for line in normalized.split("\n")
        ).strip()
        if not normalized:
            raise DocumentParseError("ingestion.parser.empty_document")
        content_digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
        return ParsedDocument(
            text=normalized,
            media_type=media_type,
            content_digest=content_digest,
            parser_digest=self._parser_digest,
            character_count=len(normalized),
        )
