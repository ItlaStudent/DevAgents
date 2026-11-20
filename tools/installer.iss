; ===============================================================================
; INNO SETUP INSTALLER SCRIPT - DEVAGENTS
; ===============================================================================
;
; P1-7 (R2 D1, D2, 11-nov): version, editor, URL y AppId no van fijos aqui.
; tools/package_installer.ps1 los pasa a ISCC con /D, tomando la version de
; core/src/root.zig (VERSION, la misma fuente que usa build.zig para la
; identidad y el VERSIONINFO de los binarios). Compilar este .iss a mano sin
; esos /D es un error, no un instalador con valores de relleno.

#ifndef MyAppVersion
  #error "Falta /DMyAppVersion=<x.y.z>: usa tools/package_installer.ps1"
#endif
#ifndef MyAppPublisher
  #error "Falta /DMyAppPublisher=<editor>: usa tools/package_installer.ps1"
#endif
#ifndef MyAppURL
  #error "Falta /DMyAppURL=<url>: usa tools/package_installer.ps1"
#endif
#ifndef MyAppId
  #error "Falta /DMyAppId=<GUID>: usa tools/package_installer.ps1"
#endif
; Carpeta con los binarios instalados por `zig build runtime-binaries`
; (por defecto ..\zig-out\bin; package_installer.ps1 pasa la de --prefix).
#ifndef BinDir
  #define BinDir "..\zig-out\bin"
#endif
#ifndef WebuiDir
  #define WebuiDir "..\shell\webui\dist"
#endif

#define MyAppName "DevAgents"
#define MyAppExeName "devagents-host.exe"
; Tanda 5 (F0.4): mutex con nombre que crea el host mientras vive
; (shell/host/update_apply.hpp, kHostMutexName). Mismo texto en los dos sitios.
#define HostMutex "DevAgentsHostRunning"

[Setup]
; AppId nuevo, sin «DevAgents» (11-nov). Cambiarlo hace que este instalador no
; reconozca como suya una instalacion hecha con el AppId anterior: no hay
; instalaciones publicas, pero una de prueba antigua se desinstala aparte.
AppId={{{#MyAppId}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
VersionInfoVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={userpf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputBaseFilename=DevAgents-Setup-v{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
SetupIconFile={#BinDir}\devagents.ico
UninstallDisplayIcon={app}\devagents.ico
UninstallFilesDir={app}\uninst
ShowLanguageDialog=auto
; T7: la tarea «Añadir devagents al PATH» toca el PATH del usuario; Inno avisa
; a Windows del cambio de entorno al terminar (y al desinstalar).
ChangesEnvironment=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
spanish.InstallingWebView2=Instalando Microsoft WebView2 Runtime (requiere conexión a internet)...
english.InstallingWebView2=Installing Microsoft WebView2 Runtime (requires an internet connection)...
spanish.WebView2Missing=DevAgents requiere el Microsoft WebView2 Runtime, que no está instalado en este equipo.%n%nEl instalador lo instalará automáticamente al finalizar (el instalador de Microsoft descargará el runtime; se requiere conexión a internet).%n%n¿Continuar con la instalación?
english.WebView2Missing=DevAgents requires the Microsoft WebView2 Runtime, which is not installed on this computer.%n%nSetup will install it automatically at the end (Microsoft's bootstrapper downloads the runtime; an internet connection is required).%n%nContinue with the installation?

spanish.AddToPath=Añadir devagents al PATH (disponible en una terminal nueva)
english.AddToPath=Add devagents to PATH (available in a new terminal)
spanish.OtherTasks=Otras tareas:
english.OtherTasks=Other tasks:

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
; T7 (d): como VS Code con `code`, opcional y solo en el PATH del
; usuario (HKCU\Environment). Se quita al desinstalar (CurUninstallStepChanged).
Name: "addtopath"; Description: "{cm:AddToPath}"; GroupDescription: "{cm:OtherTasks}"

[Files]
; Reparto real medido contra zig-out/bin y contra lo que la app carga en
; runtime (P1.1): el host lanza devagents-engine.exe por CreateProcessW
; (shell/host/engine_supervisor.cpp) y devagents.ico por LoadImageW desde el
; dir del exe (shell/host/window.cpp). WebView2Loader.dll se sirve el binario
; probado en zig-out, no la copia del SDK.
Source: "{#BinDir}\devagents-host.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\devagents-engine.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\devagents-core.exe"; DestDir: "{app}"; Flags: ignoreversion
; T7: la CLI con su nombre de producto (mismo binario que devagents-core).
Source: "{#BinDir}\devagents.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\devagents-mcp.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\devagents_core.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\key-admin.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\devagents.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\WebView2Loader.dll"; DestDir: "{app}"; Flags: ignoreversion
; La cabina sirve TODO dist/ (bundle + index + preview/), menos los tests .cjs
; que son artefactos de desarrollo y no deben salir al usuario. Los textos de
; licencia de Monaco y xterm viajan dentro de dist/vendor (esbuild.config.mjs).
Source: "{#WebuiDir}\*"; DestDir: "{app}\shell\webui\dist"; Flags: ignoreversion recursesubdirs; Excludes: "*.test.cjs,*.test.js"
; P1-7 (R2 D1): licencias y avisos que acompanan a los binarios.
Source: "..\LICENSE"; DestDir: "{app}\licenses"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\NOTICE"; DestDir: "{app}\licenses"; DestName: "NOTICE.txt"; Flags: ignoreversion
Source: "..\TRADEMARKS.md"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\shell\host\sdk\LICENSE.txt"; DestDir: "{app}\licenses"; DestName: "WebView2-SDK-LICENSE.txt"; Flags: ignoreversion
Source: "..\shell\host\sdk\NOTICE.txt"; DestDir: "{app}\licenses"; DestName: "WebView2-SDK-NOTICE.txt"; Flags: ignoreversion
Source: "ZIG-STDLIB-LICENSE.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "vendor\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\devagents.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\devagents.ico"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; Tasks: addtopath; Check: NeedsAddPath(ExpandConstant('{app}'))

[Run]
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; Check: not IsWebView2Installed; StatusMsg: "{cm:InstallingWebView2}"; Flags: waituntilterminated
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
// Bootstrapper check for WebView2 Runtime. La consulta de registro «fallaba»
// aun con el runtime presente porque usaba un GUID que no existe
// ({…-F0E3A2C7172D}); el del runtime Evergreen documentado por Microsoft es
// {F3017226-FE2A-4295-8BDF-00C3A9A7E4C5} (el mismo de core/src/doctor.zig;
// medido el 13-nov: pv=157.0.4341.46 con este y «no existe» con el anterior).
// La deteccion por carpeta queda como respaldo.
function IsWebView2Installed(): Boolean;
var
  dwVersion: String;
begin
  Result := (RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', dwVersion) and (dwVersion <> '') and (dwVersion <> '0.0.0.0')) or
            (RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', dwVersion) and (dwVersion <> '') and (dwVersion <> '0.0.0.0')) or
            (RegQueryStringValue(HKCU, 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', dwVersion) and (dwVersion <> '') and (dwVersion <> '0.0.0.0')) or
            DirExists(ExpandConstant('{commonpf32}\Microsoft\EdgeWebView\Application')) or
            DirExists(ExpandConstant('{commonpf64}\Microsoft\EdgeWebView\Application'));
end;

// Tanda 5 (F0.4): el host lanza este instalador al cerrar con /VERYSILENT
// /SUPPRESSMSGBOXES /NORESTART /UPDATE (shell/host/update_apply.cpp).
function IsUpdateRun(): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 1 to ParamCount do
    if CompareText(ParamStr(i), '/UPDATE') = 0 then begin
      Result := True;
      exit;
    end;
end;

// Espera hasta 60 s a que el host salga (su mutex desaparece al terminar el
// proceso). True si ya no queda ningún host vivo.
function WaitForHostToExit(): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while CheckForMutexes('{#HostMutex}') and (waited < 60000) do begin
    Sleep(500);
    waited := waited + 500;
  end;
  Result := not CheckForMutexes('{#HostMutex}');
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if IsUpdateRun() then begin
    if not WaitForHostToExit() then begin
      // En silencio, sin tocar nada: la actualización sigue preparada y el
      // host volverá a lanzarla en el próximo cierre.
      Log('DevAgents sigue abierto tras 60 s: no se actualiza; queda para el proximo cierre.');
      Result := False;
      exit;
    end;
    // El motor hijo del host (devagents-engine.exe) muere con el job del host
    // al terminar este; margen para que el sistema suelte sus archivos.
    Sleep(1500);
  end;
  if not IsWebView2Installed() then begin
    // En /VERYSILENT un MsgBox bloquea la instalacion esperando un clic que
    // nunca llega (medido con /LOG: el setup quedo colgado aqui). En silencio
    // se continua y el bootstrapper corre al final.
    if WizardSilent() then begin
      Result := True;
      exit;
    end;
    if MsgBox(CustomMessage('WebView2Missing'), mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;

// T7 (d): «Añadir devagents al PATH», como hace VS Code con `code`.
// Solo el PATH del usuario (HKCU\Environment), sin privilegios; la carpeta se
// añade una vez y se quita al desinstalar sin tocar el resto de entradas.
function PathContains(const Paths, Dir: String): Boolean;
begin
  Result := Pos(';' + Uppercase(RemoveBackslashUnlessRoot(Dir)) + ';', ';' + Uppercase(Paths) + ';') > 0;
end;

function NeedsAddPath(Dir: String): Boolean;
var
  OrigPath: String;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', OrigPath) then begin
    Result := True;
    exit;
  end;
  Result := not PathContains(OrigPath, Dir);
end;

procedure RemovePath(Dir: String);
var
  OrigPath, Entry, Rest, NewPath: String;
  P: Integer;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', OrigPath) then exit;
  Rest := OrigPath;
  NewPath := '';
  while Rest <> '' do begin
    P := Pos(';', Rest);
    if P = 0 then begin
      Entry := Rest;
      Rest := '';
    end else begin
      Entry := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, Length(Rest));
    end;
    if (Entry <> '') and (CompareText(RemoveBackslashUnlessRoot(Entry), RemoveBackslashUnlessRoot(Dir)) <> 0) then begin
      if NewPath <> '' then NewPath := NewPath + ';';
      NewPath := NewPath + Entry;
    end;
  end;
  if NewPath <> OrigPath then
    RegWriteExpandStringValue(HKCU, 'Environment', 'Path', NewPath);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemovePath(ExpandConstant('{app}'));
end;
