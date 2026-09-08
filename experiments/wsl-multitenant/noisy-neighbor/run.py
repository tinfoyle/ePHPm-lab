#!/usr/bin/env python3
"""Bounded local experiment. Run as root via ip netns exec ephpm-lab.
Only fixed loopback destination and two allowlisted virtual hosts are used.
"""
import argparse
import asyncio
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import time

CG = Path('/sys/fs/cgroup/system.slice/ephpm-lab.service')
ROOT = Path('/srv/ephpm/sites')
HOSTS = ('alice.lab.test', 'bob.lab.test')

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=30, choices=range(10, 61))
    parser.add_argument('--trials', type=int, default=3, choices=range(1, 4))
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    if 'ephpm-lab.service' in Path('/proc/self/cgroup').read_text():
        raise RuntimeError('Load generator must be outside serving cgroup')
    # Fail before applying pressure if namespace entry hid the cgroup mount.
    for filename in ('cpu.stat', 'memory.current', 'memory.events', 'pids.current', 'cpu.pressure'):
        (CG/filename).read_text()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=False)
    config = Path('/etc/ephpm-lab/ephpm.toml').read_bytes()
    (out / 'ephpm.toml').write_bytes(config)
    metadata = dict(kernel=platform.release(), started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                    seconds=args.seconds, trials=args.trials, victim_rps=2, static_rps=1,
                    victim_deadline_seconds=1, attacker_deadline_seconds=10,
                    config_sha256=hashlib.sha256(config).hexdigest(), generator_cgroup=Path('/proc/self/cgroup').read_text(),
                    threshold='victim successful-response p95 > max(5 * baseline p95, 250 ms), OR >1% scheduled victim requests miss 1 s deadline/fail',
                    workload_sha256=hashlib.sha256(Path(__file__).with_name('cpu.php').read_bytes()).hexdigest())
    (out / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    start = time.monotonic()
    requests = (out / 'requests.jsonl').open('w', buffering=1)
    metrics = (out / 'metrics.jsonl').open('w', buffering=1)
    phases = []
    records = []
    label = {'trial': 0, 'phase': 'warmup', 'concurrency': 0}
    finished = asyncio.Event()

    async def request(host, path, role, deadline, scheduled=None):
        began = time.monotonic()
        planned = began if scheduled is None else scheduled
        row = dict(label, host=host, role=role, path=path, scheduled_s=planned-start, start_s=began-start,
                   scheduler_lag_ms=(began-planned)*1000, status=None, error=None)
        writer = None
        try:
            async with asyncio.timeout(max(0.001, deadline - (began-planned))):
                reader, writer = await asyncio.open_connection('127.0.0.1', 8080)
                writer.write(f'GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
                await writer.drain()
                body = await reader.read(65536)
                # Read through EOF: these fixtures are tiny and response is connection-close.
                while chunk := await reader.read(65536):
                    body += chunk
                    if len(body) > 1048576:
                        raise RuntimeError('Unexpected response >1 MiB')
                row['status'] = int(body.split(b' ', 2)[1])
                if row['status'] != 200:
                    row['error'] = 'http_error'
        except TimeoutError:
            row['error'] = 'timeout'
        except Exception as exc:
            row['error'] = type(exc).__name__ + ': ' + str(exc)
        finally:
            if writer:
                writer.close()
            row['elapsed_ms'] = (time.monotonic()-planned)*1000
            row['deadline_missed'] = row['elapsed_ms'] > deadline*1000 or row['error'] is not None
            records.append(row)
            requests.write(json.dumps(row)+'\n')
        return row

    async def telemetry():
        while not finished.is_set():
            row = dict(label, t_s=time.monotonic()-start)
            for filename in ('cpu.stat', 'memory.current', 'memory.events', 'pids.current', 'cpu.pressure'):
                try:
                    row[filename] = (CG/filename).read_text().strip()
                except OSError as exc:
                    row[filename] = str(exc)
            metrics.write(json.dumps(row)+'\n')
            await asyncio.sleep(1)

    async def phase(trial, name, attacker, victim, concurrency, duration):
        nonlocal label
        label = dict(trial=trial, phase=name, concurrency=concurrency)
        began = time.monotonic()
        end = began+duration
        phases.append(dict(label, attacker=attacker, victim=victim, start_s=began-start, duration_s=duration))
        print(json.dumps(phases[-1]), flush=True)
        async def pressure():
            while time.monotonic() < end:
                row = await request(attacker, '/noisy-cpu.php', 'attacker', 10)
                if row['error']:
                    await asyncio.sleep(0.1)  # Bound even rapid refusals; do not spin on 429.
        async def fixed_rate(role, path, rate):
            pending = []
            for i in range(round(duration*rate)):
                planned = began+i/rate
                await asyncio.sleep(max(0, planned-time.monotonic()))
                pending.append(asyncio.create_task(request(victim, path, role, 1, planned)))
            await asyncio.gather(*pending)
        await asyncio.gather(*(pressure() for _ in range(concurrency)),
                             fixed_rate('victim', '/index.php', 2), fixed_rate('static', '/control.txt', 1))
        await asyncio.sleep(max(0, end-time.monotonic()))
        # All pressure clients drained before changing phase; no intentional backlog carryover.

    sampler = asyncio.create_task(telemetry())
    try:
        await phase(0, 'warmup', HOSTS[0], HOSTS[1], 0, 10)
        for trial in range(1, args.trials+1):
            attacker, victim = HOSTS if trial % 2 else HOSTS[::-1]
            await phase(trial, 'baseline', attacker, victim, 0, args.seconds)
            for concurrency in (1, 2, 4, 8):
                await phase(trial, f'load-{concurrency}', attacker, victim, concurrency, args.seconds)
            await phase(trial, 'recovery', attacker, victim, 0, args.seconds)
    finally:
        finished.set()
        await sampler
        requests.close()
        metrics.close()
        (out/'phases.json').write_text(json.dumps(phases, indent=2))
    summary = []
    for p in phases:
        for role in ('victim', 'static', 'attacker'):
            rows = [r for r in records if r['trial']==p['trial'] and r['phase']==p['phase'] and r['role']==role]
            if not rows:
                continue
            successful = sorted(r['elapsed_ms'] for r in rows if r['error'] is None)
            def percentile(q):
                return successful[max(0, math.ceil(q*len(successful))-1)] if successful else None
            summary.append(dict(p, role=role, requests=len(rows), errors=sum(r['error'] is not None for r in rows),
                                missed=sum(r['deadline_missed'] for r in rows), p50_ms=percentile(.5),
                                p95_ms=percentile(.95), p99_ms=percentile(.99),
                                max_scheduler_lag_ms=max(r['scheduler_lag_ms'] for r in rows)))
    (out/'summary.json').write_text(json.dumps(summary, indent=2))
    print('COMPLETE '+str(out), flush=True)

if __name__ == '__main__':
    asyncio.run(main())
