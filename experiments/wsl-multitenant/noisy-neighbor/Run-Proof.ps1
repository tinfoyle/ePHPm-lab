[CmdletBinding()]
param(
    [ValidatePattern('^EPHPM-Lab[-A-Za-z0-9]*$')][string]$Name = 'EPHPM-Lab',
    [switch]$CollectOnly,
    [ValidateRange(1,3)][int]$Trials = 3,
    [ValidatePattern('^[0-9]{8}T[0-9]{6}Z$')][string]$RunId
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$cache = Join-Path $repo '.generated/wsl-multitenant'
New-Item -ItemType Directory -Force $cache | Out-Null
function Wsl-Process([string]$Arguments) {
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = 'wsl.exe'
    $p.StartInfo.Arguments = "-d $Name -u root -- $Arguments"
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true
    return $p
}
if (!$CollectOnly) {
    $payload = Join-Path $cache 'noisy-neighbor-payload.tar'
    & tar.exe -cf $payload --exclude=noisy-neighbor/results --exclude=__pycache__ -C (Split-Path $PSScriptRoot) noisy-neighbor
    if ($LASTEXITCODE -ne 0) { throw 'Payload archive failed' }
    $p = Wsl-Process 'tar -xf - -C /opt/ephpm-lab'
    $p.StartInfo.RedirectStandardInput = $true
    $p.Start() | Out-Null
    $stream = [IO.File]::OpenRead($payload)
    try { $stream.CopyTo($p.StandardInput.BaseStream) }
    finally { $stream.Dispose(); $p.StandardInput.Close() }
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw 'Guest transfer failed' }
    & wsl.exe -d $Name -u root -- bash /opt/ephpm-lab/noisy-neighbor/run.sh $Trials
    if ($LASTEXITCODE -ne 0) { throw 'Experiment failed; inspect guest results before retrying' }
}
if (!$RunId) {
    $runs = & wsl.exe -d $Name -u root -- ls -1 /var/lib/ephpm-lab/noisy-neighbor
    if ($LASTEXITCODE -ne 0) { throw 'Cannot list guest results' }
    $RunId = $runs | Where-Object { $_ -match '^[0-9]{8}T[0-9]{6}Z$' } | Sort-Object | Select-Object -Last 1
}
if (!$RunId) { throw 'No run available' }
& wsl.exe -d $Name -u root -- test -f "/var/lib/ephpm-lab/noisy-neighbor/$RunId/summary.json"
if ($LASTEXITCODE -ne 0) { throw 'Run is incomplete; raw files remain in guest' }
$results = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force $results | Out-Null
$archive = Join-Path $cache "$RunId-results.tar.gz"
$p = Wsl-Process "tar -czf - -C /var/lib/ephpm-lab/noisy-neighbor $RunId"
$p.StartInfo.RedirectStandardOutput = $true
$p.Start() | Out-Null
$stream = [IO.File]::Create($archive)
try { $p.StandardOutput.BaseStream.CopyTo($stream) }
finally { $stream.Dispose() }
$p.WaitForExit()
if ($p.ExitCode -ne 0) { throw 'Results export failed' }
& tar.exe -xzf $archive -C $results
if ($LASTEXITCODE -ne 0) { throw 'Results extraction failed' }
Write-Host "Results: $results/$RunId"
Write-Host "Generate report: python $PSScriptRoot/report.py $results/$RunId"
