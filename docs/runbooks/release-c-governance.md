# Release C governance and rollback runbook

## Current safe state

`formal_selection_status=local_provisional_selected`, `selected_candidate=12D`, and
`selected_count=1`. The additive Domain Command package exists locally for exactly the itinerary
Basic Info write entry. Production allocation and production writes remain zero; formal owner review,
remote integration, deployment, and Release C acceptance remain pending. 12A, 12B, and 12C are not
part of this cycle, and no Multi-Agent framework exists.

## First checks

1. Verify the worktree branch and clean status, then bind the candidate to a full Git object ID.
2. Verify the selected write entry is exactly
   `flutter:ItineraryProvider.updateItineraryBasicInfo:user_itineraries`.
3. Verify `gonow_itinerary_basic_info_command_v1` is off by default and the command kill switch is
   active by default.
4. Verify migration, FORCE RLS, command handler, receipt lookup, failure matrix, controlled-profile,
   Flutter routing, rollback, and P12D-990 evidence hashes.
5. Verify duplicate write, unauthorized/cross-tenant write, mutation/outbox divergence, ambiguous
   committed outcome, and data-loss counts are all zero. Redlines never average into STAR.
6. Verify production schema equivalence, flow distribution, and incident-rate claims remain unknown
   or measurement pending.
7. Verify unselected Phase 12 candidates have no runtime, allocation, or implementation in this cycle.

## Formal selection procedure

Run the repository-owned TaskGate modes in task-card order from the dedicated clean governance
worktree. Do not edit the generated evidence to make a result pass. If the dependency gate returns a
formal-selection or stable-Release-B reason code, preserve that receipt and continue only unrelated
local work until the immutable inputs exist.

The selected design must compare at least two alternatives and no-change across security, data,
compatibility, cost, and rollback. The design then becomes atomic implementation tasks through an
approved plan change; the design task itself has `implementation_commit_count=0`. A second capability
is never appended to the same cycle.

## Enable, disable, and degrade

There is no production enable command in this local provisional package. In an authorized isolated
environment, enable only the named Flutter flag after applying the additive migration, configuring
server authorization, mounting the internal route through approved composition, and verifying the
same receipt/outbox/CAS tests. The internal route is unmounted by default.

| Candidate | Enable only after | Disable / first rollback action | Degraded behavior |
|---|---|---|---|
| 12A Memory | selected ADR, privacy/data approval, CT-009/015, deletion/restore drill | allocation zero; disable reads/proposals; retain tombstones/audit | Release B single Agent without Memory |
| 12B cost router | four-week calibrated evidence, certified routes, quality/cost/fallback gates | bypass router; restore previous policy digest; retain budget ledger | current certified route or existing fail-closed policy |
| 12C Multi-Agent | fresh positive XOR cycle and separately approved package | allocation zero; return to one graph; retain experiment evidence | Release B single Agent |
| 12D Domain Command | formal owner approval, real schema/RLS inventory, rollout/monitoring authority, all redlines zero | turn the named flag off or activate its kill switch for new intents; retain receipts/outbox | legacy Basic Info writer; unknown outcomes still use receipt lookup |

Global rollback order is: stop new allocation, pin the last known-good behavior/route/alias, preserve
evidence and compatible data, replay the Release B equivalence suite, then diagnose. Never roll back
by deleting audit rows, restoring revoked secrets, resurrecting deleted data, force-pushing, or
writing directly to production.

## Failure handling

Use one root-cause loop: reproduce once from a clean state; determine the failing input, environment,
dependency, and impact surface; apply the smallest reversible fix; run the minimum affected check and
then the affected regression set. A second occurrence or plan change requires a blocker record with
the complete hypothesis, excluded paths, repair, rollback, and recovery condition. Do not repeat an
unchanged gate without a new distinguishing signal.

Missing independent review blocks only formal acceptance, production allocation, remote merge/push,
and deployment. It does not invalidate completed local code, fixtures, RealPG fault evidence, static
checks, or rollback work.

## Merge and remote contract

Phase and repair commits land through a history-preserving integration on
`codex/gonow-agent-landing` after the applicable gate and acceptance contract is met.
Never push a Phase branch directly to `main`, and never use this archive to claim that Release C was accepted.
The remote landing branch must match its expected base before merge; drift requires an explicit sync
task and affected regression, not an ad-hoc conflict resolution during merge.

## Audit retention

Retain the Release B evidence manifest, selection analysis, decision/approval references, XOR
reservation, gate results, threat review, rollback evidence, candidate/merge OIDs, and artifact
hashes. Evidence contains hashes and redacted results only; it must not contain secrets, personal
data, full prompts/responses, or hidden reasoning.
