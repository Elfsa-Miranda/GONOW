# P06-006 Flutter integration-test enabler

- Reproduction: the task-card command against `integration_test/agent_network_recovery_test.dart` selected the Windows device and exited before collection with `cannot run without a dependency on package:integration_test`.
- Root cause: the Phase 6 plan requires a Flutter integration-test target, while the pinned repository manifest supplied `flutter_test` but not Flutter SDK `integration_test`.
- Impact: only integration-test collection was blocked; Python SSE/race implementation and all prior task evidence were unaffected.
- Reversible repair: add the SDK-owned development-only dependency and regenerate `pubspec.lock` with the locked Flutter executable. No runtime/production dependency or application source is changed.
- Local device diagnosis: Windows collection reached the integration runner but the host has no Visual Studio C++ toolchain; Chrome is present but Flutter reports that web devices do not support integration tests.
- Compatible local path: the runner copies the exact source bytes to an ignored `.dart_tool/gonow-p06-006/` host-test path, proves the two SHA-256 values are equal, and executes the copy on the Flutter VM. This validates the deterministic recovery contract without editing the test or claiming an unavailable device result.
- Capability difference: mobile device/background OS validation remains a formal-environment item and is not claimed here.
- Rollback: remove the two manifest lines and regenerate the lock file; the application runtime graph remains unchanged.

## Analyzer baseline repair

- Reproduction: strict root `flutter analyze --machine` returned three errors plus pre-existing warnings/info. Two errors came from the historical nested `android/` Flutter template; the third came from the root sample counter test referencing absent `MyApp`.
- Root cause: the root analyzer had no exclusion for the nested non-project template, and the generated counter test was never updated to the actual `GoNowApp` type.
- Reversible repair: exclude only `android/**` as required by the repository execution boundary and replace the broken counter fixture with a real application-type smoke assertion.
- Regression policy: the P06-006 Dart target must pass strict analysis with zero diagnostics. Root analysis also runs with warnings/info emitted but non-fatal so the unrelated legacy backlog is preserved as visible evidence rather than mass-suppressed or opportunistically rewritten.
