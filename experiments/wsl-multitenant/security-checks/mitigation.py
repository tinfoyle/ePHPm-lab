"""Repeat the original 30-second load ladder with documented site limits."""
import subprocess, time
from pathlib import Path
from harness import Lab
lab=Lab('mitigation');config=Path('/etc/ephpm-lab/ephpm.toml');baseline=config.read_bytes()
try:
    assert b'[server.limits]' not in baseline
    config.write_bytes(baseline+b'\n[server.limits]\nper_site_rate = 5.0\nper_site_burst = 20\n')
    (lab.out/'limited-ephpm.toml').write_bytes(config.read_bytes())
    subprocess.run(['systemctl','restart','ephpm-lab.service'],check=True);time.sleep(1)
    with open(lab.out/'load.log','w') as log:
        r=subprocess.run(['python3','/opt/ephpm-lab/noisy-neighbor/run.py','--seconds','30','--trials','1','--output',str(lab.out/'load')],stdout=log,stderr=subprocess.STDOUT,timeout=240)
    lab.record('limited load ladder',exit=r.returncode,summary='load/summary.json',settings={'per_site_rate':5,'per_site_burst':20})
finally:
    config.write_bytes(baseline)
    subprocess.run(['systemctl','restart','ephpm-lab.service'],check=True)
    lab.record('baseline restored',identical=config.read_bytes()==baseline)
    lab.cleanup()
