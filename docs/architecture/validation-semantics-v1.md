# GoNow validation and fallback semantics v1

Status: local provisional contract candidate. Formal Product and Security approval is pending and must bind the same immutable contract SHA-256 before this contract can be accepted or used to authorize a release.

Canonical schema: `contracts/validation-semantics-v1.schema.json`.

## Invariants

1. Validation consumes a model-produced Candidate; it never consumes a formal domain row as permission to overwrite that row.
2. Every result is exactly one of `hard`, `warning`, `unverified`, or `verified`. Individual findings retain their own class; overall precedence is `hard > warning > unverified > verified`.
3. Candidate import is always available, including `hard`. “Importable” means preserving content as a visible Candidate/draft. It never means writing a formal itinerary, diary, membership, profile, or event.
4. `candidate_import.domain_write_allowed` and `fallback.domain_write_allowed` are always `false`. A later, explicit user confirmation and an authorized Domain Command with CAS are separate prerequisites.
5. Every non-verified result requires user confirmation and a visible classification. The UI must not relabel `unverified` as verified or hide a `hard` finding.
6. Fallback always preserves user input. It cannot silently discard the original prompt/candidate, fabricate external evidence, or claim a cloud write succeeded.
7. Findings contain codes, JSON Pointer paths, localization keys, and references—not secret, PII, prompt, response, or reasoning bodies.

## Classification contract

| Class | Meaning | Candidate import | Required fallback | Formal write effect |
|---|---|---|---|---|
| `hard` | The normalized representation is structurally unsafe or cannot satisfy a non-negotiable contract. | Import raw content as `raw_candidate_draft` with a visible hard label and confirmation. | `raw_input_draft`; preserve original bytes/content and findings. | None; must be repaired and later confirmed through a Domain Command. |
| `warning` | The candidate is structurally usable but has a recoverable quality, consistency, or product warning. | Import a `normalized_candidate_draft` after visible confirmation. | `normalized_candidate`; retain warnings. | None; confirmation alone still does not bypass authorization/CAS. |
| `unverified` | A factual claim lacks current evidence, source, time, permission, or reproducible production proof. | Import the `original_candidate_draft` with an unverified label. | `original_candidate`; do not “correct” unknown facts by guessing. | None; collect evidence or let the user edit before Domain Command evaluation. |
| `verified` | The validator found no hard, warning, or unverified finding under the bound Behavior Package. | Import a `normalized_candidate_draft`; explicit confirmation remains required. | `normalized_candidate` remains available for deterministic recovery. | None; the validation result is not an authorization token. |

When several findings exist, overall precedence is deterministic. Lower-precedence findings remain in the array and must still be displayed or made inspectable.

## Fallback and failure behavior

- Validation/parser failure is fail-closed for formal writes and fail-open only for preserving a raw local Candidate draft.
- A schema version mismatch produces a `hard` result with raw-input fallback; the consumer must not guess a compatible shape.
- Network/evidence lookup failure produces `unverified`, not `verified` and not a fabricated default fact.
- A normalization failure preserves the original candidate. Partial normalized output may be retained only as a separate, clearly labeled draft.
- Retry is bounded by the calling workflow. Repeated success must not erase the record of earlier findings without a new validation result ID and provenance.
- Cancellation returns control without a formal write. A future runtime must persist cancel intent; this Phase 1 contract does not claim that capability exists today.

## Compatibility mapping

The Release A Flutter path currently accepts broad maps and has local/cloud fallback behavior. Adapters may translate its result into this Candidate contract without changing current UI outcomes. Direct legacy model paths with empty compatibility tombstones remain disabled. This contract does not authorize restoring client provider keys or direct model endpoints.

## Required positive and negative cases

The following IDs are normative seeds for TASK-P01-003 fixtures. “Negative” means an invalid result or consumer behavior that the schema/test must reject.

| Case ID | Class | Input/behavior | `expected_result` |
|---|---|---|---|
| `VS-HARD-POS-001` | hard positive | Missing required itinerary day shape creates a hard finding; import uses raw draft fallback. | schema valid; `allowed=true`; `domain_write_allowed=false`; hard finding retained |
| `VS-HARD-NEG-001` | hard negative | Hard result claims normalized mode or `domain_write_allowed=true`. | schema invalid; no domain mutation |
| `VS-WARNING-POS-001` | warning positive | Recoverable schedule overlap creates a warning and normalized draft. | schema valid; confirmation required; warning retained |
| `VS-WARNING-NEG-001` | warning negative | Warning result has no warning finding or hides confirmation. | schema invalid; no domain mutation |
| `VS-UNVERIFIED-POS-001` | unverified positive | Venue opening time has no current source reference. | schema valid; original candidate preserved and visibly unverified |
| `VS-UNVERIFIED-NEG-001` | unverified negative | Missing evidence is labeled verified or replaced by a guessed fact. | contract violation; no domain mutation |
| `VS-VERIFIED-POS-001` | verified positive | Bound validator reports no findings. | schema valid with empty findings; still a Candidate draft |
| `VS-FALLBACK-NEG-001` | cross-cutting negative | Any fallback drops user input or enables formal write. | schema invalid; original Candidate remains recoverable |

## Conflict decisions

- Safety wins over normalization: any hard finding forces raw-input fallback.
- Explicit warning wins over unverified for the overall label, while unverified findings remain present.
- Evidence absence is never converted into false certainty.
- Current product compatibility wins only within the Candidate/draft boundary; it cannot weaken authentication, tenant isolation, secret handling, CAS, or explicit confirmation.

## Approval boundary

Local implementation and fixtures may proceed against this exact schema/document candidate. Formal acceptance requires independent Product and Security decisions bound to the same candidate HEAD and schema SHA-256. The implementation agent cannot create those decisions. Until supplied, formal approval status is `pending_external`, and push, merge, production write, deployment, and Release acceptance remain prohibited.
