# Noisy-neighbor proof — local ePHPm v0.10.1

**Confirmed cross-tenant latency interference in this uncapped shared-pool configuration.**

At eight busy clients, quiet-tenant p95 rose from 6.9–6.9 ms baseline to 560.9–560.9 ms (82–82× baseline). There were 0 quiet-tenant deadline failures across 360 measured PHP requests. This is a latency-interference proof, not a demonstrated outage.

Measured configuration: four shared PHP execution threads, 200% service CPU quota, 2 GiB service memory limit, FIFO admission, queue depth 32. Per-site rate limiting and the preview preset are not enabled. eBPF tenant network policy remains enabled.

Started: 2026-09-08T22:20:17Z. Kernel: `6.18.33.2-microsoft-standard-WSL2`.

1 trial(s), alternating the busy tenant starting with Alice. Each phase lasts 30 seconds; the quiet tenant receives a scheduled 2 PHP requests/second and one static request/second. Pressure uses at most eight concurrent requests, each performing a fixed one-million SHA-256 loop. No external targets or unbounded work.

## Quiet tenant measurements

Latency percentiles below include successful responses only. The deadline-failure column includes timeouts and HTTP/transport failures out of all scheduled requests; it must be read alongside latency. Percentiles are nearest-rank and descriptive, with 60 PHP samples per phase.

| Trial | Quiet tenant | Phase | Requests | p50 ms | p95 ms | p99 ms | Deadline failures | Threshold met |
|---|---|---|---:|---:|---:|---:|---:|---|
| 1 | bob.lab.test | baseline | 60 | 3.2 | 6.9 | 28.3 | 0/60 | No |
| 1 | bob.lab.test | load-1 | 60 | 2.8 | 5.8 | 12.8 | 0/60 | No |
| 1 | bob.lab.test | load-2 | 60 | 2.6 | 5.1 | 8.5 | 0/60 | No |
| 1 | bob.lab.test | load-4 | 60 | 63.0 | 231.2 | 248.6 | 0/60 | No |
| 1 | bob.lab.test | load-8 | 60 | 450.3 | 560.9 | 667.1 | 0/60 | Yes |
| 1 | bob.lab.test | recovery | 60 | 3.2 | 7.8 | 20.2 | 0/60 | No |

The threshold was specified before execution: quiet-tenant p95 above both 5× its trial baseline and 250 ms, OR more than 1% of scheduled quiet-tenant requests failing a one-second deadline. This is a demonstration criterion, not a universal availability SLA.

## Result

1 pressure phases met the predeclared interference criterion across 1 trials.

This establishes the observed behavior of this lab configuration only. It does not establish an isolation bypass, a crash, or behavior with per-site controls enabled. Shared CPU/thread/queue contention can account for interference; this experiment does not independently separate those mechanisms.

## Controls and instrumentation

| Trial | Phase | Static p95 ms | Static deadline failures | Victim max scheduler lag ms |
|---|---|---:|---:|---:|
| 1 | baseline | 6.8 | 0/30 | 22.8 |
| 1 | load-1 | 5.7 | 0/30 | 6.7 |
| 1 | load-2 | 4.9 | 0/30 | 6.9 |
| 1 | load-4 | 28.7 | 0/30 | 8.2 |
| 1 | load-8 | 30.7 | 0/30 | 3.7 |
| 1 | recovery | 10.1 | 0/30 | 19.1 |

The generator ran outside the serving cgroup, inside the same isolated network namespace. Each scheduled request was independently launched rather than waiting for its predecessor. Scheduler lag is recorded to expose load-generator delay. HTTP results are status-based; request bodies were not independently validated by the load generator.

The service cgroup was sampled approximately once per second for CPU consumption/throttling, memory, task count and CPU pressure. Raw counters are in `metrics.jsonl`. WSL shares a kernel and physical resources with other local workloads; the run is not a dedicated production-host capacity benchmark.

## Reproduce

Run `./experiments/wsl-multitenant/noisy-neighbor/Run-Proof.ps1` from PowerShell after the WSL lab is provisioned. It installs only fixed lab fixtures, caps the whole run at 15 minutes, and exports results. No runtime config change or service restart is performed. The two fixture files remain available after the run; no pressure client remains.

Raw evidence: `requests.jsonl`, `metrics.jsonl`, `phases.json`, `summary.json`, `metadata.json`, and the exact `ephpm.toml`. The config and workload hashes are recorded in metadata. A comparison with documented per-site rate/burst limits is still required before describing this as an unmitigated product flaw.

Source context at the tested commit: [shared PHP pool](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/crates/ephpm-server/src/fpm_pool.rs), [per-site rate-limit configuration](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/site/content/reference/config.md#serverlimits).

![Busy tenant and quiet tenant timeline](timeline.png)


## Service pressure

| Trial | Phase | Busy completed requests/s | Average CPU cores | Throttled periods | Peak memory MiB |
|---|---|---:|---:|---:|---:|
| 1 | baseline | 0.00 | 0.00 | 0/76 | 59.9 |
| 1 | load-1 | 5.15 | 0.94 | 0/291 | 60.6 |
| 1 | load-2 | 10.17 | 1.88 | 5/290 | 60.7 |
| 1 | load-4 | 10.53 | 2.00 | 300/301 | 60.5 |
| 1 | load-8 | 10.50 | 2.00 | 290/290 | 60.5 |
| 1 | recovery | 0.00 | 0.00 | 0/86 | 59.5 |