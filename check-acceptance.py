#!/usr/bin/env python3
"""Compare retained native geometry with freshly opened equivalents."""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent / 'evidence'
failures = []
for version in ('base', 'head'):
    for directory in ('missing', 'partial', 'partial-manual'):
        for path in sorted((root / f'{version}-{directory}').glob('*.json')):
            if path.name in ('artifact.json', '00-initial.json'):
                continue
            actual = json.loads(path.read_text())
            fresh = json.loads((root / f'{version}-{actual["state"]}' / '00-initial.json').read_text())
            expected = (fresh['window'][2:], fresh['header_inset'])
            observed = (actual['window'][2:], actual['header_inset'])
            if observed != expected:
                failures.append(f'{path.parent.name}/{path.stem}: expected size/inset={expected}; actual={observed}')
for failure in failures:
    print('FAIL:', failure)
print(f'{len(failures)} retained-window geometry failures.')
sys.exit(bool(failures))
