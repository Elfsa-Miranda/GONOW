# Validation result consumer contract

Status: local provisional Phase 1 API contract. This document explains how consumers use
`contracts/validation-semantics-v1.schema.json`; it does not publish an HTTP endpoint.

## Input and output

A validator consumes a model-produced Candidate plus version/provenance references. Its result is
schema-versioned and contains an overall classification, typed findings, Candidate-import policy,
and fallback policy. Finding paths use JSON Pointer. User content, Prompt/response bodies,
reasoning, secrets, and PII are not valid diagnostic fields.

## Consumer rules

- Accept only the supported schema major. An unknown major is `hard` with raw-input fallback.
- Calculate overall precedence as `hard > warning > unverified > verified`; retain every finding.
- Require visible confirmation for every non-verified result. A verified Candidate is still a
  draft and still needs explicit confirmation before a later Domain Command evaluation.
- Require `candidate_import.domain_write_allowed=false` and
  `fallback.domain_write_allowed=false` for every valid result.
- Preserve the original Candidate for parser, normalization, network, evidence, and cancellation
  failures. Never substitute a fabricated fact.

## Compatibility and rollback

The Release A Flutter broad-map path may be adapted into this result shape without changing old
chat/import/Auth/fallback outcomes. The future seam is defined by
`contracts/flutter-agent-boundary-v1.yaml` and remains off by default. Roll back by disabling
`agent_itinerary_planning_v1`; do not delete compatibility adapters or re-enable client-direct
model calls.

## Verification

The canonical synthetic corpus is
`test/fixtures/validation/validation_semantics_cases.json`. Run
`flutter test test/validation_semantics_test.dart` from the repository root. Expected local result:
8 fixtures loaded, 3 tests passed, 0 failed, 0 skipped, and 0 xfailed.
