"""Authorized, generation-fenced behavior, route, and cohort kill switches."""

from __future__ import annotations

import json
from dataclasses import dataclass, replace
from enum import StrEnum
from hashlib import sha256

from app.auth.context import AuthorizationPolicy, RequestContext
from app.runtime.feature_flags import (
    FeatureFlagAuditReceipt,
    FeatureFlagControlPlane,
    RuntimeFeatureSnapshot,
    SAFE_NAME_RE,
    _pseudonymous_ref,
)


FEATURE_FLAG_WRITE = "feature_flags.write"


class KillScope(StrEnum):
    BEHAVIOR = "behavior"
    ROUTE = "route"
    COHORT = "cohort"


@dataclass(frozen=True, slots=True)
class KillSwitchCommand:
    scope: KillScope
    enabled: bool
    cohort: str | None = None

    def __post_init__(self) -> None:
        cohort_valid = self.cohort is not None and SAFE_NAME_RE.fullmatch(self.cohort) is not None
        if (self.scope is KillScope.COHORT) != cohort_valid:
            raise ValueError("kill_switch.invalid_command")


class KillSwitchController:
    """Apply only typed, authorized mutations to the feature-flag control plane."""

    def __init__(
        self,
        control_plane: FeatureFlagControlPlane,
        *,
        authorization: AuthorizationPolicy | None = None,
    ) -> None:
        self._control_plane = control_plane
        self._authorization = authorization or AuthorizationPolicy()

    def apply(
        self,
        context: RequestContext,
        command: KillSwitchCommand,
        *,
        expected_generation: int,
        approval_valid: bool,
    ) -> RuntimeFeatureSnapshot:
        if not isinstance(command, KillSwitchCommand):
            raise TypeError("kill_switch.typed_command_required")

        # Check stale operators before authorization, then repeat the CAS in the
        # atomic commit so concurrent authorized writers cannot both succeed.
        current = self._control_plane.assert_generation(expected_generation)
        self._authorization.authorize(
            context,
            action=FEATURE_FLAG_WRITE,
            resource_tenant_id=current.tenant_id,
            requested_fields={command.scope.value},
            allowed_fields={scope.value for scope in KillScope},
            approval_valid=approval_valid,
        )
        candidate = self._candidate(current, command)
        receipt = self._receipt(context, current, candidate, command)
        return self._control_plane.compare_and_swap(
            expected_generation=expected_generation,
            candidate=candidate,
            audit_receipt=receipt,
        )

    @staticmethod
    def _candidate(
        current: RuntimeFeatureSnapshot,
        command: KillSwitchCommand,
    ) -> RuntimeFeatureSnapshot:
        changes: dict[str, object] = {"generation": current.generation + 1}
        if command.scope is KillScope.BEHAVIOR:
            changes["behavior_enabled"] = command.enabled
        elif command.scope is KillScope.ROUTE:
            changes["route_enabled"] = command.enabled
        else:
            cohorts = set(current.enabled_cohorts)
            if command.enabled:
                cohorts.add(command.cohort or "")
            else:
                cohorts.discard(command.cohort or "")
            changes["enabled_cohorts"] = frozenset(cohorts)
        return replace(current, **changes)

    @staticmethod
    def _receipt(
        context: RequestContext,
        current: RuntimeFeatureSnapshot,
        candidate: RuntimeFeatureSnapshot,
        command: KillSwitchCommand,
    ) -> FeatureFlagAuditReceipt:
        actor_ref = _pseudonymous_ref("actor", context.principal_id)
        tenant_ref = _pseudonymous_ref("tenant", context.tenant_id)
        content = {
            "actor_ref": actor_ref,
            "cohort": command.cohort,
            "enabled": command.enabled,
            "generation": candidate.generation,
            "previous_generation": current.generation,
            "scope": command.scope.value,
            "state_sha256": candidate.state_sha256(),
            "tenant_ref": tenant_ref,
        }
        receipt_id = sha256(
            json.dumps(content, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        return FeatureFlagAuditReceipt(receipt_id=receipt_id, **content)


class KillSwitch:
    """Small typed facade used by drills and operator adapters."""

    def __init__(self, controller: KillSwitchController) -> None:
        self._controller = controller

    def cut_behavior(
        self, context: RequestContext, *, expected_generation: int, approval_valid: bool
    ) -> RuntimeFeatureSnapshot:
        return self._apply(
            context,
            KillSwitchCommand(KillScope.BEHAVIOR, enabled=False),
            expected_generation,
            approval_valid,
        )

    def cut_route(
        self, context: RequestContext, *, expected_generation: int, approval_valid: bool
    ) -> RuntimeFeatureSnapshot:
        return self._apply(
            context,
            KillSwitchCommand(KillScope.ROUTE, enabled=False),
            expected_generation,
            approval_valid,
        )

    def cut_cohort(
        self,
        context: RequestContext,
        cohort: str,
        *,
        expected_generation: int,
        approval_valid: bool,
    ) -> RuntimeFeatureSnapshot:
        return self._apply(
            context,
            KillSwitchCommand(KillScope.COHORT, enabled=False, cohort=cohort),
            expected_generation,
            approval_valid,
        )

    def restore_behavior(
        self, context: RequestContext, *, expected_generation: int, approval_valid: bool
    ) -> RuntimeFeatureSnapshot:
        return self._apply(
            context,
            KillSwitchCommand(KillScope.BEHAVIOR, enabled=True),
            expected_generation,
            approval_valid,
        )

    def _apply(
        self,
        context: RequestContext,
        command: KillSwitchCommand,
        expected_generation: int,
        approval_valid: bool,
    ) -> RuntimeFeatureSnapshot:
        return self._controller.apply(
            context,
            command,
            expected_generation=expected_generation,
            approval_valid=approval_valid,
        )
