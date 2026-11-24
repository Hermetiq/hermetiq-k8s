#!/usr/bin/env python3
r"""Probe an isolated Buildbarn storage endpoint across lifecycle changes.

Requires grpcio and protobuf; no Docker or Kubernetes client is used. Point this
at a port-forward to a disposable validation shard with ISCC and FSAC enabled.
`seed` writes deterministic CAS, AC, ISCC and FSAC fixtures; SplitBlob verifies
the 3 MiB CAS blob has a multi-chunk CMS mapping with the chart's default
RepMaxCDC parameters. Keep the
manifest outside the shard so `check` and `empty` can verify its state later.

Example (run from the repository root):
  uv run --no-project --with protobuf --with grpcio python3 \
    charts/buildbarn/tests/storage_gke_probe.py --endpoint localhost:18981 \
    --manifest /tmp/checkpoint.json --seed checkpoint seed

After a graceful restart, replace `seed` with `check`. For a crash test, seed a
second manifest after the checkpoint, kill storage, then run `check` against the
checkpoint manifest and `present-readable` against both manifests. After paired
block/metadata loss, `empty` must pass before reseeding. This tool never resets
storage and cannot establish physical disk placement; the provisioner and node
checks must establish that separately.
"""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

import grpc
from google.protobuf import descriptor_pb2, descriptor_pool, json_format, message_factory


REAPI = 'build.bazel.remote.execution.v2.'
ISCC = 'buildbarn.iscc.InitialSizeClassCache'
FSAC = 'buildbarn.fsac.FileSystemAccessCache'
GENERATOR = 'shake256-v1'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def descriptor_registry():
    # Same pinned descriptors and compatibility path as storage_integration.py,
    # without importing that Docker harness's jsonnet/PyYAML dependencies.
    descriptor_file = Path(__file__).with_name('testdata') / 'buildbarn_descriptors_cdc.pb'
    descriptors = descriptor_pb2.FileDescriptorSet.FromString(descriptor_file.read_bytes())
    pool = descriptor_pool.DescriptorPool()
    pending = list(descriptors.file)
    while pending:
        deferred = []
        for descriptor in pending:
            try:
                pool.Add(descriptor)
            except TypeError:
                deferred.append(descriptor)
        require(len(deferred) < len(pending), 'Unresolved descriptor dependencies')
        pending = deferred
    return pool


def message_class(descriptor):
    if hasattr(message_factory, 'GetMessageClass'):
        return message_factory.GetMessageClass(descriptor)
    return message_factory.MessageFactory().GetPrototype(descriptor)


def digest(data):
    return {'hash': hashlib.sha256(data).hexdigest(), 'sizeBytes': str(len(data))}


def blob_data(seed, label, size):
    return hashlib.shake_256(('buildbarn-gke-probe-v1\0' + seed + '\0' + label).encode()).digest(size)


def make_manifest(seed, instance_name, created_at=None):
    created_at = created_at or datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
    blobs = [
        {'name': label, 'digest': digest(blob_data(seed, label, size))}
        for label, size in [('small', 11000), ('medium', 512 * 1024), ('composite', 3 * 1024 * 1024)]
    ]
    return {
        'version': 1, 'generator': GENERATOR, 'seed': seed, 'instanceName': instance_name,
        'createdAt': created_at,
        'blobs': blobs,
        'actionDigest': digest(('action\0' + seed).encode()),
        'actionResult': {
            'outputFiles': [{'path': blob['name'] + '.bin', 'digest': blob['digest']} for blob in blobs],
            'exitCode': 0,
            # Buildbarn injects this when absent. Supply and retain it so the
            # entire ActionResult can be compared after a process restart.
            'executionMetadata': {'workerCompletedTimestamp': created_at},
        },
        'reducedActionDigest': digest(('reduced-action\0' + seed).encode()),
        'previousExecutionStats': {'sizeClasses': {
            '1': {'previousExecutions': [{'succeeded': '1.250s'}, {'timedOut': '3s'}],
                  'initialPageRankProbability': 0.25},
            '2': {'previousExecutions': [{'succeeded': '0.750s'}], 'initialPageRankProbability': 0.75},
        }},
        'fileSystemAccessProfile': {
            'bloomFilter': base64.b64encode(b'\x85\x14\x01').decode(), 'bloomFilterHashFunctions': 3,
        },
    }


class Probe:
    def __init__(self, endpoint, manifest, timeout):
        self.manifest = manifest
        self.pool = descriptor_registry()
        self.timeout = timeout
        self.channel = grpc.insecure_channel(endpoint, options=[
            ('grpc.max_receive_message_length', 16 * 1024 * 1024),
            ('grpc.max_send_message_length', 16 * 1024 * 1024),
        ])
        grpc.channel_ready_future(self.channel).result(timeout=timeout)

    def rpc(self, method, data, service=REAPI + 'ContentAddressableStorage'):
        descriptor = self.pool.FindServiceByName(service).FindMethodByName(method)
        request = message_class(descriptor.input_type)
        response = message_class(descriptor.output_type)
        return self.channel.unary_unary('/' + service + '/' + method,
            request_serializer=request.SerializeToString,
            response_deserializer=response.FromString)(
                json_format.ParseDict(data, request()), timeout=self.timeout)

    def cas_request(self, **fields):
        return dict(instanceName=self.manifest['instanceName'], digestFunction='SHA256', **fields)

    def history_request(self):
        return {'instanceName': self.manifest['instanceName'],
                'reducedActionDigest': self.manifest['reducedActionDigest'], 'digestFunction': 'SHA256'}

    def metadata_cases(self):
        return [
            (REAPI + 'ActionCache', 'GetActionResult', 'UpdateActionResult',
             self.cas_request(actionDigest=self.manifest['actionDigest']),
             'actionResult', self.manifest['actionResult']),
            (ISCC, 'GetPreviousExecutionStats', 'UpdatePreviousExecutionStats',
             self.history_request(), 'previousExecutionStats', self.manifest['previousExecutionStats']),
            (FSAC, 'GetFileSystemAccessProfile', 'UpdateFileSystemAccessProfile',
             self.history_request(), 'fileSystemAccessProfile', self.manifest['fileSystemAccessProfile']),
        ]

    def contents(self, blob):
        data = blob_data(self.manifest['seed'], blob['name'], int(blob['digest']['sizeBytes']))
        require(digest(data) == blob['digest'], 'Manifest digest mismatch: ' + blob['name'])
        return data

    def seed(self):
        for blob in self.manifest['blobs']:
            response = self.rpc('BatchUpdateBlobs', self.cas_request(requests=[{
                'digest': blob['digest'], 'data': base64.b64encode(self.contents(blob)).decode(),
            }]))
            require(len(response.responses) == 1, 'BatchUpdateBlobs returned unexpected response count')
            result = response.responses[0]
            require(result.digest.hash == blob['digest']['hash'], 'BatchUpdateBlobs returned wrong digest')
            require(result.status.code == 0, 'BatchUpdateBlobs failed: ' + str(result.status))
        for service, _, method, request, field, value in self.metadata_cases():
            self.rpc(method, dict(request, **{field: value}), service=service)
        return self.check('check')

    def check_chunk_mapping(self, blob, mode):
        try:
            result = self.rpc('SplitBlob', self.cas_request(
                blobDigest=blob['digest'], chunkingFunction='REP_MAX_CDC'))
        except grpc.RpcError as error:
            if mode == 'empty' and error.code() == grpc.StatusCode.NOT_FOUND:
                return {'status': 'missing'}
            raise
        require(mode != 'empty', 'Cold store still contains composite CMS mapping')
        chunking_enum = self.pool.FindEnumTypeByName('build.bazel.remote.execution.v2.ChunkingFunction.Value')
        require(result.chunking_function == chunking_enum.values_by_name['REP_MAX_CDC'].number,
                'SplitBlob returned an unexpected chunking function')
        require(len(result.chunk_digests) > 1,
                'Composite fixture did not exercise a multi-chunk CMS mapping; check CDC parameters')
        data = self.contents(blob)
        offset = 0
        for chunk in result.chunk_digests:
            require(chunk.size_bytes > 0, 'SplitBlob returned an empty chunk')
            contents = data[offset:offset + chunk.size_bytes]
            require(digest(contents) == {'hash': chunk.hash, 'sizeBytes': str(chunk.size_bytes)},
                    'CMS chunk digest or size does not match the original blob')
            offset += chunk.size_bytes
        require(offset == len(data), 'CMS mapping does not cover the complete composite blob')
        return {'status': 'readable', 'chunks': len(result.chunk_digests)}

    def check(self, mode):
        response = self.rpc('FindMissingBlobs', self.cas_request(
            blobDigests=[blob['digest'] for blob in self.manifest['blobs']]))
        missing = {item.hash for item in response.missing_blob_digests}
        known = {blob['digest']['hash'] for blob in self.manifest['blobs']}
        require(missing <= known, 'FindMissingBlobs returned unknown digests')
        if mode == 'check':
            require(not missing, 'Expected retained CAS blobs, found missing: ' + ', '.join(sorted(missing)))
        elif mode == 'empty':
            require(missing == known, 'Cold store still advertises CAS blobs as present')

        cms = {'status': 'not-queried', 'reason': 'composite blob is missing'}
        for blob in self.manifest['blobs']:
            if mode == 'present-readable' and blob['digest']['hash'] in missing:
                continue
            result = self.rpc('BatchReadBlobs', self.cas_request(digests=[blob['digest']]))
            require(len(result.responses) == 1, 'BatchReadBlobs returned unexpected response count')
            result = result.responses[0]
            require(result.digest.hash == blob['digest']['hash'], 'BatchReadBlobs returned wrong digest')
            if mode == 'empty':
                require(result.status.code == 5, 'Cold CAS read must return NOT_FOUND: ' + str(result.status))
            else:
                require(result.status.code == 0, 'Advertised CAS blob unreadable: ' + str(result.status))
                require(result.data == self.contents(blob), 'CAS content mismatch: ' + blob['name'])
            if blob['name'] == 'composite':
                cms = self.check_chunk_mapping(blob, mode)

        metadata = {}
        for service, method, _, request, _, expected in self.metadata_cases():
            label = service.rsplit('.', 1)[1]
            try:
                result = self.rpc(method, request, service=service)
            except grpc.RpcError as error:
                if mode in ('empty', 'present-readable') and error.code() == grpc.StatusCode.NOT_FOUND:
                    metadata[label] = 'missing'
                    continue
                raise
            require(mode != 'empty', 'Cold store still contains ' + label)
            require(result == json_format.ParseDict(expected, type(result)()), label + ' content mismatch')
            metadata[label] = 'readable'
        return {'casPresent': len(known - missing), 'casMissing': len(missing), 'cms': cms, 'metadata': metadata}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--endpoint', default='127.0.0.1:18981')
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--seed', help='Fixture identifier (required for a new seed manifest)')
    parser.add_argument('--instance-name', default='')
    parser.add_argument('--timeout', default=30, type=float)
    parser.add_argument('command', choices=['seed', 'check', 'present-readable', 'empty'])
    args = parser.parse_args()
    if args.manifest.exists():
        manifest = json.loads(args.manifest.read_text())
        require(manifest.get('version') == 1 and manifest.get('generator') == GENERATOR,
                'Unsupported manifest version or generator')
        require(args.seed is None or args.seed == manifest['seed'], 'Seed differs from existing manifest')
        require(not args.instance_name or args.instance_name == manifest['instanceName'],
                'Instance name differs from existing manifest')
        require(manifest == make_manifest(manifest['seed'], manifest['instanceName'], manifest['createdAt']),
                'Manifest fixtures differ from the deterministic generator')
    else:
        require(args.command == 'seed' and args.seed, 'New manifest requires seed command and --seed')
        manifest = make_manifest(args.seed, args.instance_name)
        # Retain expected fixtures even if the first write is interrupted.
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        with args.manifest.open('x') as output:
            json.dump(manifest, output, indent=2)
            output.write('\n')
    probe = Probe(args.endpoint, manifest, args.timeout)
    try:
        result = probe.seed() if args.command == 'seed' else probe.check(args.command)
        print(json.dumps(dict(command=args.command, seed=manifest['seed'], endpoint=args.endpoint,
                              result='PASS', **result), sort_keys=True))
    finally:
        probe.channel.close()


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, grpc.RpcError, grpc.FutureTimeoutError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
