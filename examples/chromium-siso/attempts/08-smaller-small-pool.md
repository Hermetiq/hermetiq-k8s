# Attempt 8: Shrink the small pool

Cold build of `chrome`: slower than 12 min.

## What We Changed

We cut the small pool from 12 pods to 6, with everything else the same as
[attempt 7](07-warm-pools.md).

## What Happened

The build took 14 minutes, 2 minutes slower.

## What We Learned

The small pool runs a real share of the build. Keep it at full size.

---

Previous: [Warm the pools first](07-warm-pools.md) · Next: [Drop the patch: Chromium's own config](09-chromium-config.md) · [All attempts](../README.md#what-we-tried)
