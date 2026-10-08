# Verifying the menu-bar UI

## Release-app checks

A rendered `DashboardPanel` in an `NSHostingView` checks its content, not the native menu-bar window. It cannot establish correct window sizing, chrome or placement. Use the packaged release app for UI acceptance.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make app
python3 scripts/capture-menu-bar.py --output /tmp/agent-usage-native-captures
```

The capture script opens a byte-identical copy of the release executable, retagged and ad-hoc signed to avoid replacing or stopping an installed app. It clicks its actual status item. It uses the real application scene, stores, history parser and visibility-triggered scan. No demo mode or replacement dashboard window is used.

Inputs are invented session files in temporary directories. Credentials are absent, so allowance fails before HTTP. Captures therefore show **unavailable allowance**, alongside ready, missing, partial, unsupported and zero-token history. Today/7/30 switching and close/reopen are also exercised. A separate neutral backdrop hides other desktop applications; it does not draw any of the tested UI.

The script checks the displayed synthetic token totals, native window bounds, proximity to the status item and the header's inset within the native window. Both the current fixed-height viewport and a content-sized viewport can satisfy these checks; the tooling does not require a layout change. The last assertion catches a short panel centered inside a stale 600-point window even when its apparent window position is correct. PNGs, geometry JSON and the release executable's SHA-256 are saved in the output directory. Assertion failures leave captures for diagnosis and fail the command.

Python 3 and an interactive macOS desktop are required. Accessibility/Automation permissions for input and System Events, and Screen Recording permission for screenshots, may be needed. A blocked capture is not a passing verification. The script does not change security settings.

## Review evidence

For a UI PR, build the base revision separately and use the current capture script against both bundles:

```sh
python3 scripts/capture-menu-bar.py --app '/path/to/base/.build/Agent Usage.app' \
  --output /tmp/agent-usage-native-before
python3 scripts/capture-menu-bar.py --output /tmp/agent-usage-native-after
```

Inspect the resulting images, including native chrome and the menu bar. Publish matched before/after images or accessible artifacts on the PR, with the revisions and commands used. Local `/tmp` paths are not shared evidence. CI runs the release-app checks and uploads its captures, including diagnostic images on failure.

Keep the injected-store rendering and sizing tests for component coverage, including healthy allowance, dark appearance, loading, long errors, scrolling and recovery. The sizing tests enforce bounded dimensions, overflow scrolling, recovery and no layout-triggered refetch; they do not require intrinsic-height sizing. They supplement, but do not replace, release-app captures. Each scripted history state starts a fresh app. The reopen check uses unchanged ready history. The script does not yet check partial-to-ready transitions in one retained native window, exact recovered height or native border/corner appearance. These are required manual checks for a resizing change, not established by a passing capture command.

Also check Refresh, visible loading/error transitions and scroll-to-bottom in the real menu-bar window when those behaviors change.
