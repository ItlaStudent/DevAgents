# Prueba de humo de un paquete instalado (tanda 4, F0.4/F0.5).
#
# Comprueba, con las señales que existen también en una compilación Release
# (el volcado del DOM solo lo escribe Debug, `#ifndef NDEBUG` en
# shell/host/webview_host.cpp):
#   1. el host arranca y la cabina termina de navegar (perf.log registra
#      «[DEVAGENTS_PERF] Cold Startup Time», solo tras una navegación buena);
#   2. la ventana principal se titula «DevAgents» y el proceso sigue vivo;
#   3. `devagents-core.exe doctor --json` del mismo paquete responde, con la
#      carpeta de datos y WebView2 en «ok».
# En Debug, además, valida el volcado del DOM (título y al menos 10 ids).
#
# Aislamiento de datos (12-nov-2026): ninguna prueba toca los datos del propietario.
# El host resuelve su carpeta con BEATS_DATA_DIR > DEVAGENTS_DATA_DIR >
# %LOCALAPPDATA%\DevAgents-Angel (shell/host/core_client.cpp, UserDataDir; el
# motor sigue el mismo orden en core/src/paths.zig, resolveDataDir). El guion
# crea una carpeta temporal nueva y vacía para los datos y otra para los
# registros (BEATS_WEBVIEW_LOG_DIR), lanza el host con ellas y las borra al final.

param(
    # Carpeta donde está instalado el paquete (la del instalador o el .zip).
    [string]$ReleaseDir = "C:\tmp\devagents-release-smoke",
    # Carpeta donde dejar la evidencia; por defecto, la de la tanda 4.
    [string]$EvidenceDir = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir "devagents-host.exe"))) {
    Write-Host "ERROR: falta devagents-host.exe en $ReleaseDir" -ForegroundColor Red
    exit 1
}
$coreExe = Join-Path $ReleaseDir "devagents-core.exe"
if (-not (Test-Path -LiteralPath $coreExe)) {
    Write-Host "ERROR: falta devagents-core.exe en $ReleaseDir" -ForegroundColor Red
    exit 1
}

# Carpetas propias de esta ejecución: nuevas (GUID) y vacías.
$runId = [guid]::NewGuid().ToString("N")
$dataDir = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ("devagents-smoke-" + $runId)))
$logDir = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ("devagents-smoke-log-" + $runId)))

# Se niega a seguir si una carpeta resuelta es la del propietario o está dentro de ella.
$ownerDirs = @(
    (Join-Path $env:LOCALAPPDATA "DevAgents-Angel"),
    (Join-Path $env:LOCALAPPDATA "DevAgents")
) | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') }
foreach ($candidate in @($dataDir, $logDir)) {
    foreach ($owner in $ownerDirs) {
        if ($candidate.Equals($owner, [System.StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($owner + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "ERROR: la carpeta de la prueba ($candidate) es o está dentro de la del propietario ($owner). No se lanza nada." -ForegroundColor Red
            exit 2
        }
    }
    if (Test-Path -LiteralPath $candidate) {
        Write-Host "ERROR: la carpeta temporal ya existe ($candidate); debe ser nueva y vacía." -ForegroundColor Red
        exit 2
    }
}

if (-not $EvidenceDir) {
    $repo = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
    $EvidenceDir = Join-Path $repo "docs\evidencia\FASE0-20261110"
}

$prevBeats = $env:BEATS_DATA_DIR
$prevDevAgents = $env:DEVAGENTS_DATA_DIR
$prevLog = $env:BEATS_WEBVIEW_LOG_DIR
$process = $null
$exitCode = 1
$lines = New-Object System.Collections.Generic.List[string]
try {
    New-Item -ItemType Directory -Path $dataDir | Out-Null
    New-Item -ItemType Directory -Path $logDir | Out-Null

    # Start-Process hereda el entorno de este proceso: se fija aquí y se
    # restaura en el finally. BEATS_DATA_DIR se retira porque ganaría.
    Remove-Item Env:BEATS_DATA_DIR -ErrorAction SilentlyContinue
    $env:DEVAGENTS_DATA_DIR = $dataDir
    $env:BEATS_WEBVIEW_LOG_DIR = $logDir

    Write-Host "[SMOKE] Lanzando $ReleaseDir\devagents-host.exe (datos: $dataDir)" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath (Join-Path $ReleaseDir "devagents-host.exe") -WorkingDirectory $ReleaseDir -PassThru
    if (-not $process -or $process.HasExited) { throw "devagents-host.exe no arrancó" }

    # 1. Navegación terminada: perf.log con la marca de arranque en frío.
    $perfLog = Join-Path $logDir "perf.log"
    $coldMs = $null
    while ($sw.Elapsed.TotalSeconds -lt 45) {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) { throw "devagents-host.exe terminó durante el arranque (código $($process.ExitCode))" }
        if (Test-Path -LiteralPath $perfLog) {
            $m = Select-String -LiteralPath $perfLog -Pattern 'Cold Startup Time: (\d+) ms' | Select-Object -Last 1
            if ($m) { $coldMs = [int]$m.Matches[0].Groups[1].Value; break }
        }
    }
    if ($null -eq $coldMs) { throw "la cabina no terminó de navegar en 45 s (no hay «Cold Startup Time» en $perfLog)" }
    $lines.Add("Arranque en frío (perf.log): $coldMs ms")

    # 2. Ventana y proceso.
    $title = ""
    while ($sw.Elapsed.TotalSeconds -lt 60 -and -not $title) {
        $p = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if (-not $p) { throw "devagents-host.exe se cerró tras navegar" }
        $title = $p.MainWindowTitle
        if (-not $title) { Start-Sleep -Milliseconds 500 }
    }
    if ($title -notlike "DevAgents*") { throw "título de la ventana «$title», se esperaba «DevAgents»" }
    $lines.Add("Ventana: $title")
    Start-Sleep -Seconds 5
    if ($process.HasExited) { throw "devagents-host.exe se cerró 5 s después de abrir la ventana (código $($process.ExitCode))" }
    $lines.Add("Proceso vivo 5 s después de abrir la ventana: sí")

    # En Debug, el volcado del DOM (no existe en Release).
    $dump = Join-Path $logDir "beats_cdp_dump.json"
    if (Test-Path -LiteralPath $dump) {
        $domObj = Get-Content -Raw -LiteralPath $dump | ConvertFrom-Json
        if ($domObj.title -ne "DevAgents") { throw "título del DOM «$($domObj.title)»" }
        if (-not $domObj.ids -or $domObj.ids.Count -lt 10) { throw "el DOM tiene menos de 10 elementos con id" }
        $lines.Add("DOM (Debug): título $($domObj.title), $($domObj.ids.Count) ids")
    } else {
        $lines.Add("DOM: sin volcado (normal en Release)")
    }

    # 3. doctor del mismo paquete, con la misma carpeta de datos.
    $doctorJson = & $coreExe doctor --json 2>$null | Out-String
    $doctor = $doctorJson | ConvertFrom-Json
    if ($doctor.version -ne 1) { throw "doctor --json no devolvió un informe v1: $doctorJson" }
    $byId = @{}
    foreach ($c in $doctor.checks) { if (-not $byId.ContainsKey($c.id)) { $byId[$c.id] = $c } }
    foreach ($required in @("data_dir", "webview2")) {
        if (-not $byId.ContainsKey($required) -or $byId[$required].status -ne "ok") {
            throw "doctor: «$required» no está en ok: $(($byId[$required] | ConvertTo-Json -Compress))"
        }
    }
    $lines.Add("doctor: listo=$($doctor.ready); " + (($doctor.checks | ForEach-Object { "$($_.id)=$($_.status)" }) -join ", "))

    $exitCode = 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $lines.Add("ERROR: $($_.Exception.Message)")
    $exitCode = 1
}
finally {
    # Cierra el host lanzado y su árbol (el motor hijo tiene abierta la base
    # de la carpeta temporal; si sigue vivo, la carpeta no se puede borrar).
    if ($process -and -not $process.HasExited) {
        & taskkill.exe /PID $process.Id /T /F | Out-Null
        if (-not $process.WaitForExit(10000)) {
            Write-Host "ERROR: el proceso $($process.Id) no terminó tras taskkill." -ForegroundColor Red
            $exitCode = 1
        }
    }

    # Restaura el entorno de este proceso tal como estaba.
    if ($null -ne $prevBeats) { $env:BEATS_DATA_DIR = $prevBeats } else { Remove-Item Env:BEATS_DATA_DIR -ErrorAction SilentlyContinue }
    if ($null -ne $prevDevAgents) { $env:DEVAGENTS_DATA_DIR = $prevDevAgents } else { Remove-Item Env:DEVAGENTS_DATA_DIR -ErrorAction SilentlyContinue }
    if ($null -ne $prevLog) { $env:BEATS_WEBVIEW_LOG_DIR = $prevLog } else { Remove-Item Env:BEATS_WEBVIEW_LOG_DIR -ErrorAction SilentlyContinue }

    # Borra las carpetas temporales; reintenta mientras el sistema suelta los
    # archivos. Si no se puede, se dice y la ejecución no cuenta como PASS.
    foreach ($dir in @($dataDir, $logDir)) {
        if (Test-Path -LiteralPath $dir) {
            $borrada = $false
            for ($i = 0; $i -lt 10 -and -not $borrada; $i++) {
                try { Remove-Item -LiteralPath $dir -Recurse -Force; $borrada = $true }
                catch { Start-Sleep -Milliseconds 500 }
            }
            if (-not $borrada) {
                Write-Host "ERROR: no se pudo borrar la carpeta temporal $dir; bórrala a mano." -ForegroundColor Red
                $exitCode = 1
            }
        }
    }

    $time = Get-Date -Format "yyyyMMdd-HHmmss"
    if (-not (Test-Path -LiteralPath $EvidenceDir)) { New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null }
    $evidence = @(
        "PRUEBA DE HUMO DEL PAQUETE INSTALADO · $time",
        "Paquete: $ReleaseDir",
        "Datos y registros: carpetas temporales nuevas, borradas al terminar",
        ""
    ) + $lines + @("", $(if ($exitCode -eq 0) { "RESULTADO: PASA" } else { "RESULTADO: FALLA" }))
    $txtPath = Join-Path $EvidenceDir "T4-humo-paquete-$time.txt"
    Set-Content -LiteralPath $txtPath -Value $evidence -Encoding UTF8
    Write-Host "Evidencia: $txtPath"
}
exit $exitCode
