import importlib.util
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('verify', root / 'verify.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
v.OUT = root / 'fix-evidence'
v.OUT.mkdir(exist_ok=True)
backdrop = subprocess.Popen([str(v.HELPER), 'backdrop'])
try:
    for initial in ('missing', 'ready', 'partial', 'unsupported', 'zero'):
        sequences = {'partial':['ready','partial','ready','missing','ready'],
                     'missing':['ready','partial','ready','missing']}
        v.instance('fixed', initial, sequences.get(initial, []))
    v.instance('fixed','partial',['ready','partial','ready'],manual=True)
finally:
    backdrop.terminate()
    backdrop.wait()

import json
failures = []
for directory in ('missing','partial','partial-manual'):
    for path in sorted((v.OUT / f'fixed-{directory}').glob('*.json')):
        if path.name in ('artifact.json','00-initial.json'):
            continue
        actual = json.loads(path.read_text())
        fresh = json.loads((v.OUT / f'fixed-{actual["state"]}' / '00-initial.json').read_text())
        if (actual['window'][2:],actual['header_inset']) != (fresh['window'][2:],fresh['header_inset']):
            failures.append(path.name)
assert not failures, failures
print('All retained native sizes and header insets match fresh equivalents.')
