# P04-009 gate runner enabler

The catalog declares legacy-bypass and FeatureFlags control 31 assertions, but the materialized runner initially had no P04-009 handlers. This enabler adds task-local Verify, Security, Evidence, WorksetVerify, and RollbackVerify gates. The first direct test command did not start because its evidence directory had not yet been materialized; the plan-ordered Preflight/WorkPreflight created it, and the unchanged command then passed 11 tests.

The implementation intentionally mounts no `APIRouter` and therefore adds no public endpoint. Legacy chat, import, auth, fallback, flag-off itinerary, and flag-store-failure paths all keep the Agent call count at zero. Feature-enabled itinerary selection remains an in-process seam for later Graph/API cards. The repair is reverted with one local commit and performs no model, database, production, remote, approval, or legacy Flutter mutation.

Affected regression before commit: runner contracts passed; Agent CI passed 237 unit/integration and 51 explicit contract tests, with format, lint, type, dependency, license, secret, and clock gates green.
