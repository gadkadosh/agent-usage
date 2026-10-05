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

## Local history (not activated yet)

The read-only pi history source and live-store factory are ready for later presentation work. **The current app does not scan history at launch, in the background, or on Refresh.** The panel remains allowance-only; history UI and its refresh policy will arrive separately.

When explicitly invoked, the source discovers `~/.pi/agent/sessions`, honoring `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` (including `~/` paths). Supported coverage is flat `.jsonl` files or one project-directory level, validated against pi 1.0.0 session formats v2/v3. Legacy v1, compressed histories, settings-only/CLI-only paths, ephemeral sessions and other computers are excluded. No agent extensions or running pi process are needed.

The derived index stores only operation identity, timestamps and token counts, not transcripts or credentials. Temporary read buffers are now cleaned up promptly. The source performs no history uploads or writes and preserves coverage gaps/stale readings rather than proving zero usage. See [buffer cleanup, BEFORE/AFTER measurements and remaining costs](docs/history-scanning.md).

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
