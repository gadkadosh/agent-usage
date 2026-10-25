# Native UI review sessions

`ui-review.sh` owns preparation, process lifecycle, and capture for the packaged app.
It does not interact with controls, assert behavior, build the app, or publish evidence.
Use it on a logged-in macOS desktop with Accessibility permission for the process
driving the review.
Capture also requires Screen Recording permission. These permissions are not changed
by the harness.

Prefer the [Tart background workflow](#background-reviews-with-tart) for routine
reviews. The quick start below targets the current desktop; coordinate its use
first so native clicks and menu windows do not interrupt someone working there.

```sh
make app
scripts/ui-review.sh launch .scratch/review-after --app '.build/Agent Usage.app'
scripts/ui-review.sh status .scratch/review-after
```

Launch prints a unique process name and PID. The copied `.app` is renamed and ad-hoc
re-signed, leaving the source bundle and existing app instances alone. It runs the
copied bundle executable directly to retain its exact PID. Both pi directory
variables point into the session. Credentials are empty; no provider requests can
be authenticated. To review history, pass `--sessions /path/to/synthetic/sessions`.
Only use invented, non-sensitive input. This directory is copied once; symlinks are
rejected. The harness does not generate fixtures or freeze the app's clock.

Launch again with the same arguments to reuse the running instance or restart the
same prepared copy. Changes to the source app or fixture directory are **not**
recopied. Use a new session for a new build/input. Do not move session directories
or run concurrent commands against the same session.

## Interaction and capture

Use direct `osascript` with the printed PID or process name. For example, substituting
`12345` with the actual PID:

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
menu-bar item may not respond to an Accessibility `click`; a native pointer event
can be needed. Control-specific scripts and pointer helpers stay outside the harness.

```sh
scripts/ui-review.sh status .scratch/review-after
scripts/ui-review.sh capture .scratch/review-after idle
scripts/ui-review.sh cleanup .scratch/review-after
```

Status reports the process and either native bounds or the window count. A closed
window is normal; an Accessibility error is not. Capture requires exactly one open
window and uses its current Accessibility bounds with `screencapture -R`. Keep it
unobscured: this is a screen-region capture, not an offscreen window render. It rejects
closed/ambiguous windows, unsafe names, overwritten evidence, and changed bounds.
It cannot detect every overlap or a close/reopen at identical bounds. Inspect the image.

Evidence lives in `SESSION/evidence/NAME.png` and `NAME.txt`. The sidecar records the
capture time, bounds, command, process, source/isolated binary hashes, macOS version,
and fixture snapshot hashes. Binary hashes identify the artifact, not its Git revision;
record the corresponding revision and UI setup separately on the PR. For matched
before/after checks, use separate sessions with the same synthetic inputs, appearance,
locale, selection, and pointer placement.

Match the desktop background too: native translucency includes what is behind the
window. Avoid clicking desktop widgets or wallpaper to dismiss the panel. A widget
can open another app, and macOS Show Desktop can move windows out of view while
Accessibility still reports their previous bounds. Close through the menu-bar item
instead, and inspect every image even when capture succeeds.

Cleanup checks both executable path and process start time before sending SIGTERM.
It is safe to repeat, does not force-kill, and preserves the session and evidence.
After cleanup, remove the session directory yourself when no longer needed. Failed
preparation leaves artifacts for inspection; use a new directory rather than reusing it.

## Integration checks

These launch two real isolated apps and need Accessibility permission. They do not
capture an open window; manually exercise capture and inspect the resulting image too.

```sh
scripts/test-ui-review.sh '.build/Agent Usage.app'
bash -n scripts/ui-review.sh scripts/test-ui-review.sh
shellcheck scripts/ui-review.sh scripts/test-ui-review.sh
```

## Background reviews with Tart

The existing harness runs unchanged inside a macOS guest. Build on the host,
copy only the packaged app, harness, native input helper, and invented fixtures,
then interact and capture over SSH. A VM viewer or VNC connection is not needed
for normal reviews. The VM still needs an active, unlocked graphical login.

### Prepare the VM once

Use a configured local Tart VM; the examples use `usage-ui-pilot`. Installing Tart
alone does not prepare one. Record the image/version and configure the guest with:

- A test account with automatic graphical login and SSH access. Use a dedicated
  SSH key or interactive authentication; do not put credentials in the repository.
- System Events automation and Accessibility/Device Control permissions for the
  SSH launcher. In the pilot, macOS attributed these to `sshd-keygen-wrapper`.
- Screen Recording permission for the same launcher, including any additional
  screen-capture consent prompt. Permissions are granted in the **guest's** System
  Settings; do not edit TCC databases or disable System Integrity Protection.
- Sleep/locking settings that keep this test desktop available during a review.

Initial permission setup may need a guest viewer. Coordinate opening that viewer;
normal checks should run without one. Permissions must apply to the SSH execution
path, not only to Terminal opened in the guest. OS updates can require renewed
consent. If the guest is unprepared, report what is missing before using the host.

Match macOS versions, appearance, locale, time zone, actual display scale/resolution,
and background between before/after sessions. Observe the display rather than
assuming Tart's requested size took effect. A VM covers native interactions and
layout; coordinate physical-Mac checks for changes involving notches, multiple
physical displays, GPU behavior, or performance.

### Start and stage a review

Check `tart list`. If the chosen VM is stopped, start it in a separate terminal
and record that this review started it. Reuse an already-running VM without
launching another instance; only one review may interact with its desktop at a time.

```sh
tart run usage-ui-pilot --no-graphics --no-audio --no-clipboard
```

From the repository root on the host, prepare a fresh input directory:

```sh
review_vm=usage-ui-pilot
review_host="admin@$(tart ip "$review_vm")"
ssh "$review_host" 'id -un; stat -f "%Su" /dev/console'

make app
mkdir -p .scratch/ui-review
swiftc -target arm64-apple-macosx13.0 scripts/ui-input.swift -o .scratch/ui-review/ui-input
review_stage=$(mktemp -d .scratch/ui-review/stage.XXXXXX)
ditto '.build/Agent Usage.app' "$review_stage/Agent Usage.app"
cp scripts/ui-review.sh .scratch/ui-review/ui-input "$review_stage/"
mkdir "$review_stage/fixtures"
git rev-parse HEAD > "$review_stage/revision.txt"
```

The SSH user and console user must be the intended test account. Verify its
desktop and permissions before interacting. Populate `$review_stage/fixtures`
with invented sessions needed for the change, with current relative timestamps
when testing Today/7-day/30-day history. An empty directory exercises the empty
state. Define expected outcomes from those inputs; successful capture alone is
not a behavioral check. Never copy a host home directory or real credentials.

The random stage name also gives this build/input a fresh guest directory. Run the
following in the same host shell so the variables above remain available:

```sh
review_remote="usage-ui-reviews/$(basename "$review_stage")"
ssh "$review_host" "mkdir -p '$review_remote/input'"
tar -C "$review_stage" -cf - . |
  ssh "$review_host" "tar -C '$review_remote/input' -xf -"

ssh "$review_host" /bin/bash -s -- "$review_remote" <<'GUEST'
set -euo pipefail
input="$HOME/$1/input"
"$input/ui-review.sh" launch "$HOME/$1/session" \
  --app "$input/Agent Usage.app" --sessions "$input/fixtures"
GUEST
```

Use separate stages and harness sessions for matched before/after artifacts. Do
not reuse the pilot's old packaged app or fixture snapshot for a new revision.

### Interact and collect evidence

Run all `osascript` and pointer commands **inside the guest**, using its printed
PID. For example, this opens the real menu-bar window at its current native item
bounds, without fixed screen coordinates:

```sh
ssh "$review_host" /bin/bash -s -- "$review_remote" <<'GUEST'
set -euo pipefail
input="$HOME/$1/input"
session="$HOME/$1/session"
pid=$(/usr/bin/plutil -extract pid raw -o - "$session/session.plist")
point=$(osascript - "$pid" <<'APPLESCRIPT'
on run argv
    tell application "System Events"
        set p to first application process whose unix id is (item 1 of argv as integer)
        tell p
            set {x, y} to position of menu bar item 1 of menu bar 2
            set {w, h} to size of menu bar item 1 of menu bar 2
        end tell
        return ((x + w / 2) as integer as text) & " " & ((y + h / 2) as integer as text)
    end tell
end run
APPLESCRIPT
)
read -r x y <<< "$point"
"$input/ui-input" click "$x" "$y"
sleep 1
"$input/ui-review.sh" status "$session"
GUEST
```

The helper posts native pointer events; it does not assert that a control worked.
Inspect the accessible controls/state, perform the interactions relevant to the
change, and check expected outcomes. Resolve coordinates from current bounds.
The same menu-item click closes an open panel; inspect state before repeating it.
Before capture, move the guest pointer away from the chart unless testing hover.

```sh
ssh "$review_host" /bin/bash -s -- "$review_remote" <<'GUEST'
set -euo pipefail
input="$HOME/$1/input"
"$input/ui-input" move 0 0
"$input/ui-review.sh" capture "$HOME/$1/session" state-name
GUEST

ssh "$review_host" "tar -C '$review_remote/session' -cf - evidence provenance.txt" |
  tar -C "$review_stage" -xf -
```

Save relevant Accessibility output alongside the captures in the guest evidence
directory before collection. Inspect the retrieved images locally and publish the
matched evidence on the PR. Record revision, VM/image, actual display settings,
synthetic input setup, interactions, and expected outcomes. The existing sidecars
identify the guest's app binaries and fixture snapshot.

### Clean up

```sh
ssh "$review_host" "'$review_remote/input/ui-review.sh' cleanup '$review_remote/session'"
```

This preserves inputs and evidence. If this review started the VM and no other
work is using it, shut it down cleanly with
`ssh -t "$review_host" 'sudo shutdown -h now'`, then confirm `tart list` reports it
stopped. An SSH disconnect during shutdown is expected. Leave a VM that was
already running alone. There is no need to delete images, alter host privacy
settings, or install guest development tools for each review.
