import concurrent.futures
import gzip
import hashlib
import json
from pathlib import Path
import time
from harness import Lab, HOSTS, php_value

lab=Lab('php-boundaries')
common="""
$warn=[];set_error_handler(function($n,$s)use(&$warn){$warn[]=$s;return true;});
function check($f){global $warn;$warn=[];try{$v=$f();return ['value'=>$v,'warnings'=>$warn];}catch(Throwable $e){return ['value'=>false,'exception'=>get_class($e).': '.$e->getMessage(),'warnings'=>$warn];}}
"""
try:
    secrets={h:lab.file(h,'canary.txt',h+':'+lab.prefix) for h in HOSTS}
    for host in HOSTS:
        peer=next(h for h in HOSTS if h!=host)
        own_link=lab.file(host,'own-link','');own_link.unlink();own_link.symlink_to(secrets[host])
        peer_link=lab.file(host,'peer-link','');peer_link.unlink();peer_link.symlink_to(secrets[peer])
        paths={
            'own':str(secrets[host]),'own_symlink':str(own_link),'peer':str(secrets[peer]),'peer_symlink':str(peer_link),
            'peer_traversal':str(secrets[host].parent)+'/../../'+peer+'/public/'+secrets[peer].name,
            'peer_file_wrapper':'file://'+str(secrets[peer]),
            'peer_filter':'php://filter/convert.base64-encode/resource='+str(secrets[peer]),
            'own_filter':'php://filter/convert.base64-encode/resource='+str(secrets[host]),
            'peer_proc_root':'/proc/self/root'+str(secrets[peer])}
        probe=lab.php(host,'filesystem',common+f"""
$r=[];foreach({php_value(paths)} as $k=>$p){{$r[$k]=check(fn()=>file_get_contents($p));}}
$before=ini_get('open_basedir');
foreach(['open_basedir'=>'/','sys_temp_dir'=>'/tmp','upload_tmp_dir'=>'/tmp','session.save_path'=>'/tmp','disable_functions'=>'','mysqli.allow_persistent'=>'1'] as $k=>$v){{
 $r['ini_'.$k]=check(fn()=>ini_set($k,$v));$r['effective_'.$k]=ini_get($k);
}}
$r['peer_after_ini']=check(fn()=>file_get_contents({php_value(str(secrets[peer]))}));
$r['open_basedir_before']=$before;echo json_encode($r);
""")
        lab.record('filesystem and runtime restriction changes',host=host,response=lab.request(host,probe))

    # Request state: sequential and overlapping requests, both host directions.
    envkey='EPHPM_LAB_'+lab.prefix.replace('-','_').upper()
    observers={}
    mutators={}
    for host in HOSTS:
        observers[host]=lab.php(host,'state-observe',f"""
$previous=set_error_handler(function(){{return true;}});restore_error_handler();
echo json_encode(['host'=>$_SERVER['HTTP_HOST'],'env'=>getenv('{envkey}'),'global'=>$GLOBALS['lab_marker']??null,
'precision'=>ini_get('precision'),'include_path'=>get_include_path(),'cwd'=>getcwd(),'previous_handler'=>is_null($previous)?null:get_debug_type($previous)]);
""")
        mutators[host]=lab.php(host,'state-mutate',f"""
$GLOBALS['lab_marker']={php_value(host+':'+lab.prefix)};
putenv('{envkey}='+ '');
""".replace("putenv('"+envkey+"='+ '');",f"putenv('{envkey}={host}:{lab.prefix}');")+f"""
ini_set('precision','3');set_include_path(dirname(__DIR__));chdir(dirname(__DIR__));set_error_handler(function(){{return true;}});
usleep(500000);echo json_encode(['set'=>{php_value(host+':'+lab.prefix)}]);
""")
        lab.record('state baseline',host=host,response=lab.request(host,observers[host]))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for host in HOSTS:
            peer=next(h for h in HOSTS if h!=host)
            for roundno in range(3):
                f=pool.submit(lab.request,host,mutators[host]);time.sleep(.05)
                observed=[lab.request(peer,observers[peer]) for _ in range(10)]
                lab.record('overlapping request state',mutator=host,observer=peer,round=roundno,observed=observed,mutator_response=f.result())
            lab.record('state after shutdown',host=host,observations=[lab.request(h,observers[h]) for h in HOSTS for _ in range(8)])

    # Same session id in both sites; explicit files handler tests private session paths.
    sid=lab.prefix.replace('-','')
    session_endpoints={}
    for host in HOSTS:
        session_endpoints[host]={}
        for action in ['write','read','destroy']:
            operation = f"$_SESSION['canary']={php_value(host+':'+lab.prefix)};" if action=='write' else ''
            if action=='destroy':operation='session_destroy();'
            script=lab.php(host,'session-'+action,common+f"""
ini_set('session.use_cookies','0');ini_set('session.use_strict_mode','0');$handler=ini_set('session.save_handler','files');session_id('{sid}');
$ok=session_start();{operation}
$v=$_SESSION['canary']??null;$path=session_save_path();if(session_status()===PHP_SESSION_ACTIVE)session_write_close();
echo json_encode(['started'=>$ok,'handler'=>ini_get('session.save_handler'),'path'=>$path,'id'=>session_id(),'value'=>$v,'warnings'=>$warn]);
""")
            session_endpoints[host][action]=script
    for host,action in [(HOSTS[0],'write'),(HOSTS[1],'read'),(HOSTS[1],'write'),(HOSTS[0],'read'),(HOSTS[1],'read')]:
        lab.record('session '+action,host=host,response=lab.request(host,session_endpoints[host][action]))
    for host in HOSTS:lab.record('session cleanup',host=host,response=lab.request(host,session_endpoints[host]['destroy']))

    # Multipart upload placement; readback and peer read attempts before PHP cleanup.
    uploads={}
    for host in HOSTS:
        uploads[host]=lab.php(host,'upload',common+f"""
$u=$_FILES['file']??null;$r=['file'=>$u,'sys_temp'=>sys_get_temp_dir()];
if($u && $u['error']===0){{$r['uploaded']=is_uploaded_file($u['tmp_name']);$r['content']=file_get_contents($u['tmp_name']);}}
echo json_encode($r);
""")
        boundary=lab.prefix
        body=(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="../{lab.prefix}.txt"\r\nContent-Type: text/plain\r\n\r\n{host}:{lab.prefix}\r\n--{boundary}--\r\n').encode()
        r=lab.request(host,uploads[host],headers={'Content-Type':'multipart/form-data; boundary='+boundary},body=body,method='POST')
        lab.record('multipart upload',host=host,response=r)
        if r.get('json',{}).get('file',{}).get('tmp_name'):
            p=r['json']['file']['tmp_name'];lab.record('upload temporary cleanup',host=host,path=p,absent=not (lab.root/p.lstrip('/')).exists())

    # Native KV and embedded DB: same names, distinct values.
    table='security_'+lab.prefix.split('-')[1]
    endpoints={}
    for host in HOSTS:
        endpoints[host]={}
        for action in ['write','read','cleanup']:
            statement=''
            if action=='write':statement=f"ephpm_kv_set('{lab.prefix}',{php_value(host)});ephpm_db_execute('CREATE TABLE IF NOT EXISTS {table} (id INTEGER PRIMARY KEY, value TEXT)');ephpm_db_execute('INSERT INTO {table} (id,value) VALUES (1,?)',[{php_value(host)}]);"
            if action=='cleanup':statement=f"ephpm_kv_del('{lab.prefix}');ephpm_db_execute('DROP TABLE IF EXISTS {table}');"
            endpoints[host][action]=lab.php(host,'data-'+action,common+f"""
$r=['db_available'=>ephpm_db_available()];$r['action']=check(function(){{{statement}return true;}});
$r['kv']=check(fn()=>ephpm_kv_get('{lab.prefix}'));$r['db']=check(fn()=>ephpm_db_query('SELECT * FROM {table}'));
echo json_encode($r);
""")
    for host,action in [(HOSTS[0],'write'),(HOSTS[1],'read'),(HOSTS[1],'write'),(HOSTS[0],'read'),(HOSTS[1],'read')]:
        lab.record('data '+action,host=host,response=lab.request(host,endpoints[host][action]))
    for host in HOSTS:lab.record('data cleanup',host=host,response=lab.request(host,endpoints[host]['cleanup']))
finally:
    lab.cleanup()
