---
name: verification
description: Verify Agent Usage UI changes in the packaged macOS menu-bar app. Use for native window sizing, anchoring, chrome, period switching, refresh/recovery, scrolling, and before/after PR evidence. Drive an isolated instance with direct AppleScript and screenshots, not component renders alone.
---

# Verify Agent Usage

Use the packaged release app's actual MenuBarExtra. An `NSHostingView` render checks component content, not native sizing, chrome, placement, or retained-window behavior. Run these shell blocks from the repository root. Resolve bundled helpers relative to this skill directory if the checkout is elsewhere.

## Launch

An interactive macOS desktop, Python 3, and Command Line Tools are required. Full Xcode is required separately for `swift test`. Accessibility/Automation permission for the terminal running `osascript`, and Screen Recording permission for `screencapture`, may be needed. Do not change security settings. A blocked action is not verified behavior.

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools make app
SKILL="$PWD/.agents/skills/verification"
OUTPUT=$(mktemp -d /tmp/agent-usage-proof.XXXXXX)
python3 "$SKILL/scripts/session.py" start --output "$OUTPUT"
SESSION="$OUTPUT/session.json"
PID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["app"]["pid"])' "$SESSION")
INPUT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["input"])' "$SESSION")
DATA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"])' "$SESSION")
```

`start` copies and retags the release bundle, ad-hoc signs it, seeds invented session files, and starts the exact packaged executable with isolated data directories. No replacement dashboard, injected store, or demo mode is used. Re-signing can change executable bytes; `session.json` records both source and launched SHA-256 hashes. Credentials are absent, so allowance fails before HTTP. This does **not** verify healthy allowance or the live service.

Use `--app '/path/to/base/.build/Agent Usage.app'` for a separately built base revision. Use `--history partial|missing|unsupported|zero` for other initial inputs; the default is `ready`. Ready/partial inputs contain 18,420 tokens today, 128,940 over 7 days, and 552,600 over 30 days. Do not run the date-sensitive recipe across midnight.

A separate native backdrop obscures desktop applications without drawing any tested UI. Verification instances have unique bundle identifiers and owned PIDs; an installed app is left running. Still drive only one verification session at a time: the physical pointer and desktop are shared. Repeating `start` with the same output returns the live session without resetting edited files. Ended sessions require a fresh output directory.

## Doctor

Before driving, and whenever anything looks wrong, compare the PID's full executable path and start time with `app.executable` and `app.started` in `session.json`:

```bash
ps -ww -p "$PID" -o comm=
ps -p "$PID" -o lstart=
python3 -m json.tool "$SESSION"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get {position, size} of menu bar item 1 of menu bar 2"
```

Require the recorded process identity and an accessible status item. A launched process alone does not prove readiness. If the status item has not appeared, retry the read-only check. Never substitute a process found by name or drive the user's installed app.

## Drive with native tools

Use direct `osascript` for inspection and accessible controls. Do not invent a custom click/inspect wrapper. Preserve an action transcript alongside evidence, including commands, expected state, actual result, and any blocked check.

### Open and close the actual window

The tested status item reports `AXPress`, but both AppleScript `click` and `perform action "AXPress"` returned success without opening it. Use the bundled CoreGraphics fallback **only for this demonstrated exception**:

```bash
read -r x y w h <<< "$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get {position, size} of menu bar item 1 of menu bar 2" | tr ',' ' ')"
"$INPUT" click "$((x + w / 2))" "$((y + h / 2))"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get exists window 1"
```

This toggles the window, so inspect before retrying. Re-read status-item bounds for every click; items move as apps start/stop. Require the expected open/closed state, not the click's exit code.

Inspect the actual accessibility hierarchy and choose its content container:

```bash
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get entire contents of window 1"
CONTENT='group 1 of window 1'
if [ "$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get exists scroll area 1 of group 1 of window 1")" = true ]; then
  CONTENT='scroll area 1 of group 1 of window 1'
fi
```

Wait for the visibility-triggered history scan: inspect until `Reading pi history…` is gone and the expected updated state/tokens appear. Re-resolve `CONTENT` after layout changes; content-sized revisions may add/remove the scroll area.

### Switch periods and refresh

Radio buttons are identified by **description**, not name. The options control is a **menu button**, not a button. These direct accessibility clicks were exercised against the packaged app:

```bash
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to click (first radio button of radio group 1 of $CONTENT whose description is \"7 days\")"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get {description, value} of radio buttons of radio group 1 of $CONTENT"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get name of static texts of $CONTENT"
```

Use `Today` or `30 days` similarly. Require the selected value and resulting total; number grouping follows the Mac's locale.

```bash
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to click menu button \"More options\" of $CONTENT"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to click menu item \"Refresh\" of menu 1 of menu button \"More options\" of $CONTENT"
```

Require an observable updated result after refreshing. A successful accessibility action is not proof the app refreshed.

### Change inputs without restarting

Mutate only files under the recorded `DATA`. This is the app's real external file boundary, not an internal state setter. For ready → partial → ready, append/remove the invented malformed record, then use the actual Refresh menu item:

```bash
python3 - "$DATA/sessions/synthetic.jsonl" partial <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text().splitlines()
marker = 'deliberately malformed synthetic record'
lines = [line for line in lines if line != marker]
if sys.argv[2] == 'partial':
    lines.append(marker)
path.write_text('\n'.join(lines) + '\n')
PY
```

Repeat with `ready` instead of `partial` to remove the malformed record. Capture before mutation, after the visible partial warning, and after recovery. Keep the **same PID and native window** throughout; restarting cannot prove retained-window recovery.

### Choose scenarios for the change

- **Window/layout:** ready, missing, partial, unsupported, zero; correct header inset, bounds, anchoring, border/corners, and no clipping. Recover partial → ready in one retained window; compare recovered height with fresh ready height. Close/reopen and repeat.
- **Period selection:** Today/7/30 values and visible totals; selection survives close/reopen.
- **Refresh:** use the actual menu; observe loading/error/recovery when reproducible. The no-credentials fixture proves unavailable allowance, not successful HTTP refresh.
- **Overflow:** use a genuinely overflowing state or screen configuration. Inspect the actual scroll area's controls/actions; drive its exposed scrollbar with AppleScript when available. Capture top/bottom and require movement plus reachable bottom content. No scrolling fallback is supplied yet; report blocked coverage rather than using a component test as native proof.

Keep focused Swift sizing/store tests for bounded dimensions, scrolling, recovery, and refetch behavior. Opt-in component captures (`AGENT_USAGE_RENDER_DIR=… swift test --filter DashboardRenderingTests`) cover synthetic healthy allowance and dark appearance. They supplement native acceptance, not replace it.

## Evidence

Capture the action and resulting state, not just a final screen. Save the native accessibility hierarchy, window/status-item/header bounds, and PNGs. After opening the window and resolving `CONTENT`:

```bash
NAME=ready
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get entire contents of window 1" > "$OUTPUT/$NAME.ax.txt"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get {position, size} of window 1" > "$OUTPUT/$NAME.window.txt"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get {position, size} of menu bar item 1 of menu bar 2" > "$OUTPUT/$NAME.status.txt"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get {position, size} of static text \"Agent Usage\" of $CONTENT" > "$OUTPUT/$NAME.header.txt"
read -r wx wy ww wh <<< "$(tr ',' ' ' < "$OUTPUT/$NAME.window.txt")"
read -r bx by bw bh <<< "$(tr ',' ' ' < "$OUTPUT/$NAME.status.txt")"
left=$(( (wx < bx ? wx : bx) - 10 ))
right=$(( wx + ww > bx + bw ? wx + ww : bx + bw ))
screencapture -x "-R$left,0,$((right - left + 10)),$((wy + wh + 10))" "$OUTPUT/$NAME.png"
```

Inspect the PNG itself, including native chrome, shadow, and the menu bar. Match scenarios, appearance, and screen configuration between separately built base/head bundles. Publish matched before/after images or accessible CI artifacts on the PR with revisions and commands. Local paths and dimensions alone are not shared visual evidence. Record skipped paths explicitly; one passing entry point does not verify another.

The bounded CI smoke recipe is `python3 scripts/verify-menu-bar.py --output /tmp/agent-usage-smoke-UNIQUE`. It uses these native tools, checks totals/geometry/reopen/same-window recovery, and saves actions plus accessibility snapshots. A passing smoke run does not prove corner appearance, healthy allowance, loading transitions, or actual overflow scrolling.

## Cleanup

Run cleanup after successful **and failed** attempts:

```bash
python3 "$SKILL/scripts/session.py" stop --session "$SESSION"
test -f "$OUTPUT/$NAME.png"
```

Cleanup verifies executable paths and process start times before stopping owned app/backdrop PIDs. It removes their scratch bundle/data/input executable, marks the session stopped, and keeps logs, identity/hashes, screenshots, and accessibility evidence in `OUTPUT`. Repeating cleanup is safe. Never kill by process name or delete evidence. Confirm saved proof still exists after cleanup.

## Helpers

`session.py start/stop` centralizes isolation and ownership, not UI interactions. It compiles `NativeInput.swift` into the recorded `INPUT` executable. The native helper has only `click X Y` (shown above) and `backdrop` (started/stopped by session setup). Do not add input wrappers unless direct native tools demonstrably cannot perform a required action.
