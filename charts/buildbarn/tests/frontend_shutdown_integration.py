#!/usr/bin/env python3
"""Exercise rendered frontend shutdown with the real pinned Docker images.

Requires the same tools as storage_integration.py. No Kubernetes resources or
credentials are used. Docker containers share a network namespace, as in a pod;
the test sends TERM after each rendered preStop delay. This proves process/RPC
draining, not Kubernetes EndpointSlice or external load-balancer propagation.
"""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

import _jsonnet
import grpc
import yaml

from storage_integration import CHART, descriptor_registry, message_class


def docker(*args, check=True, timeout=60):
    return subprocess.run(['docker', *args], check=check, text=True, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def render(directory, proxy):
    values = {
        'tracing': {'enabled': False},
        'frontend': {
            'terminationGracePeriodSeconds': 30,
            'shutdown': {'drainDelaySeconds': 1, 'rpcGracePeriodSeconds': 5,
                         'eventDrainTimeoutSeconds': 1},
            'grpcCacheProxy': {'enabled': proxy, 'enforceAuth': False, 'natsUrl': ''},
        },
    }
    values_file = directory / 'values.yaml'
    values_file.write_text(yaml.safe_dump(values))
    rendered = subprocess.check_output([
        'helm', 'template', 'shutdown-test', str(CHART), '--kube-version', '1.34.0',
        '-f', str(CHART / 'ci-values/ci.yaml'), '-f', str(values_file)], text=True)
    documents = [d for d in yaml.safe_load_all(rendered) if d]
    config = next(d['data'] for d in documents if d['kind'] == 'ConfigMap'
                  and d['metadata']['name'] == 'buildbarn-config')
    for name, text in config.items():
        (directory / name).write_text(text)
    frontend = json.loads(_jsonnet.evaluate_file(str(directory / 'frontend.jsonnet')))
    deployment = next(d for d in documents if d['kind'] == 'Deployment'
                      and d['metadata']['name'] == 'frontend')
    return deployment['spec']['template']['spec'], frontend


class FrontendShutdownTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        docker('info')  # Missing runtime prerequisites must fail the CI gate.
        pool = descriptor_registry()
        cls.ExecuteRequest = message_class(pool.FindMessageTypeByName(
            'build.bazel.remote.execution.v2.ExecuteRequest'))
        cls.ExecuteResponse = message_class(pool.FindMessageTypeByName(
            'build.bazel.remote.execution.v2.ExecuteResponse'))
        cls.Operation = message_class(pool.FindMessageTypeByName('google.longrunning.Operation'))

    def setUp(self):
        # TestCase does not run addCleanup hooks when KeyboardInterrupt escapes.
        # Explicitly unwind them on CI timeout or an interrupted local run.
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous = signal.signal(signum, self.interrupted)
            self.addCleanup(signal.signal, signum, previous)
        self.temp = tempfile.TemporaryDirectory(prefix='buildbarn-shutdown-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.prefix = 'buildbarn-shutdown-' + uuid.uuid4().hex[:12]
        self.network = self.prefix + '-network'
        self.containers = []
        self.release = threading.Event()
        self.calls = 0
        self.call_lock = threading.Lock()
        self.addCleanup(self.release.set)
        self.scheduler = grpc.server(ThreadPoolExecutor(max_workers=8))
        self.scheduler.add_generic_rpc_handlers((grpc.method_handlers_generic_handler(
            'build.bazel.remote.execution.v2.Execution', {
                'Execute': grpc.unary_stream_rpc_method_handler(
                    self.execute, request_deserializer=self.ExecuteRequest.FromString,
                    response_serializer=lambda response: response.SerializeToString()),
            }), grpc.method_handlers_generic_handler(
                'opentelemetry.proto.collector.metrics.v1.MetricsService', {
                    'Export': grpc.unary_unary_rpc_method_handler(lambda request, context: b''),
                })))
        self.scheduler_port = self.scheduler.add_insecure_port('0.0.0.0:0')
        self.scheduler.start()
        self.addCleanup(lambda: self.scheduler.stop(0).wait(timeout=5))
        docker('network', 'create', self.network)
        self.addCleanup(docker, 'network', 'rm', self.network, check=False)
        self.client_container = os.environ.get('BUILDBARN_TEST_CLIENT_CONTAINER')
        if self.client_container:
            docker('network', 'connect', self.network, self.client_container)
            self.addCleanup(docker, 'network', 'disconnect', self.network,
                            self.client_container, check=False)
        self.addCleanup(self.remove_containers)

    def interrupted(self, signum, frame):
        self.doCleanups()
        raise KeyboardInterrupt

    def remove_containers(self):
        for name in reversed(self.containers):
            docker('rm', '-f', name, check=False)

    def execute(self, request, context):
        with self.call_lock:
            self.calls += 1
        yield self.Operation(name='held', done=False)
        while not self.release.wait(0.05):
            if not context.is_active():
                return
        response = self.ExecuteResponse()
        response.result.exit_code = 0
        final = self.Operation(name='held', done=True)
        final.response.Pack(response)
        yield final

    def create(self, name, *args):
        # Both the production proxy and the CI runtime use amd64. This also
        # exercises that exact image on an arm64 Docker Desktop developer host.
        docker('create', '--platform', 'linux/amd64', '--name', name, *args)
        self.containers.append(name)

    def start(self, proxy=True, immediate_stop=False):
        self.pod, config = render(self.directory, proxy)
        containers = {c['name']: c for c in self.pod['containers']}
        frontend = containers['frontend']
        self.hold = frontend['lifecycle']['preStop']['sleep']['seconds']
        self.pod_grace = self.pod['terminationGracePeriodSeconds']
        # The sandbox stays alive after either application exits, matching pod
        # networking. /bin/sleep is available in the pinned proxy image.
        if proxy:
            proxy_spec = containers['grpc-cache-proxy']
        else:
            proxy_pod, _ = render(self.directory, True)
            proxy_spec = next(c for c in proxy_pod['containers'] if c['name'] == 'grpc-cache-proxy')
        self.sandbox = self.prefix + '-pod'
        self.create(self.sandbox, '--network', self.network,
                    '--add-host', 'host.docker.internal:host-gateway',
                    '-p', '127.0.0.1::8980', '-p', '127.0.0.1::50081',
                    '--entrypoint', '/bin/sleep', proxy_spec['image'], 'infinity')
        docker('start', self.sandbox)
        backend_host = self.client_container or 'host.docker.internal'
        # Keep the chart's actual gRPC/auth/shutdown config. CAS, AC and tracing
        # are independent of Execution and would require unrelated services.
        isolated = {key: config[key] for key in
                    ('grpcServers', 'maximumMessageSizeBytes', 'executeAuthorizer')}
        isolated['schedulers'] = {'': {'endpoint': {
            'address': f'{backend_host}:{self.scheduler_port}'}}}
        if immediate_stop:
            for server in isolated['grpcServers']:
                server['stopGracefully'] = False
        self.config = self.directory / 'frontend.json'
        self.config.write_text(json.dumps(isolated))
        self.frontend = self.prefix + '-frontend'
        self.create(self.frontend, '--network', 'container:' + self.sandbox,
                    frontend['image'], '/frontend.json')
        docker('cp', str(self.config), self.frontend + ':/frontend.json')
        docker('start', self.frontend)
        self.wait_ready(8980)
        if proxy:
            self.proxy = self.prefix + '-proxy'
            env = {entry['name']: entry['value'] for entry in proxy_spec['env'] if 'value' in entry}
            env.update({'PROXY_HOST': '127.0.0.1',
                        'OTEL_EXPORTER_OTLP_ENDPOINT': f'http://{backend_host}:{self.scheduler_port}',
                        'OTEL_INTERVAL': '1h'})
            self.drain_delay = float(env['SHUTDOWN_DRAIN_DELAY'].removesuffix('s'))
            self.rpc_grace = float(env['SHUTDOWN_TIMEOUT'].removesuffix('s'))
            env_args = [arg for key, value in env.items() for arg in ('-e', f'{key}={value}')]
            self.create(self.proxy, '--network', 'container:' + self.sandbox,
                        *env_args, proxy_spec['image'])
            docker('start', self.proxy)
            self.wait_ready(50081)
        self.channel = grpc.insecure_channel(self.address(50081 if proxy else 8980))
        self.addCleanup(self.channel.close)
        self.rpc = self.channel.unary_stream(
            '/build.bazel.remote.execution.v2.Execution/Execute',
            request_serializer=lambda request: request.SerializeToString(),
            response_deserializer=self.Operation.FromString)

    def address(self, port):
        if self.client_container:
            return f'{self.sandbox}:{port}'
        return docker('port', self.sandbox, f'{port}/tcp').stdout.strip()

    def logs(self, name):
        result = docker('logs', name, check=False)
        return result.stdout + result.stderr

    def wait_ready(self, port):
        with grpc.insecure_channel(self.address(port)) as channel:
            try:
                grpc.channel_ready_future(channel).result(timeout=20)
            except grpc.FutureTimeoutError:
                self.fail('\n'.join(self.logs(name) for name in self.containers))

    def held_call(self):
        request = self.ExecuteRequest()
        request.action_digest.hash = 'a' * 64
        request.action_digest.size_bytes = 1
        call = self.rpc(request, timeout=self.pod_grace + 5)
        self.addCleanup(call.cancel)
        self.assertFalse(next(call).done)  # Confirms all real forwarding hops.
        self.assertEqual(self.calls, 1)
        return call

    def reject_new_call(self):
        with self.assertRaises(grpc.RpcError) as error:
            next(self.rpc(self.ExecuteRequest(), timeout=1))
        self.assertEqual(error.exception.code(), grpc.StatusCode.UNAVAILABLE)
        self.assertEqual(self.calls, 1, 'draining frontend admitted a new Execute')

    def complete_call(self, call):
        self.assertTrue(call.is_active(), 'active Execute was cancelled during shutdown')
        self.release.set()
        results = list(call)
        self.assertEqual(len(results), 1)
        self.assertTrue(results[0].done)
        result = self.ExecuteResponse()
        self.assertTrue(results[0].response.Unpack(result))
        self.assertEqual(result.result.exit_code, 0)
        self.assertEqual(call.code(), grpc.StatusCode.OK)

    def wait_exit(self, name, timeout):
        result = docker('wait', name, timeout=timeout)
        self.assertIn(int(result.stdout.strip()), (0, 143), self.logs(name))

    def terminate_frontend_at(self, started):
        # Emulate kubelet's native preStop sleep, which consumes pod grace.
        time.sleep(max(0, started + self.hold - time.monotonic()))
        self.assertEqual(docker('inspect', '-f', '{{.State.Running}}', self.frontend).stdout.strip(), 'true')
        docker('kill', '--signal', 'TERM', self.frontend)
        self.wait_exit(self.frontend, self.pod_grace - self.hold)
        self.assertLess(time.monotonic() - started, self.pod_grace)

    def test_proxy_completes_active_execute_and_rejects_new_calls(self):
        self.start()
        call = self.held_call()
        started = time.monotonic()
        docker('kill', '--signal', 'TERM', self.proxy)
        time.sleep(self.drain_delay + 0.3)
        self.reject_new_call()
        self.complete_call(call)
        self.wait_exit(self.proxy, self.rpc_grace + 5)
        self.assertNotIn('graceful stop timed out', self.logs(self.proxy))
        self.terminate_frontend_at(started)

    def test_frontend_sigterm_preserves_active_execute_without_proxy(self):
        self.start(proxy=False)
        call = self.held_call()
        started = time.monotonic()
        time.sleep(self.hold)
        docker('kill', '--signal', 'TERM', self.frontend)
        time.sleep(0.3)
        self.reject_new_call()
        self.complete_call(call)
        self.wait_exit(self.frontend, 5)
        self.assertLess(time.monotonic() - started, self.pod_grace)

    def test_stuck_execute_is_bounded_by_proxy_rpc_grace(self):
        self.start()
        call = self.held_call()
        started = time.monotonic()
        docker('kill', '--signal', 'TERM', self.proxy)
        with self.assertRaises(grpc.RpcError) as error:
            list(call)
        self.assertEqual(error.exception.code(), grpc.StatusCode.UNAVAILABLE)
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, self.drain_delay + self.rpc_grace - 0.2)
        self.assertLess(elapsed, self.drain_delay + self.rpc_grace + 5)
        self.wait_exit(self.proxy, 6)
        self.assertIn('graceful stop timed out', self.logs(self.proxy))
        self.terminate_frontend_at(started)

    def test_immediate_stop_negative_control_interrupts_active_execute(self):
        self.start(proxy=False, immediate_stop=True)
        call = self.held_call()
        docker('kill', '--signal', 'TERM', self.frontend)
        with self.assertRaises(grpc.RpcError) as error:
            list(call)
        self.assertEqual(error.exception.code(), grpc.StatusCode.UNAVAILABLE)
        self.wait_exit(self.frontend, 5)


if __name__ == '__main__':
    unittest.main(verbosity=2)
