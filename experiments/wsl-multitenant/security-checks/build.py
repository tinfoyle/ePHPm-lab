import json
import os
from pathlib import Path
import subprocess
from harness import Lab, HOSTS
lab=Lab('build')
try:
    peer=lab.file(HOSTS[1],'build-peer-canary', 'BOB:'+lab.prefix)
    own=lab.file(HOSTS[0],'build-own-canary', 'ALICE:'+lab.prefix)
    # Synthetic, readable-by-UID control outside the allowed site: Landlock must deny it.
    outside=Path('/var/lib/ephpm-lab')/(lab.prefix+'-outside-canary');outside.write_text('CONTROL:'+lab.prefix);outside.chmod(0o644);lab.files.add(outside)
    output=own.parent/(lab.prefix+'-build-output');lab.files.add(output)
    envkey='SWITCHBOARD_SECRET_LAB_CANARY'
    childcode="""import json,os,pathlib,socket,subprocess
paths=json.loads(os.environ['SECURITY_PATHS']); r={'uid':os.getuid(),'parent_environment':os.getenv('SWITCHBOARD_SECRET_LAB_CANARY')}
for k,p in paths.items():
 try:r[k]={'read':pathlib.Path(p).read_text()}
 except Exception as e:r[k]={'error':str(e)}
try:pathlib.Path(paths['own_output']).write_text('BUILD-OWN-WRITE');r['own_write']=True
except Exception as e:r['own_write']=str(e)
try:
 with open(paths['peer'],'a') as f:f.write('MODIFIED-BY-ALICE')
 r['peer_append']=True
except Exception as e:r['peer_append']=str(e)
child=subprocess.run(['python3','-c','import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())',paths['peer']],capture_output=True,text=True,timeout=3)
r['subprocess_peer']={'exit':child.returncode,'stdout':child.stdout,'stderr':child.stderr}
try:
 s=socket.create_connection(('127.0.0.1',8080),timeout=1);s.sendall(b'GET /_ephpm/ready HTTP/1.1\\r\\nHost: alice.lab.test\\r\\nConnection: close\\r\\n\\r\\n');r['loopback_readiness']=s.recv(4096).decode();s.close()
except Exception as e:r['loopback_readiness']=str(e)
print(json.dumps(r))
"""
    env=os.environ.copy();env[envkey]=lab.prefix+'-SYNTHETIC-PARENT';env['SECURITY_PATHS']=json.dumps({'own':str(own),'peer':str(peer),'outside':str(outside),'own_output':str(output)})
    command=['/usr/local/bin/ephpm','exec','--config','/etc/ephpm-lab/ephpm.toml','--site',HOSTS[0],'--','python3','-c',childcode]
    r=subprocess.run(command,env=env,capture_output=True,text=True,timeout=20)
    lab.record('sandboxed preview command',command=command[:8]+['<fixed Python canary probe>'],exit=r.returncode,stdout=r.stdout,stderr=r.stderr)
    lab.record('post-build integrity',peer_unchanged=peer.read_text()=='BOB:'+lab.prefix,own_output_exists=output.exists())
    # Unknown site must not execute a marker command at all.
    bad=subprocess.run(['/usr/local/bin/ephpm','exec','--config','/etc/ephpm-lab/ephpm.toml','--site',lab.prefix+'.invalid','--','echo','SHOULD-NOT-RUN'],capture_output=True,text=True,timeout=5)
    lab.record('unknown site fails closed',exit=bad.returncode,stdout=bad.stdout,stderr=bad.stderr)
finally:lab.cleanup()
