# TASK-P04-010 root-cause and repair record

Execution mode is `local_provisional`; Product, Eval, Privacy, and Security approval remains `pending_external`. This record describes offline synthetic evidence only and authorizes no remote, production, merge, or acceptance action.

## Reproduction 1: locked interpreter lacked the test runner

- Reproduction: the plan-literal BOOT-005 Python executable returned `No module named pytest` before collecting any P04-010 test.
- Root cause and impact: the locked base interpreter exists but its isolated environment does not contain the repository dev dependency set. Only the P04-010 direct-test action was affected; source, E0 bytes, production data, and external systems were untouched.
- Reversible repair: used the existing `agent-service/.venv` selected by the established Phase 2–4 CI runner. No lockfile, toolchain receipt, package, or external environment was modified. The difference is explicit: this proves the repository project environment, not that the BOOT-005 base venv has been hydrated.
- Regression: the direct P04-010 collection subsequently ran and exposed implementation-level contract failures, then passed 14/14 after the repairs below. Full Agent CI is recorded separately under `ci-reports/`.

## Reproduction 2: candidate item projection did not match the frozen pointer

- Reproduction: the first project-environment run failed at the frozen `/candidate/items` `no_overlap` rule with `KeyError: items`; the fixture exposed only `candidate.days[].items`.
- Root cause and impact: the evaluator output shape lacked the frozen flat item view. Both offline adapters and only the two E0 cases using this rule were affected; the typed Graph, E0 inputs, and production paths were not.
- Reversible repair: added a deterministic flat `candidate.items` view carrying `day_index`, and made overlap validation group that view by day. No scoring threshold or label was changed.
- Affected regression: the missing pointer was resolved; the next run advanced to a distinct input-policy failure.

## Reproduction 3: valid common currencies/locales were too narrowly classified

- Reproduction: the next run rejected a common fixture before scoring because the local validation set allowed only CNY/USD and zh-CN/en-US.
- Root cause and impact: the validator assumptions were narrower than the frozen common dataset, which also contains EUR and en-GB. All common records using those values could be misclassified; boundary failure codes and production behavior were not involved.
- Reversible repair: derived the allowed offline set from the frozen common contract and added EUR and en-GB. The invalid ZZZ and xx-INVALID boundary fixtures remain rejected with their exact codes.
- Affected regression: both files passed 14/14; 40/40 cases ran on each adapter, threshold failures, field differences, critical mismatches, dataset drift, model/tool calls, and formal writes were all zero.

## Reproduction 4: new workset handler had an unmatched collection parenthesis

- Reproduction: the PowerShell AST parser stopped before runner contract tests with `Missing closing ')' in expression` at the P04-010 `$Missing` collection.
- Root cause and impact: the newly added `@(...)` expression closed the `Where-Object` block but omitted the collection parenthesis. Only the new gate runner was affected; no evaluator, dataset, external object, or production path ran through the invalid script.
- Reversible repair: added the single missing parenthesis without changing gate semantics.
- Affected regression: the full runner AST parse and existing `Invoke-TaskGate.Tests.ps1` contract suite both passed.

## Reproduction 5: Security scanner treated dataset symbols as HTTP execution

- Reproduction: Verify passed, while Security reported three `forbidden_external_executor_count` findings.
- Root cause and impact: the new scanner matched any `requests.` text, including the `requests.jsonl` filename and a local `requests` collection. It produced false positives only in the P04-010 Security gate; the evaluator made no network calls.
- Reversible repair: narrowed detection to callable HTTP-client forms such as `requests.get(...)`, `requests.Session(...)`, and corresponding `httpx` clients, while retaining subprocess, shell, urllib, and socket checks.
- Affected regression: the corrected Security gate must report external executors, PII, secrets, missing audit receipts, unexpected paths, and production writes all zero.

The first affected rerun cleared the external-executor finding and then reported one unexpected path: the resolved blocker required after the repeated diagnostic-shell root cause. The precise blocker file was added to the task enabler allowlist; no directory wildcard or product write scope was added.

No failed command was rerun without a new discriminating repair. Rollback is removal of the P04-010-only evaluator, schema, and evidence while retaining the immutable P04-000 baseline.
