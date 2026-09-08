# Shared temporary-path test

Both tenants were tested through HTTP, with unique disposable canaries and operator-side integrity checks.

| Location / API | Alice | Bob |
|---|---|---|
| shared_tmp | Denied / unavailable | Denied / unavailable |
| shared_var_tmp | Denied / unavailable | Denied / unavailable |
| shared_shm | Denied / unavailable | Denied / unavailable |
| shared_service_state | Denied / unavailable | Denied / unavailable |
| shared_sites_parent | Denied / unavailable | Denied / unavailable |
| own_container | Writable | Writable |
| own_tmp | Writable | Writable |
| own_upload_tmp | Writable | Writable |
| own_sessions | Writable | Writable |
| tempnam_default | Succeeded | Succeeded |
| tempnam_shared_argument | Denied / unavailable | Denied / unavailable |
| tmpfile | Succeeded | Succeeded |

## Actual PHP temp configuration

### alice.lab.test

```json
{
  "host": "alice.lab.test",
  "php": "8.4.23",
  "open_basedir": "/srv/ephpm/sites/alice.lab.test:/tmp/ephpm-vhosts/alice.lab.test-f608fc08338292b9",
  "sys_get_temp_dir": "/tmp/ephpm-vhosts/alice.lab.test-f608fc08338292b9/tmp",
  "sys_temp_dir": "/tmp/ephpm-vhosts/alice.lab.test-f608fc08338292b9/tmp",
  "upload_tmp_dir": "/tmp/ephpm-vhosts/alice.lab.test-f608fc08338292b9/tmp",
  "session_save_path": "/tmp/ephpm-vhosts/alice.lab.test-f608fc08338292b9/sessions"
}
```

### bob.lab.test

```json
{
  "host": "bob.lab.test",
  "php": "8.4.23",
  "open_basedir": "/srv/ephpm/sites/bob.lab.test:/tmp/ephpm-vhosts/bob.lab.test-9c7fab4e84dc9443",
  "sys_get_temp_dir": "/tmp/ephpm-vhosts/bob.lab.test-9c7fab4e84dc9443/tmp",
  "sys_temp_dir": "/tmp/ephpm-vhosts/bob.lab.test-9c7fab4e84dc9443/tmp",
  "upload_tmp_dir": "/tmp/ephpm-vhosts/bob.lab.test-9c7fab4e84dc9443/tmp",
  "session_save_path": "/tmp/ephpm-vhosts/bob.lab.test-9c7fab4e84dc9443/sessions"
}
```

## Cross-tenant and shared canary checks

| Requesting tenant | Target | Read | Append |
|---|---|---|---|
| alice.lab.test | os_tmp | Denied | Denied |
| alice.lab.test | os_var_tmp | Denied | Denied |
| alice.lab.test | peer_own_container | Denied | Denied |
| alice.lab.test | peer_own_tmp | Denied | Denied |
| alice.lab.test | peer_own_upload_tmp | Denied | Denied |
| alice.lab.test | peer_own_sessions | Denied | Denied |
| alice.lab.test | peer_tempnam_default | Denied | Denied |
| bob.lab.test | os_tmp | Denied | Denied |
| bob.lab.test | os_var_tmp | Denied | Denied |
| bob.lab.test | peer_own_container | Denied | Denied |
| bob.lab.test | peer_own_tmp | Denied | Denied |
| bob.lab.test | peer_own_upload_tmp | Denied | Denied |
| bob.lab.test | peer_own_sessions | Denied | Denied |
| bob.lab.test | peer_tempnam_default | Denied | Denied |

## Controls and limits

The operator created controls in the service mount namespace as the ephpm-web Unix UID. This distinguishes OS writability from the PHP open_basedir restriction; it does not demonstrate tenant code execution outside PHP.

```json
{
  "tmp": {
    "path": "/tmp/probe-bcb871cc30abeb5f-os-tmp",
    "created": true
  },
  "var_tmp": {
    "path": "/var/tmp/probe-bcb871cc30abeb5f-os-var_tmp",
    "created": true
  }
}
```

All existing canaries unchanged after cross-access: True. All tracked files/endpoints removed: True.

This is a direct PHP filesystem/API check in the current configuration. It does not test symlink races, native-extension escapes, uploads, session API isolation, or preview build execution. systemd PrivateTmp isolates the service from the host; per-tenant separation inside that service depends on ePHPm/PHP controls.

Full paths, return values, PHP warnings, hashes, and cleanup outcomes are preserved in evidence.json. No actual secrets or pre-existing files were modified.
