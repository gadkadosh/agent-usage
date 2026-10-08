#!/usr/bin/env python3
"""Native verification of unmodified packaged PR 18 and main executables."""
import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import os
import time

ROOT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('capture', ROOT / 'old-capture.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
HELPER = ROOT / 'helper'
OUT = ROOT / 'evidence'
OUT.mkdir(exist_ok=True)
fixtures = OUT / 'fixtures'
fixtures.mkdir(exist_ok=True)
for state in ('ready', 'partial', 'zero', 'unsupported'):
    path = fixtures / state
    if not path.exists():
        path.mkdir()
        c.history_fixture(path, state)


def apple(pid, command):
    return c.apple(f'tell (first process whose unix id is {pid}) to {command}')


def closed(pid):
    if apple(pid, 'get exists window 1') == 'true':
        x, y, w, h = c.bounds(pid, 'menu bar item 1 of menu bar 2')
        c.run(str(HELPER), 'click', str(x+w//2), str(y+h//2))
    c.wait_for(lambda: apple(pid, 'get exists window 1') == 'false', 'closed popover')


def snapshot(pid, directory, name, state, period=1):
    group = c.content_group(pid)
    window = c.bounds(pid, 'window 1')
    title = c.bounds(pid, f'static text "Agent Usage" of {group}')
    item = c.bounds(pid, 'menu bar item 1 of menu bar 2')
    contents = apple(pid, f'get entire contents of {group}')
    values = apple(pid, f'get value of every static text of {group}')
    selected = apple(pid, f'get value of radio button {period} of radio group 1 of {group}')
    warning = apple(pid, f'get exists static text "Partial history. Totals may be incomplete." of {group}')
    geometry = {'pid': pid, 'state': state, 'period': period, 'window': window,
                'status_item': item, 'title': title, 'header_inset': title[1]-window[1],
                'partial_warning': warning, 'selected': selected, 'text': values,
                'contents': contents}
    (directory / f'{name}.json').write_text(json.dumps(geometry, indent=2)+'\n')
    wx, wy, ww, wh = window
    bx, by, bw, bh = item
    left, right = min(wx, bx)-10, max(wx+ww, bx+bw)+10
    c.run('screencapture', '-x', f'-R{left},0,{right-left},{wy+wh+10}', str(directory / f'{name}.png'))
    assert selected == '1', geometry
    assert warning == ('true' if state == 'partial' else 'false'), geometry
    if state in ('ready', 'partial'):
        expected = {1:18420, 2:128940, 3:552600}[period]
        text = c.run(str(HELPER), 'tokens', str(expected))
        assert apple(pid, f'get exists static text "{text}" of {group}') == 'true', geometry
    assert ww == 360 and wh <= 601, geometry
    assert 0 <= wy-(by+bh) <= 16, geometry
    print(f'{directory.name}/{name}: pid={pid} height={wh} header_inset={geometry["header_inset"]} partial={warning}', flush=True)
    return geometry


def set_history(data, state):
    sessions = data / 'sessions'
    sessions.mkdir(exist_ok=True)
    file = sessions / 'synthetic.jsonl'
    if state == 'missing':
        file.unlink(missing_ok=True)
    else:
        shutil.copyfile(fixtures / state / 'sessions/synthetic.jsonl', file)


def refresh(pid):
    group = c.content_group(pid)
    apple(pid, f'click menu button "More options" of {group}')
    time.sleep(.2)
    # AppKit presents the options menu as an AXMenu owned by the menu button.
    apple(pid, f'click menu item "Refresh" of menu 1 of menu button "More options" of {group}')
    time.sleep(1)


def instance(version, initial, sequence, manual=False):
    directory = OUT / f'{version}-{initial}{"-manual" if manual else ""}'
    directory.mkdir(exist_ok=True)
    sandbox = ROOT / 'instances' / directory.name
    sandbox.mkdir(parents=True, exist_ok=True)
    source = ROOT / version / '.build/Agent Usage.app'
    app = sandbox / 'PR18Review.app'
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(source, app)
    binary = app / 'Contents/MacOS/AgentUsage'
    original_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    assert original_hash == hashlib.sha256((source / 'Contents/MacOS/AgentUsage').read_bytes()).hexdigest()
    c.run('codesign','--verify','--strict',str(app))
    data = sandbox / 'data'
    data.mkdir(exist_ok=True)
    assert not (data / 'auth.json').exists()
    set_history(data, initial)
    (directory / 'artifact.json').write_text(json.dumps({'commit': c.run('git','-C',str(ROOT / version),'rev-parse','HEAD'), 'executable_sha256':original_hash, 'copied_binary_verified':True, 'environment':{'PI_CODING_AGENT_DIR':str(data),'PI_CODING_AGENT_SESSION_DIR':str(data/'sessions')}, 'auth_present':False},indent=2)+'\n')
    pid = None
    try:
        process = subprocess.Popen([str(binary)], env={**os.environ, 'PI_CODING_AGENT_DIR':str(data), 'PI_CODING_AGENT_SESSION_DIR':str(data / 'sessions')}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pid = process.pid
        c.wait_for(lambda: c.bounds(pid,'menu bar item 1 of menu bar 2'),'status item')
        time.sleep(.5)
        c.open_popover(pid,HELPER)
        time.sleep(1)
        snapshot(pid,directory,'00-initial',initial)
        for n, state in enumerate(sequence,1):
            if not manual:
                closed(pid)
            set_history(data,state)
            if manual:
                refresh(pid)
            else:
                c.open_popover(pid,HELPER)
                time.sleep(1)
            snapshot(pid,directory,f'{n:02d}-{state}',state)
        if initial == 'ready' and not sequence:
            for period, name in [(2,'week'),(3,'month')]:
                apple(pid,f'click radio button {period} of radio group 1 of {c.content_group(pid)}')
                time.sleep(.5)
                snapshot(pid,directory,name,'ready',period)
            closed(pid)
            c.open_popover(pid,HELPER)
            time.sleep(1)
            snapshot(pid,directory,'month-reopened','ready',3)
    finally:
        if pid is not None:
            process.terminate()
            process.wait(timeout=10)
            time.sleep(.5)


if __name__ == '__main__':
    backdrop = subprocess.Popen([str(HELPER),'backdrop'])
    try:
        for version in ('base','head'):
            for initial in ('missing','ready','partial','unsupported','zero'):
                sequences = {'partial':['ready','partial','ready','missing','ready'],
                             'missing':['ready','partial','ready','missing']}
                instance(version,initial,sequences.get(initial, []))
            instance(version,'partial',['ready','partial','ready'],manual=True)
    finally:
        backdrop.terminate()
        backdrop.wait()
