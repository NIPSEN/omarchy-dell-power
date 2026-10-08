#!/usr/bin/python3
"""Test-copy bridge wrapper. Real snapshot implementation uses isolated state."""
import importlib.util
import json
import os
from pathlib import Path
import sys
root = Path(__file__).parent.parent
spec = importlib.util.spec_from_file_location('real_state', Path(__file__).with_name('real_state.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
flags = json.loads((root / 'flags.json').read_text()) if (root / 'flags.json').exists() else {}
operation = sys.argv[1] if len(sys.argv) > 1 else ''
try:
    if operation == 'save' and flags.get('fail-save'): raise ValueError('Fixture snapshot save failed')
    if operation == 'remember' and flags.get('fail-remember'): raise ValueError('Fixture preference save failed')
    if flags.get('isolated-ownership') and operation in {'load', 'ownership'}:
        result = {'ok': True, 'ownership': {'known': False, 'conflict': False, 'reason': 'isolated fixture'}}
        if operation == 'load':
            result['state'] = module.read_private(Path(os.environ['XDG_STATE_HOME']) / 'dell-power-extension/snapshots.json')
    else:
        result = module.main(sys.argv[1:])
except (ValueError, OSError) as error:
    result = {'ok': False, 'error': str(error)}
with (root / 'bridge.jsonl').open('a') as stream:
    stream.write(json.dumps({'operation': operation, 'ok': result.get('ok')}) + '\n')
print(json.dumps(result))
sys.exit(0 if result.get('ok') else 1)
