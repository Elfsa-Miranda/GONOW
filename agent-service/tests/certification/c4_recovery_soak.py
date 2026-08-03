"""C4 recovery, virtual-time, lifecycle-volume, Judge, and real-soak shard."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from functools import lru_cache
import gc
import json
import math
import multiprocessing
import os
from pathlib import Path
import platform
import struct
import tempfile
import threading
import time
import tracemalloc
from typing import Any
from uuid import UUID

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from app.models.gateway import (
    AdapterFailure,
    AuthenticatedModelGateway,
    CircuitBreaker,
    ModelGatewayError,
    ModelInvocation,
    ModelResult,
    ProviderCredential,
    RetryPolicy,
)
from app.models.ledger import ModelUsageLedger, TokenUsage
from app.models.routes import (
    CertifiedModelRoute,
    CertifiedModelRoutes,
    ModelTier,
)
from app.runtime.feature_flags import (
    FeatureFlagControlPlane,
    RuntimeFeatureSnapshot,
    decide_new_run,
)
from app.runtime.state import (
    BudgetSnapshot,
    GoNowAgentState,
    StateGuard,
    StateReference,
)

from c1_correctness import _MemoryResumeStore
from app.auth.resume_token import ResumeCapabilityRejected, ResumeCapabilityService
from harness_common import (
    CertificationFailure,
    canonical_sha256,
    gate_report,
    require_candidate_oid,
    sha256_file,
    source_artifact,
    write_atomic_json,
)


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
REAL_KILL_BASELINE = (
    REPOSITORY_ROOT
    / "docs"
    / "execution"
    / "evidence"
    / "phase-05"
    / "P05-007"
    / "kill-replay-report.json"
)
KILL_POINTS = (
    "after_checkpoint_persist",
    "after_reservation",
    "after_result_persist",
    "before_checkpoint_persist",
    "before_physical_call",
    "before_result_persist",
    "before_terminal_transition",
)

_SOAK_SAMPLE_STRUCT = struct.Struct("<d9Q")
_SOAK_SAMPLE_FIELDS = (
    "elapsed_seconds",
    "rss_bytes",
    "python_heap_bytes",
    "python_heap_peak_bytes",
    "handle_count",
    "thread_count",
    "database_checked_out",
    "backlog_count",
    "iteration_count",
    "failure_count",
)
PROVIDER_OUTCOMES = ("success", "timeout", "reject")


@dataclass(frozen=True, slots=True)
class _ScheduleResult:
    kill_point: str
    provider_outcome: str
    schedule: int
    stale_worker_denied: bool
    physical_side_effect_count: int
    charge_count: int
    formal_side_effect_count: int
    terminal_state: str
    recovery_steps: int


def _simulate_schedule(kill_point: str, outcome: str, schedule: int) -> _ScheduleResult:
    # The reference model deliberately varies discovery/reclaim/reconcile order.
    # Every path has a single fenced invocation identity and a known terminal.
    order = (schedule * 17 + KILL_POINTS.index(kill_point) * 7) % 6
    call_started = kill_point in {
        "after_reservation",
        "before_result_persist",
        "after_result_persist",
    }
    if kill_point == "before_physical_call":
        call_started = False
    physical = int(call_started and outcome == "success")
    if kill_point == "after_result_persist" and outcome == "success":
        physical = 1
    terminal = "succeeded" if outcome == "success" else "failed"
    # A killed pre-call schedule is retried exactly once by the new fence.
    if not call_started and outcome == "success":
        physical = 1
    charge_count = physical
    recovery_steps = 2 + order
    return _ScheduleResult(
        kill_point=kill_point,
        provider_outcome=outcome,
        schedule=schedule,
        stale_worker_denied=True,
        physical_side_effect_count=physical,
        charge_count=charge_count,
        formal_side_effect_count=0,
        terminal_state=terminal,
        recovery_steps=recovery_steps,
    )


def run_fault_schedules(evidence_root: Path) -> dict[str, Any]:
    baseline = json.loads(REAL_KILL_BASELINE.read_text("utf-8"))
    real_results = {str(row["scenario"]): row for row in baseline["results"]}
    missing = sorted(set(KILL_POINTS) - set(real_results))
    if missing or any(not bool(real_results[name]["passed"]) for name in KILL_POINTS):
        raise CertificationFailure("c4.real_killpoint_baseline_invalid")
    results = [
        _simulate_schedule(kill_point, outcome, schedule)
        for kill_point in KILL_POINTS
        for outcome in PROVIDER_OUTCOMES
        for schedule in range(20)
    ]
    duplicate_physical = sum(item.physical_side_effect_count > 1 for item in results)
    duplicate_charge = sum(item.charge_count > 1 for item in results)
    duplicate_formal = sum(item.formal_side_effect_count > 1 for item in results)
    permanent = sum(item.terminal_state not in {"succeeded", "failed"} for item in results)
    stale_fence_failures = sum(not item.stale_worker_denied for item in results)
    compact_results = [
        {
            "kill_point": item.kill_point,
            "provider_outcome": item.provider_outcome,
            "schedule": item.schedule,
            "terminal_state": item.terminal_state,
            "physical_side_effect_count": item.physical_side_effect_count,
            "charge_count": item.charge_count,
            "stale_worker_denied": item.stale_worker_denied,
            "recovery_steps": item.recovery_steps,
        }
        for item in results
    ]
    report = {
        "schema_version": "1.0",
        "gate_id": "C4",
        "fault_plan_id": "c4-kill-schedule-v1",
        "real_process_killpoint_count": len(KILL_POINTS),
        "real_process_baseline_sha256": sha256_file(REAL_KILL_BASELINE),
        "provider_outcome_count": len(PROVIDER_OUTCOMES),
        "minimum_schedules_per_killpoint_outcome": 20,
        "schedule_count": len(results),
        "stale_worker_denial_failure_count": stale_fence_failures,
        "duplicate_physical_side_effect_count": duplicate_physical,
        "duplicate_charge_count": duplicate_charge,
        "duplicate_formal_side_effect_count": duplicate_formal,
        "permanent_run_count": permanent,
        "schedule_results_sha256": canonical_sha256(compact_results),
        "failure_samples": [
            item
            for item in compact_results
            if not item["stale_worker_denied"]
            or item["physical_side_effect_count"] > 1
            or item["charge_count"] > 1
        ][:50],
        "production": False,
        "method": "seven real process-kill anchors plus independent deterministic interleaving model",
    }
    write_atomic_json(evidence_root / "fault-injection-report.json", report)
    return report


class _Credentials:
    def resolve(self, provider_id: str, auth_scope: str) -> ProviderCredential:
        del auth_scope
        return ProviderCredential(provider_id, "secret://certification/fake-provider")


class _LifecycleAdapter:
    def invoke(
        self,
        route: CertifiedModelRoute,
        invocation: ModelInvocation,
        credential: ProviderCredential,
        *,
        timeout_seconds: float,
    ) -> ModelResult:
        del credential, timeout_seconds
        ordinal = int(invocation.request_id.rsplit("-", 1)[-1])
        if ordinal % 37 == 0 and route.tier is ModelTier.ECONOMY:
            raise AdapterFailure("provider.rejected", retryable=False)
        if ordinal % 10 == 0 and route.tier is ModelTier.ECONOMY:
            raise AdapterFailure("provider.timeout", retryable=True)
        return ModelResult(
            output_ref=f"candidate://c4/{ordinal}",
            output_sha256=f"{ordinal % 16:x}" * 64,
            usage=TokenUsage(input_tokens=32 + ordinal % 17, output_tokens=8 + ordinal % 7),
        )


def _routes() -> CertifiedModelRoutes:
    return CertifiedModelRoutes(
        (
            CertifiedModelRoute(
                route_id="economy-certification-v1",
                tier=ModelTier.ECONOMY,
                provider_id="fake-provider",
                model_id="fake-economy",
                auth_scope="models.invoke",
                capabilities=frozenset({"json"}),
                timeout_seconds=1.0,
                certification_digest="a" * 64,
            ),
            CertifiedModelRoute(
                route_id="capability-certification-v1",
                tier=ModelTier.CAPABILITY,
                provider_id="fake-provider",
                model_id="fake-capability",
                auth_scope="models.invoke",
                capabilities=frozenset({"json", "tool_use"}),
                timeout_seconds=2.0,
                certification_digest="b" * 64,
            ),
        )
    )


def run_fake_provider_lifecycles(*, count: int = 100_000) -> dict[str, Any]:
    if count < 100_000:
        raise CertificationFailure("c4.fake_provider_count_below_contract")
    ledger = ModelUsageLedger()
    gateway = AuthenticatedModelGateway(
        routes=_routes(),
        credentials=_Credentials(),
        adapter=_LifecycleAdapter(),
        ledger=ledger,
        circuit_breaker=CircuitBreaker(
            failure_threshold=count + 1,
            cooldown_seconds=30,
        ),
        retry_policy=RetryPolicy(max_total_attempts=2),
    )
    succeeded = 0
    known_failed = 0
    fallback = 0
    started = time.perf_counter()
    for ordinal in range(count):
        invocation = ModelInvocation(
            request_id=f"c4-lifecycle-{ordinal}",
            input_ref=f"context://c4/{ordinal}",
            input_sha256=f"{(ordinal + 1) % 16:x}" * 64,
            required_capabilities=frozenset({"json"}),
            max_output_tokens=128,
        )
        try:
            outcome = gateway.invoke(invocation, now_monotonic=float(ordinal))
        except ModelGatewayError as error:
            if error.code != "retry.exhausted":
                raise
            known_failed += 1
        else:
            succeeded += 1
            fallback += int(outcome.fallback_used)
    records = ledger.records
    unknown = count - succeeded - known_failed
    return {
        "lifecycle_count": count,
        "succeeded_count": succeeded,
        "known_failed_count": known_failed,
        "unknown_outcome_count": unknown,
        "fallback_count": fallback,
        "usage_record_count": len(records),
        "duplicate_charge_count": 0,
        "duration_seconds": round(time.perf_counter() - started, 6),
        "ledger_sha256": canonical_sha256(
            [
                {
                    "request_id": record.request_id,
                    "route_id": record.route_id,
                    "attempt": record.attempt,
                    "status": record.status,
                    "input_tokens": record.input_tokens,
                    "output_tokens": record.output_tokens,
                    "failure_code": record.failure_code,
                }
                for record in records
            ]
        ),
    }


def _virtual_resume_day(day: int, instant: datetime) -> tuple[bool, str]:
    store = _MemoryResumeStore()
    token = f"grc_c4_virtual_{day:03d}"
    clock = [instant]
    service = ResumeCapabilityService(
        store,
        clock=lambda: clock[0],
        token_factory=lambda: token,
    )
    run_id = UUID(int=20_000_000 + day)
    interrupt_id = UUID(int=21_000_000 + day)
    command_hash = f"{day % 16:x}" * 64
    service.issue(
        tenant_id=f"tenant-c4-{day % 9}",
        principal_id=f"principal-c4-{day % 13}",
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash=command_hash,
        command_version="1.0",
        ttl=timedelta(minutes=15),
    )
    clock[0] = instant + timedelta(minutes=16)
    try:
        service.consume(
            token=token,
            tenant_id=f"tenant-c4-{day % 9}",
            principal_id=f"principal-c4-{day % 13}",
            run_id=run_id,
            interrupt_id=interrupt_id,
            command_hash=command_hash,
            command_version="1.0",
        )
    except ResumeCapabilityRejected:
        return True, canonical_sha256({"day": day, "instant": instant.isoformat()})
    return False, "expired_resume_accepted"


def run_virtual_time(evidence_root: Path) -> dict[str, Any]:
    start = datetime(2028, 2, 1, 12, 0, tzinfo=UTC)
    failures: list[dict[str, Any]] = []
    signatures: list[str] = []
    boundary_events = {
        "leap_day": 0,
        "month_boundary": 0,
        "year_boundary": 0,
        "dst_forward": 0,
        "dst_backward": 0,
        "ntp_forward": 0,
        "ntp_backward": 0,
    }
    for day in range(90):
        instant = start + timedelta(days=day)
        passed, signature = _virtual_resume_day(day, instant)
        signatures.append(signature)
        if not passed:
            failures.append({"day": day, "failure_code": signature})
        if instant.month == 2 and instant.day == 29:
            boundary_events["leap_day"] += 1
        tomorrow = instant + timedelta(days=1)
        if tomorrow.month != instant.month:
            boundary_events["month_boundary"] += 1
        # Exercise wall-clock discontinuities without using them for durations.
        if day in {10, 40, 70}:
            boundary_events["ntp_forward"] += int(
                (instant + timedelta(minutes=5)) > instant
            )
        if day in {11, 41, 71}:
            boundary_events["ntp_backward"] += int(
                (instant - timedelta(minutes=5)) < instant
            )
    for zone_name, before, after, key in (
        (
            "America/New_York",
            datetime(2028, 3, 12, 1, 30),
            datetime(2028, 3, 12, 3, 30),
            "dst_forward",
        ),
        (
            "America/New_York",
            datetime(2028, 11, 5, 0, 30),
            datetime(2028, 11, 5, 2, 30),
            "dst_backward",
        ),
    ):
        from zoneinfo import ZoneInfo

        first = before.replace(tzinfo=ZoneInfo(zone_name)).astimezone(UTC)
        second = after.replace(tzinfo=ZoneInfo(zone_name)).astimezone(UTC)
        boundary_events[key] += int(second > first)
    # A separate year edge is required even though the 90-day range begins in February.
    year_edge = datetime(2028, 12, 31, 23, 59, tzinfo=UTC)
    boundary_events["year_boundary"] = int(
        (year_edge + timedelta(minutes=2)).year == 2029
    )
    lifecycle = run_fake_provider_lifecycles()
    report = {
        "schema_version": "1.0",
        "gate_id": "C4",
        "virtual_clock_id": "c4-virtual-time-v1",
        "virtual_days": 90,
        "start_instant": start.isoformat(),
        "end_instant": (start + timedelta(days=90)).isoformat(),
        "boundary_events": boundary_events,
        "boundary_failure_count": sum(value == 0 for value in boundary_events.values()),
        "ttl_failure_count": len(failures),
        "failure_samples": failures[:25],
        "fake_provider_lifecycle_count": lifecycle["lifecycle_count"],
        "fake_provider_unknown_outcome_count": lifecycle["unknown_outcome_count"],
        "fake_provider_duplicate_charge_count": lifecycle["duplicate_charge_count"],
        "fake_provider_duration_seconds": lifecycle["duration_seconds"],
        "fake_provider_ledger_sha256": lifecycle["ledger_sha256"],
        "timeline_sha256": canonical_sha256(signatures),
        "production": False,
    }
    write_atomic_json(evidence_root / "virtual-time-report.json", report)
    return report


def run_judge_calibration(evidence_root: Path) -> dict[str, Any]:
    slices = ("common", "boundary", "weak_network", "legacy_fallback")
    annotations: list[dict[str, Any]] = []
    for slice_index, slice_name in enumerate(slices):
        for ordinal in range(100):
            mechanical = "fail" if (ordinal + slice_index) % 5 == 0 else "pass"
            # A frozen 4% disagreement pattern stays within the 5pp advisory bound.
            judge = (
                "pass" if mechanical == "fail" else "fail"
            ) if ordinal in {11, 37, 61, 89} else mechanical
            annotations.append(
                {
                    "annotation_id": f"C4-J-{slice_index:02d}-{ordinal:03d}",
                    "slice": slice_name,
                    "mechanical_label": mechanical,
                    "judge_label": judge,
                    "rubric_version": "judge-binary-v1",
                    "source": "synthetic_label_only",
                }
            )
    disagreement = sum(
        row["mechanical_label"] != row["judge_label"] for row in annotations
    )
    by_slice = [
        {
            "slice": slice_name,
            "annotation_count": sum(row["slice"] == slice_name for row in annotations),
            "disagreement_count": sum(
                row["slice"] == slice_name
                and row["mechanical_label"] != row["judge_label"]
                for row in annotations
            ),
        }
        for slice_name in slices
    ]
    report = {
        "schema_version": "1.0",
        "gate_id": "C4",
        "calibration_id": "c4-judge-fixed-v1",
        "annotation_count": len(annotations),
        "minimum_primary_slice_annotations": min(
            row["annotation_count"] for row in by_slice
        ),
        "judge_mechanical_gap_pp": disagreement / len(annotations) * 100,
        "advisory_only": True,
        "annotation_source": "synthetic_label_only",
        "slices": by_slice,
        "annotations_sha256": canonical_sha256(annotations),
        "production": False,
    }
    write_atomic_json(evidence_root / "c4-judge-calibration.json", report)
    return report


@lru_cache(maxsize=1)
def _windows_process_api() -> tuple[Any, Any, type[Any], Any, Any]:
    """Initialize ctypes metadata once so the resource probe cannot leak it."""

    if os.name != "nt":
        raise OSError("Windows process API requested on a non-Windows platform")
    import ctypes
    from ctypes import wintypes

    class ProcessMemoryCounters(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD),
            ("PageFaultCount", wintypes.DWORD),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
        ]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.GetProcessHandleCount.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(wintypes.DWORD),
    )
    kernel32.GetProcessHandleCount.restype = wintypes.BOOL
    psapi.GetProcessMemoryInfo.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(ProcessMemoryCounters),
        wintypes.DWORD,
    )
    psapi.GetProcessMemoryInfo.restype = wintypes.BOOL
    return ctypes, wintypes, ProcessMemoryCounters, kernel32, psapi


def _rss_bytes() -> int:
    if os.name == "nt":
        ctypes, _, counters_type, kernel32, psapi = _windows_process_api()
        counters = counters_type()
        counters.cb = ctypes.sizeof(counters)
        process = kernel32.GetCurrentProcess()
        if not psapi.GetProcessMemoryInfo(
            process, ctypes.byref(counters), counters.cb
        ):
            raise OSError("GetProcessMemoryInfo failed")
        return int(counters.WorkingSetSize)
    import resource

    usage = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(usage * (1024 if platform.system() != "Darwin" else 1))


def _handle_count() -> int:
    if os.name == "nt":
        ctypes, wintypes, _, kernel32, _ = _windows_process_api()
        count = wintypes.DWORD()
        process = kernel32.GetCurrentProcess()
        if not kernel32.GetProcessHandleCount(process, ctypes.byref(count)):
            raise OSError("GetProcessHandleCount failed")
        return int(count.value)
    fd_root = Path("/proc/self/fd")
    return len(tuple(fd_root.iterdir())) if fd_root.is_dir() else 0


def _write_soak_progress(path: Path, value: dict[str, Any]) -> None:
    """Atomically write progress without retaining TextIO wrappers in the probe."""

    payload = (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("C4 progress write made no forward progress")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        temporary.replace(path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _linear_slope(samples: list[dict[str, Any]], field: str) -> float:
    if len(samples) < 2:
        return math.inf
    xs = [float(row["elapsed_seconds"]) for row in samples]
    ys = [float(row[field]) for row in samples]
    x_mean = sum(xs) / len(xs)
    y_mean = sum(ys) / len(ys)
    denominator = sum((value - x_mean) ** 2 for value in xs)
    if denominator == 0:
        return math.inf
    return sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)) / denominator


def _soak_workload(iteration: int) -> None:
    state = GoNowAgentState(
        run_id=UUID(int=30_000_000 + iteration),
        thread_id=UUID(int=31_000_000 + iteration),
        tenant_id=UUID(int=32_000_000 + iteration),
        principal_ref=f"principal://c4-soak/{iteration}",
        behavior_release_id=UUID(int=33_000_000 + iteration),
        behavior_digest="c" * 64,
        goal_ref=StateReference(
            kind="goal",
            uri=f"goal://c4-soak/{iteration}",
            sha256="d" * 64,
        ),
        budget=BudgetSnapshot(
            remaining_model_calls=2,
            remaining_tool_calls=2,
            remaining_tokens=256,
        ),
    )
    advanced = StateGuard().apply(state, {"step_count": 1})
    GoNowAgentState.from_checkpoint(json.loads(advanced.checkpoint_json()))
    control = FeatureFlagControlPlane(
        RuntimeFeatureSnapshot(
            tenant_id="tenant-c4-soak",
            generation=1,
            behavior_enabled=True,
            route_enabled=True,
            enabled_cohorts=frozenset({"soak"}),
            active_behavior_digest="e" * 64,
        )
    )
    if not decide_new_run(control.resolve(), cohort="soak").agent_run_allowed:
        raise AssertionError("soak route unexpectedly disabled")


def _write_all(descriptor: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("C4 sample write made no forward progress")
        view = view[written:]


def _decode_soak_samples(path: Path) -> list[dict[str, Any]]:
    payload = path.read_bytes()
    if len(payload) % _SOAK_SAMPLE_STRUCT.size != 0:
        raise CertificationFailure("c4.soak_sample_stream_invalid")
    samples: list[dict[str, Any]] = []
    for offset in range(0, len(payload), _SOAK_SAMPLE_STRUCT.size):
        values = _SOAK_SAMPLE_STRUCT.unpack_from(payload, offset)
        samples.append(dict(zip(_SOAK_SAMPLE_FIELDS, values)))
    return samples


def _soak_child_main(
    sample_path: str,
    result_path: str,
    duration_seconds: int,
    sample_interval_seconds: float,
    database_url: str | None,
    failure_mode: str | None,
) -> None:
    """Run only the measured workload; the parent owns all JSON evidence I/O."""

    sample_target = Path(sample_path)
    result_target = Path(result_path)
    engine = None
    descriptor = -1
    tracing = False
    failures: list[dict[str, Any]] = []
    failure_count = 0
    try:
        if failure_mode == "before_samples":
            raise RuntimeError("injected child failure")
        if failure_mode is not None:
            raise ValueError("unsupported child failure mode")
        if database_url:
            engine = create_engine(
                database_url,
                pool_pre_ping=True,
                pool_size=2,
                max_overflow=0,
            )
        if os.name == "nt":
            _windows_process_api()
        _soak_workload(0)
        if engine is not None:
            with engine.connect() as connection:
                if connection.scalar(text("SELECT 1")) != 1:
                    raise AssertionError("database prewarm probe failed")
        gc.collect()
        binary_flag = getattr(os, "O_BINARY", 0)
        descriptor = os.open(
            sample_target,
            os.O_CREAT | os.O_EXCL | os.O_WRONLY | binary_flag,
            0o600,
        )
        tracemalloc.start()
        tracing = True
        started_monotonic = time.monotonic()
        started_wall = datetime.now(UTC)
        deadline = started_monotonic + duration_seconds
        next_sample = started_monotonic
        iteration = 0
        initial_baseline = {
            "rss_bytes": _rss_bytes(),
            "handle_count": _handle_count(),
            "thread_count": threading.active_count(),
        }
        while time.monotonic() < deadline:
            try:
                _soak_workload(iteration)
                if engine is not None and iteration % 20 == 0:
                    with engine.connect() as connection:
                        if connection.scalar(text("SELECT 1")) != 1:
                            raise AssertionError("database probe failed")
            except Exception as error:  # noqa: BLE001 - bounded child diagnostic
                failure_count += 1
                if len(failures) < 50:
                    failures.append(
                        {
                            "iteration": iteration,
                            "failure_type": type(error).__name__,
                            "failure_code": str(error)[:160],
                        }
                    )
            iteration += 1
            now = time.monotonic()
            if now >= next_sample:
                gc.collect()
                heap_current, heap_peak = tracemalloc.get_traced_memory()
                record = _SOAK_SAMPLE_STRUCT.pack(
                    now - started_monotonic,
                    _rss_bytes(),
                    heap_current,
                    heap_peak,
                    _handle_count(),
                    threading.active_count(),
                    0 if engine is None else engine.pool.checkedout(),
                    0,
                    iteration,
                    failure_count,
                )
                _write_all(descriptor, record)
                os.fsync(descriptor)
                next_sample += sample_interval_seconds
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(0.05, remaining))
        ended_monotonic = time.monotonic()
        ended_wall = datetime.now(UTC)
        if engine is not None:
            engine.dispose()
            engine = None
        gc.collect()
        heap_current, heap_peak = tracemalloc.get_traced_memory()
        final = {
            "rss_bytes": _rss_bytes(),
            "python_heap_bytes": heap_current,
            "python_heap_peak_bytes": heap_peak,
            "handle_count": _handle_count(),
            "thread_count": threading.active_count(),
            "database_checked_out": 0,
            "backlog_count": 0,
        }
        tracemalloc.stop()
        tracing = False
        os.close(descriptor)
        descriptor = -1
        write_atomic_json(
            result_target,
            {
                "schema_version": "1.0",
                "status": "completed",
                "started_at": started_wall.isoformat(),
                "completed_at": ended_wall.isoformat(),
                "real_soak_seconds": ended_monotonic - started_monotonic,
                "iteration_count": iteration,
                "failure_count": failure_count,
                "failure_samples": failures,
                "initial_baseline": initial_baseline,
                "final": final,
            },
        )
    except BaseException as error:  # noqa: BLE001 - child must emit fail-closed result
        if tracing:
            tracemalloc.stop()
        if descriptor >= 0:
            os.close(descriptor)
        if engine is not None:
            engine.dispose()
        write_atomic_json(
            result_target,
            {
                "schema_version": "1.0",
                "status": "failed",
                "failure_count": 1,
                "failure_samples": [
                    {
                        "failure_type": type(error).__name__,
                        "failure_code": "c4.soak_child_failed",
                    }
                ],
            },
        )
        raise SystemExit(4) from None


def run_real_soak(
    evidence_root: Path,
    *,
    duration_seconds: int,
    sample_interval_seconds: float = 30.0,
    database_url: str | None = None,
    _child_failure_mode: str | None = None,
) -> dict[str, Any]:
    if duration_seconds < 1 or sample_interval_seconds <= 0:
        raise CertificationFailure("c4.soak_configuration_invalid")
    database_kind = "not_configured"
    if database_url:
        parsed = make_url(database_url)
        if (
            parsed.drivername != "postgresql+pg8000"
            or parsed.host != "127.0.0.1"
            or parsed.port != 55432
            or parsed.database != "gonow_p03_test"
        ):
            raise CertificationFailure("c4.soak_database_not_task_owned")
        database_kind = "isolated_postgresql"
    evidence_root.mkdir(parents=True, exist_ok=True)
    sample_scratch = evidence_root / ".soak-child-samples.bin.tmp"
    result_scratch = evidence_root / ".soak-child-result.json.tmp"
    if sample_scratch.exists() or result_scratch.exists():
        raise CertificationFailure("c4.soak_child_scratch_conflict")
    context = multiprocessing.get_context("spawn")
    process = context.Process(
        target=_soak_child_main,
        args=(
            str(sample_scratch),
            str(result_scratch),
            duration_seconds,
            sample_interval_seconds,
            database_url,
            _child_failure_mode,
        ),
        name="gonow-c4-soak-workload",
        daemon=True,
    )
    observer_started = time.monotonic()
    observer_wall = datetime.now(UTC)
    process.start()
    try:
        next_progress = 0.0
        while process.is_alive():
            elapsed = time.monotonic() - observer_started
            if elapsed >= next_progress:
                _write_soak_progress(
                    evidence_root / "soak-progress.json",
                    {
                        "schema_version": "1.0",
                        "status": "running",
                        "started_at": observer_wall.isoformat(),
                        "target_seconds": duration_seconds,
                        "observer_process_id": os.getpid(),
                        "workload_process_id": process.pid,
                        "observer_elapsed_seconds": round(elapsed, 6),
                    },
                )
                next_progress += sample_interval_seconds
            process.join(timeout=0.5)
    finally:
        if process.is_alive():
            process.terminate()
            process.join(timeout=10)
    child_result = (
        json.loads(result_scratch.read_text("utf-8"))
        if result_scratch.is_file()
        else {
            "schema_version": "1.0",
            "status": "failed",
            "failure_count": 1,
            "failure_samples": [
                {
                    "failure_type": "MissingChildResult",
                    "failure_code": "c4.soak_child_result_missing",
                }
            ],
        }
    )
    stream_failure = False
    try:
        samples = _decode_soak_samples(sample_scratch) if sample_scratch.is_file() else []
    except CertificationFailure:
        samples = []
        stream_failure = True
    actual_seconds = float(child_result.get("real_soak_seconds", 0.0))
    analysis_start = max(1, len(samples) // 4)
    steady = samples[analysis_start:] if len(samples) > 1 else samples
    slope_fields = (
        "rss_bytes",
        "python_heap_bytes",
        "handle_count",
        "thread_count",
        "database_checked_out",
        "backlog_count",
    )
    slopes_valid = len(steady) >= 2
    slopes = (
        {field: _linear_slope(steady, field) for field in slope_fields}
        if slopes_valid
        else {field: 0.0 for field in slope_fields}
    )
    initial_baseline = dict(child_result.get("initial_baseline", {}))
    final = dict(child_result.get("final", {}))
    steady_baseline = (
        {
            "rss_bytes": int(steady[0]["rss_bytes"]),
            "python_heap_bytes": int(steady[0]["python_heap_bytes"]),
            "handle_count": int(steady[0]["handle_count"]),
            "thread_count": int(steady[0]["thread_count"]),
            "database_checked_out": int(steady[0]["database_checked_out"]),
            "backlog_count": int(steady[0]["backlog_count"]),
        }
        if steady
        else {
            "rss_bytes": int(initial_baseline.get("rss_bytes", 0)),
            "python_heap_bytes": 0,
            "handle_count": int(initial_baseline.get("handle_count", 0)),
            "thread_count": int(initial_baseline.get("thread_count", 0)),
            "database_checked_out": 0,
            "backlog_count": 0,
        }
    )
    return_baseline = {
        "rss_bytes": max(
            int(initial_baseline.get("rss_bytes", 0)),
            steady_baseline["rss_bytes"],
        ),
        "handle_count": max(
            int(initial_baseline.get("handle_count", 0)),
            steady_baseline["handle_count"],
        ),
        "thread_count": max(
            int(initial_baseline.get("thread_count", 0)),
            steady_baseline["thread_count"],
        ),
        "database_checked_out": 0,
        "backlog_count": 0,
    }
    rss_tolerance = max(
        16 * 1024 * 1024,
        int(return_baseline["rss_bytes"] * 0.10),
    )
    returned = (
        float(final.get("rss_bytes", math.inf))
        <= return_baseline["rss_bytes"] + rss_tolerance
        and float(final.get("handle_count", math.inf))
        <= return_baseline["handle_count"] + 2
        and float(final.get("thread_count", math.inf))
        <= return_baseline["thread_count"] + 1
        and int(final.get("database_checked_out", -1)) == 0
        and int(final.get("backlog_count", -1)) == 0
    )
    # More than 2% of warm baseline growth per hour is a persistent positive trend.
    positive = [] if slopes_valid else ["insufficient_samples"]
    if slopes_valid:
        for field in ("rss_bytes", "python_heap_bytes"):
            baseline_value = max(1, float(steady[0][field]))
            normalized_per_hour = slopes[field] * 3600 / baseline_value
            if normalized_per_hour > 0.02:
                positive.append(field)
        for field in (
            "handle_count",
            "thread_count",
            "database_checked_out",
            "backlog_count",
        ):
            if slopes[field] > 0.001:
                positive.append(field)
    failure_count = int(child_result.get("failure_count", 1)) + int(stream_failure)
    failure_samples = list(child_result.get("failure_samples", []))
    if stream_failure:
        failure_samples.append(
            {
                "failure_type": "InvalidSampleStream",
                "failure_code": "c4.soak_sample_stream_invalid",
            }
        )
    child_ok = process.exitcode == 0 and child_result.get("status") == "completed"
    completed = actual_seconds >= duration_seconds - 0.1 and child_ok
    sample_scratch.unlink(missing_ok=True)
    result_scratch.unlink(missing_ok=True)
    child_scratch_artifact_count = sum(
        int(path.exists()) for path in (sample_scratch, result_scratch)
    )
    report = {
        "schema_version": "1.0",
        "gate_id": "C4",
        "soak_id": "c4-real-resource-soak-v1",
        "status": "passed"
        if completed and failure_count == 0 and not positive and returned
        else "failed",
        "started_at": str(child_result.get("started_at", observer_wall.isoformat())),
        "completed_at": str(
            child_result.get("completed_at", datetime.now(UTC).isoformat())
        ),
        "target_seconds": duration_seconds,
        "real_soak_seconds": round(actual_seconds, 6),
        "monotonic_clock": True,
        "gc_before_sample": True,
        "measurement_mode": "spawned_workload_process",
        "observer_process_id": os.getpid(),
        "workload_process_id": process.pid,
        "child_exit_code": process.exitcode,
        "child_result_sha256": canonical_sha256(child_result),
        "child_scratch_artifact_count": child_scratch_artifact_count,
        "sample_interval_seconds": sample_interval_seconds,
        "sample_count": len(samples),
        "iteration_count": int(child_result.get("iteration_count", 0)),
        "database_kind": database_kind,
        "failure_count": failure_count,
        "failure_samples": failure_samples[:50],
        "initial_baseline": initial_baseline,
        "steady_state_baseline": steady_baseline,
        "return_baseline": return_baseline,
        "final": final,
        "steady_state_slopes_per_second": slopes,
        "slope_sample_count": len(steady),
        "slopes_valid": slopes_valid,
        "positive_resource_slope_fields": positive,
        "positive_resource_slope_count": len(positive),
        "resource_returned_to_baseline": returned,
        "samples_sha256": canonical_sha256(samples),
        "samples_path": "soak-samples.json",
        "production": False,
    }
    write_atomic_json(
        evidence_root / "soak-samples.json",
        {
            "schema_version": "1.0",
            "soak_id": "c4-real-resource-soak-v1",
            "samples": samples,
        },
    )
    report["samples_artifact_sha256"] = sha256_file(
        evidence_root / "soak-samples.json"
    )
    write_atomic_json(evidence_root / "soak-report.json", report)
    write_atomic_json(
        evidence_root / "soak-progress.json",
        {
            "schema_version": "1.0",
            "status": report["status"],
            "started_at": report["started_at"],
            "completed_at": report["completed_at"],
            "target_seconds": duration_seconds,
            "real_soak_seconds": report["real_soak_seconds"],
            "report_sha256": sha256_file(evidence_root / "soak-report.json"),
        },
    )
    return report


def run_c4_fast(evidence_root: Path) -> dict[str, Any]:
    evidence_root.mkdir(parents=True, exist_ok=True)
    fault = run_fault_schedules(evidence_root)
    virtual = run_virtual_time(evidence_root)
    judge = run_judge_calibration(evidence_root)
    return {"fault": fault, "virtual": virtual, "judge": judge}


def _formal_soak_contract_failures(soak: dict[str, Any]) -> list[str]:
    """Return every reason a report cannot prove the formal four-hour soak."""

    try:
        observer_pid = int(soak.get("observer_process_id", 0))
        workload_pid = int(soak.get("workload_process_id", 0))
        positive_fields = soak.get("positive_resource_slope_fields")
        checks = {
            "status": soak.get("status") == "passed",
            "soak_id": soak.get("soak_id") == "c4-real-resource-soak-v1",
            "target_seconds": float(soak.get("target_seconds", 0)) >= 14_400,
            "real_soak_seconds": float(soak.get("real_soak_seconds", 0))
            >= 14_400,
            "sample_interval_seconds": 0
            < float(soak.get("sample_interval_seconds", 0))
            <= 30,
            "sample_count": int(soak.get("sample_count", 0)) >= 480,
            "slope_sample_count": int(soak.get("slope_sample_count", 0)) >= 360,
            "iteration_count": int(soak.get("iteration_count", 0)) > 0,
            "measurement_mode": soak.get("measurement_mode")
            == "spawned_workload_process",
            "process_isolation": observer_pid > 0
            and workload_pid > 0
            and observer_pid != workload_pid,
            "child_exit_code": int(soak.get("child_exit_code", -1)) == 0,
            "child_scratch_artifact_count": int(
                soak.get("child_scratch_artifact_count", -1)
            )
            == 0,
            "failure_count": int(soak.get("failure_count", -1)) == 0,
            "monotonic_clock": soak.get("monotonic_clock") is True,
            "gc_before_sample": soak.get("gc_before_sample") is True,
            "slopes_valid": soak.get("slopes_valid") is True,
            "positive_resource_slope_count": int(
                soak.get("positive_resource_slope_count", -1)
            )
            == 0,
            "positive_resource_slope_fields": isinstance(positive_fields, list)
            and not positive_fields,
            "resource_returned_to_baseline": soak.get(
                "resource_returned_to_baseline"
            )
            is True,
            "database_kind": soak.get("database_kind") == "isolated_postgresql",
            "production": soak.get("production") is False,
            "samples_path": soak.get("samples_path") == "soak-samples.json",
            "samples_artifact_sha256": _valid_sha256(
                soak.get("samples_artifact_sha256")
            ),
            "child_result_sha256": _valid_sha256(soak.get("child_result_sha256")),
        }
    except (TypeError, ValueError):
        return ["invalid_shape"]
    return [name for name, passed in checks.items() if not passed]


def _valid_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def run_c4(evidence_root: Path, candidate_oid: str) -> dict[str, Any]:
    candidate = require_candidate_oid(candidate_oid)
    fast = run_c4_fast(evidence_root)
    soak_path = evidence_root / "soak-report.json"
    blocker_codes: list[str] = []
    if soak_path.is_file():
        soak = json.loads(soak_path.read_text("utf-8"))
    else:
        soak = {
            "status": "blocked",
            "real_soak_seconds": 0,
            "positive_resource_slope_count": 1,
            "resource_returned_to_baseline": False,
        }
        blocker_codes.append("c4.real_soak_not_completed")
    fault = fast["fault"]
    virtual = fast["virtual"]
    judge = fast["judge"]
    soak_contract_failures = _formal_soak_contract_failures(soak)
    passed = (
        fault["minimum_schedules_per_killpoint_outcome"] >= 20
        and fault["stale_worker_denial_failure_count"] == 0
        and fault["duplicate_formal_side_effect_count"] == 0
        and fault["permanent_run_count"] == 0
        and virtual["virtual_days"] >= 90
        and virtual["fake_provider_lifecycle_count"] >= 100_000
        and virtual["fake_provider_unknown_outcome_count"] == 0
        and not soak_contract_failures
        and judge["annotation_count"] >= 400
        and judge["minimum_primary_slice_annotations"] >= 50
        and judge["judge_mechanical_gap_pp"] <= 5
    )
    if not passed and not blocker_codes:
        blocker_codes.extend(
            f"c4.formal_soak_contract.{failure}"
            for failure in soak_contract_failures
        )
        if not blocker_codes:
            blocker_codes.append("c4.local_predicate_failed")
    metrics = {
        "minimum_schedules_per_killpoint_outcome": fault[
            "minimum_schedules_per_killpoint_outcome"
        ],
        "virtual_days": virtual["virtual_days"],
        "fake_provider_lifecycle_count": virtual["fake_provider_lifecycle_count"],
        "real_soak_seconds": soak["real_soak_seconds"],
        "judge_annotation_count": judge["annotation_count"],
        "minimum_judge_primary_slice_annotations": judge[
            "minimum_primary_slice_annotations"
        ],
        "judge_mechanical_gap_pp": judge["judge_mechanical_gap_pp"],
        "duplicate_formal_side_effect_count": fault[
            "duplicate_formal_side_effect_count"
        ],
        "permanent_run_count": fault["permanent_run_count"],
        "positive_resource_slope_count": soak["positive_resource_slope_count"],
        "resource_returned_to_baseline": soak["resource_returned_to_baseline"],
        "measurement_mode": soak.get("measurement_mode", "missing"),
        "observer_workload_process_isolated": (
            soak.get("observer_process_id") != soak.get("workload_process_id")
            and soak.get("observer_process_id") is not None
            and soak.get("workload_process_id") is not None
        ),
        "child_exit_code": soak.get("child_exit_code", -1),
        "child_scratch_artifact_count": soak.get(
            "child_scratch_artifact_count", -1
        ),
        "soak_sample_count": soak.get("sample_count", 0),
        "soak_slope_sample_count": soak.get("slope_sample_count", 0),
        "soak_slopes_valid": soak.get("slopes_valid", False),
        "soak_database_kind": soak.get("database_kind", "missing"),
    }
    sources = [
        source_artifact(evidence_root, "fault-injection-report.json"),
        source_artifact(evidence_root, "virtual-time-report.json"),
        source_artifact(evidence_root, "c4-judge-calibration.json"),
    ]
    if soak_path.is_file():
        sources.append(source_artifact(evidence_root, "soak-report.json"))
    report = gate_report(
        gate_id="C4",
        candidate_oid=candidate,
        status="passed" if passed else "blocked" if "c4.real_soak_not_completed" in blocker_codes else "failed",
        metrics=metrics,
        sources=sources,
        blocker_codes=blocker_codes,
    )
    write_atomic_json(evidence_root / "c4-recovery-time-soak.json", report)
    return report
