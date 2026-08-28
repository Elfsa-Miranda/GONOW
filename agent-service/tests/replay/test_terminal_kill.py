from __future__ import annotations

import pytest

from app.persistence.models.runtime import RunRecord, RunState
from app.persistence.repositories.events import EventsRepository
from app.persistence.repositories.jobs import JobsRepository
from app.persistence.repositories.runs import RunStateConflict, RunsRepository
from test_kill_after_reserve import (
    TENANT,
    build_result,
    create_work,
    killed_worker,
    record_result,
    replay_database,
    rotate_lease,
    set_tenant,
)


def test_kill_before_terminal_transition_converges_to_one_legal_terminal() -> None:
    scenario = "before_terminal_transition"
    with replay_database() as environment:
        identity = create_work(environment, scenario)
        with killed_worker(identity, scenario) as killed:
            lease = rotate_lease(environment, identity, scenario)
            with environment.worker_factory.begin() as session:
                set_tenant(session)
                JobsRepository(session).assert_fence(
                    tenant_id=TENANT,
                    job_id=identity.job_id,
                    holder_id=lease.holder_id,
                    fencing_token=lease.fencing_token,
                )
                run = session.get(RunRecord, identity.run_id)
                assert run is not None
                EventsRepository(session).append(
                    tenant_id=TENANT,
                    run_id=identity.run_id,
                    event_type="replay.terminal_recovered",
                    payload={"target_state": RunState.SUCCEEDED.value},
                    audit_receipt_id="audit-terminal-recovery",
                )
                RunsRepository(session).transition_state(
                    tenant_id=TENANT,
                    run_id=identity.run_id,
                    expected_state=RunState.RUNNING,
                    expected_version=run.version,
                    target_state=RunState.SUCCEEDED,
                )
            with environment.worker_factory.begin() as session:
                set_tenant(session)
                with pytest.raises(RunStateConflict):
                    RunsRepository(session).transition_state(
                        tenant_id=TENANT,
                        run_id=identity.run_id,
                        expected_state=RunState.RUNNING,
                        expected_version=1,
                        target_state=RunState.SUCCEEDED,
                    )
            result = build_result(
                environment=environment,
                identity=identity,
                killed=killed,
                lease=lease,
                ct_ids=(),
                expected_side_effect_count=0,
                expected_invocation_count=0,
                expected_checkpoint_count=0,
                expected_run_state=RunState.SUCCEEDED,
            )
            assert result["passed"]
            record_result(result)
