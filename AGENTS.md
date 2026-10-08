## Notes

- Command line tools are supported for building the app.
- Full Xcode is required for tests in this environment.
- Validate a clean Command Line Tools release build separately from Xcode tests.

## UI verification

- Verify UI changes in the packaged release app's actual menu-bar window. An NSHostingView render does not prove native sizing, chrome or anchoring.
- Run `python3 scripts/capture-menu-bar.py --output /tmp/agent-usage-native-captures`. See `docs/ui-verification.md` for coverage and permissions.
- Inspect and publish matched before/after screenshots or accessible artifacts on the PR. Local paths and reported dimensions alone are not shared visual evidence.
