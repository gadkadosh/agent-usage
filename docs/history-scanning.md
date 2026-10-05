# Pi history scanning policy

The app now owns a live `HistoryStore`, backed by one `PiHistorySource` actor for
its lifetime. Discovery, reads, parsing and aggregation run on that source actor,
not the main actor. Allowance fetching remains separate. The current panel is
unchanged; history presentation follows in a separate PR.

## Scheduling and bounds

- Scan when the menu-bar label first appears, then wait **60 seconds after each
  completed refresh** before scanning again. Opening the menu repeatedly does
  not start duplicate pollers.
- The existing Refresh action starts allowance and history refreshes independently.
  A refresh already in progress is not duplicated. Neither source waits for the
  other, and allowance failure does not prevent history collection.
- Retain the existing defaults: 256 MiB read budget per refresh, 128 MiB per file,
  8 MiB per record, 20,000 visited entries and 250,000 recent usage observations.
  These are bounds, not a promise that all histories fit.
- Unchanged-file content is not reread. Metadata enumeration, deduplication and
  calendar summaries still run. Changed/appended files are reparsed in full.
- Initial scans can be partial. Cached files do not consume the next refresh's
  read budget, allowing additional files to be indexed then. Permanently
  oversized files/records or operation/entry limits remain explicit coverage gaps;
  another refresh does not necessarily resolve them.
- The index is in memory only. Restarting repeats the initial scan. No new
  incremental reader, persisted index or accelerated catch-up scheduler is added.
- Directory enumeration failure preserves the last snapshot and exposes an error.
  It does not confirm deletion or zero usage. Per-file read failures can preserve
  cached observations with partial/stale coverage.

## Synthetic benchmark (2026-10-03)

Reproduce with full Xcode selected:

```sh
AGENT_USAGE_BENCHMARK=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -c release --filter PiHistoryBenchmarkTests
# Repeat without -c release to measure the ordinary debug build.
```

The opt-in test creates and removes its own temporary roots. Normal test runs skip
it. It uses only invented v3 records, a fixed clock/calendar and no credentials,
existing histories or network access. It checks partial-to-ready catch-up, token
reconciliation, zero extra content reads on warm scans, and one-file reparsing
after append. Timings and main-actor heartbeat gaps are printed, not CI thresholds.

Both roots contain about 320 MiB across 20 project directories:

| Shape | Files / operations | Release cold / catch-up | Release warm (3 runs) | Release append |
| --- | --- | --- | --- | --- |
| Transcript-heavy (32 KiB records) | 40 / 10,240 | 1.406 s / 0.416 s | 12–13 ms | 57 ms |
| Operation-heavy (2 KiB records) | 160 / 163,840 | 5.667 s / 1.672 s | 241–243 ms | 285 ms |

Debug: cold/catch-up 2.866/0.855 s and 8.321/2.545 s respectively; warm
27–29 ms and 484–489 ms; append 118 ms and 550 ms. Each shape became ready on
its second scan. A 10 ms main-actor heartbeat ran throughout the long scans;
maximum sampled gaps were about 14.2 ms in release and 14.1 ms in debug.

Measured on Mac14,2 (16 GiB), macOS 27.0.1, Apple Swift 6.4, Xcode 27.0.
“Cold” means a fresh in-memory index, **not** a flushed operating-system disk cache:
fixtures were just generated. These are single-machine observations, not a speed
or responsiveness guarantee for private histories, slow disks or huge file counts.

The minute cadence is **provisional**, not a demonstrated lightweight resource
policy. The initial latency-only check missed the memory problem described below.
No production resource fix or cadence change has been applied yet.

This benchmark is not normal menu-bar/panel runtime validation. The previously
reported ordinary `swift run` failure remains undiagnosed; actual launch and panel
verification remains a gate for the presentation PR.

## CPU and memory follow-up (2026-10-03)

[Reproducible harnesses, raw numeric results and full methodology](https://github.com/gadkadosh/agent-usage/tree/7e84d39c30b259031cd2695024a68a811dd9e9fb/benchmarks/history-resources)
are on a separate review branch, not in the implementation diff. Measurements
used the unchanged production scanner at `507ed9c`, Swift `-O`, six synthetic
workloads and three fresh scanner processes per workload. Compilation, fixture
generation and append writing ran outside the measured process. Roots were
explicit temporary fixtures; no private histories/auth or agent SDKs were used.

CPU is process user + system time, including instrumentation. Memory below is
sampled **physical footprint**, not input size or exact index size. The sampler
queries Mach memory counters every 20 ms; kernel peak RSS is recorded separately.
Indexed-idle measurements follow a one-second wait with the source still alive.
Warm ranges cover five unchanged checks per process. MiB means 1,048,576 bytes.

| Synthetic ~320 MiB root | CPU to index all input (cold + catch-up) | Warm CPU / check | Peak footprint | Indexed-idle footprint |
| --- | --- | --- | --- | --- |
| 40 transcript-heavy files / 10,240 operations | 1.80–1.81 s | 12–13 ms | 258 MiB | 258 MiB |
| 160 operation-heavy files / 163,840 operations | 7.31–7.42 s | 248–304 ms | 338 MiB | 167–232 MiB |
| 8,192 recent files / 163,840 operations | 9.32–9.40 s | 697–707 ms | 411 MiB | 92–97 MiB |
| 8,192 old files / no retained recent operations | 4.27–4.38 s | 430–490 ms | 341 MiB | 93–173 MiB |

Peak RSS reached 437 MiB. The old-record workload still reads the archive initially
and checks its file metadata on every refresh, even with no recent observations.

Two other workloads grew a single file from 64 to 104 MiB, appending 8 MiB before
each of five refreshes. Each refresh reparsed the whole 72–104 MiB file: **440 MiB
reread for 40 MiB appended**. CPU cost was 0.39–0.58 s/check for 32 KiB records,
and 1.59–2.49 s/check for operation-dense 2 KiB records (1.58–2.61 s elapsed).
At one check/minute, the latter extrapolates to ~2.6–4.2% of one core averaged over
the minute; 8,192 recent-file warm checks extrapolate to ~1.2%. These are not
battery measurements. Refreshes were consecutive, not real-minute polling runs.

A 10 ms main-actor heartbeat continued during scans; its largest sampled gap was
34.5 ms. This measures schedulability, not menu interaction or rendered UI latency.
Idle monitoring controls consumed ~0.016–0.025 CPU seconds per second; CPU figures
were not baseline-subtracted. Disk caches were warm from fixture generation.
Results are single-machine stress measurements, not predictions for private data.

### Actual app cross-check

One controlled release-app launch per fixture was observed for 20 seconds using
external kernel process counters, excluding probe CPU/memory. With an empty
root, peak footprint was **15 MiB**; with the transcript-heavy and operation-heavy
roots, it was **269 MiB and 333 MiB**. Footprint was still **268/333 MiB at 20 s**.
This covers initial scanning only, not minute catch-up. It confirms the large
footprint is not just a standalone-harness or fixture-generation artifact.
Synthetic input hashes were unchanged and absent credentials stayed absent.
No menu/panel interaction or successful allowance request was exercised.

### Diagnostic only: read-buffer release scope

A temporary copy of the scanner wrapped each `FileHandle.read` call in an
`autoreleasepool`, with no other source changes. One process per workload retained
correct totals and caching behavior, with similar CPU time. Sampled peak footprint
dropped from **258 to 9 MiB** for transcript-heavy input, **338 to 83 MiB** for
operation-heavy input, and **411 to 113 MiB** for many recent files. Growing-file
peaks fell from 112/138 MiB to 7/43 MiB. This strongly implicates autoreleased
read-buffer accumulation as a major cost, rather than needing to retain transcripts
in the derived index. **The diagnostic is not a reviewed production fix.**

Recommendation: fix the buffer lifetime and add regression coverage before merging
this as a lightweight app. Then reassess metadata/aggregation and growing-file
reparse costs when choosing the cadence. This follow-up changes documentation
only; it does not quietly introduce parser/index optimizations or new features.
