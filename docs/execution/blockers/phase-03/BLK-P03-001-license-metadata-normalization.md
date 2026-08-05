# BLK-P03-001 — License metadata normalization

看到了两次依赖许可门失败：先是明确不在批准集合内的 `LGPL-3.0-only`，替换为 BSD-3-Clause 驱动后仍被报为 unknown。卡住的是 P03-001 迁移依赖 enabler 的机械许可证检查，不影响已通过的 Phase 入口回归。最安全的下一步是保留许可集合不变，只修复检查器对等价标点写法的归一化，并用允许与拒绝样本回归。

## Scope and severity

- Severity: P2; no secret, production write, tenant isolation, or data-loss event occurred.
- Affected action: dependency-enabler license gate and all later gates that reuse `check_licenses`.
- Unaffected ready work: local PostgreSQL inspection, migration design, fixtures, and phase evidence.

## Reproduction and first failures

1. Adding `psycopg[binary]==3.3.4` produced metadata `License-Expression: LGPL-3.0-only`; this is known but outside `APPROVED_LICENSE_TOKENS`, so the dependency was removed rather than approving a new license policy.
2. Adding `pg8000==1.31.5` produced `License: BSD 3-Clause License` and classifier `License :: OSI Approved :: BSD License`, but the checker returned `unknown-license:pg8000`.
3. The failed report is `docs/execution/evidence/phase-03/P03-001/dependency-enabler-ci/licenses.json`; the SCA step itself completed with zero findings before the license step failed.

## Root cause and eliminated paths

- Root cause: `check_licenses` compared the token `bsd-3-clause` literally against the expression and only replaced hyphens in classifiers. The valid expression `BSD 3-Clause License` therefore matched neither form.
- Eliminated: adding LGPL to the allowlist, suppressing the gate, manually claiming zero unknown licenses, or repeatedly rerunning unchanged inputs.
- Eliminated: stale package metadata. Official PyPI metadata and installed distribution metadata agree that pg8000 is BSD 3-Clause and Production/Stable.

## Complete reversible repair

- Normalize both approved tokens and package metadata by lowercasing and replacing non-alphanumeric runs with one space.
- Match whole normalized token sequences, not arbitrary substrings.
- Add regression cases for both BSD spellings and negative cases for LGPL and an unrelated proprietary phrase.
- Rerun the focused pytest case, the complete SCA/license stage, SBOM generation, then the affected Agent regression.

Rollback: revert the normalization helper and its tests; restore the pre-enabler dependency lock. This does not require database or external-state rollback.

## Recovery condition

The blocker is resolved only when the focused normalization tests and the complete locked SCA/license gate both pass, with `unknown_license=0`, `critical_cve=0`, and `high_cve=0`. Formal dependency acceptance remains pending independent Engineering and Security review.

## Resolution

- Status: resolved locally on 2026-08-01.
- Focused regression: `1 passed`; both valid BSD spellings were accepted and both negative cases were rejected.
- Complete locked SCA/license stage: four gates passed; `unknown_license=0`, `unpinned_direct=0`, scanner exit `0`, and no vulnerability finding was returned.
- Residual external condition: independent Engineering and Security review of ADR-P03-001 remains pending before formal merge/acceptance; it does not block safe local Phase 3 work.
