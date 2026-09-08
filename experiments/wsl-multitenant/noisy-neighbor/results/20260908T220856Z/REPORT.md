# Noisy-neighbor proof — local ePHPm v0.10.1

**Confirmed cross-tenant latency interference in this uncapped shared-pool configuration.**

At eight busy clients, quiet-tenant p95 rose from 6.4–10.2 ms baseline to 572.6–627.3 ms (60–89× baseline). There were 0 quiet-tenant deadline failures across 1080 measured PHP requests. This is a latency-interference proof, not a demonstrated outage.

Measured configuration: four shared PHP execution threads, 200% service CPU quota, 2 GiB service memory limit, FIFO admission, queue depth 32. Per-site rate limiting and the preview preset are not enabled. eBPF tenant network policy remains enabled.

Started: 2026-09-08T22:08:56Z. Kernel: `6.18.33.2-microsoft-standard-WSL2`.

3 trial(s), alternating the busy tenant starting with Alice. Each phase lasts 30 seconds; the quiet tenant receives a scheduled 2 PHP requests/second and one static request/second. Pressure uses at most eight concurrent requests, each performing a fixed one-million SHA-256 loop. No external targets or unbounded work.

## Quiet tenant measurements

Latency percentiles below include successful responses only. The deadline-failure column includes timeouts and HTTP/transport failures out of all scheduled requests; it must be read alongside latency. Percentiles are nearest-rank and descriptive, with 60 PHP samples per phase.

| Trial | Quiet tenant | Phase | Requests | p50 ms | p95 ms | p99 ms | Deadline failures | Threshold met |
|---|---|---|---:|---:|---:|---:|---:|---|
| 1 | bob.lab.test | baseline | 60 | 4.2 | 10.2 | 15.8 | 0/60 | No |
| 1 | bob.lab.test | load-1 | 60 | 3.2 | 9.9 | 15.4 | 0/60 | No |
| 1 | bob.lab.test | load-2 | 60 | 2.5 | 4.7 | 6.3 | 0/60 | No |
| 1 | bob.lab.test | load-4 | 60 | 81.1 | 245.9 | 278.3 | 0/60 | No |
| 1 | bob.lab.test | load-8 | 60 | 423.4 | 610.8 | 729.8 | 0/60 | Yes |
| 1 | bob.lab.test | recovery | 60 | 3.2 | 6.1 | 8.1 | 0/60 | No |
| 2 | alice.lab.test | baseline | 60 | 3.1 | 9.6 | 16.3 | 0/60 | No |
| 2 | alice.lab.test | load-1 | 60 | 3.1 | 7.6 | 15.0 | 0/60 | No |
| 2 | alice.lab.test | load-2 | 60 | 2.7 | 9.6 | 13.4 | 0/60 | No |
| 2 | alice.lab.test | load-4 | 60 | 81.2 | 192.6 | 318.8 | 0/60 | No |
| 2 | alice.lab.test | load-8 | 60 | 454.6 | 627.3 | 684.8 | 0/60 | Yes |
| 2 | alice.lab.test | recovery | 60 | 3.2 | 8.1 | 9.1 | 0/60 | No |
| 3 | bob.lab.test | baseline | 60 | 3.1 | 6.4 | 12.6 | 0/60 | No |
| 3 | bob.lab.test | load-1 | 60 | 2.6 | 5.2 | 5.7 | 0/60 | No |
| 3 | bob.lab.test | load-2 | 60 | 2.7 | 4.2 | 5.0 | 0/60 | No |
| 3 | bob.lab.test | load-4 | 60 | 42.3 | 210.3 | 324.6 | 0/60 | No |
| 3 | bob.lab.test | load-8 | 60 | 452.1 | 572.6 | 674.8 | 0/60 | Yes |
| 3 | bob.lab.test | recovery | 60 | 2.9 | 6.8 | 17.5 | 0/60 | No |

The threshold was specified before execution: quiet-tenant p95 above both 5× its trial baseline and 250 ms, OR more than 1% of scheduled quiet-tenant requests failing a one-second deadline. This is a demonstration criterion, not a universal availability SLA.

## Result

3 pressure phases met the predeclared interference criterion across 3 trials.

This establishes the observed behavior of this lab configuration only. It does not establish an isolation bypass, a crash, or behavior with per-site controls enabled. Shared CPU/thread/queue contention can account for interference; this experiment does not independently separate those mechanisms.

## Controls and instrumentation

| Trial | Phase | Static p95 ms | Static deadline failures | Victim max scheduler lag ms |
|---|---|---:|---:|---:|
| 1 | baseline | 9.6 | 0/30 | 14.5 |
| 1 | load-1 | 11.3 | 0/30 | 11.4 |
| 1 | load-2 | 4.4 | 0/30 | 4.7 |
| 1 | load-4 | 47.9 | 0/30 | 6.5 |
| 1 | load-8 | 9.3 | 0/30 | 9.7 |
| 1 | recovery | 5.5 | 0/30 | 6.9 |
| 2 | baseline | 8.0 | 0/30 | 14.7 |
| 2 | load-1 | 6.4 | 0/30 | 12.2 |
| 2 | load-2 | 5.1 | 0/30 | 10.7 |
| 2 | load-4 | 6.0 | 0/30 | 7.4 |
| 2 | load-8 | 31.5 | 0/30 | 5.0 |
| 2 | recovery | 8.8 | 0/30 | 7.8 |
| 3 | baseline | 5.9 | 0/30 | 11.3 |
| 3 | load-1 | 5.0 | 0/30 | 4.1 |
| 3 | load-2 | 3.9 | 0/30 | 3.6 |
| 3 | load-4 | 8.9 | 0/30 | 19.2 |
| 3 | load-8 | 34.6 | 0/30 | 4.7 |
| 3 | recovery | 5.8 | 0/30 | 13.1 |

The generator ran outside the serving cgroup, inside the same isolated network namespace. Each scheduled request was independently launched rather than waiting for its predecessor. Scheduler lag is recorded to expose load-generator delay. HTTP results are status-based; request bodies were not independently validated by the load generator.

The service cgroup was sampled approximately once per second for CPU consumption/throttling, memory, task count and CPU pressure. Raw counters are in `metrics.jsonl`. WSL shares a kernel and physical resources with other local workloads; the run is not a dedicated production-host capacity benchmark.

## Reproduce

Run `./experiments/wsl-multitenant/noisy-neighbor/Run-Proof.ps1` from PowerShell after the WSL lab is provisioned. It installs only fixed lab fixtures, caps the whole run at 15 minutes, and exports results. No runtime config change or service restart is performed. The two fixture files remain available after the run; no pressure client remains.

Raw evidence: `requests.jsonl`, `metrics.jsonl`, `phases.json`, `summary.json`, `metadata.json`, and the exact `ephpm.toml`. The config and workload hashes are recorded in metadata. A comparison with documented per-site rate/burst limits is still required before describing this as an unmitigated product flaw.

Source context at the tested commit: [shared PHP pool](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/crates/ephpm-server/src/fpm_pool.rs), [per-site rate-limit configuration](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/site/content/reference/config.md#serverlimits).

![Busy tenant and quiet tenant timeline](timeline.png)


**Telemetry limitation:** cgroup collection failed for some or all samples. The original namespace launcher hid the cgroup mount. HTTP timings and scheduling records remain available; no CPU/memory conclusion is drawn from missing counters. Raw error records are preserved. The corrected launcher uses network-only nsenter and checks cgroup readability before applying load.


## Service pressure

| Trial | Phase | Busy completed requests/s | Average CPU cores | Throttled periods | Peak memory MiB |
|---|---|---:|---:|---:|---:|