#!/usr/bin/env python3
"""RPC regressions using real old/new storage images and disposable Docker volumes.

Requires helm, Docker, PyYAML, jsonnet, protobuf and grpcio. No cluster access.
All mounts are named Docker volumes, so this also works with a Docker socket
inside the CI container without assuming identical host/container paths.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
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


def render_config(directory, ephemeral=False):
    values = {'storage': {'replicas': 1, 'keyLocationMapSizing': {'validate': False}, 'persistence': {
        'cas': {'size': '4Gi', 'blocksSizeGi': 1, 'keyLocationMapSizeMi': 1},
        'ac': {'size': '2Gi', 'blocksSizeGi': 1,
               'keyLocationMap': {'type': 'blockDevice', 'entries': 10000, 'sizeMi': 1}},
        'cms': {'keyLocationMap': {'entries': 10000, 'sizeMi': 1}},
    }}}
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
        self.config, self.image, self.init = render_config(self.directory)
        self.mounts = []
        for store in ('cas', 'ac'):
            volume = self.prefix + '-' + store
            docker('volume', 'create', volume)
            self.addCleanup(docker, 'volume', 'rm', volume, check=False)
            self.mounts += ['--mount', f'type=volume,source={volume},target=/storage-{store}']
        # Kubernetes normally supplies fsGroup ownership; emulate it here, then
        # run both the rendered init and storage as the chart's non-root UID.
        self.shell('chown 65534:65534 /storage-cas /storage-ac', user='0:0')

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
        docker('create', '--name', name, '--user', '65534:65534',
               '--network', self.network, '--network-alias', alias,
               *publish, *self.mounts,
               image or self.image, '/storage.json')
        self.addCleanup(docker, 'rm', '-f', name, check=False)
        docker('cp', str(config or self.config), name + ':/storage.json')
        docker('start', name)
        return name, self.channel(name, port)

    def channel(self, name, port='8981'):
        if self.client_container:
            info = json.loads(docker('inspect', name).stdout)[0]
            address = info['NetworkSettings']['Networks'][self.network]['IPAddress'] + ':' + port
        else:
            address = docker('port', name, port + '/tcp').stdout.strip()
        channel = grpc.insecure_channel(address)
        self.addCleanup(channel.close)
        try:
            grpc.channel_ready_future(channel).result(timeout=30)
        except grpc.FutureTimeoutError:
            self.fail(docker('logs', name, check=False).stderr)
        return channel

    def rpc(self, channel, method, data, service='ContentAddressableStorage'):
        service = self.pool.FindServiceByName('build.bazel.remote.execution.v2.' + service)
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

    def test_legacy_format_requires_explicit_reset_and_clean_reupload(self):
        self.shell('mkdir -p /storage-cas/persistent_state /storage-ac/persistent_state')
        name, channel = self.start_storage(CHART / 'tests/testdata/pre_cdc_storage.json', LEGACY_IMAGE)
        blobs = [b'legacy raw CAS bytes ' * 5000, os.urandom(3 * 1024 * 1024)]
        for blob in blobs:
            self.put(channel, blob)
            self.assert_read(channel, blob)
        channel.close()
        docker('stop', '--time', '20', name)
        # A failed upgrade must not alter any old data. Restart the old image
        # after the guard fails and verify both blobs are still readable.
        result = self.initialize(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Pre-CDC CAS files detected', result.stderr)
        self.shell('test ! -e /storage-cas/cdc-v1')
        docker('start', name)
        channel = self.channel(name)
        for blob in blobs:
            self.assert_read(channel, blob)
        channel.close()
        docker('stop', '--time', '20', name)
        # Model the explicit maintenance step on these disposable test volumes.
        # Production init must never automatically delete or move these files.
        self.shell('rm -rf /storage-cas/cas-keys.db /storage-cas/cas-blocks.db /storage-cas/persistent_state')
        self.initialize()
        new, channel = self.start_storage()
        for blob in blobs:
            self.assert_missing(channel, blob)
            self.put(channel, blob)
            self.assert_read(channel, blob)
        channel = self.restart(new, channel)
        for blob in blobs:
            self.assert_read(channel, blob)

    def test_default_persistent_cms_survives_restart(self):
        self.initialize()
        name, channel = self.start_storage()
        blobs = [b'small blob' * 1024, os.urandom(3 * 1024 * 1024)]
        for blob in blobs:
            self.put(channel, blob)
            self.assert_read(channel, blob)
        action = self.put_action(channel, blobs[1])
        channel = self.restart(name, channel)
        for blob in blobs:
            self.assert_read(channel, blob)
        # Exercise the chart's real completeness-checking frontend rather than
        # only reading an unchecked ActionResult directly from storage.
        _, frontend = self.start_storage(self.directory / 'frontend.json', frontend=True)
        result = self.rpc(frontend, 'GetActionResult', {'actionDigest': action}, service='ActionCache')
        self.assertEqual(result.output_files[0].digest.hash, self.digest(blobs[1])['hash'])
        self.assertNotIn('data integrity error', docker('logs', name).stderr)

    def test_explicit_ephemeral_cms_loses_only_composite_blobs(self):
        self.config, self.image, self.init = render_config(self.directory, ephemeral=True)
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
