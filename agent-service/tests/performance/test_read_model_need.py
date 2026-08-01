from __future__ import annotations

import hashlib
import json
import math
import os
import sqlite3
import time
from pathlib import Path
from typing import Any

import pytest


TASK_ID = "TASK-P09-009"
SAMPLE_COUNT = 40
WARMUP_COUNT = 5
DATASET_ROWS = 400
QUERY_SLA_MS = 50.0
VISIBILITY_SLA_MS = 50.0
REPORT_ENV = "GONOW_P09_009_REPORT"

QUERY_PROFILES = (
    {
        "query_id": "run_status_by_tenant",
        "join_count": 0,
        "sla_p95_ms": QUERY_SLA_MS,
        "sql": ("SELECT state, version FROM runs WHERE tenant_id = ? AND run_id = ?"),
    },
    {
        "query_id": "adoption_receipt_with_delivery",
        "join_count": 2,
        "sla_p95_ms": QUERY_SLA_MS,
        "sql": (
            "SELECT r.result_version, a.status, o.status "
            "FROM domain_command_receipts AS r "
            "JOIN domain_command_approvals AS a "
            "ON a.approval_id = r.approval_id AND a.tenant_id = r.tenant_id "
            "JOIN outbox_messages AS o "
            "ON o.outbox_id = r.outbox_id AND o.tenant_id = r.tenant_id "
            "WHERE r.tenant_id = ? AND r.candidate_id = ?"
        ),
    },
    {
        "query_id": "itinerary_detail_with_activities",
        "join_count": 1,
        "sla_p95_ms": QUERY_SLA_MS,
        "sql": (
            "SELECT i.version, i.title, a.position, a.title "
            "FROM user_itineraries AS i "
            "LEFT JOIN itinerary_activities AS a "
            "ON a.itinerary_id = i.itinerary_id AND a.tenant_id = i.tenant_id "
            "WHERE i.tenant_id = ? AND i.itinerary_id = ? "
            "ORDER BY a.position"
        ),
    },
)


def _schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        CREATE TABLE runs (
          tenant_id TEXT NOT NULL,
          run_id TEXT NOT NULL,
          state TEXT NOT NULL,
          version INTEGER NOT NULL,
          PRIMARY KEY (tenant_id, run_id)
        );
        CREATE TABLE domain_command_approvals (
          tenant_id TEXT NOT NULL,
          approval_id TEXT NOT NULL,
          status TEXT NOT NULL,
          PRIMARY KEY (tenant_id, approval_id)
        );
        CREATE TABLE outbox_messages (
          tenant_id TEXT NOT NULL,
          outbox_id TEXT NOT NULL,
          status TEXT NOT NULL,
          PRIMARY KEY (tenant_id, outbox_id)
        );
        CREATE TABLE domain_command_receipts (
          tenant_id TEXT NOT NULL,
          candidate_id TEXT NOT NULL,
          approval_id TEXT NOT NULL,
          outbox_id TEXT NOT NULL,
          result_version INTEGER NOT NULL,
          PRIMARY KEY (tenant_id, candidate_id)
        );
        CREATE TABLE user_itineraries (
          tenant_id TEXT NOT NULL,
          itinerary_id TEXT NOT NULL,
          title TEXT NOT NULL,
          version INTEGER NOT NULL,
          PRIMARY KEY (tenant_id, itinerary_id)
        );
        CREATE TABLE itinerary_activities (
          tenant_id TEXT NOT NULL,
          itinerary_id TEXT NOT NULL,
          position INTEGER NOT NULL,
          title TEXT NOT NULL,
          PRIMARY KEY (tenant_id, itinerary_id, position)
        );
        CREATE TABLE visibility_probe (
          probe_id INTEGER PRIMARY KEY,
          observed_value TEXT NOT NULL
        );
        CREATE INDEX ix_receipts_tenant_candidate
          ON domain_command_receipts (tenant_id, candidate_id);
        CREATE INDEX ix_activities_tenant_itinerary
          ON itinerary_activities (tenant_id, itinerary_id, position);
        """
    )


def _seed(connection: sqlite3.Connection) -> None:
    tenant = "tenant-synthetic-read-model"
    connection.executemany(
        "INSERT INTO runs VALUES (?, ?, ?, ?)",
        ((tenant, f"run-{index}", "succeeded", 3) for index in range(DATASET_ROWS)),
    )
    connection.executemany(
        "INSERT INTO domain_command_approvals VALUES (?, ?, ?)",
        ((tenant, f"approval-{index}", "consumed") for index in range(DATASET_ROWS)),
    )
    connection.executemany(
        "INSERT INTO outbox_messages VALUES (?, ?, ?)",
        ((tenant, f"outbox-{index}", "pending") for index in range(DATASET_ROWS)),
    )
    connection.executemany(
        "INSERT INTO domain_command_receipts VALUES (?, ?, ?, ?, ?)",
        (
            (
                tenant,
                f"candidate-{index}",
                f"approval-{index}",
                f"outbox-{index}",
                1,
            )
            for index in range(DATASET_ROWS)
        ),
    )
    connection.executemany(
        "INSERT INTO user_itineraries VALUES (?, ?, ?, ?)",
        (
            (tenant, f"itinerary-{index}", f"Synthetic {index}", 1)
            for index in range(DATASET_ROWS)
        ),
    )
    connection.executemany(
        "INSERT INTO itinerary_activities VALUES (?, ?, ?, ?)",
        (
            (tenant, f"itinerary-{index}", position, f"Activity {position}")
            for index in range(DATASET_ROWS)
            for position in range(4)
        ),
    )
    connection.commit()


def _query_parameters(query_id: str, index: int) -> tuple[str, str]:
    tenant = "tenant-synthetic-read-model"
    row = (index * 37) % DATASET_ROWS
    if query_id == "run_status_by_tenant":
        return tenant, f"run-{row}"
    if query_id == "adoption_receipt_with_delivery":
        return tenant, f"candidate-{row}"
    return tenant, f"itinerary-{row}"


def _p95_ms(samples_ns: list[int]) -> float:
    ordered = sorted(samples_ns)
    index = max(0, math.ceil(0.95 * len(ordered)) - 1)
    return round(ordered[index] / 1_000_000, 6)


def _measure_query(
    connection: sqlite3.Connection,
    profile: dict[str, Any],
) -> dict[str, Any]:
    query_id = str(profile["query_id"])
    sql = str(profile["sql"])
    for index in range(WARMUP_COUNT):
        connection.execute(sql, _query_parameters(query_id, index)).fetchall()
    durations: list[int] = []
    result_shape: list[int] = []
    for index in range(SAMPLE_COUNT):
        started = time.perf_counter_ns()
        rows = connection.execute(
            sql,
            _query_parameters(query_id, index + WARMUP_COUNT),
        ).fetchall()
        durations.append(time.perf_counter_ns() - started)
        result_shape.append(len(rows))
    p95_ms = _p95_ms(durations)
    return {
        "query_id": query_id,
        "join_count": int(profile["join_count"]),
        "sample_count": len(durations),
        "warmup_count": WARMUP_COUNT,
        "sla_p95_ms": float(profile["sla_p95_ms"]),
        "observed_p95_ms": p95_ms,
        "observed_max_ms": round(max(durations) / 1_000_000, 6),
        "sla_met": p95_ms <= float(profile["sla_p95_ms"]),
        "result_shape_sha256": hashlib.sha256(
            json.dumps(result_shape, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
    }


def _measure_visibility(connection: sqlite3.Connection) -> dict[str, Any]:
    durations: list[int] = []
    stale_reads = 0
    for index in range(SAMPLE_COUNT):
        started = time.perf_counter_ns()
        connection.execute(
            "INSERT INTO visibility_probe VALUES (?, ?)",
            (index, f"visible-{index}"),
        )
        connection.commit()
        observed = connection.execute(
            "SELECT observed_value FROM visibility_probe WHERE probe_id = ?",
            (index,),
        ).fetchone()
        durations.append(time.perf_counter_ns() - started)
        stale_reads += int(observed != (f"visible-{index}",))
    p95_ms = _p95_ms(durations)
    return {
        "sample_count": len(durations),
        "sla_p95_ms": VISIBILITY_SLA_MS,
        "observed_p95_ms": p95_ms,
        "stale_read_count": stale_reads,
        "sla_met": p95_ms <= VISIBILITY_SLA_MS and stale_reads == 0,
    }


def _write_report(report: dict[str, Any]) -> None:
    requested = os.environ.get(REPORT_ENV)
    if not requested:
        return
    path = Path(requested).resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(report, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
    temporary.replace(path)


@pytest.fixture(scope="module")
def read_model_report() -> dict[str, Any]:
    connection = sqlite3.connect(":memory:")
    try:
        _schema(connection)
        _seed(connection)
        profiles = [_measure_query(connection, profile) for profile in QUERY_PROFILES]
        visibility = _measure_visibility(connection)
    finally:
        connection.close()
    missed_queries = sum(not bool(profile["sla_met"]) for profile in profiles)
    decision = (
        "not_applicable"
        if missed_queries == 0 and visibility["sla_met"]
        else "candidate"
    )
    report: dict[str, Any] = {
        "schema_version": "1.0",
        "task_id": TASK_ID,
        "environment": "synthetic_local_sqlite_read_only_decision_fixture",
        "production_claim_authorized": False,
        "dataset_rows": DATASET_ROWS,
        "query_profiles": profiles,
        "query_profile_count": len(profiles),
        "total_query_samples": sum(
            int(profile["sample_count"]) for profile in profiles
        ),
        "visibility": visibility,
        "missed_query_sla_count": missed_queries,
        "decision": decision,
        "read_model_implemented": False,
        "decision_reason_codes": (
            [
                "all_preregistered_direct_queries_meet_local_initial_sla",
                "synchronous_source_visibility_meets_local_initial_sla",
                "no_production_sla_or_workload_claim",
                "avoid_unowned_projection_and_lag_boundary",
            ]
            if decision == "not_applicable"
            else ["local_direct_query_gate_requires_architecture_review"]
        ),
        "ownership": {
            "normalized_source_owner": "Domain+Data",
            "decision_owner": "Architecture",
            "read_model_owner": "unassigned_until_trigger_and_adr",
        },
        "candidate_trigger": {
            "minimum_approved_samples_per_query": 100,
            "minimum_consecutive_windows": 3,
            "minimum_critical_queries_missing_approved_p95_sla": 2,
            "maximum_projection_lag_p95_ms": 5_000,
            "requires_production_approved_workload": True,
        },
        "production_write_count": 0,
    }
    _write_report(report)
    return report


def test_query_profiles_preregister_sla_and_sample(
    read_model_report: dict[str, Any],
) -> None:
    assert read_model_report["query_profile_count"] == 3
    assert read_model_report["total_query_samples"] == 3 * SAMPLE_COUNT
    assert {profile["query_id"] for profile in read_model_report["query_profiles"]} == {
        "run_status_by_tenant",
        "adoption_receipt_with_delivery",
        "itinerary_detail_with_activities",
    }
    assert all(
        profile["sample_count"] == SAMPLE_COUNT
        for profile in read_model_report["query_profiles"]
    )
    assert all(
        profile["sla_p95_ms"] == QUERY_SLA_MS
        for profile in read_model_report["query_profiles"]
    )


def test_normalized_queries_meet_local_initial_sla(
    read_model_report: dict[str, Any],
) -> None:
    assert read_model_report["missed_query_sla_count"] == 0
    assert all(profile["sla_met"] for profile in read_model_report["query_profiles"])


def test_source_visibility_has_no_stale_sample(
    read_model_report: dict[str, Any],
) -> None:
    visibility = read_model_report["visibility"]
    assert visibility["sample_count"] == SAMPLE_COUNT
    assert visibility["stale_read_count"] == 0
    assert visibility["sla_met"]


def test_decision_is_not_applicable_and_ownership_is_explicit(
    read_model_report: dict[str, Any],
) -> None:
    assert read_model_report["decision"] == "not_applicable"
    assert not read_model_report["read_model_implemented"]
    assert (
        read_model_report["ownership"]["read_model_owner"]
        == "unassigned_until_trigger_and_adr"
    )
    assert (
        read_model_report["candidate_trigger"][
            "minimum_critical_queries_missing_approved_p95_sla"
        ]
        == 2
    )


def test_synthetic_fixture_cannot_authorize_production_claim(
    read_model_report: dict[str, Any],
) -> None:
    assert not read_model_report["production_claim_authorized"]
    assert read_model_report["production_write_count"] == 0
