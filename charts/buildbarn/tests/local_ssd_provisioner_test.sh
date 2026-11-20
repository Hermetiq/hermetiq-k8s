#!/usr/bin/env bash
# Exercise the actual DaemonSet shell with fake devices and stubbed privileged
# tools. No cluster, real block device, mount, LVM command or root access is used.
set -euo pipefail
python3 - "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

import yaml

repo = pathlib.Path(sys.argv[1])
manifest = repo / 'custom-values/partition-ephemeral-disks-daemonset.yaml'
daemonset = next(x for x in yaml.safe_load_all(manifest.read_text()) if x['kind'] == 'DaemonSet')
pod = daemonset['spec']['template']['spec']
container = pod['containers'][0]
source = container['command'][2]
mount = next(x for x in container['volumeMounts'] if x['name'] == 'metadata-parent')
assert mount == {'name': 'metadata-parent', 'mountPath': '/mnt/stateful_partition/buildbarn-local-ssd',
                 'mountPropagation': 'Bidirectional'}, mount
volume = next(x for x in pod['volumes'] if x['name'] == 'metadata-parent')
assert volume['hostPath']['path'] == mount['mountPath']
assert container['readinessProbe']['exec']['command'] == ['/bin/sh', '/tmp/check-metadata-ready']
initializer = pod['initContainers'][0]
assert pod['hostPID'] is True and initializer['securityContext']['privileged'] is True
assert not any(mount.get('mountPropagation') == 'Bidirectional' for mount in initializer.get('volumeMounts', []))

# One executable implements every potentially privileged/host-dependent tool.
# All other commands operate strictly on paths rewritten into this temp tree.
stub = r'''#!PYTHON
import json, os, pathlib, signal, subprocess, sys
root = pathlib.Path(os.environ['STUB_ROOT'])
state_path = root / 'state.json'
s = json.loads(state_path.read_text())
cmd, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
s['events'].append([cmd, *args])
code, output = 0, ''
if cmd == 'apk':
    pass
elif cmd == 'nsenter':
    assert args[:8] == ['--target', '1', '--mount', '--root', '--wd', '--', '/bin/sh', '-ec']
    state_path.write_text(json.dumps(s))
    sys.exit(subprocess.run(args[args.index('--') + 1:]).returncode)
elif cmd == 'mountpoint':
    assert args == ['-q', str(root / 'host-parent')]
    code = 0 if s['parent_bound'] else 1
elif cmd == 'mount' and args[-1] == str(root / 'host-parent'):
    if args[0] == '--bind':
        assert args == ['--bind', str(root / 'host-parent'), str(root / 'host-parent')]
        assert not s['parent_bound']
        s['parent_bound'] = True
    else:
        assert args == ['--make-rshared', str(root / 'host-parent')]
        assert s['parent_bound'], 'only the dedicated self-bind may be shared'
        s['parent_shared'] = True
elif cmd == 'curl':
    label = json.loads(args[args.index('-d') + 1])['metadata']['labels']['hermetiq/ephemeral-lvm']
    if s.get('label_failure') and label is None:
        code = 22
    else:
        s['labels'].append(label)
elif cmd == 'vgs':
    if not s['vg']:
        code = 5
    elif '-o' in args:
        output = ' vg-uuid\n'
elif cmd == 'lvs':
    name = args[-1].split('/')[-1]
    if name not in s['lvs']:
        code = 5
    elif '-o' in args:
        output = ' ' + s['lvs'][name] + '\n'
elif cmd == 'vgcreate':
    assert not s['vg']
    s['vg'] = True
elif cmd == 'vgchange':
    assert args == ['--activate', 'y', '--activationmode', 'complete', 'ephemeral']
    assert s['vg'] and set(s['lvs']) == {'meta', 'cas', 'ac', 'iscc', 'fsac'}
    if s.get('activation_failure'):
        code = 5
    else:
        for name in s['lvs']:
            (root / 'dev/ephemeral' / name).touch()
elif cmd == 'lvcreate':
    name = args[args.index('--name') + 1]
    assert name not in s['lvs'], 'existing LV must never be recreated'
    s['lvs'][name] = name + '-uuid'
    (root / 'dev/ephemeral' / name).touch()
elif cmd == 'mkfs.ext4':
    assert not s['fstype'], 'existing filesystem must never be formatted'
    s['fstype'], s['fsuuid'] = 'ext4', 'filesystem-uuid'
elif cmd == 'blkid':
    field = args[args.index('-s') + 1]
    output = s['fstype'] if field == 'TYPE' else s['fsuuid']
    code = 0 if output else 2
elif cmd == 'findmnt':
    assert '--mountpoint' in args, 'must check the exact mount, not its parent'
    target = pathlib.Path(args[args.index('--mountpoint') + 1])
    assert target in (root / 'metadata', root / 'run/buildbarn-metadata-staging')
    staged = target.name == 'buildbarn-metadata-staging'
    if not s['staged' if staged else 'mounted']:
        code = 1
    elif '-o' in args:
        field = args[args.index('-o') + 1]
        output = {'FSTYPE': s['fstype'] if staged else s['mounted_type'],
                  'UUID': s['fsuuid'] if staged else s['mounted_uuid'], 'OPTIONS': 'rw,noatime'}[field]
elif cmd == 'mount':
    bind = '--bind' in args
    target = root / ('metadata' if bind else 'run/buildbarn-metadata-staging')
    assert args[-2] == str(root / ('run/buildbarn-metadata-staging' if bind else 'dev/ephemeral/meta'))
    assert args[-1] == str(target)
    if bind:
        assert s['staged'], 'must stage privately before publishing'
        assert (root / 'filesystem/.buildbarn-layout-v1').is_file(), 'must create marker before publishing'
    if not s.get('mount_disappears'):
        target.rmdir()
        target.symlink_to(root / 'filesystem')
        s['mounted' if bind else 'staged'] = True
        if bind:
            s['mounted_type'], s['mounted_uuid'] = s['fstype'], s['fsuuid']
elif cmd == 'chown':
    assert args[0] == '65534:65534'
    s['owners'][str(pathlib.Path(args[-1]).resolve())] = args[0]
elif cmd == 'stat':
    path = pathlib.Path(args[-1])
    if not path.is_dir():
        code = 1
    else:
        output = s['owners'].get(str(path.resolve()), '0:0') + ':' + oct(path.stat().st_mode & 0o777)[2:]
elif cmd == 'sleep':
    # End a successful daemon run after its first ready iteration, including
    # the normal signal/EXIT traps that must revoke the scheduling label.
    if s.get('lose_mount_after_ready'):
        s['mounted'] = False
    else:
        os.kill(os.getppid(), signal.SIGTERM)
elif cmd == 'readlink':
    output = str(pathlib.Path(args[-1]).resolve())
else:
    raise AssertionError('unexpected stub command: ' + cmd)
state_path.write_text(json.dumps(s))
if output:
    print(output.strip())
sys.exit(code)
'''.replace('#!PYTHON', '#!' + sys.executable)


def run_initializer(already_bound):
    with tempfile.TemporaryDirectory(prefix='local-ssd-parent-') as directory:
        root = pathlib.Path(directory)
        (root / 'bin').mkdir()
        (root / 'state.json').write_text(json.dumps(dict(events=[], parent_bound=already_bound, parent_shared=False)))
        stub_path = root / 'bin/stub'
        stub_path.write_text(stub)
        stub_path.chmod(0o755)
        for command in ('apk', 'nsenter', 'mountpoint', 'mount'):
            (root / 'bin' / command).symlink_to(stub_path)
        script = initializer['command'][2].replace('/mnt/stateful_partition/buildbarn-local-ssd', str(root / 'host-parent'))
        result = subprocess.run(['/bin/sh', '-ec', script], text=True, capture_output=True,
                                env=dict(os.environ, STUB_ROOT=str(root),
                                         PATH=str(root / 'bin') + ':' + os.environ['PATH']), timeout=30)
        assert result.returncode == 0, result.stderr
        state = json.loads((root / 'state.json').read_text())
        assert state['parent_bound'] and state['parent_shared'], state
        mounts = [event[1:] for event in state['events'] if event[0] == 'mount']
        expected = [] if already_bound else [['--bind', str(root / 'host-parent'), str(root / 'host-parent')]]
        expected += [['--make-rshared', str(root / 'host-parent')]]
        assert mounts == expected, mounts
        print(f'COS host-parent initialization (already bound={already_bound}): pass')


def run(name, *, existing=True, mounted=True, marker=True, legacy=False,
        missing_data=False, changed_uuid=False, wrong_mount=False,
        mount_disappears=False, unformatted=False, bad_permissions=False,
        label_failure=False, lose_mount_after_ready=False, inactive=False, activation_failure=False,
        orphaned_public_mount=False):
    with tempfile.TemporaryDirectory(prefix='local-ssd-provisioner-') as directory:
        root = pathlib.Path(directory)
        for path in ('bin', 'run', 'dev/ephemeral', 'dev/disk/by-id', 'serviceaccount', 'metadata', 'filesystem'):
            (root / path).mkdir(parents=True, exist_ok=True)
        (root / 'serviceaccount/token').write_text('stub-token')
        for number in (0, 1):
            disk = root / 'dev' / f'nvme{number}n1'
            disk.touch()
            (root / 'dev/disk/by-id' / f'google-local-nvme-ssd-{number}').symlink_to(disk)
        lvs = {name: name + '-uuid' for name in ('meta', 'cas', 'ac', 'iscc', 'fsac')} if existing else {}
        state = dict(vg=existing, lvs=lvs, events=[], labels=[], owners={},
                     fstype='ext4' if existing and not unformatted else '',
                     fsuuid='filesystem-uuid' if existing and not unformatted else '',
                     mounted=(mounted and existing) or orphaned_public_mount, staged=False, mounted_type='ext4',
                     mounted_uuid='wrong-uuid' if wrong_mount else 'filesystem-uuid',
                     mount_disappears=mount_disappears, label_failure=label_failure,
                     lose_mount_after_ready=lose_mount_after_ready, activation_failure=activation_failure)
        if existing:
            for store in ('cas', 'ac', 'iscc', 'fsac'):
                path = root / 'filesystem' / store
                path.mkdir(mode=0o770)
                path.chmod(0o770)
                state['owners'][str(path.resolve())] = '65534:65534'
            if marker:
                identity = 'buildbarn-local-ssd-layout-v1\nvg=vg-uuid\n'
                identity += ''.join(f'{key}={value}\n' for key, value in lvs.items())
                identity += 'filesystem=filesystem-uuid\n'
                (root / 'filesystem/.buildbarn-layout-v1').write_text(identity)
        if state['mounted']:
            (root / 'metadata').rmdir()
            (root / 'metadata').symlink_to(root / 'filesystem')
        if legacy:
            del lvs['meta']
        if missing_data:
            del lvs['cas']
        if changed_uuid:
            lvs['cas'] = 'replacement-cas-uuid'
        if bad_permissions:
            (root / 'filesystem/ac').chmod(0o755)
        if not inactive:
            for lv in lvs:
                (root / 'dev/ephemeral' / lv).touch()
        (root / 'state.json').write_text(json.dumps(state))
        stub_path = root / 'bin/stub'
        stub_path.write_text(stub)
        stub_path.chmod(0o755)
        for command in ('apk', 'curl', 'vgs', 'lvs', 'vgcreate', 'vgchange', 'lvcreate', 'mkfs.ext4',
                        'blkid', 'findmnt', 'mount', 'chown', 'stat', 'sleep', 'readlink'):
            (root / 'bin' / command).symlink_to(stub_path)
        replacements = {
            '/mnt/stateful_partition/buildbarn-local-ssd/metadata': str(root / 'metadata'),
            '/var/run/secrets/kubernetes.io/serviceaccount': str(root / 'serviceaccount'),
            '/tmp/': str(root / 'run') + '/',
            '/dev/': str(root / 'dev') + '/',
        }
        # Rewrite original paths once. On Linux the replacement root itself
        # starts with /tmp/, so successive replaces would rewrite inserted paths.
        script = re.sub('|'.join(re.escape(path) for path in replacements),
                        lambda match: replacements[match.group(0)], source)
        # Fake block devices are regular files; only the node-type predicate is
        # substituted. The command flow and mount/identity checks stay intact.
        script = script.replace('[ -b ', '[ -e ')
        script_path = root / 'script.sh'
        script_path.write_text(script)
        result = subprocess.run(['/bin/sh', '-ec', script], text=True, capture_output=True,
                                env=dict(os.environ, STUB_ROOT=str(root), NODE_NAME='stub-node',
                                         PATH=str(root / 'bin') + ':' + os.environ['PATH']), timeout=30)
        state = json.loads((root / 'state.json').read_text())
        state['result'] = result
        state['marker'] = (root / 'filesystem/.buildbarn-layout-v1').read_text() if (root / 'filesystem/.buildbarn-layout-v1').exists() else None
        state['public_store_exists'] = (root / 'metadata/cas').exists()
        print(f'{name}: exit={result.returncode}, labels={state["labels"]}')
        return state


def successful(state):
    assert state['result'].returncode == 0, state['result'].stderr
    assert state['labels'] == [None, 'ready', None], state


def rejected(state, message):
    assert state['result'].returncode != 0, state
    assert 'ready' not in state['labels'], state
    assert state['labels'] and state['labels'][-1] is None, state
    assert message in state['result'].stderr, state['result'].stderr
    assert not any(event[0] in ('mkfs.ext4', 'lvcreate', 'vgcreate') for event in state['events']), state


run_initializer(False)
run_initializer(True)
fresh = run('fresh SSDs', existing=False, mounted=False)
successful(fresh)
events = fresh['events']
created = [event for event in events if event[0] == 'lvcreate']
assert [event[event.index('--name') + 1] for event in created] == ['meta', 'ac', 'iscc', 'fsac', 'cas']
assert created[0][created[0].index('--size') + 1] == '16G'
assert '--stripes' in created[0] and created[0][created[0].index('--stripes') + 1] == '2'
assert sum(event[0] == 'mkfs.ext4' for event in events) == 1
positions = {command: next(i for i, event in enumerate(events) if event[0] == command)
             for command in ('mkfs.ext4', 'mount')}
ready = next(i for i, event in enumerate(events) if event[0] == 'curl' and '"ready"' in event[-1])
assert positions['mkfs.ext4'] < positions['mount'] < ready
publication = next(i for i, event in enumerate(events) if event[0] == 'mount' and '--bind' in event)
assert positions['mount'] < publication < ready
assert sum(event[0] == 'stat' for event in events[:publication]) == 4, 'validate all store permissions before publication'
assert fresh['marker'].startswith('buildbarn-local-ssd-layout-v1\nvg=vg-uuid\n')

for mounted in (True, False):
    reused = run('existing layout' if mounted else 'reboot remount', mounted=mounted)
    successful(reused)
    assert not any(event[0] in ('mkfs.ext4', 'lvcreate', 'vgcreate') for event in reused['events'])
    assert sum(event[0] == 'mount' for event in reused['events']) == (0 if mounted else 2)

activated = run('reboot with inactive LVs', mounted=False, inactive=True)
successful(activated)
assert sum(event[0] == 'vgchange' for event in activated['events']) == 1
rejected(run('incomplete VG cannot activate', mounted=False, inactive=True, activation_failure=True), 'could not activate all existing LVs')
rejected(run('VG lost with old mount still published', existing=False, orphaned_public_mount=True), 'VG missing while metadata remains published')
rejected(run('legacy full VG', legacy=True), 'legacy VG has no metadata LV')
rejected(run('missing data LV', missing_data=True), 'existing VG is missing cas')
rejected(run('changed data generation', changed_uuid=True), 'data/metadata generation mismatch')
reboot_mismatch = run('reboot with changed data generation', mounted=False, changed_uuid=True)
rejected(reboot_mismatch, 'data/metadata generation mismatch')
assert not reboot_mismatch['public_store_exists'], 'reboot must not expose failed generation to already-bound pods'
assert not any(event[0] == 'mount' and '--bind' in event for event in reboot_mismatch['events'])
rejected(run('unmounted after mount command', mounted=False, mount_disappears=True), 'metadata is not mounted as ext4')
rejected(run('wrong mount', wrong_mount=True), 'metadata mount UUID does not match')
rejected(run('missing marker', marker=False), 'metadata generation marker missing')
rejected(run('unformatted existing metadata', unformatted=True), 'refusing to format an existing LV')
rejected(run('wrong permissions', bad_permissions=True), 'must be owned by 65534:65534 with mode 0770')
mount_loss = run('mount lost after ready', lose_mount_after_ready=True)
assert mount_loss['result'].returncode != 0
assert mount_loss['labels'] == [None, 'ready', None], mount_loss
assert 'metadata is not mounted as ext4' in mount_loss['result'].stderr
fresh_mount_loss = run('fresh mount lost before marker', existing=False, mounted=False, mount_disappears=True)
assert fresh_mount_loss['result'].returncode != 0
assert 'ready' not in fresh_mount_loss['labels'] and fresh_mount_loss['marker'] is None
assert not any(event[0] == 'chown' for event in fresh_mount_loss['events'])
label_failure = run('cannot revoke stale readiness', label_failure=True)
assert label_failure['result'].returncode != 0 and 'ready' not in label_failure['labels']
assert not any(event[0] in ('vgs', 'mkfs.ext4', 'lvcreate', 'vgcreate') for event in label_failure['events'])
print('Local SSD provisioning preserves existing metadata and fails closed before readiness.')
PY
