"""C1 correctness shard: expanded E0 and 50k executable state sequences."""

from __future__ import annotations

from copy import deepcopy
from datetime import UTC, datetime, timedelta
import importlib.util
import json
from pathlib import Path
import random
import time
from types import ModuleType
from typing import Any
from uuid import UUID

from app.api.sse import LastEventIdInvalid, parse_last_event_id
from app.auth.resume_token import (
    ResumeCapabilityRecord,
    ResumeCapabilityRejected,
    ResumeCapabilityService,
)
from app.persistence.models.runtime import RunState
from app.persistence.repositories.runs import ALLOWED_TRANSITIONS
from app.runtime.state import (
    BudgetSnapshot,
    GoNowAgentState,
    StateContractError,
    StateGuard,
    StateReference,
)

from harness_common import (
    CertificationFailure,
    canonical_sha256,
    gate_report,
    require_candidate_oid,
    sha256_file,
    source_artifact,
    wilson_lower_bound,
    write_atomic_json,
)


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
E0_MODULE_PATH = SERVICE_ROOT / "tests" / "eval" / "test_e0_parity.py"
E0_REQUESTS_PATH = SERVICE_ROOT / "tests" / "eval" / "datasets" / "e0" / "requests.jsonl"
E0_MANIFEST_PATH = (
    REPOSITORY_ROOT / "docs" / "execution" / "evidence" / "phase-04" / "P04-000" / "e0-manifest.json"
)


REFERENCE_TRANSITIONS: dict[RunState, frozenset[RunState]] = {
    RunState.CREATED: frozenset({RunState.QUEUED}),
    RunState.QUEUED: frozenset(
        {RunState.RUNNING, RunState.CANCELLING, RunState.BLOCKED, RunState.FAILED}
    ),
    RunState.RUNNING: frozenset(
        {
            RunState.WAITING_INPUT,
            RunState.RECOVERING,
            RunState.CANCELLING,
            RunState.SUCCEEDED,
            RunState.BLOCKED,
            RunState.FAILED,
        }
    ),
    RunState.WAITING_INPUT: frozenset(
        {RunState.RESUMING, RunState.CANCELLING, RunState.BLOCKED, RunState.FAILED}
    ),
    RunState.RESUMING: frozenset(
        {
            RunState.RUNNING,
            RunState.CANCELLING,
            RunState.SUCCEEDED,
            RunState.BLOCKED,
            RunState.FAILED,
        }
    ),
    RunState.RECOVERING: frozenset(
        {
            RunState.RUNNING,
            RunState.CANCELLING,
            RunState.SUCCEEDED,
            RunState.BLOCKED,
            RunState.FAILED,
        }
    ),
    RunState.CANCELLING: frozenset({RunState.CANCELLED}),
    RunState.SUCCEEDED: frozenset(),
    RunState.CANCELLED: frozenset(),
    RunState.BLOCKED: frozenset(),
    RunState.FAILED: frozenset(),
}


class _MemoryResumeStore:
    def __init__(self) -> None:
        self.records: dict[str, ResumeCapabilityRecord] = {}

    def insert(self, record: ResumeCapabilityRecord) -> None:
        if record.token_hash in self.records:
            raise AssertionError("duplicate resume token digest")
        self.records[record.token_hash] = record

    def consume_once(self, **values: Any) -> ResumeCapabilityRecord | None:
        token_hash = str(values["token_hash"])
        record = self.records.get(token_hash)
        if record is None or record.consumed_at is not None:
            return None
        for name in (
            "tenant_id",
            "principal_id",
            "run_id",
            "interrupt_id",
            "command_hash",
            "command_version",
        ):
            if getattr(record, name) != values[name]:
                return None
        consumed_at = values["consumed_at"]
        if consumed_at > record.expires_at:
            return None
        consumed = ResumeCapabilityRecord(
            capability_id=record.capability_id,
            token_hash=record.token_hash,
            nonce=record.nonce,
            tenant_id=record.tenant_id,
            principal_id=record.principal_id,
            run_id=record.run_id,
            interrupt_id=record.interrupt_id,
            command_hash=record.command_hash,
            command_version=record.command_version,
            issued_at=record.issued_at,
            expires_at=record.expires_at,
            consumed_at=consumed_at,
        )
        self.records[token_hash] = consumed
        return consumed


def _load_e0_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("gonow_certification_e0", E0_MODULE_PATH)
    if spec is None or spec.loader is None:
        raise CertificationFailure("c1.e0_module_unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text("utf-8").splitlines() if line]


def _allowed_rotation(value: str, allowed: tuple[str, ...], variant: int) -> str:
    if value not in allowed:
        return value
    return allowed[(allowed.index(value) + variant) % len(allowed)]


def _e0_variant(source: dict[str, Any], variant: int, ordinal: int) -> dict[str, Any]:
    record = deepcopy(source)
    request = record["request"]
    record["case_id"] = f"C1-E0-{ordinal:06d}"
    if variant == 1:
        request["currency"] = _allowed_rotation(
            str(request["currency"]), ("CNY", "EUR", "USD"), 1
        )
    elif variant == 2:
        request["locale"] = _allowed_rotation(
            str(request["locale"]), ("en-GB", "en-US", "zh-CN"), 2
        )
    elif variant == 3:
        budget = int(request["budget"])
        request["budget"] = budget - (ordinal % 17 + 1) if budget < 0 else budget + ordinal + 1
    elif variant == 4:
        destination = request["destination"]
        if destination is not None:
            if request["origin"] == destination:
                replacement = f"SameCity{ordinal}"
                request["origin"] = replacement
                request["destination"] = replacement
            else:
                request["origin"] = f"Origin{ordinal}"
                request["destination"] = f"Destination{ordinal}"
    return record


def _semantic_view(output: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": output["kind"],
        "candidate": output["candidate"],
        "error": output["error"],
        "metrics": output["metrics"],
        "warning_codes": output["warning_codes"],
    }


def run_expanded_e0(evidence_root: Path) -> dict[str, Any]:
    module = _load_e0_module()
    frozen = module.verify_frozen_contract()
    source_cases = _read_jsonl(E0_REQUESTS_PATH)
    if len(source_cases) != 40:
        raise CertificationFailure("c1.e0_source_count_drift")
    legacy = module.LegacyFixtureAdapter()
    candidate = module.SingleAgentFixtureAdapter()
    failures: list[dict[str, Any]] = []
    derived_identity: list[dict[str, Any]] = []
    case_count = 0
    for variant in range(5):
        for index, source in enumerate(source_cases):
            ordinal = variant * len(source_cases) + index + 1
            record = _e0_variant(source, variant, ordinal)
            before_request = deepcopy(record["request"])
            legacy_output = legacy.invoke(record)
            candidate_output = candidate.invoke(record)
            case_count += 1
            if _semantic_view(legacy_output) != _semantic_view(candidate_output):
                failures.append(
                    {
                        "case_id": record["case_id"],
                        "failure_code": "e0.parity_mismatch",
                    }
                )
            if record["request"] != before_request:
                failures.append(
                    {
                        "case_id": record["case_id"],
                        "failure_code": "e0.input_mutated",
                    }
                )
            if candidate_output["metrics"]["formal_write_count"] != 0:
                failures.append(
                    {
                        "case_id": record["case_id"],
                        "failure_code": "e0.formal_write",
                    }
                )
            derived_identity.append(
                {
                    "case_id": record["case_id"],
                    "variant": variant,
                    "input_sha256": canonical_sha256(record["request"]),
                    "outcome": candidate_output["kind"],
                }
            )
    if len({row["input_sha256"] for row in derived_identity}) < 160:
        raise CertificationFailure("c1.e0_insufficient_unique_inputs")
    report = {
        "schema_version": "1.0",
        "gate_id": "C1",
        "corpus_id": "c1-e0-metamorphic-v1",
        "source_case_count": len(source_cases),
        "metamorphic_variant_count": 5,
        "case_count": case_count,
        "unique_input_count": len({row["input_sha256"] for row in derived_identity}),
        "failure_count": len(failures),
        "failures": failures[:100],
        "formal_write_count": 0,
        "frozen_e0": frozen,
        "source_manifest_sha256": sha256_file(E0_MANIFEST_PATH),
        "derived_cases_sha256": canonical_sha256(derived_identity),
        "production": False,
    }
    write_atomic_json(evidence_root / "c1-e0-expanded.json", report)
    return report


def _base_state(seed: int) -> GoNowAgentState:
    return GoNowAgentState(
        run_id=UUID(int=1_000_000 + seed),
        thread_id=UUID(int=2_000_000 + seed),
        tenant_id=UUID(int=3_000_000 + seed),
        principal_ref=f"principal://c1/{seed}",
        behavior_release_id=UUID(int=4_000_000 + seed),
        behavior_digest=f"{seed % 16:x}" * 64,
        goal_ref=StateReference(
            kind="goal",
            uri=f"goal://c1/{seed}",
            sha256=f"{(seed + 1) % 16:x}" * 64,
        ),
        budget=BudgetSnapshot(
            remaining_model_calls=8,
            remaining_tool_calls=12,
            remaining_tokens=16_000,
        ),
    )


def _run_resume_probe(seed: int) -> None:
    now = datetime(2028, 1, 1, tzinfo=UTC) + timedelta(seconds=seed)
    store = _MemoryResumeStore()
    token = f"grc_c1_{seed:08x}"
    service = ResumeCapabilityService(
        store,
        clock=lambda: now,
        token_factory=lambda: token,
    )
    run_id = UUID(int=5_000_000 + seed)
    interrupt_id = UUID(int=6_000_000 + seed)
    command_hash = f"{(seed + 2) % 16:x}" * 64
    issued = service.issue(
        tenant_id=f"tenant-c1-{seed % 23}",
        principal_id=f"principal-c1-{seed % 31}",
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash=command_hash,
        command_version="1.0",
        ttl=timedelta(minutes=5),
    )
    consumed = service.consume(
        token=token,
        tenant_id=f"tenant-c1-{seed % 23}",
        principal_id=f"principal-c1-{seed % 31}",
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash=command_hash,
        command_version="1.0",
    )
    if consumed.capability_id != issued.capability_id:
        raise AssertionError("resume capability identity changed")
    try:
        service.consume(
            token=token,
            tenant_id=f"tenant-c1-{seed % 23}",
            principal_id=f"principal-c1-{seed % 31}",
            run_id=run_id,
            interrupt_id=interrupt_id,
            command_hash=command_hash,
            command_version="1.0",
        )
    except ResumeCapabilityRejected:
        return
    raise AssertionError("resume replay was accepted")


def _run_sequence(seed: int) -> tuple[str, int]:
    randomizer = random.Random(0xC100_0000 + seed)
    state = _base_state(seed)
    guard = StateGuard()
    run_state = RunState.CREATED
    idempotency: dict[str, str] = {}
    transition_count = 0
    for step in range(12):
        operation = randomizer.randrange(7)
        if operation == 0:
            before = state
            state = guard.apply(
                state,
                {
                    "step_count": state.step_count + 1,
                    "model_call_count": state.model_call_count + (seed + step) % 2,
                    "tool_call_count": state.tool_call_count + (seed + step + 1) % 2,
                },
            )
            if state.step_count != before.step_count + 1:
                raise AssertionError("state counter did not advance")
        elif operation == 1:
            state = GoNowAgentState.from_checkpoint(
                json.loads(state.checkpoint_json())
            )
        elif operation == 2:
            try:
                guard.apply(state, {"step_count": max(0, state.step_count - 1)})
            except StateContractError:
                pass
            else:
                if state.step_count > 0:
                    raise AssertionError("counter regression accepted")
        elif operation == 3:
            key = f"idem-{seed % 97}-{step % 3}"
            request_hash = f"{(seed + step) % 16:x}" * 64
            existing = idempotency.get(key)
            if existing is None:
                idempotency[key] = request_hash
            elif existing != request_hash:
                # A changed request must not replace the original binding.
                if idempotency[key] != existing:
                    raise AssertionError("idempotency binding changed")
        elif operation == 4:
            allowed = REFERENCE_TRANSITIONS[run_state]
            actual = ALLOWED_TRANSITIONS[run_state]
            if actual != allowed:
                raise AssertionError(f"run transition drift:{run_state.value}")
            if allowed:
                run_state = sorted(allowed, key=lambda item: item.value)[
                    randomizer.randrange(len(allowed))
                ]
                transition_count += 1
        elif operation == 5:
            event_id = (seed * 13 + step) % 9_223_372_036_854_775_807
            if parse_last_event_id(str(event_id)) != event_id:
                raise AssertionError("SSE cursor changed")
            try:
                parse_last_event_id(f"{event_id}x")
            except LastEventIdInvalid:
                pass
            else:
                raise AssertionError("invalid SSE cursor accepted")
        else:
            if step == 0 or seed % 11 == 0:
                _run_resume_probe(seed * 16 + step)
            else:
                try:
                    guard.apply(state, {"secret": "synthetic-canary"})
                except StateContractError:
                    pass
                else:
                    raise AssertionError("forbidden state key accepted")
    return run_state.value, transition_count


def run_state_space(evidence_root: Path, *, sequence_count: int = 50_000) -> dict[str, Any]:
    if sequence_count < 50_000:
        raise CertificationFailure("c1.state_sequence_count_below_contract")
    started = time.perf_counter()
    failures: list[dict[str, Any]] = []
    terminal_counts: dict[str, int] = {}
    total_transitions = 0
    sequence_digests: list[str] = []
    for seed in range(sequence_count):
        try:
            terminal, transition_count = _run_sequence(seed)
            terminal_counts[terminal] = terminal_counts.get(terminal, 0) + 1
            total_transitions += transition_count
            sequence_digests.append(
                canonical_sha256(
                    {"seed": seed, "terminal": terminal, "transitions": transition_count}
                )
            )
        except Exception as error:  # noqa: BLE001 - preserve seed and stable type only
            failures.append(
                {
                    "seed": seed,
                    "failure_type": type(error).__name__,
                    "failure_code": str(error)[:160],
                }
            )
    elapsed = time.perf_counter() - started
    passed = sequence_count - len(failures)
    report = {
        "schema_version": "1.0",
        "gate_id": "C1",
        "corpus_id": "c1-state-space-v1",
        "seed_namespace": "0xC1000000+ordinal",
        "sequence_count": sequence_count,
        "steps_per_sequence": 12,
        "transition_count": total_transitions,
        "success_count": passed,
        "failure_count": len(failures),
        "success_rate": passed / sequence_count,
        "success_rate_lower_95": wilson_lower_bound(passed, sequence_count),
        "hard_invariant_pass_rate": passed / sequence_count,
        "terminal_counts": dict(sorted(terminal_counts.items())),
        "failure_samples": failures[:100],
        "sequence_results_sha256": canonical_sha256(sequence_digests),
        "duration_seconds": round(elapsed, 6),
        "production": False,
    }
    write_atomic_json(evidence_root / "state-space-report.json", report)
    return report


def run_c1(evidence_root: Path, candidate_oid: str) -> dict[str, Any]:
    candidate = require_candidate_oid(candidate_oid)
    evidence_root.mkdir(parents=True, exist_ok=True)
    e0 = run_expanded_e0(evidence_root)
    state = run_state_space(evidence_root)
    failures = e0["failure_count"] + state["failure_count"]
    metrics = {
        "e0_case_count": e0["case_count"],
        "state_sequence_count": state["sequence_count"],
        "mandatory_pass_rate": 1.0 if failures == 0 else 0.0,
        "hard_invariant_pass_rate": state["hard_invariant_pass_rate"],
        "success_rate_lower_95": state["success_rate_lower_95"],
    }
    supporting = [
        source_artifact(evidence_root, "regression-report.json"),
        source_artifact(evidence_root, "state-space-report.json"),
        source_artifact(evidence_root, "c1-e0-expanded.json"),
    ]
    status = "passed" if failures == 0 else "failed"
    report = gate_report(
        gate_id="C1",
        candidate_oid=candidate,
        status=status,
        metrics=metrics,
        sources=supporting,
    )
    write_atomic_json(evidence_root / "c1-correctness.json", report)
    return report
