# ===============================================================================
# INSTALLER & DIFFERENTIAL AUTO-UPDATER PACKAGER - DEVAGENTS RELEASE V1.0 (T-F9-04)
# ===============================================================================

param(
    [string]$beatsDir = "",
    [string]$SigningCertThumbprint = "",
    # Carpeta bin de `zig build runtime-binaries` (la de --prefix). Por defecto
    # <repo>\zig-out\bin.
    [string]$BinDir = "",
    # Sin instalador: solo el .zip portable (p. ej. si no hay Inno Setup).
    [switch]$ZipOnly
)

# P1-7 (R2 D2): editor, URL y AppId del producto. La version NO va aqui: se lee
# de core/src/root.zig (VERSION), la fuente unica que usa build.zig.
$AppPublisher = "Ad Astra"
$AppURL = "https://github.com/ItlaStudent/DevAgents"
# AppId nuevo sin «DevAgents» (11-nov). No cambiarlo entre versiones: es lo que
# permite actualizar una instalacion encima de la anterior.
$AppId = "AD4FA4B8-8D39-44D0-938A-FA038C633C32"

$ErrorActionPreference = "Continue"

if (-not $beatsDir) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $beatsDir = (Get-Item (Join-Path $scriptDir "..")).FullName
}
Set-Location $beatsDir

$rootZig = Join-Path $beatsDir "core\src\root.zig"
$versionMatch = Select-String -Path $rootZig -Pattern 'pub const VERSION = "([0-9]+\.[0-9]+\.[0-9]+)"' | Select-Object -First 1
if (-not $versionMatch) {
    Write-Host "FAIL: no se encontro 'pub const VERSION = \"x.y.z\"' en $rootZig" -ForegroundColor Red
    exit 1
}
$AppVersion = $versionMatch.Matches[0].Groups[1].Value

Write-Host "Generando paquete de instalacion v$AppVersion..."

$binDir = if ($BinDir) { (Get-Item $BinDir).FullName } else { Join-Path $beatsDir "zig-out\bin" }

# P1-7 (R2 D1): licencias y avisos que viajan con el instalador y con el .zip.
$licenseFiles = [ordered]@{
    "LICENSE.txt"                = Join-Path $beatsDir "LICENSE"
    "NOTICE.txt"                 = Join-Path $beatsDir "NOTICE"
    "TRADEMARKS.md"              = Join-Path $beatsDir "TRADEMARKS.md"
    "WebView2-SDK-LICENSE.txt"   = Join-Path $beatsDir "shell\host\sdk\LICENSE.txt"
    "WebView2-SDK-NOTICE.txt"    = Join-Path $beatsDir "shell\host\sdk\NOTICE.txt"
    "ZIG-STDLIB-LICENSE.txt"     = Join-Path $beatsDir "tools\ZIG-STDLIB-LICENSE.txt"
}
$missingLicenses = @($licenseFiles.Values | Where-Object { -not (Test-Path $_) })
if ($missingLicenses.Count -gt 0) {
    Write-Host "FAIL: faltan archivos de licencia: $($missingLicenses -join ', ')" -ForegroundColor Red
    exit 1
}
$distDir = Join-Path $beatsDir "dist"
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Force -Path $distDir | Out-Null }

# 1. Comprobar binarios distribuidos — la lista se mide contra el .iss y contra
#    lo que la app carga en runtime: devagents-engine.exe (lo lanza el host por
#    CreateProcessW), devagents.ico (LoadImageW desde el dir del exe) y
#    WebView2Loader.dll. Sin ellos el instalador producía una app que no arranca.
$required = @(
    "devagents-host.exe",
    "devagents-engine.exe",
    "devagents-core.exe",
    # T7: la CLI con su nombre de producto (mismo binario que devagents-core).
    "devagents.exe",
    "devagents-mcp.exe",
    "devagents_core.dll",
    "key-admin.exe",
    "devagents.ico",
    "WebView2Loader.dll"
)

$missing = @()
foreach ($r in $required) {
    $p = Join-Path $binDir $r
    if (-not (Test-Path $p)) { $missing += $r }
}

if ($missing.Count -gt 0) {
    Write-Host "FAIL: Faltan binarios requeridos en zig-out/bin: $($missing -join ', ')" -ForegroundColor Red
    exit 1
}

# P2-2/R3-1: el host que se empaqueta debe ser el ReleaseSafe de
# distribucion. El marcador devagents-host.distribution lo instala SOLO el
# paso de distribucion (runtime-binaries / shell-distribution-only) junto al
# .exe, con el modo real y -DNDEBUG certificados por build.zig. Un `zig build`
# a secas instala el host de desarrollo en zig-out/bin (necesario para el CDP
# de la cabina) y no instala el marcador: sin el, el paquete no se genera.
# La procedencia se certifica por el CONTENIDO, sin fechas: al instalar, Zig
# conserva el mtime del archivo de la caché, y el marcador, de contenido
# constante, guarda el de su primera generacion; por eso la antiguedad
# rechazaba lo legitimo y dejaba pasar un host de desarrollo cacheado antes
# que el marcador (R3-1, medido). Ademas del marcador, se buscan
# en los BYTES del.exe instalado la cadena BEATS_DEVTOOLS_PORT: solo se
# compila sin NDEBUG (CDP de desarrollo), su presencia denuncia un host de
# desarrollo. La busqueda decodifica los bytes 1:1 con ISO-8859-1 (codigo
# 28591; cada byte es exactamente un codigo U+0000..U+00FF, valido en
# PowerShell 5.1 y 7) y hace Contains; NO findstr ni
# Select-String, que mienten en binarios.
$hostPath = Join-Path $binDir "devagents-host.exe"
$markerPath = Join-Path $binDir "devagents-host.distribution"
if (-not (Test-Path $markerPath)) {
    Write-Host "FAIL: falta zig-out/bin/devagents-host.distribution; el host no es el de distribucion. Ejecuta 'zig build runtime-binaries' (no empaquetes tras un 'zig build' o 'shell-host-only' a secas)." -ForegroundColor Red
    exit 1
}
$markerText = Get-Content -Path $markerPath -Raw
if ($markerText -notmatch 'DA_DISTRIBUTION_RELEASE_SAFE\s+1' -or $markerText -notmatch 'DA_DISTRIBUTION_NDEBUG\s+1') {
    Write-Host "FAIL: el marcador de distribucion no certifica ReleaseSafe+NDEBUG." -ForegroundColor Red
    exit 1
}
if ($markerText -notmatch 'DA_DISTRIBUTION_ENGINE_OPTIMIZED\s+1') {
    Write-Host "FAIL: el motor, la CLI, el MCP o la DLL estan en Debug (E-368). Compila con 'zig build runtime-binaries -Doptimize=ReleaseSafe'." -ForegroundColor Red
    exit 1
}
$hostBytesLatin1 = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($hostPath))
if ($hostBytesLatin1.Contains("BEATS_DEVTOOLS_PORT")) {
    Write-Host "FAIL: zig-out/bin/devagents-host.exe contiene BEATS_DEVTOOLS_PORT en sus bytes: es el host de DESARROLLO (con CDP abierto), no el de distribucion. Ejecuta 'zig build runtime-binaries' de nuevo." -ForegroundColor Red
    exit 1
}

# WebUI distribuible: dist/ entero menos los tests .cjs (artefactos de desarrollo).
$webuiDist = Join-Path $beatsDir "shell\webui\dist"
if (-not (Test-Path (Join-Path $webuiDist "bundle.js")) -or -not (Test-Path (Join-Path $webuiDist "index.html"))) {
    Write-Host "FAIL: falta el bundle WebUI en shell/webui/dist (bundle.js/index.html)" -ForegroundColor Red
    exit 1
}

# 3. Firma Authenticode
#    -SigningCertThumbprint <thumbprint>: firma de produccion con el certificado indicado.
#    Sin parametro: firma AUTOFIRMADA solo para desarrollo/pruebas locales — no confiere
#    confianza SmartScreen ni valida la identidad del editor.
Write-Host "Verificando firmas de codigo..."
$cert = $null
$selfSigned = $false
if ($SigningCertThumbprint) {
    $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $SigningCertThumbprint -and $_.HasPrivateKey } | Select-Object -First 1
    if (-not $cert) {
        Write-Host "FAIL: certificado $SigningCertThumbprint no encontrado o sin clave privada." -ForegroundColor Red
        exit 1
    }
} else {
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like "*DevAgents Release Signing*" } | Select-Object -First 1
    if (-not $cert) {
        Write-Host "Creando certificado de firmas de pruebas DevAgents Code Signing..."
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=DevAgents Release Signing, O=DevAgents Team" -CertStoreLocation Cert:\CurrentUser\My -ErrorAction SilentlyContinue
    }
    $selfSigned = $true
}

# Solo se firman los PE: devagents.ico no es ejecutable y pasarlo por
# Set-AuthenticodeSignature lo deja bloqueado (medido: el Get-FileHash
# posterior fallaba con archivo en uso y el manifiesto heredaba el hash
# del binario anterior).
$signable = $required | Where-Object { $_ -match '\.(exe|dll)$' }

if ($cert) {
    $signed = 0
    foreach ($r in $signable) {
        $p = Join-Path $binDir $r
        $sig = Set-AuthenticodeSignature -FilePath $p -Certificate $cert -ErrorAction SilentlyContinue
        if ($sig -and ($sig.Status -eq 'Valid' -or $sig.Status -eq 'UnknownError')) { $signed++ }
    }
    if ($selfSigned) {
        Write-Host "Binarios firmados ($signed/$($signable.Count)) con certificado AUTOFIRMADO $($cert.Thumbprint) — solo valido para pruebas locales. Para release usar -SigningCertThumbprint con un certificado de CA/EV." -ForegroundColor Yellow
    } else {
        Write-Host "Binarios firmados ($signed/$($signable.Count)) con certificado $($cert.Thumbprint) (emisor: $($cert.Subject))"
    }
} else {
    Write-Host "ADVERTENCIA: No se pudo firmar; el paquete quedara sin firma." -ForegroundColor Yellow
}

# 4. Manifiesto de firmas SHA-256 DESPUES de firmar — un hash tomado antes de
#    Set-AuthenticodeSignature no coincide con el binario firmado que sale al
#    usuario; el auto-updater diferencial compararia contra bytes distintos.
$hashes = @{}
foreach ($r in $required) {
    $p = Join-Path $binDir $r
    try {
        $h = (Get-FileHash -Path $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
    } catch {
        Write-Host "FAIL: no se pudo hashear $p — $_" -ForegroundColor Red
        exit 1
    }
    $hashes[$r] = $h
}

$manifest = @{
    version = $AppVersion
    releaseDate = (Get-Date -Format "o")
    hashes = $hashes
    autoUpdateStrategy = "differential-atomic-quit-and-install"
    minSupportedVersion = "0.9.0"
    # Lo que se puede afirmar del empaquetado: el .iss solo escribe en {app} y
    # {tmp}; el dir de datos vive fuera. La preservacion real de datos se mide
    # instalando encima de una instalacion previa — no se declara sin medirla.
    userDataDir = "%LOCALAPPDATA%\DevAgents-Angel (fuera de {app}; el instalador no la toca)"
    userDirPreservedVerified = $false
}

$manifestJson = $manifest | ConvertTo-Json -Depth 5
$manifestPath = Join-Path $distDir "update_manifest.json"
Set-Content -Path $manifestPath -Value $manifestJson -Encoding UTF8
Write-Host "Manifiesto de auto-updater creado en: $manifestPath"

# 5. P1-7 (R2 D3): alternativa portable .zip con los MISMOS archivos que el
#    instalador (binarios, cabina y licencias), sin instalar nada. Se descomprime
#    y se abre devagents-host.exe; WebView2 Runtime tiene que estar instalado.
$portableName = "DevAgents-v$AppVersion-portable"
$staging = Join-Path $distDir $portableName
$zipPath = Join-Path $distDir "$portableName.zip"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
foreach ($r in $required) { Copy-Item -Path (Join-Path $binDir $r) -Destination $staging -ErrorAction Stop }
$stagingWebui = Join-Path $staging "shell\webui\dist"
New-Item -ItemType Directory -Force -Path $stagingWebui | Out-Null
# 13-nov: tambien *.test.js (seis pruebas de la cabina compiladas como .js
# salian en el instalador y en el .zip; medido en el paquete de la tanda 4).
Copy-Item -Path (Join-Path $webuiDist "*") -Destination $stagingWebui -Recurse -Exclude "*.test.cjs","*.test.js" -ErrorAction Stop
Get-ChildItem -Path $stagingWebui -Recurse -Include "*.test.cjs","*.test.js" | Remove-Item -Force
$stagingLicenses = Join-Path $staging "licenses"
New-Item -ItemType Directory -Force -Path $stagingLicenses | Out-Null
foreach ($entry in $licenseFiles.GetEnumerator()) {
    Copy-Item -Path $entry.Value -Destination (Join-Path $stagingLicenses $entry.Key) -ErrorAction Stop
}
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
Remove-Item -Recurse -Force $staging
$zipMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Host "Paquete portable: $zipPath ($zipMb MB)"
if ($ZipOnly) {
    Write-Host "PACKAGING STATUS: PASS (solo .zip portable)"
    exit 0
}

# 6. Compilar el instalador real con Inno Setup (ISCC). Antes este script solo
#    generaba un ZIP con binarios sueltos: no habia instalador que probar.
$issPath = Join-Path $beatsDir "tools\installer.iss"
$iscc = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $iscc) {
    Write-Host "FAIL: ISCC.exe (Inno Setup 6) no encontrado. Instalar Inno Setup o pasar la ruta." -ForegroundColor Red
    exit 1
}

Write-Host "Compilando instalador con ISCC: $iscc"
& $iscc "/DMyAppVersion=$AppVersion" "/DMyAppPublisher=$AppPublisher" "/DMyAppURL=$AppURL" "/DMyAppId=$AppId" "/DBinDir=$binDir" "/DWebuiDir=$webuiDist" $issPath | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: ISCC devolvio $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

$setupExe = Join-Path $beatsDir "tools\Output\DevAgents-Setup-v$AppVersion.exe"
if (-not (Test-Path $setupExe)) {
    Write-Host "FAIL: ISCC termino sin producir $setupExe" -ForegroundColor Red
    exit 1
}
$setupMb = [math]::Round((Get-Item $setupExe).Length / 1MB, 2)
Write-Host "Instalador compilado: $setupExe ($setupMb MB)"

# 7. Tanda 5 (F0.4): huella del instalador para el actualizador de la cabina
#    (core/src/updater.zig, parseShaLine). Formato de sha256sum:
#    «<64 hex>  <nombre>». Se toma del .exe FINAL: si algun dia se firma el
#    instalador, ese paso va ANTES de esta linea o la huella no coincidira.
#    Se publica junto al .exe en la Release de GitHub.
$setupName = Split-Path -Leaf $setupExe
try {
    $setupHash = (Get-FileHash -Path $setupExe -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
} catch {
    Write-Host "FAIL: no se pudo hashear $setupExe — $_" -ForegroundColor Red
    exit 1
}
$shaPath = "$setupExe.sha256"
[System.IO.File]::WriteAllText($shaPath, "$setupHash  $setupName`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Huella del instalador: $shaPath"

Write-Host "PACKAGING STATUS: PASS"
exit 0
