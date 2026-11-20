param(
    [string]$ZigPath = $env:ZIG_PATH
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cache = Join-Path $env:TEMP ('beats-cache-sec-webview-preprocessor-' + [guid]::NewGuid().ToString('N'))
$oldGlobalCache = $env:ZIG_GLOBAL_CACHE_DIR
try {
    if ((Get-PSDrive C).Free -lt 3GB) { throw 'Espacio insuficiente para preprocesar' }
    New-Item -ItemType Directory -Path $cache | Out-Null
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $cache 'global'
    $includes = @('-I', (Join-Path $root 'shell/host'), '-I', (Join-Path $root 'shell/host/include'), '-I', (Join-Path $root 'shell/host/sdk/build/native/include'))
    foreach ($source in @('main.cpp', 'webview_host.cpp')) {
        foreach ($configuration in @('Debug', 'Release')) {
            $arguments = @('c++', '-E', '-P', '-std=c++17', '-DUNICODE', '-D_UNICODE') + $includes
            if ($configuration -eq 'Release') { $arguments += '-DNDEBUG' }
            $arguments += Join-Path $root ('shell/host/' + $source)
            $output = Join-Path $cache ($source + '.' + $configuration + '.ii')
            $errors = Join-Path $cache ($source + '.' + $configuration + '.err')
            & $ZigPath @arguments 1> $output 2> $errors
            if ($LASTEXITCODE -ne 0) {
                Get-Content -LiteralPath $errors
                throw "Fallo del preprocesador: $source $configuration"
            }
            $code = Get-Content -Raw -LiteralPath $output
            foreach ($token in @('"DEVAGENTS_DEVTOOLS_PORT"', '"BEATS_DEVTOOLS_PORT"', '--remote-debugging-port=')) {
                $present = $code.Contains($token)
                if ($present -ne ($configuration -eq 'Debug')) {
                    throw "Rama CDP incorrecta: $source $configuration $token"
                }
            }
            # El arnés --test-bridge instancia el motor real y escribe en su catálogo:
            # sólo puede existir en Debug.
            if ($source -eq 'main.cpp') {
                $present = $code.Contains('"--test-bridge"')
                if ($present -ne ($configuration -eq 'Debug')) {
                    throw "Arnés --test-bridge incorrecto: $source $configuration"
                }
            }
            if ($configuration -eq 'Release' -and $source -eq 'webview_host.cpp' -and
                $code -notmatch 'SetEnvironmentVariableW\s*\(\s*L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"\s*,\s*nullptr\s*\)') {
                throw 'Release no elimina los argumentos de navegador heredados'
            }
            Write-Output "PASS preprocessor: $source $configuration (CDP env and flags; --test-bridge only in Debug)"
        }
    }
} finally {
    $env:ZIG_GLOBAL_CACHE_DIR = $oldGlobalCache
    if (Test-Path -LiteralPath $cache) {
        $resolved = (Resolve-Path -LiteralPath $cache).Path
        $tempRoot = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $resolved) -notlike 'beats-cache-sec-webview-preprocessor-*') {
            throw 'Ruta de limpieza inesperada'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
