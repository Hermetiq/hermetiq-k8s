# codex

- repository: https://github.com/openai/codex
- latest tested revision: db5781a08872873a4df82fbb4b3dc6ffd98b5d15

## Bazel Version

The project is configured to use Bazel version 9.0.0.
If you are using Bazelisk, then the version is already configured via `.bazelversion`.

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
--bes_instance_name=$INSTANCE_NAME
--bes_backend=grpcs://bep.<your-domain>
--bes_timeout=120s
--bes_results_url=https://dashboard.<your-domain>/build/
--bes_upload_mode=wait_for_upload_complete

--remote_instance_name=$INSTANCE_NAME
--remote_cache=grpcs://bb.<your-domain>
--credential_helper=bep.<your-domain>=$CREDENTIAL_HELPER
--credential_helper=bb.<your-domain>=$CREDENTIAL_HELPER

--build_metadata="COMMIT_SHA=$(git rev-parse HEAD)"
--build_metadata="REPO=$(git config --get remote.origin.url)"
--build_metadata="BRANCH=$(git rev-parse --abbrev-ref HEAD)"
--generate_json_trace_profile
--experimental_profile_include_primary_output
--experimental_profile_include_target_label
--noslim_profile

--config=remote
--jobs=200
--remote_executor=grpcs://bb.<your-domain>
```

### Build Targets

The following command should succeed provided that the configuration above is applied.

```
bazel test //...
```
