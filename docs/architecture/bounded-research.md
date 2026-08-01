# Bounded research architecture

Status: local provisional Phase 8 candidate. Formal Product, Eval, Security, Data, and SRE review
is pending. The experiment is disabled by default and has no production activation proof.

## Boundary and data flow

The research path accepts closed, versioned `ResearchRequest` values. The contract permits only
read-only research; a write permission, unknown version, unknown kind, extra field, Prompt field,
secret-like field, or reasoning payload fails closed before branch execution. Each branch returns a
typed `EvidenceBundle`. The deterministic merger returns a typed `MergeDecision`; it never invokes
a model, executes a tool, or writes a domain table.

```text
typed read-only request
          |
          v
 shared per-Run budget -- max two branches, no lending
          |
      +---+---+
      |       |
 branch A   branch B       physical retries debit the same branch cap
      |       |
      +---+---+
          |
 deterministic evidence-preserving merge
          |
 typed decision candidate only
```

## Budget and merge invariants

`SharedBranchBudget` serializes allocation under one lock. The per-Run maximum is two logical
branches. Each branch has an independent cap of four physical attempts, including retries; unused
capacity cannot be borrowed. The concurrency replay admits exactly eight of 24 simultaneous
attempts, four for A and four for B, with zero over-limit or borrowing.

The merger canonicalizes source references and assessments, retains contradictory evidence, and
uses stable rank and tie rules. Equivalent input permutations produce one digest and one decision.
Conflicting sources remain referenced by the output; a tie cannot silently discard a source.

## Router, flags, and compatibility

`ResearchExperimentFlags` defaults to disabled, has no active cohort, and recognizes only offline,
replay, and shadow experiment modes. A kill switch dominates all other configuration. With the
flag off, an active-cohort request, or the kill switch engaged, routing returns the exact Phase 7
bytes and records zero research calls. Phase 8 does not add a public endpoint, process boundary,
migration, active cohort, or domain write.

## Experiment decision

The pre-registered dataset contains 48 synthetic observations, 12 in each of four declared slices.
The best strict quality upper 95% bound was 2.778557 percentage points, below the required strict
greater-than 3 point trigger. Every slice was slower than the local comparator, and the lowest
mean cost ratio was 1.0975, above the comparator ceiling of 1.0. Synthetic evidence cannot authorize
production. The mechanical result is therefore `none`; no P12C Multi-Agent candidate is opened.

The user's preference toward Multi-Agent is retained as decision context. A future decision may be
revisited only with pre-registered production-like or approved production evidence that satisfies
the quality, latency, cost, risk, and sample requirements without weakening thresholds.

## Rollback

Leave the feature disabled or engage the kill switch, then verify Phase 7 byte equality. If package
removal is required, remove only the Phase 8 research contracts, budget, merger, router, synthetic
dataset, and evidence. Phase 7 validation and repair remain intact; there is no schema or production
data rollback in this phase.
