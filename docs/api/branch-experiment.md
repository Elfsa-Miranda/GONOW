# Branch experiment contract

Status: local provisional, internal-only Phase 8 contract. No public endpoint or production cohort
is introduced.

## Request

`ResearchRequest` is a closed versioned object with a read-only permission literal. Unknown
versions, write permissions, unknown request kinds, extra fields, Prompt fields, secret-like fields,
and reasoning payloads are rejected. Callers must not tunnel domain commands through metadata.

## Evidence bundle

Each branch returns an `EvidenceBundle` with a stable branch identity, assessment, and canonical
source references. Evidence transport success is not proof of truth. Source conflicts remain visible
through merge and must not be deleted to manufacture agreement.

## Merge decision

`MergeDecision` records the selected assessment, rank/tie outcome, retained evidence references,
and canonical digest. Equivalent permutations produce identical bytes and digest. Consumers must
treat it as a candidate only; it cannot authorize a Domain Command or formal write.

## Budget errors and degradation

The shared Run budget permits at most two logical branches. Each branch permits four physical
attempts, including retries, without lending. Exhaustion fails closed. The safe degradation is the
Phase 7 byte-identical route with zero research calls.

## Experiment result

The pre-registered local synthetic dataset contains 48 observations across four slices. It did not
meet the strict quality, latency, and cost trigger; the decision value is `none`. There is no active
cohort, production claim, or Multi-Agent P12C candidate.
