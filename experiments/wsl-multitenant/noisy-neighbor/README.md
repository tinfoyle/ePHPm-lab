# Proof: noisy-neighbor latency interference

This experiment asks whether one busy PHP vhost degrades a second vhost's latency in the existing local ePHPm service. It does not attempt an escape, memory exhaustion, or a kernel attack.

See [the measured proof](PROOF.md) for findings and raw evidence.

Run from PowerShell after provisioning the WSL lab:

```powershell
./experiments/wsl-multitenant/noisy-neighbor/Run-Proof.ps1
```

The script installs a fixed CPU fixture and static control in Alice and Bob, runs the measurement, and exports results to `results/<UTC-run-id>/`. It does not alter runtime limits or restart ePHPm. A guest lock prevents concurrent experiments; a 15-minute watchdog caps execution. The normal run takes roughly nine minutes.

`-Trials 1` runs one three-minute ladder for a diagnostic repeat; the default is three alternating-role trials. Namespace entry uses `nsenter --net` so cgroup telemetry stays visible. Before traffic starts, every required counter must be readable.

To collect an already completed run without applying pressure again:

```powershell
./experiments/wsl-multitenant/noisy-neighbor/Run-Proof.ps1 -CollectOnly -RunId 20260908T220856Z
```

Generate the report/chart with Python 3 and matplotlib:

```text
python report.py results/<UTC-run-id>
```

## Protocol fixed before the first run

- Ten-second quiet warm-up.
- Three trials with busy/quiet tenants alternating Alice/Bob, Bob/Alice, Alice/Bob.
- Each trial: 30-second quiet baseline; 30 seconds at each of 1, 2, 4 and 8 busy-client concurrency; 30-second recovery.
- Quiet tenant: fixed arrival rate of two PHP requests/second, plus a separate static request/second, each with a one-second deadline measured from scheduled launch.
- Busy tenant: one million SHA-256 operations per request, no input-controlled size, up to eight closed-loop clients, ten-second client deadline. All pressure clients drain before the next phase.
- Generator outside the server's service cgroup. Sample service CPU/throttling, memory, task count and CPU pressure once a second.
- Demonstration criterion: quiet-tenant p95 above both five times baseline and 250 ms, OR more than 1% of scheduled quiet-tenant requests failing their one-second deadline.

This short proof uses 30-second phases rather than the earlier proposed 60-second phases. There are 60 quiet PHP samples per phase: adequate for demonstrating a large repeated shift, not for precise production p99 or capacity estimates. The reversed direction is run once; the original direction twice.

## Scope and interpretation

The initial service has four shared PHP threads, a two-core CPU quota, 2 GiB memory, FIFO admission, and a shared queue depth of 32. `preview=true` and `[server.limits] per_site_rate` are absent: the effective per-site rate is unlimited. The preview preset's documented rate is five PHP executions/second with a burst of 20, and it is **not tested here**. Do not turn this result into a claim that all ePHPm deployments are equally affected or that mitigation is impossible.

Count successful-response percentiles together with errors/timeouts. The timeline includes timeout observations. Every scheduled quiet request gets a record, and scheduler lag is recorded; traffic does not shrink silently as the server slows. The workload is fixed and local to the allowlisted loopback listener/hosts. HTTP status is captured but the load generator does not independently validate response bodies.

Artifacts: every request (`requests.jsonl`), sampled cgroup counters (`metrics.jsonl`), phase boundaries (`phases.json`), summary statistics, environment/config/workload hashes, and the exact runtime config. CPU and memory remain shared with surrounding WSL workloads at the physical host level. Baseline/recovery, repetition and the static control strengthen the causal evidence but do not separate CPU throttling from PHP pool/queue contention.

No runtime configuration is changed. The finite fixtures remain at `/noisy-cpu.php` and `/control.txt`; nothing generates traffic after the run exits. They are available only inside the lab namespace.
