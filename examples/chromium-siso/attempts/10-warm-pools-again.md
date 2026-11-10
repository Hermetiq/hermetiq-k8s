# Attempt 10: Warm the pools first, again

Cold build of `chrome`: 16 min, from 21 min.

## What We Changed

We asked Barn Owl where the 21-minute build's time went. It answered that the
largest loss was "the ~7-minute worker ramp-up at the start", and recommended
warming the large pool. We did, and changed nothing else.

## What Happened

Three builds took 15, 16 and 16 minutes.

## What We Learned

Warming the pools is worth about 5 minutes on a cold build. Barn Owl found
that from the build's own data, without being told about the pools.

---

Previous: [Drop the patch: Chromium's own config](09-chromium-config.md) · Next: [More actions per large pod](11-more-actions-per-pod.md) · [All attempts](../README.md#what-we-tried)
