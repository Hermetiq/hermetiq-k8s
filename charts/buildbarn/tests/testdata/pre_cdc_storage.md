# Pre-CDC storage fixture

`pre_cdc_storage.json` is the evaluated storage config from chart commit
`99795d2b6e5e8d3b56b60b630eed5b7c8b0b0a07` (Buildbarn chart 0.9.9), with
CAS/AC blocks reduced to 1 GiB, CAS index to 1 MiB, and AC index to 10,000
entries for the container regression test. No storage paths, encodings,
persistence settings, or block counts were changed.

The fixture runs with the prior default storage image:
`ghcr.io/buildbarn/bb-storage:20260908T142448Z-db62041@sha256:32ebc54b769b9e5fcc4beec3fdb527fd45853ca1ec9d1a112d00b1812f272a1f`.

Keep this old fixture and image when updating the current chart. Their purpose
is to verify the incompatible format boundary, rather than merely starting
the new image twice with fresh data.
