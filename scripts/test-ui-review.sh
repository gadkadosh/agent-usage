#!/bin/bash
# Integration checks against a real packaged app; no mocked osascript/processes.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: test-ui-review.sh APP' >&2; exit 1; }
app=$(cd "$1" && pwd -P)
harness="$(cd "$(dirname "$0")" && pwd -P)/ui-review.sh"
root=$(mktemp -d "${TMPDIR:-/tmp}/ui-review-tests.XXXXXX")
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

mkdir "$root/fixtures"
/usr/bin/sqlite3 "$root/opencode.db" 'CREATE TABLE synthetic (tokens INTEGER); INSERT INTO synthetic VALUES (200);'
printf '{"type":"session","version":3,"id":"synthetic","timestamp":"2026-01-01T00:00:00Z","cwd":"/synthetic"}\n' > "$root/fixtures/synthetic.jsonl"
"$harness" launch "$first" --app "$app" --sessions "$root/fixtures" --opencode-db "$root/opencode.db"
pid=$(value "$first" pid)
[[ $(/bin/ps -ww -p "$pid" -o comm=) == "$(value "$first" executable)" ]] || fail 'Wrong process launched.'
[[ ! -e $first/agent/auth.json ]] || fail 'Credentials were not isolated.'
cmp "$root/fixtures/synthetic.jsonl" "$first/agent/sessions/synthetic.jsonl" || fail 'Fixture snapshot differs.'
cmp "$root/opencode.db" "$first/opencode.db" || fail 'OpenCode snapshot differs.'
/usr/bin/sqlite3 "$root/opencode.db" 'UPDATE synthetic SET tokens = 400;'
[[ $(/usr/bin/sqlite3 "$first/opencode.db" 'SELECT tokens FROM synthetic;') == 200 ]] || fail 'OpenCode snapshot follows source changes.'
printf 'modified\n' >> "$root/fixtures/synthetic.jsonl"
[[ $(wc -l < "$first/agent/sessions/synthetic.jsonl") -eq 1 ]] || fail 'Snapshot follows source changes.'
"$harness" launch "$first" --app "$app" --sessions "$root/fixtures" --opencode-db "$root/opencode.db"
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
mkdir "$root/linked-fixtures"
ln -s "$root/fixtures/synthetic.jsonl" "$root/linked-fixtures/link.jsonl"
reject "$harness" launch "$root/linked-session" --app "$app" --sessions "$root/linked-fixtures"
ln -s "$root/opencode.db" "$root/linked.db"
reject "$harness" launch "$root/linked-db-session" --app "$app" --opencode-db "$root/linked.db"
printf 'invented WAL content\n' > "$root/opencode.db-wal"
reject "$harness" launch "$root/wal-session" --app "$app" --opencode-db "$root/opencode.db"
rm "$root/opencode.db-wal"

"$harness" launch "$second" --app "$app"
[[ ! -e $second/opencode.db ]] || fail 'Missing OpenCode input must not be created.'
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
"$harness" launch "$first" --app "$app" --sessions "$root/fixtures" --opencode-db "$root/opencode.db"
[[ $(value "$first" pid) != "$pid" ]] || fail 'Stopped session did not relaunch.'
[[ $(wc -l < "$first/agent/sessions/synthetic.jsonl") -eq 1 ]] || fail 'Relaunch replaced the snapshot.'
[[ $(/usr/bin/sqlite3 "$first/opencode.db" 'SELECT tokens FROM synthetic;') == 200 ]] || fail 'Relaunch replaced the OpenCode snapshot.'
"$harness" status "$second" > "$root/other.txt"
grep -q 'State: running' "$root/other.txt" || fail 'Other session stopped.'
printf 'PASS: real-app lifecycle, isolation, snapshot reuse, capture guards, and cleanup ownership.\nArtifacts: %s\n' "$root"
