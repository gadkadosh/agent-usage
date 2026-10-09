# Native UI review sessions

`ui-review.sh` owns preparation, process lifecycle, and capture for the packaged app.
It does not interact with controls, assert behavior, build the app, or publish evidence.
Use it on a logged-in macOS desktop with Accessibility permission for your terminal.
Capture also requires Screen Recording permission. These permissions are not changed
by the harness.

```sh
make app
scripts/ui-review.sh launch .scratch/review-after --app '.build/Agent Usage.app'
scripts/ui-review.sh status .scratch/review-after
```

Launch prints a unique process name and PID. The copied `.app` is renamed and ad-hoc
re-signed, leaving the source bundle and existing app instances alone. It runs the
copied bundle executable directly to retain its exact PID. Both pi directory
variables and `OPENCODE_DB` point into the session. Credentials are empty; no provider
requests can be authenticated. To review history, pass `--sessions /path/to/synthetic/sessions`
and/or `--opencode-db /path/to/synthetic/opencode.db`. Only use invented, non-sensitive
input. Inputs are copied once; symlinks are rejected. Checkpoint and close the synthetic
SQLite database before supplying it; non-empty WAL sidecars are rejected. The harness does not generate fixtures or freeze the app's clock.

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
