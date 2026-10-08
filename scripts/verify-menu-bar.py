#!/usr/bin/env python3
"""Bounded CI smoke checks. For exploratory driving, use the verification skill."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
SESSION = ROOT / ".agents/skills/verification/scripts/session.py"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def apple(pid, action):
    return run("osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to {action}')


def bounds(pid, selector):
    return [int(value.strip()) for value in apple(pid, f"get {{position, size}} of {selector}").split(",")]


def content(pid):
    scroll = "scroll area 1 of group 1 of window 1"
    return scroll if apple(pid, f"get exists {scroll}") == "true" else "group 1 of window 1"


def wait_for(action, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = action()
            if result:
                return result
        except (subprocess.CalledProcessError, ValueError):
            pass
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {description}; inspect the UI state and desktop/Accessibility permissions")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/Agent Usage.app")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError("Use a fresh output directory so previous evidence is not overwritten")
    ready_height = None
    with (output / "actions.log").open("w") as log:
        for state in ("missing", "ready", "partial", "unsupported", "zero"):
            directory = output / state
            record = directory / "session.json"
            try:
                run("python3", str(SESSION), "start", "--app", str(args.app.resolve()),
                    "--output", str(directory), "--history", state)
                session = json.loads(record.read_text())
                pid = session["app"]["pid"]
                helper = session["input"]

                def action(message):
                    log.write(f"{state}: {message}\n")
                    log.flush()

                def status_click():
                    x, y, w, h = bounds(pid, "menu bar item 1 of menu bar 2")
                    action("click native status item")
                    run(helper, "click", str(x + w // 2), str(y + h // 2))

                def open_window():
                    wait_for(lambda: bounds(pid, "menu bar item 1 of menu bar 2"), "status item")
                    for _ in range(3):
                        if apple(pid, "get exists window 1") == "true":
                            return
                        status_click()
                        try:
                            wait_for(lambda: apple(pid, "get exists window 1") == "true", "open menu-bar window")
                            return
                        except RuntimeError:
                            pass
                    raise RuntimeError("Native status click did not open the menu-bar window")

                def tokens():
                    label = apple(pid, f'get name of first static text of {content(pid)} whose name ends with " observed tokens"')
                    return int(re.sub(r"\D", "", label))

                def period(description, expected):
                    action(f"click period {description}")
                    apple(pid, f'click (first radio button of radio group 1 of {content(pid)} whose description is "{description}")')
                    wait_for(lambda: tokens() == expected, f"{description} token total {expected}")

                def partial_warning():
                    return apple(pid, f'get exists static text "Partial history. Totals may be incomplete." of {content(pid)}') == "true"

                def capture(name, expected=None):
                    action(f"capture {name}")
                    group = content(pid)
                    window = bounds(pid, "window 1")
                    button = bounds(pid, "menu bar item 1 of menu bar 2")
                    title = bounds(pid, f'static text "Agent Usage" of {group}')
                    geometry = {"window": window, "status_item": button, "title": title}
                    (output / f"{name}.json").write_text(json.dumps(geometry, indent=2) + "\n")
                    (output / f"{name}.ax.txt").write_text(apple(pid, "get entire contents of window 1") + "\n")
                    (output / f"{name}.controls.txt").write_text(apple(pid, f"get {{name, description}} of menu buttons of {group}") + "\n")
                    wx, wy, ww, wh = window
                    bx, by, bw, bh = button
                    left, right = min(wx, bx) - 10, max(wx + ww, bx + bw) + 10
                    run("screencapture", "-x", f"-R{left},0,{right-left},{wy+wh+10}", str(output / f"{name}.png"))
                    if expected is not None:
                        assert tokens() == expected, f"Expected {expected} tokens"
                    assert ww == 360 and 0 < wh <= 601, f"Unexpected viewport: {geometry}"
                    assert 0 <= wy - (by + bh) <= 16, f"Detached popover: {geometry}"
                    assert 15 <= title[1] - wy <= 40, f"Content centered in stale native window: {geometry}"
                    print(f"{name}: window={window}, title inset={title[1]-wy}", flush=True)
                    return wh

                open_window()
                wait_for(lambda: "Updated:" in apple(pid, f"get name of static texts of {content(pid)}"), "visibility-triggered history scan")
                expected = {"ready": 18420, "partial": 18420, "zero": 0}.get(state)
                if expected is not None:
                    wait_for(lambda: tokens() == expected, "synthetic Today total")
                if state == "partial":
                    wait_for(partial_warning, "partial-history warning")
                else:
                    empty = {
                        "missing": "No pi history found. Missing history isn't zero usage.",
                        "unsupported": "Pi history was found, but its session format isn't supported yet.",
                    }.get(state)
                    if empty:
                        wait_for(lambda: apple(pid, f'get exists static text "{empty}" of {content(pid)}') == "true", f"{state} presentation")
                wait_for(lambda: apple(pid, f'get exists static text "Allowance unavailable" of {content(pid)}') == "true", "no-credentials allowance failure")
                height = capture(state, expected)
                if state == "ready":
                    ready_height = height
                    period("7 days", 128940)
                    capture("ready-week", 128940)
                    period("30 days", 552600)
                    capture("ready-month", 552600)
                    status_click()
                    wait_for(lambda: apple(pid, "get exists window 1") == "false", "closed window")
                    open_window()
                    wait_for(lambda: tokens() == 552600, "retained period after reopening")
                    capture("ready-reopened", 552600)
                elif state == "partial":
                    path = Path(session["data"]) / "sessions/synthetic.jsonl"
                    action("remove malformed record without restarting app; click More options > Refresh")
                    path.write_text("\n".join(path.read_text().splitlines()[:-1]) + "\n")
                    group = content(pid)
                    options = f'menu button "More options" of {group}'
                    if apple(pid, f"get exists {options}") != "true":
                        assert apple(pid, f"get count of menu buttons of {group}") == "1", "Options menu is ambiguous"
                        options = f"menu button 1 of {group}"
                    def refresh_item():
                        # Observed native trees: local menu under the button; macOS 15
                        # menu beside the scroll area, under the window's root group.
                        for menu in (f"menu 1 of {options}", "menu 1 of group 1 of window 1"):
                            selector = f'menu item "Refresh" of {menu}'
                            if apple(pid, f"get exists {selector}") == "true":
                                return selector
                        return None

                    apple(pid, f"click {options}")
                    try:
                        refresh = wait_for(refresh_item, "accessible options menu", timeout=2)
                    except RuntimeError:
                        action("no exposed Refresh item after accessibility click; use native mouse fallback")
                        x, y, w, h = bounds(pid, options)
                        run(helper, "click", str(x + w // 2), str(y + h // 2))
                        refresh = wait_for(refresh_item, "open options menu")
                    (output / "options.ax.txt").write_text(apple(pid, "get entire contents of window 1") + "\n")
                    apple(pid, f"click {refresh}")
                    wait_for(lambda: not partial_warning() and tokens() == 18420, "same-window recovery")
                    recovered = capture("partial-recovered", 18420)
                    assert abs(recovered - ready_height) <= 1, "Recovered native height differs from fresh ready window"
                    action("repeat setup; require same PID and preserved edited inputs")
                    repeated = json.loads(run("python3", str(SESSION), "start", "--app", str(args.app.resolve()),
                                              "--output", str(directory), "--history", state))
                    assert repeated["app"] == session["app"] and "malformed" not in path.read_text()
            except Exception:
                if record.exists():
                    # The owned backdrop is still up. Preserve diagnostic pixels even
                    # when the accessibility hierarchy cannot be inspected.
                    subprocess.run(["screencapture", "-x", str(output / f"{state}-failure.png")], check=False)
                raise
            finally:
                if record.exists():
                    run("python3", str(SESSION), "stop", "--session", str(record))
                    run("python3", str(SESSION), "stop", "--session", str(record))
                    assert json.loads(record.read_text())["stopped"]
                    assert not Path(json.loads(record.read_text())["work"]).exists()


if __name__ == "__main__":
    main()
