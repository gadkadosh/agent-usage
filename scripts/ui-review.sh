#!/bin/bash
# Lifecycle and evidence for the packaged app. UI interaction stays in direct osascript.
set -euo pipefail
umask 077

usage() {
    cat <<'HELP'
Usage:
  ui-review.sh launch SESSION --app APP [--sessions SYNTHETIC_SESSIONS]
  ui-review.sh status SESSION
  ui-review.sh capture SESSION NAME
  ui-review.sh cleanup SESSION

SESSION is an explicit directory owned by this harness. Launch copies and re-signs
APP, with empty credentials and a snapshot of optional synthetic history. Repeating
launch reuses that copy. Capture requires exactly one open native window and saves
NAME.png plus NAME.txt in SESSION/evidence. Cleanup preserves the session/evidence.
Requires macOS. Status/capture need Accessibility; capture needs Screen Recording.
HELP
}
fail() { printf 'ui-review: %s\n' "$*" >&2; exit 1; }
get() { /usr/bin/plutil -extract "$1" raw -o - "$state"; }
put() { /usr/bin/plutil -replace "$1" -string "$2" "$state"; }

[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -ge 2 ]] || { usage >&2; exit 1; }
command=$1
session=$2
shift 2
case "$command" in launch|status|capture|cleanup) ;; *) fail "Unknown command: $command" ;; esac
[[ $(uname -s) == Darwin ]] || fail 'Requires macOS.'

app=
fixtures=
name=
if [[ $command == launch ]]; then
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || fail "Missing value for $1"
        case "$1" in
            --app) app=$2 ;;
            --sessions) fixtures=$2 ;;
            *) fail "Unknown option: $1" ;;
        esac
        shift 2
    done
    [[ -d $app ]] || fail 'Supply --app with a packaged .app directory.'
    app=$(cd "$app" && pwd -P)
    if [[ -n $fixtures ]]; then
        [[ -d $fixtures ]] || fail 'Synthetic sessions directory does not exist.'
        fixtures=$(cd "$fixtures" && pwd -P)
        [[ -z $(find "$fixtures" -type l -print -quit) ]] || fail 'Synthetic sessions must not contain symlinks.'
    fi
elif [[ $command == capture ]]; then
    [[ $# == 1 && $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || fail 'Capture needs a simple name (letters, digits, underscores, hyphens).'
    name=$1
else
    [[ $# == 0 ]] || fail 'Unexpected arguments.'
fi

# Only create a new directory; never adopt or delete an unrelated one.
if [[ ! -e $session && $command == launch ]]; then
    mkdir -p "$(dirname "$session")"
    mkdir "$session"
    session=$(cd "$session" && pwd -P)
    state="$session/session.plist"
    /usr/bin/plutil -create xml1 "$state"
    put version 1
    put source "$app"
    put fixtures "$fixtures"
    # The unique executable name also makes direct System Events interaction easy.
    token=$(/usr/bin/uuidgen | tr -d '-' | cut -c1-12)
    process="UsageReview$token"
    bundle="$session/Review.app"
    executable="$bundle/Contents/MacOS/$process"
    put process "$process"
    put executable "$executable"
    put pid ''
    put started ''
    /usr/bin/ditto "$app" "$bundle"
    plist="$bundle/Contents/Info.plist"
    original=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist")
    [[ $original == AgentUsage ]] || fail 'Expected an AgentUsage packaged app.'
    source_hash=$(/usr/bin/shasum -a 256 "$bundle/Contents/MacOS/$original" | cut -d ' ' -f1)
    mv "$bundle/Contents/MacOS/$original" "$executable"
    /usr/bin/plutil -replace CFBundleExecutable -string "$process" "$plist"
    /usr/bin/plutil -replace CFBundleName -string "$process" "$plist"
    /usr/bin/plutil -replace CFBundleIdentifier -string "local.agentusage.review.$token" "$plist"
    /usr/bin/codesign --force --sign - --timestamp=none "$bundle"
    /usr/bin/codesign --verify --strict "$bundle"
    mkdir -p "$session/agent/sessions" "$session/evidence"
    if [[ -n $fixtures ]]; then
        /usr/bin/ditto "$fixtures" "$session/agent/sessions"
    fi
    {
        printf 'Source app: %s\nSource executable SHA-256: %s\n' "$app" "$source_hash"
        printf 'Isolated executable SHA-256: '
        /usr/bin/shasum -a 256 "$executable" | cut -d ' ' -f1
        printf 'Prepared UTC: %s\n' "$(date -u +%FT%TZ)"
        /usr/bin/sw_vers
        printf 'Synthetic sessions source: %s\n' "${fixtures:-empty}"
        printf 'Snapshot hashes (relative to agent/sessions):\n'
        (cd "$session/agent/sessions" && find . -type f -exec /usr/bin/shasum -a 256 {} \;)
    } > "$session/provenance.txt"
    put ready yes
else
    [[ -d $session ]] || fail 'Session directory does not exist.'
    session=$(cd "$session" && pwd -P)
    state="$session/session.plist"
fi
[[ -f $state && $(get version) == 1 ]] || fail 'Not a ui-review session.'
# Partial preparation is never silently reused.
[[ $(get ready 2>/dev/null || true) == yes ]] || fail 'Incomplete preparation; inspect the session and use a new directory.'
process=$(get process)
executable=$(get executable)
[[ $executable == "$session/Review.app/Contents/MacOS/$process" ]] || fail 'Session was moved or its executable path changed.'
pid=$(get pid)
started=$(get started)

owned_process() {
    [[ $pid =~ ^[0-9]+$ && -n $started ]] &&
        [[ $(/bin/ps -ww -p "$pid" -o comm=) == "$executable" ]] &&
        [[ $(/bin/ps -p "$pid" -o lstart=) == "$started" ]]
}

# Arguments are passed as data, not interpolated AppleScript source.
window_info() {
    /usr/bin/osascript - "$pid" "${1:-bounds}" <<'APPLESCRIPT'
on run argv
    tell application "System Events"
        set targetProcess to first application process whose unix id is (item 1 of argv as integer)
        tell targetProcess
            set windowCount to count of windows
            if windowCount is not 1 then
                if item 2 of argv is "status" then return "Windows: " & windowCount
                error "Open exactly one review menu-bar window before capture."
            end if
            set {x, y} to position of window 1
            set {w, h} to size of window 1
            set windowRect to (x as text) & "," & (y as text) & "," & (w as text) & "," & (h as text)
            if item 2 of argv is "status" then return "Bounds (screen points): " & windowRect
            return windowRect
        end tell
    end tell
end run
APPLESCRIPT
}

case "$command" in
    launch)
        [[ $(get source) == "$app" && $(get fixtures) == "$fixtures" ]] || fail 'Session inputs differ; use a new session directory.'
        if ! owned_process; then
            # Launch the real bundle executable to retain an exact PID, not open's PID.
            PI_CODING_AGENT_DIR="$session/agent" \
                PI_CODING_AGENT_SESSION_DIR="$session/agent/sessions" \
                "$executable" > "$session/app.log" 2>&1 < /dev/null &
            pid=$!
            started=$(/bin/ps -p "$pid" -o lstart=)
            put pid "$pid"
            put started "$started"
            sleep 1
            owned_process || fail "Review app exited; inspect $session/app.log"
        fi
        printf 'Session: %s\nPID: %s\nProcess: %s\n' "$session" "$pid" "$process"
        ;;
    status)
        printf 'Session: %s\nPID: %s\nProcess: %s\n' "$session" "$pid" "$process"
        if owned_process; then
            printf 'State: running\n'
            window_info status || fail 'Window inspection failed; check Accessibility permission.'
        else
            printf 'State: stopped (or PID no longer belongs to this session)\n'
        fi
        ;;
    capture)
        owned_process || fail 'Review app is not running.'
        bounds=$(window_info) || fail 'Cannot identify the review window; no screenshot taken.'
        [[ $bounds =~ ^-?[0-9]+,-?[0-9]+,[1-9][0-9]*,[1-9][0-9]*$ ]] || fail "Invalid window bounds: $bounds"
        image="$session/evidence/$name.png"
        note="$session/evidence/$name.txt"
        [[ ! -e $image && ! -e $note ]] || fail 'Evidence already exists; use a new capture name.'
        if ! /usr/sbin/screencapture -x -R"$bounds" "$image" || [[ ! -s $image ]]; then
            rm -f "$image"
            fail 'No screenshot produced; check Screen Recording permission.'
        fi
        if ! owned_process || [[ $(window_info) != "$bounds" ]]; then
            rm -f "$image"
            fail 'Window closed or moved during capture; discarded screenshot.'
        fi
        {
            printf 'Capture UTC: %s\nPID: %s\nProcess: %s\nBounds (screen points): %s\n' "$(date -u +%FT%TZ)" "$pid" "$process" "$bounds"
            printf 'Command: screencapture -x -R%s <output.png>\n' "$bounds"
            printf 'Region capture: keep the review window unobscured. This is not a behavioral assertion.\n\n'
            /bin/cat "$session/provenance.txt"
        } > "$note"
        printf '%s\n%s\n' "$image" "$note"
        ;;
    cleanup)
        if owned_process; then
            /bin/kill -TERM "$pid"
            for ((attempt=0; attempt<50; attempt++)); do
                owned_process || break
                sleep 0.1
            done
            owned_process && fail 'Review app did not stop; no force-kill attempted.'
        fi
        printf 'Cleanup complete. Preserved session and evidence: %s\n' "$session"
        ;;
esac
