## Notes

- Command line tools are supported for building the app.
- Full Xcode is required for tests in this environment.
- Validate a clean Command Line Tools release build separately from Xcode tests.

## Safe validation

- Use synthetic history and absent credentials in an isolated test home unless access to private sources is explicitly authorized.
- Do not share auth JSON, transcripts, raw provider responses or unredacted private paths in diagnostics or PR evidence.
- Do not grant Full Disk Access as a blanket workaround for unreadable histories.

## UI verification

- Visually verify UI changes in an isolated instance of the packaged app's actual menu-bar window. Drive it with native tools. Use direct `osascript` for inspection and accessible controls, and `screencapture` for screenshots.
- Inspect and publish matched before/after screenshots or accessible artifacts on the PR. Component renders alone do not prove native UI behavior. Record the minimal setup, non-sensitive inputs, commands, and expected outcomes with the evidence so another agent can repeat the check.
