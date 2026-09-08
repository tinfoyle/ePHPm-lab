"""Fake metadata endpoint on an isolated veth; never adds a default route."""
import json, subprocess, threading, socket, time
from harness import Lab, HOSTS, php_value

lab=Lab('outbound'); peer='ephpm-security-mock'; proc=None
def run(*args, **kw):
    return subprocess.run(args,check=True,capture_output=True,text=True,**kw)
original=run('nft','list','table','inet','ephpm_lab').stdout
try:
    run('ip','netns','add',peer)
    run('ip','link','add','sec-lab','type','veth','peer','name','sec-mock')
    run('ip','link','set','sec-mock','netns',peer)
    run('ip','addr','add','10.203.0.1/30','dev','sec-lab');run('ip','link','set','sec-lab','up')
    for args in [('link','set','lo','up'),('addr','add','10.203.0.2/30','dev','sec-mock'),('link','set','sec-mock','up'),('addr','add','169.254.169.254/32','dev','lo')]:
        run('ip','-n',peer,*args)
    run('ip','route','add','169.254.169.254/32','via','10.203.0.2')
    # Only the root positive-control collector may reach the mock. PHP keeps
    # the existing non-loopback deny policy. Return packets are permitted.
    run('nft','insert','rule','inet','ephpm_lab','output','oifname','sec-lab','meta','skuid','0','accept')
    run('nft','insert','rule','inet','ephpm_lab','input','iifname','sec-lab','ct','state','established,related','accept')
    code="""import socket,threading,time
def tcp():
 s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',18080));s.listen()
 while True:
  c,a=s.accept();c.recv(8192);print('TCP',a,flush=True);c.sendall(b'HTTP/1.0 200 OK\\r\\nContent-Length: 13\\r\\n\\r\\nMOCK-METADATA');c.close()
threading.Thread(target=tcp,daemon=True).start()
def udp(addr):
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((addr,18081))
 while True:
  d,a=s.recvfrom(4096);print('UDP',d.decode(errors='replace'),a,flush=True);s.sendto(b'MOCK-UDP',a)
for addr in ['10.203.0.2','169.254.169.254']:threading.Thread(target=udp,args=(addr,),daemon=True).start()
print('READY',flush=True)
while True:time.sleep(1)
"""
    log=open(lab.out/'mock.log','w+')
    proc=subprocess.Popen(['ip','netns','exec',peer,'python3','-u','-c',code],stdout=log,stderr=log)
    time.sleep(.3)
    for address in ['10.203.0.2','169.254.169.254']:
        s=socket.create_connection((address,18080),timeout=2);s.sendall(b'GET / HTTP/1.0\r\n\r\n');reply=s.recv(4096).decode();s.close()
        u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);u.settimeout(2);u.sendto(b'ROOT-POSITIVE',(address,18081));udp=u.recv(100).decode();u.close()
        assert 'MOCK-METADATA' in reply and udp=='MOCK-UDP'
        lab.record('root reachable positive control',address=address,tcp=reply,udp=udp)
    for host in HOSTS:
        p=lab.php(host,'outbound',"""
$r=[];set_error_handler(function() {return true;});
foreach (['10.203.0.2','169.254.169.254','2852039166','0xa9fea9fe','[::ffff:169.254.169.254]'] as $a) {
 $s=stream_socket_client('tcp://'.$a.':18080',$errno,$errstr,0.35);$r[$a]=['connected'=>(bool)$s,'errno'=>$errno,'error'=>$errstr];if($s)fclose($s);
}
$s=stream_socket_client('udp://169.254.169.254:18081',$errno,$errstr,0.35);
if($s){stream_set_timeout($s,0,350000);$r['udp']=['written'=>fwrite($s,'TENANT-PROBE'),'reply'=>fread($s,100),'meta'=>stream_get_meta_data($s)];fclose($s);}else $r['udp']=['error'=>$errstr];
echo json_encode($r);
""")
        lab.record('tenant outbound',host=host,response=lab.request(host,p))
    time.sleep(.2);log.flush();log.seek(0);received=log.read()
    lab.record('mock receipt log',log=received,tenant_datagram_received='TENANT-PROBE' in received)
    lab.record('effective firewall',rules=run('nft','list','table','inet','ephpm_lab').stdout)
finally:
    if proc:proc.terminate();proc.wait(timeout=3)
    run('nft','-f','-',input='delete table inet ephpm_lab\n'+original)
    subprocess.run(['ip','link','del','sec-lab'],capture_output=True)
    subprocess.run(['ip','netns','del',peer],capture_output=True)
    lab.record('restored firewall',identical=run('nft','list','table','inet','ephpm_lab').stdout==original)
    lab.cleanup()
