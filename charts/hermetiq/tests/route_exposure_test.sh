#!/usr/bin/env bash
# Full renders include validate.yaml, which single-template unit tests can skip.
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$chart_dir" <<'PY'
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

chart = Path(sys.argv.pop())
snippet_key = 'nginx.ingress.kubernetes.io/configuration-snippet'
snippet = 'more_set_headers "X-Example: value";'


def render(settings, chart_path=chart):
    command = ['helm', 'template', 'route-check', str(chart_path),
               '-f', str(chart_path / 'ci-values/ci.yaml')]
    for key, value in settings.items():
        command += ['--set-json', key + '=' + json.dumps(value)]
    return subprocess.run(command, text=True, capture_output=True)


class RouteExposureTests(unittest.TestCase):
    def test_removing_public_grafana_route_keeps_backend_isolated(self):
        result = render({'gateway.routes.grafanaEnabled': False})
        self.assertEqual(result.returncode, 0, result.stderr)
        resources = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        policies = [doc for doc in resources if doc['kind'] == 'NetworkPolicy']
        self.assertEqual([doc['metadata']['name'] for doc in policies],
                         ['grafana-from-oauth2-proxy'])
        self.assertEqual(policies[0]['spec']['ingress'], [{
            'ports': [{'protocol': 'TCP', 'port': 3000}],
            'from': [
                {'podSelector': {'matchLabels': {'app': 'grafana-oauth2-proxy'}}},
                {'podSelector': {'matchLabels': {'app.kubernetes.io/name': 'vmagent'}}},
            ],
        }])
        self.assertFalse(any(doc['metadata']['name'] == 'grafana-oauth2-proxy'
                             for doc in resources))

    def test_custom_snippets_do_not_collide_when_no_headers_are_removed(self):
        for source in ('commonAnnotations', 'ingress.apiWeb.annotations'):
            with self.subTest(source=source):
                result = render({
                    'routing.provider': 'ingress',
                    'ingress.apiWeb.stripIdentityHeaders': True,
                    'gateway.routes.apiWebRemoveRequestHeaders': [],
                    source: {snippet_key: snippet},
                })
                self.assertEqual(result.returncode, 0, result.stderr)
                ingress = next(doc for doc in yaml.safe_load_all(result.stdout)
                               if doc and doc['kind'] == 'Ingress'
                               and doc['metadata']['name'] == 'api-web')
                self.assertEqual(ingress['metadata']['annotations'][snippet_key], snippet)

    def test_generated_snippet_rejects_both_annotation_collision_sources(self):
        for source in ('commonAnnotations', 'ingress.apiWeb.annotations'):
            with self.subTest(source=source):
                result = render({
                    'routing.provider': 'ingress',
                    'ingress.apiWeb.stripIdentityHeaders': True,
                    source: {snippet_key: snippet},
                })
                self.assertNotEqual(result.returncode, 0,
                                    'render accepted conflicting ' + source)
                self.assertIn('remove it from ' + source, result.stderr)


class ReusedValuesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # --reuse-values uses the previous release's defaults. Passing an old
        # values file with -f would silently merge in the new defaults and miss
        # precisely this migration failure, so remove the new keys from a copy
        # of the chart's own values.yaml instead.
        cls.temporary = tempfile.TemporaryDirectory(prefix='hermetiq-legacy-values-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.chart = Path(cls.temporary.name) / 'hermetiq'
        shutil.copytree(chart, cls.chart)
        values_file = cls.chart / 'values.yaml'
        values = yaml.safe_load(values_file.read_text())
        del values['grafana']['networkPolicy']
        del values['gateway']['routes']['bepGrpcServices']
        del values['gateway']['routes']['apiWebRemoveRequestHeaders']
        del values['ingress']['apiWeb']['stripIdentityHeaders']
        values_file.write_text(yaml.safe_dump(values))

    def resources(self, settings):
        result = render(settings, self.chart)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {doc['metadata']['name']: doc
                for doc in yaml.safe_load_all(result.stdout) if doc
                and doc['kind'] in ('NetworkPolicy', 'GRPCRoute', 'HTTPRoute',
                                    'HTTPProxy', 'Ingress')}

    def test_legacy_defaults_retain_new_protections_for_every_routing_provider(self):
        headers = ['X-Forwarded-User', 'X-Forwarded-Email', 'X-Forwarded-Groups',
                   'X-Forwarded-Preferred-Username', 'X-Hermetiq-Project-Id']
        service = 'google.devtools.build.v1.PublishBuildEvent'
        for provider in ('gateway', 'gateway-httproute-only', 'contour', 'ingress'):
            with self.subTest(provider=provider):
                resources = self.resources({
                    'routing.provider': provider,
                    'gateway.name': 'test-gateway',
                    'ingress.apiWeb.stripIdentityHeaders': True,
                })
                policy = resources['grafana-from-oauth2-proxy']['spec']
                self.assertEqual(policy['podSelector'], {
                    'matchLabels': {'app.kubernetes.io/name': 'grafana'}})
                self.assertEqual(policy['ingress'][0]['ports'], [
                    {'protocol': 'TCP', 'port': 3000}])
                self.assertEqual(policy['ingress'][0]['from'], [
                    {'podSelector': {'matchLabels': {'app': 'grafana-oauth2-proxy'}}},
                    {'podSelector': {'matchLabels': {'app.kubernetes.io/name': 'vmagent'}}},
                ])
                bep = resources['bep-cloud-grpc']['spec']
                api = resources['api-web']
                if provider == 'gateway':
                    self.assertEqual(bep['rules'][0]['matches'], [
                        {'method': {'service': service}}])
                elif provider == 'gateway-httproute-only':
                    self.assertEqual(bep['rules'][0]['matches'], [
                        {'path': {'type': 'PathPrefix', 'value': '/' + service + '/'}}])
                elif provider == 'contour':
                    self.assertEqual(bep['routes'][0]['conditions'], [
                        {'prefix': '/' + service + '/'}])
                else:
                    self.assertEqual(len(bep['rules'][0]['http']['paths']), 1)
                    self.assertEqual(bep['rules'][0]['http']['paths'][0]['path'],
                                     '/' + service + '/')
                if provider.startswith('gateway'):
                    self.assertEqual(api['spec']['rules'][0]['filters'][0]
                                     ['requestHeaderModifier']['remove'], headers)
                elif provider == 'contour':
                    self.assertEqual(api['spec']['routes'][0]
                                     ['requestHeadersPolicy']['remove'], headers)
                else:
                    self.assertEqual(api['metadata']['annotations'][snippet_key],
                                     ''.join('proxy_set_header ' + header + ' "";\n'
                                             for header in headers))

    def test_legacy_values_keep_explicit_policy_and_header_opt_outs(self):
        resources = self.resources({
            'routing.provider': 'gateway',
            'gateway.name': 'test-gateway',
            'grafana.networkPolicy.enabled': False,
            'gateway.routes.apiWebRemoveRequestHeaders': [],
        })
        self.assertNotIn('grafana-from-oauth2-proxy', resources)
        self.assertNotIn('filters', resources['api-web']['spec']['rules'][0])

    def test_partial_policy_override_preserves_empty_scraper_list(self):
        resources = self.resources({'grafana.networkPolicy.scrapersFrom': []})
        policy = resources['grafana-from-oauth2-proxy']['spec']
        self.assertEqual(policy['ingress'], [{
            'ports': [{'protocol': 'TCP', 'port': 3000}],
            'from': [{'podSelector': {'matchLabels': {'app': 'grafana-oauth2-proxy'}}}],
        }])


unittest.main()
PY
