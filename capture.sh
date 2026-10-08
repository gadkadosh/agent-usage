#!/bin/bash
# Capture the packaged app, using synthetic local history and no credentials/networking.
set -euo pipefail
repo=$(cd "$1" && pwd)
mkdir -p "$2"
run=$(cd "$2" && pwd)
prefix=$3
script_dir=$(cd "$(dirname "$0")" && pwd)
if pgrep -x ChartQA >/dev/null; then
  echo 'Quit the existing ChartQA verification instance first.' >&2
  exit 1
fi
cd "$repo"
DEVELOPER_DIR=/Library/Developer/CommandLineTools make app
app="$run/Chart QA.app"
rm -rf "$app"
cp -R '.build/Agent Usage.app' "$app"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.gadkadosh.AgentUsage.ChartQA' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Chart QA' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable ChartQA' "$plist"
mv "$app/Contents/MacOS/AgentUsage" "$app/Contents/MacOS/ChartQA"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
# Reuse exactly the same input for before/after.
python3 - "$run" <<'PY'
import datetime, json, pathlib, sys
root = pathlib.Path(sys.argv[1]) / 'fixture'
(root / 'sessions').mkdir(parents=True, exist_ok=True)
(root / 'auth.json').write_text('{}\n')
fixture = root / 'sessions/chart.jsonl'
if not fixture.exists():
    now = datetime.datetime.now().astimezone()
    rows = [dict(type='session', version=3, id='synthetic-chart',
                 timestamp=now.isoformat(), cwd='/synthetic')]
    for day in range(30):
        for hour in range(24):
            timestamp = (now - datetime.timedelta(days=day)).replace(
                hour=hour, minute=0, second=0, microsecond=0)
            if timestamp > now:
                continue
            rows.append(dict(type='message', id=f'd{day}h{hour}',
                timestamp=timestamp.isoformat(), message=dict(role='assistant',
                stopReason='stop', timestamp=int(timestamp.timestamp()*1000),
                usage=dict(input=1000+(day%7)*200+hour*50, output=100,
                           cacheRead=0, cacheWrite=0))))
    fixture.write_text('\n'.join(json.dumps(row) for row in rows) + '\n')
PY
open -n "$app" --env "PI_CODING_AGENT_DIR=$run/fixture" \
  --env "PI_CODING_AGENT_SESSION_DIR=$run/fixture/sessions"
sleep 2
pid=$(osascript -e 'tell application "System Events" to tell process "ChartQA" to get unix id')
trap 'kill "$pid" 2>/dev/null || true' EXIT
osascript -e 'tell application "System Events" to tell process "ChartQA" to perform action "AXPress" of menu bar item 1 of menu bar 2'
sleep 1
if [[ $(osascript -e 'tell application "System Events" to tell process "ChartQA" to count windows') == 0 ]]; then
  # On macOS 27 AXPress on MenuBarExtra is a no-op. Emit a native click instead.
  point=$(osascript -e 'tell application "System Events" to tell process "ChartQA"' \
    -e 'set {x, y} to position of menu bar item 1 of menu bar 2' \
    -e 'set {w, h} to size of menu bar item 1 of menu bar 2' \
    -e 'return ((x + w / 2) as integer) & " " & ((y + h / 2) as integer) as text' \
    -e 'end tell')
  swift "$script_dir/native.swift" $point
fi
sleep 2
window=$(swift "$script_dir/native.swift")
for index in 1 2 3; do
  case "$index" in 1) period=today;; 2) period=week;; 3) period=month;; esac
  osascript -e 'tell application "System Events" to tell process "ChartQA"' \
    -e "click radio button $index of radio group 1 of group 1 of window 1" \
    -e 'delay 1' \
    -e 'get value of radio buttons of radio group 1 of group 1 of window 1' \
    -e 'end tell'
  screencapture -x -o -l "$window" "$run/$prefix-$period.png"
done
