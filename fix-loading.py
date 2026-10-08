import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import time

ROOT=pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('v',ROOT/'verify.py')
v=importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
outroot=ROOT/'fix-evidence'
for version in ('head','fixed'):
    out=outroot/f'{version}-loading'; out.mkdir(exist_ok=True)
    root=v.ROOT/'instances'/f'{version}-loading'; root.mkdir(parents=True,exist_ok=True)
    app=root/'LoadingReview.app'
    if app.exists(): shutil.rmtree(app)
    shutil.copytree(v.ROOT/version/'.build/Agent Usage.app',app)
    v.c.run('codesign','--verify','--strict',str(app))
    digest=hashlib.sha256((app/'Contents/MacOS/AgentUsage').read_bytes()).hexdigest()
    assert digest==hashlib.sha256((v.ROOT/version/'.build/Agent Usage.app/Contents/MacOS/AgentUsage').read_bytes()).hexdigest()
    (out/'artifact.json').write_text(json.dumps({'commit':v.c.run('git','-C',str(v.ROOT/version),'rev-parse','HEAD'),'executable_sha256':digest,'copied_binary_verified':True,'auth_present':False},indent=2)+'\n')
    data=root/'data'; data.mkdir(exist_ok=True)
    sessions=data/'sessions'; sessions.mkdir(exist_ok=True)
    lines=(v.fixtures/'ready/sessions/synthetic.jsonl').read_text().splitlines()
    message=json.loads(lines[1]); message['message']['content']=[{'type':'text','text':'synthetic padding '*64}]
    record=json.dumps(message)+'\n'
    count=(120*1024*1024)//len(record.encode())
    with (sessions/'synthetic.jsonl').open('w') as file:
        file.write(lines[0]+'\n')
        for _ in range(count): file.write(record)
    (out/'input.json').write_text(json.dumps({'generator':'Repeat first synthetic ready operation with harmless ignored content padding','record_count':count,'file_bytes':(sessions/'synthetic.jsonl').stat().st_size,'distinct_operations':1},indent=2)+'\n')
    proc=subprocess.Popen([str(app/'Contents/MacOS/AgentUsage')],env={**v.os.environ,'PI_CODING_AGENT_DIR':str(data),'PI_CODING_AGENT_SESSION_DIR':str(sessions)},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    backdrop=subprocess.Popen([str(v.HELPER),'backdrop'])
    pid=proc.pid
    try:
        v.c.wait_for(lambda:v.c.bounds(pid,'menu bar item 1 of menu bar 2'),'status item')
        v.c.open_popover(pid,v.HELPER)
        group=v.c.content_group(pid)
        assert v.apple(pid,f'get exists static text "Reading pi history…" of {group}')=='true'
        v.snapshot(pid,out,'00-loading','loading')
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            group=v.c.content_group(pid)
            if v.apple(pid,f'get exists static text "Reading pi history…" of {group}')=='false': break
            time.sleep(.5)
        else: raise AssertionError('History scan timed out')
        time.sleep(.5)
        # Same operation ID/timestamp deduplicates the repeated records.
        v.snapshot(pid,out,'01-ready','ready')
        shutil.copyfile(v.fixtures/'partial/sessions/synthetic.jsonl',sessions/'synthetic.jsonl')
        v.refresh(pid)
        v.snapshot(pid,out,'02-partial','partial')
        shutil.copyfile(v.fixtures/'ready/sessions/synthetic.jsonl',sessions/'synthetic.jsonl')
        v.refresh(pid)
        state=v.snapshot(pid,out,'03-ready-recovered','ready')
        if version=='fixed':
            assert state['window'][3]==489 and state['header_inset']==20,state
    finally:
        proc.terminate(); proc.wait(timeout=10)
        backdrop.terminate(); backdrop.wait()
