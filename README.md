# Agent Usage

A native macOS menu-bar app showing ChatGPT account allowance and observed pi token usage on this Mac.

## Requirements

- macOS 13 or newer
- Swift 6 / Apple Command Line Tools (or Xcode)
- Existing [pi](https://pi.dev) histories for local token totals
- Optional: pi signed into OpenAI with your ChatGPT subscription (`/login` in pi) for allowance

Allowance refreshes about once a minute, independently of local history. The ChatGPT endpoint is not a supported public API and may change without notice. Allowance requests refuse redirects, including same-host redirects; a legitimate endpoint move may require an app update.

## Dashboard

Account-wide allowance meters and reset countdowns stay separate from **On this Mac** history. Choose **Today / 7 days / 30 days** for observed tokens, an hourly/daily chart and the pi total. Other agents and API cost estimates are not supported yet.

Missing or unreadable histories are not presented as zero usage. Partial coverage and failed refreshes are visible; failed refreshes preserve the last readable totals. Source details explain exclusions. Refresh and Quit remain in the header options menu; longer error/details content scrolls.

## Run

Run (optionally sign into OpenAI in pi first for allowance):

```sh
swift run
```

No access-token environment variable is required. Agent Usage reads only pi's `openai-codex` OAuth entry from `~/.pi/agent/auth.json` before each request, including its account ID when available. API keys and other agents' credentials are not used. The allowance is account-wide, not usage attributable only to pi.

The app never modifies pi's credentials or refreshes tokens itself. If the token expires or is rejected, use OpenAI in pi so pi can refresh it, or sign in again with `/login`, then refresh. No app restart is needed. Pi's credential storage format and the usage endpoint are unofficial integration points and may change.

If you use a custom pi directory, the optional `PI_CODING_AGENT_DIR` override is honored (including `~/` paths). A Finder-launched app uses the default location unless the override is present in its own environment; it does not inherit terminal-only variables.

`swift run` builds and launches an executable; it does not create an installable `.app` bundle. Packaging and additional usage sources are future steps.

## Local history

History refreshes when the panel becomes visible and on manual Refresh, not on an invisible timer. Hiding the panel cancels its visibility-triggered scan; an explicitly requested manual refresh may finish while hidden. Changing periods uses the existing snapshot without rescanning. Periods end at the last history refresh, not a live counter; reopen or Refresh to update them. History works even when allowance access fails.

The source discovers `~/.pi/agent/sessions`, honoring `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` (including `~/` paths). Supported coverage is flat `.jsonl` files or one project-directory level, validated against pi 1.0.0 session formats v2/v3. Legacy v1, compressed histories, settings-only/CLI-only paths, ephemeral sessions and other computers are excluded. No agent extensions or running pi process are needed.

The in-memory index stores only operation identity, timestamps and token counts, not transcripts or credentials. The source performs no history uploads or writes. Unchanged file contents are reused; changed files are reparsed in full, and app restart repeats the cold scan. Large archives may exceed the 256 MiB per-refresh read budget: coverage stays partial and later opens/manual refreshes may catch up. Some permanent exclusions cannot be recovered by refreshing. See [buffer cleanup, BEFORE/AFTER measurements and remaining costs](docs/history-scanning.md).

## Tests

Run tests with `swift test` when full Xcode is installed and selected, or use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. The Apple Command Line Tools installation on its own does not provide XCTest in this environment. Credential, HTTP and history tests use synthetic data, never your real pi auth file or histories.

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
