## Notes

- Command line tools are supported for building the app.
- Full Xcode is required for tests in this environment.
- Validate a clean Command Line Tools release build separately from Xcode tests.

## UI verification

- Visually verify UI changes in an isolated instance of the packaged app's actual menu-bar window. Drive it with native tools. Use direct `osascript` for inspection and accessible controls, and `screencapture` for screenshots.
- Inspect and publish matched before/after screenshots or accessible artifacts on the PR. Component renders alone do not prove native UI behavior. Record the minimal setup, non-sensitive inputs, commands, and expected outcomes with the evidence so another agent can repeat the check.
