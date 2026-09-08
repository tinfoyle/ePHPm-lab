import concurrent.futures
import json
import socket
import time
from harness import Lab, HOSTS, php_value

lab=Lab('network')
try:
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for family, bind, virtual in [('ipv4','0.0.0.0',14001),('ipv6','[::]',14002),
                                      ('ipv4-localhost','127.0.0.1',14003),('ipv6-localhost','[::1]',14004)]:
            state = lab.file(HOSTS[0],family+'-state.json','{}')
            state.unlink()
            server = lab.php(HOSTS[0], family+'-listener', f"""
$warnings=[]; set_error_handler(function($n,$s)use(&$warnings){{$warnings[]=$s;return true;}});
$listener=stream_socket_server('tcp://{bind}:{virtual}', $errno, $error);
if(!$listener){{file_put_contents({php_value(str(state))},json_encode(['error'=>$error,'errno'=>$errno,'warnings'=>$warnings]));echo json_encode(['error'=>$error]);return;}}
$actual=stream_socket_get_name($listener,false);
file_put_contents({php_value(str(state))},json_encode(['actual'=>$actual]));
$seen=[]; $until=microtime(true)+7;
while(microtime(true)<$until){{
 $client=stream_socket_accept($listener,0.2);
 if($client){{$seen[]=stream_socket_get_name($client,true);fwrite($client,'ALICE-{lab.prefix}');fclose($client);}}
}}
fclose($listener);echo json_encode(['actual'=>$actual,'accepted'=>$seen]);
""")
            future=pool.submit(lab.request, HOSTS[0], server)
            deadline=time.monotonic()+4
            while not state.exists() and time.monotonic()<deadline: time.sleep(.05)
            info=json.loads(state.read_text()) if state.exists() else {'error':'listener state missing'}
            lab.record(family+' listener start', result=info)
            if 'actual' not in info:
                lab.record(family+' listener response',response=future.result()); continue
            real=int(info['actual'].rsplit(':',1)[1])
            own_address='127.0.0.1' if family.startswith('ipv4') else '[::1]'
            # Controls and bypass candidates are all confined to the offline loopback namespace.
            for who, label, address, port in [
                (HOSTS[0],'own virtual port',own_address,virtual),
                (HOSTS[0],'own actual port',own_address,real),
                (HOSTS[1],'peer virtual port',own_address,virtual),
                (HOSTS[1],'peer actual port',own_address,real),
                (HOSTS[1],'peer alternate loopback','127.0.0.2',real),
                (HOSTS[1],'peer IPv4-mapped loopback','[::ffff:127.0.0.1]',real),
            ]:
                client=lab.php(who, family+'-client-'+str(port)+'-'+label.replace(' ','-'), f"""
$warnings=[];set_error_handler(function($n,$s)use(&$warnings){{$warnings[]=$s;return true;}});
$c=stream_socket_client('tcp://{address}:{port}',$errno,$error,0.4);
$body=false;if($c){{stream_set_timeout($c,1);$body=fread($c,256);fclose($c);}}
echo json_encode(['connected'=>$c!==false,'body'=>$body,'errno'=>$errno,'error'=>$error,'warnings'=>$warnings]);
""")
                response=lab.request(who,client)
                lab.record(family+' '+label, host=who, address=address, port=port, response=response)
            lab.record(family+' listener completed', response=future.result())
finally:
    lab.cleanup()
