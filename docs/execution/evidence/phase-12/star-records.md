# Phase 12 cumulative STAR records

## Situation and task

The cumulative close preserves three independently preregistered problems: unsafe direct Basic Info
writes, ungoverned provider cost routing, and absence of explicit typed Memory. For Memory, reusing chat history or
model inference would have created hidden profiling, ambiguous consent, cross-purpose access,
conflicting facts, and backup resurrection risk. The selected task was to add only Structured Memory
while preserving Single-Agent architecture and existing behavior when disabled.

## Actions and evidence

| Area | Evidence | SHA-256 |
|---|---|---|
| P12D complete regression | `../phase-12d/P12D-990/regression-summary.json` | `f10fd29026bfdb6f7afadb4406c6c3c757387924e371ae255be2eeed04500914` |
| P12D test-only drift revalidation | `../phase-12d/P12D-990/legacy-equivalence-revalidation.json` | `63844dadbde2cff18f8aa84cf9505fae73966442a783c5357343d17175129e89` |
| P12B complete regression | `../phase-12b/P12B-990/regression-summary.json` | `8c2d2f78efae1a29a4081d90311d4774638d52d59c70e0395272c53c69023ae9` |
| P12B local no-ff merge and 98/98 smoke | `../phase-12b/merge.json` | `8cbc38b3a99e949158d53a277d8dda2e489df127ee31eb3003e51218a874060e` |
| frozen types, consent, purpose, retention, provenance | `../phase-12a/P12A-010/scope-contract.json` | `6951b2cc0189755aff7909d713e04fe1914c6c0e7df973411a7112a8c5560673` |
| seven FORCE RLS tables and principal isolation | `../phase-12a/P12A-020/realpg-verification.json` | `98c04c982556a061519028655ca8c901689883c8c39599c253e83c89314f5daa` |
| confirmation, authorization, CAS, idempotency, outbox | `../phase-12a/P12A-030/command-contract-results.json` | `ba1ea5feade8194a3f89821ff03bd0c60118442deed5ac5ef5532f9de82ffba8` |
| conflict and injection defenses | `../phase-12a/P12A-040/injection-and-conflict-results.json` | `e5627df6ffc3e58c6fc523ddf7fe224ab76ec1cb662aa5815dd4743bf2d2f1dd` |
| deletion, export, and tombstone-first restore | `../phase-12a/P12A-050/deletion-export-restore-results.json` | `d0d40e3a7a7a148b3852f1c091e4fae64648213e066182750bebd72470680acb` |
| controlled lifecycle measurement | `../phase-12a/P12A-060/star-evaluation.json` | `cfafef01b3f4daac4a3cf208dc09a7621e00c9b03fda15347453f39d3af45c6f` |
| complete regression and retained failures | `../phase-12a/P12A-990/regression-summary.json` | `eab115c0058ea31b736db3c41d943239fac0d2e757943c16ba23cef354ff0d2a` |
| local acceptance boundary | `../phase-12a/acceptance.md` | `94cf2fe213ff5e536f557e91742a035e1597ffe61d0c88f675f95ff0f41caf18` |

## Result

Capability existence is proven locally for P12D, P12B, and P12A; this does not make their separate
test denominators additive or comparable. For P12A, all four types and the complete authorized lifecycle are
implemented, default off, and reachable only through the Single-Agent port. In the frozen local
fixture, authorized lifecycle success was 12/12; four typed eligible fixtures were accepted and eight
deny/reject fixtures stayed denied. Affected tests were 65/65.

The main acceptance result was 15/15 CI suites, 895 unit, 255 contract, 124 Flutter, and 53
RealPG/fault tests, with failures/skips/xfails all zero. Diagnostic RealPG checks proved seven FORCE
RLS tables, one authorized row, zero wrong-principal rows, and denied Worker formal mutation.

Safety redlines are non-compensable and remained zero: cross-tenant materialization, negative-consent
bypass, injection-executed action, deletion propagation failure, and backup resurrection. Model API
calls and production writes were zero.

P12D's 10,000/10,000 paired controlled results prove only local mechanics. P12B's synthetic replay
and qualified DeepSeek strata do not prove relative live savings because the paired Gemini baseline
has zero qualified successes. This is not a production-improvement claim. Production schema/RLS, backup replay, real consent,
traffic, quality, latency, cost, and user outcome remain unknown/pending.
