"""Authorized immutable Behavior registry writes and deployment generation CAS."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from app.persistence.models.behavior import (
    BehaviorCertificationRecord,
    BehaviorDeploymentHistoryRecord,
    BehaviorDeploymentRecord,
    BehaviorReleaseRecord,
    BehaviorRevisionRecord,
)
from app.persistence.repositories.runs import TransactionRequired


DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
REFERENCE_PATTERNS = {
    "graph": re.compile(r"^graph://sha256/[0-9a-f]{64}$"),
    "prompt": re.compile(r"^prompt://sha256/[0-9a-f]{64}$"),
    "schema": re.compile(r"^schema://sha256/[0-9a-f]{64}$"),
}


class BehaviorAuthorizationDenied(RuntimeError):
    code = "behavior.authorization_denied"

    def __init__(self) -> None:
        super().__init__(self.code)


class BehaviorNotQualified(RuntimeError):
    code = "behavior.not_qualified"

    def __init__(self) -> None:
        super().__init__(self.code)


class PointerCasConflict(RuntimeError):
    code = "behavior.pointer_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class BehaviorWriteContext:
    principal_id: str
    permissions: frozenset[str]
    allowed_behavior_keys: frozenset[str]
    audit_receipt_id: str


class BehaviorRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def _authorize(
        self,
        context: BehaviorWriteContext,
        *,
        permission: str,
        behavior_key: str,
    ) -> None:
        if (
            not context.principal_id
            or not context.audit_receipt_id
            or permission not in context.permissions
            or behavior_key not in context.allowed_behavior_keys
        ):
            raise BehaviorAuthorizationDenied()

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def create_revision(
        self,
        *,
        context: BehaviorWriteContext,
        behavior_key: str,
        revision_number: int,
        content_digest: str,
        graph_ref: str,
        prompt_ref: str,
        state_schema_ref: str,
    ) -> BehaviorRevisionRecord:
        self._require_transaction()
        self._authorize(context, permission="behavior.revise", behavior_key=behavior_key)
        if (
            revision_number < 1
            or DIGEST_PATTERN.fullmatch(content_digest) is None
            or REFERENCE_PATTERNS["graph"].fullmatch(graph_ref) is None
            or REFERENCE_PATTERNS["prompt"].fullmatch(prompt_ref) is None
            or REFERENCE_PATTERNS["schema"].fullmatch(state_schema_ref) is None
        ):
            raise ValueError("behavior revision contains an invalid immutable reference")
        record = BehaviorRevisionRecord(
            revision_id=uuid.uuid4(),
            behavior_key=behavior_key,
            revision_number=revision_number,
            content_digest=content_digest,
            graph_ref=graph_ref,
            prompt_ref=prompt_ref,
            state_schema_ref=state_schema_ref,
            created_by_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._session.add(record)
        self._session.flush()
        return record

    def certify_revision(
        self,
        *,
        context: BehaviorWriteContext,
        behavior_key: str,
        revision_id: uuid.UUID,
        dataset_digest: str,
        qualified: bool,
    ) -> BehaviorCertificationRecord:
        self._require_transaction()
        self._authorize(context, permission="behavior.certify", behavior_key=behavior_key)
        if DIGEST_PATTERN.fullmatch(dataset_digest) is None:
            raise ValueError("dataset digest must be lowercase SHA-256")
        revision = self._session.execute(
            select(BehaviorRevisionRecord).where(
                BehaviorRevisionRecord.revision_id == revision_id,
                BehaviorRevisionRecord.behavior_key == behavior_key,
            )
        ).scalar_one_or_none()
        if revision is None:
            raise BehaviorNotQualified()
        record = BehaviorCertificationRecord(
            certification_id=uuid.uuid4(),
            revision_id=revision.revision_id,
            dataset_digest=dataset_digest,
            result="qualified" if qualified else "rejected",
            certifier_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._session.add(record)
        self._session.flush()
        return record

    def create_release(
        self,
        *,
        context: BehaviorWriteContext,
        behavior_key: str,
        revision_id: uuid.UUID,
        certification_id: uuid.UUID,
        release_version: str,
        package_digest: str,
    ) -> BehaviorReleaseRecord:
        self._require_transaction()
        self._authorize(context, permission="behavior.release", behavior_key=behavior_key)
        if VERSION_PATTERN.fullmatch(release_version) is None or DIGEST_PATTERN.fullmatch(package_digest) is None:
            raise ValueError("release version or digest is invalid")
        qualified = self._session.execute(
            select(BehaviorCertificationRecord.certification_id)
            .join(
                BehaviorRevisionRecord,
                BehaviorRevisionRecord.revision_id == BehaviorCertificationRecord.revision_id,
            )
            .where(
                BehaviorCertificationRecord.certification_id == certification_id,
                BehaviorCertificationRecord.revision_id == revision_id,
                BehaviorCertificationRecord.result == "qualified",
                BehaviorRevisionRecord.behavior_key == behavior_key,
            )
        ).scalar_one_or_none()
        if qualified is None:
            raise BehaviorNotQualified()
        record = BehaviorReleaseRecord(
            release_id=uuid.uuid4(),
            behavior_key=behavior_key,
            revision_id=revision_id,
            certification_id=certification_id,
            release_version=release_version,
            package_digest=package_digest,
            lifecycle_state="offline_qualified",
            created_by_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._session.add(record)
        self._session.flush()
        return record

    def create_deployment(
        self,
        *,
        context: BehaviorWriteContext,
        behavior_key: str,
        environment: str,
        release_id: uuid.UUID,
    ) -> BehaviorDeploymentRecord:
        self._require_transaction()
        self._authorize(context, permission="behavior.deploy", behavior_key=behavior_key)
        deployment = BehaviorDeploymentRecord(
            deployment_id=uuid.uuid4(),
            behavior_key=behavior_key,
            environment=environment,
            release_id=release_id,
            generation=1,
            updated_by_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._session.add(deployment)
        self._session.flush()
        self._session.add(
            BehaviorDeploymentHistoryRecord(
                history_id=uuid.uuid4(),
                deployment_id=deployment.deployment_id,
                behavior_key=behavior_key,
                generation=1,
                previous_release_id=None,
                new_release_id=release_id,
                actor_principal_id=context.principal_id,
                audit_receipt_id=context.audit_receipt_id,
            )
        )
        self._session.flush()
        return deployment

    def move_pointer(
        self,
        *,
        context: BehaviorWriteContext,
        behavior_key: str,
        environment: str,
        expected_generation: int,
        target_release_id: uuid.UUID,
    ) -> BehaviorDeploymentRecord:
        self._require_transaction()
        self._authorize(context, permission="behavior.deploy", behavior_key=behavior_key)
        current = self._session.execute(
            select(BehaviorDeploymentRecord).where(
                BehaviorDeploymentRecord.behavior_key == behavior_key,
                BehaviorDeploymentRecord.environment == environment,
            )
        ).scalar_one_or_none()
        if current is None:
            raise PointerCasConflict()
        previous_release_id = current.release_id
        statement = (
            update(BehaviorDeploymentRecord)
            .where(
                BehaviorDeploymentRecord.deployment_id == current.deployment_id,
                BehaviorDeploymentRecord.generation == expected_generation,
            )
            .values(
                release_id=target_release_id,
                generation=expected_generation + 1,
                updated_by_principal_id=context.principal_id,
                audit_receipt_id=context.audit_receipt_id,
                updated_at=func.statement_timestamp(),
            )
            .returning(BehaviorDeploymentRecord)
        )
        changed = self._session.execute(statement).scalar_one_or_none()
        if changed is None:
            raise PointerCasConflict()
        self._session.add(
            BehaviorDeploymentHistoryRecord(
                history_id=uuid.uuid4(),
                deployment_id=changed.deployment_id,
                behavior_key=behavior_key,
                generation=changed.generation,
                previous_release_id=previous_release_id,
                new_release_id=target_release_id,
                actor_principal_id=context.principal_id,
                audit_receipt_id=context.audit_receipt_id,
            )
        )
        self._session.flush()
        return changed
