# Attempt 3: Add `default-remote`

Cold build of `chrome`: 29 min, from 29 min.

## What We Changed

We added Siso's `default-remote` config option, which sends every rule that
doesn't say otherwise to Buildbarn, including links.

## What Happened

About 5,400 more steps ran remotely, leaving about 5,000 on the workstation,
but the build took the same time. The `chrome` link ran on a worker and took
about five minutes, against seconds on the workstation.

## What We Learned

Moving steps off the workstation only helps once enough of them have moved.
The steps still running locally kept the workstation busy, and the remote link
added time at the end.

---

Previous: [Up to 40 nodes](02-more-nodes.md) · Next: [Keep links on the workstation](04-local-links.md) · [All attempts](../README.md#what-we-tried)
