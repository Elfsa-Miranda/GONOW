# C2 live route-budget repair

## Scope and evidence boundary

- Base candidate: `2afcaac54b36dd1ccb3e85882025fdb17b878185`
- Repair branch: `codex/repair-phase10-c2-route-budget`
- Affected shard: P10-009 C2 live provider only
- Production allocation/write count: `0`
- Credential, prompt, response, reasoning, secret, and PII bodies retained: `0`

This record describes a local repair candidate. It is not a C2 pass receipt and does not replace the mandatory `200` successful live calls per fixed route.

## Reproduction

The `2026-08-03` fresh live attempt issued `41` provider requests before both three-429 route circuits opened. The economic route completed `0/28` pre-quota responses and classified all `28` as `llm.incomplete_output`; the capability route completed `7/7` pre-quota responses. The failed candidate receipt is preserved separately as `BLK-P10-009-gemini-live-quota-2afcaac.md` in the certification evidence worktree and is bound to SHA-256 `bb1faddff2e3ed7a0d82763e7847fbcc32a0488e5812472145a939de77ec66c8`.

## Root cause and impact surface

The C2 micro-contract used one global `64`-token output limit for both certified models. That assumption is incompatible with the observed route-asymmetric behavior. Gemini 3 low thinking is model-managed and cannot be guaranteed fully disabled, while thinking tokens are output-priced and included in usage accounting. A fixed global cap therefore coupled the cheaper economic model's thinking behavior to the capability model's cost envelope.

The previous diagnostic path also mapped every non-`STOP` result to `llm.incomplete_output` and discarded safe scalar response metadata. It correctly retained no provider body, but it could not distinguish `MAX_TOKENS` from a safety or other non-`STOP` reason after the fact. The old receipt is consequently evidence of repeated non-completion, not proof of one exact finish reason.

The production itinerary processor requests `1,024–8,192` output tokens and is not constrained by the C2 micro-contract's `64`-token limit. The direct impact is limited to the live certification configuration, projected-cost calculation, route receipts, and sanitized failure diagnosis.

Official behavior references reviewed for this repair:

- <https://ai.google.dev/gemini-api/docs/generate-content/thinking>
- <https://ai.google.dev/api/generate-content>
- <https://ai.google.dev/gemini-api/docs/pricing>

## Reversible repair

The frozen configuration schema is advanced from `1.0` to `1.1` and replaces the global output limit with model-bound route limits:

| Route | Model | Input maximum | Output maximum | Worst-case cost |
|---|---|---:|---:|---:|
| economic | `gemini-3.1-flash-lite` | 64 | 384 | USD 0.1184 |
| capability | `gemini-3.6-flash` | 64 | 64 | USD 0.1152 |
| total | fixed pair | — | — | USD 0.2336 |

The total remains below the frozen USD `0.25` pre-call cap without changing provider, model IDs, `20 RPM`, `200` calls per route, or the three-consecutive-429 circuit. Strict parsing rejects Boolean-as-integer limits, route/model swaps, provider drift, call-count/RPM drift, cap increases, unknown fields, and any configuration whose projected maximum exceeds the cap.

A test-only observing client now retains only the HTTP status, an allowlisted finish reason (or the constant `UNRECOGNIZED`), and non-negative token counts. It never records arbitrary finish text, provider error data, prompt, response content, reasoning content, or credentials. C2 success still requires the production `GeminiModelAdapter` to return typed `{"ok": true}` with `STOP` and valid usage.

Rollback is a normal revert of this certification-only commit. No database, production data, allocation, billing, credential, provider, or model state is changed.

## Affected regression

Pre-commit verification on the repair worktree:

- `agent-service/tests/certification/test_compressed_release_harness.py`: `22 passed`;
- `Invoke-PersonalReleaseCertification.Tests.ps1`: positive fixture passed, `10` negative fixtures passed, C1–C5 order intact, minimum soak `14,400s`, production writes `0`;
- `git diff --check`: passed.

The live provider was not invoked during these regressions. After commit, the new candidate must regenerate candidate-bound local certification evidence. The next live attempt remains limited to one attempt after `16:15 Asia/Shanghai` on a later day with available free quota.
