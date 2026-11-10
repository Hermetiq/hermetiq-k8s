# Attempt 9: Drop the patch: Chromium's own config

Cold build of `chrome`: 21 min, from 12 min.

## What We Changed

We went back to Chromium's own Siso config, without the local-link patch, so
the example works on an unmodified checkout. We added `remote-link`, and
`-output_local_strategy=greedy` so Siso downloads only the outputs you need. We
also let the pools scale from zero again, and ran the large pool at 9 actions
per pod. This is the starting point of the example: three builds took 21, 21
and 23 minutes.

## What Happened

The large pool took about 7 minutes to reach full size. Until then most of
the queued work waited.

## What We Learned

This is the setup a reader gets from this repository before any tuning.

---

Previous: [Shrink the small pool](08-smaller-small-pool.md) · Next: [Warm the pools first, again](10-warm-pools-again.md) · [All attempts](../README.md#what-we-tried)
