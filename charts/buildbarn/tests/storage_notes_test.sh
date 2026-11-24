#!/usr/bin/env bash
# Render the actual NOTES source through a temporary ConfigMap using helm
# template. Helm 3 install --dry-run=client still performs cluster discovery;
# this wrapper keeps the same template context without an install action.
set -euo pipefail
python3 - "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml

chart = pathlib.Path(sys.argv[1])
repo = chart.parent.parent

# NOTES.txt is omitted from helm template output. Capture its unmodified source
# in a named template in a temporary chart copy, then expose the rendered text
# as data in one ordinary manifest. All production helpers, values, and files
# remain available, and every assertion below reads the real NOTES implementation.
render_temp = tempfile.TemporaryDirectory(prefix='buildbarn-notes-test-')
render_chart = pathlib.Path(render_temp.name) / 'buildbarn'
shutil.copytree(chart, render_chart)
notes_source = (chart / 'templates/NOTES.txt').read_text()
(render_chart / 'templates/storage-notes-test.yaml').write_text(
    '{{- define "buildbarn.test.actualNotes" -}}\n' + notes_source +
    '\n{{- end -}}\n'
    'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: storage-notes-test\n'
    'data:\n  notes: {{ include "buildbarn.test.actualNotes" . | toJson }}\n'
)


def notes(values=None, profiles=()):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml') as overrides:
        yaml.safe_dump(values or {}, overrides)
        overrides.flush()
        command = ['helm', 'template', 'storage-notes-test', str(render_chart),
                   '--namespace', 'notes-test',
                   '--show-only', 'templates/storage-notes-test.yaml',
                   '-f', str(chart / 'ci-values/ci.yaml')]
        for profile in profiles:
            command += ['-f', str(repo / 'custom-values' / profile)]
        command += ['-f', overrides.name]
        output = subprocess.check_output(command, text=True,
                                         env=dict(os.environ, KUBECONFIG='/dev/null'))
    document = yaml.safe_load(output)
    assert document['kind'] == 'ConfigMap', document
    return document['data']['notes']


baseline = notes()
assert 'All enabled storage stores use persistent indexes' in baseline, baseline
assert 'VOLATILE STORAGE STORES:' not in baseline, baseline
assert 'STORAGE INDEX CAPACITY:' not in baseline, baseline
assert 'STORAGE CLASS MISMATCH:' not in baseline, baseline

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
# The index size is set here so the case does not depend on the chart default.
for backend in ('sharedCas', 'filesystem'):
    warning = notes({'storage': {'persistence': {'cms': {
        'backend': backend, 'size': '4Gi', 'blocksSizeGi': 2,
        'keyLocationMap': {'sizeMi': 256},
    }}}})
    assert 'Set storage.persistence.cms.keyLocationMap.sizeMi to at least 484 MiB' in warning, warning

warning = notes({'storage': {'persistence': {'iscc': {
    'enabled': True, 'backend': 'blockDevice', 'blockDevice': {'size': '4Gi'},
}}}})
assert 'Set storage.persistence.iscc.blockDevice.metadata.keyLocationMapSizeMi to at least 968 MiB' in warning, warning

bounded = notes({'storage': {'persistence': {
    'mode': 'emptyDir', 'cas': {'emptyDir': {'sizeLimit': '1000Gi'}},
    'ac': {'emptyDir': {'sizeLimit': '12Gi'}},
    'iscc': {'emptyDir': {'sizeLimit': '2Gi'}},
    'fsac': {'emptyDir': {'sizeLimit': '6Gi'}},
}}})
assert 'storage.persistence.mode=emptyDir loses all stores on pod replacement' in bounded, bounded
assert 'VOLATILE STORAGE STORES:' not in bounded, bounded

# In pvc mode every store has its own StorageClass. Setting it for CAS and AC
# leaves the default-enabled ISCC and FSAC claims on the chart default.
classes = notes({'storage': {'persistence': {
    'cas': {'storageClassName': 'gp3'}, 'ac': {'storageClassName': 'gp3'},
}}})
for store in ('iscc', 'fsac'):
    assert ('WARNING: STORAGE CLASS MISMATCH: storage.persistence.%s.storageClassName is "premium-rwo" '
            'but storage.persistence.cas.storageClassName is "gp3".' % store) in classes, classes
assert 'STORAGE CLASS MISMATCH: storage.persistence.ac.' not in classes, classes
aligned = notes({'storage': {'persistence': {
    name: {'storageClassName': 'gp3'} for name in ('cas', 'ac', 'iscc', 'fsac')
}}})
assert 'STORAGE CLASS MISMATCH:' not in aligned, aligned

# A raw store's metadata claim holds its index and checkpoint state. A blocks
# class next to a different metadata class must be reported; one class for
# both must not.
split = notes({'storage': {'persistence': {'ac': {
    'backend': 'blockDevice', 'blockDevice': {'storageClassName': 'topolvm-ssd'},
}}}})
assert ('WARNING: STORAGE CLASS MISMATCH: storage.persistence.ac.blockDevice.storageClassName is "topolvm-ssd" '
        'but storage.persistence.ac.blockDevice.metadata.storageClassName is "premium-rwo".') in split, split
paired = notes({'storage': {'persistence': {'ac': {
    'backend': 'blockDevice', 'blockDevice': {
        'storageClassName': 'topolvm-ssd', 'metadata': {'storageClassName': 'topolvm-ssd'},
    },
}}}})
assert 'STORAGE CLASS MISMATCH: storage.persistence.ac.blockDevice' not in paired, paired
# No claims are rendered outside pvc mode.
assert 'STORAGE CLASS MISMATCH:' not in bounded, bounded

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

green = notes({'deploymentMode': 'storage-only', 'storage': {'name': 'storage-cdc'}})
assert 'Storage target: storage-cdc' in green, green
assert 'Storage-only release:' in green, green
assert 'EXTERNAL ENDPOINTS' not in green, green
external = notes({'storage': {'enabled': False, 'name': 'storage-cdc',
                              'persistence': {'mode': 'unused'}}})
assert 'Storage is managed by another release.' in external, external
assert 'retains its PVCs' in external, external
assert 'All enabled storage stores use persistent indexes' not in external, external
assert 'STORAGE INDEX CAPACITY' not in external, external

print('Storage NOTES report actual volatile selections, actionable file-index capacity warnings, and StorageClass mismatches.')
PY
