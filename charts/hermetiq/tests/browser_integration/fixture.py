"""Disposable JWT issuer and fixture API, not the Hermetiq API implementation.

The two real RPC names exercise the production proxy path. Role checks here
provide deterministic positive/negative transport cases; application permission
semantics require separate tests against an authorization-capable API image.
"""

import argparse
import base64
from concurrent import futures
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import struct
import threading
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives.asymmetric import rsa
import grpc
import jwt


ISSUER = "http://fixture:8000"
AUDIENCE = "dashboard-client"
METHODS = ("GetProjects", "GetUsageMetrics")
SERVICE = "admin.v1.AdminService"


def serve():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update(kid="integration", use="sig", alg="RS256")

    def token(admin):
        return jwt.encode(
            {"iss": ISSUER, "aud": AUDIENCE, "sub": "admin" if admin else "viewer",
             "email": "test@example.test", "email_verified": True,
             "name": "Integration fixture", "groups": ["fixture-admins"] if admin else [],
             "iat": int(time.time()), "exp": int(time.time()) + 3600},
            key, algorithm="RS256", headers={"kid": "integration"},
        )

    class HTTP(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/.well-known/openid-configuration":
                data = {"issuer": ISSUER, "jwks_uri": ISSUER + "/jwks",
                        "authorization_endpoint": ISSUER + "/unused-authorize",
                        "token_endpoint": ISSUER + "/unused-token",
                        "userinfo_endpoint": ISSUER + "/unused-userinfo",
                        "response_types_supported": ["code"],
                        "subject_types_supported": ["public"],
                        "id_token_signing_alg_values_supported": ["RS256"]}
            elif self.path == "/jwks":
                data = {"keys": [jwk]}
            elif self.path == "/tokens":
                data = {"admin": token(True), "viewer": token(False)}
            elif self.path == "/ready":
                data = {"ready": True}
            else:
                self.send_error(404)
                return
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    def rpc(_request, context):
        bearer = dict(context.invocation_metadata()).get("authorization", "")
        try:
            claims = jwt.decode(bearer.removeprefix("Bearer "), key.public_key(),
                                algorithms=["RS256"], audience=AUDIENCE, issuer=ISSUER)
        except jwt.PyJWTError:
            context.abort(grpc.StatusCode.UNAUTHENTICATED, "fixture requires a valid JWT")
        if "fixture-admins" not in claims.get("groups", []):
            context.abort(grpc.StatusCode.PERMISSION_DENIED, "fixture administrator required")
        context.set_trailing_metadata((("fixture-authorized", "true"),))
        # Valid protobuf wire data without importing private application protos.
        return b"\x0a\x07fixture"

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    server.add_generic_rpc_handlers((grpc.method_handlers_generic_handler(
        SERVICE, {name: grpc.unary_unary_rpc_method_handler(
            rpc, request_deserializer=lambda raw: raw, response_serializer=lambda raw: raw,
        ) for name in METHODS}),))
    server.add_insecure_port("0.0.0.0:50092")
    server.start()
    threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", 8000), HTTP).serve_forever,
                     daemon=True).start()
    print("Fixture issuer and API ready", flush=True)
    server.wait_for_termination()


def request(url, data=None, headers=None, timeout=15):
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *_args, **_kwargs):
            return None

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(urllib.request.Request(url, data=data, headers=headers or {}), timeout=timeout) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def decode_frames(body, text_mode):
    if text_mode:
        # grpc-web-text permits separately padded base64 chunks on flush.
        chunks = re.findall(rb"[^=]+={1,2}|[^=]+$", body)
        body = b"".join(base64.b64decode(chunk) for chunk in chunks)
    messages, trailers = [], {}
    while body:
        assert len(body) >= 5, "truncated gRPC-web frame header"
        flag, length = struct.unpack(">BI", body[:5])
        frame, body = body[5:5 + length], body[5 + length:]
        assert len(frame) == length, "truncated gRPC-web frame"
        if flag & 0x80:
            for line in frame.decode().split("\r\n"):
                if ":" in line:
                    name, value = line.split(":", 1)
                    trailers[name.lower()] = value.strip()
        else:
            messages.append(frame)
    return messages, trailers


def call(host, method, bearer=None, text_mode=True, spoof=False):
    content_type = "application/grpc-web-text+proto" if text_mode else "application/grpc-web+proto"
    body = struct.pack(">BI", 0, 0)
    if text_mode:
        body = base64.b64encode(body)
    headers = {"Content-Type": content_type, "Accept": content_type,
               "X-Grpc-Web": "1", "X-Requested-With": "XMLHttpRequest"}
    if bearer:
        headers["Authorization"] = "Bearer " + bearer
    if spoof:
        headers.update({"X-Forwarded-Groups": "fixture-admins", "X-Hermetiq-Admin": "true"})
    prefix = "/grpc" if host == "dashboard.test" else ""
    return request(f"http://{host}:8080{prefix}/{SERVICE}/{method}", body, headers)


def client(phase):
    tokens = json.loads(request(ISSUER + "/tokens")[2])
    for text_mode in (True, False):
        for method in METHODS:
            code, headers, body = call("dashboard.test", method, tokens["admin"], text_mode)
            if phase == "broken":
                assert code == 505, f"broken control {method}: expected HTTP 505, got {code}, {body[:200]!r}"
                continue
            assert code == 200, f"{method}: HTTP {code}: {body[:200]!r}"
            messages, trailers = decode_frames(body, text_mode)
            assert trailers.get("grpc-status") == "0", (method, trailers)
            assert trailers.get("fixture-authorized") == "true", (method, trailers)
            assert messages == [b"\x0a\x07fixture"], (method, messages)
    if phase == "broken":
        print("PASS: unpatched gateway reproduces HTTP 505 for both RPCs and encodings")
        return
    for method in METHODS:
        code, headers, body = call("dashboard.test", method, tokens["viewer"], spoof=True)
        assert code == 200, f"viewer {method}: unexpected HTTP {code}: {body[:100]!r}"
        messages, trailers = decode_frames(body, True)
        # A trailers-only gRPC denial may put grpc-status in HTTP headers.
        status = trailers.get("grpc-status") or {name.lower(): value for name, value in headers.items()}.get("grpc-status")
        assert status == "7" and not any(messages), (method, headers, trailers, body[:100])
        for bearer in (None, "invalid.jwt.signature"):
            code, headers, body = call("dashboard.test", method, bearer)
            assert code in (302, 401, 403), f"unauthenticated {method}: HTTP {code}, {body[:100]!r}"
            if code == 302:
                location = {name.lower(): value for name, value in headers.items()}.get("location", "")
                assert location.startswith(ISSUER + "/unused-authorize?"), "unexpected authentication redirect"
        # The unrelated API virtual host must retain gateway translation and h2.
        code, headers, body = call("api.test", method, tokens["admin"], text_mode=False)
        assert code == 200, f"API host {method}: HTTP {code}: {body[:100]!r}"
        messages, trailers = decode_frames(body, False)
        assert trailers.get("grpc-status") == "0" and messages, (method, trailers)
    print(f"PASS: {phase}: both RPCs/encodings succeed with status trailers; viewer, invalid and absent JWT denied; API host unaffected")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("serve", "client", "wait"))
    parser.add_argument("target", nargs="?")
    args = parser.parse_args()
    if args.mode == "serve":
        serve()
    elif args.mode == "client":
        client(args.target)
    else:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                if request(args.target, timeout=2)[0] == 200:
                    break
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.5)
        else:
            raise SystemExit("Timed out waiting for " + args.target)
