<?php
header('Content-Type: application/json');
$prefix = '__PREFIX__';
$peerPaths = json_decode(base64_decode('__PEERS__'), true);
$warnings = [];
set_error_handler(function($severity, $message) use (&$warnings) { $warnings[] = $message; return true; });
function attempt($fn) {
    global $warnings;
    $warnings = [];
    try { $value = $fn(); return ['value' => $value, 'warnings' => $warnings]; }
    catch (Throwable $e) { return ['value' => false, 'exception' => get_class($e) . ': ' . $e->getMessage(), 'warnings' => $warnings]; }
}
$info = ['host' => $_SERVER['HTTP_HOST'], 'php' => PHP_VERSION,
    'open_basedir' => ini_get('open_basedir'), 'sys_get_temp_dir' => sys_get_temp_dir(),
    'sys_temp_dir' => ini_get('sys_temp_dir'), 'upload_tmp_dir' => ini_get('upload_tmp_dir'),
    'session_save_path' => ini_get('session.save_path')];
$results = [];
if ($peerPaths) {
    foreach ($peerPaths as $label => $path) {
        $results[$label] = ['path' => $path,
            'read' => attempt(fn() => file_get_contents($path)),
            'append' => attempt(function() use ($path, $prefix) {
                $f = fopen($path, 'r+'); // No creation: the canary must already exist.
                if (!$f) return false;
                fseek($f, 0, SEEK_END); $n = fwrite($f, $prefix . '-PEER-APPEND'); fclose($f); return $n;
            })];
    }
} else {
    $dirs = ['shared_tmp' => '/tmp', 'shared_var_tmp' => '/var/tmp', 'shared_shm' => '/dev/shm',
        'shared_service_state' => '/var/lib/ephpm-web', 'shared_sites_parent' => '/srv/ephpm/sites',
        'own_container' => dirname(__DIR__), 'own_tmp' => sys_get_temp_dir(),
        'own_upload_tmp' => ini_get('upload_tmp_dir'), 'own_sessions' => ini_get('session.save_path')];
    foreach ($dirs as $label => $dir) {
        $path = rtrim($dir, '/') . '/' . $prefix . '-' . $label;
        $results[$label] = ['path' => $path, 'write' => attempt(function() use ($path, $prefix, $label) {
            $f = fopen($path, 'x');
            if (!$f) return false;
            $n = fwrite($f, $prefix . ':' . $label); fclose($f); return $n;
        })];
        if ($results[$label]['write']['value'] !== false) {
            $results[$label]['readback'] = attempt(fn() => file_get_contents($path));
        }
    }
    $results['tempnam_default'] = attempt(fn() => tempnam(sys_get_temp_dir(), $prefix . '-default-'));
    $results['tempnam_shared_argument'] = attempt(fn() => tempnam('/tmp', $prefix . '-shared-'));
    $results['tmpfile'] = attempt(function() {
        $f = tmpfile(); if (!$f) return false;
        $meta = stream_get_meta_data($f); $n = fwrite($f, 'benign-temp-control'); fclose($f);
        return ['path' => $meta['uri'], 'bytes_written' => $n, 'closed_auto_removed' => true];
    });
}
echo json_encode(['info' => $info, 'results' => $results], JSON_PRETTY_PRINT | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
