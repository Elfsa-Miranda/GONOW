# P06-990 regression enabler

- Reproduction: the first complete CI run stopped in `test_harness_catalog_rejects_fake_implemented_control`; unit XML contained 43 tests with one failure and the contract stage was not run.
- Root cause and impact surface: the negative fixture depended on Harness 14 remaining `contract_only`. P06-089 correctly promoted Harness 14 to `implemented`, so the string replacement became a no-op and the test no longer exercised the missing-test-path rejection. Runtime behavior and the catalog transition were unaffected; CI contract-fixture stability was affected.
- Reversible repair: construct the invalid catalog from Harness 1's stable implemented test path and replace only that path with a nonexistent path. Reverting the single test diff restores the prior fixture.
- Affected regression: the exact previously failing pytest node passed 1/1. The complete P06-990 CI and runner contract suites are rerun after this repair; their reports are the authoritative affected-regression evidence.
- Safety boundary: this enabler changes only a negative test fixture and local evidence. Production writes, remote pushes, merges, approval claims, skips, xfails, and threshold changes remain zero.
