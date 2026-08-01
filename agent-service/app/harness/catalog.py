"""Safe, read-only loader and bidirectional index for the 34 Harness controls."""

from __future__ import annotations

import hashlib
import re
from collections import defaultdict
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any


CONTROL_IDS = tuple(range(1, 35))
CONTROL_FIELDS = frozenset(
    {"id", "name", "status", "first_phase", "test_file", "minimum_cases"}
)
ROOT_FIELDS = frozenset(
    {"schema_version", "status_model", "minimum_cases_total", "controls"}
)
ALLOWED_STATUSES = frozenset({"contract_only", "implemented", "not_applicable"})
TEST_PATH_PATTERN = re.compile(
    r"^agent-service/tests/unit/harness/test_([0-9]{2})_[a-z0-9_]+\.py$"
)

OWNER_TASK_BY_CONTROL: Mapping[int, str] = MappingProxyType(
    {
        1: "TASK-P02-003", 2: "TASK-P02-003", 3: "TASK-P02-003", 4: "TASK-P02-003",
        5: "TASK-P03-008", 6: "TASK-P02-003", 7: "TASK-P04-002", 8: "TASK-P04-002",
        9: "TASK-P04-004", 10: "TASK-P04-004", 11: "TASK-P03-004", 12: "TASK-P04-006",
        13: "TASK-P04-001", 14: "TASK-P06-004", 15: "TASK-P04-005", 16: "TASK-P04-005",
        17: "TASK-P04-005", 18: "TASK-P05-004", 19: "TASK-P04-004", 20: "TASK-P04-004",
        21: "TASK-P04-007", 22: "TASK-P04-007", 23: "TASK-P04-007", 24: "TASK-P05-003",
        25: "TASK-P03-002", 26: "TASK-P04-007", 27: "TASK-P02-004", 28: "TASK-P02-004",
        29: "TASK-P02-004", 30: "TASK-P04-010", 31: "TASK-P04-009", 32: "TASK-P02-002",
        33: "TASK-P02-007", 34: "TASK-P03-008",
    }
)

FAILURE_CODE_BY_CONTROL: Mapping[int, str] = MappingProxyType(
    {
        1: "context.invalid", 2: "auth.invalid_token", 3: "auth.forbidden",
        4: "tenant.scope_missing", 5: "idempotency.conflict", 6: "rate.limit",
        7: "budget.exhausted", 8: "budget.global_exhausted",
        9: "model.no_certified_route", 10: "llm.error", 11: "behavior.not_qualified",
        12: "context.required_slice_missing", 13: "state.invalid_delta",
        14: "interrupt.invalid", 15: "tool.unknown", 16: "tool.invalid_args",
        17: "tool.timeout", 18: "tool.invocation_conflict", 19: "provider.circuit_open",
        20: "retry.exhausted", 21: "output.schema_invalid", 22: "evidence.invalid",
        23: "citation.missing", 24: "checkpoint.unavailable",
        25: "event.sequence_conflict", 26: "candidate.invalid_projection",
        27: "privacy.redaction_failed", 28: "audit.unavailable",
        29: "telemetry.export_failed", 30: "eval.unavailable", 31: "feature.disabled",
        32: "secret.unavailable", 33: "schema.unsupported", 34: "consistency.stale_fence",
    }
)


CONTROL_LINE_PATTERN = re.compile(
    r"^  - \{id: (?P<id>[0-9]+), name: (?P<name>[A-Za-z0-9]+), "
    r"status: (?P<status>[a-z_]+), first_phase: (?P<phase>[A-Za-z0-9/]+), "
    r"test_file: (?P<path>[A-Za-z0-9_./-]+), minimum_cases: (?P<minimum>[0-9]+)\}$"
)


class HarnessMappingError(ValueError):
    def __init__(self, code: str = "harness.mapping_invalid") -> None:
        self.code = code
        super().__init__(code)


def _parse_frozen_yaml_subset(text: str) -> dict[str, Any]:
    """Parse only the canonical catalog syntax without adding a runtime YAML dependency."""

    lines = text.splitlines()
    expected_headers = (
        'schema_version: "1.0"',
        'status_model: "contract_only->implemented|not_applicable"',
        "minimum_cases_total: 149",
        "controls:",
    )
    if tuple(lines[:4]) != expected_headers or len(lines) != 38:
        raise HarnessMappingError()
    controls: list[dict[str, Any]] = []
    for line in lines[4:]:
        match = CONTROL_LINE_PATTERN.fullmatch(line)
        if match is None:
            raise HarnessMappingError()
        controls.append(
            {
                "id": int(match.group("id")),
                "name": match.group("name"),
                "status": match.group("status"),
                "first_phase": match.group("phase"),
                "test_file": match.group("path"),
                "minimum_cases": int(match.group("minimum")),
            }
        )
    return {
        "schema_version": "1.0",
        "status_model": "contract_only->implemented|not_applicable",
        "minimum_cases_total": 149,
        "controls": controls,
    }


@dataclass(frozen=True, slots=True)
class HarnessControl:
    id: int
    name: str
    status: str
    first_phase: str
    test_file: str
    minimum_cases: int
    owner_task: str
    failure_code: str


@dataclass(frozen=True, slots=True)
class HarnessCatalog:
    schema_version: str
    sha256: str
    controls: tuple[HarnessControl, ...]
    by_id: Mapping[int, HarnessControl]
    by_test_file: Mapping[str, HarnessControl]
    by_owner_task: Mapping[str, tuple[HarnessControl, ...]]
    by_first_phase: Mapping[str, tuple[HarnessControl, ...]]
    by_status: Mapping[str, tuple[HarnessControl, ...]]

    def control(self, control_id: int) -> HarnessControl:
        try:
            return self.by_id[control_id]
        except KeyError as error:
            raise HarnessMappingError("harness.control_unknown") from error

    def control_for_test(self, test_file: str) -> HarnessControl:
        try:
            return self.by_test_file[test_file]
        except KeyError as error:
            raise HarnessMappingError("harness.test_path_unknown") from error


def _group_index(
    controls: tuple[HarnessControl, ...], attribute: str
) -> Mapping[str, tuple[HarnessControl, ...]]:
    grouped: dict[str, list[HarnessControl]] = defaultdict(list)
    for control in controls:
        grouped[str(getattr(control, attribute))].append(control)
    return MappingProxyType({key: tuple(value) for key, value in sorted(grouped.items())})


def parse_harness_catalog(
    raw: bytes,
    *,
    repository_root: Path,
    verify_implemented_paths: bool = True,
    owner_task_by_control: Mapping[int, str] = OWNER_TASK_BY_CONTROL,
    failure_code_by_control: Mapping[int, str] = FAILURE_CODE_BY_CONTROL,
) -> HarnessCatalog:
    try:
        text = raw.decode("utf-8")
        if "\t" in text:
            raise HarnessMappingError()
        value = _parse_frozen_yaml_subset(text)
    except HarnessMappingError:
        raise
    except Exception as error:
        raise HarnessMappingError() from error
    if not isinstance(value, dict) or set(value) != ROOT_FIELDS:
        raise HarnessMappingError()
    if (
        value.get("schema_version") != "1.0"
        or value.get("status_model") != "contract_only->implemented|not_applicable"
        or value.get("minimum_cases_total") != 149
    ):
        raise HarnessMappingError()
    raw_controls = value.get("controls")
    if not isinstance(raw_controls, list) or len(raw_controls) != 34:
        raise HarnessMappingError()
    if set(owner_task_by_control) != set(CONTROL_IDS) or set(failure_code_by_control) != set(
        CONTROL_IDS
    ):
        raise HarnessMappingError("harness.owner_or_failure_mapping_incomplete")

    controls: list[HarnessControl] = []
    for expected_id, raw_control in zip(CONTROL_IDS, raw_controls, strict=True):
        if not isinstance(raw_control, dict) or set(raw_control) != CONTROL_FIELDS:
            raise HarnessMappingError()
        control_id = raw_control.get("id")
        status = raw_control.get("status")
        test_file = raw_control.get("test_file")
        match = TEST_PATH_PATTERN.fullmatch(test_file) if isinstance(test_file, str) else None
        if (
            control_id != expected_id
            or status not in ALLOWED_STATUSES
            or match is None
            or int(match.group(1)) != expected_id
            or not isinstance(raw_control.get("name"), str)
            or not raw_control["name"]
            or not isinstance(raw_control.get("first_phase"), str)
            or not raw_control["first_phase"]
            or not isinstance(raw_control.get("minimum_cases"), int)
            or raw_control["minimum_cases"] < 1
        ):
            raise HarnessMappingError()
        if status == "implemented" and verify_implemented_paths:
            path = (repository_root / test_file).resolve()
            try:
                path.relative_to(repository_root.resolve())
            except ValueError as error:
                raise HarnessMappingError() from error
            if not path.is_file():
                raise HarnessMappingError("harness.implemented_test_missing")
        controls.append(
            HarnessControl(
                id=expected_id,
                name=raw_control["name"],
                status=status,
                first_phase=raw_control["first_phase"],
                test_file=test_file,
                minimum_cases=raw_control["minimum_cases"],
                owner_task=owner_task_by_control[expected_id],
                failure_code=failure_code_by_control[expected_id],
            )
        )
    frozen = tuple(controls)
    if (
        sum(control.minimum_cases for control in frozen) != 149
        or len({control.name for control in frozen}) != 34
        or len({control.test_file for control in frozen}) != 34
    ):
        raise HarnessMappingError()
    return HarnessCatalog(
        schema_version="1.0",
        sha256=hashlib.sha256(raw).hexdigest(),
        controls=frozen,
        by_id=MappingProxyType({control.id: control for control in frozen}),
        by_test_file=MappingProxyType({control.test_file: control for control in frozen}),
        by_owner_task=_group_index(frozen, "owner_task"),
        by_first_phase=_group_index(frozen, "first_phase"),
        by_status=_group_index(frozen, "status"),
    )


def load_harness_catalog(catalog_path: Path, *, repository_root: Path) -> HarnessCatalog:
    resolved_root = repository_root.resolve()
    resolved_path = catalog_path.resolve()
    expected = (resolved_root / "docs/execution/schemas/harness-test-catalog.yaml").resolve()
    if resolved_path != expected or not resolved_path.is_file():
        raise HarnessMappingError("harness.catalog_path_invalid")
    before = resolved_path.read_bytes()
    catalog = parse_harness_catalog(before, repository_root=resolved_root)
    after = resolved_path.read_bytes()
    if before != after:
        raise HarnessMappingError("harness.catalog_mutated")
    return catalog
