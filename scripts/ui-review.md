# Native UI review

Use a prepared macOS VM where possible; coordinate before using the host desktop
(see `AGENTS.md`). The desktop must be logged in and unlocked, with Accessibility
and automation permission for the process driving the review. Screenshots also need
Screen Recording permission. Check permissions through the actual execution path:
guest Terminal permissions may not apply over SSH. You can build on the host and
copy the app, helper, and fixtures into the guest. Run the app, helper, and UI
interactions there, then retrieve and inspect the evidence.

## Prepare and launch

```sh
make app
scripts/ui-review.sh launch .scratch/review-after --app '.build/Agent Usage.app'
scripts/ui-review.sh status .scratch/review-after
```

The helper copies and re-signs the packaged app with a unique process identity,
leaving existing app instances alone. It prints the review process name and PID.
Credentials and history paths point into the review directory, so authenticated
provider requests are unavailable. Optional inputs must be invented, non-sensitive
history; they are copied once, without credentials:

| Option | Input | Copied destination |
| --- | --- | --- |
| `--pi-history PATH` | Pi sessions directory, not an agent home | `SESSION/pi/sessions` |
| `--codex-history PATH` | Codex home with `sessions` and/or `archived_sessions` | `SESSION/codex/{sessions,archived_sessions}` |
| `--opencode-history PATH` | Closed, checkpointed OpenCode v2 SQLite database; no `-wal`/`-shm` sidecars | `SESSION/xdg-data/opencode/opencode.db` |

Symlinks are rejected. The helper does not generate fixtures or freeze the clock.
Repeating launch with the same arguments reuses the prepared copy and inputs, even
if their sources changed. Use a fresh directory for each new build/input or after
changing the helper. Do not move directories or run concurrent commands on one
session. If preparation fails, inspect the artifacts and start with a new directory.

## Interact and capture

Use direct `osascript` with the printed PID, for example:

```sh
osascript - 12345 <<'APPLESCRIPT'
on run argv
    tell application "System Events"
        set p to first application process whose unix id is (item 1 of argv as integer)
        tell p to get {position, size} of menu bar item 1 of menu bar 2
    end tell
end run
APPLESCRIPT
```

Open the review instance's menu-bar window manually or with native tools. SwiftUI's
menu-bar item may need a pointer event rather than an Accessibility `click`.
Control-specific interactions stay outside the helper.

```sh
scripts/ui-review.sh status .scratch/review-after
scripts/ui-review.sh capture .scratch/review-after idle
scripts/ui-review.sh cleanup .scratch/review-after
```

Status reports the window count or bounds; a closed window is normal, an
Accessibility error is not. Capture requires exactly one open window and uses its
Accessibility bounds with `screencapture -R`. Keep it unobscured: this captures a
screen region, not an offscreen render. The helper rejects overwritten evidence
and discards captures if the window closes or moves, but cannot detect every overlap
or a close/reopen at identical bounds. Inspect the image; capture is not a behavior test.

Evidence is saved as `SESSION/evidence/NAME.png` and `NAME.txt`. The text records the
capture time, process, bounds, and command. Publish matched before/after evidence
with the build revisions, relevant OS details, synthetic setup, actions, and expected
versus observed results. Match appearance, locale, selection, and pointer placement.
Cleanup checks executable path and process start time before stopping only that
instance; it is safe to repeat and preserves evidence. Remove the directory yourself
when no longer needed.

## Check changes to the helper

```sh
bash -n scripts/ui-review.sh scripts/test-ui-review.sh
shellcheck scripts/ui-review.sh scripts/test-ui-review.sh
scripts/test-ui-review.sh '.build/Agent Usage.app'
```

The integration checks launch two real isolated apps and need Accessibility. They
check lifecycle and safety, not UI behavior. Also open the actual menu-bar window,
capture it, and inspect the image when changing capture behavior.
