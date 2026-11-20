param(
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$Fixture,
    [string]$WebUi = (Join-Path $PSScriptRoot '../shell/webui/dist')
)
$ErrorActionPreference = 'Stop'
$Binary = (Resolve-Path -LiteralPath $Binary).Path
$WebUi = (Resolve-Path -LiteralPath $WebUi).Path
$Fixture = [IO.Path]::GetFullPath($Fixture)
$tempRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Temp')).TrimEnd('\') + '\'
if (-not $Fixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'La fixture debe estar dentro de LocalAppData/Temp'
}
if (Get-NetTCPConnection -LocalPort 9333 -State Listen -ErrorAction SilentlyContinue) {
    throw '9333 ya está ocupado: cerrar primero la cabina Debug propia'
}
$variables = @('BEATS_SECURITY_FIXTURE_DIR', 'BEATS_WEBVIEW_LOG_DIR', 'BEATS_WEBUI_DIR',
    'BEATS_DEVTOOLS_PORT', 'DEVAGENTS_DEVTOOLS_PORT', 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$process = $null
try {
    New-Item -ItemType Directory -Force -Path $Fixture, (Join-Path $Fixture 'logs') | Out-Null
    $env:BEATS_SECURITY_FIXTURE_DIR = $Fixture
    $env:BEATS_WEBVIEW_LOG_DIR = Join-Path $Fixture 'logs'
    $env:BEATS_WEBUI_DIR = $WebUi
    $env:BEATS_DEVTOOLS_PORT = '9333'
    $env:DEVAGENTS_DEVTOOLS_PORT = '9333'
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=9333'
    $log = Join-Path $Fixture 'logs/webview.log'
    if (Test-Path -LiteralPath $log) { Clear-Content -LiteralPath $log }
    $process = Start-Process -FilePath $Binary -WorkingDirectory $Fixture -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Fixture 'stdout.txt') `
        -RedirectStandardError (Join-Path $Fixture 'stderr.txt')
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $loaded = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { throw 'Release terminó durante arranque' }
        if (Test-Path -LiteralPath $log) {
            $text = [string](Get-Content -Raw -LiteralPath $log)
            if (([regex]::Matches($text, '\[NavCompleted\] IsSuccess=1 WebErrorStatus=0')).Count -ge 2) {
                $loaded = $true
                break
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $loaded) { throw 'No cargaron ambas WebViews release' }
    if (Get-NetTCPConnection -LocalPort 9333 -State Listen -ErrorAction SilentlyContinue) {
        throw 'Release expone CDP9333'
    }
    'PASS ReleaseFast: dos WebViews cargadas; tres variables de CDP definidas; sin listener9333'
    Get-Content -LiteralPath (Join-Path $Fixture 'stdout.txt')
    Get-Content -LiteralPath $log
} finally {
    if ($process -and -not $process.HasExited) {
        if ($process.Path -ne $Binary) { throw 'Proceso fuera del ejecutable propio' }
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(10000)) {
            Stop-Process -Id $process.Id
            $process.WaitForExit()
        }
    }
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
