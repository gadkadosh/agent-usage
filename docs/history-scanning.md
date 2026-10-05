# Pi history factory and buffer cleanup

This PR prepares a live `HistoryStore` factory backed by one `PiHistorySource`
actor and fixes temporary read-buffer accumulation. **It does not activate history
in the app.** `AgentUsageApp.swift` matches the allowance-only baseline: launch,
polling and Refresh do not construct or scan history. UI integration and a history
refresh policy come later; the proposed fixed minute cadence has been removed.

The factory retains one actor/index across explicitly requested refreshes. Tests
inject synthetic roots and a clock/calendar. Discovery, reads, parsing and
aggregation execute on the source actor, independently of allowance fetching.

## Read-buffer fix

Foundation can autorelease temporary objects created by `FileHandle.read`. Without
an explicit release scope, those buffers accumulated during scans even though the
derived index retained only normalized metadata. Each 64 KiB read now runs inside
an `autoreleasepool`. The returned `Data` remains owned by the loop iteration and
its slices; temporary read objects are released promptly rather than waiting for
a surrounding pool. Files were already being closed correctly.

This changes memory lifetime, **not** file selection, chunk size, token accounting,
read budgets, cancellation or cache rules. It is not an incremental tail reader.

## Matched BEFORE / AFTER measurements (2026-10-05)

[Reproducible scripts, raw results and full methodology](https://github.com/gadkadosh/agent-usage/tree/313ebdc77a105a8a7418975db2b84a92d7f14d6b/benchmarks/history-resources/buffer-cleanup)
are on a separate review branch, outside the implementation diff. All six workloads
were rerun on the original reader (`507ed9c`) and actual fixed source (`0924704`),
with three fresh release scanner processes per workload per version (36 total).
The scanner benchmark does not include app activation code, so the comparison
isolates the buffer fix rather than avoiding scans.

Measured on Mac14,2 / 16 GiB / macOS 27.0.1 / Swift 6.4 / Xcode 27.0. Compilation,
fixture generation and external append writing ran outside measured processes.
Every history was generated at an explicit temporary root; no private histories,
credentials, provider requests or agent SDKs were used. Disk caches were warm from
generation. Peak below is the maximum sampled physical footprint during scan
phases across three processes; MiB means 1,048,576 bytes. Sampling interval: 20 ms.
These are whole-process measurements, not exact index sizes or universal limits.

| Synthetic workload | BEFORE peak footprint | AFTER peak footprint |
| --- | --- | --- |
| ~320 MiB / 40 transcript-heavy files | 258.4 MiB | 9.3 MiB |
| ~320 MiB / 160 operation-heavy files | 337.9 MiB | 82.6 MiB |
| ~320 MiB / 8,192 recent files | 415.5 MiB | 111.3 MiB |
| ~320 MiB / 8,192 old files, no recent observations | 340.3 MiB | 32.8 MiB |
| Growing 64→104 MiB transcript-heavy file | 111.7 MiB | 7.1 MiB |
| Growing 64→104 MiB operation-heavy file | 143.9 MiB | 38.5 MiB |

CPU work is essentially unchanged. For example, indexing all transcript-heavy
input cost 1.81–1.84 CPU seconds before vs 1.76–1.79 after; operation-heavy input
cost 7.40–7.52 vs 7.31–7.37. A changed growing operation-heavy file still costs
1.60–2.31 vs 1.59–2.33 CPU seconds/check. Those five checks still reread 440 MiB for
40 MiB appended. All runs retained exact final totals, partial-to-ready catch-up,
zero warm content rereads and one-file reparsing per append. This is a memory
improvement, not a promise that archive processing is now cheap.

## Regression and app checks

The new memory regression writes a 64 MiB synthetic file using one reused 32 KiB
block. It checks extra footprint at read completion before the source yields:
**64.9 MiB before (expected failure), 0.58 MiB after in debug, 0.56 MiB in release**.
It requires <24 MiB growth and is run by CI in a fresh filtered test process so
allocator reuse from other tests cannot hide the regression:

```sh
AGENT_USAGE_MEMORY_REGRESSION=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter PiHistoryMemoryTests
```

Regular source tests cover chunk-spanning/CRLF records, partial and oversized
records, limits, stale recovery, cancellation and deduplication. The existing
opt-in large-history test remains reproducible with `AGENT_USAGE_BENCHMARK=1
swift test -c release --filter PiHistoryBenchmarkTests` and full Xcode selected.

Controlled release-app launches with empty and both ~320 MiB roots now all peak
at about **15 MiB** over 20 seconds. This is because **history activation was
removed**, not because the buffer fix alone makes a scanning app use 15 MiB.
Input hashes were unchanged; credentials stayed absent. No menu/panel interaction
or successful allowance fetch was exercised. The previously reported normal-launch
issue remains undiagnosed; ordinary menu/panel validation is still a UI merge gate.

## Bounds and deferred work

- Existing source defaults remain: 256 MiB per-refresh read budget, 128 MiB/file,
  8 MiB/record, 20,000 visited entries and 250,000 recent observations.
- Unchanged contents are cached, but metadata checks and aggregation still run.
  Changed/appended files are reparsed in full; the index is in memory only.
- Scans may be partial; cached files can permit later budget catch-up. Permanent
  file/record/operation/entry exclusions remain explicit coverage gaps.
- Enumeration failure preserves the previous snapshot, not an invented zero.
- Persistent indexing, verified incremental reads, file watching and on-demand/
  adaptive refresh are separate reviews, not hidden additions here.

Memory counters and main-actor heartbeat are not native UI or battery measurements.
These single-machine synthetic results do not establish cold-disk performance or
performance guarantees for private histories. Remaining CPU/index costs must inform
future activation policy; the app currently performs none of this background work.
