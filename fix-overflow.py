import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('v', ROOT / 'verify.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
base = ROOT / 'fix-evidence'
for version in ('head','fixed'):
    out = base / f'{version}-overflow'
    out.mkdir(exist_ok=True)
    root = v.ROOT / 'instances' / f'{version}-overflow'
    root.mkdir(parents=True,exist_ok=True)
    app = root / 'OverflowReview.app'
    if app.exists(): shutil.rmtree(app)
    shutil.copytree(v.ROOT / version / '.build/Agent Usage.app',app)
    v.c.run('codesign','--verify','--strict',str(app))
    digest = hashlib.sha256((app/'Contents/MacOS/AgentUsage').read_bytes()).hexdigest()
    assert digest == hashlib.sha256((v.ROOT/version/'.build/Agent Usage.app/Contents/MacOS/AgentUsage').read_bytes()).hexdigest()
    (out/'artifact.json').write_text(json.dumps({'commit':v.c.run('git','-C',str(v.ROOT/version),'rev-parse','HEAD'),'executable_sha256':digest,'copied_binary_verified':True,'auth_present':False},indent=2)+'\n')
    data = root / 'data'
    data.mkdir(exist_ok=True)
    sessions = data / 'sessions'
    if sessions.is_file(): sessions.unlink()
    sessions.mkdir(exist_ok=True)
    partial = (v.fixtures / 'partial/sessions/synthetic.jsonl').read_text()
    tool = json.loads(partial.splitlines()[1])
    tool['id'] = 'synthetic-tool'
    tool['message']['role'] = 'toolResult'
    # Already-recorded tiny usage, deliberately nonzero to exercise the real warning.
    tool['message']['usage']['input'] = 1
    tool['message']['usage']['output'] = 0
    (sessions/'synthetic.jsonl').write_text(partial + json.dumps(tool)+'\n')
    (out/'input.jsonl').write_text(partial + json.dumps(tool)+'\n')
    proc = subprocess.Popen([str(app/'Contents/MacOS/AgentUsage')],env={**v.os.environ,'PI_CODING_AGENT_DIR':str(data),'PI_CODING_AGENT_SESSION_DIR':str(sessions)},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    backdrop = subprocess.Popen([str(v.HELPER),'backdrop'])
    pid = proc.pid
    def capture(name):
        group = v.c.content_group(pid)
        window = v.c.bounds(pid,'window 1')
        title = v.c.bounds(pid,f'static text "Agent Usage" of {group}')
        footer = v.apple(pid,f'get {{position, size}} of last static text of {group}')
        contents = v.apple(pid,f'get entire contents of {group}')
        state = {'window':window,'title':title,'header_inset':title[1]-window[1], 'footer':footer,'contents':contents}
        (out/f'{name}.json').write_text(json.dumps(state,indent=2)+'\n')
        wx,wy,ww,wh = window
        v.c.run('screencapture','-x',f'-R{wx-10},0,{ww+20},{wy+wh+10}',str(out/f'{name}.png'))
        print(f'{version}/{name}: height={wh}, inset={title[1]-wy}, footer={footer}',flush=True)
        return state
    try:
        v.c.wait_for(lambda:v.c.bounds(pid,'menu bar item 1 of menu bar 2'),'status item')
        v.c.open_popover(pid,v.HELPER)
        time.sleep(1)
        capture('00-partial-tool')
        # Make the explicitly selected session root a file. This gives a real directory
        # read error while retaining the last partial/tool snapshot, without permissions tricks.
        backup = data/'saved-sessions'
        if backup.exists(): shutil.rmtree(backup)
        sessions.rename(backup)
        sessions.write_text('synthetic inaccessible session directory\n')
        v.refresh(pid)
        before = capture('01-overflow-top')
        assert before['window'][3] == 600, before
        group = v.c.content_group(pid)
        assert 'scroll area' in group, group
        actions = v.apple(pid,f'get name of every action of {group}')
        print('scroll actions:', actions,flush=True)
        # Native AX scrolling moves actual menu-bar content, not a component document.
        v.apple(pid,f'set value of scroll bar 1 of {group} to 1.0')
        time.sleep(.5)
        after = capture('02-overflow-scrolled')
        assert after['footer'] != before['footer'], (before,after)
        sessions.unlink()
        backup.rename(sessions)
        shutil.copyfile(v.fixtures/'ready/sessions/synthetic.jsonl',sessions/'synthetic.jsonl')
        # Header may have scrolled offscreen; close/reopen retains the same window.
        v.closed(pid)
        v.c.open_popover(pid,v.HELPER)
        time.sleep(1)
        recovered = capture('03-recovered')
        expected = 489 if version == 'fixed' else 600
        assert recovered['window'][3] == expected,recovered
        if version == 'fixed': assert recovered['header_inset'] == 20,recovered
    finally:
        proc.terminate(); proc.wait(timeout=10)
        backdrop.terminate(); backdrop.wait()
