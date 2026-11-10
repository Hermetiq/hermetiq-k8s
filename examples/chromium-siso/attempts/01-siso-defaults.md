# Attempt 1: Siso's defaults on 16 nodes

Cold build of `chrome`: 46 min.

## What We Changed

We built `chrome` with Chromium's default Siso settings, sending to Buildbarn
only the steps Siso sends remotely out of the box. The cluster had a limit of
16 worker nodes, shared by three pools: small, medium and large.

## What Happened

About 10,400 steps ran on the 8-core workstation and about 46,900 ran
remotely. The large pool scaled up to 12 pods. The small pool asked for 5 pods
but only ever had 1, because there were no nodes left for it.

## What We Learned

Two things were slowing the build down at once. The workstation was doing a
lot of the work, and the cluster ran out of nodes before the pools were full.

---

Next: [Up to 40 nodes](02-more-nodes.md) · [All attempts](../README.md#what-we-tried)
