"""Bounded failure and service restart controls; restores the baseline config."""
import subprocess, socket, time
from pathlib import Path
from harness import Lab, HOSTS
lab=Lab('lifecycle')
config=Path('/etc/ephpm-lab/ephpm.toml'); baseline=config.read_bytes()
def call(*a,timeout=20):return subprocess.run(a,capture_output=True,text=True,timeout=timeout)
try:
    # A separate transient service has no capability to attach eBPF. The main
    # service remains active; use a different HTTP port to avoid bind conflict.
    bad=Path('/etc/ephpm-lab')/(lab.prefix+'-bad.toml');lab.files.add(bad)
    bad.write_text(baseline.decode().replace('127.0.0.1:8080','127.0.0.1:18089')+'\n[db.sqlite.proxy]\nmysql_listen = "127.0.0.1:13389"\n')
    unit=lab.prefix+'-policy'
    r=call('systemd-run','--unit='+unit,'--wait','--pipe','--collect',
       '-p','User=ephpm-web','-p','CapabilityBoundingSet=',
       '-p','NetworkNamespacePath=/run/netns/ephpm-lab',
       '-p','RuntimeMaxSec=8','/usr/local/bin/ephpm','serve','--config',str(bad))
    s=socket.socket();s.settimeout(.3);opened=s.connect_ex(('127.0.0.1',18089))==0;s.close()
    lab.record('missing BPF capabilities fails closed',exit=r.returncode,stdout=r.stdout,stderr=r.stderr,listener_open=opened)
    lab.record('before restart',pid=lab.pid,bpf=call('bpftool','cgroup','tree','/sys/fs/cgroup/system.slice/ephpm-lab.service').stdout)
    r=call('systemctl','stop','ephpm-lab.service')
    s=socket.socket();s.settimeout(.3);opened=s.connect_ex(('127.0.0.1',8080))==0;s.close()
    lab.record('stopped',exit=r.returncode,listener_open=opened,bpf_vhost_programs=[s for s in call('bpftool','prog','show').stdout.splitlines() if 'vhost_' in s])
    r=call('systemctl','start','ephpm-lab.service');time.sleep(1)
    lab.record('restarted',exit=r.returncode,new_pid=call('systemctl','show','ephpm-lab.service','-p','MainPID','--value').stdout,bpf=call('bpftool','cgroup','tree','/sys/fs/cgroup/system.slice/ephpm-lab.service').stdout,responses=[lab.request(h,'/_ephpm/ready') for h in HOSTS])
finally:
    assert config.read_bytes()==baseline
    call('systemctl','start','ephpm-lab.service')
    lab.cleanup()
