# Multiventana del host (E5.21)

Una `AppWindow` = `Window` nativa + `WebViewHost` propio + `Bridge` propio.
Todas viven en **un mismo proceso** y comparten los servicios de proceso.
`WindowSupervisor` (en `shell/host/app_windows.*`) es el registro: asigna
`id`, enruta por `HWND`, difunde y persiste el layout.

## Reglas de hilo

- **Toda mutación del registro corre en el hilo de UI.** Crear ventana,
  destruirla, difundir: solo ahí. Las colas del motor entregan al bucle por
  `PostMessageW(hwnd, WM_BEATS_ENGINE_RESPONSE, …)` dirigido al HWND de la
  ventana que pidió — el bucle resuelve `ByHwnd` y entrega a SU WebView.
- **`m_byHwnd` es de solo lectura tras el alta.** Los workers del motor pueden
  consultarlo mientras una ventana se cierra: si el HWND ya no está, la
  respuesta se descarta. Nunca queda un puntero a un `AppWindow` borrado.
- **Un `Bridge` por ventana.** Los handlers capturan el HWND de SU ventana:
  `window.command` arrastra/minimiza/cierra la propia, `dialog.pickFolder` es
  modal de la propia. Los servicios que recibe (`BindServices`) son los mismos
  objetos de proceso.

## Servicios compartidos — revisión de seguridad entre hilos

| Servicio | Quién lo toca | ¿Seguro? |
|---|---|---|
| `CoreClient` | workers rápido+lento vía `core.*` | Sí: el C API de `devagents_core.dll` ya serializa con sus mutex (la dualidad de colas existe desde H4b). |
| `DocumentManager` | hilo UI (handlers `doc.*` de cualquier ventana) + `DirtyPaths()` en `WM_CLOSE` de la principal | Sí: todo en hilo UI. Un `doc.save` en W2 emite `doc.saved` que llega también a W1. |
| `FileWatcher` | `fs.watch` en hilo UI; su **callback corre en el hilo del watcher** | Sí: el callback solo llama al sink del puente, que postea `WM_BEATS_ENGINE_PUSH` a la cola de UI — nunca toca el WebView directamente. |
| `ProjectSearch` | carril lento (`search.*` en cola) | Sí: peticiones serializadas en el worker lento. |
| `HunkManager` | hilo UI | Sí. |
| `PtyManager` | hilo UI | Sí. La terminal de W2 es un PTY más del mismo gestor — salidas llegan a SU ventana por el `id` del puente. |
| `LspClient` | hilo UI | Sí. |
| `WebViewHost` | hilo UI (controller/WebView son STA) | Sí: cada uno solo vive en el hilo UI. La recuperación de crash resuelve el host por `m_parentHwnd` — antes un puntero global único habría recargado la ventana equivocada. |
| `EngineSupervisor` | main.cpp | Sin cambios. E4.2 (reposición del motor por ventana) sigue DIFERIDO: el motor vive en proceso; una caída de `devagents_core.dll` tumba el proceso entero, no una ventana. |

## Difusión

`Bridge::EmitEvent(topic, payload)` → sink del host → `PostMessageW`
`WM_BEATS_ENGINE_PUSH` a la principal → `supervisor.Broadcast` → todas las
ventanas. Se difunden: `doc.saved`, `fs.changed`. Sesiones/órdenes/tema ya
llegan por sondeo de la WebUI en cada ventana (E5.22).

## Ventanas secundarias

- `window.open {vista: editor|terminal|conversacion|monitor, path?, order_id?}`
  — validado por `ParseOpenWindow` (vista conocida, params requeridos,
  caracteres que romperían la URL rechazados). El host compone
  `?ventana=<id>&vista=<…>&path=<…>&order=<…>` y navega a `dist` con ella.
- `window.close {window_id}` — solo secundarias; la principal se cierra con
  WM_CLOSE normal.
- `window.list` — inventario con `id`, `primary`, `vista`, `focused`.
- `ui_action open_window` — paridad motor/cabina/puente/MCP (allowlist
  `executor.UI_ACTIONS`, `ui_actions.ts`, `mcp_server.zig`).

## Modo secundario de la WebUI (E5.22)

- `window_mode.ts` lee `?ventana=<id>&vista=<vista>` una vez al arrancar. Con
  `vista` válida la cabina arranca entera (puente, paneles, listeners) y al
  final **mueve** el panel pedido a `#ventana-unica` (fixed inset:0) y oculta
  `.app-shell`. Se mueve, no se reconstruye: el transcript del chat, la sesión
  ConPTY y el modelo de Monaco conservan su estado y sus ResizeObserver.
- La `.titlebar` viaja al host aislado: es el marco sin ventana de Win32 —
  sin ella la secundaria no se podía arrastrar, minimizar ni cerrar.
- En secundaria se desactivan: el onboarding automático y el sondeo de
  `uiActions` (dos ventanas ackeando la misma acción es una carrera — el
  sondeo queda solo en la principal). Los `ui_action` por orden de esa ventana
  siguen llegando por `handleOrderEvent`.
- Vista desconocida o panel inexistente → `empty-state` con el motivo, nunca
  una ventana en blanco muda.
- «Abrir en ventana nueva» se ofrece en: el ⧉ de cada pestaña de archivo
  (`TabManager.onTabPopout` → `window.open editor+path`), el ⧉ del panel
  inferior (terminal), y los ⧉ de las cabeceras de Actividad (conversación,
  lleva el `order_id` vigente) y Monitor.

## Persistencia y cierre

- `%LOCALAPPDATA%\DevAgents\windows.ini` — una línea por secundaria:
  `id|x|y|w|h|max|vista|path|order`. `SaveLayout` corre en
  `OnWindowDestroyed` ANTES de `CloseSecondaries` (con las ventanas vivas,
  para que `GetWindowPlacement` lea la geometría real). Al arrancar,
  `LoadSecondaryViews` reabre cada una con su vista, posición y tamaño.
- La geometría de la principal sigue en `window_geometry.ini` (formato
  histórico, foto tomada en `WM_DESTROY`).
- **Cerrar la principal**: `WM_CLOSE` → si `DocumentManager::DirtyPaths()` no
  está vacío, `MessageBox` nativo de confirmación (la WebUI puede no estar
  respondiendo justo cuando el usuario quiere salir). Si se confirma,
  `WM_DESTROY` → `OnWindowDestroyed` → `SaveLayout` → `CloseSecondaries()` →
  `PostQuitMessage`. Una secundaria cierra sin arrastrar nada.
- **Reentrada de WM_DESTROY** (medido 26-09): el `HWND` se conserva durante
  `m_onDestroy` — `ByHwnd` lo necesita para encontrar la ventana y postear el
  quit. La reentrada la corta `m_inDestroy`: el `~Window` que corre dentro
  del callback (al borrarse el `AppWindow`) se salta el segundo
  `DestroyWindow`. Antes de esto, cerrar la principal dejaba el proceso vivo
  sin ventanas para siempre.
- `ParseOpenWindow` también rechaza caracteres de control (<0x20) en `path`:
  un `\b` mal escapado navegaba a una URL con `%08` incrustado.
- DPI por monitor: `PerMonitorV2` en `devagents.manifest` + `WM_DPICHANGED`
  ya existentes — cada ventana reajusta su WebView con el DPI de SU monitor.

## Nota E4.9 (tablero V1)

E4.9 quedó encadenado a E4.2 porque «sin supervisor en host no hay reposición
del motor en la 2ª ventana». En E5.21 todas las ventanas comparten el motor
del proceso, así que reposición por ventana no aplica: la dependencia real
era el **registro de ventanas** (hecho aquí) y el enrutado por HWND (hecho).
La reposición del motor en caliente sigue siendo deuda de E4.2.
