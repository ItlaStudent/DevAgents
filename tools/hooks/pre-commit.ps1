#!/usr/bin/env pwsh
# Pre-commit hook: zig fmt + clang-format + build verde
# Se instala desde: tools/install-hooks.ps1
#
# FIX cambios clave:
# - Usa --check / --dry-run --Werror para BLOQUEAR commits con archivos mal formateados.
# - Funciona en PowerShell 5.1 y 7.x (usa exit codes, no excepciones).
# - Compatible con pwsh (shebang) y PowerShell 5.1 (invocación directa).
#
# TODO (cuando extensions/ exista): añadir `prettier --check extensions/**` antes del build test.
#   La extensión VS Code (TypeScript) usa Prettier como formateador obligatorio (CODING-STANDARDS §6).

$ErrorActionPreference = "Stop"

# Resolver zig.exe: primero env ZIG_PATH, luego PATH, luego rutas conocidas
$zigPath = $env:ZIG_PATH
if (-not $zigPath) {
    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    $zigPath = if ($zigCmd) { $zigCmd.Source } else { $null }
}
if (-not $zigPath) {
    $candidates = @(
        "C:\Program Files\Zig\zig.exe",
        "C:\zig\zig.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $zigPath = $c; break }
    }
}
if (-not $zigPath) {
    Write-Host "ERROR: zig.exe no encontrado. Agregalo al PATH o instala Zig." -ForegroundColor Red
    exit 1
}

# Resolver clang-format.exe: primero PATH, luego rutas conocidas
$clangCmd = Get-Command clang-format -ErrorAction SilentlyContinue
$clangFormatPath = if ($clangCmd) { $clangCmd.Source } else { $null }
if (-not $clangFormatPath) {
    $candidates = @(
        "C:\Program Files\LLVM\bin\clang-format.exe",
        "C:\Program Files (x86)\LLVM\bin\clang-format.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $clangFormatPath = $c; break }
    }
}

Write-Host "Running pre-commit checks..."

# --- 0. Secrets check ---
Write-Host "Checking for leaked secrets..."
$repoRoot = git rev-parse --show-toplevel
$secretsScript = Join-Path $repoRoot "tools\secrets_check.ps1"
if (Test-Path $secretsScript) {
    & pwsh -NoProfile -File $secretsScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: secrets_check detected leaked API key or secret!" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "WARNING: tools/secrets_check.ps1 no encontrado" -ForegroundColor Yellow
}


# --- 1. Zig fmt CHECK (modo dry-run / check, no in-place) ---
Write-Host "Checking Zig formatting..."
$fmtTargets = @('build.zig', 'core', 'providers', 'tests') | Where-Object { (Test-Path $_) -and (Get-ChildItem -Path $_ -Recurse -Filter *.zig -ErrorAction SilentlyContinue) }
if ($fmtTargets) {
    $zigFmtOutput = & $zigPath fmt --check $fmtTargets 2>&1
    $zigFmtExit = $LASTEXITCODE
    if ($zigFmtExit -ne 0) {
        Write-Host "ERROR: zig fmt --check found unformatted files. Run '$($zigPath) fmt ...' to fix." -ForegroundColor Red
        Write-Host "Output:" -ForegroundColor Yellow
        $zigFmtOutput | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
} else {
    Write-Host "  (Sin archivos .zig aún para formatear)" -ForegroundColor DarkGray
}

# --- 2. Clang-format CHECK (modo dry-run, no in-place) ---
if ($clangFormatPath) {
    Write-Host "Checking C/C++ formatting..."
 # INCIDENTE §2.8 (la documentación interna §2.8): Archivos *.def de MSVC/lld-link son orientados a líneas con comentarios ';'.
    # Exclusión explícita obligatoria: NUNCA deben formatearse con clang-format/reflow porque destruye las directivas LIBRARY/EXPORTS.
    $cFiles = Get-ChildItem -Path . -Include *.c,*.cpp,*.h,*.hpp -Recurse | Where-Object { $_.FullName -notmatch "\\.zig-cache|zig-cache|[\\/]core[\\/](src[\\/])?db|[\\/]build[\\/]|CMakeFiles|devagents-workspace|[\\/]almacen[\\/]|[\\/]toolchain[\\/]|[\\/]tools[\\/]vendor[\\/]|\.def$" }
    foreach ($file in $cFiles) {
        & $clangFormatPath --dry-run --Werror --style=file "$($file.FullName)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: clang-format --dry-run --Werror failed on $($file.FullName)" -ForegroundColor Red
            Write-Host "Run '$($clangFormatPath) -i $($file.FullName) --style=file' to fix." -ForegroundColor Yellow
            exit 1
        }
    }
} else {
    Write-Host "WARNING: clang-format no encontrado, saltando formato C/C++" -ForegroundColor Yellow
}

# --- 3. Build test ---
if (Test-Path "build.zig") {
    Write-Host "Running build test..."
    $env:PATH = $env:PATH + ";$(Split-Path $zigPath -Parent)"
    if ($clangFormatPath) {
        $env:PATH = $env:PATH + ";$(Split-Path $clangFormatPath -Parent)"
    }
 $hookCache = if ($env:DEVAGENTS_HOOK_CACHE) { $env:DEVAGENTS_HOOK_CACHE } else { Join-Path $env:LOCALAPPDATA 'Temp\beats-cache-hook' }
    & $zigPath build runtime-binaries -j1 --cache-dir $hookCache --summary all
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: zig build test failed" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  (build.zig no presente aún, saltando build test)" -ForegroundColor DarkGray
}


Write-Host "Pre-commit checks passed." -ForegroundColor Green
exit 0
