# Phase 12 STAR records

Phase 12 keeps capability existence, measured behavior, and governance acceptance separate. This
cycle selects P12B; P12A/P12C are dormant and the prior P12D package remains historical evidence.

## Indexed P12B records

| Record | SHA-256 | Result | Evidence boundary |
|---|---|---|---|
| `../phase-12b/P12B-060/live-calibration.json` | `71879579baffb66a41a79e295278da3aa5b7d8ddfda23622d9db1ec115676cb2` | v1: both arms had zero qualified success | Immutable negative evidence; exact DeepSeek rule-code detail was not recorded by the v1 recorder and is not invented later |
| `../phase-12b/P12B-060/deepseek-quality-final.json` | `67e310e198157bc7e6c03c5670c4f6b4b3dfac3d2aafa3d2dc92b9810141a5a6` | latest DeepSeek strata 10/10 qualified; Schema/business/provider/fallback/redline failures 0; p95 8,400 ms | Bounded local live calibration; response bodies and keys not retained |
| `../phase-12b/P12B-060/star-evaluation-final.json` | `d337437c5435b55120f44fb33eafb336de3d16afe9c31ca19bafce5a794587fe` | all P12B live: 30 calls, 23,108 tokens, 4,555 micro-USD / CNY 0.03644 | Gemini live baseline success is zero; relative benefit and paired non-inferiority remain undefined |
| `../phase-12b/P12B-050/stratified-replay-results.json` | `e736f63697b71d30ba3cb725e053b55531da5072668a186e0934796ec6c38e32` | fake replay: baseline and candidate 10/10; synthetic cost ratio 0.135149 | Mechanics and frozen-price diagnostic only; not a live or production benefit claim |
| `../phase-12b/P12B-060/rollback-drill.json` | `72d663e3c904580d326c14e261b56f4cc43d999c71d66752e29eb977e60cd8bc` | allocation zero, router bypass, prior digest restored, receipts retained | Local rollback proof only |
| `../phase-12b/P12B-060/BLK-P12B-060-gemini-live-availability.md` | `2c9a8824c195babdcb0b84f4aa8e32343a64359ea1312fa406e74f10a20c2ee8` | Gemini request-invalid repair proved offline; later rate-limit/5xx prevented a non-zero live baseline | External availability blocker; no repeated calls for a green result |

## Outcome boundary

- Capability existence: one default-off deterministic Cost Router inside the existing Single-Agent
  Worker model boundary; no public contract, database schema, process, or Multi-Agent addition.
- DeepSeek behavior: the latest frozen ten-scenario set is fully quality-qualified and the complete
  output/metering/fallback/rollback chain is mechanically covered.
- Comparative benefit: not established. Gemini has zero qualified live successes, so live
  cost/success ratio and quality non-inferiority cannot be computed.
- Decision: `candidate_allocation=0`, `positive_benefit_claim=false`, formal acceptance pending.
- Safety redlines are non-compensable: tenant/secret/PII exposure, invalid Schema/business shape,
  unapproved region/provider, recursive fallback, unmetered attempt, or production write fails
  regardless of cost.
- Historical P12D controlled evidence remains valid within its own local scope, but it is not the
  selected candidate or an allocation authority in this cycle.
