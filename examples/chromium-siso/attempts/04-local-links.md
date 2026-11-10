# Attempt 4: Keep links on the workstation

Cold build of `chrome`: 23 min, from 29 min.

## What We Changed

Chromium's Siso config has no option for "everything remote except links",
so we changed one line in `build/config/siso/clang_unix.star` to keep links
local while `default-remote` sent everything else to Buildbarn.

## What Happened

The build dropped by about 5 minutes. The `chrome` link ran locally again.

## What We Learned

Remote links were slow for us. The change is a local patch to Chromium, which
you'd have to carry yourself, so the final setup doesn't use it.

---

Previous: [Add `default-remote`](03-default-remote.md) · Next: [Add `googlechrome`](05-googlechrome.md) · [All attempts](../README.md#what-we-tried)
