from __future__ import annotations

import json
import os
import site
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, inspect, select, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DatabaseError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import (  # noqa: E402
    BEHAVIOR_SCHEMA,
    BehaviorDeploymentHistoryRecord,
    BehaviorDeploymentRecord,
    BehaviorReleaseRecord,
)
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.behavior import (  # noqa: E402
    BehaviorAuthorizationDenied,
    BehaviorNotQualified,
    BehaviorRepository,
    BehaviorWriteContext,
    PointerCasConflict,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
PREVIOUS_REVISION = "p03_003_jobs_leases_checkpoints"
TARGET_REVISION = "p03_004_behavior_releases"
VERSION_SCHEMA = "p03_004_pointer_cas_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
REPORT_ENV = "GONOW_P03_BEHAVIOR_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-03"
    / "P03-004"
    / "behavior-release-report.json"
)
BEHAVIOR_KEY = "itinerary.single-agent"
BEHAVIOR_TABLES = [
    "certifications",
    "deployment_history",
    "deployments",
    "releases",
    "revisions",
]
RUNTIME_TABLES = [
    "checkpoint_metadata",
    "events",
    "idempotency_records",
    "jobs",
    "leases",
    "runs",
    "threads",
]


def _assert_task_owned_database() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None


def _config(monkeypatch: pytest.MonkeyPatch) -> Config:
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    return Config(str(ALEMBIC_INI))


def _reset(engine: Engine, config: Config) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    command.upgrade(config, TARGET_REVISION)


@pytest.fixture()
def behavior_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _reset(engine, config)
    try:
        yield engine, config
    finally:
        try:
            command.downgrade(config, "base")
        finally:
            with engine.begin() as connection:
                connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
                connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
                connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
            engine.dispose()


def _factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(engine, expire_on_commit=False)


def _context(receipt: str, permissions: frozenset[str] | None = None) -> BehaviorWriteContext:
    return BehaviorWriteContext(
        principal_id="release-operator",
        permissions=permissions
        or frozenset(
            {
                "behavior.revise",
                "behavior.certify",
                "behavior.release",
                "behavior.deploy",
            }
        ),
        allowed_behavior_keys=frozenset({BEHAVIOR_KEY}),
        audit_receipt_id=receipt,
    )


def _release(
    factory: sessionmaker[Session],
    *,
    number: int,
) -> BehaviorReleaseRecord:
    digit = format(number, "x")[-1]
    with factory.begin() as session:
        repository = BehaviorRepository(session)
        revision = repository.create_revision(
            context=_context(f"audit-revision-{number}"),
            behavior_key=BEHAVIOR_KEY,
            revision_number=number,
            content_digest=digit * 64,
            graph_ref="graph://sha256/" + digit * 64,
            prompt_ref="prompt://sha256/" + digit * 64,
            state_schema_ref="schema://sha256/" + digit * 64,
        )
        certification = repository.certify_revision(
            context=_context(f"audit-certification-{number}"),
            behavior_key=BEHAVIOR_KEY,
            revision_id=revision.revision_id,
            dataset_digest=format(number + 8, "x")[-1] * 64,
            qualified=True,
        )
        return repository.create_release(
            context=_context(f"audit-release-{number}"),
            behavior_key=BEHAVIOR_KEY,
            revision_id=revision.revision_id,
            certification_id=certification.certification_id,
            release_version=f"1.0.{number}",
            package_digest=format(number + 4, "x")[-1] * 64,
        )


def _deployment(
    factory: sessionmaker[Session],
    release_id: uuid.UUID,
) -> BehaviorDeploymentRecord:
    with factory.begin() as session:
        return BehaviorRepository(session).create_deployment(
            context=_context("audit-deployment-initial"),
            behavior_key=BEHAVIOR_KEY,
            environment="test",
            release_id=release_id,
        )


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )


def test_ct_013_concurrent_pointer_generation_cas(behavior_database) -> None:
    engine, config = behavior_database
    factory = _factory(engine)
    old_release = _release(factory, number=1)
    target_a = _release(factory, number=2)
    target_b = _release(factory, number=3)
    deployment = _deployment(factory, old_release.release_id)
    barrier = threading.Barrier(2)

    def move(index: int, target: uuid.UUID) -> tuple[str, str]:
        barrier.wait()
        try:
            with factory.begin() as session:
                changed = BehaviorRepository(session).move_pointer(
                    context=_context(f"audit-pointer-race-{index}"),
                    behavior_key=BEHAVIOR_KEY,
                    environment="test",
                    expected_generation=deployment.generation,
                    target_release_id=target,
                )
            return "won", str(changed.release_id)
        except PointerCasConflict as error:
            return "conflict", str(error)

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(
            executor.map(
                lambda item: move(*item),
                enumerate((target_a.release_id, target_b.release_id)),
            )
        )
    assert sorted(result[0] for result in results) == ["conflict", "won"]
    with factory.begin() as session:
        current = session.scalar(
            select(BehaviorDeploymentRecord).where(
                BehaviorDeploymentRecord.deployment_id == deployment.deployment_id
            )
        )
        history_count = session.scalar(
            select(func.count()).select_from(BehaviorDeploymentHistoryRecord)
        )
        old_snapshot = session.get(BehaviorReleaseRecord, old_release.release_id)
    assert current is not None
    assert current.generation == 2
    assert str(current.release_id) in {result[1] for result in results if result[0] == "won"}
    assert history_count == 2
    assert old_snapshot is not None
    assert old_snapshot.package_digest == old_release.package_digest

    with pytest.raises(DatabaseError, match="behavior.immutable"):
        with factory.begin() as session:
            session.execute(
                update(BehaviorReleaseRecord)
                .where(BehaviorReleaseRecord.release_id == old_release.release_id)
                .values(package_digest="f" * 64)
            )

    command.downgrade(config, PREVIOUS_REVISION)
    with engine.connect() as connection:
        behavior_schema_after_downgrade = inspect(connection).has_schema(BEHAVIOR_SCHEMA)
        runtime_tables_after_downgrade = sorted(
            inspect(connection).get_table_names(schema=RUNTIME_SCHEMA)
        )
    command.upgrade(config, TARGET_REVISION)
    with engine.connect() as connection:
        rebuilt_behavior_tables = sorted(
            inspect(connection).get_table_names(schema=BEHAVIOR_SCHEMA)
        )
    assert behavior_schema_after_downgrade is False
    assert runtime_tables_after_downgrade == RUNTIME_TABLES
    assert rebuilt_behavior_tables == BEHAVIOR_TABLES
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P03-004",
            "revision": TARGET_REVISION,
            "ct_012_passed": True,
            "ct_013_passed": True,
            "winning_generation": current.generation,
            "history_count": history_count,
            "old_release_immutable": True,
            "behavior_schema_after_downgrade": behavior_schema_after_downgrade,
            "runtime_tables_after_downgrade": runtime_tables_after_downgrade,
            "rebuilt_behavior_tables": rebuilt_behavior_tables,
            "production": False,
        }
    )


def test_ct_012_old_release_remains_addressable_after_pointer_move(behavior_database) -> None:
    engine, _ = behavior_database
    factory = _factory(engine)
    old_release = _release(factory, number=1)
    new_release = _release(factory, number=2)
    deployment = _deployment(factory, old_release.release_id)
    with factory.begin() as session:
        changed = BehaviorRepository(session).move_pointer(
            context=_context("audit-pointer-sequential"),
            behavior_key=BEHAVIOR_KEY,
            environment="test",
            expected_generation=deployment.generation,
            target_release_id=new_release.release_id,
        )
    with factory.begin() as session:
        persisted_old = session.get(BehaviorReleaseRecord, old_release.release_id)
    assert changed.release_id == new_release.release_id
    assert persisted_old is not None
    assert persisted_old.release_id == old_release.release_id
    assert persisted_old.package_digest == old_release.package_digest


def test_pointer_write_denies_identity_scope_mismatch(behavior_database) -> None:
    engine, _ = behavior_database
    factory = _factory(engine)
    release = _release(factory, number=1)
    forged = BehaviorWriteContext(
        principal_id="forged-operator",
        permissions=frozenset({"behavior.deploy"}),
        allowed_behavior_keys=frozenset({"different.behavior"}),
        audit_receipt_id="audit-forged",
    )
    with pytest.raises(BehaviorAuthorizationDenied, match="behavior.authorization_denied"):
        with factory.begin() as session:
            BehaviorRepository(session).create_deployment(
                context=forged,
                behavior_key=BEHAVIOR_KEY,
                environment="test",
                release_id=release.release_id,
            )
    with factory.begin() as session:
        assert session.scalar(select(func.count()).select_from(BehaviorDeploymentRecord)) == 0


def test_rejected_certification_cannot_create_release(behavior_database) -> None:
    engine, _ = behavior_database
    factory = _factory(engine)
    with factory.begin() as session:
        repository = BehaviorRepository(session)
        revision = repository.create_revision(
            context=_context("audit-revision-rejected"),
            behavior_key=BEHAVIOR_KEY,
            revision_number=1,
            content_digest="1" * 64,
            graph_ref="graph://sha256/" + "1" * 64,
            prompt_ref="prompt://sha256/" + "1" * 64,
            state_schema_ref="schema://sha256/" + "1" * 64,
        )
        certification = repository.certify_revision(
            context=_context("audit-certification-rejected"),
            behavior_key=BEHAVIOR_KEY,
            revision_id=revision.revision_id,
            dataset_digest="2" * 64,
            qualified=False,
        )
        with pytest.raises(BehaviorNotQualified, match="behavior.not_qualified"):
            repository.create_release(
                context=_context("audit-release-rejected"),
                behavior_key=BEHAVIOR_KEY,
                revision_id=revision.revision_id,
                certification_id=certification.certification_id,
                release_version="1.0.0",
                package_digest="3" * 64,
            )
