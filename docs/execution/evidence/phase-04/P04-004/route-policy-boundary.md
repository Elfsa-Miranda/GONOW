# P04-004 route-policy and runner boundary

- Route-policy assumption: the repository does not prove production provider/model certification, so this task implements an immutable exactly-two-tier, same-provider certification contract and uses synthetic route fixtures only. It does not select production model IDs or endpoints.
- Impact: deterministic economy/capability selection, authentication binding, usage-only ledgering, timeout propagation, circuit breaking, and a maximum of two total attempts are locally verified. Production route certification remains pending external owner evidence.
- Fail-closed behavior: unknown capabilities, cross-provider tables, invalid certification digests, credential mismatch, open circuits, and exhausted retry/fallback budgets return stable errors; no dynamic URL is accepted.
- Reproduced runner issue: the first Verify aggregation passed all 26 tests but PowerShell 5.1 rejected `Measure-Object -Property` over ordered dictionaries. The reversible repair uses explicit integer accumulation; runner contracts and Verify then passed, with one recovered diagnostic recorded.
- Rollback: remove the unmounted model package/tests and restore the prior certified-route pointer when formal policy exists. No provider call, remote push, merge, production write, or acceptance was performed.
