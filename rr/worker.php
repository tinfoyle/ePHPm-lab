<?php
require __DIR__ . '/vendor/autoload.php';

use Nyholm\Psr7\Factory\Psr17Factory;
use Spiral\RoadRunner\Http\PSR7Worker;
use Spiral\RoadRunner\Worker;

ini_set('display_errors', 'stderr');

$factory = new Psr17Factory();
$worker  = new PSR7Worker(Worker::create(), $factory, $factory, $factory);

while ($req = $worker->waitRequest()) {
    try {
        $path = $req->getUri()->getPath();
        if ($path === '/hello' || $path === '/hello.php') {
            $body = json_encode(['ok' => true, 't' => microtime(true)]);
            $resp = $factory->createResponse(200)
                ->withHeader('Content-Type', 'application/json');
            $resp->getBody()->write($body);
            $worker->respond($resp);
            continue;
        }
        if ($path === '/cpu' || $path === '/cpu.php') {
            $h = '';
            for ($i = 0; $i < 5000; $i++) { $h = hash('sha256', $h . $i); }
            $body = json_encode(['h' => substr($h, 0, 16)]);
            $resp = $factory->createResponse(200)
                ->withHeader('Content-Type', 'application/json');
            $resp->getBody()->write($body);
            $worker->respond($resp);
            continue;
        }
        $resp = $factory->createResponse(404);
        $resp->getBody()->write('nf');
        $worker->respond($resp);
    } catch (\Throwable $e) {
        $worker->getWorker()->error((string)$e);
    }
}
