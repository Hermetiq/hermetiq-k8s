load("@rules_go//go:def.bzl", "go_library", "go_test")

go_library(
    name = "redisclient",
    srcs = ["redisclient.go"],
    importpath = "github.com/hermetiq/testcontainers-example/redisclient",
    visibility = ["//visibility:public"],
    deps = [
        "@com_github_redis_go_redis_v9//:go-redis",
    ],
)

go_test(
    name = "redisclient_test",
    srcs = ["redisclient_test.go"],
    embed = [":redisclient"],
    # Bazel's test wrapper strips environment by default — anything bb_worker
    # injects via its `environmentVariables` config (DOCKER_HOST etc.) does
    # NOT reach the test binary. So we set the vars Testcontainers needs
    # directly on the target, where Bazel will preserve them.
    env = {
        "DOCKER_HOST": "unix:///var/run/docker.sock",
        "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE": "/var/run/docker.sock",
        "TESTCONTAINERS_HOST_OVERRIDE": "localhost",
        # Ryuk is left enabled (default) — the chart's DinD sidecar provides it.
    },
    # `exec_properties` adds platform properties to actions produced for this
    # target (compile, link, test). The Buildbarn scheduler routes by exact-match
    # equality on these properties: a worker advertising `pool=testcontainers`
    # is the one that will pick up these actions.
    #
    # NOTE: this scopes all actions of this target -- compile and link too -- to
    # the Testcontainers worker fleet, not just the test action. It does not
    # route unrelated host/toolchain actions; set --remote_default_exec_properties
    # in your Bazel invocation for those.
    exec_properties = {
        "pool": "testcontainers",
    },
    # Tag kept as informational metadata (queryable via `bazel query`).
    # It is NOT used for routing — see exec_properties above.
    tags = ["requires-docker"],
    deps = [
        "@com_github_testcontainers_testcontainers_go_modules_redis//:redis",
    ],
)
