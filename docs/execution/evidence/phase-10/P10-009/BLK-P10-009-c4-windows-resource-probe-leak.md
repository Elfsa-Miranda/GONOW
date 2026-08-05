# BLK-P10-009 — C4 Windows resource probe retained ctypes metadata

## Plain-language summary

The four-hour C4 workload completed 275,574 iterations without an application, database, handle, thread, backlog, or monotonic-clock failure, but the soak report correctly refused to pass because its traced Python heap had a positive slope. The leak is in the Windows measurement probe: every RSS sample created a new `ctypes.Structure` type, and ctypes retained the associated pointer metadata. The safest next step is to initialize that Windows API metadata once, prove the probe is stable with a focused regression, then rerun the affected C4 certification on a newly frozen candidate.

## Reproduction

- Candidate: `4e960e60e5f5f1f9e5a0a04ae3b483ca893bf777`
- Real duration: `14400.110839` seconds
- Samples: `480`, monotonic and hash-bound to `soak-report.json`
- Workload iterations: `275574`
- Workload failures: `0`
- Reported positive field: `python_heap_bytes`, slope `265.5461060605477 B/s`
- RSS slope: `-240.0338086113042 B/s`; handles, threads, checked-out connections, and backlog slopes were `0`
- Focused control: 10,000 `_soak_workload` executions retained only `700 B`
- Focused probe reproduction: 1,000 `_rss_bytes` calls retained `7,534,228 B`; the allocation traceback pointed to the per-call `PROCESS_MEMORY_COUNTERS` class and `ctypes.POINTER(PROCESS_MEMORY_COUNTERS)` construction.
- After caching the ctypes metadata, the same 1,000-call reproduction retained only `32 B`.
- A five-minute real PostgreSQL diagnostic then reduced the heap slope from `265.5461 B/s` to `15.0989 B/s`; that remaining slope matched the harness retaining each 30-second sample dictionary inside the measured heap. It had zero workload failures and all non-heap resources returned to baseline.
- Streaming the samples reduced a second five-minute diagnostic to `3.8181 B/s`. Independent 1,000-cycle sample-I/O and 2,000-cycle PostgreSQL controls retained only `6,187 B` and `926 B` respectively, identifying the residual as collectible progress-I/O noise against a very small traced-heap denominator rather than workload growth.

The original `soak-report.json`, `soak-samples.json`, stdout, and empty stderr remain immutable failure evidence. It must not be relabelled as passed.

## Root cause and impact surface

`_rss_bytes()` defined `PROCESS_MEMORY_COUNTERS` inside the function. On Windows, each 30-second sample therefore constructed a distinct ctypes type. The ctypes pointer-type cache retained metadata for every distinct class, producing a linear heap trend that the C4 gate was designed to reject. `_handle_count()` also reconfigured the same DLL functions on every sample.

The controlled workload-only run rules out the exercised state/checkpoint/feature-flag path as the source of this trend. The defect affects Windows C4 resource measurement and its final baseline predicate; it does not change product runtime behavior, database state, provider calls, or production data. Linux/macOS use a different RSS implementation.

## Reversible repair

- Cache one Windows process API bundle containing the ctypes structure type, DLL handles, and function signatures.
- Make both RSS and handle probes reuse that bundle.
- Run the measured workload in a spawned child process and keep progress/JSON evidence assembly in the parent observer. The child emits fixed-size binary samples, so sample retention and serialization allocations cannot contaminate its traced heap.
- Compare the final resource state against the greater of the initial and steady-state baseline before applying the unchanged tolerance; this prevents Windows working-set trimming from turning a return to the original baseline into a false failure.
- Run a full collection immediately before every heap sample so each point compares live objects at the same collection boundary; record `gc_before_sample=true`. The existing `2%`-per-hour slope threshold remains unchanged.
- Use a C4-local low-level `os.write`/`fsync`/atomic-replace progress writer in the parent. Final evidence continues to use the repository's canonical JSON writer after the child exits.
- Add a Windows regression proving 100 repeated RSS/handle samples reuse the same cached metadata and return valid values.
- Fail closed unless the formal report proves distinct positive observer/workload PIDs, child exit `0`, no scratch artifact, at least `480` samples and `360` steady-state samples, valid slopes, isolated PostgreSQL, zero failures/positive slopes, and return to baseline. Bind those fields independently in Python, Gate metrics, and the PowerShell source validator.
- Keep thresholds, four-hour duration, sample interval, workload, and fail-closed predicates unchanged.

Rollback is a normal revert of the test-harness and regression commit. No schema, production, or external state is changed.

## Recovery and required regression

1. Run the focused certification test and a 1,000-call tracemalloc probe; expected retained growth is bounded and no longer proportional to call count.
2. Run a short affected C4 diagnostic to verify the heap and RSS predicates behave after warm-up.
3. Because the runner hash and candidate OID change, freeze a new certification manifest and rerun all candidate-bound mandatory gates. The four-hour C4 soak must run again; the failed report cannot be post-processed into a pass.
4. Only aggregate C4 when the new report has `status=passed`, `real_soak_seconds>=14400`, `failure_count=0`, `positive_resource_slope_count=0`, `resource_returned_to_baseline=true`, monotonic samples, and valid artifact binding.

## Final state

`blocked_pending_measurement_redesign` — the first four-hour attempt remains a truthful failure and no duplicate soak is running. The bounded repair removed three observer artifacts without changing the workload or the `2%` threshold:

- Windows ctypes probe: `265.5461 B/s` → fixed; 1,000-call retained heap `7,534,228 B` → `32 B`.
- In-memory sample history: streamed outside the traced heap.
- Text progress writer: replaced for C4 with a low-level atomic writer; 1,000-write retained heap=`32 B`.

The final five-minute diagnostic still reported `python_heap_bytes=+1.7559 B/s` against a small `134,492 B` steady traced-heap denominator, so the relative predicate remained above `2%/hour`. It completed 5,822 workload iterations with zero failures; RSS slope was negative, handles/threads/connections/backlog were stable, `resource_returned_to_baseline=true`, and final traced heap `105,038 B` was below the steady baseline. Independent controls remained bounded: 10,000 workload iterations=`+700 B`, 2,000 PostgreSQL probes=`+926 B`, and 1,000 combined sample/progress observer cycles=`+32 B`.

This residual was not cleared by a threshold tweak. The selected complete measurement design isolates the workload in a spawned child process, writes fixed-size binary samples from that child, and assigns all JSON/progress/evidence work to the parent observer. Child exit, missing result, malformed/partial sample stream, scratch collision, and insufficient slope samples all fail closed.

The first post-redesign five-minute real PostgreSQL regression passed with:

- measurement mode `spawned_workload_process` and distinct observer/workload PIDs;
- child exit `0`, duration `300.000759s`, `10/10` monotonic hash-bound samples;
- `5,664` workload iterations and `0` failures;
- Python heap slope `0.0 B/s`, RSS slope `-341.3454 B/s`, and positive slope count `0`;
- handles, threads, checked-out connections, and backlog stable; `resource_returned_to_baseline=true`;
- no child scratch artifacts left behind and no production writes.

`resolved_pending_full_regression` — the root cause and affected short regression are closed. The original four-hour report remains a truthful failed attempt. Completion still requires committing the harness repair, freezing a new candidate/manifest, rerunning candidate-bound mandatory regression, and obtaining a fresh passing four-hour C4 report; no old evidence will be relabelled.

The contract-hardening regression is also complete: Python focused tests pass `14/14`; PowerShell self-tests pass one positive fixture plus `10` distinct negative fixtures, including a same-process Gate metric and a separately tampered raw source report. The locked minimums are `480` real samples and `360` steady-state slope samples for the four-hour run.
