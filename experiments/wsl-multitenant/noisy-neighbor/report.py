"""Generate a report and publication-style timeline from captured measurements."""
import json
from pathlib import Path
import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

root = Path(sys.argv[1])
summary = json.loads((root/'summary.json').read_text())
phases = json.loads((root/'phases.json').read_text())
metadata = json.loads((root/'metadata.json').read_text())
requests = [json.loads(line) for line in (root/'requests.jsonl').read_text().splitlines()]
metrics = [json.loads(line) for line in (root/'metrics.jsonl').read_text().splitlines()]
victims = [s for s in summary if s['role']=='victim' and s['trial']>0]
baseline = {s['trial']:s for s in victims if s['phase']=='baseline'}
def num(v):
    return 'n/a' if v is None else f'{v:.1f}'
hits = []
lines = ['# Noisy-neighbor proof — local ePHPm v0.10.1', '',
         'Measured configuration: four shared PHP execution threads, 200% service CPU quota, 2 GiB service memory limit, FIFO admission, queue depth 32. Per-site rate limiting and the preview preset are not enabled. eBPF tenant network policy remains enabled.', '',
         f"Started: {metadata['started_utc']}. Kernel: `{metadata['kernel']}`.", '',
         f"{metadata['trials']} trial(s), alternating the busy tenant starting with Alice. Each phase lasts {metadata['seconds']} seconds; the quiet tenant receives a scheduled 2 PHP requests/second and one static request/second. Pressure uses at most eight concurrent requests, each performing a fixed one-million SHA-256 loop. No external targets or unbounded work.", '',
         '## Quiet tenant measurements', '',
         'Latency percentiles below include successful responses only. The deadline-failure column includes timeouts and HTTP/transport failures out of all scheduled requests; it must be read alongside latency. Percentiles are nearest-rank and descriptive, with 60 PHP samples per phase.', '',
         '| Trial | Quiet tenant | Phase | Requests | p50 ms | p95 ms | p99 ms | Deadline failures | Threshold met |',
         '|---|---|---|---:|---:|---:|---:|---:|---|']
for s in victims:
    threshold = max(250, 5*baseline[s['trial']]['p95_ms'])
    hit = (s['p95_ms'] is not None and s['p95_ms'] > threshold) or s['missed']/s['requests']>.01
    if s['concurrency'] and hit:
        hits.append(s)
    lines.append(f"| {s['trial']} | {s['victim']} | {s['phase']} | {s['requests']} | {num(s['p50_ms'])} | {num(s['p95_ms'])} | {num(s['p99_ms'])} | {s['missed']}/{s['requests']} | {'Yes' if hit else 'No'} |")
lines += ['', 'The threshold was specified before execution: quiet-tenant p95 above both 5× its trial baseline and 250 ms, OR more than 1% of scheduled quiet-tenant requests failing a one-second deadline. This is a demonstration criterion, not a universal availability SLA.', '',
          '## Result', '',
          f"{len(hits)} pressure phases met the predeclared interference criterion across {len(set(s['trial'] for s in hits))} trials.", '',
          'This establishes the observed behavior of this lab configuration only. It does not establish an isolation bypass, a crash, or behavior with per-site controls enabled. Shared CPU/thread/queue contention can account for interference; this experiment does not independently separate those mechanisms.', '',
          '## Controls and instrumentation', '',
          '| Trial | Phase | Static p95 ms | Static deadline failures | Victim max scheduler lag ms |',
          '|---|---|---:|---:|---:|']
for s in victims:
    control = next(t for t in summary if t['trial']==s['trial'] and t['phase']==s['phase'] and t['role']=='static')
    lines.append(f"| {s['trial']} | {s['phase']} | {num(control['p95_ms'])} | {control['missed']}/{control['requests']} | {num(s['max_scheduler_lag_ms'])} |")
lines += ['', 'The generator ran outside the serving cgroup, inside the same isolated network namespace. Each scheduled request was independently launched rather than waiting for its predecessor. Scheduler lag is recorded to expose load-generator delay. HTTP results are status-based; request bodies were not independently validated by the load generator.', '',
          'The service cgroup was sampled approximately once per second for CPU consumption/throttling, memory, task count and CPU pressure. Raw counters are in `metrics.jsonl`. WSL shares a kernel and physical resources with other local workloads; the run is not a dedicated production-host capacity benchmark.', '',
          '## Reproduce', '',
          'Run `./experiments/wsl-multitenant/noisy-neighbor/Run-Proof.ps1` from PowerShell after the WSL lab is provisioned. It installs only fixed lab fixtures, caps the whole run at 15 minutes, and exports results. No runtime config change or service restart is performed. The two fixture files remain available after the run; no pressure client remains.', '',
          'Raw evidence: `requests.jsonl`, `metrics.jsonl`, `phases.json`, `summary.json`, `metadata.json`, and the exact `ephpm.toml`. The config and workload hashes are recorded in metadata. A comparison with documented per-site rate/burst limits is still required before describing this as an unmitigated product flaw.', '',
          'Source context at the tested commit: [shared PHP pool](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/crates/ephpm-server/src/fpm_pool.rs), [per-site rate-limit configuration](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/site/content/reference/config.md#serverlimits).', '',
          '![Busy tenant and quiet tenant timeline](timeline.png)', '']
headline = 'Confirmed cross-tenant latency interference in this uncapped shared-pool configuration.' if hits else 'The run did not meet the predeclared interference criterion.'
lines[2:2] = ['**'+headline+'**', '']
high = [s for s in victims if s['concurrency']==8]
if high:
    ratios = [s['p95_ms']/baseline[s['trial']]['p95_ms'] for s in high if s['p95_ms'] is not None]
    quiet_base = [baseline[s['trial']]['p95_ms'] for s in high]
    high_p95 = [s['p95_ms'] for s in high if s['p95_ms'] is not None]
    total_failures = sum(s['missed'] for s in victims)
    lines[4:4] = [f"At eight busy clients, quiet-tenant p95 rose from {min(quiet_base):.1f}–{max(quiet_base):.1f} ms baseline to {min(high_p95):.1f}–{max(high_p95):.1f} ms ({min(ratios):.0f}–{max(ratios):.0f}× baseline). There were {total_failures} quiet-tenant deadline failures across {sum(s['requests'] for s in victims)} measured PHP requests. This is a latency-interference proof, not a demonstrated outage.", '']
def cpu(row):
    return {k:int(v) for k,v in (line.split() for line in row['cpu.stat'].splitlines())}
valid_metrics = [m for m in metrics if m['cpu.stat'].startswith('usage_usec ') and m['memory.current'].isdigit()]
if len(valid_metrics) != len(metrics):
    lines += ['', '**Telemetry limitation:** cgroup collection failed for some or all samples. The original namespace launcher hid the cgroup mount. HTTP timings and scheduling records remain available; no CPU/memory conclusion is drawn from missing counters. Raw error records are preserved. The corrected launcher uses network-only nsenter and checks cgroup readability before applying load.', '']
cpu_lines = ['', '## Service pressure', '',
             '| Trial | Phase | Busy completed requests/s | Average CPU cores | Throttled periods | Peak memory MiB |',
             '|---|---|---:|---:|---:|---:|']
for p in phases:
    if not p['trial']:
        continue
    samples=[m for m in valid_metrics if m['trial']==p['trial'] and m['phase']==p['phase']]
    busy=[r for r in requests if r['trial']==p['trial'] and r['phase']==p['phase'] and r['role']=='attacker' and not r['error']]
    if len(samples)>1:
        a,b=samples[0],samples[-1]
        ca,cb=cpu(a),cpu(b)
        cores=(cb['usage_usec']-ca['usage_usec'])/1e6/(b['t_s']-a['t_s'])
        periods=cb['nr_periods']-ca['nr_periods']
        throttled=cb['nr_throttled']-ca['nr_throttled']
        mem=max(int(m['memory.current']) for m in samples)/1024**2
        # Offered client phase plus its final in-flight response drain.
        end=max((r['scheduled_s']+r['elapsed_ms']/1000 for r in busy),default=p['start_s']+p['duration_s'])
        rate=len(busy)/max(p['duration_s'],end-p['start_s'])
        cpu_lines.append(f"| {p['trial']} | {p['phase']} | {rate:.2f} | {cores:.2f} | {throttled}/{periods} | {mem:.1f} |")
lines += cpu_lines
(root/'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')

ratios = [1, 2, 1] if valid_metrics else [1, 2]
fig, axes = plt.subplots(len(ratios), 1, figsize=(13, 8 if valid_metrics else 6), sharex=True, gridspec_kw={'height_ratios':ratios})
for p in phases:
    x0, x1 = p['start_s'], p['start_s']+p['duration_s']
    axes[0].fill_between([x0,x1], p['concurrency'], step='post', color='#c95b39', alpha=.8)
    if p['concurrency']:
        for ax in axes[1:]:
            ax.axvspan(x0,x1,color='#c95b39',alpha=.055)
for role, color in [('victim','#116e9b'), ('static','#369568')]:
    rows = [r for r in requests if r['role']==role]
    axes[1].scatter([r['scheduled_s'] for r in rows], [max(.1,r['elapsed_ms']) for r in rows], s=5, alpha=.65, color=color, label='Quiet tenant PHP' if role=='victim' else 'Quiet tenant static')
axes[1].axhline(1000, color='#ad3333', linestyle='--', linewidth=1, label='1 s deadline')
axes[1].set_yscale('log')
axes[1].legend(loc='upper left', ncol=3, fontsize=8)
xs, usage = [], []
for a,b in zip(valid_metrics,valid_metrics[1:]):
    dt=b['t_s']-a['t_s']
    xs.append(b['t_s'])
    usage.append((cpu(b)['usage_usec']-cpu(a)['usage_usec'])/1e6/dt)
if valid_metrics:
    axes[2].plot(xs,usage,color='#66519b',linewidth=1)
    axes[2].axhline(2, color='#777',linestyle='--',linewidth=.8)
    axes[2].set_ylabel('Service CPU\ncores used')
for ax in axes:
    ax.grid(alpha=.18)
    ax.spines[['top','right']].set_visible(False)
for p in phases:
    if p['phase']=='baseline':
        axes[0].text(p['start_s'],9,f"Trial {p['trial']}: busy {p['attacker'].split('.')[0].title()}",fontsize=9)
axes[0].set_ylim(0,11)
axes[0].set_yticks([0,1,2,4,8])
axes[0].set_ylabel('Busy client\nconcurrency')
axes[1].set_ylabel('Quiet response latency (ms)\nlog scale; timeouts included')
axes[-1].set_xlabel('Elapsed seconds')
fig.suptitle('ePHPm noisy-neighbor experiment — shared pool, no per-site rate cap',fontsize=14)
fig.tight_layout()
fig.savefig(root/'timeline.png',dpi=160)
fig.savefig(root/'timeline.svg')
print(root/'REPORT.md')
