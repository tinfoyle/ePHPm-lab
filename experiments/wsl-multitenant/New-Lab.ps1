[CmdletBinding()]
param(
    [ValidatePattern('^EPHPM-Lab[-A-Za-z0-9]*$')][string]$Name = 'EPHPM-Lab',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'WSL'),
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$pins = Get-Content (Join-Path $PSScriptRoot 'versions.json') -Raw | ConvertFrom-Json
$cache = Join-Path $repo '.generated/wsl-multitenant'
New-Item -ItemType Directory -Force $cache | Out-Null
function Run-WSL([string[]]$Arguments) {
    & wsl.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "WSL failed: $Arguments (exit $LASTEXITCODE)" }
}
$names = ((& wsl.exe --list --quiet) -replace "`0", '') | ForEach-Object { $_.Trim() }
if ($Name -in $names) {
    if (!$Resume) { throw "$Name already exists. Use -Resume only for this experiment's instance." }
    Run-WSL @('-d', $Name, '-u', 'root', '--', 'grep', '-qx', 'ephpm-wsl-multitenant-v1', '/etc/ephpm-lab-instance')
} else {
    $archive = Join-Path $cache 'ubuntu-base-24.04.4-amd64.tar.gz'
    if (!(Test-Path -LiteralPath $archive)) {
        & curl.exe --fail --location --retry 3 --output $archive $pins.rootfsUrl
        if ($LASTEXITCODE -ne 0) { throw 'Ubuntu rootfs download failed' }
    }
    if ((Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant() -ne $pins.rootfsSha256) { throw 'Rootfs checksum mismatch' }
    $destination = Join-Path $InstallRoot $Name
    if (Test-Path -LiteralPath $destination) { throw "Refusing existing install directory: $destination" }
    New-Item -ItemType Directory -Force $destination | Out-Null
    Run-WSL @('--import', $Name, $destination, $archive, '--version', '2')
    Run-WSL @('-d', $Name, '-u', 'root', '--', 'sh', '-c', 'echo ephpm-wsl-multitenant-v1 > /etc/ephpm-lab-instance')
}
$stagingKeeper = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', $Name, '-u', 'root', '--', 'sleep', 'infinity') -WindowStyle Hidden -PassThru
Run-WSL @('-d', $Name, '-u', 'root', '--', 'mkdir', '-p', '/opt/ephpm-lab/assets')
$guest = Join-Path $cache ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force "$guest/assets" | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $guest -Recurse -Force
# Explicit allowlist: never copy kubeconfigs, .env files, credentials or the whole checkout.
Copy-Item -LiteralPath (Join-Path $repo 'k8s/php-benchmark.yaml') -Destination "$guest\assets\php-benchmark.yaml" -Force
New-Item -ItemType Directory -Force "$guest\assets\wordpress-v5\scripts", "$guest\assets\wordpress-v5\k6" | Out-Null
Copy-Item -Path (Join-Path $repo 'wordpress-v5/scripts/*.sh'), (Join-Path $repo 'wordpress-v5/scripts/*.php') -Destination "$guest\assets\wordpress-v5\scripts" -Force
Copy-Item -Path (Join-Path $repo 'wordpress-v5/k6/*.js') -Destination "$guest\assets\wordpress-v5\k6" -Force
Copy-Item -LiteralPath (Join-Path $repo 'wordpress-v5/README.md') -Destination "$guest\assets\wordpress-v5" -Force
# Binary stdin works even with automount/interop disabled and no WSL file share.
$payload = Join-Path $cache "$Name-payload.tar"
& tar.exe -cf $payload -C $guest .
if ($LASTEXITCODE -ne 0) { throw 'Payload archive creation failed' }
$transfer = New-Object System.Diagnostics.Process
$transfer.StartInfo.FileName = 'wsl.exe'
$transfer.StartInfo.Arguments = "-d $Name -u root -- tar -xf - -C /opt/ephpm-lab"
$transfer.StartInfo.UseShellExecute = $false
$transfer.StartInfo.CreateNoWindow = $true
$transfer.StartInfo.RedirectStandardInput = $true
$transfer.StartInfo.RedirectStandardError = $true
$transfer.Start() | Out-Null
$transferErrors = $transfer.StandardError.ReadToEndAsync()
$payloadStream = [IO.File]::OpenRead($payload)
try { $payloadStream.CopyTo($transfer.StandardInput.BaseStream) }
finally { $payloadStream.Dispose(); $transfer.StandardInput.Close() }
$transfer.WaitForExit()
if ($transfer.ExitCode -ne 0) { throw "Guest payload extraction failed: $($transferErrors.Result)" }
Run-WSL @('-d', $Name, '-u', 'root', '--', 'bash', '/opt/ephpm-lab/bootstrap.sh')
Run-WSL @('--terminate', $Name)
# systemd services alone do not keep WSL alive. A hidden, idle client does.
# Terminating this distro also ends this client; no global WSL settings change.
$keeper = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', $Name, '-u', 'root', '--', 'sleep', 'infinity') -WindowStyle Hidden -PassThru
$keeper.Id | Set-Content (Join-Path $cache "$Name-keepalive.pid")
Run-WSL @('-d', $Name, '-u', 'root', '--', 'bash', '/opt/ephpm-lab/provision.sh')
Write-Host "Ready: wsl -d $Name -u root -- /usr/local/sbin/ephpm-lab status"
Write-Host 'Setup only. Security probing and load testing have not run.'
