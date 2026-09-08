import http.client
import json
import socket
import h2.connection
import h2.config
import h2.events
from harness import Lab, HOSTS, php_value
lab=Lab('routing')
try:
    probes={h:lab.php(h,'route',"echo json_encode(['tenant'=>trim(file_get_contents(dirname(__DIR__).'/tenant-id')),'host'=>$_SERVER['HTTP_HOST']??null,'basedir'=>ini_get('open_basedir')]);") for h in HOSTS}
    path='/'+probes[HOSTS[0]].name
    cases=[('canonical',HOSTS[0],{}),('uppercase','ALICE.LAB.TEST',{}),('trailing dot','alice.lab.test.',{}),('port','alice.lab.test:8080',{}),
           ('forwarded host',HOSTS[0],{'X-Forwarded-Host':HOSTS[1],'Forwarded':'host='+HOSTS[1]}),
           ('traversal','../bob.lab.test',{}),('encoded traversal','%2e%2e/bob.lab.test',{}),('backslash','alice.lab.test\\..\\bob.lab.test',{}),('unknown','missing.lab.test',{})]
    for label,host,headers in cases:
        lab.record('HTTP1 '+label,sent_host=host,response=lab.request(HOSTS[0],path,headers={'Host':host,**headers}))
    c=http.client.HTTPConnection('127.0.0.1',8080,timeout=3)
    for host in HOSTS*4:
        c.request('GET',path,headers={'Host':host});r=c.getresponse();body=r.read().decode()
        lab.record('HTTP1 connection reuse',sent_host=host,status=r.status,body=body)
    c.close()
    for label,raw in [
        ('duplicate host',f'GET {path} HTTP/1.1\r\nHost: {HOSTS[0]}\r\nHost: {HOSTS[1]}\r\nConnection: close\r\n\r\n'),
        ('absolute URI conflict',f'GET http://{HOSTS[1]}{path} HTTP/1.1\r\nHost: {HOSTS[0]}\r\nConnection: close\r\n\r\n'),
        ('missing host',f'GET {path} HTTP/1.1\r\nConnection: close\r\n\r\n')]:
        with socket.create_connection(('127.0.0.1',8080),timeout=3) as s:
            s.sendall(raw.encode());parts=[]
            try:
                while b:=s.recv(65536):parts.append(b)
            except socket.timeout:pass
            lab.record('HTTP1 '+label,raw_response=b''.join(parts).decode(errors='replace'))
    # Send real HTTP/2 prior-knowledge frames; reuse one connection across authorities.
    try:
        with socket.create_connection(('127.0.0.1',8080),timeout=3) as s:
            conn=h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=True,header_encoding='utf-8',validate_outbound_headers=False))
            conn.initiate_connection();s.sendall(conn.data_to_send())
            for host,extra in [(HOSTS[0],[]),(HOSTS[1],[]),(HOSTS[0],[('host',HOSTS[1])]),(HOSTS[1],[('x-forwarded-host',HOSTS[0])])]:
                sid=conn.get_next_available_stream_id();conn.send_headers(sid,[(':method','GET'),(':scheme','http'),(':authority',host),(':path',path)]+extra,end_stream=True);s.sendall(conn.data_to_send())
                body=b'';headers=[];events=[];done=False
                while not done:
                    incoming=s.recv(65536)
                    if not incoming:break
                    for e in conn.receive_data(incoming):
                        events.append(type(e).__name__)
                        if isinstance(e,h2.events.ResponseReceived):headers=e.headers
                        if isinstance(e,h2.events.DataReceived):body+=e.data;conn.acknowledge_received_data(e.flow_controlled_length,e.stream_id)
                        if isinstance(e,(h2.events.StreamEnded,h2.events.StreamReset,h2.events.ConnectionTerminated)):done=True
                    s.sendall(conn.data_to_send())
                lab.record('HTTP2 authority routing',authority=host,extra_headers=extra,headers=headers,body=body.decode(errors='replace'),events=events)
    except Exception as e:lab.record('HTTP2 transport',error=str(e))
    for host in HOSTS:
        for endpoint in ['/_ephpm/health','/_ephpm/ready','/_ephpm/primary','/_ephpm/requests','/_ephpm/config','/_ephpm/deploy','/_ephpm/metrics','/metrics','/api/config','/api/workers']:
            r=lab.request(host,endpoint);r['body']=r['body'][:8000]
            lab.record('management public surface',host=host,path=endpoint,response=r)
    # A tenant-origin HTTP fetch, including the confirmed mapped-address bypass candidate.
    for address in ['127.0.0.1','[::ffff:127.0.0.1]']:
        probe=lab.php(HOSTS[1],'internal-'+str(len(address)),f"""
$warnings=[];set_error_handler(function($n,$s)use(&$warnings){{$warnings[]=$s;return true;}});
$ctx=stream_context_create(['http'=>['timeout'=>1,'header'=>'Host: bob.lab.test']]);
$b=file_get_contents('http://{address}:8080/_ephpm/ready',false,$ctx);echo json_encode(['body'=>$b,'warnings'=>$warnings]);
""")
        lab.record('management tenant-origin readiness',address=address,response=lab.request(HOSTS[1],probe))
finally:lab.cleanup()
