<?php
// Fixed finite workload: no parameters, allocation growth, I/O, or external target.
$start = hrtime(true);
$hash = 'ephpm-lab-noisy-neighbor';
for ($i = 0; $i < 1000000; $i++) {
    $hash = hash('sha256', $hash);
}
header('Content-Type: application/json');
echo json_encode(['work' => 1000000, 'digest' => $hash, 'elapsed_ms' => (hrtime(true) - $start) / 1e6]);
