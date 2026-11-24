#!/usr/bin/env python3
"""Exercise real gateway/OAuth/nginx/gRPC-web hops with a disposable fixture API.

Requires docker, helm, and PyYAML. Pulls pinned public images and builds a small
test image. Runtime containers have no host mounts, exposed ports, credentials,
or external networking. Does not require a cluster or private source checkout.
"""

import copy
import json
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

import yaml


CHART = Path(__file__).resolve().parents[1]
FIXTURE = Path(__file__).with_name("browser_integration")
ENVOY = "envoyproxy/envoy:v1.37.2@sha256:c5e8a68e52f4d4697a9adb280dbe415d77fedf1257e183dcb86205bd438f18bd"
NGINX = "nginx:1.28.0-alpine@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284"
OAUTH = "us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/oauth2-proxy:v7.15.6@sha256:c3415e8660af553f5e18f5d90db050614c02493c0ac6260ac59442f6d9b12048"
PROXY = "us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/grpc-auth-proxy:v0.9.8@sha256:8555a0160ab6adc41a02c029f0eca5a6c3277a7c00c167bff7f73c1459e769dc"


def run(*args, timeout=180, check=True, include_stderr=False):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
    return (result.stdout + (result.stderr if include_stderr else "")).strip()


def rendered_chart():
    output = run("helm", "template", "browser-integration", str(CHART),
                 "--namespace", "integration", "-f", str(CHART / "ci-values/ci.yaml"),
                 "--set", "routing.provider=gateway", "--set", "gateway.name=eg",
                 "--set", "gateway.namespace=integration", "--set", "hosts.dashboard=dashboard.test",
                 "--set-json", 'dashboard.oauth2Proxy.emailDomains=["example.test"]')
    documents = [doc for doc in yaml.safe_load_all(output) if doc]
    policies = [doc for doc in documents if doc["kind"] == "EnvoyPatchPolicy"]
    assert len(policies) == 1, "chart must render exactly one dashboard EnvoyPatchPolicy"
    config = next(doc["data"] for doc in documents
                  if doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == "oauth2-proxy-config-web-ui")
    return policies[0], config


def route_config(with_sibling=False):
    dashboard = {"name": "generated-dashboard-name", "domains": ["dashboard.test", "dashboard.test:8080"],
                 "routes": [{"match": {"prefix": "/"}, "route": {"cluster": "oauth", "timeout": "30s"}}]}
    if with_sibling:
        dashboard["typed_per_filter_config"] = {"envoy.filters.http.cors": {
            "@type": "type.googleapis.com/envoy.extensions.filters.http.cors.v3.CorsPolicy",
            "allow_origin_string_match": [{"exact": "https://control.test"}], "allow_methods": "POST"}}
    return {"name": "integration/eg/https", "virtual_hosts": [
        {"name": "generated-api-name", "domains": ["api.test", "api.test:8080"],
         "routes": [{"match": {"prefix": "/"}, "route": {"cluster": "auth-proxy", "timeout": "30s"}}]},
        dashboard,
    ]}


def apply_rendered_policy(route, policy):
    """Apply the rendered leaf operations with Envoy Gateway add semantics.

    Restrict this adapter to the chart's supported selector so drift fails the
    test; the test never substitutes a hardcoded per-filter disable value.
    """
    before_api = copy.deepcopy(route["virtual_hosts"][0])
    before_filters = copy.deepcopy(route["virtual_hosts"][1].get("typed_per_filter_config", {}))
    applied = 0
    for patch in policy["spec"]["jsonPatches"]:
        assert patch["type"] == "type.googleapis.com/envoy.config.route.v3.RouteConfiguration"
        if patch["name"] != route["name"]:
            continue
        operation = patch["operation"]
        assert operation["op"] == "add"
        match = re.fullmatch(r'\$\.virtual_hosts\[\?\(@\.domains\[0\] == (".*")\)\]', operation["jsonPath"])
        assert match, "unexpected chart JSONPath: " + operation["jsonPath"]
        host = json.loads(match[1])
        targets = [vhost for vhost in route["virtual_hosts"] if vhost["domains"][0] == host]
        assert len(targets) == 1, "rendered policy must select exactly the dashboard virtual host"
        path = [part.replace("~1", "/").replace("~0", "~") for part in operation["path"].split("/")[1:]]
        target = targets[0]
        for part in path[:-1]:
            target = target.setdefault(part, {})
        target[path[-1]] = copy.deepcopy(operation["value"])
        applied += 1
    assert applied == 1, "rendered policy did not target the fixture listener"
    assert route["virtual_hosts"][0] == before_api, "dashboard policy changed the API virtual host"
    for name, value in before_filters.items():
        assert route["virtual_hosts"][1]["typed_per_filter_config"][name] == value, "policy replaced a sibling filter"


def envoy_config(route):
    def cluster(name, host, port, h2=False):
        result = {"name": name, "type": "STRICT_DNS", "connect_timeout": "2s",
                  "load_assignment": {"cluster_name": name, "endpoints": [{"lb_endpoints": [{"endpoint": {
                      "address": {"socket_address": {"address": host, "port_value": port}}}}]}]}}
        if h2:
            result["typed_extension_protocol_options"] = {
                "envoy.extensions.upstreams.http.v3.HttpProtocolOptions": {
                    "@type": "type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions",
                    "explicit_http_config": {"http2_protocol_options": {}}}}
        return result
    return {"static_resources": {"listeners": [{"name": "shared-listener", "address": {
        "socket_address": {"address": "0.0.0.0", "port_value": 8080}}, "filter_chains": [{"filters": [{
            "name": "envoy.filters.network.http_connection_manager", "typed_config": {
                "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                "stat_prefix": "ingress", "codec_type": "AUTO", "route_config": route,
                "http_filters": [
                    {"name": "envoy.filters.http.grpc_web", "typed_config": {
                        "@type": "type.googleapis.com/envoy.extensions.filters.http.grpc_web.v3.GrpcWeb"}},
                    {"name": "envoy.filters.http.cors", "typed_config": {
                        "@type": "type.googleapis.com/envoy.extensions.filters.http.cors.v3.Cors"}},
                    {"name": "envoy.filters.http.router", "typed_config": {
                        "@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"}},
                ]}}]}]}], "clusters": [cluster("oauth", "oauth", 8888), cluster("auth-proxy", "auth-proxy", 50091, True)]}}


def main():
    policy, oauth_env = rendered_chart()
    suffix = uuid.uuid4().hex[:10]
    network = "hermetiq-browser-" + suffix
    fixture_image = "hermetiq-browser-fixture:" + suffix
    containers = []
    volumes = []
    limits = ["--user=65532:65532", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--pids-limit=64",
              "--memory=256m", "--cpus=1", "--tmpfs=/tmp:rw,noexec,nosuid,size=32m"]
    try:
        for image, platform in ((ENVOY, None), (NGINX, None), (OAUTH, None), (PROXY, "linux/amd64")):
            if not json.loads(run("docker", "image", "inspect", image, check=False) or "[]"):
                run("docker", "pull", *(["--platform", platform] if platform else []), image, timeout=300)
        print("Building disposable issuer/API fixture", flush=True)
        run("docker", "build", "--tag", fixture_image, str(FIXTURE), timeout=600)
        run("docker", "network", "create", "--internal", network)

        def start(name, image, args=(), env=None, aliases=(), copy_files=None, platform=None, entrypoint=None):
            full_name = network + "-" + name
            command = ["docker", "create", "--name", full_name, "--network", network,
                       "--network-alias", name, *limits]
            if copy_files:
                volume = full_name + "-config-" + uuid.uuid4().hex[:6]
                run("docker", "volume", "create", volume)
                volumes.append(volume)
                loader = volume + "-loader"
                run("docker", "create", "--name", loader, "--network", "none",
                    "--mount", f"type=volume,source={volume},target=/config", fixture_image, "serve")
                try:
                    for source, destination in copy_files.items():
                        run("docker", "cp", str(source), loader + ":/config/" + Path(destination).name)
                finally:
                    run("docker", "rm", "-f", loader, check=False)
                command += ["--mount", f"type=volume,source={volume},target=/fixture,readonly"]
            for alias in aliases:
                command += ["--network-alias", alias]
            if platform:
                command += ["--platform", platform]
            if entrypoint:
                command += ["--entrypoint", entrypoint]
            for key, value in (env or {}).items():
                command += ["--env", f"{key}={value}"]
            run(*command, image, *args)
            containers.append(full_name)
            run("docker", "start", full_name)
            return full_name

        def fixture_command(*args):
            client = network + "-client-" + uuid.uuid4().hex[:6]
            containers.append(client)
            try:
                output = run("docker", "run", "--name", client, "--rm", "--network", network,
                             *limits, fixture_image, *args)
                if output:
                    print(output, flush=True)
            finally:
                run("docker", "rm", "-f", client, check=False)
                containers.remove(client)

        start("fixture", fixture_image, ("serve",))
        fixture_command("wait", "http://fixture:8000/ready")
        start("auth-proxy", PROXY, env={"PROXY_HOST": "fixture", "PROXY_PORT": "50092",
              "GRPC_PORT": "50091", "JWT_AUTH_ENABLED": "true", "JWT_JWKS_URL": "http://fixture:8000/jwks",
              "JWT_ISSUER": "http://fixture:8000", "JWT_AUDIENCE": "dashboard-client",
              "HERMETIQ_ADMIN_GROUP": "fixture-admins", "GRPC_AUTH_PROXY_ENDPOINT_DRAIN_DELAY": "0s"},
              platform="linux/amd64")
        start("nginx", NGINX, ("-c", "/fixture/nginx.conf", "-g", "daemon off;"),
              entrypoint="nginx", copy_files={FIXTURE / "nginx.conf": "/fixture/nginx.conf"})
        oauth_env.update({"OAUTH2_PROXY_OIDC_ISSUER_URL": "http://fixture:8000",
            "OAUTH2_PROXY_CLIENT_ID": "dashboard-client", "OAUTH2_PROXY_CLIENT_SECRET": "fixture-client-secret",
            "OAUTH2_PROXY_COOKIE_SECRET": "0123456789abcdef0123456789abcdef",
            "OAUTH2_PROXY_COOKIE_SECURE": "false", "OAUTH2_PROXY_UPSTREAMS": "http://nginx:3000",
            "OAUTH2_PROXY_REDIRECT_URL": "http://dashboard.test:8080/oauth2/callback",
            "OAUTH2_PROXY_SKIP_JWT_BEARER_TOKENS": "true", "OAUTH2_PROXY_COOKIE_DOMAINS": "",
            "OAUTH2_PROXY_WHITELIST_DOMAINS": "dashboard.test:8080", "OAUTH2_PROXY_REQUEST_LOGGING": "false"})
        start("oauth", OAUTH, env=oauth_env)
        fixture_command("wait", "http://oauth:8888/ping")
        with tempfile.TemporaryDirectory(prefix="hermetiq-browser-config-") as temporary:
            config_path = Path(temporary) / "envoy.json"
            for phase in ("broken", "fixed-new-filter-map", "fixed-existing-filter-map"):
                route = route_config(with_sibling=phase == "fixed-existing-filter-map")
                if phase != "broken":
                    apply_rendered_policy(route, policy)
                config_path.write_text(json.dumps(envoy_config(route)))
                gateway = start("gateway", ENVOY, ("-c", "/fixture/envoy.json", "--concurrency", "1", "--log-level", "warn"),
                                aliases=("dashboard.test", "api.test"),
                                copy_files={config_path: "/fixture/envoy.json"})
                fixture_command("wait", "http://dashboard.test:8080/ping")
                fixture_command("client", phase)
                run("docker", "rm", "-f", gateway)
                containers.remove(gateway)
        print("Browser gateway transport integration passed", flush=True)
    except Exception:
        for container in containers:
            output = run("docker", "logs", "--tail", "35", container, check=False, include_stderr=True)
            if output:
                print(container + " logs:\n" + output, flush=True)
        raise
    finally:
        for container in reversed(containers):
            run("docker", "rm", "-f", container, check=False)
        for volume in reversed(volumes):
            run("docker", "volume", "rm", volume, check=False)
        run("docker", "network", "rm", network, check=False)
        run("docker", "image", "rm", fixture_image, check=False)


if __name__ == "__main__":
    main()
