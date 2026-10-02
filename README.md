# Agent Usage

A native macOS menu-bar app showing account-wide ChatGPT allowance and pi's observed token history on this Mac.

## Requirements

- macOS 13 or newer
- Swift 6 / Apple Command Line Tools (or Xcode)
- Existing [pi](https://pi.dev) sessions for local history
- Optional: pi signed into OpenAI with your ChatGPT subscription (`/login` in pi) for allowance

The app reads local history and requests allowance independently, refreshing about once a minute. The ChatGPT endpoint is not a supported public API and may change without notice.

## Dashboard

See remaining 5-hour/weekly allowance and reset countdowns, plus pi token totals and a small chart for Today / 7 days / 30 days. History remains usable when allowance is unavailable.

<img src="docs/dashboard.png" alt="Native dashboard with account allowance and pi's 7-day token history" width="360">

*Shown with sample data.*

## Run

Run (optionally sign into OpenAI using `/login` in pi first to enable allowance):

```sh
swift run
```

No access-token environment variable is required. Agent Usage reads only pi's `openai-codex` OAuth entry from `~/.pi/agent/auth.json` before each request, including its account ID when available. API keys and other agents' credentials are not used. The allowance is account-wide, not usage attributable only to pi.

The app never modifies pi's credentials or refreshes tokens itself. If the token expires or is rejected, use OpenAI in pi so pi can refresh it, or sign in again with `/login`, then refresh. No app restart is needed. Pi's credential storage format and the usage endpoint are unofficial integration points and may change.

If you use a custom pi directory, the optional `PI_CODING_AGENT_DIR` override is honored (including `~/` paths). A Finder-launched app uses the default location unless the override is present in its own environment; it does not inherit terminal-only variables.

Run tests with `swift test` when full Xcode is installed and selected, or use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. The Apple Command Line Tools installation on its own does not provide XCTest in this environment. Credential and HTTP tests use synthetic data, never your real pi auth file.

`swift run` builds and launches an executable; it does not create an installable `.app` bundle. Packaging, Codex/OpenCode history, cost estimates and broader allowance support are future steps.

## Pi history

The read-only adapter is validated against pi **0.99.2**, supporting **session JSONL versions 2 and 3**. It discovers `~/.pi/agent/sessions/` (or `<PI_CODING_AGENT_DIR>/sessions`) and honors `PI_CODING_AGENT_SESSION_DIR`, including `~/` expansion. Roots may contain files directly or grouped one directory deep. Finder does not inherit terminal-only overrides. Custom `sessionDir` settings and CLI-only paths are not discovered yet.

```text
tokens = input + output + cacheRead + cacheWrite
sources = finalized assistant replies + standalone usage
        + compaction/branch summaries + tool-reported usage
```

Reasoning and one-hour cache writes are subsets, not added again. Pending/deferred responses are excluded; completed errors/aborts with reported usage are retained. All stored branches count, including abandoned/context-edited history. Copies/forks/clones retaining operation IDs and timestamps count once; conflicting copies are excluded with a warning. Nested tool details are not added to their enclosing aggregate, but tool aggregates may overlap separately saved child sessions and always carry a coverage warning.

Today starts at local midnight; 7/30 days include today and the preceding 6/29 calendar days. Charts use hourly/daily buckets and handle DST. Totals count processed tokens, including repeated context/cache usage—not unique context, quota share, or billing.

Missing, legacy, malformed and unreadable histories are reported, not silently treated as zero. Source details describe coverage gaps; oldest records do not establish completeness. Deleted histories, ephemeral runs and usage from other Macs are unavailable.

Parsing runs off the UI actor. Unchanged files reuse a bounded **in-memory** index; changed files are reparsed and deleted files removed. Only normalized IDs, timestamps and token counts are retained for the last 30 calendar days—no prompts, outputs, tool arguments, credentials or raw transcripts. No history is uploaded or persisted, and the app never modifies agent files or uses pi's SDK/migrations. Safety limits: 20,000 directory entries, 128 MiB/file, 8 MiB/line, 256 MiB read/refresh and 250,000 observations. Reaching a limit visibly reduces coverage.

Format references: pinned [session format](https://github.com/earendil-works/pi/blob/v0.99.2/packages/coding-agent/docs/session-format.md), [token semantics](https://github.com/earendil-works/pi/blob/v0.99.2/packages/ai/src/types.ts), and [full-session statistics](https://github.com/earendil-works/pi/blob/v0.99.2/packages/coding-agent/src/core/agent-session.ts).

## Safe synthetic demo

```sh
swift run AgentUsage --demo          # Today / 7 days / 30 days
swift run AgentUsage --demo partial  # Coverage gaps
swift run AgentUsage --demo missing  # Missing history (not zero)
swift run AgentUsage --demo stale    # Preserved readings after failures
```

Demo mode opens a native window with invented data. It bypasses all real history discovery, credential access and networking. Tests also use only temporary synthetic roots and injected sources.

## Formatting

```sh
make format        # Format Swift files in place
make format-check  # Check formatting without changing files
```

Use Xcode 26.3 to match CI's formatter; formatting can differ between toolchain versions.

## License

[MIT](LICENSE) © 2026 Gad Kadosh.
