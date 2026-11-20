#!/usr/bin/env pwsh
# Secrets check (T-F9-03): detecta claves filtradas en artefactos, fuentes,
# documentacion, configuracion y en el historial git. Falla con exit 1 ante
# cualquier hallazgo NO presente en la allowlist de placeholders conocidos.
#
# Endurecimiento (auditoria dogfood w2 2026-06-17, docs/audits/dogfood-audit-w2-2026-06-17.md):
#   (a) cobertura ampliada: ya no solo *.zig. Tambien .md/.json/.ps1/.txt y docs/.
#   (b) el hallazgo en el historial git ahora FALLA (exit 1), no solo advierte.
#       Ademas se corrige un bug latente: el `git log -S "regex"` previo buscaba
#       el patron como CADENA LITERAL (sin --pickaxe-regex) => nunca acertaba.
#       Ahora usa `-G <regex>` (busqueda por regex sobre el diff).
#   (c) el skip de claves de test ya NO es `-match "test"` (substring laxo que
#       dejaba pasar una clave REAL que contuviera "test"). Ahora es una allowlist
#       de valores EXACTOS + patrones ANCLADOS (^...$) de placeholders conocidos.
#   (d) cobertura de logs ampliada: todo .verifications/*.log y *.txt, no solo V-*.log.
#
# NO toca *.db (claves productivas via DPAPI en catalog.db).
#
# Uso:
#   pwsh -File tools/secrets_check.ps1                 # raiz = "."
#   pwsh -File tools/secrets_check.ps1 -Root <dir>     # para self-test en sandbox
#   pwsh -File tools/secrets_check.ps1 -NoGitHistory   # omite el chequeo de historial
#   pwsh -File tools/secrets_check.ps1 -FullHistory    # historial con TODOS los patrones
#     (auditoría de salida pública, ~6 min; el hook de commit mira el historial
#     solo con los dos patrones de siempre porque el resto genera 330 MB de diff)
param(
    [string]$Root = ".",
    [switch]$NoGitHistory,
    [switch]$FullHistory
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $Root).Path
$failed = $false
$matched = 0
$checked = 0

# ── Patrones de clave ──────────────────────────────────────────────────────
# "Strong": forma de clave inequivoca; se aplican a TODO (fuentes, docs, logs, git).
$strongPatterns = @(
    '\bsk-[a-zA-Z0-9]{15,}',
    '\bnvapi-[a-zA-Z0-9]{15,}',
 # 10-nov: formas que el gate no veía y que el escaneo del
    # historial completo sí encontró (OpenRouter y Cerebras), más las comunes.
    '\bsk-or-v1-[a-f0-9]{40,}',
    '\bcsk-[a-z0-9]{40,}',
    '\bsk-ant-[A-Za-z0-9_\-]{20,}',
    '\bAIza[0-9A-Za-z_\-]{35}',
    '\bgh[pousr]_[A-Za-z0-9]{36,}',
    '\bgithub_pat_[A-Za-z0-9_]{60,}',
    '\bglpat-[A-Za-z0-9_\-]{20,}',
    '\bgsk_[A-Za-z0-9]{40,}',
    '\bhf_[A-Za-z0-9]{30,}',
    '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
)
# Claves reales que ya están en el HISTORIAL (commits del 30-jul en
# tests/live/ola2-*.py y en la allowlist de este mismo archivo). Se identifican
# por su SHA-256, nunca por el valor. En el historial avisan sin fallar: la
# solución es rotarlas y publicar con historial nuevo (la documentación interna, lista de
# salida A3). En el árbol de trabajo NO se perdonan: si reaparecen, falla.
$historyKnownSha256 = @(
    '7ded07bc6d144d35875f6c13d34abaf108c4ea8b627843d514c0ccdee01fac6c', # OpenRouter
    'a47f5da30b28d684c47724b1f758243cbcaf2070037455616844ad9c649a842b', # NVIDIA
    '689840e800d3f1d93248bea23b16431c5e4e58e45af1a322c94f5d14a1c970ef'  # Cerebras
)
function Get-Sha256Hex([string]$value) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
    return ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}
$historyKnown = 0
# "Context": asignacion/cabecera con valor; se aplican a artefactos, fuentes y config.
$contextPatterns = @(
    '\bBearer\s+[a-zA-Z0-9\-_\.]{15,}',
    '\bAuthorization:\s*[a-zA-Z0-9\-_\.]{15,}',
    '\bapi[_-]?key\s*[:=]\s*["''][^"'']+["'']',
    '\bSECRET\s*[:=]\s*["''][^"'']+["'']'
)
$allPatterns = $strongPatterns + $contextPatterns

# ── Allowlist de placeholders conocidos (reemplaza el skip por substring laxo) ──
# Un hallazgo SOLO se ignora si su valor COMPLETO coincide exacto o casa con un
# patron ANCLADO de placeholder. Una clave real que contenga "test" NO se ignora.
$allowlistExact = @(
    # Literal fixtures used only by loopback/mock transport tests. Match the
    # entire context-regex result; real credentials remain rejected.
    'api_key = "fake-native-key"', 'api_key = "fake-key"', 'api_key = "fake"',
    'sk-test', 'sk-test123', 'sk-priority-test',
    'sk-opencode', 'sk-dummy', 'sk-placeholder', 'sk-example',
    'nvapi-test', 'nvapi-dummy', 'nvapi-placeholder', 'nvapi-example',
    # Relleno de la prueba de redacción de URL de Gemini (gemini.zig).
    'AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ1234567'
 # 10-nov: aquí había una clave NVIDIA real como «permitida»; se quitó.
)
$allowlistPatterns = @(
    '^sk-test[0-9]*$',
    '^sk-priority-test$',
    '^sk-(dummy|placeholder|example)[0-9]*$',
    '^nvapi-(test|dummy|placeholder|example)[0-9]*$'
)

function Test-Allowlisted([string]$value) {
    $v = $value.Trim()
    foreach ($a in $allowlistExact) {
        if ([string]::Equals($v, $a, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($p in $allowlistPatterns) {
        if ($v -match $p) { return $true }
    }
    return $false
}

function Add-Leak([string]$where, [string]$pattern, [string]$value) {
    $script:matched++
    $script:failed = $true
    $shown = $value.Substring(0, [Math]::Min(80, $value.Length))
    Write-Host "  LEAK in ${where}: pattern '$pattern'" -ForegroundColor Red
    Write-Host "    matched: $shown" -ForegroundColor Red
}

# Directorios a excluir del barrido (gitignored / ruido / binarios).
$excludeDirRegex = '[\\/](\.git|\.zig-cache|zig-cache|zig-out|dist|node_modules|\.vscode|\.idea|temporal|devagents-workspace|qa-results|almacen)[\\/]|[\\/]ide[\\/]build[\\/]'
# Ficheros a excluir (los propios gates contienen los patrones como literales regex).
$excludeFiles = @('secrets_check.ps1', 'secrets_check_selftest.ps1')

Write-Host "=== SECRETS CHECK (T-F9-03) ===" -ForegroundColor Cyan
Write-Host "Root: $Root"
Write-Host ""

function Scan-File([System.IO.FileInfo]$file, [string[]]$patterns) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return }
    $script:checked++
    $rel = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
    # 10-nov: una sola pasada con la alternancia compilada; solo si hay
    # coincidencia se busca qué patrón fue (para el mensaje).
    $combined = Get-CombinedRegex $patterns
    foreach ($m in $combined.Matches($content)) {
        if (Test-Allowlisted $m.Value) { continue }
        $which = ($patterns | Where-Object { $m.Value -match $_ } | Select-Object -First 1)
        Add-Leak $rel $which $m.Value
    }
}

$script:combinedCache = @{}
function Get-CombinedRegex([string[]]$patterns) {
    $key = $patterns -join "`n"
    if (-not $script:combinedCache.ContainsKey($key)) {
        $script:combinedCache[$key] = [regex]::new((($patterns | ForEach-Object { "(?:$_)" }) -join '|'), 'Compiled')
    }
    return $script:combinedCache[$key]
}

# ── 1) Artefactos de verificacion (.verifications/*.log + *.txt) ────────────
Write-Host "Checking verification artifacts (.verifications)..."
$verDir = Join-Path $Root ".verifications"
if (Test-Path -LiteralPath $verDir) {
    Get-ChildItem -Path $verDir -Recurse -File -Include '*.log', '*.txt' -ErrorAction SilentlyContinue |
        ForEach-Object { Scan-File $_ $allPatterns }
}

# ── 2) Fuentes, documentacion y configuracion ──────────────────────────────
# Ampliado (a): ya no solo *.zig; tambien .md/.json/.ps1/.txt y docs/.
Write-Host "Checking sources, docs and config (.zig/.md/.json/.ps1/.txt)..."
$includeExt = @('*.zig', '*.md', '*.json', '*.ps1', '*.txt')
Get-ChildItem -Path $Root -Recurse -File -Include $includeExt -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notmatch $excludeDirRegex -and
        $_.Extension -ne '.db' -and
        $excludeFiles -notcontains $_.Name
    } |
    ForEach-Object { Scan-File $_ $allPatterns }

# ── 3) Historial git ───────────────────────────────────────────────────────
# Endurecimiento (b): un hallazgo en el historial FALLA (exit 1), no solo advierte.
if (-not $NoGitHistory) {
    Write-Host "Checking git history..."
    $isRepo = (& git -C $Root rev-parse --is-inside-work-tree 2>$null)
    if ($LASTEXITCODE -eq 0 -and $isRepo -match 'true') {
        # -G busca el regex sobre el diff (a diferencia de -S, que sin
        # --pickaxe-regex trataba el patron como cadena literal => bug latente).
        # 10-nov: una sola pasada con todos los patrones alternados; con doce
        # patrones, una pasada por patrón hacía el hook de commit eterno.
        $historyPatterns = if ($FullHistory) { $strongPatterns } else { $strongPatterns[0..1] }
        $histRegex = ($historyPatterns | ForEach-Object { "($_)" }) -join '|'
        # Recupera los valores anadidos que casan, para poder allowlistar; los
        # commits salen de la misma pasada.
        $diff = & git -C $Root log --all -p --format='commit %h %s' -G $histRegex 2>$null | Out-String
        $commits = [regex]::Matches($diff, '(?m)^commit ([0-9a-f]{7,}.*)$') | ForEach-Object { $_.Groups[1].Value }
        foreach ($pattern in $historyPatterns) {
            foreach ($m in [regex]::Matches($diff, $pattern)) {
                if (Test-Allowlisted $m.Value) { continue }
                if ($historyKnownSha256 -contains (Get-Sha256Hex $m.Value)) { $script:historyKnown++; continue }
                $commitList = ($commits | Select-Object -First 5) -join '; '
                Add-Leak "git-history ($commitList)" $pattern $m.Value
            }
        }
    } else {
        Write-Host "  (no es un repo git; se omite el chequeo de historial)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Files checked: $checked"
Write-Host "Leaks found:   $matched"
if ($historyKnown -gt 0) {
    Write-Host "AVISO: $historyKnown aparicion(es) de claves reales conocidas en el historial (por huella SHA-256)." -ForegroundColor Yellow
 Write-Host " Rotarlas en su proveedor y publicar con historial nuevo (la documentación interna, A3)." -ForegroundColor Yellow
}
if ($failed) {
    Write-Host "FAIL: secrets detected (sources, docs, artifacts or git history)!" -ForegroundColor Red
    exit 1
}
Write-Host "PASS: no secrets found." -ForegroundColor Green
exit 0
