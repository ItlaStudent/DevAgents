#!/usr/bin/env pwsh
# Script de instalacion de hooks de Git
# Uso: .\tools\install-hooks.ps1

$ErrorActionPreference = "Stop"
$repoRoot = git rev-parse --show-toplevel
# En un worktree `.git` es un archivo: los hooks viven en el directorio comun.
$hookDir = Join-Path (git rev-parse --path-format=absolute --git-common-dir) "hooks"
$sourceDir = Join-Path $repoRoot "tools\hooks"

if (-not (Test-Path $hookDir)) {
    Write-Host "ERROR: No se encontro .git/hooks. ¿Estas en un repo git?" -ForegroundColor Red
    exit 1
}

Write-Host "Instalando hooks desde $sourceDir a $hookDir..."

# Instalar pre-commit.ps1
$src = Join-Path $sourceDir "pre-commit.ps1"
$dst = Join-Path $hookDir "pre-commit.ps1"
if (Test-Path $src) {
    Copy-Item $src $dst -Force
    Write-Host "  Instalado: pre-commit.ps1"
} else {
    Write-Host "  No encontrado: pre-commit.ps1" -ForegroundColor Yellow
}

# Instalar wrapper shell (para Git-Bash / WSL / compatibilidad)
$srcSh = Join-Path $sourceDir "pre-commit"
$dstSh = Join-Path $hookDir "pre-commit"
if (Test-Path $srcSh) {
    Copy-Item $srcSh $dstSh -Force
    Write-Host "  Instalado: pre-commit"
} else {
    Write-Host "  No encontrado: pre-commit (shell wrapper)" -ForegroundColor Yellow
}

Write-Host "Hooks instalados correctamente." -ForegroundColor Green
exit 0
