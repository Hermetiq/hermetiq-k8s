#!/usr/bin/env bash
# Exercise the rendered init script against real files, including repeated
# starts. No Docker/Kubernetes dependency; container RPC tests run separately.
set -euo pipefail
python3 - "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" <<'PY'
import pathlib
import subprocess
import sys
import tempfile

import yaml

chart = pathlib.Path(sys.argv[1])

def render(raw=False):
    cmd = ['helm', 'template', 'test', str(chart), '-f', str(chart / 'ci-values/ci.yaml')]
    if raw:
        cmd += ['--set', 'storage.persistence.cas.backend=blockDevice',
                '--set', 'storage.persistence.cas.blockDevice.keyLocationMap=file']
    docs = list(yaml.safe_load_all(subprocess.check_output(cmd, text=True)))
    storage = next(d for d in docs if d and d['kind'] == 'StatefulSet' and d['metadata']['name'] == 'storage')
    return next(c['command'][2] for c in storage['spec']['template']['spec']['initContainers'] if c['name'] == 'volume-init')

for raw in (False, True):
    script = render(raw)
    for legacy in ('cas-keys.db', 'cas-blocks.db', 'persistent_state'):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            cas = root / ('storage-cas-meta' if raw else 'storage-cas')
            ac = root / 'storage-ac'
            cas.mkdir()
            ac.mkdir()
            target = cas / legacy
            if legacy == 'persistent_state':
                target.mkdir()
                (target / 'checkpoint').write_bytes(b'legacy state must be untouched')
            else:
                target.write_bytes(b'legacy bytes must be untouched')
            before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            local_script = script.replace('/storage-cas-meta', str(root / 'storage-cas-meta')).replace('/storage-ac', str(ac)) if raw else script.replace('/storage-cas', str(cas)).replace('/storage-ac', str(ac))
            for attempt in range(2):
                result = subprocess.run(['sh', '-c', local_script], capture_output=True, text=True)
                assert result.returncode != 0, (raw, legacy, 'legacy CAS accepted')
                assert 'Pre-CDC CAS files detected' in result.stderr, result.stderr
                assert before == {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
                assert not (cas / 'cdc-v1').exists(), 'allocated CDC storage before migration'
            # Model an operator explicitly retiring the legacy files after a
            # snapshot. The chart itself must never perform this removal.
            if target.is_dir():
                (target / 'checkpoint').unlink()
                target.rmdir()
            else:
                target.unlink()
            for attempt in range(2):
                subprocess.run(['sh', '-c', local_script], check=True)
                assert (cas / 'cdc-v1/persistent_state').is_dir()
                assert (cas / 'cms_persistent_state').is_dir()
                sentinel = cas / 'cdc-v1/persistent_state/sentinel'
                if attempt:
                    assert sentinel.read_bytes() == b'CDC state survives init'
                sentinel.write_bytes(b'CDC state survives init')
print('Storage format guard rejects legacy files without modifying them; CDC init is repeatable.')
PY
