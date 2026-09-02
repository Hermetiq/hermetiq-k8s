load("@rules_go//go:def.bzl", "go_library", "go_test")

go_library(
    name = "vespaclient",
    srcs = ["vespaclient.go"],
    importpath = "github.com/hermetiq/testcontainers-example/vespaclient",
    visibility = ["//visibility:public"],
)

go_test(
    name = "vespaclient_test",
    srcs = ["vespaclient_test.go"],
    embed = [":vespaclient"],
    embedsrcs = [
        "testapp/hosts.xml",
        "testapp/services.xml",
        "testapp/schemas/doc.sd",
    ],
    # Bazel's test wrapper strips environment by default — see redisclient/BUILD
    # for the rationale. These env vars point testcontainers-go at the DinD
    # socket served by the worker pod's sidecar.
    env = {
        "DOCKER_HOST": "unix:///var/run/docker.sock",
        "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE": "/var/run/docker.sock",
        "TESTCONTAINERS_HOST_OVERRIDE": "localhost",
    },
    # Pin this target to the Testcontainers worker fleet that has a DinD
    # sidecar. Set --remote_default_exec_properties in your Bazel invocation for
    # unrelated host/toolchain actions.
    exec_properties = {"pool": "testcontainers"},
    # Vespa cold-start is 30-60s and the deploy/index cycle adds another
    # 15-30s. Default test timeout (`moderate`, 5 min) is enough but cuts it
    # close on a slow registry pull; `long` (15 min) gives headroom.
    timeout = "long",
    tags = ["requires-docker"],
    deps = [
        "@com_github_testcontainers_testcontainers_go//:testcontainers-go",
        "@com_github_testcontainers_testcontainers_go//wait",
    ],
)
