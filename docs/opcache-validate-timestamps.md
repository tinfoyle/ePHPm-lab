# What `opcache.validate_timestamps` costs, and why serve mode should turn it off

Date: 2026-07-10

The ePHPm images currently ship PHP's OPcache defaults:
`opcache.validate_timestamps=1`, `opcache.revalidate_freq=2`. Under load that
means every cached script gets its mtime re-`stat()`ed at most once per
2-second window — a stat burst over the entire codebase every 2 s, forever.
For a containerized app whose files change only on deploy, all of that work
buys exactly one thing: edits to `.php` files appear within 2 s.

ePHPm already ships the alternative: `ephpm deploy` / `ephpm cache reset`
invalidate OPcache explicitly — across a whole gossip cluster with one KV
write ([`k8s/OPCACHE-CLUSTER.md`](../k8s/OPCACHE-CLUSTER.md) demonstrates
that end to end). The proposed v0.4.2 change is to make
`validate_timestamps=0` the serve-mode default. This bench
([`opcache-timestamps/`](../opcache-timestamps/README.md)) puts numbers on
both sides of that trade.

## Setup, in one paragraph

One ePHPm container at a time (`ephpm/ephpm:latest` = **v0.4.0** at run
time, `--cpus 1 --memory 512m`, podman), serving a 501-file fixture — 500
generated class files plus an `index.php` that `require_once`'s all of them
(the composer-vendor shape). Load is `hey` keep-alive at `c=16`, 30 s runs
after warmup, every counted run verified 100% HTTP 200 and every variant's
ini pair verified via `ini_get()` before measuring. The docroot lives either
on the container's overlayfs ("baked in") or on a podman named volume —
never a host bind mount. Full method, knobs, and per-run data in the
[bench README](../opcache-timestamps/README.md).

## The numbers

| Variant | Docroot | req/s | vs A | p50 |
| --- | --- | ---: | ---: | ---: |
| A `vt=1 freq=2` (image default) | overlay | 912 | — | 2.3 ms |
| B `vt=1 freq=60` | overlay | 999 | +9.5% | 2.1 ms |
| C `vt=0` (proposed) | overlay | 995 | +9.1% | 2.1 ms |
| A `vt=1 freq=2` (image default) | volume | 806 | — | 2.6 ms |
| B `vt=1 freq=60` | volume | 874 | +8.5% | 2.4 ms |
| C `vt=0` (proposed) | volume | 890 | +10.5% | 2.4 ms |

Three observations:

1. **The 2-second default costs about 9–10% of throughput** on this
   stat-heavy fixture, on both docroot filesystems. That is the honest size
   of the win on a *fast local filesystem*: real, reproducible in every
   pass, and modest. It is not a 2x story on overlayfs/ext4 — `stat()` there
   is cheap; it is merely 501 of them per window plus the revalidation
   bookkeeping.
2. **Escaping the 2 s window is the whole win.** `freq=60` and `vt=0` were
   indistinguishable (their gap never cleared the ±15% single-run noise
   floor; the A→B/C gap always did). The case for going all the way to
   `vt=0` is therefore *operational*, not throughput — see below.
3. **The classic horror stories live elsewhere.** On NFS-class filesystems
   every `stat()` is a network round trip and this same default becomes a
   storm; that regime is exactly why `validate_timestamps=0` is standard
   production advice. This bench deliberately measures the *cheapest* case
   for variant A — the recommendation survives it anyway.

## The staleness trade, asserted

The bench does not take the invalidation story on faith. After the timed
runs it rewrites one class constant on disk and asserts the contract, which
all passed:

```
PASS: A picked up the change in 0s (revalidate_freq=2)
PASS: B stayed stale >=30s and picked up the change in ~49s (revalidate_freq=60)
PASS: C stayed stale until explicit reset, then flipped in 0s
```

Variant B is the interesting failure mode: a file edit sat stale for ~49
seconds and then appeared *on its own schedule*, anchored to when OPcache
last validated the file, not to when the edit happened. That is the worst of
both worlds — you still pay for validation, and a mid-incident hotfix lands
at an unpredictable moment somewhere in the next minute.

Variant C stayed stale indefinitely until `ephpm cache reset --all` — and
then flipped on the very next request. With `validate_timestamps=0` a file
edit is invisible **until you say otherwise**, and saying otherwise is a
one-command, immediate, cluster-capable operation.

## Recommendation

Ship `opcache.validate_timestamps=0` as the serve-mode default in v0.4.2.

The framing that matters: **in a container, deploys are events, not
filesystem drift.** The image's PHP files change exactly once — when a new
image rolls out — and ePHPm additionally supports in-place code pushes via
`ephpm deploy`, which invalidates OPcache cluster-wide with one KV write
(demonstrated in [the OPcache cluster demo](../k8s/OPCACHE-CLUSTER.md), and
asserted single-node by this bench's staleness lane). Once invalidation is
an explicit event, per-window `stat()` validation is pure overhead: ~9–10%
of throughput here, arbitrarily more on slow filesystems, and zero benefit.

Two guardrails the change should keep:

- `ephpm php` / CLI and any dev-oriented mode should keep PHP's defaults —
  the 2 s pickup is exactly right for iterating on code.
- The changed default must be loud in release notes and docs: anyone
  `kubectl cp`-ing a hotfix into a running pod will now need
  `ephpm cache reset` (or a restart), and the failure mode — stale code,
  no error — is confusing if you don't know the default flipped.

`revalidate_freq=60` is not a good middle ground for servers: it captures
the same throughput win but replaces the deterministic staleness contract
with "sometime in the next minute" (see the ~49 s assertion above).

## Caveats

- Absolute numbers are from one developer machine (Windows host, podman
  machine, load generator on the host through the port forward; p99 there
  is dominated by a constant ~92 ms forwarding artifact identical across
  variants). Read columns relative to each other; reproduce locally for
  your hardware.
- Single-run variance on this host was up to ±15%; the reported cells are
  best-of-N and the README lists every raw run. The A→B/C delta reproduced
  in all passes and on both docroots; the B↔C delta did not.
- `ephpm/ephpm:latest` resolved to v0.4.0. The driver is parameterized
  (`EPHPM_IMAGE=…`) so the matrix can be re-run as-is when v0.4.1
  publishes.
- The fixture is deliberately include-heavy (500 requires per request).
  Apps with fatter per-request work (DB, templating, HTTP calls) will see a
  smaller *relative* delta; apps on slower filesystems will see a larger
  one.
- Single node. In a cluster the C-variant staleness lane's
  `ephpm cache reset` becomes `ephpm deploy`, which the
  [OPcache cluster demo](../k8s/OPCACHE-CLUSTER.md) already covers.
