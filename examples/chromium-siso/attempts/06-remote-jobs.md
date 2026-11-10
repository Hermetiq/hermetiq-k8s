# Attempt 6: Double `--remote_jobs` to 800

Cold build of `chrome`: 17 min, from 18 min.

## What We Changed

We doubled `--remote_jobs` from 400 to 800, so Siso kept more actions queued
for the workers. The large pool's limit had also gone up from 25 to 30 pods.

## What Happened

The build was about a minute faster. Because the pool changed too, we can't
say how much of that minute came from `--remote_jobs`.

## What We Learned

Set `--remote_jobs` above the total number of slots in your pools, so no
worker waits for Siso to send it work. It's free to change.

---

Previous: [Add `googlechrome`](05-googlechrome.md) · Next: [Warm the pools first](07-warm-pools.md) · [All attempts](../README.md#what-we-tried)
