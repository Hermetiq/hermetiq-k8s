# Attempt 2: Up to 40 nodes

Cold build of `chrome`: 29 min, from 46 min.

## What We Changed

We raised the node limit from 16 to 40, and raised `--remote_jobs` to 400 so
Siso kept enough work in flight to use the extra nodes.

## What Happened

The large pool scaled to 26 pods and the small pool to 10 at their busiest.
New nodes took several minutes to arrive, so the large pool was still growing
25 minutes into the build. The workstation still ran the same 10,400 steps.

## What We Learned

More nodes was the biggest single improvement we made. It costs money, and
the cloud quota sets how far it can go.

---

Previous: [Siso's defaults on 16 nodes](01-siso-defaults.md) · Next: [Add `default-remote`](03-default-remote.md) · [All attempts](../README.md#what-we-tried)
