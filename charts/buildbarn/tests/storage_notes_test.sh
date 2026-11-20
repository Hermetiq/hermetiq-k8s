#!/usr/bin/env bash
# Render the actual Helm NOTES without contacting a Kubernetes cluster. NOTES
# are not part of `helm template` manifests, so use a client-only dry install.
set -euo pipefail
python3 - "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" <<'PY'
import os
import pathlib
import subprocess
import sys
import tempfile

import yaml

chart = pathlib.Path(sys.argv[1])
repo = chart.parent.parent


def notes(values=None, profiles=()):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml') as overrides:
        yaml.safe_dump(values or {}, overrides)
        overrides.flush()
        command = ['helm', 'install', 'storage-notes-test', str(chart),
                   '--namespace', 'notes-test', '--dry-run=client',
                   '-f', str(chart / 'ci-values/ci.yaml')]
        for profile in profiles:
            command += ['-f', str(repo / 'custom-values' / profile)]
        command += ['-f', overrides.name]
        output = subprocess.check_output(command, text=True,
                                         env=dict(os.environ, KUBECONFIG='/dev/null'))
    assert '\nNOTES:\n' in output, 'Helm did not return NOTES'
    return output.split('\nNOTES:\n', 1)[1]


baseline = notes()
assert 'All enabled storage stores use persistent indexes' in baseline, baseline
assert 'VOLATILE STORAGE STORES:' not in baseline, baseline
assert 'STORAGE INDEX CAPACITY:' not in baseline, baseline

one = notes({'storage': {'persistence': {
    'iscc': {'enabled': True, 'keyLocationMap': {'type': 'inMemory'}},
    'fsac': {'enabled': False, 'keyLocationMap': {'type': 'inMemory', 'entries': 1}},
}}})
assert 'VOLATILE STORAGE STORES: ISCC.' in one, one
assert 'VOLATILE STORAGE STORES: ISCC, FSAC' not in one, one
assert 'STORAGE INDEX CAPACITY:' not in one, one  # disabled FSAC is excluded
assert '--reset-then-reuse-values' in one and 'preserves explicit inMemory' in one, one

fallback = notes({'storage': {'persistence': {'cas': {
    'backend': 'blockDevice', 'blockDevice': {'keyLocationMap': 'inMemory'},
}}}})
assert 'VOLATILE STORAGE STORES: CAS, CMS.' in fallback, fallback

raw = {'storage': {'persistence': {
    name: dict({'backend': 'blockDevice'}, **({'enabled': True} if name in ('iscc', 'fsac') else {}))
    for name in ('cas', 'cms', 'ac', 'iscc', 'fsac')
}}}
ephemeral = notes(raw, profiles=['buildbarn-values-ephemeral.yaml'])
assert 'VOLATILE STORAGE STORES: CAS, CMS, AC, ISCC, FSAC.' in ephemeral, ephemeral
assert 'All enabled storage stores use persistent indexes' not in ephemeral, ephemeral

# Turning off fatal capacity validation must still expose ignored RAM sizing
# knobs and tell the operator the exact disk-file setting and rounded MiB.
undersized = {'storage': {'persistence': {'ac': {
    'size': '25Gi', 'blocksSizeGi': 20, 'keyLocationMap': {'entries': 42000000},
}}}}
warning = notes(undersized)
assert 'WARNING: STORAGE INDEX CAPACITY: storage.persistence.ac:' in warning, warning
assert 'Set storage.persistence.ac.keyLocationMap.sizeMi to at least 2152 MiB' in warning, warning
assert 'RAM entry settings do not size this file index' in warning, warning
assert 'switching to a device-backed' not in warning, warning
assert 'VOLATILE STORAGE STORES:' not in warning, warning

# Both dedicated and shared CMS use the same warning arithmetic as validation.
for backend in ('sharedCas', 'filesystem'):
    warning = notes({'storage': {'persistence': {'cms': {
        'backend': backend, 'size': '4Gi', 'blocksSizeGi': 2,
    }}}})
    assert 'Set storage.persistence.cms.keyLocationMap.sizeMi to at least 484 MiB' in warning, warning

warning = notes({'storage': {'persistence': {'iscc': {
    'enabled': True, 'backend': 'blockDevice', 'blockDevice': {'size': '4Gi'},
}}}})
assert 'Set storage.persistence.iscc.blockDevice.metadata.keyLocationMapSizeMi to at least 968 MiB' in warning, warning

bounded = notes({'storage': {'persistence': {
    'mode': 'emptyDir', 'cas': {'emptyDir': {'sizeLimit': '1000Gi'}},
    'ac': {'emptyDir': {'sizeLimit': '12Gi'}},
}}})
assert 'storage.persistence.mode=emptyDir loses all stores on pod replacement' in bounded, bounded
assert 'VOLATILE STORAGE STORES:' not in bounded, bounded

custom = notes({'configOverrides': {'storage.jsonnet': '{}'}, **undersized})
assert 'STORAGE CONFIG OVERRIDE:' in custom, custom
assert 'VOLATILE STORAGE STORES:' not in custom, custom
assert 'All enabled storage stores use persistent indexes' not in custom, custom
assert 'STORAGE INDEX CAPACITY:' not in custom, custom

empty_override = notes({'configOverrides': {'storage.jsonnet': ''}, **undersized})
assert 'STORAGE CONFIG OVERRIDE:' not in empty_override, empty_override
assert 'Set storage.persistence.ac.keyLocationMap.sizeMi to at least 2152 MiB' in empty_override, empty_override
empty_volatile = notes({'configOverrides': {'storage.jsonnet': ''}, 'storage': {
    'persistence': {'ac': {'keyLocationMap': {'type': 'inMemory'}}},
}})
assert 'VOLATILE STORAGE STORES: AC.' in empty_volatile, empty_volatile

print('Storage NOTES report actual volatile selections and actionable file-index capacity warnings.')
PY
