The local archive gate failed twice before evaluating the archive because PowerShell changed Git output between character, string, and list forms.
This blocked only the new local archive verifier; it did not affect runtime, data, public contracts, the formal Phase 12 runner, or remote state.
The safest repair is to normalize every Git result into explicit lines once, then rerun the affected gate and repository regression.

ID: BLK-P12-089-archive-gate-line-normalization
Phase / TASK: Phase 12 repair enabler / provisional P12-089 archive gate
status: resolved
severity: P3; local evidence generation was unavailable, with zero runtime, data, user, or remote impact
owner / reviewer: Engineering / Architecture
first_seen / last_updated / timezone: 2026-08-04T13:40+08:00 / 2026-08-04T13:43+08:00 / Asia/Shanghai

期望结果：The verifier emits one structured receipt and exits 0 when every archive invariant passes.
实际结果：First execution called `Trim()` on a character. After the narrow caller fix, the second execution concatenated one tracked path and all untracked paths into one invalid path and also exposed one exact marker split across a line break.
影响：Only the local archive receipt was blocked. No pass receipt was emitted, no production or remote action ran, and no runtime file changed.

最小复现步骤：On Windows PowerShell 5.1, call a helper that returns one Git line and index `[0]`, then combine scalar and multi-line helper results with `+`; observe character selection and string concatenation instead of stable path arrays.
脱敏证据路径与哈希：The failed structured receipt at `docs/execution/evidence/phase-12/P12-089/archive-gate-runtime.json` records `marker_gap_count=1` and one concatenated unexpected path; final hash is indexed after closure.

已知事实：PowerShell pipeline output is unrolled; a single returned line can become a scalar string, and indexing it selects a character. The same unstable type reached changed-path aggregation.
仍不确定：None for the identified type-normalization root cause.
受影响的不变量：The archive gate could not prove allowlist scope, so it correctly remained failed even though no unsafe change was observed.

尝试时间线：
- 时间：2026-08-04T13:39+08:00
- 我以为这样能修好：Wrapping the two single-line Git calls in array expressions would stop character indexing.
- 为什么先试这个：It was the smallest reversible change matching the first exception.
- 具体做了什么：Changed HEAD and object-format reads to `@(Invoke-GitLines ...)[0]` equivalents and reran the same gate.
- 退出码和实际输出：First gate exit 1 with `System.Char` missing `Trim`; retry produced a structured failure with one concatenated unexpected path and one marker gap.
- 这次学到的新事实：The root cause affected every helper caller, not only the two indexed values.
- 有没有回滚：No; the narrow change was safe but superseded by the complete normalization.
- 本次升级的具体触发条件：The same mandatory local gate step failed a second time, requiring complete root-cause and impact documentation.

- 时间：2026-08-04T13:43+08:00
- 我以为这样能修好：Normalizing inside the helper and array-wrapping every multi-value caller would remove scalar/list ambiguity across the whole gate.
- 为什么先试这个：It repairs the shared source instead of adding more caller-specific patches and is reversible in one script diff.
- 具体做了什么：Split every Git result into explicit non-empty lines, converted ref/worktree/diff/untracked callers to arrays, made changed-path addition array-safe, and placed the required main-branch marker on one line.
- 退出码和实际输出：0; 18/18 required artifacts, 20 changed paths, and zero marker, scope, formal-artifact, specialist-ref/worktree, implementation, contract, secret-like, unsafe-command, or production-write failures.
- 这次学到的新事实：Central line normalization closed the complete scalar/list impact surface; no caller-specific cast is needed.
- 有没有回滚：Not required; only the verifier and documentation marker changed.
- 本次升级的具体触发条件：L1 minimal repair impact expanded to the shared helper, so the full affected surface was repaired once.

最终方案与选择理由：Normalize at the Git-helper boundary, keep callers explicit, and preserve fail-closed exit behavior. It is safest, has no data/compatibility/cost impact, and reverts with this documentation repair.
被否决方案及理由：Adding one-off casts at each new failure repeats micro-fixes; accepting the concatenated path would weaken the allowlist; parsing formatted console output would be less deterministic.
fix commit/PR: pending local archive commit; no remote action
验证命令与回归：`Verify-Phase12ArchitectureArchive.ps1`, `git diff --check`, JSON/hash verification, and the affected prior-checkpoint suite; final exits and receipt hashes are recorded in P12-089 evidence.
最终状态与关闭时间：resolved at 2026-08-04T13:47+08:00 after the complete helper repair, archive gate exit 0, and 15-gate/877-test affected regression.
剩余风险、预防措施、待更新文档：PowerShell 5.1 scalar unrolling remains a platform behavior; prevention is centralized normalization plus the verifier's own changed-path assertion. Owner Engineering; no open action after final gate pass.
