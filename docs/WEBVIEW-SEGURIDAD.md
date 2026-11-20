# Puente de la cabina: origen y depuración

Todas las `AppWindow` usan `WebViewHost`: la principal y los popouts reciben
las mismas barreras antes de navegar. `origin_policy.hpp` obtiene esquema,
host y puerto con `CreateUri`; únicamente HTTPS, `devagents.local` y puerto
443 permiten mensajes y navegación superior/frames. `:443` explícito es el
mismo origen. Los popups siempre se marcan manejados; HTTPS externo se abre
mediante la política del navegador del sistema. HTTP sólo se admite para `localhost` y `127.0.0.1` (Open Design);
los demás destinos web requieren HTTPS y se abren fuera de la WebView.

La vista previa existente conserva `preview.local`, recursos confinados,
frames bloqueados y su selector aislado. No tiene `Bridge`, no recibe eventos
de la cabina y nunca se conecta al callback de mensajes de la aplicación.

## Cabina de desarrollo y CDP

Los drivers `tools/cdp_*.mjs` continúan usando el puerto 9333 con una build
**Debug**. ReleaseSafe, ReleaseFast y ReleaseSmall definen `NDEBUG` para todo
el host C++: no leen las variables de CDP, deshabilitan DevTools, descartan
los flags de navegador enviados por la línea de comandos y eliminan la
variable heredada `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`. Los volcados
automáticos del DOM también quedan deshabilitados en release.

Compilar únicamente el host (requiere la DLL del motor existente junto al
ejecutable para una cabina completa), sin reconstruir el motor:

```powershell
$zig = 'C:\Workspace\Desktop\Proyectos\Proyecto - Model Zig\zig-0.16.0\zig-x86_64-windows-0.16.0\zig.exe'
$cache = Join-Path $env:LOCALAPPDATA ('Temp\beats-cache-sec-webview-' + [guid]::NewGuid.ToString('N'))
if ((Get-PSDrive C).Free -lt 20GB) { throw 'Espacio insuficiente para compilar' }
& $zig build shell-host-only -Doptimize=Debug -j1 --cache-dir "$cache\local" --global-cache-dir "$cache\global" --summary all
```

Construir la WebUI con `npm --prefix shell/webui run build` y sincronizar su
`dist` a `zig-out/bin/shell/webui/dist` antes de usar los drivers. Al iniciar
la cabina de pruebas, establecer `$env:BEATS_DEVTOOLS_PORT='9333'`. CDP no
necesita `--remote-allow-origins=*`; los drivers propios no envían Origin.
Usar datos y workspace de prueba; no ejecutar pruebas contra datos del propietario.

## Driver aislado del lote de seguridad

`zig build webview-security-driver -Doptimize=Debug -j1` con las mismas dos
opciones de caché construye `zig-out/bin/test-webview-security.exe`. Utiliza
la WebUI real, dos `AppWindow`, el puente y sus servicios reales, y
`CoreClient::InitMode::isolated_empty`: no inicializa DLL, base ni motor.
Antes de iniciarlo se requieren directorios existentes en estas variables:

* `BEATS_SECURITY_FIXTURE_DIR`: workspace y configuración temporales.
* `BEATS_WEBUI_DIR`: ruta absoluta al `dist` que se probará.
* `BEATS_WEBVIEW_LOG_DIR`: logs temporales (opción del proceso nativo).
* `BEATS_DEVTOOLS_PORT=9333`: conexión de los drivers CDP.

El perfil WebView2 queda dentro de `BEATS_SECURITY_FIXTURE_DIR`. Los logs y
el volcado del DOM quedan dentro de `BEATS_WEBVIEW_LOG_DIR`. La vista monitor
secundaria se crea al inicio; `window.open` crea más popouts por el supervisor
real. El driver permite comprobar navegación, frames, CSP, mensajes y
operaciones del puente; los flujos que requieren un motor activo siguen
requiriendo una prueba de la cabina completa. Eliminar solo la caché y las
fixtures propias después de cerrar el driver.

Prueba de origen enfocada: `zig build test-origin-policy -j1` con las mismas
opciones de caché. Incluye origen válido con puerto por defecto/explícito,
suplantación de host, HTTP, otros puertos, credenciales, controles, file,
about, data y javascript.

## Escritura y capacidad residual de terminal

`doc.save`, `search.replace` y `hunk.accept/reject` comparten
`DocumentManager::WriteAuthorizedFile`: la misma lista de raíces concedidas
por el host y los mismos ancestros retenidos. Desde la ronda 6 la escritura es
**atómica** (ver «Residuales de la auditoría el modelo r1»): archivo hermano creado
con `CREATE_NEW`, validado y escrito por su handle y renombrado sobre el
destino; la hoja existente se valida antes (sin reparse points, `nlink == 1`,
no solo lectura). Búsqueda/hunks usan `WriteWorkspaceFile`,
sin acceso a tokens Save As. `rootDir` de `search.replace` debe coincidir
con una raíz de workspace autorizada; enviar una ruta, subcarpeta, UNC o
`core.workspace.set` no concede autoridad. La enumeración omite reparse points;
los hardlinks se rechazan al abrir el handle. Un fallo de escritura devuelve
error, nunca éxito con un contador ficticio. El reemplazo de varios archivos
no es transaccional: archivos anteriores dentro de la raíz pueden quedar
modificados si uno posterior falla.

`pty.write` conserva, sin cambio de comportamiento, una **capacidad privilegiada
residual**: puede enviar comandos a una terminal y ejecutarlos con los permisos
del usuario. Su seguridad depende de que el JavaScript del origen autorizado
sea de confianza. Un XSS en ese origen hereda esa capacidad. La lista de shells
limita el ejecutable inicial; no restringe los comandos posteriores ni crea
un sandbox. El puente no protege frente al compromiso del JavaScript confiable.

El parser rechaza también credenciales vacías (`https://@devagents.local`),
aunque `CreateUri` devuelva user-info vacío. Las pruebas incluyen hosts con
`%2e` y punycode que intentan suplantar el origen.

Recorrido de la ronda 2: tras definir `BEATS_SECURITY_FIXTURE_DIR`, ejecutar
`node tools/cdp_sec_webview.mjs <directorio-evidencia> --prepare` antes del
arranque nativo. Prepara los enlaces de la fixture antes de que la autorización
retenga los handles de directorio. El driver autoriza también su subdirectorio
`workspace`, evitando buscar en perfiles/logs. Cuando principal y popout estén
listos, repetir el comando sin `--prepare`; incluye búsqueda/reemplazo y clics
reales del visor de hunks, con captura y texto de la misma ejecución.

## Zonas protegidas, errores y arnés de desarrollo (ronda 4)

* **Zonas sin escritura.** Dentro de una raíz concedida, el host no escribe
  (guardar, crear, buscar/reemplazar, hunks, clonar) en el bundle servido
  (`shell/webui/dist` o el que resuelva `main.cpp`), en el directorio del
  ejecutable, en ningún componente `.git` ni en `.gitattributes`
  (`DocumentManager::IsWritableWorkspacePath`). Leer y listar siguen siendo
  posibles. Los destinos de Guardar como elegidos con el diálogo nativo quedan
  fuera de esta regla porque los elige el usuario.
* **cwd amplio.** Si el cwd inicial es el perfil, Windows, Program Files,
  ProgramData, una unidad o un ancestro de ellos
  (`DocumentManager::IsBroadStartupRoot`), no se concede como raíz: la cabina
  arranca sin raíz y exige `dialog.pickWorkspace`.
* **Errores estables.** Los fallos de documentos, listados, búsqueda,
  checkpoints, clonado, consentimiento y Open Design devuelven
  `E_CODIGO: mensaje en español`. La WebUI decide por el código, no por el
  texto (`monaco_editor.ts` usa `E_SAVE_NOT_AUTHORIZED` y `E_SAVE_CONFLICT`).
* **CSP.** Se añaden `base-uri 'none'` y `form-action 'none'`.
* **Arnés `--test-bridge`.** Sólo existe bajo `#ifndef NDEBUG`; instancia el
  motor real y escribe en su catálogo. `tools/check_webview_release.ps1`
  comprueba que el preprocesado Release no lo contiene.
* **Pruebas del host.** Cada `test_*.cpp` con `assert` hace `#undef NDEBUG` al
  principio: ningún modo de optimización las deja sin efecto, y un fallo termina
  el proceso con código distinto de cero.
* **Despacho previo.** `bridge_inventory.test.mjs` falla ante cualquier
  comparación de `kind` (`msg.kind`, `msgKind`, `ExtractKind(...)` o variables
  asignadas desde él) que no esté en una lista blanca justificada por archivo y
  nombre; así `main.cpp` no puede volver a actuar antes del registro.

## Pruebas negativas por handler confinado (ronda 5)

Cada handler que toca una ruta enviada desde JS tiene casos hostiles ejecutables
en el host (`test-bridge`, `test-doc-mgr`, `test-bridge-policy`), no sólo en la
tabla:

| Vector | `test_document_manager.cpp` (primitiva) | `test_bridge.cpp` (handler por el puente) |
|---|---|---|
| Traversal `..` | `test_confined_save`, `Absolute` | `fs.mkdir`, `fs.createFile`, `fs.list`, `fs.watch`, `search.*`, `checkpoint.*`, `core.workspace.set`, `core.mount.add`, `core.repo.clone`, `doc.open`, `search.replace`, `hunk.*` |
| Absoluta fuera de raíz | idem | idem |
| Junction / hardlink | `test_confined_save` (+ conversión a reparse) | idem, con víctima intacta |
| UNC (`\\localhost\...`, `\\?\UNC\...`) | `test_unc_path_policy`, `test_win32_device_names_denied_everywhere` | bucle de dispositivos (17 handlers x 21 destinos) |
| Dispositivos Win32 (NUL, CON, PRN, AUX, COMn, LPTn; hoja, componente, con extensión, punto/espacio final, `\\.\`, `\\?\GLOBALROOT`, `C:\NUL`, `C:NUL`) | `test_win32_device_names_denied_everywhere`: 42 formas x 2 (barras normales) en las 12 primitivas del `DocumentManager`; la raíz y la carpeta externa quedan sin entradas | mismo bucle, más hoja hostil en `fs.mkdir`/`fs.createFile` y comparación del número de entradas de la raíz antes/después |
| Flujo alterno (`x.txt:$DATA`, `x:NUL`) | idem | idem |
| `shell.open` reveal | `test_bridge_policy.cpp`: 27 rutas hostiles rechazadas y normalización de `/` y barra final | n/a (la política vive en `shell_policy.hpp`) |

Estas pruebas se añadieron en la ronda 5 sin poder compilar (disco C: por debajo
de 20 GiB). **Se ejecutaron en la ronda 6** con el mínimo de espacio y pasaron a
la primera: `test-bridge` (21 bloques, 516 comprobaciones del escritor alterno),
`test-doc-mgr`, `test-bridge-policy` (`FASE-X/SEC-WEBVIEW/lote1-r6-test-*.txt`,
corridas de las 01:36-01:39 del 2026-10-08, anteriores a los cambios de la ronda 6).

## Residuales de la auditoría el modelo r1 (ronda 6)

* **BAJO-1 — autorización nativa con contexto y hilo correcto.**
  `Bridge::ConsentText` compone el diálogo con una tabla de 20 entradas (una por
  kind de `nativeConsent`): la **acción** la fija el host y el **recurso** lo
  declara la página, con control y marcas/anulaciones bidireccionales
  neutralizados, acotado a 240-400 caracteres, URL sin credenciales, consulta ni
  fragmento, y sin los secretos del payload (argumentos de `core.mcp.connect`,
  contraseña de `core.git.storeCredential`, secreto de webhooks, token MCP, texto
  de comentarios). Un kind desconocido muestra «Capacidad privilegiada del host».
  Los handlers `core.*` corren en un worker; `consent_prompt.hpp` publica la
  solicitud en la cola de la ventana propietaria (`WM_APP + 47`, atendida por su
  `WndProc`, también dentro de bucles modales) y el `MessageBox` se abre **en el
  hilo de UI** con ese propietario. Si la ventana muere o el host se apaga
  (`consent::Shutdown()` antes de unir los workers) antes de mostrarla, la
  respuesta es «no» y el worker no queda colgado. Desde el propio hilo de UI
  (`lsp.request`) no hay salto de hilo. Pruebas: `test_native_consent_context` en
  `test_bridge.cpp` (20 kinds con acción y recurso, secretos ausentes, texto
  hostil, presentador «no»/«sí», hilo de UI comprobado con un worker real,
  propietario destruido y apagado).
* **BAJO-4 — permisos, descargas y diálogos de la WebView principal.**
  `webview_policy.hpp`: `ApplyMainViewSettings` (DevTools sólo Debug, sin objetos
  del host, sin diálogos de script, sin página de error ni menús contextuales),
  `DenyPermission` (todo `PermissionRequested` → `DENY`) y `CancelDownload`
  (`DownloadStarting` → cancelar y marcar tratada). `webview_host.cpp` ya no
  ignora ningún HRESULT de los ajustes (antes las dos llamadas de las líneas
  810-811 se descartaban) y un registro fallido de `PermissionRequested` o
  `DownloadStarting`, o la ausencia de `ICoreWebView2_4`, aborta el arranque de
  la vista. Principal y popouts comparten `WebViewHost`. Pruebas negativas en
  `test_app_windows.cpp` (`MainViewPolicyTests`: ajustes, un HRESULT fallido en
  cada llamada, argumentos nulos, cableado en la fuente del producto) y sonda
  CDP sobre la WebView real (`lote1-r6-bajo4-probe-*`: `alert/confirm/prompt` no
  bloquean, geolocalización → `PERMISSION_DENIED`, `Notification` → `denied`,
  la descarga termina en `canceled`, nunca `completed`).
* **BAJO-5 — escritura atómica en `doc.save`.** `confined::AtomicWrite`
  (`confined_write.hpp`) la usan `doc.save`, Guardar como, `search.replace` y
  `hunk.accept/reject`. Se conservan las garantías de confinamiento: ancestros
  retenidos sin `FILE_SHARE_DELETE`, rechazo de reparse points y hardlinks en la
  hoja existente, hoja nueva por `CREATE_NEW`. **Dos choques con el diseño
  anterior, resueltos así:** (1) los ancestros del guardado se retenían con
  `kMutationDirectoryShare` (sólo READ); renombrar dentro de ese directorio
  choca con su propio handle, de modo que el guardado usa
  `kSessionDirectoryShare` (READ|WRITE, aún sin DELETE: nadie puede renombrar o
  borrar un componente de la ruta autorizada); lo que se pierde es sólo «nadie
  añade entradas durante el guardado», irrelevante porque la hoja se reemplaza
  por nombre. (2) `MoveFileExW` clásico no puede reemplazar un archivo que otro
  proceso tiene abierto aunque comparta `DELETE` (`ERROR_ACCESS_DENIED`,
  comprobado), así que se renombra el handle del archivo ya escrito con
  `FileRenameInfoEx` (`REPLACE_IF_EXISTS | POSIX_SEMANTICS`); donde no esté
  soportado se cae a `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)`. Contenido y
  metadatos se vacían (`FlushFileBuffers`) antes del renombrado, que NTFS
  registra en su diario. **Costes aceptados:** el archivo nuevo hereda la ACL del
  directorio (se conservan oculto/sistema/archivo), no se arrastran flujos
  alternos y la fecha de creación no está garantizada, y un hardlink (rechazado de entrada) no se
  escribiría a través de él aunque cambiara tras la validación: el renombrado sólo
  reemplaza el nombre. Un guardado con el destino abierto por otro proceso sin
  `FILE_SHARE_DELETE` falla completo (`E_WRITE_INCOMPLETE`) y deja el original.
  El archivo hermano se llama `.devagents-save-<hex>.tmp` y el watcher lo omite.
  Pruebas negativas en `test_atomic_save` (`test_document_manager.cpp`):
  lector concurrente sin lecturas parciales durante 40 reemplazos de 2 MiB, sin
  restos, atributos conservados, solo lectura / destino abierto / directorio con
  el original intacto, hardlink y junction rechazados con la víctima intacta.

## Inventario completo de capacidades (161 handlers)

Todas las filas heredan la comprobación de origen HTTPS exacto en WebViewHost
y la cota de transporte de 28 MiB. FS incluye la base/catálogo propio del motor;
una lectura del catálogo no concede lectura arbitraria de archivos. Las filas
agénticas/protocolos privilegiados mantienen sus límites explícitos: la
confianza en el origen sigue siendo necesaria para terminal y ejecución de
planes. La confirmación nativa es por petición y no acepta un flag JS como
consentimiento; muestra la acción y el recurso (datos de la página neutralizados,
URL sin credenciales) y nunca secretos del payload. Sin propietario nativo se rechaza.

Las raíces de escritura se conceden al iniciar el host desde su cwd nativo,
mediante `dialog.pickWorkspace` o desde la ruta de una orden emitida por el
registro nativo del motor (`core.order.worktree`, nunca desde su payload JS). `dialog.pickFolder` concede sólo lectura.
Las listas se comparten entre ventanas mediante DocumentManager y un mutex;
los nombres del registro de handlers se inspeccionan también en ejecución.
Las lecturas de documentos se limitan a 24 MiB y fallan si son incompletas.
Un SHA de checkpoint sólo vale en el Bridge que lo emitió, durante esa sesión
y para esa raíz: cambiar de ventana/sesión requiere crear otro checkpoint.
**Compartición de los handles retenidos (ronda 4, ALTO-1).** Ningún handle de
directorio comparte DELETE: nadie puede renombrar, mover ni borrar un componente
retenido, que es lo que mantiene fija la ruta autorizada. Los handles de
**sesión** (ancestros y raíces de escritura/lectura, destinos de Guardar como,
ancestros de binarios fijados, directorio del watcher: `kSessionDirectoryShare`
en `confined_write.hpp`) comparten además WRITE, para no bloquear otros procesos
(renombrados atómicos, `git config --global`, Explorer, guardados de otros
editores); el contenido nunca se confía por nombre, porque `Validate` rechaza
reparse points y `nlink>1` en cada apertura. Sólo las ventanas **cortas** de una
mutación, lectura o ejecución de Git (`kMutationDirectoryShare`, READ) impiden
añadir o cambiar entradas. Consecuencia aceptada: un directorio retenido y vacío
puede convertirse en junction por otro proceso; el host falla cerrado en cada
uso posterior (prueba `test-doc-mgr`). Los binarios fijados conservan share READ
en el propio archivo. Desde la ronda 6 los ancestros de `doc.save` también usan el
modo de sesión (necesario para el renombrado atómico; ver BAJO-5).

`LockTree` usa el modo corto: sin share-delete todos los directorios durante
Git. Los metadatos `.git` permiten share-write para que Git actualice su
índice; el árbol de trabajo conserva sólo share-read. Todos se validan sin reparse ni
hardlinks antes de ejecutar. Git conserva acceso a sus metadatos nativos
(incluida la ruta de un worktree `.git`); no se declara un sandbox de Git.

| Método | Clasificación | Protección aplicada / límite |
|---|---|---|
| `app.exedir` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `browser.panel.toggle` | solo UI/estado; lectura FS confinada de la orden | Alterna el HWND del navegador propio; order_id opcional validado y worktree resuelto por motor y concesión de carpeta; no acepta URLs ni CDP; la página no tiene Bridge ni web messages. |
| `browser.app.register` | solo UI/estado | Solo la WebUI de confianza llega aquí. `url` de texto ≤ 8192; el host la admite solo si es http en `localhost`, `127.0.0.1` o `[::1]` con puerto (política `browser_policy.hpp`) y abre la app en la pestaña activa. No toca el ledger de sitios aprobados. |
| `browser.approval.resolve` | escritura FS (ledger DPAPI de orígenes aprobados) | `request_id` generado por el host para una petición que mostró al usuario y `allow` booleano; id desconocido, repetido o de otro ciclo se rechaza. «Sí» escribe el origen exacto con reemplazo atómico y entropía de producto; «No», cierre del panel, reinicio de la WebUI (`browser.state` con `init`) y 120 s sin respuesta equivalen a rechazar. La página no tiene Bridge: no puede ver, provocar ni responder la petición. |
| `browser.back` | solo UI/estado | Sin datos; GoBack de la pestaña activa, sujeto a la política de navegación. |
| `browser.blocked.retry` | solo UI/estado | Sin datos. Vuelve a pedir, como petición del usuario, el destino que quedó bloqueado en la pestaña activa (botón «Aprobar este origen…» de la tarjeta). No aprueba nada: abre el mismo diálogo de aprobación que `browser.navigate`; no acepta URL (usa la que el host ya tenía bloqueada) y no cambia el control del agente. |
| `browser.control` | control humano de sesión `browser.v1` | Solo `{action:"take"}` o `{action:"resume"}` desde la cabina de confianza. El host toma control local antes de retornar y envía el cambio por el carril browser; reanudar requiere la nueva época autoritativa del motor. No admite capacidad, orden, destino ni aprobación enviados por la página o el worker. |
| `browser.cover` | solo UI/estado | `on` booleano. La cabina avisa de que una capa suya (bandeja de avisos, menú, paleta, modal) pisa el rectángulo de la página nativa: el host captura la página con una operación CDP fija (`Page.captureScreenshot`, JPEG), se la entrega a la WebUI como evento `browser.cover` (imagen en memoria, no se escribe a disco ni se registra) y oculta el HWND de la página; con `on:false` lo vuelve a mostrar. No navega, no aprueba, no cambia el control del agente y no acepta método, parámetros ni ruta. La WebUI solo acepta la imagen si es `data:image/jpeg;base64` y la usa como fondo, nunca como marcado. |
| `browser.forward` | solo UI/estado | Sin datos; GoForward de la pestaña activa, sujeto a la política de navegación. |
| `browser.navigate` | solo UI/estado | `url` de texto ≤ 8192. Un origen ya permitido navega; uno nuevo no se abre: el host pide la aprobación a la WebUI (`browser.approval.resolve`) y la navegación queda bloqueada hasta el clic. Esta llamada no aprueba nada. |
| `browser.reload` | solo UI/estado | Sin datos; recarga la pestaña activa (también «Reintentar» y «Descartar» tras un bloqueo). |
| `browser.state` | solo UI/estado | `init` booleano opcional. Devuelve las pestañas, la activa, el estado de carga y las peticiones de aprobación pendientes; con `init` rechaza las que la WebUI anterior no pudo responder. Eventos del mismo estado se publican como `browser.state` desde el host. |
| `browser.stop` | solo UI/estado | Sin datos; detiene la carga de la pestaña activa. |
| `browser.tab.close` | solo UI/estado | `id` entero de una pestaña existente; cierra solo el WebView de esa pestaña y descarta sus peticiones de aprobación. |
| `browser.tab.new` | solo UI/estado | Sin datos ni destino (máximo 12 pestañas); la pestaña nace en `about:blank`. |
| `browser.tab.select` | solo UI/estado | `id` entero de una pestaña existente; solo cambia cuál se ve. |
| `cdp.dump` | escritura FS (bloqueada) | Siempre error; el puente no escribe volcados en C:\tmp ni acepta rutas de diagnóstico. `main.cpp` ya no intercepta este kind antes del despacho: la puerta `bridge_inventory.test.mjs` falla ante cualquier comparación de `kind` fuera de una lista blanca justificada. |
| `checkpoint.create` | git; lectura/escritura FS; ejecución de procesos | Raíz nativa exacta; git de instalación nativa retenida, argv fijo, LockTree retiene directorios durante Git y rechaza reparse/hardlinks antes de leer, core.worktree forzado/hooks y fsmonitor desactivados; SHA completo almacenado en memoria por raíz sólo tras éxito. |
| `checkpoint.restore` | git; escritura FS; ejecución de procesos | Raíz nativa exacta y SHA de 40/64 hex emitido por este Bridge para esa raíz; LockTree retiene directorios y rechaza reparse/hardlinks; argv estructurado, errores de proceso propagados. No recupera archivos no seguidos. |
| `core.agentic.getIterations` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.agentic.setIterations` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.approvals.pending` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.approvals.resolve` | escritura FS (estado gobernado) | IDs positivos; motor valida transición/plan/expected; scope 0..2. Estado gobernado, no ruta ni proceso arbitrario entrante. |
| `core.approvals.resolveScoped` | escritura FS (estado gobernado) | IDs positivos; motor valida transición/plan/expected; scope 0..2. Estado gobernado, no ruta ni proceso arbitrario entrante. |
| `core.artifacts.list` | lectura FS (artefactos de orden) | Motor y API disponibles; listado por ID de orden; sin rutas de lectura arbitrarias. |
| `core.audit.getModel` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.audit.setModel` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.auditChecklist` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.budget.get` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.budget.set` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.catalog.info` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.complete` | red; lectura/escritura FS (catálogo) | Motor/función disponibles; parámetros requeridos, proveedor/credenciales y presupuesto del motor; respuestas y errores propagados sin ejecución local de contenido. |
| `core.composer.review` | solo UI/estado | Sin datos en el payload; el motor devuelve un JSON fijo (`mode: undecided`, veredicto pendiente) sin leer rutas ni lanzar programas. Sin diálogo nativo. Devuelve errores si motor/API no disponibles. |
| `core.doctor` | lectura FS (carpeta de datos y catálogo); ejecución de procesos (detección de CLI, sin órdenes); red solo loopback | Sin datos en el payload. El motor comprueba carpeta de datos (crea y borra un archivo de prueba), espacio en disco, WebView2 (registro), git (PATH), CLI de terceros por la detección existente, claves activas (solo el número) y Ollama en 127.0.0.1:11434. No devuelve claves ni tokens. Sin diálogo nativo. Devuelve errores si motor/API no disponibles. |
| `core.update.state` | lectura FS (catálogo) | Sin datos en el payload. Estado del actualizador guardado en `settings` (última comprobación, versión preparada, consentimiento). Sin red. Devuelve errores si motor/API no disponibles. |
| `core.update.check` | red (solo `api.github.com`, GET sin datos del usuario); escritura FS (catálogo) | Payload: `force` (bool). Desactivado en Ajustes no sale a la red; sin `force` no repite antes de 24 h. La única URL es la fija del repositorio de publicación; User-Agent fijo `DevAgents-updater`, sin identificadores. El texto de GitHub vuelve como datos y la cabina lo pinta como texto. |
| `core.update.download` | red (assets del repositorio de publicación, saltos filtrados por `publicHost`); escritura FS (`<datos>\updates\<versión>\`) | Sin datos en el payload: el motor solo baja las URL que su última comprobación guardó y que empiezan por `https://github.com/ItlaStudent/DevAgents/releases/download/`. Huella SHA-256 obligatoria (si no coincide, se borra) y firma Authenticode (inválida: se borra). No ejecuta nada. |
| `core.update.setEnabled` | escritura FS (catálogo) | Payload: `enabled` (bool; ausente = `false`). Solo cambia el ajuste `update_check_enabled`. |
| `core.update.applyOnExit` | escritura FS (catálogo) | Payload: `apply` (bool) y `unverified` (bool, T12 M3). Consentimiento del usuario para instalar al cerrar; sin nada descargado, error. Sin firma Authenticode verificable del editor esperado, el motor rechaza `apply` a secas y exige `unverified:true`, que la cabina solo manda desde el botón «Instalar al cerrar sin firma verificable». El host aplica solo al cerrar, sin órdenes en curso, con el instalador dentro de `<datos>\updates\` (ruta final, sin enlaces) y tras recalcular la huella con el archivo bloqueado justo antes de lanzarlo (`da_update_pending_apply_json`, `OpenVerifiedInstaller`). |
| `core.project.rules.get` | lectura FS (catálogo; las reglas del repositorio/las reglas del repositorio de la carpeta del proyecto elegida) | Sin datos en el payload. Devuelve las reglas vigentes del proyecto abierto, las de DevAgents por defecto y qué documentos del proyecto mandan sobre ellas (solo nombres). Sin red ni procesos. |
| `core.project.rules.set` | escritura FS (catálogo) | Payload: `rules` (texto, máx. 16 KiB, UTF-8 sin nulos) o `reset` (bool). El host reconstruye un JSON canónico; el motor guarda por carpeta de proyecto y lo rechaza en un núcleo con superficie MCP. Sin rutas ni argv. |
| `core.cliAccounts.list` | lectura FS (catálogo) | Sin datos en el payload. Cuentas por CLI (id, nombre, carpeta bajo `<datos>\cli-accounts`, comando de inicio de sesión) y CLIs no admitidas con el motivo. Nunca credenciales. |
| `core.cliAccounts.add` | escritura FS (catálogo; crea `<datos>\cli-accounts\<cli>\<id>`) | Payload: `cli` (solo `codex` o `claude-code`) y `label` (1-40 caracteres, sin comillas ni metacaracteres de cmd). JSON canónico del host; la ruta la elige el motor. No inicia sesión ni lanza procesos; rechazado en núcleo MCP. |
| `core.cliAccounts.remove` | escritura FS (catálogo; borra la carpeta de la cuenta) | Payload: `id`. El motor solo borra carpetas bajo `<datos>\cli-accounts`; la carpeta por defecto de la CLI nunca se toca. Rechazado en núcleo MCP. |
| `core.cliAccounts.select` | escritura FS (catálogo) | Payload: `cli` e `id` (vacío = login del sistema). El motor valida que la cuenta exista y sea de esa CLI. Rechazado en núcleo MCP. |
| `core.escalations` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.evolution` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.exec.getModel` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.exec.setModel` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.external.agents` | lectura/escritura FS; ejecución de procesos (detección) | Registro/rutas de agentes del motor (cambios de rutas requieren confirmación nativa); detección nativa. No ejecutable/argv directo en payload. |
| `core.external.limits.get` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.external.limits.set` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.external.options.set` | escritura FS; ejecución de procesos (configuración privilegiada) | Confirmación nativa obligatoria; payload/config validado por motor. Configurar comandos/rutas no equivale a confinarlos. |
| `core.external.paths.get` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.external.paths.set` | escritura FS; ejecución de procesos (configuración privilegiada) | Confirmación nativa obligatoria; payload/config validado por motor. Configurar comandos/rutas no equivale a confinarlos. |
| `core.external.refresh` | lectura/escritura FS; ejecución de procesos (detección) | Registro/rutas de agentes del motor (cambios de rutas requieren confirmación nativa); detección nativa. No ejecutable/argv directo en payload. |
| `core.git.storeCredential` | git; ejecución de procesos; escritura FS | Confirmación nativa obligatoria; motor valida URL/credencial y entrega secreto a git por stdin, no argv. |
| `core.git.branch` | git; lectura FS | Root del workspace autorizado por el host; comando fijo y ruta canónica. |
| `core.git.status` | git; lectura FS | Root autorizado por el host; estado git con comando fijo. |
| `core.git.init` | git; escritura FS | Root autorizado, `git init` con comando fijo solo si aún no es repositorio; git con `core.hooksPath=NUL`. Sin diálogo nativo desde (fuera de `RequiresNativeConsent`, `shell/host/bridge.cpp:371-375`). |
| `core.git.commit` | git; escritura FS | Root autorizado, mensaje como dato, lista exacta de archivos confinada a la raíz; git con `core.hooksPath=NUL`, sin shell arbitrario. Sin diálogo nativo desde (fuera de `RequiresNativeConsent`, `shell/host/bridge.cpp:371-375`); la confirmación la da el modal de la cabina. |
| `core.governance.get` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `core.governance.set` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.health` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.health.detail` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.health.probe` | red; lectura/escritura FS (catálogo) | Motor/función disponibles; parámetros requeridos, proveedor/credenciales y presupuesto del motor; respuestas y errores propagados sin ejecución local de contenido. |
| `core.hooks.set` | escritura FS; ejecución de procesos (configuración privilegiada) | Confirmación nativa obligatoria; payload/config validado por motor. Configurar comandos/rutas no equivale a confinarlos. |
| `core.inventory` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.inventory.refresh` | lectura/escritura FS; ejecución de procesos (detección) | Registro/rutas de agentes del motor (cambios de rutas requieren confirmación nativa); detección nativa. No ejecutable/argv directo en payload. |
| `core.issues.comment` | red; escritura FS (catálogo) | Confirmación nativa obligatoria y explicit=true; payload ≤65536; motor valida forge/repo/ID. El flag de UI por sí solo no concede autorización. |
| `core.issues.list` | red; lectura FS (catálogo) | Payload ≤65536; motor valida forge/repo/ID, respuestas externas no confiables y errores saneados. |
| `core.issues.prompt` | red; lectura FS (catálogo) | Payload ≤65536; motor valida forge/repo/ID, respuestas externas no confiables y errores saneados. |
| `core.issues.read` | red; lectura FS (catálogo) | Payload ≤65536; motor valida forge/repo/ID, respuestas externas no confiables y errores saneados. |
| `core.keys.add` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.keys.list` | lectura FS (metadatos de credenciales) | Catálogo elegido por host; keysJson sólo selecciona proveedor, etiqueta, estado, prioridad y cuotas/uso, nunca el secreto. Devuelve errores si motor/API no disponibles. |
| `core.keys.remove` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.keys.setMeta` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.ledger` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.mcp.authToken` | lectura FS (secreto del host) | Confirmación nativa obligatoria antes de revelar token; ningún payload se muestra en la confirmación/log. |
| `core.mcp.call` | ejecución de procesos; red; lectura/escritura FS (privilegiada) | Confirmación nativa obligatoria por petición; sin HWND/error si cancelada. Motor valida protocolo/argv; MCP es una capacidad arbitraria autorizada, no un sandbox. |
| `core.mcp.connect` | ejecución de procesos; red; lectura/escritura FS (privilegiada) | Confirmación nativa obligatoria por petición; sin HWND/error si cancelada. Motor valida protocolo/argv; MCP es una capacidad arbitraria autorizada, no un sandbox. |
| `core.mcp.disconnect` | ejecución de procesos; solo UI/estado | Sólo cliente MCP conectado por el motor, no PID enviado por JS. |
| `core.mcp.status` | solo UI/estado | Motor/handle del cliente MCP propio; sin ruta/programa arbitrario entrante. |
| `core.mcp.tools` | solo UI/estado | Motor/handle del cliente MCP propio; sin ruta/programa arbitrario entrante. |
| `core.memory` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.model.register` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.model.scores` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.model.setFavorite` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.models.discover` | red; lectura/escritura FS (catálogo) | Motor/función disponibles; parámetros requeridos, proveedor/credenciales y presupuesto del motor; respuestas y errores propagados sin ejecución local de contenido. |
| `core.models.list` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.models.selection.v1` | lectura FS (catálogo) | Metadatos de texto, gratuidad y permisos por identidad; sin claves ni sondeos de red. |
| `core.models.preferences.set.v1` | lectura/escritura FS (catálogo) | JSON v1 acotado; dos booleanos y modelo conocido; SQL enlazado, transacción y preflight con aviso de auditor independiente. Conserva los pines manuales. |
| `core.mount.add` | lectura FS; escritura FS (catálogo) | Guarda común: directorio de lectura concedido, padres/leaf retenidos; selección nativa previa; motor valida y persiste montaje. |
| `core.mount.remove` | escritura FS (catálogo) | Motor elimina registro del montaje indicado; no escribe/borrar archivos en la ruta enviada. |
| `core.mounts.list` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.onboarding.done` | solo UI/estado; escritura FS (configuración del motor) | Sin datos en el payload; el motor marca el primer arranque como visto en su propio almacén. Sin diálogo nativo, sin rutas ni programas entrantes. Devuelve errores si motor/API no disponibles. |
| `core.onboarding.state` | lectura FS (catálogo/estado del host) | Sin datos en el payload; devuelve `{"done","has_usage"}` del motor. Sin diálogo nativo ni ruta arbitraria de lectura. Devuelve errores si motor/API no disponibles. |
| `core.order.answer` | red; escritura FS (órdenes) | Entradas requeridas/IDs, imágenes y plan validados por C-ABI; proveedor/presupuesto/estado del motor. fromIssue limita request/text; no FS arbitrario por ruta del mensaje. |
| `core.order.approve` | escritura FS (estado gobernado) | IDs positivos; motor valida transición/plan/expected; scope 0..2. Estado gobernado, no ruta ni proceso arbitrario entrante. |
| `core.order.attachments` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.order.bestOfNCandidates` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.order.bestOfNChoose` | git; lectura/escritura FS; ejecución de procesos | IDs/nombre del registro del motor; spaces/worktrees y estados gobernados por motor desde raíz elegida y autorizada. No ruta entrante directa. |
| `core.order.cancel` | solo UI/estado; escritura FS (estado del motor) | IDs del motor; cancela orden/plan o reconoce acción, sin PID/ruta arbitraria. |
| `core.order.dispatch` | git; red; ejecución de procesos; lectura/escritura FS (agéntica) | ID positivo del motor; plan aprobado/estado, permisos y presupuesto en motor. Workspace sólo se cambia a raíz nativa; ejecución agéntica autorizada no es sandbox del puente. |
| `core.order.events` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.order.expected` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.order.fromIssue` | red; escritura FS (órdenes) | Entradas requeridas/IDs, imágenes y plan validados por C-ABI; proveedor/presupuesto/estado del motor. fromIssue limita request/text; no FS arbitrario por ruta del mensaje. |
| `core.order.plan` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.order.plan.set` | escritura FS (estado gobernado) | IDs positivos; motor valida transición/plan/expected; scope 0..2. Estado gobernado, no ruta ni proceso arbitrario entrante. |
| `core.order.pollDispatch` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.order.pollPlan` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.order.preflight` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.order.replan` | red; escritura de metadatos (orden/plan) | ID positivo y cambios de 1..16384 bytes; C-ABI exige planned/clarifying y planificador libre. Reutiliza la orden con wait_for_plan_approval, crea una revisión no aprobada y no despacha workers ni ejecuta el plan. |
| `core.order.resume` | git; red; ejecución de procesos; lectura/escritura FS (agéntica) | ID positivo del motor; plan aprobado/estado, permisos y presupuesto en motor. Workspace sólo se cambia a raíz nativa; ejecución agéntica autorizada no es sandbox del puente. |
| `core.order.setExpected` | escritura FS (estado gobernado) | IDs positivos; motor valida transición/plan/expected; scope 0..2. Estado gobernado, no ruta ni proceso arbitrario entrante. |
| `core.order.ship` | git; red; escritura FS; ejecución de procesos | Confirmación nativa obligatoria; ID positivo, estado/registro de PR u orden del motor y políticas de ship; no root/PID entrante. |
| `core.order.status` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.order.submit` | red; escritura FS (órdenes) | Entradas requeridas/IDs, imágenes y plan validados por C-ABI; proveedor/presupuesto/estado del motor. fromIssue limita request/text; no FS arbitrario por ruta del mensaje. |
| `core.order.worktree` | lectura FS; solo UI/estado (concesión nativa) | ID positivo; ruta devuelta por el registro nativo de órdenes, nunca desde JS. Sólo se concede escritura si la orden se creó en esta sesión (`core.order.submit`/`fromIssue`, registro común a todas las ventanas) o la carpeta ya cuelga de una raíz concedida (incluye `<raíz>\.beats\spaces`); si no, error `E_ORDER_ROOT_NOT_GRANTED` y hay que elegirla con `dialog.pickWorkspace`. AuthorizeWorkspaceRoot valida y retiene ancestros. |
| `core.permissions.forgetElevated` | solo UI/estado; escritura FS (estado del host) | Sin datos en el payload. Solo borra el recuerdo de Auto y Omitir en `<datos>\permisos-modos-habilitados.txt` (endurece: la próxima elevación vuelve a pedir confirmación); no cambia el modo vigente del motor. Sin diálogo nativo. |
| `core.permissions.get` | solo UI/estado | Sin datos en el payload; lectura sin privilegio de la configuración de permisos vigente del motor (modo y listas). No cambia nada y no pide diálogo nativo. Devuelve errores si motor/API no disponibles. |
| `core.permissions.set` | solo UI/estado (permisos privilegiados) | Confirmación nativa obligatoria antes de cambiar permisos; configJson validado por motor. |
| `core.plan.cancel` | solo UI/estado; escritura FS (estado del motor) | IDs del motor; cancela orden/plan o reconoce acción, sin PID/ruta arbitraria. |
| `core.plan.getDeterministic` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.plan.getDirect` | solo UI/estado | Sin datos en el payload; devuelve `{"enabled","delegate"}` del modo Directo del motor. Sin diálogo nativo, sin rutas ni programas entrantes. |
| `core.plan.getModel` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.plan.setDeterministic` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.plan.setDirect` | solo UI/estado (estado en memoria del motor) | Solo dos booleanos (`enabled`, `delegate`); el host los reduce a 0, 1 o 2 antes de llamar al motor, que lo guarda en memoria. Sin rutas, argv ni diálogo nativo. |
| `core.plan.setModel` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.plugin.trust` | lectura/escritura FS; ejecución de procesos | Confirmación nativa obligatoria; plugin_loader valida ABI y ancla hash; cargar un plugin autorizado es privilegiado. |
| `core.plugin.untrust` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.plugins.dir` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.plugins.list` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.pr.merge` | git; red; escritura FS; ejecución de procesos | Confirmación nativa obligatoria; ID positivo, estado/registro de PR u orden del motor y políticas de ship; no root/PID entrante. |
| `core.provider.add` | escritura FS (catálogo); red (configuración) | Confirmación nativa obligatoria para configurar destino; motor valida estructura/URL y persiste configuración. |
| `core.providers.list` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.prs.list` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.reasoningEffort.set` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.remote.start` | red; ejecución de procesos; escritura FS | Confirmación nativa obligatoria; RemoteController valida opciones, binario hermano/hashes, job y pipe ACL/PID; HTTP en hijo, token/origen en motor. |
| `core.remote.status` | solo UI/estado | Estado del broker nativo, sin entrada que seleccione proceso o ruta. |
| `core.remote.stop` | ejecución de procesos; solo UI/estado | Sólo proceso/job remoto que pertenece al host, con cierre del broker/pipe. |
| `core.repo.clone` | git; red; lectura/escritura FS; ejecución de procesos | targetDir dentro de raíz de escritura concedida; padres y destino retenidos, creación por handle confinado; rechaza junction en destino. HTTPS sin credenciales (rechaza opciones, file, SSH y ext::) y confirmación nativa antes del motor; cloneRepo usa argv estructurado. |
| `core.roles.getModels` | solo UI/estado | Sin datos en el payload; devuelve los pines de modelo por rol guardados en el catálogo del motor. Sin diálogo nativo, sin rutas ni programas entrantes. Devuelve errores si motor/API no disponibles. |
| `core.roles.setModel` | solo UI/estado; escritura FS (configuración del motor) | `role`, `provider`, `model` como datos; el motor valida el rol contra su lista cerrada, exige proveedor y modelo juntos (o ambos vacíos para quitar el pin), longitudes y UTF-8, y que el modelo sea de chat en el catálogo o en la detección de CLIs. Sin rutas, argv ni diálogo nativo. |
| `core.router.candidates` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.screenshot` | lectura/escritura FS (pantalla) | Confirmación nativa obligatoria; motor elige destino nativo, JS no elige ruta. |
| `core.session.archive` | escritura de estado reversible | C-ABI sobre orderId positivo y archived 0/1; el motor excluye internas y estados vivos. No borra datos. |
| `core.session.archiveBefore` | escritura de estado reversible | Fecha epoch positiva, confirmed explícito y expectedCount; el motor comprueba el recuento dentro de la transacción, excluye internas y hilos vivos/recientes. |
| `core.session.archiveBefore.preview` | lectura de estado | Cuenta sesiones elegibles antes de una fecha epoch positiva sin escribir; mismo predicado que el archivado. |
| `core.session.delete` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.session.messages` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.session.messages.v2` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.session.rename` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.sessions.list` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.skills` | lectura FS | Motor descubre skills en montajes registrados; añadir montajes exige raíz de lectura concedida; sin ruta arbitraria entrante. |
| `core.space.archive` | git; lectura/escritura FS; ejecución de procesos | IDs/nombre del registro del motor; spaces/worktrees y estados gobernados por motor desde raíz elegida y autorizada. No ruta entrante directa. |
| `core.space.create` | git; lectura/escritura FS; ejecución de procesos | Motor valida nombre ASCII de 1..64 (alfanumérico inicial, resto alfanumérico/-/_; sin alias DOS), kind cerrado y base nativa; confined_fs valida padres/destino. No ruta entrante directa. |
| `core.spaces.list` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.spaces.prune` | git; lectura/escritura FS; ejecución de procesos | IDs/nombre del registro del motor; spaces/worktrees y estados gobernados por motor desde raíz elegida y autorizada. No ruta entrante directa. |
| `core.specialists` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.status` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `core.swarm.getEnabled` | solo UI/estado | Sin datos en el payload; devuelve si el enjambre está activado en el catálogo del motor. Sin diálogo nativo, sin rutas ni programas entrantes. |
| `core.swarm.getModels` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.swarm.setEnabled` | solo UI/estado; escritura FS (configuración del motor) | Un solo booleano (`enabled`) guardado en el catálogo del motor. Sin rutas, argv ni diálogo nativo. |
| `core.swarm.setModels` | solo UI/estado; escritura FS (configuración del motor) | Enum/límites/modelos/config validados por motor; presupuesto >=0, governance enum cerrado; sin rutas ni argv arbitrarios. |
| `core.ui.ack` | solo UI/estado; escritura FS (estado del motor) | IDs del motor; cancela orden/plan o reconoce acción, sin PID/ruta arbitraria. |
| `core.ui.actions` | solo UI/estado | Estado/configuración del motor propio; no ruta ni programa entrante; preflight no despacha una orden. |
| `core.usage` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.usage.week` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `core.vision.probe` | red; lectura/escritura FS (catálogo) | Motor/función disponibles; parámetros requeridos, proveedor/credenciales y presupuesto del motor; respuestas y errores propagados sin ejecución local de contenido. |
| `core.webhooks.add` | escritura FS (catálogo); red (configuración) | Confirmación nativa obligatoria para configurar destino; motor valida estructura/URL y persiste configuración. |
| `core.webhooks.delete` | escritura FS (catálogo) | ID entero positivo; claves exactas/Parser sin duplicados; sólo elimina registro del motor. |
| `core.webhooks.list` | lectura/escritura FS (catálogo) | Handle/ruta de catálogo del host; campos/IDs requeridos validados por motor; sin ruta de FS elegida por JS. keys.remove exige label o allowAll explícito; plugin.untrust revoca confianza. |
| `core.webhooks.test` | red | Confirmación nativa obligatoria; ID entero positivo/estructura estricta; motor usa sólo webhook registrado. |
| `core.websearch` | red; lectura/escritura FS (catálogo) | Motor/función disponibles; parámetros requeridos, proveedor/credenciales y presupuesto del motor; respuestas y errores propagados sin ejecución local de contenido. |
| `core.workspace.restorePermissions` | escritura FS (ACL del espacio de la orden) | Confirmación nativa obligatoria por petición (el flag `explicit` de JS no cuenta como consentimiento); orderId positivo. El motor toma la raíz del evento `external_agent_finished` de una orden fallida, exige que esté gobernada y que conserve la misma identidad, y restaura su propio snapshot con auditoría previa; sin ruta, SDDL ni argv en el payload. |
| `core.process.control` | solo UI/estado | Consulta la salida acotada o detiene el árbol de un proceso gobernado mediante su identificador opaco y generación. No recibe rutas, PID ni un comando. |
| `core.workspace.set` | solo UI/estado | Guarda común: raíz exacta previamente concedida por host. El mensaje no concede autoridad de FS. |
| `core.worktree.config` | lectura FS (catálogo/estado del host) | C-ABI sobre handle/rutas elegidos por host; IDs/params requeridos; sin ruta arbitraria de lectura en payload. Devuelve errores si motor/API no disponibles. |
| `dialog.pickFolder` | solo UI/estado; lectura FS | Selección nativa; AuthorizeReadRoot retiene ancestros y concede sólo lectura. Nunca concede escritura. |
| `dialog.pickWorkspace` | solo UI/estado; lectura FS | Diálogo nativo con título del host; concede raíz de lectura/escritura reteniendo todos sus ancestros, sin reparse. |
| `dialog.saveAs` | solo UI/estado; escritura FS | Diálogo nativo, ruta exacta y token CSPRNG de un uso; consume también el intento fallido y retiene ancestros. |
| `doc.open` | lectura FS | ReadWorkspaceFile: raíz concedida, ancestros retenidos, leaf OPEN_REPARSE_POINT validado; rechaza hardlinks y lectura incompleta. |
| `doc.save` | escritura FS | WriteAuthorizedFile: raíz nativa o token Save As exacto; escritura atómica (archivo hermano validado por handle + renombrado POSIX sobre el destino, `AtomicWrite`); hoja con reparse point/hardlink/solo lectura rechazada y la víctima no se toca; error si escritura incompleta, con el original intacto y sin archivo hermano. |
| `fs.createFile` | escritura FS | CreateWorkspaceEntry: raíz de escritura; CREATE_NEW con padres retenidos y handle validado; WriteComplete + flush; no éxito parcial. |
| `fs.list` | lectura FS | LockReadDirectory: raíz de lectura/escritura concedida; ancestros/leaf retenidos durante enumeración; omite reparse; comprueba fin de listado. |
| `fs.mkdir` | escritura FS | CreateWorkspaceEntry: raíz de escritura; NtCreateFile FILE_CREATE relativo al handle padre retenido; valida handle nuevo; no sobrescribe. |
| `fs.unwatch` | solo UI/estado | Detiene sólo el watcher del host y libera sus handles. |
| `fs.watch` | lectura FS | Raíz concedida antes de StartWatching; mantiene ancestros y handle validado hasta unwatch, con share READ|WRITE sin DELETE (no bloquea renombrados de otros procesos ni permite mover el componente). |
| `hunk.accept` | escritura FS | WriteWorkspaceFile comparte autoridad y writer de doc.save; hash y resultado de escritura comprobados; sin token Save As. |
| `hunk.reject` | escritura FS | WriteWorkspaceFile comparte autoridad y writer de doc.save; hash y resultado de escritura comprobados; sin token Save As. |
| `init` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `lsp.request` | ejecución de procesos; lectura FS (privilegiada) | Registro nativo de LSP y confirmación nativa por petición; ejecutable absoluto retenido, sin comandos/args en serverCmd. Consentir LSP no implica sandbox de sus params. |
| `notifications.status` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `opendesign.launch` | ejecución de procesos; red local | wsl.exe absoluto de System32; distro [A-Za-z0-9_.-], directorio POSIX absoluto sin metacaracteres/traversal; --cd y argv fijo /usr/bin/env pnpm tools-dev; sin shell interpolado. Sin DIR configurado obtiene HOME mediante printenv (argv fijo), valida la ruta y conserva HOME/open-design. |
| `ping` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `pty.kill` | ejecución de procesos | Sólo cierra una terminal por ID del registro de PtyManager; no acepta PID arbitrario. |
| `pty.read` | solo UI/estado | Scrollback del terminal propio/ID del host; offset saneado y tamaño 2..1000 columnas, 1..1000 filas. |
| `pty.resize` | solo UI/estado | Scrollback del terminal propio/ID del host; offset saneado y tamaño 2..1000 columnas, 1..1000 filas. |
| `pty.spawn` | ejecución de procesos | Ejecutable absoluto del registro nativo de shells, retenido; cwd concedido. Capacidad privilegiada: la terminal ejecuta comandos con permisos del usuario. |
| `pty.write` | ejecución de procesos (privilegiada residual) | Sólo terminal creada por PtyManager e ID del host; origen confiable. Entrada libre por diseño: no es sandbox; un XSS confiable hereda ejecución. |
| `search.embedIndex` | lectura/escritura FS; red | Guarda común de raíz nativa exacta; motor gestiona índice y presupuesto/credenciales; ninguna raíz implícita del motor sustituye el grant. |
| `search.embedStatus` | lectura FS | Guarda común de raíz nativa exacta; estado del índice desde motor. |
| `search.query` | lectura FS; red en modo semantic/hybrid | Guarda común exige raíz nativa exacta en todos los modos. Texto: enumeración/lectura confinadas, sin reparse/hardlinks. Ranking: motor con raíz validada; embeddings bajo presupuesto del motor. |
| `search.replace` | lectura/escritura FS | Raíz exacta concedida; lectura confinada y WriteWorkspaceFile; errores explícitos. Operación de varios archivos no transaccional. |
| `shell.open` | apertura externa | Parser URI: HTTPS o HTTP loopback literal (Open Design), sin credenciales/control/protocolos ejecutables. Las rutas locales sólo se revelan con `explorer.exe /select,` (nunca se ejecutan) y deben cumplir `confined::Absolute` (`CanonicalRevealPath`): unidad + ruta sin `.`/`..`, sin nombres de dispositivo Win32 (NUL, CON, PRN, AUX, COMn, LPTn), sin flujos alternos, sin UNC ni espacios `\\?\`/`\\.\`, sin punto/espacio final; se pasa a Explorer la ruta normalizada. No exige raíz concedida: los flujos legítimos revelan capturas y rutas de diagnóstico fuera del espacio. |
| `system.keep_awake` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `window.close` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `window.command` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `window.list` | solo UI/estado | Estado del host; no ruta ni programa elegible por JS; comandos/IDs de ventanas limitados. |
| `window.open` | solo UI/estado; lectura FS para preview | ParseOpenWindow: vistas/argumentos conocidos; preview desde worktree del motor, SafeTree y WebView aislada sin Bridge; editor vuelve a doc.open. |

La lista blanca independiente vive en `shell/webui/tests/bridge_inventory.test.mjs`
y `shell/host/test_bridge_inventory.hpp`. La primera recorre los registros de
todos los fuentes/cabeceras C++ productivos del host de forma recursiva, expande la macro conocida y bucles e identifica
expresiones desconocidas como fallo; exige paridad exacta con esta tabla. La
segunda compara los 151 nombres del registro de Bridge con el registro vivo (los otros 10 de los 161 se registran en main.cpp/app_windows y los cubre la prueba WebUI) tras BindServices. Añadir
un handler exige revisar tabla y ambas listas, no actualizar un snapshot automático.

La CSP permite `data:` en imágenes y fuentes (Codicon empaquetado por Monaco),
nunca en `script-src`. CDP exige que Codicon cargue realmente, además de probar
los bloqueos de scripts inline, frames ajenos y protocolos ejecutables.
