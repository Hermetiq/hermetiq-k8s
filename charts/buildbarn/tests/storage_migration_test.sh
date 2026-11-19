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

def render(extra_sets=()):
    cmd = ['helm', 'template', 'test', str(chart), '-f', str(chart / 'ci-values/ci.yaml')]
    for item in extra_sets:
        cmd += ['--set', item]
    docs = list(yaml.safe_load_all(subprocess.check_output(cmd, text=True)))
    storage = next(d for d in docs if d and d['kind'] == 'StatefulSet' and d['metadata']['name'] == 'storage')
    return next(c['command'][2] for c in storage['spec']['template']['spec']['initContainers'] if c['name'] == 'volume-init')


def snapshot(root):
    dirs = sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_dir())
    files = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
    return dirs, files


def rewrite_paths(script, root, mounts):
    # Replace longest paths first so /storage-cas-meta is never partially rewritten as /storage-cas.
    for mount in sorted(mounts, key=len, reverse=True):
        script = script.replace(mount, str(root / mount.lstrip('/')))
    return script


# 1. Exercise legacy CAS, AC, ISCC, and FSAC guards in both filesystem and raw+file-KLM modes.
for raw in (False, True):
    extra = [
        'storage.persistence.iscc.enabled=true',
        'storage.persistence.fsac.enabled=true',
    ]
    if raw:
        extra += [
            'storage.persistence.cas.backend=blockDevice',
            'storage.persistence.cas.blockDevice.keyLocationMap=file',
            'storage.persistence.ac.backend=blockDevice',
            'storage.persistence.ac.blockDevice.keyLocationMap=file',
        ]
    script = render(extra)
    mounts = [
        '/storage-cas-meta' if raw else '/storage-cas',
        '/storage-ac-meta' if raw else '/storage-ac',
        '/storage-iscc',
        '/storage-fsac',
    ]
    store_cases = [
        ('cas', mounts[0], ('cas-keys.db', 'cas-blocks.db', 'persistent_state')),
        ('ac', mounts[1], ('ac-keys.db', 'ac-blocks.db', 'persistent_state')),
        ('iscc', '/storage-iscc', ('iscc-keys.db', 'iscc-blocks.db', 'persistent_state')),
        ('fsac', '/storage-fsac', ('fsac-keys.db', 'fsac-blocks.db', 'persistent_state')),
    ]
    for store, mount, legacy_names in store_cases:
        for legacy in legacy_names:
            with tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                for m in mounts:
                    (root / m.lstrip('/')).mkdir()
                store_dir = root / mount.lstrip('/')
                target = store_dir / legacy
                if legacy == 'persistent_state':
                    target.mkdir()
                    (target / 'checkpoint').write_bytes(b'legacy state must be untouched')
                else:
                    target.write_bytes(b'legacy bytes must be untouched')
                before = snapshot(root)
                local_script = rewrite_paths(script, root, mounts)
                for attempt in range(2):
                    result = subprocess.run(['sh', '-c', local_script], capture_output=True, text=True)
                    assert result.returncode != 0, (raw, store, legacy, 'legacy store accepted')
                    assert f'Pre-CDC {store.upper()} files detected' in result.stderr, result.stderr
                    # Snapshot verifies neither files NOR stray directories were created on any mount.
                    assert before == snapshot(root), (raw, store, legacy, 'filesystem mutated on rejected upgrade')
                # Model an operator explicitly retiring the legacy files after a
                # snapshot. The chart itself must never perform this removal.
                if target.is_dir():
                    (target / 'checkpoint').unlink()
                    target.rmdir()
                else:
                    target.unlink()
                cas_dir = root / mounts[0].lstrip('/')
                ac_dir = root / mounts[1].lstrip('/')
                for attempt in range(2):
                    subprocess.run(['sh', '-c', local_script], check=True)
                    assert (cas_dir / 'cdc-v1/persistent_state').is_dir()
                    assert (cas_dir / 'cdc-v1/cms_persistent_state').is_dir()
                    assert (ac_dir / 'cdc-v1/persistent_state').is_dir()
                    assert (root / 'storage-iscc/cdc-v1/persistent_state').is_dir()
                    assert (root / 'storage-fsac/cdc-v1/persistent_state').is_dir()
                    sentinel = cas_dir / 'cdc-v1/persistent_state/sentinel'
                    if attempt:
                        assert sentinel.read_bytes() == b'CDC state survives init'
                    sentinel.write_bytes(b'CDC state survives init')

# 2. Dedicated CMS filesystem mode creates /storage-cms/persistent_state alongside cdc-v1 stores.
dedicated_script = render(['storage.persistence.cms.backend=filesystem', 'storage.persistence.cms.size=4Gi'])
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    mounts = ['/storage-cas', '/storage-cms', '/storage-ac']
    for m in mounts:
        (root / m.lstrip('/')).mkdir()
    subprocess.run(['sh', '-c', rewrite_paths(dedicated_script, root, mounts)], check=True)
    assert (root / 'storage-cas/cdc-v1/persistent_state').is_dir()
    assert not (root / 'storage-cas/cdc-v1/cms_persistent_state').exists()
    assert (root / 'storage-cms/persistent_state').is_dir()
    assert (root / 'storage-ac/cdc-v1/persistent_state').is_dir()

print('Storage format guard rejects legacy CAS/AC/ISCC/FSAC files without mutating files or dirs; CDC init is repeatable.')
PY
