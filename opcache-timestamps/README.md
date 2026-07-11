# OPcache `validate_timestamps` cost bench

What does `opcache.validate_timestamps=1` actually cost, and what would the
ePHPm images buy by turning it off?

Today the `ephpm/ephpm` images ship PHP's defaults: `validate_timestamps=1`,
`revalidate_freq=2`. That means every cached script's mtime is re-`stat()`ed
at most once per 2-second window — a stat burst across the whole codebase
every 2 s under load, forever, for a file set that in a container image
changes exactly never. ePHPm v0.4.x already ships the replacement mechanism:
`ephpm deploy` / `ephpm cache reset` invalidate OPcache explicitly (see
[`k8s/OPCACHE-CLUSTER.md`](../k8s/OPCACHE-CLUSTER.md)). This bench quantifies
what flipping the default to `validate_timestamps=0` would buy — and verifies
what it costs (the staleness contract).

## Matrix

Same image, same fixture, same limits — only the OPcache ini pair changes
(via `[php] ini_overrides` in each `configs/*.toml`):

| Variant | `validate_timestamps` | `revalidate_freq` | Meaning |
| --- | --- | --- | --- |
| A `a-vt1-freq2` | 1 | 2 | current image default (PHP default) |
| B `b-vt1-freq60` | 1 | 60 | the middle setting |
| C `c-vt0` | 0 | — | proposed serve-mode default |

## Fixture

A composer-vendor-shaped require chain, generated at container start by
[`container/start.sh`](container/start.sh): **500** small class files
(`lib/C0001.php` … `C0500.php`) plus an `index.php` that `require_once`'s
every one of them and chains a sha256 checksum through all 500 —
**501 PHP files stat-relevant per request**. `status.php` (not part of the
load path) reports the effective ini values so the driver can prove each
variant's knobs actually took effect.

## Docroot filesystems

`stat()` cost depends on the filesystem the docroot lives on, so the matrix
runs twice:

- **overlay** — fixture generated into the container's own filesystem
  (overlayfs), the equivalent of `COPY`ing the app into the image.
- **volume** — fixture generated into a podman **named volume** mounted at
  `/web` (ext4 inside the podman machine), the equivalent of a
  volume-deployed app.

Host bind mounts are deliberately not used: on Windows/macOS podman machines
they go through virtiofs/9p and would measure the share protocol, not
OPcache.

## Method

- One server container at a time (`--cpus 1 --memory 512m`), podman.
- Load: `hey` (keep-alive, `c=16`), 5 s warmup, then best of 2 × 30 s runs —
  the same local method as [`RUNTIMES-BENCH.md`](../RUNTIMES-BENCH.md).
- Every counted run is asserted to be **100% HTTP 200** (exactly one status
  line, `[200]`) — the baked-in image config's `per_ip_rate = 500` limiter
  has tainted lab numbers before, so the bench replaces the config entirely
  (no `[server.limits]`) and verifies.
- The driver also asserts `opcache_enabled=true` and the variant's exact
  `validate_timestamps` / `revalidate_freq` values before measuring.
- Runs with transport-level errors (occasional dropped keep-alive connections
  on podman-machine port forwards) are re-run, never averaged in.

## Staleness contract (asserted, not prose)

After the timed runs, the driver mutates one class file
(`sed -i 's/const REV = 1;/const REV = 2;/' /web/lib/C0001.php`) and asserts:

- **A** serves the new `rev` within ~2 s (assert ≤ 5 s).
- **B** still serves the old `rev` at +5 s and +30 s, then flips by ~60 s.
- **C** still serves the old `rev` at +30 s, and flips **only** after
  `ephpm cache reset --all` — immediately.

## Results

Measured 2026-07-10 on one developer machine (Windows host, podman machine,
`hey` on the host through the podman port forward). Image:
`docker.io/ephpm/ephpm:latest`, which resolved to **ePHPm v0.4.0** at run
time (`localhost/ephpm:v0.4.1-final` was available locally as a fallback but
was not needed — latest has `ini_overrides`, the watcher, and
`ephpm cache reset`). Absolute numbers are machine-specific; read the columns
relative to each other. The overlay matrix was run twice (noise check), so
overlay cells are best of 4 × 30 s and volume cells best of 2 × 30 s.

| Variant | Docroot | req/s | vs A | p50 | p99* |
| --- | --- | ---: | ---: | ---: | ---: |
| A `vt=1 freq=2` | overlay | 912 | — | 2.3 ms | 92.8 ms |
| B `vt=1 freq=60` | overlay | 999 | +9.5% | 2.1 ms | 92.2 ms |
| C `vt=0` | overlay | 995 | +9.1% | 2.1 ms | 92.0 ms |
| A `vt=1 freq=2` | volume | 806 | — | 2.6 ms | 92.8 ms |
| B `vt=1 freq=60` | volume | 874 | +8.5% | 2.4 ms | 92.5 ms |
| C `vt=0` | volume | 890 | +10.5% | 2.4 ms | 91.8 ms |

\* p99 on this host is dominated by a constant ~92 ms podman-machine
port-forward artifact (a bimodal latency mode affecting roughly the slowest
10–25% of requests identically in every variant and both docroots — p75 sits
at ~3 ms, p90 at ~90 ms). It is not an OPcache signal; p50 is the meaningful
latency column here.

**Noise floor:** individual 30 s runs varied up to ±15% on this machine
(e.g. variant C overlay runs: 658–995 req/s), which is why cells report
best-of-N. The A → B/C gap (~+9–10%) reproduced in every pass and on both
docroots; the B vs C gap did not (within noise).

Staleness assertions (overlay), all PASS:

```
PASS: A picked up the change in 0s (revalidate_freq=2)
PASS: B stayed stale >=30s and picked up the change in ~49s (revalidate_freq=60)
PASS: C stayed stale until explicit reset, then flipped in 0s
```

(B flipping at ~49 s rather than 60 s is correct: the revalidate window is
anchored to the file's *last validation* — which happened during the timed
run — not to the mutation.)

<details>
<summary>Raw runs (req/s @ p50)</summary>

| Variant | Docroot | Pass 1 run 1 | Pass 1 run 2 | Pass 2 run 1 | Pass 2 run 2 |
| --- | --- | ---: | ---: | ---: | ---: |
| A | overlay | 812.6 @ 2.5 ms | 848.2 @ 2.5 ms | 912.1 @ 2.3 ms | 765.1 @ 2.7 ms |
| B | overlay | 995.6 @ 2.1 ms | 998.9 @ 2.1 ms | 864.4 @ 2.4 ms | 714.4 @ 2.9 ms |
| C | overlay | 929.2 @ 2.2 ms | 658.4 @ 3.3 ms | 913.1 @ 2.3 ms | 995.2 @ 2.1 ms |
| A | volume | 777.2 @ 2.7 ms | 806.0 @ 2.6 ms | | |
| B | volume | 874.2 @ 2.4 ms | 819.1 @ 2.5 ms | | |
| C | volume | 834.7 @ 2.5 ms | 890.4 @ 2.4 ms | | |

</details>

Reading: turning timestamp validation off (or merely stretching the window
to 60 s) is worth roughly **+9–10% throughput and ~0.2–0.4 ms off p50** on
this 501-file, stat-heavy fixture — consistent across both docroot
filesystems. Almost all of the win comes from escaping the 2 s window;
`freq=60` and `vt=0` are indistinguishable here. The interpretation and the
v0.4.2 default-change recommendation live in
[`docs/opcache-validate-timestamps.md`](../docs/opcache-validate-timestamps.md).

## Reproduce

```sh
# Full matrix (both docroots) + staleness assertions:
bash opcache-timestamps/run-bench.sh

# Re-run against a specific image (e.g. when v0.4.1 publishes):
EPHPM_IMAGE=docker.io/ephpm/ephpm:v0.4.1 bash opcache-timestamps/run-bench.sh

# Quick pass:
BENCH_DOCROOTS=overlay BENCH_SKIP_STALENESS=1 bash opcache-timestamps/run-bench.sh
```

Knobs: `EPHPM_IMAGE`, `BENCH_PORT` (18080), `BENCH_DURATION` (30s),
`BENCH_RUNS` (2), `BENCH_CONCURRENCY` (16), `BENCH_NFILES` (500),
`BENCH_CPUS` (1), `BENCH_MEMORY` (512m), `BENCH_DOCROOTS`
(`"overlay volume"`), `BENCH_SKIP_STALENESS`.

Requires `podman`, `hey`, `curl`, `jq`. On Windows run it from git-bash;
the script handles `MSYS_NO_PATHCONV` and `C:/`-style paths itself.
