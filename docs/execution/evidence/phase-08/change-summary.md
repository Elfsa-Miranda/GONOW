# Phase 8 change summary

Status: local provisional; independent review and formal acceptance pending.

Before Phase 8 there was no closed research-branch contract, shared per-Run branch budget,
deterministic evidence merger, default-off experiment router, pre-registered A/B fixture, or
mechanical architecture decision. After this candidate:

- read-only research requests and evidence/decision objects are strict and versioned;
- writes, unknown versions, Prompt/secret-like fields, and extra payload fields fail closed;
- a per-Run shared lock allows two branches and four physical attempts per branch without lending;
- 24 concurrent attempts admit exactly eight, split four/four, with zero over-limit;
- the merger has one digest across input permutations and retains conflicting source references;
- flag-off, active-cohort, and kill-switch paths make zero research calls and return Phase 7 bytes;
- the pre-registered synthetic experiment has 48 observations, 12 per slice, with complete
  exclusion and confidence accounting;
- the measured trigger result is `none`, so no Multi-Agent P12C package is opened.

The user's preference toward Multi-Agent was recorded and evaluated, but it did not override the
strict data gate. There is no new endpoint, process, migration, production write, active cohort,
remote push, accepted merge, or production claim.
