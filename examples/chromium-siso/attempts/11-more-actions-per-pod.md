# Attempt 11: More actions per large pod

Cold build of `chrome`: no faster than 16 min.

## What We Changed

We ran 12 actions on each large pod instead of 9.

## What Happened

Two builds took 16 and 17 minutes. During the build, the large pods were
already using most of their CPU and the small pods all of theirs.

## What We Learned

The nodes were already busy, so packing more actions onto them didn't help.
The example keeps 9.

---

Previous: [Warm the pools first, again](10-warm-pools-again.md) · Next: [Summary](summary.md) · [All attempts](../README.md#what-we-tried)
