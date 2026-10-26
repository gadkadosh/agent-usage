# Technical notes

[Back to the README](../README.md)

## ChatGPT allowance

No access-token environment variable is required. Agent Usage reads only pi's `openai-codex` OAuth entry from `~/.pi/agent/auth.json` before each request, including its account ID when available. API keys and other agents' credentials are not used. The allowance is account-wide, not usage attributable only to pi.

The app never modifies pi's credentials or refreshes tokens itself. If the token expires or is rejected, use OpenAI in pi so pi can refresh it, or sign in again with `/login`, then refresh. No app restart is needed. Pi's credential storage format is an unofficial integration point and may change.

If you use a custom pi directory, the optional `PI_CODING_AGENT_DIR` override is honored (including `~/` paths). A Finder-launched app uses the default location unless the override is present in its own environment; it does not inherit terminal-only variables.

Allowance refreshes about once a minute, independently of local history. The ChatGPT endpoint is not a supported public API and may change without notice. Allowance requests refuse redirects, including same-host redirects; a legitimate endpoint move may require an app update.

## Local history

Choose **Today / 7 days / 30 days** for combined Pi and Codex token activity and an hourly/daily chart. These totals cover only this Mac, separately from your account-wide ChatGPT limits. Alphabetical agent rows show the same selected period. Hovering a chart bucket changes only the large number, not the period totals in the rows. API cost estimates are outside scope.

Missing or unreadable histories are not presented as zero usage. Failed refreshes preserve the last readable observations. An unreadable agent with no accepted readings shows Unavailable/Failed, rather than a numeric zero. Warnings belong to the affected agent row; the combined chart shows available contributions. Healthy agents with no recorded activity in the last 30 days stay hidden. An agent remains visible with zero usage for a shorter selected period when it has activity in the 30-day window. The footer shows loading progress during catch-up, otherwise the oldest accepted contribution's update time. Failed refreshes do not advance the freshness of retained readings.

### Refresh behavior

History indexing starts in the background at app launch. Opening the panel or choosing Refresh starts a refresh or joins one already running. Closing the panel does not cancel indexing. There is no periodic history refresh timer. Changing periods uses the existing snapshot without rescanning. Periods end at the last history refresh, not a live counter; reopen or Refresh to update them. History works even when allowance access fails.

### Adapter boundary

Pi and Codex are the live history adapters. `HistoryAdapter` accepts an explicit 30-day request window and returns normalized observations, coverage, an observation time, and continuation state. Ready and usable partial results replace that source's accepted set, including corrected or deleted records. A readable empty result establishes zero; confirmed missing history clears the contribution. Unsupported or unavailable results retain the last accepted observations as stale. Continuation batches include earlier accepted observations instead of returning additive deltas. Storage-specific caches, safety budgets, and duplicate/conflict handling stay inside the adapter.

Production `HistoryStore.live()` discovers all supported adapters. Tests use `live(adapters:)` with explicit synthetic sources; it never adds adapters or falls through to personal history discovery. Snapshots carry explicit source identities, never an implied Pi source.

`HistoryService` owns the complete refresh. Each source reads and catches up independently under one fixed clock, calendar and retention cutoff, publishing accepted results as they arrive. Completed or failed adapters wait for the next refresh. The presentation store publishes updates and awaits completion.

Failed or unsupported reads retain the previous timestamped observations. Reaggregation filters yesterday's activity out of Today after midnight, even if the source stays unavailable. Operation identities are scoped to each source. Coverage and failures use typed source status; the panel chooses agent-specific error wording, and file-count diagnostics stay inside the reader. Missing optional sources do not make healthy contributions incomplete.

### Pi discovery and supported formats

Pi discovers `~/.pi/agent/sessions`, honoring `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` (including `~/` paths). Supported coverage is `.jsonl` files at the root or in nested directories (up to the shared 16-directory-level scan limit), including child-session layouts, validated against pi 1.0.0 session formats v2/v3. `subagent-artifacts` directories are excluded because their transcript copies are not canonical sessions. Legacy v1, hidden files, package directories, compressed histories, settings-only/CLI-only paths, ephemeral sessions and other computers are excluded. Session lease sidecars (`*.jsonl.lease`) are ignored without marking history partial. No agent extensions or running pi process are needed.

### Codex discovery and accounting

Codex reads `~/.codex/sessions` and `~/.codex/archived_sessions`, honoring `CODEX_HOME` (including `~/` paths). It does not read Codex credentials or SQLite state. This covers local CLI, app, extension, child, and background threads when their usage is persisted in those roots; remote/cloud-only, temporary, deleted, compressed, or otherwise unpersisted histories are outside coverage.

The JSONL contract is verified against [OpenAI Codex 0.163.0](https://github.com/openai/codex/tree/83086188ae0614bd882818ff1aa23f3194962012):

- [Protocol types](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/protocol/src/protocol.rs) define response usage, cumulative counters, cache/reasoning subsets, and thread ownership. `world_state` snapshots/patches persist environment comparison state, not spending; like response items, they do not affect totals or coverage.
- [Session accounting](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/core/src/session/mod.rs) and [compaction accounting](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/core/src/compact.rs) persist a durable response record before the paired token-count report. The parser uses the response record once and suppresses its paired counter. Legacy reports, including incomplete responses without durable records, count only when last-operation usage agrees with cumulative input/output advances. Repeated reports and counter resets are not additional spending; inconsistent reports mark coverage partial. Reset or invalid counters start a new identity segment so later consistent spending cannot collide with an earlier cumulative position.
- [Rollout recording](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/rollout/src/recorder.rs) writes a fork's header before inherited records and may rewrite envelope timestamps. Durable records belonging to ancestors are excluded. Legacy inherited reports are excluded until a settings marker identifies the actual child thread. Local settings updates preserve the active turn; crossing an inherited-history boundary clears it. Earlier formats without enough ownership/counter metadata may be partial; ambiguous copied legacy usage is omitted rather than guessed.

Totals are input plus output tokens. Cached input/cache-write categories and reasoning output are subsets, counted once. Response IDs are scoped to their spending thread. Active/archive copies deduplicate together; conflicting copies are excluded and marked partial. Matching copies with different envelope timestamps use the earliest available timestamp. Child and background threads contribute to the Codex row. Compaction/replay snapshots are not new spending.

### Indexing and safety limits

The in-memory index stores only operation identity, timestamps, and token totals, not transcripts, credentials, or model/provider attribution. Token categories are validated while parsing but are not retained separately. Neither adapter uploads or writes history.

Pi files whose modification and change times both precede the 30-day chart cutoff are not read or validated. This assumes normal pi writes with consistent clocks; imported histories with both filesystem times backdated can be missed. Metadata is still checked on every refresh, so resumed sessions become eligible again. An archive containing only age-excluded files shows zero usage, not missing history.

Codex resolves duplicates and conflicts before applying the chart cutoff. Its index retains older normalized accounting metadata and does not age-skip files: an older original can disqualify a copy whose envelope timestamp was rewritten into the current window. These older records share the existing operation and byte limits, so a large Codex archive can hit incomplete-coverage limits even with little recent activity.

Unchanged eligible file contents are reused; changed files are reparsed in full, and app restart repeats the cold scan of eligible files. Large archives are read in batches with a 256 MiB read budget per root per batch. Pi has one root and Codex has independent active/archive roots, each with its own bounded index. Intermediate totals appear while indexing automatically continues in the background, even with the panel closed. Permanent safety limits and exclusions may still leave coverage incomplete. Some permanent exclusions cannot be recovered by refreshing.

## Development

### Tests

Run tests with `make test` when full Xcode is installed and selected, or use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`. This runs the ordinary suite, then the opt-in memory regression alone in a fresh test process, reusing the same build. Allocator reuse from the full suite can hide memory regressions. The Apple Command Line Tools installation on its own does not provide XCTest in this environment. Credential, HTTP and history tests use synthetic data, never real agent credentials or personal histories.

Shared `HistoryFixtures` supplies the fixed clock/calendar, and `HistoryFixtureRoot` supplies temporary files. `PiHistoryFixtures` and `CodexHistoryFixtures` generate only their respective formats.

### Synthetic native screenshots

The opt-in rendering test uses injected synthetic snapshots only, with no live history discovery, credential access or networking:

```sh
AGENT_USAGE_RENDER_DIR=/tmp/agent-usage-captures \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DashboardRenderingTests
```

It captures combined-agent and single-agent dashboards, all periods, light/dark, partial/missing/stale/unsupported history, zero recorded usage, loading, and unavailable allowance. This test is skipped normally and does not replace ordinary menu-bar launch/interaction validation. There is no shipped demo mode. See the [native UI review guide](../scripts/ui-review.md) for isolated packaged-app verification.

### Formatting

```sh
make format        # Format Swift files in place
make format-check  # Check formatting without changing files
```

Use Xcode 26.3 to match CI's formatter; formatting can differ between toolchain versions.
