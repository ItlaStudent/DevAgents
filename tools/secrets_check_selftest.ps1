#!/usr/bin/env pwsh
# Self-test del gate de secretos (T-F9-03).
# Inyecta una clave FALSA en cada ubicacion cubierta y verifica que el gate
# falla con exit 1; verifica ademas que un arbol limpio (solo placeholders de la
# allowlist) pasa con exit 0 y que un placeholder NO produce falso positivo.
#
# Cubre los cuatro huecos hallados en la auditoria dogfood w2:
#   (a) cobertura .md/.json/.ps1/.txt/.zig  -> casos MD/JSON/PS1/TXT/ZIG
#   (b) historial git FALLA (exit 1)        -> caso GIT-HISTORY
#   (c) skip de test NO es substring laxo    -> caso REAL-KEY-CON-SUBSTRING-TEST
#   (d) logs ampliados (.verifications)      -> caso LOG
#
# No commitea claves reales: opera en sandboxes temporales bajo $env:TEMP.
$ErrorActionPreference = "Stop"

$gate = Join-Path $PSScriptRoot "secrets_check.ps1"
if (-not (Test-Path -LiteralPath $gate)) { throw "No se encuentra el gate: $gate" }

# Clave FALSA con forma de clave real (>=15 alfanumericos tras 'sk-'), sin guiones
# (para no caer en la allowlist) y SIN ser un placeholder conocido.
$FAKE = 'sk-' + 'F4KE' + ('A1B2C3D4E5F6G7H8' * 2) + 'ZZ'
# Clave real que CONTIENE la subcadena "test" (debe ser detectada igualmente).
$FAKE_TEST = 'sk-test' + 'A1B2C3D4E5F6G7H8I9J0KEYREAL'

$pass = 0
$fail = 0

function New-Sandbox {
    $name = "sc-selftest-{0}-{1}" -f $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Invoke-Gate([string]$root, [switch]$NoGit) {
    if ($NoGit) {
        & pwsh -NoProfile -File $gate -Root $root -NoGitHistory | Out-Null
    } else {
        & pwsh -NoProfile -File $gate -Root $root | Out-Null
    }
    return $LASTEXITCODE
}

function Assert-Exit([string]$label, [int]$got, [int]$want) {
    if ($got -eq $want) {
        Write-Host "  PASS  $label (exit $got)" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL  $label (exit $got, esperado $want)" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "=== SECRETS CHECK SELF-TEST (T-F9-03) ===" -ForegroundColor Cyan
Write-Host ""

# ── Caso CLEAN: arbol con solo placeholders allowlistados -> exit 0 ──────────
$sb = New-Sandbox
try {
    Set-Content -LiteralPath (Join-Path $sb 'ok.zig') -Value 'const k = "sk-test123";' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sb 'ok.md')  -Value 'ejemplo: sk-priority-test' -Encoding UTF8
    Assert-Exit "CLEAN (solo placeholders allowlistados)" (Invoke-Gate $sb -NoGit) 0
} finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }

# ── Casos por extension: clave falsa en cada ubicacion -> exit 1 ─────────────
$locations = @(
    @{ Label = 'MD  (.md)';            File = 'evidence.md';            Body = "leaked key: $FAKE" },
    @{ Label = 'JSON (.json)';         File = 'config.json';            Body = "{ `"key`": `"$FAKE`" }" },
    @{ Label = 'PS1 (.ps1)';           File = 'script.ps1';             Body = "`$k = '$FAKE'" },
    @{ Label = 'TXT (.txt)';           File = 'notes.txt';              Body = "token=$FAKE" },
    @{ Label = 'ZIG (.zig)';           File = 'src.zig';                Body = "const k = `"$FAKE`";" },
    @{ Label = 'DOCS (docs/*.md)';     File = 'docs/audit.md';          Body = "evidencia: $FAKE" },
    @{ Label = 'LOG (.verifications)'; File = '.verifications/V-x.log';  Body = "output: $FAKE" }
)
foreach ($loc in $locations) {
    $sb = New-Sandbox
    try {
        $target = Join-Path $sb $loc.File
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Set-Content -LiteralPath $target -Value $loc.Body -Encoding UTF8
        Assert-Exit ("detecta clave en " + $loc.Label) (Invoke-Gate $sb -NoGit) 1
    } finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }
}

# ── Caso (c): clave REAL que contiene "test" NO debe ser allowlistada ────────
$sb = New-Sandbox
try {
    Set-Content -LiteralPath (Join-Path $sb 'leak.md') -Value "key: $FAKE_TEST" -Encoding UTF8
    Assert-Exit "clave real con substring 'test' SI se detecta (hardening c)" (Invoke-Gate $sb -NoGit) 1
} finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }

# ── Caso (b): clave en el HISTORIAL git (no en el arbol) -> exit 1 ───────────
$sb = New-Sandbox
try {
    & git -C $sb init -q 2>$null | Out-Null
    & git -C $sb config user.email "selftest@local" | Out-Null
    & git -C $sb config user.name  "selftest"       | Out-Null
    & git -C $sb config commit.gpgsign false        | Out-Null
    $leaked = Join-Path $sb 'leaked.zig'
    Set-Content -LiteralPath $leaked -Value "const k = `"$FAKE`";" -Encoding UTF8
    & git -C $sb add -A | Out-Null
    & git -C $sb commit -q -m "introduce key" | Out-Null
    # Lo eliminamos del arbol: queda SOLO en el historial.
    Remove-Item -LiteralPath $leaked -Force
    & git -C $sb add -A | Out-Null
    & git -C $sb commit -q -m "remove key from tree" | Out-Null
    Assert-Exit "historial git FALLA (hardening b)" (Invoke-Gate $sb) 1
} finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Self-test: $pass passed, $fail failed."
if ($fail -gt 0) {
    Write-Host "SELF-TEST FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "SELF-TEST PASS" -ForegroundColor Green
exit 0
