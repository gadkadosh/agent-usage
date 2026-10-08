#!/usr/bin/env python3
"""Create and clean up an owned release-app session. Drive it with native tools."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def identity(pid):
    try:
        return {
            "pid": pid,
            "executable": run("ps", "-ww", "-p", str(pid), "-o", "comm="),
            "started": run("ps", "-p", str(pid), "-o", "lstart="),
        }
    except subprocess.CalledProcessError:
        return None


def terminate(process):
    current = identity(process["pid"])
    if current is None:
        return
    if current != process:
        raise RuntimeError(f"Refusing to stop an unrelated process: {current}")
    os.kill(process["pid"], signal.SIGTERM)
    for _ in range(50):
        if identity(process["pid"]) is None:
            return
        time.sleep(0.1)
    raise RuntimeError(f"Process {process['pid']} did not stop; scratch state was retained")


def seed(data, state):
    if state == "missing":
        return
    sessions = data / "sessions"
    sessions.mkdir()
    now = datetime.datetime.now().astimezone()
    lines = [json.dumps({"type": "session", "version": 99 if state == "unsupported" else 3,
                        "id": "synthetic-verification", "timestamp": now.isoformat(), "cwd": "/synthetic"})]
    if state not in ("zero", "unsupported"):
        for day in range(30):
            stamp = now if day == 0 else now.replace(hour=12, minute=0, second=0) - datetime.timedelta(days=day)
            lines.append(json.dumps({"type": "message", "id": f"synthetic-{day}", "timestamp": stamp.isoformat(),
                                     "message": {"role": "assistant", "stopReason": "stop",
                                                 "timestamp": int(stamp.timestamp() * 1000),
                                                 "usage": {"input": 18000, "output": 420,
                                                           "cacheRead": 0, "cacheWrite": 0}}}))
    if state == "partial":
        lines.append("deliberately malformed synthetic record")
    (sessions / "synthetic.jsonl").write_text("\n".join(lines) + "\n")


def start(app, output, state):
    output.mkdir(parents=True, exist_ok=True)
    record = output / "session.json"
    if record.exists():
        session = json.loads(record.read_text())
        if session["source_app"] != str(app):
            raise RuntimeError("Output belongs to a different build; use a fresh output directory")
        if not session.get("stopped") and all(identity(session[key]["pid"]) == session[key] for key in ("app", "backdrop")):
            return session  # Do not reset a live session or its edited inputs.
        raise RuntimeError("Output already contains an ended session; use a fresh output directory")
    work = Path(tempfile.mkdtemp(prefix="agent-usage-verify-"))
    session = {"work": str(work), "source_app": str(app), "output": str(output)}
    processes = []
    try:
        copied = work / "Agent Usage.app"
        shutil.copytree(app, copied)
        executable = copied / "Contents/MacOS/AgentUsage"
        session["source_executable_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        run("plutil", "-replace", "CFBundleIdentifier", "-string",
            f"io.github.gadkadosh.AgentUsage.verify.{uuid.uuid4().hex}", str(copied / "Contents/Info.plist"))
        run("codesign", "--force", "--sign", "-", "--timestamp=none", str(copied))
        run("codesign", "--verify", "--strict", str(copied))
        session["launched_executable_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        helper = work / "native-input"
        run("xcrun", "swiftc", str(HERE / "NativeInput.swift"), "-o", str(helper))
        session["input"] = str(helper)
        data = work / "data"
        data.mkdir()
        seed(data, state)
        session["data"] = str(data)
        with (output / "launch.log").open("w") as log:
            for key, command, environment in [
                ("backdrop", [str(helper), "backdrop"], os.environ),
                ("app", [str(executable)], {**os.environ, "PI_CODING_AGENT_DIR": str(data),
                                          "PI_CODING_AGENT_SESSION_DIR": str(data / "sessions")}),
            ]:
                process = subprocess.Popen(command, env=environment, stdout=log, stderr=log, start_new_session=True)
                processes.append(process)
                time.sleep(0.2)
                if process.poll() is not None:
                    raise RuntimeError(f"{key} exited at launch; see {output / 'launch.log'}")
                session[key] = identity(process.pid)
        record.write_text(json.dumps(session, indent=2) + "\n")
        return session
    except BaseException:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        shutil.rmtree(work)
        raise


def stop(record):
    session = json.loads(record.read_text())
    if session.get("stopped"):
        return
    work = Path(session["work"])
    if (work.parent != Path(tempfile.gettempdir()) or not work.name.startswith("agent-usage-verify-")
            or session["app"]["executable"] != str(work / "Agent Usage.app/Contents/MacOS/AgentUsage")
            or session["backdrop"]["executable"] != str(work / "native-input")):
        raise RuntimeError("Refusing cleanup of an unrecognized scratch directory")
    # Validate both identities before stopping either process.
    for key in ("app", "backdrop"):
        current = identity(session[key]["pid"])
        if current is not None and current != session[key]:
            raise RuntimeError(f"Refusing to stop an unrelated process: {current}")
    for key in ("app", "backdrop"):
        terminate(session[key])
    shutil.rmtree(work, ignore_errors=True)
    session["stopped"] = True
    record.write_text(json.dumps(session, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    launch = commands.add_parser("start")
    launch.add_argument("--app", type=Path, default=ROOT / ".build/Agent Usage.app")
    launch.add_argument("--output", type=Path, required=True)
    launch.add_argument("--history", choices=("ready", "partial", "missing", "unsupported", "zero"), default="ready")
    cleanup = commands.add_parser("stop")
    cleanup.add_argument("--session", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "start":
        print(json.dumps(start(args.app.resolve(), args.output.resolve(), args.history), indent=2))
    else:
        stop(args.session.resolve())


if __name__ == "__main__":
    main()
