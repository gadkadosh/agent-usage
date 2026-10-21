# Technical notes

[Back to the README](../README.md)

## ChatGPT allowance

No access-token environment variable is required. Agent Usage reads only pi's `openai-codex` OAuth entry from `~/.pi/agent/auth.json` before each request, including its account ID when available. API keys and other agents' credentials are not used. The allowance is account-wide, not usage attributable only to pi.

The app never modifies pi's credentials or refreshes tokens itself. If the token expires or is rejected, use OpenAI in pi so pi can refresh it, or sign in again with `/login`, then refresh. No app restart is needed. Pi's credential storage format is an unofficial integration point and may change.

If you use a custom pi directory, the optional `PI_CODING_AGENT_DIR` override is honored (including `~/` paths). A Finder-launched app uses the default location unless the override is present in its own environment; it does not inherit terminal-only variables.

Allowance refreshes about once a minute, independently of local history. The ChatGPT endpoint is not a supported public API and may change without notice. Allowance requests refuse redirects, including same-host redirects; a legitimate endpoint move may require an app update.

## Local history

Choose **Today / 7 days / 30 days** for pi token totals and an hourly/daily chart. These totals cover only this Mac, separately from your account-wide ChatGPT limits. Other agents and API cost estimates are not supported yet.

Missing or unreadable histories are not presented as zero usage. Failed refreshes preserve the last readable totals. The history footer shows loading progress during catch-up, otherwise its update time, with a brief warning when totals may be incomplete, stale or double-counted.

### Refresh behavior

History indexing starts in the background at app launch. Opening the panel or choosing Refresh starts a refresh or joins one already running. Closing the panel does not cancel indexing. There is no periodic history refresh timer. Changing periods uses the existing snapshot without rescanning. Periods end at the last history refresh, not a live counter; reopen or Refresh to update them. History works even when allowance access fails.

### Adapter boundary

Pi is currently the only live history adapter. `HistoryAdapter` accepts an explicit 30-day request window and returns normalized observations, coverage, an observation time, and continuation state. Ready and usable partial results replace that source's accepted set, including corrected or deleted records. A readable empty result establishes zero; confirmed missing history clears the contribution. Unsupported or unavailable results retain the last accepted observations as stale. Continuation batches include earlier accepted observations instead of returning additive deltas. Storage-specific caches, safety budgets, and duplicate/conflict handling stay inside the adapter.

`HistoryService` retains accepted source results and builds period summaries away from the UI actor. A failed read retains timestamped observations, so a refresh after midnight filters yesterday's activity out of Today even when the source remains unavailable. Observation identities are scoped to each source during aggregation. Each source publishes as it completes. Catch-up reads only adapters that requested continuation, with one fixed clock, calendar and retention cutoff for the whole refresh. Failed or completed adapters wait for the next explicit refresh. Coverage reports usable measurements independently of storage format; Pi file counts stay inside its reader. Missing optional sources do not make healthy contributions incomplete. The current Pi panel and refresh triggers remain in place. See the [two-PR implementation plan](multi-agent-history-plan.md) for Codex and the later multi-agent presentation.

### Discovery and supported formats

The source discovers `~/.pi/agent/sessions`, honoring `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` (including `~/` paths). Supported coverage is flat `.jsonl` files or one project-directory level, validated against pi 1.0.0 session formats v2/v3. Legacy v1, hidden files, package directories, compressed histories, settings-only/CLI-only paths, ephemeral sessions and other computers are excluded. Session lease sidecars (`*.jsonl.lease`) are ignored without marking history partial. No agent extensions or running pi process are needed.

### Indexing and safety limits

The in-memory index stores only operation identity, timestamps and token counts, not transcripts or credentials. The source performs no history uploads or writes.

Files whose modification and change times both precede the 30-day chart cutoff are not read or validated. This assumes normal pi writes with consistent clocks; imported histories with both filesystem times backdated can be missed. Metadata is still checked on every refresh, so resumed sessions become eligible again. An archive containing only age-excluded files shows zero usage, not missing history.

Unchanged eligible file contents are reused; changed files are reparsed in full, and app restart repeats the cold scan of eligible files. Large archives are read in batches with a 256 MiB read budget per batch. Intermediate totals appear while indexing automatically continues in the background, even with the panel closed. Permanent safety limits and exclusions may still leave coverage incomplete. Some permanent exclusions cannot be recovered by refreshing.

## Development

### Tests

Run tests with `make test` when full Xcode is installed and selected, or use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`. This runs the ordinary suite, then the opt-in memory regression alone in a fresh test process, reusing the same build. Allocator reuse from the full suite can hide memory regressions. The Apple Command Line Tools installation on its own does not provide XCTest in this environment. Credential, HTTP and history tests use synthetic data, never your real pi auth file or histories.

### Synthetic native screenshots

The opt-in rendering test uses injected synthetic snapshots only, with no live history discovery, credential access or networking:

```sh
AGENT_USAGE_RENDER_DIR=/tmp/agent-usage-captures \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DashboardRenderingTests
```

It captures all periods, light/dark, partial/missing/stale/unsupported history, zero recorded usage, loading, and unavailable allowance. This test is skipped normally and does not replace ordinary menu-bar launch/interaction validation. There is no shipped demo mode. See the [native UI review guide](../scripts/ui-review.md) for isolated packaged-app verification.

### Formatting

```sh
make format        # Format Swift files in place
make format-check  # Check formatting without changing files
```

Use Xcode 26.3 to match CI's formatter; formatting can differ between toolchain versions.
