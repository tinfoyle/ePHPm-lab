import base64
import fcntl
import http.client
import json
from pathlib import Path
import secrets
import subprocess
import time

HOSTS = ('alice.lab.test', 'bob.lab.test')

class Lab:
    def __init__(self, category):
        assert Path('/etc/ephpm-lab-instance').read_text().strip() == 'ephpm-wsl-multitenant-v1'
        self.lock = open('/run/ephpm-security-checks.lock', 'w')
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.pid = int(subprocess.check_output(['systemctl','show','ephpm-lab.service','-p','MainPID','--value']))
        assert self.pid > 0
        self.root = Path(f'/proc/{self.pid}/root')
        self.prefix = 'security-' + secrets.token_hex(8)
        self.run_id = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + category
        self.out = Path('/var/lib/ephpm-lab/security-checks') / self.run_id
        self.out.mkdir(parents=True)
        self.files = set()
        self.evidence = {'category': category, 'run_id': self.run_id, 'pid':self.pid, 'cases':[], 'cleanup':{}}
        (self.out/'ephpm.toml').write_bytes(Path('/etc/ephpm-lab/ephpm.toml').read_bytes())
        self.save()

    def save(self):
        (self.out/'evidence.json').write_text(json.dumps(self.evidence, indent=2))

    def record(self, label, **values):
        self.evidence['cases'].append({'label':label, **values}); self.save()

    def file(self, host, name, content):
        assert host in HOSTS and '/' not in name
        p = Path('/srv/ephpm/sites', host, 'public', self.prefix+'-'+name)
        self.files.add(p)
        p.write_text(content); p.chmod(0o644)
        return p

    def php(self, host, name, body):
        return self.file(host, name+'.php', "<?php\nheader('Content-Type: application/json');\n"+body)

    def request(self, host, path, timeout=12, headers=None, body=None, method='GET'):
        assert host in HOSTS
        h = {'Host':host}; h.update(headers or {})
        c = http.client.HTTPConnection('127.0.0.1',8080,timeout=timeout)
        try:
            c.request(method, '/'+path.name if isinstance(path,Path) else path, body=body, headers=h)
            r=c.getresponse(); b=r.read()
            result={'status':r.status,'headers':dict(r.getheaders()),'body':b.decode(errors='replace')}
            try: result['json']=json.loads(b)
            except Exception: pass
            return result
        finally: c.close()

    def cleanup(self):
        for p in self.files:
            try:
                assert p.name.startswith(self.prefix)
                p.unlink(missing_ok=True)
                self.evidence['cleanup'][str(p)] = not p.exists()
            except Exception as e: self.evidence['cleanup'][str(p)] = str(e)
        self.save()
        print(self.out, flush=True)

def php_value(value):
    encoded=base64.b64encode(json.dumps(value).encode()).decode()
    return f"json_decode(base64_decode('{encoded}'), true)"
