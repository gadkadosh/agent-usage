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

The minute cadence keeps observed warm work low while refreshing calendar periods
and catching up after a partial first scan. The existing bounded scans kept the
main actor schedulable in these fixtures, so this PR retains their budgets rather
than introducing another batching mechanism. Revisit the policy with wider
synthetic workloads if warm work becomes material.

This benchmark is not normal menu-bar/panel runtime validation. The previously
reported ordinary `swift run` failure remains undiagnosed; actual launch and panel
verification remains a gate for the presentation PR.
