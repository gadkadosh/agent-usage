#!/bin/bash
# Integration checks against a real packaged app; no mocked osascript/processes.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: test-ui-review.sh APP' >&2; exit 1; }
app=$(cd "$1" && pwd -P)
harness="$(cd "$(dirname "$0")" && pwd -P)/ui-review.sh"
root=$(mktemp -d "${TMPDIR:-/tmp}/ui-review-tests.XXXXXX")
root=$(cd "$root" && pwd -P)
first="$root/session one"
second="$root/session two"
cleanup() {
    for session in "$first" "$second"; do
        [[ ! -f $session/session.plist ]] || "$harness" cleanup "$session"
    done
}
trap cleanup EXIT
fail() { echo "FAIL: $* (artifacts: $root)" >&2; exit 1; }
value() { /usr/bin/plutil -extract "$2" raw -o - "$1/session.plist"; }
reject() {
    if "$@" > "$root/rejected.log" 2>&1; then
        fail "Unexpected success: $*"
    fi
}

mkdir "$root/pi-fixtures"
printf '{"type":"session","version":3,"id":"synthetic","timestamp":"2026-01-01T00:00:00Z","cwd":"/synthetic"}\n' > "$root/pi-fixtures/synthetic.jsonl"
mkdir -p "$root/codex-fixtures/sessions" "$root/codex-fixtures/archived_sessions"
printf '{"type":"session_meta","payload":{"id":"synthetic-codex"}}\n' > "$root/codex-fixtures/sessions/rollout-synthetic.jsonl"
printf '{"invented":"must not copy credentials"}\n' > "$root/codex-fixtures/auth.json"
/usr/bin/sqlite3 "$root/opencode-fixtures.db" 'CREATE TABLE synthetic (tokens INTEGER); INSERT INTO synthetic VALUES (123);'
"$harness" launch "$first" --app "$app" --pi-history "$root/pi-fixtures" --codex-history "$root/codex-fixtures" --opencode-history "$root/opencode-fixtures.db"
pid=$(value "$first" pid)
[[ $(value "$first" pi_fixtures) == "$(cd "$root/pi-fixtures" && pwd -P)" ]] || fail 'Pi input path was not recorded.'
[[ $(value "$first" codex_fixtures) == "$(cd "$root/codex-fixtures" && pwd -P)" ]] || fail 'Codex input path was not recorded.'
grep -q 'Synthetic Pi history source:' "$first/provenance.txt" || fail 'Pi provenance is unlabeled.'
grep -q 'Synthetic Codex history source:' "$first/provenance.txt" || fail 'Codex provenance is unlabeled.'
[[ $(value "$first" opencode_fixtures) == "$root/opencode-fixtures.db" ]] || fail 'OpenCode input path was not recorded.'
grep -q 'Synthetic OpenCode history source:' "$first/provenance.txt" || fail 'OpenCode provenance is unlabeled.'
cmp "$root/opencode-fixtures.db" "$first/xdg-data/opencode/opencode.db" || fail 'OpenCode snapshot differs.'
/usr/bin/sqlite3 "$root/opencode-fixtures.db" 'INSERT INTO synthetic VALUES (456);'
[[ $(/usr/bin/sqlite3 -readonly "$first/xdg-data/opencode/opencode.db" 'SELECT sum(tokens) FROM synthetic;') == 123 ]] || fail 'OpenCode snapshot follows source changes.'
[[ $(/bin/ps -ww -p "$pid" -o comm=) == "$(value "$first" executable)" ]] || fail 'Wrong process launched.'
/bin/ps eww -p "$pid" -o command= | grep -Fq "XDG_DATA_HOME=$first/xdg-data" || fail 'OpenCode data home was not isolated.'
/bin/ps eww -p "$pid" -o command= | grep -Fq 'OPENCODE_DB=opencode.db' || fail 'Inherited database override was not replaced.'
[[ ! -e $first/pi/auth.json && ! -e $first/codex/auth.json ]] || fail 'Credentials were not isolated.'
cmp "$root/codex-fixtures/sessions/rollout-synthetic.jsonl" "$first/codex/sessions/rollout-synthetic.jsonl" || fail 'Codex snapshot differs.'
printf 'changed\n' >> "$root/codex-fixtures/sessions/rollout-synthetic.jsonl"
[[ $(wc -l < "$first/codex/sessions/rollout-synthetic.jsonl") -eq 1 ]] || fail 'Codex snapshot follows source changes.'
cmp "$root/pi-fixtures/synthetic.jsonl" "$first/pi/sessions/synthetic.jsonl" || fail 'Pi snapshot differs.'
printf 'modified\n' >> "$root/pi-fixtures/synthetic.jsonl"
[[ $(wc -l < "$first/pi/sessions/synthetic.jsonl") -eq 1 ]] || fail 'Pi snapshot follows source changes.'
"$harness" launch "$first" --app "$app" --pi-history "$root/pi-fixtures" --codex-history "$root/codex-fixtures" --opencode-history "$root/opencode-fixtures.db"
[[ $(value "$first" pid) == "$pid" ]] || fail 'Repeated launch created another process.'
"$harness" status "$first" > "$root/status.txt"
grep -q 'State: running' "$root/status.txt" || fail 'Status missed running process.'
grep -q 'Windows: 0' "$root/status.txt" || fail 'New review window should be closed.'
reject "$harness" capture "$first" closed-window
[[ ! -e $first/evidence/closed-window.png ]] || fail 'Closed-window capture left an image.'
reject "$harness" capture "$first" ../escape
reject "$harness" launch "$first" --app "$app"
mkdir "$root/unrelated"
reject "$harness" launch "$root/unrelated" --app "$app"
[[ ! -e $root/unrelated/session.plist ]] || fail 'Adopted an unrelated directory.'
reject "$harness" launch "$first" --app "$app" --pi-history "$root/pi-fixtures"
reject "$harness" launch "$first" --app "$app" --codex-history "$root/codex-fixtures"
mkdir "$root/linked-fixtures"
ln -s "$root/pi-fixtures/synthetic.jsonl" "$root/linked-fixtures/link.jsonl"
reject "$harness" launch "$root/linked-session" --app "$app" --pi-history "$root/linked-fixtures"

reject "$harness" launch "$root/linked-codex-session" --app "$app" --codex-history "$root/linked-fixtures"
ln -s "$root/opencode-fixtures.db" "$root/linked.db"
reject "$harness" launch "$root/linked-opencode-session" --app "$app" --opencode-history "$root/linked.db"
touch "$root/opencode-fixtures.db-wal"
reject "$harness" launch "$root/wal-opencode-session" --app "$app" --opencode-history "$root/opencode-fixtures.db"
rm "$root/opencode-fixtures.db-wal"
reject "$harness" launch "$first" --app "$app" --pi-history "$root/pi-fixtures" --codex-history "$root/codex-fixtures"
"$harness" launch "$second" --app "$app"
other_pid=$(value "$second" pid)
[[ $other_pid != "$pid" ]] || fail 'Sessions share a process.'
[[ $(value "$second" process) != "$(value "$first" process)" ]] || fail 'Sessions share an identity.'
# Simulate PID reuse: even another owned review instance must not be signaled.
/usr/bin/plutil -replace pid -string "$other_pid" "$first/session.plist"
/usr/bin/plutil -replace started -string "$(value "$second" started)" "$first/session.plist"
"$harness" cleanup "$first"
/bin/kill -0 "$other_pid" || fail 'Cleanup stopped a foreign process.'
/bin/kill -0 "$pid" || fail 'Cleanup signaled a process without verified identity.'
/usr/bin/plutil -replace pid -string "$pid" "$first/session.plist"
# Also exercise start-time validation for the matching executable/PID.
/usr/bin/plutil -replace started -string 'wrong start time' "$first/session.plist"
"$harness" cleanup "$first"
/bin/kill -0 "$pid" || fail 'Cleanup ignored process start time.'
/usr/bin/plutil -replace started -string "$(/bin/ps -p "$pid" -o lstart=)" "$first/session.plist"
mkdir -p "$first/evidence"
printf 'preserve me\n' > "$first/evidence/sentinel.txt"
"$harness" cleanup "$first"
"$harness" cleanup "$first"
if /bin/kill -0 "$pid" 2>/dev/null; then fail 'Cleanup did not stop the review process.'; fi
[[ $(< "$first/evidence/sentinel.txt") == 'preserve me' ]] || fail 'Cleanup deleted evidence.'
"$harness" status "$first" > "$root/stopped.txt"
grep -q 'State: stopped' "$root/stopped.txt" || fail 'Status missed stopped process.'
"$harness" launch "$first" --app "$app" --pi-history "$root/pi-fixtures" --codex-history "$root/codex-fixtures" --opencode-history "$root/opencode-fixtures.db"
[[ $(value "$first" pid) != "$pid" ]] || fail 'Stopped session did not relaunch.'
[[ $(wc -l < "$first/pi/sessions/synthetic.jsonl") -eq 1 ]] || fail 'Relaunch replaced the Pi snapshot.'
"$harness" status "$second" > "$root/other.txt"
grep -q 'State: running' "$root/other.txt" || fail 'Other session stopped.'
# Pre-OpenCode sessions cannot safely relaunch a newer app with incomplete isolation.
/usr/bin/plutil -replace version -string 2 "$second/session.plist"
reject "$harness" launch "$second" --app "$app"
grep -q 'Legacy review session' "$root/rejected.log" || fail 'Version 2 launch did not explain isolation migration.'
# Legacy sessions keep their old Pi layout/key, but can still be inspected and stopped.
mv "$second/pi" "$second/agent"
/usr/bin/plutil -replace version -string 1 "$second/session.plist"
/usr/bin/plutil -replace fixtures -string '' "$second/session.plist"
/usr/bin/plutil -remove pi_fixtures "$second/session.plist"
"$harness" status "$second" > "$root/legacy.txt"
grep -q 'State: running' "$root/legacy.txt" || fail 'Legacy status missed the running process.'
reject "$harness" launch "$second" --app "$app"
grep -q 'Legacy review session' "$root/rejected.log" || fail 'Legacy launch did not explain how to proceed.'
"$harness" cleanup "$second"
"$harness" cleanup "$second"
if /bin/kill -0 "$other_pid" 2>/dev/null; then fail 'Legacy cleanup did not stop its process.'; fi
[[ -f $second/provenance.txt ]] || fail 'Legacy cleanup deleted evidence.'
printf 'PASS: real-app lifecycle, isolation, snapshot reuse, capture guards, cleanup ownership, and legacy sessions.\nArtifacts: %s\n' "$root"
