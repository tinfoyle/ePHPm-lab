<?php
// Deliberately benign readiness fixture. No probing, exec or cross-tenant access.
header('Content-Type: application/json');
$tenant = trim(file_get_contents(__DIR__ . '/../tenant-id'));
echo json_encode([
    'experiment' => 'wsl-multitenant',
    'tenant' => $tenant,
    'php' => PHP_VERSION,
    'mode' => 'per_request',
    'kv_available' => function_exists('ephpm_kv_get'),
    'db_available' => function_exists('ephpm_db_query'),
    'status' => 'ready-for-test-planning',
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
