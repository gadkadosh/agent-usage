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

Run tests with `swift test` when full Xcode is installed and selected, or use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. The Apple Command Line Tools installation on its own does not provide XCTest in this environment. Credential and HTTP tests use synthetic data, never your real pi auth file.

`swift run` builds and launches an executable; it does not create an installable `.app` bundle. Packaging and additional usage sources are future steps.

## Formatting

Use Apple's `swift-format`, bundled with Swift 6, with the committed `.swift-format` configuration (four-space indentation and a 100-column line-length target):

```sh
make format        # Format Package.swift, Sources/, and Tests/ in place
make format-check  # Check without changing files; exits nonzero on style violations
```

Generated build files and mockups are excluded. CI uses Xcode 26.3; use that toolchain when formatting and checking, since formatter behavior can change between versions.

## CI

GitHub Actions runs `make format-check` and `swift test` on pull requests and pushes to `main`, using a standard macOS runner with Xcode 26.3 explicitly selected. `swift test` also builds the app. Tests use synthetic credentials and HTTP responses; no pi login or repository secrets are required.

## License

[MIT](LICENSE) © 2026 Gad Kadosh.
