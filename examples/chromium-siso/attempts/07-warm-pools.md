# Attempt 7: Warm the pools first

Cold build of `chrome`: 12 min, from 17 min.

## What We Changed

We scaled both pools up before starting the build: 28 large pods and 12
small ones, all 40 nodes. Normally the large pool starts at zero.

## What Happened

The build started with every worker ready, and finished in 12 minutes, our
fastest. It still used the local-link patch from
[attempt 4](04-local-links.md).

## What We Learned

A cold build spends its first minutes waiting for the large pool. Warming
the pools removes that wait, at the cost of paying for idle nodes.

---

Previous: [Double `--remote_jobs` to 800](06-remote-jobs.md) · Next: [Shrink the small pool](08-smaller-small-pool.md) · [All attempts](../README.md#what-we-tried)
