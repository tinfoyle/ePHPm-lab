import concurrent.futures, time, json, os, pwd
from pathlib import Path
from harness import Lab, HOSTS, php_value
lab=Lab('storage'); table='security_'+lab.prefix.split('-')[1]; endpoints={}
try:
    for host in HOSTS:
        peer=next(h for h in HOSTS if h!=host)
        endpoints[host]={}
        for action in ['write','read','peer-auth','switch-db','cleanup']:
            body=f"""
$r=['user'=>$_SERVER['DB_USER']??null,'password_present'=>isset($_SERVER['DB_PASSWORD'])];
try {{
$u=$_SERVER['DB_USER'];$pw=$_SERVER['DB_PASSWORD'];$db=$_SERVER['DB_NAME'];
if('{action}'==='peer-auth')$u={php_value(peer)};
$p=new PDO("mysql:host={{$_SERVER['DB_HOST']}};port={{$_SERVER['DB_PORT']}};dbname=$db",$u,$pw,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$r['connected']=true;
if('{action}'==='write'){{$p->exec('CREATE TABLE {table} (id INTEGER PRIMARY KEY, value TEXT)');$s=$p->prepare('INSERT INTO {table} VALUES (1,?)');$s->execute([{php_value(host)}]);}}
if('{action}'==='switch-db'){{$p->exec('USE `{peer}`');$r['use_peer_accepted']=true;}}
if('{action}'==='cleanup')$p->exec('DROP TABLE IF EXISTS {table}');
else $r['rows']=$p->query('SELECT * FROM {table}')->fetchAll(PDO::FETCH_ASSOC);
}}catch(Throwable $e){{$r['exception']=$e->getMessage();}}
echo json_encode($r);
"""
            endpoints[host][action]=lab.php(host,'mysql-'+action,body)
    for host,action in [(HOSTS[0],'write'),(HOSTS[1],'read'),(HOSTS[1],'write')]+[(h,a) for h in HOSTS for a in ['read','peer-auth','switch-db']]:
        lab.record('MySQL '+action,host=host,response=lab.request(host,endpoints[host][action]))
    # Hold a real upload open, then let the other tenant try its exact path.
    for host in HOSTS:
        peer=next(h for h in HOSTS if h!=host)
        state=lab.file(host,'upload-state','')
        os.chown(state,pwd.getpwnam('ephpm-web').pw_uid,-1)
        upload=lab.php(host,'held-upload',f"""
$u=$_FILES['file'];file_put_contents({php_value(str(state))},json_encode($u));usleep(1800000);
echo json_encode(['uploaded'=>is_uploaded_file($u['tmp_name']),'content'=>file_get_contents($u['tmp_name'])]);
""")
        body=(f'--{lab.prefix}\r\nContent-Disposition: form-data; name="file"; filename="canary.txt"\r\n\r\n{host}:{lab.prefix}\r\n--{lab.prefix}--\r\n').encode()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            f=pool.submit(lab.request,host,upload,headers={'Content-Type':'multipart/form-data; boundary='+lab.prefix},body=body,method='POST')
            deadline=time.monotonic()+1
            while not state.read_text() and time.monotonic()<deadline:time.sleep(.02)
            info=json.loads(state.read_text());path=info['tmp_name']
            p=lab.php(peer,'peer-upload',f"""$w=[];set_error_handler(function($n,$s)use(&$w){{$w[]=$s;return true;}});echo json_encode(['read'=>file_get_contents({php_value(path)}),'append'=>file_put_contents({php_value(path)},'CHANGED',FILE_APPEND),'warnings'=>$w]);""")
            lab.record('live peer upload access',owner=host,peer=peer,path=path,exists_during_probe=(lab.root/path.lstrip('/')).exists(),peer_response=lab.request(peer,p),owner_response=f.result())
finally:
    for host in HOSTS:
        if host in endpoints and 'cleanup' in endpoints[host]:lab.record('MySQL cleanup',host=host,response=lab.request(host,endpoints[host]['cleanup']))
    lab.cleanup()
