# Local macOS app packaging

## Build and install

From the repository root on macOS with Swift 6 available:

```sh
make app
```

`scripts/build-app.sh` builds the existing SwiftPM product in release mode, using the selected toolchain and the current Mac's architecture. It stages this bundle, validates its plist and ad-hoc signature, then replaces only `.build/Agent Usage.app`:

```text
Agent Usage.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/AgentUsage
    └── _CodeSignature/CodeResources
```

No Xcode project, third-party bundler, embedded agent or runtime server is needed. The bundle metadata declares macOS 13+, the `io.github.gadkadosh.AgentUsage` identifier and `LSUIElement` for menu-bar-only operation. The initial bundle version is `0.1.0` (build `1`), maintained in `packaging/Info.plist`.

Use Finder's Go to Folder to open the repository's `.build` directory. Copy `Agent Usage.app` to `/Applications` (or `~/Applications`), then double-click it. The app has no Dock icon or main window; open its chart menu-bar item to see the dashboard. Quit through the dashboard options menu before replacing an installed copy with a new build. The build does not install, launch, stop or register login items automatically.

This is a repeatable build procedure, not a claim of byte-identical output across SDKs or toolchains. CI builds and verifies the bundle but does not launch it.

## Discovery and permissions

Finder launch uses the existing defaults: `~/.pi/agent/auth.json` for optional ChatGPT allowance and `~/.pi/agent/sessions` for history. Histories are scanned only when the panel opens or on manual Refresh. Missing credentials do not block local history.

Finder does not inherit terminal-only `PI_CODING_AGENT_DIR` or `PI_CODING_AGENT_SESSION_DIR` exports. The existing overrides still work when explicitly supplied to the app's own environment, but there is no persistent custom-directory picker yet. No setup wizard, agent configuration changes or token refreshes were added.

The bundle is not App Sandbox-enabled. Existing discovery is bounded and read-only; it does not recursively search the home directory. Files must be readable by the current user. If a source is missing or unreadable, use the dashboard's coverage/error state to check the location and permissions. Do not grant Full Disk Access as a blanket workaround. Sign-in renewal remains in pi, not this app.

## Signing and distribution limits

The build runs `codesign --sign - --timestamp=none`: ad-hoc signing only, with no Keychain signing identity or private credentials. This verifies local bundle integrity; it does **not** provide Developer ID trust or notarization.

A copied local build needs no Swift toolchain to run. It targets only the build Mac's architecture; this is not a universal binary. Downloaded/quarantined copies may be blocked by Gatekeeper. This local build path does not promise frictionless distribution to other Macs and does not remove quarantine attributes or change macOS security settings. Developer ID signing, notarization, universal builds, release archives and an app icon remain separate work.

## Safe validation and diagnostics

`make app` automatically checks the plist and signature. These checks and optional architecture/dependency inspection can also be run manually:

```sh
plutil -lint '.build/Agent Usage.app/Contents/Info.plist'
codesign --verify --strict '.build/Agent Usage.app'
file '.build/Agent Usage.app/Contents/MacOS/AgentUsage'
otool -L '.build/Agent Usage.app/Contents/MacOS/AgentUsage'
```

These commands inspect build output, not credentials or histories. Share toolchain versions, build/signature errors and whether the menu item appears. Do not share auth JSON, transcripts, raw provider responses or unredacted private paths.

Functional validation should cover Finder launch, no Dock icon, Today/7/30 switching, Refresh, close/reopen and Quit. Use synthetic history and absent credentials in an isolated test home when private-source access is not authorized. Distinguish such a test from a launch against the actual user's default roots; never silently inspect real histories or credentials for a packaging smoke test.
