from __future__ import annotations

import pytest

from app.persistence.repositories.checkpoints import CheckpointsRepository
from app.persistence.repositories.jobs import StaleFence
from test_kill_after_reserve import (
    STATE_DIGEST,
    STATE_SCHEMA_DIGEST,
    TENANT,
    append_recovery_event,
    build_result,
    create_work,
    killed_worker,
    record_result,
    replay_database,
    rotate_lease,
    set_tenant,
)


def _save_checkpoint(environment, identity, lease, audit_receipt_id: str) -> None:
    with environment.worker_factory.begin() as session:
        set_tenant(session)
        CheckpointsRepository(session).save(
            tenant_id=TENANT,
            run_id=identity.run_id,
            job_id=identity.job_id,
            holder_id=lease.holder_id,
            fencing_token=lease.fencing_token,
            state_ref="checkpoint://sha256/" + STATE_DIGEST,
            state_digest=STATE_DIGEST,
            state_schema_digest=STATE_SCHEMA_DIGEST,
            pending_writes_ref=None,
            audit_receipt_id=audit_receipt_id,
        )


def test_kill_before_checkpoint_persist_recovers_exactly_one_checkpoint() -> None:
    scenario = "before_checkpoint_persist"
    with replay_database() as environment:
        identity = create_work(environment, scenario)
        with killed_worker(identity, scenario) as killed:
            lease = rotate_lease(environment, identity, scenario)
            _save_checkpoint(
                environment, identity, lease, "audit-before-checkpoint-recover"
            )
            with pytest.raises(StaleFence):
                _save_checkpoint(
                    environment,
                    identity,
                    type(lease)(
                        holder_id=identity.old_holder_id,
                        fencing_token=identity.old_fencing_token,
                        old_worker_denied=False,
                    ),
                    "audit-old-checkpoint-denied",
                )
            append_recovery_event(environment, identity, scenario)
            result = build_result(
                environment=environment,
                identity=identity,
                killed=killed,
                lease=lease,
                ct_ids=(),
                expected_side_effect_count=0,
                expected_invocation_count=0,
                expected_checkpoint_count=1,
            )
            assert result["passed"]
            record_result(result)


def test_kill_after_checkpoint_persist_reuses_committed_checkpoint() -> None:
    scenario = "after_checkpoint_persist"
    with replay_database() as environment:
        identity = create_work(environment, scenario)
        with killed_worker(identity, scenario) as killed:
            lease = rotate_lease(environment, identity, scenario)
            with environment.worker_factory.begin() as session:
                set_tenant(session)
                latest = CheckpointsRepository(session).latest(
                    tenant_id=TENANT, run_id=identity.run_id
                )
                assert latest is not None and latest.checkpoint_seq == 1
            append_recovery_event(environment, identity, scenario)
            result = build_result(
                environment=environment,
                identity=identity,
                killed=killed,
                lease=lease,
                ct_ids=(),
                expected_side_effect_count=0,
                expected_invocation_count=0,
                expected_checkpoint_count=1,
            )
            assert result["passed"]
            record_result(result)
