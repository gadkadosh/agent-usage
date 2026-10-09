## Notes

- Command line tools are supported for building the app.
- Full Xcode is required for tests in this environment.
- Run `make check-clt-build` separately from Xcode tests. It must pass without SDK overrides.

## UI verification

- Visually verify UI changes in an isolated instance of the packaged app's actual menu-bar window. Use `scripts/ui-review.sh` for launch, status, capture, and cleanup; see `scripts/ui-review.md` for session setup and limitations. Continue using direct `osascript` for inspection and accessible controls. The harness records evidence, not a behavioral verdict.
- Inspect and publish matched before/after screenshots or accessible artifacts on the PR. Component renders alone do not prove native UI behavior. Record the minimal setup, non-sensitive inputs, commands, and expected outcomes with the evidence so another agent can repeat the check.
