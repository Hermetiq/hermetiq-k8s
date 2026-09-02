# bazel-examples

- repository: https://github.com/bazelbuild/examples.git
- latest tested revision: a788c24f921ec800907c056f4e5e3633c352d13e

## Bazel Version

The repository contains multiple, small, self-contained Bazel example projects.
Each of these provides its own `.bazelversion` file specifying the Bazel version to use.

### Hermetiq Configuration

In each example project configure the Hermetiq Build Event Protocol (BEP) backend, remote cache, and remote execution for Bazel as follows.

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

## Example Projects

### go-tutorial

All stages work with Hermetiq remote execution as configured above.

For stages 1 and 2, use the following command to build the project:
```
bazel build //...
```

For stages 3, use the following command to build and test the project:
```
bazel test //...
```

### rust-tutorial

All Bazel commands shown below assume the Hermetiq remote execution configuration above.

#### 01-hello-world

The project requires a C/C++ toolchain, but the default configuration is not
hermetic and thereby not remote execution compatible.

Add the following to the `MODULE.bazel` file:

```starlark
bazel_dep(name = "toolchains_llvm", version = "1.6.0", dev_dependency = True)
llvm = use_extension("@toolchains_llvm//toolchain/extensions:llvm.bzl", "llvm")
llvm.toolchain(llvm_version = "20.1.4")
use_repo(llvm, "llvm_toolchain")
register_toolchains("@llvm_toolchain//:all")
```

Then run the following commands:

```
bazel build //...
bazel run //:bin
```

#### 02-hello-cross

The project is already correctly configured to work with remote execution,
assuming the Hermetiq configuration from above is applied.

Run the following command:

```
bazel build //...
```

#### 03-comp-opt

The project requires the same configuration as [01-hello-world](#01-hello-world) above.

Run the following commands:

```
bazel build -c opt //...
bazel run -c opt //hello_comp_opt:bin
```

#### 04-ffi

The project requires the same configuration as [01-hello-world](#01-hello-world) above.

Run the following command:

```
bazel build //...
```

#### 05-deps-cargo

The project requires the same configuration as [01-hello-world](#01-hello-world) above.

Run the following command:

```
bazel build //...
```

#### 06-deps-direct

The project requires the same configuration as [01-hello-world](#01-hello-world) above.

Run the following command:

```
bazel build //...
```

Run the following commands in two separate shells:

```
server> bazel run //rest_tokio:bin
[main]: Starting server took 6 ms.

||  Sample Service  ||
==========================================
Service on endpoint: 0.0.0.0:4242/
==========================================

client> curl 0.0.0.0/health
{"status":"OK"}
```

#### 07-deps-vendor

The project requires the same configuration as [01-hello-world](#01-hello-world) above.

Run the following commands:

```
bazel run //thirdparty:crates_vendor
bazel build //...
```

#### 08-grpc-client-server

The project installs an LLVM toolchain, but doesn't register it, and the version used is incompatible with the RBE worker images, `ghcr.io/catthehacker/ubuntu:act-22.04`.

Change the LLVM toolchain configuration in `MODULE.bazel` to match that of [01-hello-world](#01-hello-world) above.

Run the following command:

```
bazel build //...
```

Run the following commands in two separate shells:

```
server> bazel --bazelrc=../../.bazelrc.hermetiq run //grpc_server:bin
GreeterServer listening on [::1]:5042

client> bazel --bazelrc=../../.bazelrc.hermetiq run //grpc_client:bin
RESPONSE=Response { metadata: MetadataMap { headers: {"content-type": "application/grpc", "date": "Mon, 23 Mar 2026 13:28:34 GMT", "grpc-status": "0"} }, message: HelloReply { message: "Hello Hello gRPC!" }, extensions: {} }

server>
Got a request from Some([::1]:56522)
```

#### 09-oci-containers

The project installs an LLVM toolchain, but doesn't register it, and the version used is incompatible with the RBE worker images, `ghcr.io/catthehacker/ubuntu:act-22.04`.

Change the LLVM toolchain configuration in `MODULE.bazel` to match that of [01-hello-world](#01-hello-world) above.

Run the following command:

```
bazel build //...
```

Run the following commands in two separate shells:

```
server> bazel --bazelrc=../../.bazelrc.hermetiq run //tokio_oci:bin
[main]: Starting server took 0 ms.

||  Sample Service  ||
==========================================
Service on endpoint: 0.0.0.0:4242/
==========================================

client> curl 0.0.0.0:4242/health
{"status":"OK"}
```
