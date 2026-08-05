# STAR: solver cold-start deadline diagnosis

## Situation

The optional solver normal-path replay failed twice: first under a 300 ms deadline and then under a
5 second deadline. The hung-child CT-014 path still passed, so repeated blind timeout changes would
not distinguish native startup from IPC or solver behavior.

## Task

Identify one verifiable root cause, exclude competing hypotheses, preserve the parent hard-kill
contract, and restore the affected normal and CT-014 regression set without weakening assertions.

## Action

The child transport was changed from Queue to a one-way typed Pipe, eliminating feeder/join ordering
as a hypothesis without changing the failure. A direct timed import measured OR-Tools native cold
start at 8.9795798 seconds on Windows/Python 3.13. The normal typed hard deadline was bounded at 15
seconds; deterministic hang injection was moved before native import so the independent 300 ms
replay reaches the intended parent kill boundary. The parent still kills and joins the child and
returns original order as a valid fallback.

## Result

Before: normal solver replay failed at both 0.3 and 5 seconds; the root cause was not distinguished.
After: 3/3 solver tests passed; CT-014 passed; killed-child-survived=false, main-service-alive=true,
fallback-valid=true, SSRF escape count=0, arbitrary tool execution count=0. The dependency audit
covered 96 environment packages with zero known vulnerabilities. These are local synthetic results,
not a production latency claim.

## Reproduction and hashes

- Command: `python -m pytest -q agent-service/tests/replay/test_solver_kill.py --maxfail=1`
- Root-cause receipt: `docs/execution/evidence/phase-07/P07-005/blocker.json`
- Root-cause receipt SHA-256: `7975d7a89e6cfd0b3af1d3eb8edf95d96270a3a72bd708ef838bcb58a0d8b506`
- CT-014 receipt: `docs/execution/evidence/phase-07/P07-005/solver-kill-report.json`
- CT-014 receipt SHA-256: `ee2a22e9deb05f0e8636012e455dfa287604d7837ad66541163f1d59de1be670`
- Solver implementation SHA-256: `ffa86f91d43b65230e502dbba0a6e2497d512429da319ef0f5ce6d3edf744004`
