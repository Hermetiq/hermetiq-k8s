#!/usr/bin/env python3
"""RPC regressions using real old/new storage images and disposable Docker volumes.

Requires helm, Docker, PyYAML, jsonnet, protobuf and grpcio. No cluster access.
All mounts are named Docker volumes, so this also works with a Docker socket
inside the CI container without assuming identical host/container paths.
Raw-device tests require privileged helper containers to attach disposable
volume files to loop devices; no existing disks or Kubernetes resources are used.
"""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
import uuid

import _jsonnet
import grpc
from google.protobuf import descriptor_pb2, descriptor_pool, json_format, message_factory
import yaml

CHART = Path(__file__).resolve().parents[1]
LEGACY_IMAGE = ('ghcr.io/buildbarn/bb-storage:20260908T142448Z-db62041'
                '@sha256:32ebc54b769b9e5fcc4beec3fdb527fd45853ca1ec9d1a112d00b1812f272a1f')
LOOP_TOOL_IMAGE = 'debian:bookworm-slim'


def docker(*args, check=True):
    return subprocess.run(['docker', *args], check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def descriptor_registry():
    descriptors = descriptor_pb2.FileDescriptorSet.FromString(
        (CHART / 'tests/testdata/buildbarn_descriptors_cdc.pb').read_bytes())
    pool = descriptor_pool.DescriptorPool()
    pending = list(descriptors.file)
    while pending:
        deferred = []
        for descriptor in pending:
            try:
                pool.Add(descriptor)
            except TypeError:
                deferred.append(descriptor)
        if len(pending) == len(deferred):
            raise AssertionError('Unresolved descriptor dependencies')
        pending = deferred
    return pool


def message_class(descriptor):
    # Debian bookworm's protobuf 3.x and current protobuf expose different
    # factory APIs; both use the official proto-JSON implementation.
    if hasattr(message_factory, 'GetMessageClass'):
        return message_factory.GetMessageClass(descriptor)
    return message_factory.MessageFactory().GetPrototype(descriptor)


def render_config(directory, ephemeral=False, optional_stores=False, raw=False, local=False):
    values = {'storage': {'replicas': 1, 'keyLocationMapSizing': {'validate': False}, 'persistence': {
        'cas': {'size': '4Gi', 'blocksSizeGi': 1, 'keyLocationMapSizeMi': 1},
        'ac': {'size': '2Gi', 'blocksSizeGi': 1,
               'keyLocationMap': {'entries': 10000, 'sizeMi': 1}},
        'cms': {'keyLocationMap': {'entries': 10000, 'sizeMi': 1}},
    }}}
    if optional_stores:
        for store in ('iscc', 'fsac'):
            values['storage']['persistence'][store] = {
                'enabled': True, 'size': '2Gi', 'blocksSizeGi': 1,
                'keyLocationMap': {'entries': 10000, 'sizeMi': 1},
            }
    if raw:
        for store in ('cas', 'ac', 'iscc', 'fsac'):
            values['storage']['persistence'][store].update({
                'backend': 'blockDevice',
                'blockDevice': {'size': '256Mi',
                                'metadata': {'size': '2Gi', 'keyLocationMapSizeMi': 1}},
            })
        if local:
            values['storage']['persistence'].update({
                'mode': 'hostPath', 'blockDevice': {'allowHostPath': True},
            })
            for store in ('cas', 'ac', 'iscc', 'fsac'):
                block = values['storage']['persistence'][store]['blockDevice']
                block['hostPath'] = {'devicePath': '/dev/ephemeral/' + store}
                block['metadata']['hostPath'] = {'path': '/mnt/buildbarn/' + store + '-meta'}
    if ephemeral:
        values['storage']['persistence']['cms']['keyLocationMap']['type'] = 'inMemory'
    values_file = directory / 'values.yaml'
    values_file.write_text(yaml.safe_dump(values))
    rendered = subprocess.check_output(['helm', 'template', 'storage-test', str(CHART), '--namespace', 'integration',
        '-f', str(CHART / 'ci-values/ci.yaml'), '-f', str(values_file)], text=True)
    documents = [d for d in yaml.safe_load_all(rendered) if d]
    config = next(d['data'] for d in documents if d['kind'] == 'ConfigMap'
                  and d['metadata']['name'] == 'buildbarn-config')
    for name, text in config.items():
        (directory / name).write_text(text)
    # Keep evaluated storage paths, persistence and chunking exactly as rendered.
    storage_file = directory / 'storage.json'
    storage_file.write_text(_jsonnet.evaluate_file(str(directory / 'storage.jsonnet')))
    (directory / 'frontend.json').write_text(_jsonnet.evaluate_file(str(directory / 'frontend.jsonnet')))
    statefulset = next(d for d in documents if d['kind'] == 'StatefulSet'
                      and d['metadata']['name'] == 'storage')
    pod = statefulset['spec']['template']['spec']
    init = next(c for c in pod['initContainers'] if c['name'] == 'volume-init')
    image = next(c['image'] for c in pod['containers'] if c['name'] == 'storage')
    return storage_file, image, init


class StorageMigrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        docker('info')  # Fail, rather than silently skip runtime coverage in CI.
        cls.pool = descriptor_registry()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='buildbarn-storage-test-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.prefix = 'buildbarn-test-' + uuid.uuid4().hex[:12]
        self.network = self.prefix + '-network'
        docker('network', 'create', self.network)
        self.addCleanup(docker, 'network', 'rm', self.network, check=False)
        # CI's Python client runs inside a sibling container. Join the test
        # network instead of assuming its localhost is the Docker host's.
        self.client_container = os.environ.get('BUILDBARN_TEST_CLIENT_CONTAINER')
        if self.client_container:
            docker('network', 'connect', self.network, self.client_container)
            self.addCleanup(docker, 'network', 'disconnect', self.network,
                            self.client_container, check=False)
        self.config = self.image = self.init = None
        self.mounts = []
        self.devices = []
        for store in ('cas', 'ac', 'iscc', 'fsac'):
            volume = self.prefix + '-' + store
            docker('volume', 'create', volume)
            self.addCleanup(docker, 'volume', 'rm', volume, check=False)
            self.mounts += ['--mount', f'type=volume,source={volume},target=/storage-{store}']
        # Ensure SIGTERM (e.g. CI timeout) runs addCleanup hooks instead of leaking Docker resources.
        self._prev_sigterm = signal.signal(signal.SIGTERM, self._handle_signal)
        self.addCleanup(signal.signal, signal.SIGTERM, self._prev_sigterm)

    def _handle_signal(self, signum, _frame):
        self.doCleanups()
        raise SystemExit(128 + signum)

    def configure(self, ephemeral=False, optional_stores=False, raw=False, local=False):
        self.config, self.image, self.init = render_config(
            self.directory, ephemeral=ephemeral, optional_stores=optional_stores, raw=raw, local=local,
        )
        if raw:
            self.mounts = [arg + '-meta' if arg.startswith('type=volume,') else arg
                           for arg in self.mounts]
            self.prepare_loop_devices()
        # Kubernetes normally supplies fsGroup ownership; emulate it here, then
        # run both the rendered init and storage as the chart's non-root UID.
        suffix = '-meta' if raw else ''
        paths = ' '.join('/storage-' + store + suffix for store in ('cas', 'ac', 'iscc', 'fsac'))
        self.shell('chown 65534:65534 ' + paths, user='0:0')

    def prepare_loop_devices(self):
        volume = self.prefix + '-raw-blocks'
        docker('volume', 'create', volume)
        self.addCleanup(docker, 'volume', 'rm', volume, check=False)
        for store in ('cas', 'ac', 'iscc', 'fsac'):
            # --find --show selects and attaches an unused loop device. The
            # backing file belongs to this test's named Docker volume.
            result = docker('run', '--rm', '--privileged',
                            '--mount', f'type=volume,source={volume},target=/blocks',
                            LOOP_TOOL_IMAGE, 'sh', '-ec',
                            f'truncate -s 256M /blocks/{store}; losetup --find --show /blocks/{store}',
                            check=False)
            self.assertEqual(result.returncode, 0,
                             'Raw-device tests require privileged Docker helpers and unused Linux '
                             'loop devices:\n' + result.stderr)
            device = result.stdout.strip()
            self.assertRegex(device, r'^/dev/loop[0-9]+$',
                             'Loop helper did not return an allocated loop device: ' + result.stdout)
            self.addCleanup(docker, 'run', '--rm', '--privileged', LOOP_TOOL_IMAGE,
                            'losetup', '--detach', device, check=False)
            self.devices += ['--device', f'{device}:/dev/bb/{store}']

    def shell(self, script, user='65534:65534', check=True):
        return docker('run', '--rm', '--user', user, *self.mounts,
                      self.init['image'], 'sh', '-c', script, check=check)

    def initialize(self, check=True):
        return self.shell(self.init['command'][2], check=check)

    def start_storage(self, config=None, image=None, frontend=False):
        name = self.prefix + '-' + uuid.uuid4().hex[:6]
        port = '8980' if frontend else '8981'
        alias = 'frontend' if frontend else 'storage-0.storage.integration'
        publish = [] if self.client_container else ['-p', '127.0.0.1::' + port]
        mounts = [] if frontend else self.mounts + self.devices
        docker('create', '--name', name, '--user', '65534:65534',
               '--network', self.network, '--network-alias', alias,
               *publish, *mounts,
               image or self.image, '/storage.json')
        self.addCleanup(docker, 'rm', '-f', name, check=False)
        docker('cp', str(config or self.config), name + ':/storage.json')
        docker('start', name)
        return name, self.channel(name, port)

    def container_logs(self, name):
        logs = docker('logs', name, check=False)
        return (logs.stdout or '') + (logs.stderr or '')

    def assert_no_storage_errors(self, name):
        logs = self.container_logs(name)
        for needle in ('data integrity error', 'SHA-256', 'Failed to decode ZSTD'):
            self.assertNotIn(needle, logs, logs)

    def channel(self, name, port='8981'):
        if self.client_container:
            info = json.loads(docker('inspect', name).stdout)[0]
            ip = info['NetworkSettings']['Networks'][self.network]['IPAddress']
            if not ip:
                self.fail(f'container {name} exited before receiving IP:\n{self.container_logs(name)}')
            address = ip + ':' + port
        else:
            port_result = docker('port', name, port + '/tcp', check=False)
            address = port_result.stdout.strip()
            if port_result.returncode != 0 or not address:
                self.fail(f'container {name} did not expose port {port}:\n{self.container_logs(name)}')
        channel = grpc.insecure_channel(address)
        self.addCleanup(channel.close)
        try:
            grpc.channel_ready_future(channel).result(timeout=30)
        except grpc.FutureTimeoutError:
            self.fail(self.container_logs(name))
        return channel

    def rpc(self, channel, method, data, service='ContentAddressableStorage'):
        name = service if '.' in service else 'build.bazel.remote.execution.v2.' + service
        service = self.pool.FindServiceByName(name)
        descriptor = service.FindMethodByName(method)
        request = message_class(descriptor.input_type)
        response = message_class(descriptor.output_type)
        return channel.unary_unary('/' + service.full_name + '/' + method,
            request_serializer=request.SerializeToString,
            response_deserializer=response.FromString)(
                json_format.ParseDict(data, request()), timeout=15)

    @staticmethod
    def digest(blob):
        return {'hash': hashlib.sha256(blob).hexdigest(), 'sizeBytes': str(len(blob))}

    def put(self, channel, blob):
        digest = self.digest(blob)
        result = self.rpc(channel, 'BatchUpdateBlobs', {'requests': [
            {'digest': digest, 'data': base64.b64encode(blob).decode()}]})
        self.assertEqual(result.responses[0].status.code, 0, result)

    def assert_read(self, channel, blob):
        result = self.rpc(channel, 'BatchReadBlobs', {'digests': [self.digest(blob)]})
        self.assertEqual(result.responses[0].status.code, 0, result.responses[0].status)
        self.assertEqual(result.responses[0].data, blob)

    def assert_missing(self, channel, blob):
        result = self.rpc(channel, 'FindMissingBlobs', {'blobDigests': [self.digest(blob)]})
        self.assertEqual([d.hash for d in result.missing_blob_digests], [self.digest(blob)['hash']])

    def put_action(self, channel, output):
        action = self.digest(b'action producing composite output')
        result = {'outputFiles': [{'path': 'output.bin', 'digest': self.digest(output)}], 'exitCode': 0}
        self.rpc(channel, 'UpdateActionResult', {'actionDigest': action, 'actionResult': result}, service='ActionCache')
        return action

    def restart(self, name, channel):
        channel.close()
        docker('stop', '--time', '20', name)
        self.initialize()
        docker('start', name)
        return self.channel(name)

    def recreate(self, name, channel, abrupt=False):
        channel.close()
        if abrupt:
            docker('kill', '--signal', 'KILL', name)
        else:
            docker('stop', '--time', '20', name)
            exit_code = json.loads(docker('inspect', name).stdout)[0]['State']['ExitCode']
            # Buildbarn re-raises SIGTERM after completing its shutdown groups.
            # Exit 143 is expected; Docker's timeout-driven SIGKILL would be 137.
            self.assertIn(exit_code, (0, 143), self.container_logs(name))
        docker('rm', name)
        # A replacement Pod reruns volume-init and starts a new process against
        # retained volumes. No storage files or config paths are synthesized.
        self.initialize()
        return self.start_storage()

    def put_learning_history(self, channel):
        digest = self.digest(b'reduced action with learned scheduling and input hints')
        stats = {
            'sizeClasses': {
                '1': {'previousExecutions': [{'succeeded': '1.250s'}, {'timedOut': '3s'}],
                      'initialPageRankProbability': 0.25},
                '2': {'previousExecutions': [{'succeeded': '0.750s'}],
                      'initialPageRankProbability': 0.75},
            },
        }
        profile = {
            'bloomFilter': base64.b64encode(b'\x85\x14\x01').decode(),
            'bloomFilterHashFunctions': 3,
        }
        request = {'reducedActionDigest': digest, 'digestFunction': 'SHA256'}
        self.rpc(channel, 'UpdatePreviousExecutionStats',
                 dict(request, previousExecutionStats=stats),
                 service='buildbarn.iscc.InitialSizeClassCache')
        self.rpc(channel, 'UpdateFileSystemAccessProfile',
                 dict(request, fileSystemAccessProfile=profile),
                 service='buildbarn.fsac.FileSystemAccessCache')
        return request, stats, profile

    def assert_learning_history(self, channel, history):
        request, stats, profile = history
        actual_stats = self.rpc(channel, 'GetPreviousExecutionStats', request,
                                service='buildbarn.iscc.InitialSizeClassCache')
        actual_profile = self.rpc(channel, 'GetFileSystemAccessProfile', request,
                                  service='buildbarn.fsac.FileSystemAccessCache')
        self.assertEqual(actual_stats, json_format.ParseDict(stats, type(actual_stats)()))
        self.assertEqual(actual_profile, json_format.ParseDict(profile, type(actual_profile)()))

    def legacy_persistent_config(self):
        # Derive a persistent-AC variant from the pinned pre-CDC fixture so the
        # upgrade guard is also proven against pre-CDC persistent AC (which
        # lacked SHA256SuffixCoder before bb-storage 8d2acac).
        cfg = copy.deepcopy(json.loads((CHART / 'tests/testdata/pre_cdc_storage.json').read_text()))
        ac_local = cfg['actionCache']['backend']['local']
        ac_local.pop('keyLocationMapInMemory')
        ac_local['keyLocationMapOnBlockDevice'] = {
            'file': {'path': '/storage-ac/ac-keys.db', 'sizeBytes': 1048576},
        }
        ac_local['persistent'] = {
            'minimumEpochInterval': '300s',
            'stateDirectoryPath': '/storage-ac/persistent_state',
        }
        path = self.directory / 'pre_cdc_storage_persistent_ac.json'
        path.write_text(json.dumps(cfg))
        return path

    def test_legacy_format_requires_explicit_reset_and_clean_reupload(self):
        self.configure()
        self.shell('mkdir -p /storage-cas/persistent_state /storage-ac/persistent_state')
        name, channel = self.start_storage(self.legacy_persistent_config(), LEGACY_IMAGE)
        blobs = [b'legacy raw CAS bytes ' * 5000, os.urandom(3 * 1024 * 1024)]
        for blob in blobs:
            self.put(channel, blob)
            self.assert_read(channel, blob)
        legacy_action = self.put_action(channel, blobs[1])
        channel.close()
        docker('stop', '--time', '20', name)
        # A failed upgrade must not alter any old CAS or AC data. Restart the
        # old image after the guard fails and verify blobs and AC remain readable.
        result = self.initialize(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Pre-CDC CAS files detected', result.stderr)
        self.shell('test ! -e /storage-cas/cdc-v1 && test ! -e /storage-ac/cdc-v1 && test ! -e /storage-cas/cms_persistent_state')
        docker('start', name)
        channel = self.channel(name)
        for blob in blobs:
            self.assert_read(channel, blob)
        legacy_ac_hit = self.rpc(channel, 'GetActionResult', {'actionDigest': legacy_action}, service='ActionCache')
        self.assertEqual(legacy_ac_hit.output_files[0].digest.hash, self.digest(blobs[1])['hash'])
        channel.close()
        docker('stop', '--time', '20', name)
        # Retiring only CAS while legacy AC remains must STILL be refused without
        # creating cdc-v1 on either volume, leaving legacy AC readable on rollback.
        self.shell('rm -rf /storage-cas/cas-keys.db /storage-cas/cas-blocks.db /storage-cas/persistent_state')
        result = self.initialize(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Pre-CDC AC files detected', result.stderr)
        self.shell('test ! -e /storage-cas/cdc-v1 && test ! -e /storage-ac/cdc-v1')
        # Now explicitly retire legacy AC files as documented and start CDC.
        self.shell('rm -rf /storage-ac/ac-keys.db /storage-ac/ac-blocks.db /storage-ac/persistent_state')
        self.initialize()
        new, channel = self.start_storage()
        _, frontend = self.start_storage(self.directory / 'frontend.json', frontend=True)
        # Exercise CAS FindMissing/Put/Get and AC Update/Get through the real frontend.
        for blob in blobs:
            self.assert_missing(frontend, blob)
            self.put(frontend, blob)
            self.assert_read(frontend, blob)
        action = self.put_action(frontend, blobs[1])
        ac_hit = self.rpc(frontend, 'GetActionResult', {'actionDigest': action}, service='ActionCache')
        self.assertEqual(ac_hit.output_files[0].digest.hash, self.digest(blobs[1])['hash'])
        channel = self.restart(new, channel)
        for blob in blobs:
            self.assert_read(frontend, blob)
        ac_hit = self.rpc(frontend, 'GetActionResult', {'actionDigest': action}, service='ActionCache')
        self.assertEqual(ac_hit.output_files[0].digest.hash, self.digest(blobs[1])['hash'])
        self.assert_no_storage_errors(new)

    def check_all_five_stores_after_recreation(self, raw=False, local=False):
        # Only sizes and optional-store enablement are overridden; index types
        # come from chart defaults, so this catches accidental default reversions.
        self.configure(optional_stores=True, raw=raw, local=local)
        self.initialize()
        name, channel = self.start_storage()
        blobs = [b'small blob' * 1024, os.urandom(3 * 1024 * 1024)]
        for blob in blobs:
            self.put(channel, blob)
            self.assert_read(channel, blob)
        action = self.put_action(channel, blobs[1])
        history = self.put_learning_history(channel)
        self.assert_learning_history(channel, history)
        name, channel = self.recreate(name, channel)
        self.assert_learning_history(channel, history)
        for blob in blobs:
            self.assert_read(channel, blob)
        # The graceful stop checkpointed these records. A subsequent hard kill
        # must retain that checkpoint; newly unsynchronized writes are not tested
        # or promised durable here, and there is no five-minute sleep.
        name, channel = self.recreate(name, channel, abrupt=True)
        self.assert_learning_history(channel, history)
        for blob in blobs:
            self.assert_read(channel, blob)
        # Exercise the chart's real completeness-checking frontend rather than
        # only reading an unchecked ActionResult directly from storage.
        _, frontend = self.start_storage(self.directory / 'frontend.json', frontend=True)
        for blob in blobs:
            self.assert_read(frontend, blob)
        result = self.rpc(frontend, 'GetActionResult', {'actionDigest': action}, service='ActionCache')
        self.assertEqual(result.output_files[0].digest.hash, self.digest(blobs[1])['hash'])
        self.assert_no_storage_errors(name)

    def test_default_indexes_preserve_all_five_filesystem_stores(self):
        self.check_all_five_stores_after_recreation()

    def test_default_indexes_preserve_all_five_raw_pvc_stores(self):
        self.check_all_five_stores_after_recreation(raw=True)

    def test_default_indexes_preserve_all_five_raw_hostpath_stores(self):
        # Loop devices stand in for retained NVMe; mounted metadata volumes
        # stand in for retained node-local directories. No node-loss guarantee.
        self.check_all_five_stores_after_recreation(raw=True, local=True)

    def test_explicit_ephemeral_cms_loses_only_composite_blobs(self):
        self.configure(ephemeral=True)
        self.initialize()
        name, channel = self.start_storage()
        small, large = b'small blob' * 1024, os.urandom(3 * 1024 * 1024)
        for blob in (small, large):
            self.put(channel, blob)
            self.assert_read(channel, blob)
        action = self.put_action(channel, large)
        channel = self.restart(name, channel)
        self.assert_read(channel, small)
        self.assert_missing(channel, large)
        _, frontend = self.start_storage(self.directory / 'frontend.json', frontend=True)
        with self.assertRaises(grpc.RpcError) as failure:
            self.rpc(frontend, 'GetActionResult', {'actionDigest': action}, service='ActionCache')
        self.assertEqual(failure.exception.code(), grpc.StatusCode.NOT_FOUND)
        self.assert_no_storage_errors(name)


if __name__ == '__main__':
    unittest.main(verbosity=2)
