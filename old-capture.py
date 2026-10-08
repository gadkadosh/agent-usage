#!/usr/bin/env python3
"""Capture and check the actual release MenuBarExtra, never a replacement window."""
import argparse
import datetime
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def apple(script):
    return run("osascript", "-e", 'tell application "System Events"\n' + script + "\nend tell")


def bounds(pid, selector):
    result = apple(f"tell (first process whose unix id is {pid}) to get {{position, size}} of {selector}")
    return [int(value.strip()) for value in result.split(",")]


def content_group(pid):
    scroll = "scroll area 1 of group 1 of window 1"
    exists = apple(f"tell (first process whose unix id is {pid}) to get exists {scroll}")
    return scroll if exists == "true" else "group 1 of window 1"


def wait_for(action, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            result = action()
            if result:
                return result
        except (subprocess.CalledProcessError, ValueError):
            pass
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {description}. Check Accessibility/Automation permissions.")


def open_popover(pid, helper):
    # Status items can move while the previous capture app exits. Converge on an
    # open window, rather than assuming one click at cached coordinates succeeded.
    for _ in range(3):
        try:
            return bounds(pid, "window 1")
        except subprocess.CalledProcessError:
            pass
        bx, by, bw, bh = bounds(pid, "menu bar item 1 of menu bar 2")
        run(str(helper), "click", str(bx + bw // 2), str(by + bh // 2))
        for _ in range(10):
            time.sleep(0.2)
            try:
                return bounds(pid, "window 1")
            except subprocess.CalledProcessError:
                pass
    raise RuntimeError("Could not open the actual MenuBarExtra. Check input permissions.")


def history_fixture(root, state):
    # auth.json is deliberately absent: allowance fails before any HTTP request.
    if state == "missing":
        return
    sessions = root / "sessions"
    sessions.mkdir()
    now = datetime.datetime.now().astimezone()
    header = {"type": "session", "version": 99 if state == "unsupported" else 3,
              "id": "synthetic-capture", "timestamp": now.isoformat(), "cwd": "/synthetic"}
    lines = [json.dumps(header)]
    if state not in ("zero", "unsupported"):
        for day in range(30):
            stamp = now if day == 0 else now.replace(hour=12, minute=0, second=0) - datetime.timedelta(days=day)
            lines.append(json.dumps({"type": "message", "id": f"synthetic-{day}",
                                     "timestamp": stamp.isoformat(), "message": {
                                         "role": "assistant", "stopReason": "stop",
                                         "timestamp": int(stamp.timestamp() * 1000),
                                         "usage": {"input": 18000, "output": 420,
                                                   "cacheRead": 0, "cacheWrite": 0}}}))
    if state == "partial":
        lines.append("deliberately malformed synthetic record")
    (sessions / "synthetic.jsonl").write_text("\n".join(lines) + "\n")


def capture(pid, helper, output, name, period=1):
    if period != 1:
        selector = f"radio button {period} of radio group 1 of {content_group(pid)}"
        x, y, w, h = bounds(pid, selector)
        run(str(helper), "click", str(x + w // 2), str(y + h // 2))
        time.sleep(0.4)
    window = bounds(pid, "window 1")
    button = bounds(pid, "menu bar item 1 of menu bar 2")
    group = content_group(pid)
    title = bounds(pid, f'static text "Agent Usage" of {group}')
    wx, wy, ww, wh = window
    bx, by, bw, bh = button
    geometry = {"window": window, "status_item": button, "title": title}
    (output / f"{name}.json").write_text(json.dumps(geometry, indent=2) + "\n")
    # Include the menu bar, native chrome, entire popover and shadow. A neutral
    # external backdrop hides other apps; the app supplies every tested UI element.
    left, right = min(wx, bx) - 10, max(wx + ww, bx + bw) + 10
    run("screencapture", "-x", f"-R{left},0,{right-left},{wy+wh+10}", str(output / f"{name}.png"))
    if name.startswith("ready") or name == "partial":
        expected = 552600 if name in ("ready-month", "ready-reopened") else 128940 if period == 2 else 18420
        text = run(str(helper), "tokens", str(expected))
        present = apple(f'tell (first process whose unix id is {pid}) to get exists static text "{text}" of {group}')
        assert present == "true", f"Expected synthetic token total {expected} is not displayed"
    assert ww == 360 and wh <= 601, f"Unexpected viewport: {geometry}"
    assert 0 <= wy - (by + bh) <= 16, f"Popover detached from status item: {geometry}"
    assert 15 <= title[1] - wy <= 40, f"Content centered in stale native window: {geometry}"
    print(f"{name}: window={window}, title inset={title[1]-wy}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=ROOT / ".build/Agent Usage.app")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    executable = app / "Contents/MacOS/AgentUsage"
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    (output / "artifact.json").write_text(json.dumps({"executable_sha256": digest}, indent=2) + "\n")
    with tempfile.TemporaryDirectory(prefix="agent-usage-menu-capture-") as temporary:
        temporary = pathlib.Path(temporary)
        helper = temporary / "input-helper"
        run("xcrun", "swiftc", str(ROOT / "Tests/MenuBarCapture.swift"), "-o", str(helper))
        # Retag a byte-identical copy so capture never closes or replaces a user's app.
        copied = temporary / "AgentUsageCapture.app"
        shutil.copytree(app, copied)
        (copied / "Contents/MacOS/AgentUsage").rename(copied / "Contents/MacOS/AgentUsageCapture")
        plist = copied / "Contents/Info.plist"
        for key, value in [("CFBundleExecutable", "AgentUsageCapture"),
                           ("CFBundleName", "AgentUsageCapture"),
                           ("CFBundleIdentifier", "io.github.gadkadosh.AgentUsage.capture")]:
            run("plutil", "-replace", key, "-string", value, str(plist))
        run("codesign", "--force", "--sign", "-", str(copied))
        backdrop = subprocess.Popen([str(helper), "backdrop"])
        try:
            for state in ("missing", "ready", "partial", "unsupported", "zero"):
                root = temporary / state
                root.mkdir()
                history_fixture(root, state)
                pid = None
                try:
                    run("open", "-n", "--env", f"PI_CODING_AGENT_DIR={root}",
                        "--env", f"PI_CODING_AGENT_SESSION_DIR={root / 'sessions'}", str(copied))
                    pid = int(wait_for(lambda: apple('get unix id of first process whose name is "AgentUsageCapture"'),
                                       "capture app"))
                    wait_for(lambda: bounds(pid, "menu bar item 1 of menu bar 2"), "status item")
                    time.sleep(0.5)
                    open_popover(pid, helper)
                    # Wait for the real visibility-triggered synthetic file scan.
                    time.sleep(1)
                    capture(pid, helper, output, state)
                    if state == "ready":
                        capture(pid, helper, output, "ready-week", period=2)
                        capture(pid, helper, output, "ready-month", period=3)
                        # Native close/reopen, not reconstructing an NSHostingView.
                        bx, by, bw, bh = bounds(pid, "menu bar item 1 of menu bar 2")
                        run(str(helper), "click", str(bx + bw // 2), str(by + bh // 2))
                        wait_for(lambda: apple(f'tell (first process whose unix id is {pid}) to get exists window 1') == "false",
                                 "closed popover")
                        open_popover(pid, helper)
                        time.sleep(0.5)
                        capture(pid, helper, output, "ready-reopened")
                finally:
                    if pid is not None:
                        run("kill", str(pid))
                        time.sleep(0.3)
        finally:
            backdrop.terminate()
            backdrop.wait()


if __name__ == "__main__":
    main()
