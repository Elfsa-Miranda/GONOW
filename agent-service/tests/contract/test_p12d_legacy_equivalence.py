from __future__ import annotations

import hashlib
import json
import os
import site
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
            "candidate_conflict_count": candidate_conflict_count,
            "candidate_receipt_count": candidate_receipt_count,
            "candidate_outbox_count": candidate_outbox_count,
            "baseline_elapsed_seconds": round(baseline_elapsed, 6),
            "candidate_elapsed_seconds": round(candidate_elapsed, 6),
            "claim_scope": "local_controlled_mechanism",
            "production_improvement_claim": False,
            "production_measurement_status": "measurement_pending",
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
