# abseil-cpp

- repository: https://github.com/abseil/abseil-cpp
- latest tested revision: 267879b45aabbebdab0eb9d8bc9e217b3390eb6c

## Bazel Version

The project is configured to use Bazel version 9.0.0.
If you are using Bazelisk, then set `USE_BAZEL_VERSION=9.0.0`.

## C/C++ Toolchain

The project is configured to use the locally installed C/C++ toolchain. This toolchain is likely to differ from the one installed on the Hermetiq remote execution nodes. Apply the following patch to configure a hermetic C/C++ toolchain:

```patch
diff --git a/MODULE.bazel b/MODULE.bazel
index edb49d0b..994a6d7f 100644
--- a/MODULE.bazel
+++ b/MODULE.bazel
@@ -20,10 +20,9 @@ module(
     compatibility_level = 1,
 )

-cc_configure = use_extension("@rules_cc//cc:extensions.bzl",
-                             "cc_configure_extension",
-                             dev_dependency = True)
-use_repo(cc_configure, "local_config_cc")
+bazel_dep(name = "llvm", version = "0.6.0")
+
+register_toolchains("@llvm//toolchain:all")

 bazel_dep(name = "rules_cc", version = "0.2.9")
 bazel_dep(name = "bazel_skylib", version = "1.8.1")
```

## Project Configuration
 
The project can be built in several configurations. Examples can be found in the `ci` directory.
One important configuration is the location of timezone information data required by some of the tests.
Apply the following flags:

```
--compilation_mode=opt
--copt="-fexceptions"
--copt="-DGTEST_REMOVE_LEGACY_TEST_CASEAPI_=1"
--define="absl=1"
--test_env="GTEST_INSTALL_FAILURE_SIGNAL_HANDLER=1"
--test_tag_filters=-benchmark
--test_env=TZDIR=absl/time/internal/cctz/testdata/zoneinfo
```

### Hermetiq Configuration

Configure the Hermetiq Build Event Protocol (BEP) backend, remote cache, and remote execution for Bazel as follows.

Replace the following placeholders with your Hermetiq account data.

- `$INSTANCE_NAME`: Your Project ID.
- `$CREDENTIAL_HELPER`: Path to your credential helper executable.
- `<your-domain>`: The `hosts.domainBase` you configured for the Hermetiq
  and Buildbarn charts. These examples assume both charts share one base
  domain, giving `bep.<your-domain>` (BEP), `bb.<your-domain>` (Buildbarn
  frontend gRPC), and `dashboard.<your-domain>` (web UI).

```
--bes_instance_name=$INSTANCE_NAME \
--bes_backend=grpcs://bep.<your-domain> \
--bes_timeout=120s \
--bes_results_url=https://dashboard.<your-domain>/build/ \
--bes_upload_mode=wait_for_upload_complete \
--credential_helper="bep.<your-domain>=$CREDENTIAL_HELPER" \
--credential_helper="bb.<your-domain>=$CREDENTIAL_HELPER" \
--build_metadata="COMMIT_SHA=$(git rev-parse HEAD)" \
--build_metadata="REPO=$(git config --get remote.origin.url)" \
--build_metadata="BRANCH=$(git rev-parse --abbrev-ref HEAD)" \
--generate_json_trace_profile \
--experimental_profile_include_primary_output \
--experimental_profile_include_target_label \
--noslim_profile \
--remote_instance_name=$INSTANCE_NAME \
--remote_cache=grpcs://bb.<your-domain> \
--remote_executor=grpcs://bb.<your-domain> \
--remote_timeout=600s \
--remote_default_exec_properties=container-image=docker://ghcr.io/catthehacker/ubuntu:act-22.04
```

To use the operator-managed size-class workers instead of the exact Ubuntu
image pool, replace the final platform property with:

```text
--remote_default_exec_properties=pool=sizeclass
```

### Build Targets

The following command should succeed provided that the configuration above is applied.

```
bazel test //absl/...
```
