# ADR-B002 — Cabina de escritorio nativa: C++ Win32 + WebView2 del sistema

**Estado**: Aceptada · **Fecha**: 2026-07-30 · **Decide**: usuario (propietario del proyecto)
**Depende de**: ADR-B001

## Contexto

Eliminado el fork (ADR-B001), hay que decidir qué sostiene la UI. Restricciones:

- La constitución manda C, C++ y Zig, y prohíbe runtimes pesados empaquetados.
- Existen **63 archivos TypeScript** de UI ya construidos y probados (chat, mission control,
  catálogo, verificación, sesiones, memoria, especialistas, ajustes unificados, canvas, aprobaciones).
  Tirarlos cuesta meses.
- El producto debe verse y comportarse como un IDE profesional, no como una página web.
- El usuario ya validó este patrón en `Proyecto - PhyllusMed`: ejecutable de escritorio de 22 MB con
  ventana propia, construido sobre WebView2 (vía Tauri). Su valoración: *"el ejecutable es
  tremendamente funcional"*.

## Decisión

La cabina es un ejecutable **C++ nativo** (`DevAgentsBeats.exe`) que:

1. Crea y gestiona su propia ventana **Win32** (sin borde, con hit-testing de barra de título propia,
   DPI-aware, multi-monitor, geometría persistida).
2. Hospeda el **WebView2** del sistema operativo como superficie de renderizado de los paneles.
3. Implementa nativamente todo lo que no es renderizado: menús, tray, notificaciones, diálogos de
   archivo (`IFileOpenDialog`), terminales (**ConPTY**), watcher de archivos
   (`ReadDirectoryChangesW`), keep-awake (`SetThreadExecutionState`), aceleradores y auto-updater.
4. Habla con el motor por la **C-ABI** (`devagents_core.h`) y con el WebView por un puente
   `postMessage` con validación de esquema en el host.

**El lenguaje de la cabina es C++.** No se introduce Rust ni ningún lenguaje nuevo: el proyecto sigue
siendo íntegramente C/C++/Zig y cumple el Principio II sin excepciones.

### Qué es y qué no es WebView2

| | |
|---|---|
| **Es** | Un componente del sistema operativo, preinstalado en Windows 11, igual que Direct2D o GDI. Lo usan Teams, el nuevo Outlook, PowerToys y Tauri. |
| **No es** | Un navegador para el usuario. La app no tiene barra de direcciones, ni pestañas, ni botones de navegación. No abre Chrome ni Edge. El usuario nunca percibe que hay un WebView dentro. |
| **No es** | Electron. Electron **empaqueta** Chromium + Node (~180 MB) y da a JavaScript acceso al sistema de archivos y a procesos. Aquí el JS no puede tocar el FS ni lanzar procesos: solo enviar mensajes al host, que valida. |

### Contenido servido

El bundle web se sirve desde recursos embebidos vía
`SetVirtualHostNameToFolderMapping` bajo `https://devagents.local/`. **Sin servidor HTTP local, sin
puertos abiertos.** CSP estricta, cero contenido remoto, devtools deshabilitadas en release.

## Alternativas consideradas

| Alternativa | Coste | Por qué se descartó |
|---|---|---|
| **C++ / Qt 6 + Scintilla puro** | ~6–8 meses | 100% constitucional sin matices y máximo control, pero exige **reescribir los 63 archivos TS desde cero** en C++. El coste de oportunidad no lo justifica cuando el WebView del SO da el mismo resultado visual. Se conserva como plan B documentado si el WebView incumpliera presupuestos. |
| **Qt 6 + QWebEngineView** | ~4–5 meses | Reutiliza el TS, pero QWebEngine **arrastra Chromium empaquetado** (~120 MB): reintroduce por la puerta de atrás justo lo que ADR-B001 elimina. |
| **Tauri v2 (Rust)** | ~3 meses | Mismo modelo de WebView, ya validado por el usuario en PhyllusMed, y regala updater/instalador/tray. Descartada porque **introduce Rust como cuarto lenguaje**, lo que exigiría otra enmienda constitucional. El usuario eligió pureza sobre conveniencia. |
| **Extensión `.vsix`** | — | Descartada en ADR-B001. |

## Consecuencias

**Positivas**
- Ejecutable de escritorio real, con identidad propia, ≤ 40 MB.
- Se conserva íntegra la inversión en UI TypeScript.
- Cero lenguajes nuevos: C/C++/Zig, tal como manda la constitución.
- El arnés de pruebas CDP del proyecto padre **se conserva**: WebView2 expone CDP igual que Electron
  (ver ADR-B007).
- JavaScript sin acceso al sistema: superficie de ataque mucho menor que Electron.

**Negativas, aceptadas**
- Hay que construir a mano la plomería que Tauri regalaba: auto-updater firmado, generación de
  instalador (Inno Setup, ya usado en el proyecto padre), system tray, notificaciones. Estimado
  ~3 semanas dentro de F1 y F9.
- Dependencia del runtime de WebView2 en la máquina del usuario. Mitigación: viene preinstalado en
  Windows 11 (plataforma objetivo de v1) y el instalador puede incluir el bootstrapper evergreen.
- Portabilidad futura exige un backend de webview por plataforma (WKWebView, WebKitGTK). Mitigación:
  la abstracción de webview se aísla en su propio módulo desde F1.

**Riesgo abierto con criterio objetivo de escape**
- Si en F2 Monaco dentro del WebView incumple los presupuestos medidos (abrir 10 000 líneas
  ≤ 300 ms, scroll ≥ 50 fps), se abre ADR de migración del **editor** a Scintilla nativo, sin
  cambiar el resto de la cabina. Ver ADR-B003.

## Presupuestos vinculantes (gate G1)

| Presupuesto | Umbral |
|---|---|
| Arranque en frío | ≤ 800 ms (p50 de 5 medidas) |
| Tamaño del artefacto | ≤ 40 MB |
| Memoria en reposo | ≤ 250 MB (working set total, 60 s tras arranque) |

Un incumplimiento medido bloquea el gate. No se negocia con una nota al pie.
