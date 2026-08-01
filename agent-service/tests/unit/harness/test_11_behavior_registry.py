from __future__ import annotations

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
from sqlalchemy import create_engine, select, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DatabaseError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import (  # noqa: E402
    BEHAVIOR_SCHEMA,
    BehaviorDeploymentRecord,
    BehaviorReleaseRecord,
)
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.behavior import (  # noqa: E402
    BehaviorNotQualified,
    BehaviorRepository,
    BehaviorWriteContext,
    PointerCasConflict,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_004_behavior_releases"
VERSION_SCHEMA = "p03_004_behavior_harness_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
BEHAVIOR_KEY = "itinerary.single-agent"


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
def registry_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _reset(engine, config)
    try:
        yield sessionmaker(engine, expire_on_commit=False)
    finally:
        try:
            command.downgrade(config, "base")
        finally:
            with engine.begin() as connection:
                connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
                connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
                connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
            engine.dispose()


def _context(receipt: str) -> BehaviorWriteContext:
    return BehaviorWriteContext(
        principal_id="harness-release-operator",
        permissions=frozenset(
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


def _release(factory: sessionmaker[Session], number: int, *, qualified: bool = True):
    digit = format(number, "x")[-1]
    with factory.begin() as session:
        repository = BehaviorRepository(session)
        revision = repository.create_revision(
            context=_context(f"audit-harness-revision-{number}"),
            behavior_key=BEHAVIOR_KEY,
            revision_number=number,
            content_digest=digit * 64,
            graph_ref="graph://sha256/" + digit * 64,
            prompt_ref="prompt://sha256/" + digit * 64,
            state_schema_ref="schema://sha256/" + digit * 64,
        )
        certification = repository.certify_revision(
            context=_context(f"audit-harness-cert-{number}"),
            behavior_key=BEHAVIOR_KEY,
            revision_id=revision.revision_id,
            dataset_digest=format(number + 8, "x")[-1] * 64,
            qualified=qualified,
        )
        if not qualified:
            return revision, certification
        return repository.create_release(
            context=_context(f"audit-harness-release-{number}"),
            behavior_key=BEHAVIOR_KEY,
            revision_id=revision.revision_id,
            certification_id=certification.certification_id,
            release_version=f"1.0.{number}",
            package_digest=format(number + 4, "x")[-1] * 64,
        )


def test_11_behavior_registry_s_reads_immutable_release(registry_database) -> None:
    factory = registry_database
    release = _release(factory, 1)
    with factory.begin() as session:
        persisted = session.get(BehaviorReleaseRecord, release.release_id)
    assert persisted is not None
    assert persisted.package_digest == release.package_digest
    assert persisted.lifecycle_state == "offline_qualified"


def test_11_behavior_registry_s_resolves_qualified_deployment(registry_database) -> None:
    factory = registry_database
    release = _release(factory, 1)
    with factory.begin() as session:
        repository = BehaviorRepository(session)
        repository.create_deployment(
            context=_context("audit-harness-deployment-resolve"),
            behavior_key=BEHAVIOR_KEY,
            environment="test",
            release_id=release.release_id,
        )
        resolved = repository.resolve_deployed_release(
            behavior_key=BEHAVIOR_KEY,
            environment="test",
        )
    assert resolved.release_id == release.release_id
    assert resolved.package_digest == release.package_digest
    assert resolved.audit_receipt_id


def test_11_behavior_registry_i_modifying_existing_digest_is_rejected(registry_database) -> None:
    factory = registry_database
    release = _release(factory, 1)
    with pytest.raises(DatabaseError, match="behavior.immutable"):
        with factory.begin() as session:
            session.execute(
                update(BehaviorReleaseRecord)
                .where(BehaviorReleaseRecord.release_id == release.release_id)
                .values(package_digest="f" * 64)
            )


def test_11_behavior_registry_d_pointer_generation_race_has_one_winner(registry_database) -> None:
    factory = registry_database
    old_release = _release(factory, 1)
    target_a = _release(factory, 2)
    target_b = _release(factory, 3)
    with factory.begin() as session:
        deployment = BehaviorRepository(session).create_deployment(
            context=_context("audit-harness-deployment"),
            behavior_key=BEHAVIOR_KEY,
            environment="test",
            release_id=old_release.release_id,
        )
    barrier = threading.Barrier(2)

    def move(index: int, target: uuid.UUID) -> str:
        barrier.wait()
        try:
            with factory.begin() as session:
                BehaviorRepository(session).move_pointer(
                    context=_context(f"audit-harness-pointer-{index}"),
                    behavior_key=BEHAVIOR_KEY,
                    environment="test",
                    expected_generation=deployment.generation,
                    target_release_id=target,
                )
            return "won"
        except PointerCasConflict:
            return "conflict"

    with ThreadPoolExecutor(max_workers=2) as executor:
        outcomes = list(
            executor.map(
                lambda item: move(*item),
                enumerate((target_a.release_id, target_b.release_id)),
            )
        )
    assert sorted(outcomes) == ["conflict", "won"]
    with factory.begin() as session:
        persisted = session.get(BehaviorDeploymentRecord, deployment.deployment_id)
    assert persisted is not None
    assert persisted.generation == 2


def test_11_behavior_registry_d_unqualified_registry_fails_closed(registry_database) -> None:
    factory = registry_database
    revision, certification = _release(factory, 1, qualified=False)
    with factory.begin() as session:
        with pytest.raises(BehaviorNotQualified, match="behavior.not_qualified"):
            BehaviorRepository(session).create_release(
                context=_context("audit-harness-rejected"),
                behavior_key=BEHAVIOR_KEY,
                revision_id=revision.revision_id,
                certification_id=certification.certification_id,
                release_version="1.0.1",
                package_digest="5" * 64,
            )
