# Buildbarn configuration schema fixtures

`../config_schema_test.sh` uses the official Python protobuf JSON parser with
unknown-field rejection. Its checksums pin these fixtures and the fork source.
The fixtures describe accepted protobuf JSON; they do not establish binary
startup, disk-format compatibility, or successful scheduler handover.

## Upstream application descriptors

The two existing descriptor sets are copied byte-for-byte from Hermetiq's
`cloud-native` repository. They are also used by the application configuration
validator. Do not edit their serialized fields to make a chart test pass.

| Fixture | Immutable source |
| --- | --- |
| `buildbarn_descriptors.pb` | [`bep-nats/bbproto/buildbarn_descriptors.pb` at `71b1a01297b3890252435930b39252a47ba5cbd7`](https://github.com/Hermetiq/cloud-native/blob/71b1a01297b3890252435930b39252a47ba5cbd7/bep-nats/bbproto/buildbarn_descriptors.pb) |
| `buildbarn_descriptors_cdc.pb` | [`bep-nats/bbproto/buildbarn_descriptors_cdc.pb` at `c671b03bfff5df4b49072f612b48f09b5a732e32`](https://github.com/Hermetiq/cloud-native/blob/c671b03bfff5df4b49072f612b48f09b5a732e32/bep-nats/bbproto/buildbarn_descriptors_cdc.pb) |

The CDC snapshot's [`upstream-cdc.txt`](https://github.com/Hermetiq/cloud-native/blob/c671b03bfff5df4b49072f612b48f09b5a732e32/bep-nats/bbproto/upstream-cdc.txt)
pins these application revisions:

| Application | Commit |
| --- | --- |
| bb-storage | `8d2acac49b3b17bad8dade297ef98847685d3699` |
| bb-remote-execution | `f22e022dfa042a91c6cd4b57efd537d2fbb75ffb` |
| bb-portal | `a40873368f235611d83f33690e994ef7d7d9fd04` |
| bb-remote-asset | `e72be5ead773d2e1b836ca818d769ff306b1598f` |

The legacy snapshot (`buildbarn_descriptors.pb`) is retained for `bb-browser`
(built from `bb-browser` commit `ee35c54d5cecfc7a763870fe2187c93fa47aaf85` in
`cloud-native/bep-nats/bbproto/upstream.txt`; the pinned `bb-browser` image
`6d856c8` uses the same `ApplicationConfiguration` schema). When refreshing a
base fixture, copy it from the configuration validator's reviewed release,
update its source commit here and its SHA-256 in `config_schema_test.sh`, then
run the full matrix.

## CDC fork scheduler descriptor

`bb_scheduler_fork.proto` is the unmodified scheduler configuration source from
[Hermetiq/bb-remote-execution commit `9f75e926d1d1eaf19ff470e9a5863f895cf19d47`](https://github.com/Hermetiq/bb-remote-execution/blob/9f75e926d1d1eaf19ff470e9a5863f895cf19d47/pkg/proto/configuration/bb_scheduler/bb_scheduler.proto).
It uses the CDC `content_addressable_storage` field and includes configuration
reload, handover listeners, and coordinator configuration. Its license is in
`bb_scheduler_fork.LICENSE`.

`scheduler_fork_descriptors.pb` compiles that source against imports from the
pinned CDC descriptor above. This keeps the fork feature contract separate from
the stock image's schema: tests also verify that stock schemas reject the fork
fields. A deployment still needs an actual CDC-capable fork image; this fixture
is not a claim about an arbitrary image selected by the user.

Regenerate from the repository root in a Python environment with
`grpcio-tools==1.78.0` (libprotoc 31.1):

```python
import pathlib
import tempfile
from grpc_tools import protoc

fixtures = pathlib.Path("charts/buildbarn/tests/testdata")
name = "github.com/buildbarn/bb-remote-execution/pkg/proto/configuration/bb_scheduler/bb_scheduler.proto"
with tempfile.TemporaryDirectory() as directory:
    source = pathlib.Path(directory) / name
    source.parent.mkdir(parents=True)
    source.write_bytes((fixtures / "bb_scheduler_fork.proto").read_bytes())
    assert protoc.main([
        "protoc", "-I" + directory,
        "--descriptor_set_in=" + str(fixtures / "buildbarn_descriptors_cdc.pb"),
        "--include_imports",
        "--descriptor_set_out=" + str(fixtures / "scheduler_fork_descriptors.pb"),
        name,
    ]) == 0
```

An intentional fork update must change the source commit, source file, generated
descriptor, and their checksums together. Keep all negative parser controls and
all three reload/handover combinations when updating the fixture.
