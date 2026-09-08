#!/usr/bin/env python3
"""Fixed-path shared-temp test. Run through network-only nsenter in EPHPM-Lab."""
import base64
import fcntl
import hashlib
import http.client
import json
from pathlib import Path
import pwd
import secrets
import subprocess
import time

assert Path('/etc/ephpm-lab-instance').read_text().strip() == 'ephpm-wsl-multitenant-v1'
lock = open('/run/ephpm-shared-temp.lock', 'w')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
run_id = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
prefix = 'probe-' + secrets.token_hex(8)
hosts = ('alice.lab.test', 'bob.lab.test')
pid = int(subprocess.check_output(['systemctl', 'show', 'ephpm-lab.service', '-p', 'MainPID', '--value']))
assert pid > 0
service_root = Path(f'/proc/{pid}/root')
out = Path('/var/lib/ephpm-lab/shared-temp') / run_id
out.mkdir(parents=True, exist_ok=False)
template = Path(__file__).with_name('probe.php').read_text()
endpoints, candidates = [], set()
data = {'run_id': run_id, 'prefix': prefix, 'service_pid': pid, 'local': {}, 'cross': {}, 'os_control': {}, 'integrity': {}, 'cleanup': {}}
(out/'ephpm.toml').write_bytes(Path('/etc/ephpm-lab/ephpm.toml').read_bytes())

def view(path):
    p = Path(path)
    assert p.is_absolute() and '..' not in p.parts and p.name.startswith(prefix), path
    return service_root / str(p).lstrip('/')

def save():
    (out/'evidence.json').write_text(json.dumps(data, indent=2))

def request(host, filename):
    c = http.client.HTTPConnection('127.0.0.1', 8080, timeout=5)
    try:
        c.request('GET', '/' + filename, headers={'Host': host})
        r = c.getresponse(); body = r.read()
        assert r.status == 200, (host, r.status, body[:300])
        return json.loads(body)
    finally:
        c.close()

def install(host, phase, peers):
    name = f'{prefix}-{phase}.php'
    p = Path('/srv/ephpm/sites', host, 'public', name)
    content = template.replace('__PREFIX__', prefix).replace('__PEERS__', base64.b64encode(json.dumps(peers).encode()).decode())
    with p.open('x') as f: f.write(content)
    p.chmod(0o644); endpoints.append(p)
    return name

try:
    # Positive OS control: same UID and same mount view as ePHPm, but no PHP guard.
    # This is operator instrumentation, NOT execution obtained through tenant PHP.
    account = pwd.getpwnam('ephpm-web')
    control_paths = {label: directory+'/'+prefix+'-os-'+label for label,directory in [('tmp','/tmp'),('var_tmp','/var/tmp')]}
    candidates.update(control_paths.values())
    code = """import json,sys
paths=json.loads(sys.argv[1]); result={}
for label,path in paths.items():
 try:
  with open(path,'x') as f: f.write('synthetic-os-control:'+label)
  result[label]={'path':path,'created':True}
 except OSError as e: result[label]={'path':path,'created':False,'error':str(e)}
print(json.dumps(result))
"""
    raw = subprocess.check_output(['nsenter', '--target', str(pid), '--mount', '--', 'setpriv',
        '--reuid', str(account.pw_uid), '--regid', str(account.pw_gid), '--clear-groups',
        'python3', '-c', code, json.dumps(control_paths)])
    data['os_control'] = json.loads(raw)
    for host in hosts:
        data['local'][host] = request(host, install(host, 'local', {}))
        for label,r in data['local'][host]['results'].items():
            if 'path' in r: candidates.add(r['path'])
            elif label.startswith('tempnam') and isinstance(r['value'], str): candidates.add(r['value'])
        save()
    # Snapshot only files actually present; peers are never tested against nonexistent files.
    snapshots = {p: view(p).read_bytes() for p in candidates if view(p).is_file()}
    for host in hosts:
        other = next(h for h in hosts if h != host)
        peers = {'os_'+k:r['path'] for k,r in data['os_control'].items() if r['created']}
        for label,r in data['local'][other]['results'].items():
            if 'path' in r and r['path'] in snapshots: peers['peer_'+label] = r['path']
            elif label.startswith('tempnam') and isinstance(r['value'], str) and r['value'] in snapshots: peers['peer_'+label] = r['value']
        data['cross'][host] = request(host, install(host, 'cross', peers))
        save()
    for p, before in snapshots.items():
        after = view(p).read_bytes()
        data['integrity'][p] = {'unchanged': before == after, 'before_sha256': hashlib.sha256(before).hexdigest(), 'after_sha256': hashlib.sha256(after).hexdigest()}
finally:
    for p in sorted(candidates):
        try:
            f = view(p)
            if f.exists(): f.unlink()
            data['cleanup'][p] = not f.exists()
        except Exception as e: data['cleanup'][p] = str(e)
    for p in endpoints:
        try: p.unlink(); data['cleanup'][str(p)] = not p.exists()
        except Exception as e: data['cleanup'][str(p)] = str(e)
    save()
assert all(v is True for v in data['cleanup'].values()), 'Canary cleanup incomplete'
lines = ['# Shared temporary-path test', '', 'Both tenants were tested through HTTP, with unique disposable canaries and operator-side integrity checks.', '',
         '| Location / API | Alice | Bob |', '|---|---|---|']
for label in data['local'][hosts[0]]['results']:
    def outcome(host):
        r=data['local'][host]['results'][label]
        if 'write' in r: return 'Writable' if r['write']['value'] is not False else 'Denied / unavailable'
        return 'Succeeded' if r['value'] is not False else 'Denied / unavailable'
    lines.append(f'| {label} | {outcome(hosts[0])} | {outcome(hosts[1])} |')
lines += ['', '## Actual PHP temp configuration', '']
for host in hosts:
    lines += ['### '+host, '', '```json', json.dumps(data['local'][host]['info'],indent=2), '```', '']
lines += ['## Cross-tenant and shared canary checks', '', '| Requesting tenant | Target | Read | Append |', '|---|---|---|---|']
for host,result in data['cross'].items():
    for label,r in result['results'].items():
        lines.append(f"| {host} | {label} | {'Denied' if r['read']['value'] is False else 'READABLE'} | {'Denied' if r['append']['value'] is False else 'WRITABLE'} |")
lines += ['', '## Controls and limits', '',
          'The operator created controls in the service mount namespace as the ephpm-web Unix UID. This distinguishes OS writability from the PHP open_basedir restriction; it does not demonstrate tenant code execution outside PHP.', '',
          '```json', json.dumps(data['os_control'],indent=2), '```', '',
          f"All existing canaries unchanged after cross-access: {all(r['unchanged'] for r in data['integrity'].values())}. All tracked files/endpoints removed: {all(v is True for v in data['cleanup'].values())}.", '',
          'This is a direct PHP filesystem/API check in the current configuration. It does not test symlink races, native-extension escapes, uploads, session API isolation, or preview build execution. systemd PrivateTmp isolates the service from the host; per-tenant separation inside that service depends on ePHPm/PHP controls.', '',
          'Full paths, return values, PHP warnings, hashes, and cleanup outcomes are preserved in evidence.json. No actual secrets or pre-existing files were modified.', '']
(out/'REPORT.md').write_text('\n'.join(lines))
print(str(out), flush=True)
