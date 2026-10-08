# PR #18 native UI evidence

This is a review-only evidence branch. No images are added to the application branch or main.

- `original/`: packaged Command Line Tools release app from `138f7da`, before PR #18.
- `regression/`: packaged Command Line Tools release app from `370325d`. The current native regression check fails: title inset 144 points inside a 600-point native window.
- `fixed/`: packaged Command Line Tools release app from the source tree committed as `ca950b0`. The native check passes: title inset 20 points; the missing-history window is 351 points tall.

The capture script from `ca950b0` is run against each packaged app. It retags a byte-identical executable copy for isolation, opens its actual MenuBarExtra and captures the menu bar and native window. `artifact.json` records each executable's SHA-256; per-image JSON records native window, title and status-item bounds.

All captures use absent credentials and invented session files in temporary pi roots. Allowance is therefore unavailable in every image; the history states vary. No real credentials, transcripts or allowance endpoint were accessed. The neutral background is an external privacy backdrop, not a replacement dashboard window.

Local environment: macOS 27, Swift 6.4, Command Line Tools release builds. The base and fixed sets cover missing, ready, partial, unsupported and zero history, plus native period switching and close/reopen. The broken build stops after saving its failing missing-history capture.

Reproduction, from the application checkout:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make app
python3 scripts/capture-menu-bar.py --output /tmp/native-fixed
python3 scripts/capture-menu-bar.py --app '/path/to/base/.build/Agent Usage.app' --output /tmp/native-base
```

Images were inspected before publication. See the application's `docs/ui-verification.md` for coverage and permissions.
