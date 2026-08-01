# Phase 4 entry timeout repair

The first cumulative entry run exceeded the shell cell's 60-second wall-clock limit while the Agent unit suite was still running. The outer command terminated it and the partial CI summary recorded unit exit `120` after about 55 seconds; contract, Flutter, runner, report, and manifest steps were not reached. This is an orchestration timeout, not a test assertion result.

The repair keeps the full regression scope and splits it into bounded, observable components. A complete report bound to the same task and phase-base OID can be reused by Preflight; partial or failed reports cannot. Agent CI, Flutter critical journeys, and runner contracts must each finish with zero failure/skip before `phase-entry-regression.json` is written with `failure_count=0`. Preflight then creates the content-bound manifest without rerunning unchanged successful components.

Rollback removes the Phase 4 partial reports and this P04-only resumability branch. No production code, migration, database, remote ref, or external system changed.

The first standalone Flutter replay then failed before loading tests because a new worktree has no ignored `.dart_tool/package_config.json`, while `--no-pub` intentionally refuses dependency resolution. The reversible repair followed the prior-phase contract: resolve the committed lock file from the local cache with `flutter pub get --offline`, then rerun the same four files with `--no-pub`. All 14 tests passed. Generated plugin files had zero normalized Git diff; no dependency or lockfile changed.
