from __future__ import annotations

import pytest

from app.persistence.repositories.invocations import (
    InvocationHandlerOutcome,
    PhysicalInvocationLedger,
)
from app.persistence.repositories.jobs import StaleFence
from test_kill_after_reserve import (
    ARGUMENT_DIGEST,
    TENANT,
    append_recovery_event,
    build_result,
    create_work,
    increment_side_effect,
    invocation_arguments,
    killed_worker,
    record_result,
    replay_database,
    rotate_lease,
)


def test_ct_006_kill_after_handler_before_result_persist_is_not_replayed() -> None:
    scenario = "before_result_persist"
    with replay_database() as environment:
        identity = create_work(environment, scenario)
        with killed_worker(identity, scenario) as killed:
            lease = rotate_lease(environment, identity, scenario)
            ledger = PhysicalInvocationLedger(environment.worker_factory)
            replay = ledger.reserve(
                **invocation_arguments(identity, lease),
                audit_receipt_id="audit-before-result-recover",
            )
            assert replay.decision == "reconcile"
            ledger.record_outcome(
                tenant_id=TENANT,
                run_id=identity.run_id,
                job_id=identity.job_id,
                holder_id=lease.holder_id,
                fencing_token=lease.fencing_token,
                tool_call_id="tool-call-p05-007",
                request_fingerprint=ARGUMENT_DIGEST,
                outcome=InvocationHandlerOutcome.unknown("tool.unknown_after_kill"),
                audit_receipt_id="audit-before-result-unknown",
            )
            with pytest.raises(StaleFence):
                ledger.record_outcome(
                    tenant_id=TENANT,
                    run_id=identity.run_id,
                    job_id=identity.job_id,
                    holder_id=identity.old_holder_id,
                    fencing_token=identity.old_fencing_token,
                    tool_call_id="tool-call-p05-007",
                    request_fingerprint=ARGUMENT_DIGEST,
                    outcome=InvocationHandlerOutcome.succeeded("b" * 64),
                    audit_receipt_id="audit-old-worker-denied",
                )
            append_recovery_event(environment, identity, scenario)
            result = build_result(
                environment=environment,
                identity=identity,
                killed=killed,
                lease=lease,
                ct_ids=("CT-006",),
                expected_side_effect_count=1,
                expected_invocation_count=1,
                expected_checkpoint_count=0,
                expected_invocation_status="unknown_outcome",
            )
            assert result["reserved_calls"] == 1
            assert result["passed"]
            record_result(result)


def test_ct_006_kill_after_result_persist_replays_without_second_call() -> None:
    scenario = "after_result_persist"
    with replay_database() as environment:
        identity = create_work(environment, scenario)
        with killed_worker(identity, scenario) as killed:
            lease = rotate_lease(environment, identity, scenario)
            replay = PhysicalInvocationLedger(environment.worker_factory).invoke(
                **invocation_arguments(identity, lease),
                reservation_audit_receipt_id="audit-after-result-replay-reserve",
                completion_audit_receipt_id="audit-after-result-replay-complete",
                handler=lambda: increment_side_effect(killed.fixture),
            )
            assert replay.decision == "replay"
            assert replay.handler_called is False
            append_recovery_event(environment, identity, scenario)
            result = build_result(
                environment=environment,
                identity=identity,
                killed=killed,
                lease=lease,
                ct_ids=("CT-006",),
                expected_side_effect_count=1,
                expected_invocation_count=1,
                expected_checkpoint_count=0,
                expected_invocation_status="succeeded",
            )
            assert result["reserved_calls"] == 1
            assert result["passed"]
            record_result(result)
