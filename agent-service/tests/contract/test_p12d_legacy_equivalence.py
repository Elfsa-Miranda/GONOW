from __future__ import annotations

import hashlib
import json
import math
import os
import platform
import site
import subprocess
import sys
import time
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

from sqlalchemy import MetaData, create_engine, delete, func, insert, select, text, update
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))
sys.path.insert(0, str(SERVICE_ROOT / "tests" / "integration"))

import test_p12d_domain_command as base  # noqa: E402
from app.commands.itinerary_basic_info import (  # noqa: E402
    CommandOutcome,
    ItineraryBasicInfoPatch,
    UpdateItineraryBasicInfoCommand,
)
from app.persistence.repositories.itinerary_basic_info_commands import (  # noqa: E402
    ATTEMPTS,
    OUTBOX,
    RECEIPTS,
    ItineraryBasicInfoCommandService,
    isolated_business_projection,
)


command_database = base.command_database

WORKLOAD_VERSION = "p12d-stale-conflict-v1"
FIXED_RANDOM_SEED = 12040010
DENOMINATOR = 10_000
LEGACY_SCHEMA = "p12d_legacy_projection"
EVALUATOR_VERSION = "p12d-star-evaluator-v2"
ONE_SIDED_ALPHA = 0.05


def _target(index: int) -> uuid.UUID:
    return uuid.UUID(f"70000000-0000-4000-8000-{index:012d}")


def _command_id(index: int) -> uuid.UUID:
    return uuid.UUID(f"80000000-0000-4000-8000-{index:012d}")


def _workload() -> list[dict[str, object]]:
    return [
        {
            "intent_id": index,
            "target_itinerary_id": str(_target(index)),
            "command_id": str(_command_id(index)),
            "idempotency_key": f"p12d-stale-{index:05d}-{FIXED_RANDOM_SEED}",
            "read_version": 5,
            "winner_version": 6,
            "title": f"Stale intent {index:05d}",
        }
        for index in range(1, DENOMINATOR + 1)
    ]


def _fixture_rows() -> list[dict[str, object]]:
    now = datetime(2026, 8, 4, 9, 30, tzinfo=timezone.utc)
    return [
        {
            "id": _target(index),
            "tenant_id": base.TENANT,
            "user_id": base.PRINCIPAL,
            "title": "Winner title",
            "destination_city": "Shanghai",
            "start_date": date(2026, 10, 1),
            "end_date": date(2026, 10, 3),
            "budget": Decimal("1200.00"),
            "actual_cost": Decimal("50.00"),
            "tags": ["winner"],
            "version": 6,
            "updated_at": now,
        }
        for index in range(1, DENOMINATOR + 1)
    ]


def _normal_fixture_rows() -> list[dict[str, object]]:
    now = datetime(2026, 8, 4, 9, 0, tzinfo=timezone.utc)
    return [
        {
            "id": _target(index),
            "tenant_id": base.TENANT,
            "user_id": base.PRINCIPAL,
            "title": "Legacy title",
            "destination_city": "Hangzhou",
            "start_date": date(2026, 9, 1),
            "end_date": date(2026, 9, 2),
            "budget": Decimal("100.00"),
            "actual_cost": Decimal("10.00"),
            "tags": ["legacy"],
            "version": 5,
            "updated_at": now,
        }
        for index in range(1, DENOMINATOR + 1)
    ]


def _nearest_rank(values: list[float], percentile: float) -> float:
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return ordered[rank - 1]


def _latency_summary(values: list[float]) -> dict[str, float]:
    total = sum(values)
    return {
        "p50_ms": round(_nearest_rank(values, 0.50) * 1000, 6),
        "p95_ms": round(_nearest_rank(values, 0.95) * 1000, 6),
        "p99_ms": round(_nearest_rank(values, 0.99) * 1000, 6),
        "max_ms": round(max(values) * 1000, 6),
        "elapsed_seconds": round(total, 6),
        "seconds_per_intent": round(total / len(values), 9),
        "intents_per_second": round(len(values) / total, 6),
    }


def _one_sided_exact_all_success_lower(count: int) -> float:
    """Clopper-Pearson lower bound when every paired indicator is success."""
    return ONE_SIDED_ALPHA ** (1 / count)


def _one_sided_exact_zero_failure_upper(count: int) -> float:
    """Clopper-Pearson upper bound when no failures are observed."""
    return 1 - ONE_SIDED_ALPHA ** (1 / count)


def _git_oid() -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=SERVICE_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _behavior_digest() -> str:
    paths = (
        SERVICE_ROOT / "app" / "commands" / "itinerary_basic_info.py",
        SERVICE_ROOT
        / "app"
        / "persistence"
        / "repositories"
        / "itinerary_basic_info_commands.py",
        SERVICE_ROOT / "app" / "api" / "routes" / "itinerary_commands.py",
        SERVICE_ROOT.parent
        / "lib"
        / "features"
        / "itinerary"
        / "data"
        / "itinerary_provider.dart",
    )
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.relative_to(SERVICE_ROOT.parent).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def _run_record(
    *,
    arm: str,
    run_id: str,
    dataset_version: str,
    database_version: str,
    started_at: datetime,
    ended_at: datetime,
) -> dict[str, object]:
    return {
        "task_id": "TASK-P12D-050-STAR-REPAIR",
        "run_id": run_id,
        "baseline_or_candidate": arm,
        "git_oid": _git_oid(),
        "behavior_digest": _behavior_digest(),
        "dataset_version": dataset_version,
        "toolset_version": f"python-{platform.python_version()}",
        "database_version": database_version,
        "random_seed": FIXED_RANDOM_SEED,
        "retry_count": 0,
        "final_success": True,
        "failure_category": "none",
        "evaluator_version": EVALUATOR_VERSION,
        "start_time": started_at.isoformat(),
        "end_time": ended_at.isoformat(),
    }


def _candidate_command(intent: dict[str, object]) -> UpdateItineraryBasicInfoCommand:
    return UpdateItineraryBasicInfoCommand(
        schema_version="1.0",
        command_id=uuid.UUID(str(intent["command_id"])),
        idempotency_key=str(intent["idempotency_key"]),
        target_itinerary_id=uuid.UUID(str(intent["target_itinerary_id"])),
        expected_version=int(intent["read_version"]),
        patch=ItineraryBasicInfoPatch(
            title=str(intent["title"]),
            destination="Shanghai",
            start_date=date(2026, 10, 1),
            end_date=date(2026, 10, 3),
            budget=Decimal("1200.00"),
            actual_cost=Decimal("50.00"),
            tags=("stale",),
        ),
    )


def test_controlled_stale_conflict_profile_uses_identical_10k_inputs(
    command_database,
    capsys,
) -> None:
    engine, candidate_table, factory = command_database
    workload = _workload()
    workload_document = {
        "workload_version": WORKLOAD_VERSION,
        "fixed_random_seed": FIXED_RANDOM_SEED,
        "intents": workload,
    }
    workload_sha256 = hashlib.sha256(
        json.dumps(workload_document, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    fixture = _fixture_rows()
    fixture_sha256 = hashlib.sha256(
        json.dumps(
            [
                {
                    **row,
                    "id": str(row["id"]),
                    "start_date": row["start_date"].isoformat(),
                    "end_date": row["end_date"].isoformat(),
                    "budget": str(row["budget"]),
                    "actual_cost": str(row["actual_cost"]),
                    "updated_at": row["updated_at"].isoformat(),
                }
                for row in fixture
            ],
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    ).hexdigest()

    legacy_metadata = MetaData()
    legacy_table = isolated_business_projection(
        legacy_metadata, schema=LEGACY_SCHEMA
    )
    try:
        with engine.begin() as connection:
            connection.execute(DropSchema(LEGACY_SCHEMA, cascade=True, if_exists=True))
            connection.execute(CreateSchema(LEGACY_SCHEMA))
            legacy_metadata.create_all(connection)
            connection.execute(select(func.set_config("app.tenant_id", base.TENANT, True)))
            connection.execute(delete(candidate_table))
            connection.execute(insert(candidate_table), fixture)
            connection.execute(insert(legacy_table), fixture)

        baseline_started_at = datetime.now(timezone.utc)
        baseline_started = time.perf_counter()
        legacy_client_success_state_count = 0
        legacy_business_mutation_count = 0
        baseline_partial_effect_count = 0
        for intent in workload:
            # This wrapper preserves the selected tracked legacy ordering: the
            # provider publishes local success first, then performs a remote
            # update by resource id without an expected-version predicate.
            legacy_local_success_state_changed = True
            legacy_client_success_state_count += int(
                legacy_local_success_state_changed
            )
            with engine.begin() as connection:
                connection.execute(
                    select(func.set_config("app.tenant_id", base.TENANT, True))
                )
                legacy_mutation = connection.execute(
                    update(legacy_table)
                    .where(
                        legacy_table.c.id
                        == uuid.UUID(str(intent["target_itinerary_id"])),
                        legacy_table.c.tenant_id == base.TENANT,
                        legacy_table.c.user_id == base.PRINCIPAL,
                    )
                    .values(
                        title=str(intent["title"]),
                        version=int(intent["read_version"]),
                        updated_at=datetime.now(timezone.utc),
                    )
                )
            mutation_count = int(legacy_mutation.rowcount or 0)
            legacy_business_mutation_count += mutation_count
            if mutation_count or legacy_local_success_state_changed:
                baseline_partial_effect_count += 1
        baseline_elapsed = time.perf_counter() - baseline_started
        baseline_ended_at = datetime.now(timezone.utc)

        candidate_started_at = datetime.now(timezone.utc)
        candidate_started = time.perf_counter()
        candidate_outcomes: list[CommandOutcome] = []
        service = ItineraryBasicInfoCommandService(
            factory, business_table=candidate_table
        )
        for intent in workload:
            candidate_outcomes.append(
                service.execute(
                    context=base._context(),
                    command=_candidate_command(intent),
                ).state
            )
        candidate_elapsed = time.perf_counter() - candidate_started
        candidate_ended_at = datetime.now(timezone.utc)

        with engine.begin() as connection:
            connection.execute(select(func.set_config("app.tenant_id", base.TENANT, True)))
            candidate_business_mutation_count = int(
                connection.scalar(
                    select(func.count())
                    .select_from(candidate_table)
                    .where(
                        (candidate_table.c.version != 6)
                        | (candidate_table.c.title != "Winner title")
                    )
                )
                or 0
            )
            candidate_attempt_count = int(
                connection.scalar(select(func.count()).select_from(ATTEMPTS)) or 0
            )
            candidate_receipt_count = int(
                connection.scalar(select(func.count()).select_from(RECEIPTS)) or 0
            )
            candidate_outbox_count = int(
                connection.scalar(select(func.count()).select_from(OUTBOX)) or 0
            )
            database_version = str(connection.scalar(select(func.version())))

        candidate_conflict_count = sum(
            outcome is CommandOutcome.CONFLICT for outcome in candidate_outcomes
        )
        candidate_partial_effect_count = candidate_business_mutation_count
        baseline_rate = baseline_partial_effect_count / DENOMINATOR * 10_000
        candidate_rate = candidate_partial_effect_count / DENOMINATOR * 10_000
        assert legacy_business_mutation_count == DENOMINATOR
        assert legacy_client_success_state_count == DENOMINATOR
        assert baseline_partial_effect_count == DENOMINATOR
        assert candidate_conflict_count == DENOMINATOR
        assert candidate_business_mutation_count == 0
        assert candidate_attempt_count == candidate_receipt_count == DENOMINATOR
        assert candidate_outbox_count == 0
        assert baseline_rate == 10_000
        assert candidate_rate == 0
        paired_improvement_lower = _one_sided_exact_all_success_lower(DENOMINATOR)
        candidate_partial_effect_upper = _one_sided_exact_zero_failure_upper(
            DENOMINATOR
        )
        assert paired_improvement_lower > 0.999

        report = {
            "schema_version": "1.0",
            "workload_version": WORKLOAD_VERSION,
            "fixed_random_seed": FIXED_RANDOM_SEED,
            "workload_sha256": workload_sha256,
            "fixture_sha256": fixture_sha256,
            "baseline_input_sha256": workload_sha256,
            "candidate_input_sha256": workload_sha256,
            "baseline_denominator": DENOMINATOR,
            "candidate_denominator": DENOMINATOR,
            "excluded_failure_count": 0,
            "baseline_partial_effect_count": baseline_partial_effect_count,
            "candidate_partial_effect_count": candidate_partial_effect_count,
            "baseline_rate_per_10k": baseline_rate,
            "candidate_rate_per_10k": candidate_rate,
            "controlled_relative_improvement_percent": 100.0,
            "statistical_result": {
                "comparison_unit": "paired logical stale-conflict intent",
                "method": "exact one-sided Clopper-Pearson bound on paired improvement indicators",
                "confidence_level": 0.95,
                "paired_improvement_count": DENOMINATOR,
                "paired_regression_count": 0,
                "paired_tie_count": 0,
                "improvement_rate_lower_bound": round(
                    paired_improvement_lower, 9
                ),
                "improvement_lower_bound_per_10k": round(
                    paired_improvement_lower * 10_000, 6
                ),
                "candidate_partial_effect_rate_upper_bound_per_10k": round(
                    candidate_partial_effect_upper * 10_000, 6
                ),
                "primary_bound_passed": True,
                "population_scope": "frozen local controlled workload only",
            },
            "candidate_conflict_count": candidate_conflict_count,
            "candidate_receipt_count": candidate_receipt_count,
            "candidate_outbox_count": candidate_outbox_count,
            "baseline_elapsed_seconds": round(baseline_elapsed, 6),
            "candidate_elapsed_seconds": round(candidate_elapsed, 6),
            "claim_scope": "local_controlled_mechanism",
            "production_improvement_claim": False,
            "production_measurement_status": "measurement_pending",
            "run_records": [
                _run_record(
                    arm="baseline",
                    run_id=f"p12d-stale-baseline-{workload_sha256[:16]}",
                    dataset_version=WORKLOAD_VERSION,
                    database_version=database_version,
                    started_at=baseline_started_at,
                    ended_at=baseline_ended_at,
                ),
                _run_record(
                    arm="candidate",
                    run_id=f"p12d-stale-candidate-{workload_sha256[:16]}",
                    dataset_version=WORKLOAD_VERSION,
                    database_version=database_version,
                    started_at=candidate_started_at,
                    ended_at=candidate_ended_at,
                ),
            ],
        }
        if os.environ.get("GONOW_P12D_PROFILE_REPORT_STDOUT") == "1":
            print("P12D_PROFILE=" + json.dumps(report, sort_keys=True))
            captured = capsys.readouterr()
            print(captured.out, end="")
    finally:
        cleanup = create_engine(base.DATABASE_URL)
        try:
            with cleanup.begin() as connection:
                connection.execute(
                    DropSchema(LEGACY_SCHEMA, cascade=True, if_exists=True)
                )
        finally:
            cleanup.dispose()


def test_controlled_normal_write_profile_proves_equivalence_receipts_and_cost(
    command_database,
    capsys,
) -> None:
    engine, candidate_table, factory = command_database
    workload = _workload()
    workload_document = {
        "profile": "p12d-normal-write-v1",
        "workload_version": WORKLOAD_VERSION,
        "fixed_random_seed": FIXED_RANDOM_SEED,
        "intents": workload,
    }
    workload_sha256 = hashlib.sha256(
        json.dumps(workload_document, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    fixture = _normal_fixture_rows()
    fixture_sha256 = hashlib.sha256(
        json.dumps(
            [
                {
                    **row,
                    "id": str(row["id"]),
                    "start_date": row["start_date"].isoformat(),
                    "end_date": row["end_date"].isoformat(),
                    "budget": str(row["budget"]),
                    "actual_cost": str(row["actual_cost"]),
                    "updated_at": row["updated_at"].isoformat(),
                }
                for row in fixture
            ],
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    ).hexdigest()

    legacy_metadata = MetaData()
    legacy_table = isolated_business_projection(
        legacy_metadata, schema=LEGACY_SCHEMA
    )
    try:
        with engine.begin() as connection:
            connection.execute(DropSchema(LEGACY_SCHEMA, cascade=True, if_exists=True))
            connection.execute(CreateSchema(LEGACY_SCHEMA))
            legacy_metadata.create_all(connection)
            connection.execute(select(func.set_config("app.tenant_id", base.TENANT, True)))
            connection.execute(delete(candidate_table))
            connection.execute(insert(candidate_table), fixture)
            connection.execute(insert(legacy_table), fixture)

        baseline_latencies: list[float] = []
        baseline_success_count = 0
        baseline_started_at = datetime.now(timezone.utc)
        for intent in workload:
            started = time.perf_counter()
            with engine.begin() as connection:
                connection.execute(
                    select(func.set_config("app.tenant_id", base.TENANT, True))
                )
                result = connection.execute(
                    update(legacy_table)
                    .where(
                        legacy_table.c.id
                        == uuid.UUID(str(intent["target_itinerary_id"])),
                        legacy_table.c.tenant_id == base.TENANT,
                        legacy_table.c.user_id == base.PRINCIPAL,
                    )
                    .values(
                        title=str(intent["title"]),
                        destination_city="Shanghai",
                        start_date=date(2026, 10, 1),
                        end_date=date(2026, 10, 3),
                        budget=Decimal("1200.00"),
                        actual_cost=Decimal("50.00"),
                        tags=["stale"],
                        version=int(intent["read_version"]),
                        updated_at=datetime.now(timezone.utc),
                    )
                )
            baseline_latencies.append(time.perf_counter() - started)
            baseline_success_count += int((result.rowcount or 0) == 1)
        baseline_ended_at = datetime.now(timezone.utc)

        service = ItineraryBasicInfoCommandService(factory, business_table=candidate_table)
        candidate_latencies: list[float] = []
        candidate_success_count = 0
        candidate_started_at = datetime.now(timezone.utc)
        for intent in workload:
            started = time.perf_counter()
            receipt = service.execute(
                context=base._context(), command=_candidate_command(intent)
            )
            candidate_latencies.append(time.perf_counter() - started)
            candidate_success_count += int(receipt.state is CommandOutcome.COMMITTED)
        candidate_ended_at = datetime.now(timezone.utc)

        with engine.begin() as connection:
            connection.execute(select(func.set_config("app.tenant_id", base.TENANT, True)))
            legacy_equivalent_count = int(
                connection.scalar(
                    select(func.count())
                    .select_from(legacy_table)
                    .where(
                        legacy_table.c.title.like("Stale intent %"),
                        legacy_table.c.destination_city == "Shanghai",
                        legacy_table.c.start_date == date(2026, 10, 1),
                        legacy_table.c.end_date == date(2026, 10, 3),
                        legacy_table.c.budget == Decimal("1200.00"),
                        legacy_table.c.actual_cost == Decimal("50.00"),
                        legacy_table.c.version == 5,
                    )
                )
                or 0
            )
            candidate_equivalent_count = int(
                connection.scalar(
                    select(func.count())
                    .select_from(candidate_table)
                    .where(
                        candidate_table.c.title.like("Stale intent %"),
                        candidate_table.c.destination_city == "Shanghai",
                        candidate_table.c.start_date == date(2026, 10, 1),
                        candidate_table.c.end_date == date(2026, 10, 3),
                        candidate_table.c.budget == Decimal("1200.00"),
                        candidate_table.c.actual_cost == Decimal("50.00"),
                        candidate_table.c.version == 6,
                    )
                )
                or 0
            )
            candidate_attempt_count = int(
                connection.scalar(select(func.count()).select_from(ATTEMPTS)) or 0
            )
            candidate_receipt_count = int(
                connection.scalar(select(func.count()).select_from(RECEIPTS)) or 0
            )
            candidate_outbox_count = int(
                connection.scalar(select(func.count()).select_from(OUTBOX)) or 0
            )
            database_version = str(connection.scalar(select(func.version())))

        assert baseline_success_count == DENOMINATOR
        assert candidate_success_count == DENOMINATOR
        assert legacy_equivalent_count == DENOMINATOR
        assert candidate_equivalent_count == DENOMINATOR
        assert candidate_attempt_count == DENOMINATOR
        assert candidate_receipt_count == DENOMINATOR
        assert candidate_outbox_count == DENOMINATOR

        zero_failure_upper = _one_sided_exact_zero_failure_upper(DENOMINATOR)
        report = {
            "schema_version": "1.0",
            "profile": "p12d-normal-write-v1",
            "fixed_random_seed": FIXED_RANDOM_SEED,
            "workload_sha256": workload_sha256,
            "fixture_sha256": fixture_sha256,
            "baseline_input_sha256": workload_sha256,
            "candidate_input_sha256": workload_sha256,
            "baseline_denominator": DENOMINATOR,
            "candidate_denominator": DENOMINATOR,
            "baseline_success_count": baseline_success_count,
            "candidate_success_count": candidate_success_count,
            "baseline_success_rate": 1.0,
            "candidate_success_rate": 1.0,
            "fixed_fixture_success_difference_pp": 0.0,
            "normal_write_guardrail_passed": True,
            "guardrail_scope": "exact census of the frozen local controlled workload",
            "population_noninferiority_claim": False,
            "zero_observed_failure_one_sided_95_upper_per_10k": round(
                zero_failure_upper * 10_000, 6
            ),
            "field_equivalence_count": DENOMINATOR,
            "candidate_expected_version_delta": 1,
            "receipt_coverage": {
                "terminal_attempt_count": candidate_attempt_count,
                "schema_valid_stable_receipt_count": candidate_receipt_count,
                "coverage_rate": candidate_receipt_count / candidate_attempt_count,
            },
            "logical_outbox_events_per_successful_command": (
                candidate_outbox_count / candidate_success_count
            ),
            "local_timing_diagnostic": {
                "clock": "time.perf_counter",
                "runner": {
                    "platform": platform.platform(),
                    "machine": platform.machine(),
                    "processor": platform.processor() or "unknown",
                    "python_version": platform.python_version(),
                },
                "legacy": _latency_summary(baseline_latencies),
                "candidate": _latency_summary(candidate_latencies),
                "benchmark_claim_allowed": False,
                "reason": "single-run local sequential test without production topology or calibrated runner",
            },
            "excluded_failure_count": 0,
            "all_failed_intents_retained_in_denominator": True,
            "claim_scope": "local_controlled_mechanism",
            "production_improvement_claim": False,
            "production_measurement_status": "measurement_pending",
            "run_records": [
                _run_record(
                    arm="baseline",
                    run_id=f"p12d-normal-baseline-{workload_sha256[:16]}",
                    dataset_version="p12d-normal-write-v1",
                    database_version=database_version,
                    started_at=baseline_started_at,
                    ended_at=baseline_ended_at,
                ),
                _run_record(
                    arm="candidate",
                    run_id=f"p12d-normal-candidate-{workload_sha256[:16]}",
                    dataset_version="p12d-normal-write-v1",
                    database_version=database_version,
                    started_at=candidate_started_at,
                    ended_at=candidate_ended_at,
                ),
            ],
        }
        if os.environ.get("GONOW_P12D_PROFILE_REPORT_STDOUT") == "1":
            print("P12D_NORMAL_PROFILE=" + json.dumps(report, sort_keys=True))
            captured = capsys.readouterr()
            print(captured.out, end="")
    finally:
        cleanup = create_engine(base.DATABASE_URL)
        try:
            with cleanup.begin() as connection:
                connection.execute(
                    DropSchema(LEGACY_SCHEMA, cascade=True, if_exists=True)
                )
        finally:
            cleanup.dispose()
