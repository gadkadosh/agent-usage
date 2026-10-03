# Agent Usage

A minimal macOS menu-bar app showing the 5-hour and 7-day Codex usage limits associated with your ChatGPT subscription.

## Requirements

- macOS 13 or newer
- Swift 6 / Apple Command Line Tools (or Xcode)
- [pi](https://pi.dev) signed into OpenAI with your ChatGPT subscription (`/login` in pi)

The app requests usage directly and refreshes about once a minute. The ChatGPT endpoint is not a supported public API and may change without notice.

## Dashboard

See your remaining session and weekly allowance and reset countdowns.

<img src="docs/dashboard.png" alt="Codex dashboard with session and weekly usage meters" width="360">

*Shown with sample data.*

## Run

Sign into OpenAI (ChatGPT Plus/Pro) using `/login` in pi, then run:

```sh
swift run
```

No access-token environment variable is required. Agent Usage reads only pi's `openai-codex` OAuth entry from `~/.pi/agent/auth.json` before each request, including its account ID when available. API keys and other agents' credentials are not used. The allowance is account-wide, not usage attributable only to pi.

The app never modifies pi's credentials or refreshes tokens itself. If the token expires or is rejected, use OpenAI in pi so pi can refresh it, or sign in again with `/login`, then refresh. No app restart is needed. Pi's credential storage format and the usage endpoint are unofficial integration points and may change.

If you use a custom pi directory, the optional `PI_CODING_AGENT_DIR` override is honored (including `~/` paths). A Finder-launched app uses the default location unless the override is present in its own environment; it does not inherit terminal-only variables.

`swift run` builds and launches an executable; it does not create an installable `.app` bundle. Packaging and additional usage sources are future steps.

## Local history (integration in progress)

The app now scans supported local pi histories in the background, independently of allowance authentication. The panel is still allowance-only; period totals and charts will arrive in a separate presentation change.

History is discovered in `~/.pi/agent/sessions`. `PI_CODING_AGENT_DIR` changes the agent root; `PI_CODING_AGENT_SESSION_DIR` overrides the session root directly (including `~/` paths). Only that root's flat `.jsonl` files or one project-directory level are scanned. Pi 1.0.0 session formats v2/v3 are supported; legacy v1, compressed histories, settings-only/CLI-only custom paths, ephemeral sessions and other computers are excluded. No agent extensions or running pi process are needed.

Scans are read-only and keep only normalized operation identity, timestamps and token counts in memory—not transcript text or credentials. There are no history uploads or writes. Initial/limited scans can be partial; failures preserve last-readable data rather than proving zero usage. An initial scan, minute polling and the existing Refresh action feed this index. See [scan bounds, cadence and synthetic benchmark results](docs/history-scanning.md).

## Tests

Run tests with `swift test` when full Xcode is installed and selected, or use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. The Apple Command Line Tools installation on its own does not provide XCTest in this environment. Credential, HTTP and history tests use synthetic data, never your real pi auth file or histories.

## Formatting

```sh
make format        # Format Swift files in place
make format-check  # Check formatting without changing files
```

Use Xcode 26.3 to match CI's formatter; formatting can differ between toolchain versions.

## License

[MIT](LICENSE) © 2026 Gad Kadosh.
