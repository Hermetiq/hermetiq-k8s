#!/usr/bin/env bash
# The persistent selector profile must remain equivalent to the chart defaults,
# including when applied after older explicit RAM-index deployment values.
set -euo pipefail
python3 - "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" <<'PY'
import copy
import pathlib
import subprocess
import sys
import tempfile

import yaml

chart = pathlib.Path(sys.argv[1])
profile = chart.parent.parent / 'custom-values/buildbarn-values-persistent.yaml'
ci_values = chart / 'ci-values/ci.yaml'


def render(directory, values, include_profile=False):
    values_file = directory / 'deployment.yaml'
    values_file.write_text(yaml.safe_dump(values))
    args = ['helm', 'template', 'profile-test', str(chart), '--namespace', 'hermetiq',
            '-f', str(ci_values), '-f', str(values_file)]
    if include_profile:
        args += ['-f', str(profile)]
    return subprocess.check_output(args, text=True)


def check_layout(output, expected_claims, expected_stores):
    documents = [doc for doc in yaml.safe_load_all(output) if doc]
    storage = next(doc for doc in documents if doc['kind'] == 'StatefulSet'
                   and doc['metadata']['name'] == 'storage')
    assert len(storage['spec'].get('volumeClaimTemplates', [])) == expected_claims
    config = next(doc['data']['storage.jsonnet'] for doc in documents
                  if doc['kind'] == 'ConfigMap' and doc['metadata']['name'] == 'buildbarn-config')
    assert config.count('stateDirectoryPath:') == expected_stores, config
    assert 'inMemory:' not in config and 'blocksInMemory:' not in config, config


with tempfile.TemporaryDirectory(prefix='buildbarn-profile-test-') as tmp:
    directory = pathlib.Path(tmp)
    # The profile preserves default enablement and explicit disabled overrides.
    output = render(directory, {})
    assert output == render(directory, {}, include_profile=True)
    check_layout(output, expected_claims=4, expected_stores=5)
    print('PASS default/profile equality with all five stores enabled')
    disabled = {'storage': {'persistence': {
        'iscc': {'enabled': False}, 'fsac': {'enabled': False},
    }}}
    output = render(directory, disabled)
    assert output == render(directory, disabled, include_profile=True)
    check_layout(output, expected_claims=2, expected_stores=3)
    print('PASS default/profile equality with explicitly disabled ISCC and FSAC')

    for mode in ('pvc', 'hostPath'):
        for backend in ('filesystem', 'blockDevice'):
            for dedicated_cms in (False, True):
                names = ['cas', 'ac', 'iscc', 'fsac']
                if dedicated_cms:
                    names.append('cms')
                persistence = {'mode': mode}
                if mode == 'hostPath' and backend == 'blockDevice':
                    persistence['blockDevice'] = {'allowHostPath': True}
                for name in names:
                    store = {'backend': backend}
                    if name in ('iscc', 'fsac'):
                        store['enabled'] = True
                    if mode == 'hostPath' and backend == 'blockDevice':
                        store['blockDevice'] = {
                            'hostPath': {'devicePath': f'/dev/local/{name}'},
                            'metadata': {'hostPath': {'path': f'/mnt/local/meta/{name}'}},
                        }
                    persistence[name] = store
                values = {'storage': {'persistence': persistence}}
                label = f'{mode}-{backend}-{"dedicated" if dedicated_cms else "shared"}-cms'
                expected = render(directory, values)
                assert expected == render(directory, values, include_profile=True), label

                # Model an old deployment that explicitly chose RAM indexes.
                # Both filesystem and raw selector keys are present so the actual
                # profile must override the relevant choice for every backend.
                legacy = copy.deepcopy(values)
                for name in ('cas', 'cms', 'ac', 'iscc', 'fsac'):
                    store = legacy['storage']['persistence'].setdefault(name, {})
                    store.setdefault('blockDevice', {})['keyLocationMap'] = 'inMemory'
                    if name != 'cas':
                        store['keyLocationMap'] = {'type': 'inMemory'}
                assert expected == render(directory, legacy, include_profile=True), label

                claims = len(names) * (2 if backend == 'blockDevice' else 1)
                check_layout(expected, expected_claims=claims if mode == 'pvc' else 0,
                             expected_stores=5)
                print(f'PASS {label}: default/profile equality, old RAM overrides, five persistent stores')

    # The shipped Local SSD overlay must keep every raw index and checkpoint
    # on the provisioner's metadata LV, alongside the four disposable data LVs.
    local_overlay = chart.parent.parent / 'custom-values/buildbarn-values-local-ssd-block.yaml'
    output = subprocess.check_output(
        ['helm', 'template', 'profile-test', str(chart), '--namespace', 'hermetiq',
         '-f', str(ci_values), '-f', str(local_overlay)], text=True,
    )
    documents = [doc for doc in yaml.safe_load_all(output) if doc]
    storage = next(doc for doc in documents if doc['kind'] == 'StatefulSet'
                   and doc['metadata']['name'] == 'storage')
    assert not storage['spec'].get('volumeClaimTemplates'), storage['spec']
    pod = storage['spec']['template']['spec']
    assert pod['nodeSelector']['hermetiq/ephemeral-lvm'] == 'ready', pod['nodeSelector']
    volumes = {volume['name']: volume for volume in pod['volumes']}
    expected_meta = {f'{store}-meta' for store in ('cas', 'ac', 'iscc', 'fsac')}
    assert {name for name in volumes if name.endswith('-meta')} == expected_meta, volumes
    for store in ('cas', 'ac', 'iscc', 'fsac'):
        assert volumes[store + '-meta']['hostPath'] == {
            'path': '/mnt/stateful_partition/buildbarn-local-ssd/metadata/' + store,
            'type': 'Directory',
        }, volumes[store + '-meta']
    for container_name, containers in (('storage', pod['containers']),
                                       ('volume-init', pod.get('initContainers', []))):
        container = next(item for item in containers if item['name'] == container_name)
        mounts = {item['name']: item for item in container.get('volumeMounts', [])}
        for store in ('cas', 'ac', 'iscc', 'fsac'):
            assert mounts[store + '-meta']['mountPath'] == '/storage-' + store + '-meta', mounts
    config = next(doc['data']['storage.jsonnet'] for doc in documents
                  if doc['kind'] == 'ConfigMap' and doc['metadata']['name'] == 'buildbarn-config')
    check_layout(output, expected_claims=0, expected_stores=5)
    assert "path: '/storage-cas-meta/cdc-v1/cms-blocks.db'" in config, config
    print('PASS bundled Local SSD example persists all five stores on the provisioned metadata LV')

print('Persistent profile matches defaults and overrides old RAM settings across all storage layouts.')
PY
