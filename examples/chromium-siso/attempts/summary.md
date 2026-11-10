# Summary

We started at 46 minutes for a cold build of `chrome` and ended at 16 with
Chromium's own Siso config, or 12 with a local patch. These are the changes
that mattered, cheapest first. Each saving is from our runs, one change at a
time.

| Change | Cost | Saved |
| --- | --- | --- |
| Add `googlechrome` to `default-remote` ([5](05-googlechrome.md)) | Free | About 5 min |
| Set `--remote_jobs` above your total slots ([6](06-remote-jobs.md)) | Free | About 1 min |
| Warm the pools before building ([7](07-warm-pools.md), [10](10-warm-pools-again.md)) | Idle node time | About 5 min |
| Keep links on the workstation ([4](04-local-links.md)) | A patch to Chromium you carry yourself | About 5 min |
| Go from 16 to 40 nodes, with `--remote_jobs` 400 ([2](02-more-nodes.md)) | More nodes, up to your cloud quota | About 17 min |

Some changes didn't help:

- `default-remote` on its own saved nothing ([3](03-default-remote.md)). It
  only paid off once `googlechrome` moved the rest of the steps off the
  workstation.
- A smaller small pool made the build slower ([8](08-smaller-small-pool.md)).
- More actions per large pod made no difference, because the nodes were
  already busy ([11](11-more-actions-per-pod.md)).

This example ships Chromium's own config with warm pools: 16 minutes. The
build now ends with the `chrome` link, and a few of the remaining minutes go
to downloading that binary to the workstation.

To find what's slowing down your own builds, open a slow build in Hermetiq and
click **Ask Barn Owl**. It found the pool ramp-up in
[attempt 10](10-warm-pools-again.md) from the build's own data.

---

Previous: [More actions per large pod](11-more-actions-per-pod.md) · [All attempts](../README.md#what-we-tried)
