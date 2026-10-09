# Agent Usage

A native macOS menu-bar app showing ChatGPT account allowance and observed pi token usage on this Mac.

## Requirements

- macOS 13 or newer
- Swift 6 / Apple Command Line Tools (or Xcode)
- Existing [pi](https://pi.dev) histories for local token totals
- Optional: pi signed into OpenAI with your ChatGPT subscription (`/login` in pi) for allowance

Allowance refreshes about once a minute, independently of local history. The ChatGPT endpoint is not a supported public API and may change without notice. Allowance requests refuse redirects, including same-host redirects; a legitimate endpoint move may require an app update.

## Dashboard

Account-wide allowance meters and reset countdowns stay separate from **On this Mac** history. Choose **Today / 7 days / 30 days** for observed tokens, a combined hourly/daily chart and separate pi and OpenCode totals. OpenCode appears below pi. Other agents and API cost estimates are not supported yet.

Missing or unreadable histories are not presented as zero usage. Partial coverage and failed refreshes are visible; failed refreshes preserve the last readable totals. The history footer shows loading progress during catch-up, otherwise its update time, with a brief warning when totals may be incomplete, stale or double-counted. Technical coverage limits are documented below, not listed in the panel. Refresh and Quit remain in the header options menu; longer error content scrolls.

## Build and install

```sh
make app
```

This builds a release executable for the current Mac's architecture and creates `.build/Agent Usage.app`. Open it in Finder, or copy it to `/Applications` and double-click it there. The app runs in the menu bar without a Dock icon. Use its options menu to Refresh or Quit.

The bundle is signed ad hoc for local use, not Developer ID signed or notarized. Downloaded or quarantined copies may be blocked by Gatekeeper. Building needs Swift; running the copied bundle does not need a terminal, Swift, Node/Bun or agent extensions.

## Run from source

Run without bundling (optionally sign into OpenAI in pi first for allowance):

```sh
swift run
```

No access-token environment variable is required. Agent Usage reads only pi's `openai-codex` OAuth entry from `~/.pi/agent/auth.json` before each request, including its account ID when available. API keys and other agents' credentials are not used. The allowance is account-wide, not usage attributable only to pi.

The app never modifies pi's credentials or refreshes tokens itself. If the token expires or is rejected, use OpenAI in pi so pi can refresh it, or sign in again with `/login`, then refresh. No app restart is needed. Pi's credential storage format and the usage endpoint are unofficial integration points and may change.

If you use a custom pi directory, the optional `PI_CODING_AGENT_DIR` override is honored (including `~/` paths). A Finder-launched app uses the default location unless the override is present in its own environment; it does not inherit terminal-only variables.

`swift run` builds and launches an executable; use `make app` for an installable `.app` bundle. Additional usage sources are future steps.

## Local history

History indexing starts in the background at app launch. Opening the panel or choosing Refresh starts a refresh or joins one already running. Closing the panel does not cancel indexing. There is no periodic history refresh timer. Changing periods uses the existing snapshot without rescanning. Periods end at the last history refresh, not a live counter; reopen or Refresh to update them. History works even when allowance access fails.

The source discovers `~/.pi/agent/sessions`, honoring `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` (including `~/` paths). Supported coverage is flat `.jsonl` files or one project-directory level, validated against pi 1.0.0 session formats v2/v3. Legacy v1, hidden files, package directories, compressed histories, settings-only/CLI-only paths, ephemeral sessions and other computers are excluded. Session lease sidecars (`*.jsonl.lease`) are ignored without marking history partial. No agent extensions or running pi process are needed.

OpenCode discovery uses `~/.local/share/opencode/opencode.db`, honoring `XDG_DATA_HOME` and absolute or data-directory-relative `OPENCODE_DB` overrides. The read-only SQLite adapter is validated against OpenCode **v2.0.25** (`session_v2` / `session_message`). It counts assistant and compaction request usage, including reasoning and cached tokens; session totals and event logs are not added again. Fork copies are deduplicated through their stored ancestry and sequence numbers. Deleted ancestry can prevent complete deduplication; the panel warns when forked usage may be counted twice. Legacy v1 layouts, channel-specific databases without an explicit override, ephemeral `:memory:` databases and other computers are excluded. Each refresh reads the last 30 calendar days in one WAL-aware transaction, with a 250,000-record cap, 8 MiB record cap and five-second SQLite work deadline. Permanent limits show partial coverage; failed reads retain that agent's last readable totals while the other agent still updates. Missing sources are shown as not found, not measured zero. GUI launches only see environment overrides supplied to the app process.

The in-memory index stores only operation identity, timestamps and token counts, not transcripts or credentials. Readers never upload history, update session records or run migrations. SQLite may use its normal WAL shared-memory sidecar. For pi, files whose modification and change times both precede the 30-day chart cutoff are not read or validated. This assumes normal pi writes with consistent clocks; imported histories with both filesystem times backdated can be missed. Metadata is still checked on every refresh, so resumed sessions become eligible again. An archive containing only age-excluded files shows zero usage, not missing history. Unchanged eligible file contents are reused; changed files are reparsed in full, and app restart repeats the cold scan of eligible files. Large archives are read in batches with a 256 MiB read budget per batch. Intermediate totals appear while indexing automatically continues in the background, even with the panel closed. Permanent safety limits and exclusions may still leave coverage incomplete. Some permanent exclusions cannot be recovered by refreshing.

## Tests

Run tests with `make test` when full Xcode is installed and selected, or use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`. This runs the ordinary suite, then the opt-in memory regression alone in a fresh test process, reusing the same build. Allocator reuse from the full suite can hide memory regressions. The Apple Command Line Tools installation on its own does not provide XCTest in this environment. Credential, HTTP and history tests use synthetic data, never your real auth files, pi histories or OpenCode databases.

### Synthetic native screenshots (development only)

The opt-in rendering test uses injected synthetic snapshots only, with no live history discovery, credential access or networking:

```sh
AGENT_USAGE_RENDER_DIR=/tmp/agent-usage-captures \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DashboardRenderingTests
```

It captures all periods, light/dark, partial/missing/stale/unsupported history, zero recorded usage, loading, and unavailable allowance. This test is skipped normally and does not replace ordinary menu-bar launch/interaction validation. There is no shipped demo mode.

## Formatting

```sh
make format        # Format Swift files in place
make format-check  # Check formatting without changing files
```

Use Xcode 26.3 to match CI's formatter; formatting can differ between toolchain versions.

## License

[MIT](LICENSE) © 2026 Gad Kadosh.
