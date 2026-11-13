# Siso backend config for a Hermetiq-hosted Buildbarn: the platform every
# remote action asks for. It must match the RbeWorker pools' platformProperties.
# Both the default and the large platform use the same properties; Buildbarn's
# size classes, not the client, pick the worker size.

load("@builtin//struct.star", "module")

def __platform_properties(ctx):
    props = {
        "OSFamily": "Linux",
        "container-image": "docker://gcr.io/chops-public-images-prod/rbe/siso-chromium/linux@sha256:d7cb1ab14a0f20aa669c23f22c15a9dead761dcac19f43985bf9dd5f41fbef3a",
    }
    return {
        "default": props,
        "large": props,
    }

backend = module(
    "backend",
    platform_properties = __platform_properties,
)
