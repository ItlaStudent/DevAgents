@echo off
setlocal EnableDelayedExpansion
title DevAgents Angel

rem ===========================================================================
rem  Lanzador de DevAgents Angel (version de trabajo; DevAgents esta congelado)
rem
rem  Compila lo que falte y abre la cabina nativa. Pensado para pruebas: deja
rem  el motor apuntando a este proyecto como workspace, de modo que el
rem  explorador y las herramientas de los agentes operen sobre el repositorio.
rem
rem  Si faltan Zig o Node, los INSTALA en vez de rendirse. Un tester con el
rem  codigo recien descargado no tiene por que saber que hace falta Zig 0.16.
rem  Zig se instala DENTRO del repositorio (toolchain\), sin tocar el PATH del
rem  sistema ni pisar otra version que el tester ya tenga.
rem
rem  Uso:
rem    DevAgents.bat              compila si hace falta y arranca
rem    DevAgents.bat /rebuild     fuerza recompilacion completa
rem    DevAgents.bat /ui          recompila solo la interfaz y arranca
rem    DevAgents.bat /devtools    arranca con DevTools en el puerto 9222
rem    DevAgents.bat /nodeps      no instala nada; falla si algo falta
rem    DevAgents.bat /limpiar     borra cache y binarios y sale (no arranca)
rem
rem  Si la compilacion falla, reintenta UNA vez con la cache borrada antes de
rem  rendirse: en Windows con Defender activo es normal que el antivirus ponga
rem  en cuarentena los binarios intermedios de Zig A MITAD de compilacion, y el
rem  sintoma es un error distinto cada vez (InvalidExe, 'unexpected EOF reading
rem  cached ZIR', 'truncated or malformed archive'). Ninguno es culpa del codigo.
rem ===========================================================================

rem ROOT se captura ANTES del bucle de argumentos y todo lo de abajo lo usa en
rem vez de %~dp0. Motivo: 'shift' desplaza TAMBIEN %0, asi que tras procesar el
rem primer flag %~dp0 pasa a ser la ruta del propio flag — sin unidad ni carpeta,
rem o sea "C:\". Medido: con /ui, Zig se instalaba en C:\toolchain\ en vez de en
rem la carpeta del repositorio. Sin flags no se notaba porque el bucle sale sin
rem llegar a hacer ni un shift.
set "ROOT=%~dp0"
cd /d "%ROOT%"

set "HOST=zig-out\bin\devagents-host.exe"
rem  La cache va en %LOCALAPPDATA%\Temp, NO en C:\tmp\beats-cache: medido el
rem  15-08 que esa ruta corrompe los test.exe ('InvalidExe', 'unexpected EOF
rem  reading cached ZIR') tres corridas seguidas. La causa raiz es Defender
rem  borrando binarios intermedios a mitad de compilacion; la exclusion sigue
rem  siendo la cura definitiva (ver :builderror).
set "CACHE=%LOCALAPPDATA%\Temp\angel-cache"
set "REBUILD="
set "UIONLY="
set "DEVTOOLS="
set "NODEPS="
set "LIMPIAR="

rem Version de Zig que compila este arbol. Si la cambias, cambia tambien
rem ZIG_DIR y ZIG_URL: el nombre de la carpeta viene dentro del propio zip.
set "ZIG_REQ=0.16"
set "ZIG_FULL=0.16.0"
set "ZIG_DIR=%ROOT%toolchain\zig-x86_64-windows-0.16.0"
set "ZIG_URL=https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip"
rem  SHA-256 y tamano oficiales del zip, copiados de
rem  https://ziglang.org/download/index.json (clave "0.16.0" > "x86_64-windows",
rem  leidos el 11-nov-2026). Si cambias ZIG_URL, cambia estos dos valores.
set "ZIG_SHA256=68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e"
set "ZIG_SIZE=97217739"

rem  Espacio libre recomendado en la unidad del repositorio y en la de la
rem  cache. Medido el 11-nov-2026 (cache nueva): una compilacion limpia de
rem  runtime-binaries ocupa 0,59 GiB (0,40 de cache y 0,19 de salida); con
rem  Zig en toolchain\ (0,34), su zip temporal (0,09), node_modules (0,13) y
rem  la cache global de Zig (0,14) son unos 1,3 GiB. Se piden 3 GiB de margen.
rem  Es un aviso, no un bloqueo.
set "NEED_GIB=3"

:parse
if "%~1"=="" goto endparse
if /I "%~1"=="/rebuild"  set "REBUILD=1"
if /I "%~1"=="/ui"       set "UIONLY=1"
if /I "%~1"=="/devtools" set "DEVTOOLS=1"
if /I "%~1"=="/nodeps"   set "NODEPS=1"
if /I "%~1"=="/limpiar"  set "LIMPIAR=1"
shift
goto parse
:endparse

echo.
echo   DevAgents Angel
echo   ---------------

rem --- Limpieza ---------------------------------------------------------------
rem  Deja el arbol como recien clonado, para llevarlo a otro equipo o para
rem  empezar de cero tras una cache corrupta. NO toca %LOCALAPPDATA%\DevAgents-Angel:
rem  ahi viven las claves API cifradas y el catalogo, y borrarlos sin avisar
rem  seria destruir trabajo del usuario.
if defined LIMPIAR (
  echo   Limpiando...
  if exist "%CACHE%"    ( rmdir /s /q "%CACHE%"    && echo     [i] cache de compilacion borrada )
  if exist "zig-out"    ( rmdir /s /q "zig-out"    && echo     [i] zig-out\ borrado )
  if exist "dist"       ( rmdir /s /q "dist"       && echo     [i] dist\ borrado )
  for /d %%d in ("orden-*") do ( rmdir /s /q "%%d" && echo     [i] %%d borrado )
  echo.
  echo   Listo. Tus claves API y el catalogo NO se han tocado
  echo   ^(siguen en %LOCALAPPDATA%\DevAgents-Angel^).
  echo.
  pause
  exit /b 0
)

rem --- Espacio libre ----------------------------------------------------------
rem  Sin espacio, Zig falla a mitad con errores que parecen del codigo. Se
rem  avisa antes, en la unidad del repositorio y en la de la cache.
for %%u in ("%ROOT%" "%CACHE%") do (
  set "FREEGIB="
  for /f "delims=" %%g in ('powershell -NoProfile -Command "[math]::Floor((Get-PSDrive -Name '%%~du'.TrimEnd(':')).Free/1GB)" 2^>nul') do set "FREEGIB=%%g"
  if not defined FREEGIB (
    echo   [^^!] No se pudo medir el espacio libre de %%~du.
  ) else if !FREEGIB! LSS %NEED_GIB% (
    echo   [^^!] Quedan !FREEGIB! GiB libres en %%~du y una compilacion limpia
    echo       necesita unos %NEED_GIB% GiB. Libera espacio si falla a mitad.
  ) else (
    echo   [i] Espacio libre en la unidad %%~du: !FREEGIB! GiB.
  )
)

rem --- Zig --------------------------------------------------------------------
rem  Se comprueba la VERSION, no solo la presencia. Un tester con Zig 0.15 en el
rem  PATH pasaba el 'where zig' y luego se comia una pared de errores de
rem  compilacion sin ninguna pista de que la culpa era la version.

if exist "%ZIG_DIR%\zig.exe" (
  set "PATH=%ZIG_DIR%;%PATH%"
  echo   [i] Usando el Zig local del repositorio ^(toolchain\^).
)

set "ZIGVER="
for /f "delims=" %%v in ('zig version 2^>nul') do set "ZIGVER=%%v"

if not defined ZIGVER (
  echo   [^^!] No se encontro 'zig' en el PATH.
  goto needzig
)

echo !ZIGVER! | findstr /b /c:"%ZIG_REQ%" >nul
if errorlevel 1 (
  echo   [^^!] Zig !ZIGVER! encontrado, pero DevAgents necesita %ZIG_REQ%.x
  echo       Se instalara %ZIG_FULL% en toolchain\ sin tocar tu Zig actual.
  goto needzig
)

echo   [i] Zig !ZIGVER! OK.
goto checknode

:needzig
if defined NODEPS (
  echo   [X] Falta Zig %ZIG_REQ% y se paso /nodeps.
  echo       Descargalo de %ZIG_URL%
  echo.
  pause
  exit /b 1
)
echo.
echo   Hace falta Zig %ZIG_FULL% para compilar el motor y la cabina.
echo     Origen : %ZIG_URL%
echo     Destino: %ROOT%toolchain\   ^(unos 93 MB de descarga, ~350 MB en disco^)
echo     No se modifica el PATH del sistema ni el Zig que ya tengas.
echo.
echo   Sin respuesta en 20 s no se instala nada. Usa /nodeps para omitir dependencias.
choice /c SN /t 20 /d N /m "   Descargar e instalar ahora [S/N]"
if errorlevel 2 (
  echo.
  echo   [X] Cancelado. Instala Zig %ZIG_FULL% manualmente y vuelve a ejecutar.
  echo.
  pause
  exit /b 1
)

echo.
echo   [1/4] Descargando Zig %ZIG_FULL% ...
if not exist "%ROOT%toolchain" mkdir "%ROOT%toolchain"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$zip=Join-Path $env:TEMP 'zig-devagents.zip';" ^
  "try {" ^
  "  $ProgressPreference='SilentlyContinue';" ^
  "  Invoke-WebRequest -Uri '%ZIG_URL%' -OutFile $zip -UseBasicParsing;" ^
  "  Write-Host ('       descargado: ' + [math]::Round((Get-Item $zip).Length/1MB,1) + ' MB');" ^
  "  $len=(Get-Item $zip).Length; $h=[Security.Cryptography.SHA256]::Create(); $sha=([BitConverter]::ToString($h.ComputeHash([IO.File]::ReadAllBytes($zip)))).Replace('-','').ToLowerInvariant();" ^
  "  if ($len -ne %ZIG_SIZE% -or $sha -ne '%ZIG_SHA256%') {" ^
  "    Remove-Item $zip -Force;" ^
  "    Write-Host ('       ERROR: el zip no coincide con el publicado por ziglang.org (tamano ' + $len + ', SHA-256 ' + $sha + '; se esperaba %ZIG_SIZE% y %ZIG_SHA256%). Se ha borrado y no se instala.');" ^
  "    exit 2" ^
  "  }" ^
  "  Write-Host '       SHA-256 comprobado.';" ^
  "  Write-Host '       extrayendo...';" ^
  "  Expand-Archive -Path $zip -DestinationPath '%ROOT%toolchain' -Force;" ^
  "  Remove-Item $zip -Force;" ^
  "  exit 0" ^
  "} catch { if (Test-Path $zip) { Remove-Item $zip -Force }; Write-Host ('       ERROR: ' + $_.Exception.Message); exit 1 }"
if errorlevel 2 (
  echo.
  echo   [X] El zip de Zig descargado no es el oficial ^(SHA-256 distinto^).
  echo       Puede ser una descarga corrupta o manipulada. Vuelve a intentarlo
  echo       o descargalo a mano de %ZIG_URL% y comprueba su SHA-256:
  echo       %ZIG_SHA256%
  echo.
  pause
  exit /b 1
)
if errorlevel 1 (
  echo.
  echo   [X] Fallo la descarga de Zig.
  echo       Descargalo a mano de %ZIG_URL%
  echo       y descomprimelo en %ROOT%toolchain\
  echo.
  pause
  exit /b 1
)

if not exist "%ZIG_DIR%\zig.exe" (
  echo.
  echo   [X] El zip se descomprimio pero no aparecio %ZIG_DIR%\zig.exe
  echo       Revisa el contenido de %ROOT%toolchain\
  echo.
  pause
  exit /b 1
)
set "PATH=%ZIG_DIR%;%PATH%"
set "ZIGVER="
for /f "delims=" %%v in ('zig version 2^>nul') do set "ZIGVER=%%v"
echo   [i] Zig !ZIGVER! instalado en toolchain\.

rem --- Node -------------------------------------------------------------------
:checknode
where node >nul 2>&1
if not errorlevel 1 goto nodeok

echo   [^^!] No se encontro 'node' en el PATH.
if defined NODEPS (
  echo   [X] Node hace falta para empaquetar la interfaz y se paso /nodeps.
  echo       Instalalo de https://nodejs.org/
  echo.
  pause
  exit /b 1
)

where winget >nul 2>&1
if errorlevel 1 (
  echo   [X] Node hace falta para empaquetar la interfaz ^(esbuild^),
  echo       y este equipo no tiene 'winget' para instalarlo solo.
  echo       Instalalo de https://nodejs.org/ y vuelve a ejecutar.
  echo.
  pause
  exit /b 1
)

echo.
echo   Se instalara Node.js LTS con winget ^(paquete OpenJS.NodeJS.LTS^).
echo.
echo   Sin respuesta en 20 s no se instala nada. Usa /nodeps para omitir dependencias.
choice /c SN /t 20 /d N /m "   Instalar ahora [S/N]"
if errorlevel 2 (
  echo.
  echo   [X] Cancelado. Instala Node de https://nodejs.org/ y vuelve a ejecutar.
  echo.
  pause
  exit /b 1
)

echo   [1/4] Instalando Node.js LTS ...
winget install --id OpenJS.NodeJS.LTS --exact --silent ^
  --accept-package-agreements --accept-source-agreements
if errorlevel 1 (
  echo.
  echo   [X] Fallo la instalacion de Node con winget.
  echo       Instalalo de https://nodejs.org/ y vuelve a ejecutar.
  echo.
  pause
  exit /b 1
)

rem winget actualiza el PATH del sistema, pero NO el de esta consola ya abierta.
rem Sin esto, el 'where node' de abajo sigue fallando en la misma ejecucion.
for /f "skip=2 tokens=2,*" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYSPATH=%%b"
if defined SYSPATH set "PATH=!SYSPATH!;!PATH!"
if exist "%ProgramFiles%\nodejs\node.exe" set "PATH=%ProgramFiles%\nodejs;!PATH!"

where node >nul 2>&1
if errorlevel 1 (
  echo.
  echo   [^^!] Node quedo instalado, pero esta consola no lo ve todavia.
  echo       Cierra esta ventana y vuelve a ejecutar DevAgents.bat.
  echo.
  pause
  exit /b 1
)

:nodeok
for /f "delims=" %%v in ('node --version 2^>nul') do set "NODEVER=%%v"
echo   [i] Node !NODEVER! OK.

if not exist "shell\webui\node_modules" (
  echo   [2/4] Instalando dependencias de la interfaz...
  pushd shell\webui
  call npm install --no-audit --no-fund
  popd
  if errorlevel 1 (
    echo   [X] Fallo 'npm install'.
    pause
    exit /b 1
  )
)

rem --- Compilacion -----------------------------------------------------------
if defined UIONLY (
  echo   [3/4] Recompilando solo la interfaz...
  set "PASO=webui"
  goto compilar
)

if defined REBUILD goto build
if not exist "%HOST%" goto build

echo   [3/4] Comprobando cambios...
goto build

:build
echo   [3/4] Compilando motor, cabina e interfaz...
echo         ^(la primera vez tarda varios minutos^)
set "PASO=runtime-binaries"

rem  Primer intento. Si falla NO se da por perdido: en un Windows con Defender
rem  activo lo mas probable es que el antivirus se haya comido un binario
rem  intermedio de la cache, y con la cache borrada compila a la primera.
:compilar
zig build -j1 --cache-dir "%CACHE%" !PASO!
if not errorlevel 1 goto launch

echo.
echo   [^^!] La compilacion fallo. Casi siempre es el antivirus mordiendo la
echo       cache, no tu codigo. Reintentando con la cache borrada...
echo.
if exist "%CACHE%" rmdir /s /q "%CACHE%"
zig build -j1 --cache-dir "%CACHE%" !PASO!
if errorlevel 1 goto builderror

echo   [i] A la segunda funciono: era la cache.

:launch
if not exist "%HOST%" (
  echo   [X] No se genero %HOST%.
  pause
  exit /b 1
)

rem --- Arranque --------------------------------------------------------------
if defined DEVTOOLS (
  set "DEVAGENTS_DEVTOOLS_PORT=9222"
  echo   [4/4] Arrancando con DevTools en http://localhost:9222 ...
) else (
  echo   [4/4] Arrancando DevAgents...
)

echo.
echo   Workspace: %CD%
echo   Claves API y catalogo: %LOCALAPPDATA%\DevAgents-Angel
echo.
echo   Primer paso: barra de actividad ^> Configuracion ^> Proveedores y claves,
echo   y usa "Conectar Claude" o "Conectar Google Gemini" para pegar tu clave.
echo.

start "" "%HOST%"
exit /b 0

:builderror
echo.
echo   [X] La compilacion fallo DOS veces, la segunda con la cache recien
echo       borrada. Revisa la salida de arriba.
echo.
echo   Si ves 'unexpected EOF reading cached ZIR', 'InvalidExe', 'truncated or
echo   malformed archive' o 'unable to load' sobre archivos de la cache, sigue
echo   siendo el antivirus: esta poniendo en cuarentena los binarios intermedios
echo   MIENTRAS se compila, asi que borrar la cache no basta. Hace falta una
echo   exclusion, desde una consola de ADMINISTRADOR:
echo.
echo       Add-MpPreference -ExclusionPath '%LOCALAPPDATA%\Temp\angel-cache'
echo       Add-MpPreference -ExclusionPath '%ROOT%'
echo.
echo   Y luego vuelve a ejecutar DevAgents.bat.
echo.
pause
exit /b 1
