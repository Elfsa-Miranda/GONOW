# STAR: read-only deterministic E0 parity

## Situation

Before Phase 4, the repository had no executable baseline that ran the same planning cases
through a legacy compatibility path and the new typed single-agent path. Quality, field
differences, latency samples, cost, and frozen-input drift could not be reported together.

## Task

Use the pre-Graph E0 contract without modifying it, produce one structured result per case and
adapter, enforce the frozen scoring thresholds, and distinguish local synthetic evidence from
production validation.

## Action

P04-010 added a schema-validated evaluator with a deterministic compatibility fixture and a
typed fixture that traverses the current six-stage Graph. It hashes the frozen dataset and
scoring files before and after evaluation, creates a latency denominator for every adapter,
records zero provider/tool cost only because none is invoked, and derives a latency-independent
semantic digest for replay comparison.

Reproduce from the repository root:

```powershell
& .\agent-service\.venv\Scripts\python.exe -m pytest -q agent-service/tests/eval/test_e0_parity.py agent-service/tests/unit/harness/test_30_eval_hooks.py
```

## Result

- Before: `0` executable old/new E0 comparisons.
- After: `40/40` cases on each of two adapters (`80` structured results).
- Field differences, threshold failures, critical mismatches, dataset drift, model calls,
  tool calls, audit gaps, PII findings, and formal writes: `0`.
- Frozen dataset SHA-256:
  `8f5bf67e9e17e5db8d9f87bf8ae48d2db314e117f30c22acd31f617627384c4b`.
- Frozen scoring SHA-256:
  `c2870896474b017ce4cdff172f48c9266569e91aa0086a27b222775a8cb52f8b`.

This is a reproducible local testing improvement, not proof of production model quality,
latency, cost, privacy, or user acceptance.
