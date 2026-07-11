# ePHPm v0.4.1 retest

Re-run of the local RUNTIMES-BENCH methodology against the published
`ephpm/ephpm:v0.4.1-php8.4` image, with `v0.4.0` as a control and the
official PHP 8.4 FPM image as the reference competitor.

## Method

- Same recipe as [RUNTIMES-BENCH.md](../RUNTIMES-BENCH.md): podman, one
  stack at a time, 0.25 CPU / 320Mi per stack, `hey` keep-alive, warmup +
  30s runs, best-of-2 reported, **100% HTTP 200 verified in every cell**
  (no rate-limiter taint).
- The `v0.4.0` control reproduced this repo's recorded baselines almost
  exactly (hello c=1 1.9 vs 2.0 ms; cpu c=16 78.7 vs 79 RPS; fpm cpu 142.7
  vs 151 RPS), so the numbers below are directly comparable to the lab's
  reference hardware.
- New lane: `db.php` — 10 sequential PDO queries against ePHPm's in-process
  SQLite (`pdo_mysql` -> `127.0.0.1:3306`, no external database). FPM has no
  built-in database, so the DB lane is version-vs-version.

## Results

| Test | v0.4.0 | **v0.4.1** | php-fpm |
|---|---|---|---|
| hello.php c=1 (avg ms) | 1.9 | **1.8** | 2.3 |
| hello.php c=16 (RPS) | 730 | **781** | 520 |
| cpu.php c=16 (RPS) | 78.7 | **147.9** | 142.7 |
| worker hello c=16 (RPS) | 940 | **984** | — |
| worker cpu c=16 (RPS) | 79.1 | **149.3** | — |
| db.php c=1 (p50 ms) | 444.0 | **4.4** | — |
| db.php c=16 (RPS) | 35.0 | **106.0** | — |

## What changed

**cpu.php flipped from loss to win.** v0.4.0 was ~2x behind FPM (78.7 vs
142.7 RPS) — the clearest loss in this suite. v0.4.1 restores the PHP SDK's
SHA-NI sha256 intrinsics (disabled since the project began by a stray
C++-only compiler flag), giving 1.88x and edging FPM (147.9 vs 142.7).

**db.php: the ~44ms/query stall is gone.** v0.4.0 paid a Nagle +
delayed-ACK deadlock on every result-set response — 10 queries per page =
~444ms. v0.4.1 (litewire `TCP_NODELAY` + coalescing the MySQL result-set
into a single write) drops per-request p50 to 4.4ms: a **101x** latency
improvement, validated end-to-end through `pdo_mysql`.

**hello held its win over FPM** (781 vs 520 RPS) and improved slightly.
An apparent c=16 dip in one run window (563 vs 657) was disproved by a
paired rerun (781 vs 731) — run-window drift, not a regression.

## Remaining gaps (informing ePHPm's own backlog, not this lab)

- FPM's hello c=16 p50 is still lower (1.4 vs ~16 ms) though bimodal
  (98.6 ms p99); ePHPm queues where FPM races — a worker-dispatch cost.
- Class B Swoole still leads worker cpu (lab-recorded 206 vs 149 RPS),
  mapping to the ZTS allocation tax; a global-allocator/LTO change is in
  ePHPm's v0.4.2 line.
- Absolute worker hello RPS here is RTT-bound in podman/WSL (~980 ceiling);
  the version delta is valid but the lab's cluster numbers are higher.
