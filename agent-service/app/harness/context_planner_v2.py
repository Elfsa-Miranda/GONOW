"""Fail-closed Phase 13 extension over the immutable 34-control Harness Catalog."""

from __future__ import annotations

import json
from pathlib import Path
import re
from typing import Any

from app.harness.catalog import CONTROL_IDS, HarnessMappingError


FAILURE_PATTERN = re.compile(r"^[a-z][a-z0-9_.]{2,127}$")
PATH_PATTERN = re.compile(r"^(agent-service/tests|docs/execution/evidence)/[A-Za-z0-9_./-]+$")


def load_context_planner_harness_mapping(
    path: Path,
    *,
    repository_root: Path,
) -> dict[str, Any]:
    expected = (
        repository_root
        / "docs/execution/schemas/context-planner-v2-harness-mapping.json"
    ).resolve()
    if path.resolve() != expected or not path.is_file():
        raise HarnessMappingError("harness.catalog_path_invalid")
    before = path.read_bytes()
    try:
        value = json.loads(before)
        controls = value["controls"]
    except (KeyError, TypeError, ValueError) as error:
        raise HarnessMappingError() from error
    if (
        set(value) != {"schema_version", "mapping_id", "owner_task", "controls"}
        or value["schema_version"] != "1.0"
        or value["mapping_id"] != "context-planner-v2-phase-13"
        or value["owner_task"] != "P13-004"
        or not isinstance(controls, list)
        or not controls
    ):
        raise HarnessMappingError()
    ids: list[int] = []
    for item in controls:
        if not isinstance(item, dict) or set(item) != {
            "harness_control_id",
            "failure_code",
            "test",
            "evidence",
        }:
            raise HarnessMappingError()
        control_id = item["harness_control_id"]
        paths = (item["test"], item["evidence"])
        if (
            control_id not in CONTROL_IDS
            or FAILURE_PATTERN.fullmatch(item["failure_code"]) is None
            or any(PATH_PATTERN.fullmatch(candidate) is None for candidate in paths)
            or not (repository_root / item["test"]).is_file()
        ):
            raise HarnessMappingError()
        ids.append(control_id)
    if len(ids) != len(set(ids)):
        raise HarnessMappingError()
    if path.read_bytes() != before:
        raise HarnessMappingError("harness.catalog_mutated")
    return value
