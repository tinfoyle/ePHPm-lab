"""An expendable third site tests port quotas and same-name state reuse."""
import os, pwd, shutil, subprocess, time
from pathlib import Path
from harness import Lab, HOSTS, php_value
lab=Lab('recycle');host=lab.prefix+'.lab.test'
site=Path('/srv/ephpm/sites')/host;override=Path('/etc/ephpm-lab/sites')/(host+'.toml');uid=pwd.getpwnam('ephpm-web').pw_uid
def request(name):return lab.request(HOSTS[0],'/'+name,headers={'Host':host})
def write(name,body):
    p=site/'public'/name;p.write_text('<?php header("Content-Type: application/json");\n'+body);p.chmod(0o644)
try:
    site.mkdir();(site/'public').mkdir();os.chown(site,uid,uid);os.chown(site/'public',uid,uid)
    override.write_text('document_root = "public"\n')
    write('quota.php',"""$r=[];set_error_handler(fn()=>true);for($i=0;$i<10;$i++){$s=stream_socket_server('tcp://127.0.0.1:'.(15000+$i),$n,$e);$r[]=['virtual'=>15000+$i,'opened'=>(bool)$s,'actual'=>$s?stream_socket_get_name($s,false):null,'errno'=>$n,'error'=>$e];if($s)fclose($s);}echo json_encode($r);""")
    write('seed.php',f"ephpm_kv_set('{lab.prefix}','OLD-TENANT');ephpm_db_execute('CREATE TABLE security_recycle (value TEXT)');ephpm_db_execute(\"INSERT INTO security_recycle VALUES ('OLD-TENANT')\");echo json_encode(['kv'=>ephpm_kv_get('{lab.prefix}'),'db'=>ephpm_db_query('SELECT * FROM security_recycle')]);")
    write('read.php',f"$r=['kv'=>ephpm_kv_get('{lab.prefix}')];try{{$r['db']=ephpm_db_query('SELECT * FROM security_recycle');}}catch(Throwable $e){{$r['db_error']=$e->getMessage();}}echo json_encode($r);")
    write('clean.php',f"ephpm_kv_del('{lab.prefix}');ephpm_db_execute('DROP TABLE IF EXISTS security_recycle');echo json_encode(['clean'=>true]);")
    lab.record('sidecar port quota',response=request('quota.php'))
    lab.record('state positive control',response=request('seed.php'))
    saved=lab.out/'removed-site';site.rename(saved);override.unlink()
    time.sleep(.3);lab.record('site absent',response=request('read.php'))
    # Same path recreation represents identity reuse, not a new identity. This
    # intentionally does not call controller teardown and is reported as such.
    saved.rename(site);override.write_text('document_root = "public"\n')
    time.sleep(.3);lab.record('same-name recreation without explicit state purge',response=request('read.php'))
    lab.record('closed listeners still consume port quota',response=request('quota.php'))
    lab.record('state cleanup',response=request('clean.php'))
finally:
    # Only this script's uniquely named site and its exact DB artifacts.
    assert site.parent==Path('/srv/ephpm/sites') and site.name.startswith(lab.prefix)
    if site.exists():shutil.rmtree(site)
    override.unlink(missing_ok=True)
    subprocess.run(['systemctl','restart','ephpm-lab.service'],check=True)
    for suffix in ['.db','.db-wal','.db-shm','.db-journal']:
        p=Path('/var/lib/ephpm-web/db')/(host+suffix);p.unlink(missing_ok=True)
    lab.record('recycle cleanup',site_absent=not site.exists(),override_absent=not override.exists())
    lab.cleanup()
