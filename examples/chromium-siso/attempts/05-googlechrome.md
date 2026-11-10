# Attempt 5: Add `googlechrome`

Cold build of `chrome`: 18 min, from 23 min.

## What We Changed

We added Siso's `googlechrome` config option. It sends the steps Chromium's
own builders run remotely, such as mojo, Rust, nasm, TypeScript and grit, which
`default-remote` doesn't cover.

## What Happened

The steps on the workstation dropped from about 5,000 to under 600. Work now
queued on the cluster for most of the build, with the large pool full.

## What We Learned

`default-remote` and `googlechrome` work together. With both, the workstation
stops being the bottleneck and the worker pools become the limit.

---

Previous: [Keep links on the workstation](04-local-links.md) · Next: [Double `--remote_jobs` to 800](06-remote-jobs.md) · [All attempts](../README.md#what-we-tried)
