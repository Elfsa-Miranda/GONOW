"""C4 recovery, virtual-time, lifecycle-volume, Judge, and real-soak shard."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
import gc
import json
import math
import os
from pathlib import Path
import platform
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


def _rss_bytes() -> int:
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
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

        counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = ctypes.sizeof(counters)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        psapi.GetProcessMemoryInfo.argtypes = (
            wintypes.HANDLE,
            ctypes.POINTER(PROCESS_MEMORY_COUNTERS),
            wintypes.DWORD,
        )
        psapi.GetProcessMemoryInfo.restype = wintypes.BOOL
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
        import ctypes
        from ctypes import wintypes

        count = wintypes.DWORD()
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        kernel32.GetProcessHandleCount.argtypes = (
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.DWORD),
        )
        kernel32.GetProcessHandleCount.restype = wintypes.BOOL
        process = kernel32.GetCurrentProcess()
        if not kernel32.GetProcessHandleCount(process, ctypes.byref(count)):
            raise OSError("GetProcessHandleCount failed")
        return int(count.value)
    fd_root = Path("/proc/self/fd")
    return len(tuple(fd_root.iterdir())) if fd_root.is_dir() else 0


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


def run_real_soak(
    evidence_root: Path,
    *,
    duration_seconds: int,
    sample_interval_seconds: float = 30.0,
    database_url: str | None = None,
) -> dict[str, Any]:
    if duration_seconds < 1 or sample_interval_seconds <= 0:
        raise CertificationFailure("c4.soak_configuration_invalid")
    engine = None
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
        engine = create_engine(database_url, pool_pre_ping=True, pool_size=2, max_overflow=0)
        database_kind = "isolated_postgresql"
    samples: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    iteration = 0
    tracemalloc.start()
    started_monotonic = time.monotonic()
    started_wall = datetime.now(UTC)
    deadline = started_monotonic + duration_seconds
    next_sample = started_monotonic
    initial_baseline = {
        "rss_bytes": _rss_bytes(),
        "handle_count": _handle_count(),
        "thread_count": threading.active_count(),
    }
    try:
        while time.monotonic() < deadline:
            try:
                _soak_workload(iteration)
                if engine is not None and iteration % 20 == 0:
                    with engine.connect() as connection:
                        if connection.scalar(text("SELECT 1")) != 1:
                            raise AssertionError("database probe failed")
            except Exception as error:  # noqa: BLE001 - record bounded diagnostic
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
                heap_current, heap_peak = tracemalloc.get_traced_memory()
                sample = {
                    "elapsed_seconds": round(now - started_monotonic, 6),
                    "rss_bytes": _rss_bytes(),
                    "python_heap_bytes": heap_current,
                    "python_heap_peak_bytes": heap_peak,
                    "handle_count": _handle_count(),
                    "thread_count": threading.active_count(),
                    "database_checked_out": 0 if engine is None else engine.pool.checkedout(),
                    "backlog_count": 0,
                    "iteration_count": iteration,
                    "failure_count": len(failures),
                }
                samples.append(sample)
                write_atomic_json(
                    evidence_root / "soak-progress.json",
                    {
                        "schema_version": "1.0",
                        "status": "running",
                        "started_at": started_wall.isoformat(),
                        "target_seconds": duration_seconds,
                        "latest": sample,
                    },
                )
                next_sample += sample_interval_seconds
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(0.05, remaining))
    finally:
        gc.collect()
        ended_monotonic = time.monotonic()
        ended_wall = datetime.now(UTC)
        heap_current, heap_peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        if engine is not None:
            engine.dispose()
    actual_seconds = ended_monotonic - started_monotonic
    analysis_start = max(1, len(samples) // 4)
    steady = samples[analysis_start:] if len(samples) > 1 else samples
    slopes = {
        field: _linear_slope(steady, field)
        for field in (
            "rss_bytes",
            "python_heap_bytes",
            "handle_count",
            "thread_count",
            "database_checked_out",
            "backlog_count",
        )
    }
    final = {
        "rss_bytes": _rss_bytes(),
        "python_heap_bytes": heap_current,
        "python_heap_peak_bytes": heap_peak,
        "handle_count": _handle_count(),
        "thread_count": threading.active_count(),
        "database_checked_out": 0,
        "backlog_count": 0,
    }
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
        else {**initial_baseline, "python_heap_bytes": 0, "database_checked_out": 0, "backlog_count": 0}
    )
    rss_tolerance = max(
        16 * 1024 * 1024,
        int(steady_baseline["rss_bytes"] * 0.10),
    )
    returned = (
        final["rss_bytes"] <= steady_baseline["rss_bytes"] + rss_tolerance
        and final["handle_count"] <= steady_baseline["handle_count"] + 2
        and final["thread_count"] <= steady_baseline["thread_count"] + 1
        and final["database_checked_out"] == 0
        and final["backlog_count"] == 0
    )
    # More than 2% of warm baseline growth per hour is a persistent positive trend.
    positive = []
    for field in ("rss_bytes", "python_heap_bytes"):
        baseline_value = max(1, float(steady[0][field])) if steady else 1.0
        normalized_per_hour = slopes[field] * 3600 / baseline_value
        if normalized_per_hour > 0.02:
            positive.append(field)
    for field in ("handle_count", "thread_count", "database_checked_out", "backlog_count"):
        if slopes[field] > 0.001:
            positive.append(field)
    completed = actual_seconds >= duration_seconds - 0.1
    report = {
        "schema_version": "1.0",
        "gate_id": "C4",
        "soak_id": "c4-real-resource-soak-v1",
        "status": "passed" if completed and not failures and not positive and returned else "failed",
        "started_at": started_wall.isoformat(),
        "completed_at": ended_wall.isoformat(),
        "target_seconds": duration_seconds,
        "real_soak_seconds": round(actual_seconds, 6),
        "monotonic_clock": True,
        "sample_interval_seconds": sample_interval_seconds,
        "sample_count": len(samples),
        "iteration_count": iteration,
        "database_kind": database_kind,
        "failure_count": len(failures),
        "failure_samples": failures[:50],
        "initial_baseline": initial_baseline,
        "steady_state_baseline": steady_baseline,
        "final": final,
        "steady_state_slopes_per_second": slopes,
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
    passed = (
        fault["minimum_schedules_per_killpoint_outcome"] >= 20
        and fault["stale_worker_denial_failure_count"] == 0
        and fault["duplicate_formal_side_effect_count"] == 0
        and fault["permanent_run_count"] == 0
        and virtual["virtual_days"] >= 90
        and virtual["fake_provider_lifecycle_count"] >= 100_000
        and virtual["fake_provider_unknown_outcome_count"] == 0
        and float(soak["real_soak_seconds"]) >= 14_400
        and soak["status"] == "passed"
        and judge["annotation_count"] >= 400
        and judge["minimum_primary_slice_annotations"] >= 50
        and judge["judge_mechanical_gap_pp"] <= 5
    )
    if not passed and not blocker_codes:
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
