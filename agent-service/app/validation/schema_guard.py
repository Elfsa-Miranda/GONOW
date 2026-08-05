"""Typed output validation with at most two local, no-progress-aware repairs."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from typing import Any

from pydantic import BaseModel, ValidationError


class OutputSchemaError(ValueError):
    def __init__(self, code: str = "output.schema_invalid") -> None:
        self.code = code
        super().__init__(code)


RepairFunction = Callable[[object, int, tuple[str, ...]], object]


class OutputSchemaGuard:
    def __init__(self, schema_model: type[BaseModel] | None) -> None:
        self._schema_model = schema_model

    def validate(
        self,
        raw_value: object,
        *,
        repair: RepairFunction | None = None,
    ) -> BaseModel:
        if self._schema_model is None:
            raise OutputSchemaError()
        candidate = raw_value
        seen: set[str] = set()
        for repair_round in range(3):
            fingerprint = self._fingerprint(candidate)
            if fingerprint in seen:
                raise OutputSchemaError()
            seen.add(fingerprint)
            try:
                return self._schema_model.model_validate(candidate)
            except ValidationError as error:
                if repair is None or repair_round >= 2:
                    raise OutputSchemaError() from error
                issues = tuple(
                    ".".join(str(part) for part in issue["loc"]) for issue in error.errors()
                )
                try:
                    candidate = repair(candidate, repair_round + 1, issues)
                except Exception as repair_error:
                    raise OutputSchemaError() from repair_error
        raise OutputSchemaError()

    @staticmethod
    def _fingerprint(value: object) -> str:
        try:
            canonical = json.dumps(
                value,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                default=lambda item: {"unsupported_type": type(item).__name__},
            )
        except (TypeError, ValueError) as error:
            raise OutputSchemaError() from error
        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
