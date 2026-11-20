import { BOOT_SPLASH_CSS } from './boot_splash';
import { tokens } from './tokens';

/**
 * Hoja de estilos global de la cabina.
 *
 * Todo lo visual comun (superficies, botones, campos, listas, pestañas,
 * scrollbars) vive aqui como clases sobre CSS variables. Los componentes
 * escriben markup semantico con clases y no repiten estilos inline, que es lo
 * que impedia que los temas hicieran efecto.
 */

const CSS = `
.cli-quota { position: relative; font-size: 11px; min-width: 0; }
.cli-quota summary { cursor: pointer; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.cli-quota__body { position: absolute; bottom: 28px; left: 0; z-index: 8500; width: min(420px, 85vw); max-height: 70vh; overflow: auto; padding: 14px; background: var(--surface-2, #202321); color: var(--fg, #ddd); border: 1px solid var(--border, #555); border-radius: 8px; box-shadow: 0 4px 18px #0005; }
.cli-quota__body section + section { margin-top: 14px; }
.cli-quota__body small { display: block; color: var(--fg-muted, #aaa); margin: 3px 0 7px; }
.cli-quota__row { display: grid; gap: 4px; margin-top: 8px; color: #79996A; line-height: 1.5; }
.cli-quota__row[data-level="warning"] { color: #C89246; }
.cli-quota__row[data-level="exhausted"] { color: #C4553D; }
.cli-quota__row[data-level="unknown"] { color: var(--fg-muted, #aaa); }
.cli-quota progress { width: 100%; height: 5px; border: 0; accent-color: currentColor; }
.cli-quota progress::-webkit-progress-bar { background: var(--border, #555); border-radius: 4px; }
.cli-quota progress::-webkit-progress-value { background: currentColor; border-radius: 4px; }
:root {
  --radius-sm: ${tokens.radii.sm};
  --radius-md: ${tokens.radii.md};
  --radius-lg: ${tokens.radii.lg};
  --radius-pill: ${tokens.radii.pill};
  --font-ui: ${tokens.typography.fontFamily};
  --font-code: ${tokens.typography.fontCode};
  --motion-fast: ${tokens.motion.fast};
  --motion-normal: ${tokens.motion.normal};
  /* 22-09 — alias de nombres antiguos. Varios componentes (plan editable,
     onboarding, catálogo, replay) usaban variables que ningún tema define y
     caían a su literal de respaldo: el morado #7c5cff de la maqueta y blancos
     fijos, se pusiera el tema que se pusiera. Aquí apuntan a los tokens reales. */
  --accent-primary: var(--accent);
  --accent-2: var(--accent-hover);
  --bg-elevated: var(--surface-2);
  --bg-surface-0: var(--bg-main);
  --bg-surface-1: var(--surface-1);
  --bg-surface-2: var(--surface-2);
  --border-default: var(--border-strong);
  --border-subtle: var(--border);
  --fg-default: var(--fg);
  --text: var(--fg);
  --text-muted: var(--fg-muted);
  --warn: var(--warning);
  --font-sans: var(--font-ui);
}

* { box-sizing: border-box; margin: 0; padding: 0; }

html, body {
  width: 100%;
  height: 100%;
  overflow: hidden;
  background: var(--bg-app);
  color: var(--fg);
  font-family: var(--font-ui);
  font-size: ${tokens.typography.fontSizeMd};
  -webkit-font-smoothing: antialiased;
}

button, input, select, textarea { font-family: inherit; font-size: inherit; color: inherit; }
button { cursor: pointer; background: none; border: none; }
button:disabled { cursor: not-allowed; opacity: 0.45; }
a { color: var(--accent); text-decoration: none; }

::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb {
  background: var(--border-strong);
  border-radius: var(--radius-pill, 999px);
  border: 3px solid transparent;
  background-clip: padding-box;
}
::-webkit-scrollbar-thumb:hover { background: var(--fg-subtle); background-clip: padding-box; }

:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }

/* ---------------------------------------------------------------- Layout */

.app-shell {
  display: flex;
  flex-direction: column;
  width: 100vw;
  height: 100vh;
  background: var(--bg-app);
  color: var(--fg);
  overflow: hidden;
  /* Sin seleccion por defecto: la cabina es una ventana sin marco y arrastrarla
     no debe pintar texto en azul. Pero el CONTENIDO si se selecciona: no poder
     copiar una respuesta del agente convertia el chat en un cartel. */
  user-select: none;
}

.titlebar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  height: 36px;
  flex: 0 0 36px;
  padding: 0 8px 0 12px;
  background: var(--bg-titlebar);
  border-bottom: 1px solid var(--border);
  -webkit-app-region: drag;
}
.titlebar__group { display: flex; align-items: center; gap: 10px; -webkit-app-region: no-drag; }
.titlebar__brand {
  display: flex; align-items: center; gap: 6px;
  font-size: ${tokens.typography.fontSizeSm};
  font-weight: 700; letter-spacing: 0.06em;
  color: var(--accent);
}
.titlebar__sep { color: var(--border-strong); }
.titlebar__project { color: var(--fg-muted); font-size: ${tokens.typography.fontSizeSm}; font-weight: 500; max-width: 32vw; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.win-btn {
  position: relative;
  width: 34px; height: 26px;
  display: inline-flex; align-items: center; justify-content: center;
  border-radius: var(--radius-sm);
  color: var(--fg-muted);
  transition: background var(--motion-fast), color var(--motion-fast);
}
.win-btn:hover { background: var(--surface-2); color: var(--fg); }
.win-btn--close:hover { background: #e81123; color: #fff; }

.body-row { display: flex; flex: 1 1 auto; min-height: 0; }

.activity-bar {
  width: 52px; flex: 0 0 52px;
  display: flex; flex-direction: column; align-items: center;
  gap: 4px; padding: 8px 0;
  background: var(--bg-activitybar);
  border-right: 1px solid var(--border);
}
.activity-bar__item {
  position: relative;
  width: 36px; height: 36px;
  display: flex; align-items: center; justify-content: center;
  border-radius: var(--radius-md);
  color: var(--fg-subtle);
  transition: background var(--motion-fast), color var(--motion-fast);
}
.activity-bar__item:hover { background: var(--surface-2); color: var(--fg); }
.activity-bar__item.is-active { background: var(--accent-soft); color: var(--accent); }
.activity-bar__item.is-active::before {
  content: ''; position: absolute; left: -8px; top: 8px; bottom: 8px;
  width: 2px; border-radius: 0 2px 2px 0; background: var(--accent);
}
.activity-bar__spacer { margin-top: auto; }
/* La marca pequeña es la silueta del logo real usada como máscara: toma
   currentColor, igual que los iconos de trazo, y así sigue al tema. */
.brand-mark {
  display: block; flex: 0 0 auto;
  background-color: currentColor;
  -webkit-mask: url(brand/glyph.png) center / contain no-repeat;
  mask: url(brand/glyph.png) center / contain no-repeat;
}
.brand-emblem { display: block; }

/* Editor · 22-09. Monaco trae fijo un rojo sangre (#960000) para los bytes
   de control y lo marca con !important: en la cabina monocroma era lo único
   que gritaba. Con la paleta: un hueco tenue que se distingue sin alarmar. */
.monaco-editor .mtkcontrol {
  color: var(--fg-muted) !important;
  background: var(--surface-3) !important;
  border-radius: 2px;
}
/* Aviso de archivo binario: tapa el editor y no deja escribir. */
.editor-binary {
  position: absolute; inset: 0; z-index: 3;
  align-items: center; justify-content: center; padding: 24px;
  background: var(--bg-main);
}
.editor-binary__card {
  max-width: 440px; padding: 18px 20px;
  border: 1px solid var(--border); border-radius: 8px;
  background: var(--surface-1); color: var(--fg);
  font-family: var(--font-ui); font-size: 13px; line-height: 1.5;
}
.editor-binary__title { font-weight: 600; }
.editor-binary__card p { margin: 8px 0 0; }

.sidebar {
  width: 260px; flex: 0 0 260px;
  display: flex; flex-direction: column; min-height: 0;
  background: var(--bg-sidebar);
  border-right: 1px solid var(--border);
}
.sidebar__header {
  display: flex; align-items: center; justify-content: space-between;
  height: 38px; flex: 0 0 38px; padding: 0 12px;
  border-bottom: 1px solid var(--border);
}
.sidebar__body { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding: 8px; }

/* Plegado: el atributo lo gestiona initPanelToggles() (layout.ts). Se reduce
   a una franja estrecha con solo el botón de flecha visible, sin tocar la
   propiedad display que cada contenido gestiona por su cuenta.
   (Ojo: esta hoja vive dentro de un template literal, así que aquí no puede
   aparecer ningún acento grave.) */
.sidebar[data-collapsed='true'] {
  width: 32px; flex: 0 0 32px; overflow: hidden;
}
.sidebar[data-collapsed='true'] .sidebar__body,
.sidebar[data-collapsed='true'] #sidebar-title,
.sidebar[data-collapsed='true'] #sidebar-actions {
  display: none;
}
.sidebar[data-collapsed='true'] .sidebar__header {
  justify-content: center;
  padding: 0 4px;
}

.central {
  flex: 1 1 auto; min-width: 0;
  display: flex; flex-direction: column;
  background: var(--bg-main);
}
.editor-area { flex: 1 1 auto; min-height: 0; position: relative; }
.editor-area > * { position: absolute; inset: 0; }

.central { position: relative; container-type: inline-size; --rc-width: clamp(200px, 28cqw, 300px); }
/* Ventanas sobre el mismo lienzo del chat, sin columna ni borde exterior. */
#right-cards-host {
  position: absolute; top: 0; right: 0; bottom: 0; left: auto;
  width: var(--rc-width, 300px); z-index: 4;
  background: transparent; border: 0;
}
.right-cards-host { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
.rc-cards {
  flex: 1 1 auto; display: flex; flex-direction: column; gap: 8px;
  padding: 8px; min-height: 0; min-width: 0; overflow-y: auto; overflow-x: hidden;
  /* r6: la columna de ventanas se desplaza con la rueda, pero no dibuja su
     propia barra junto a la del chat (una sola pista vertical; la del hilo). */
  scrollbar-width: none;
}
.rc-cards::-webkit-scrollbar { width: 0; height: 0; }
.right-cards-host[data-collapsed='true'] .rc-cards { display: none; }
/* r4-4: fuera de la vista «Agente» no existe la fila de iconos ni la pila de
   ventanas: el host completo desaparece y el chat recupera su lienzo. */
#right-cards-host[data-view-hidden='true'],
.right-cards-host[data-view-hidden='true'] { display: none; }
#central-container.cards-view-hidden #pane-mission-container > .col { padding-right: 0; padding-top: 0; }
#pane-mission-container > .col { padding-right: calc(var(--rc-width) + 16px); }
.cards-hidden #pane-mission-container > .col { padding-right: 0; padding-top: 36px; }
@container (max-width: 720px) {
  .side-panel-open #right-cards-host .rc-cards { display: none; }
  .side-panel-open #pane-mission-container > .col { padding-right: 0; padding-top: 36px; }
  .side-panel-open #pane-mission-container #mission-body { width: 100%; padding-right: 24px; }
}
@container (max-width: 320px) {
  #right-cards-host { width: 100%; }
  .rc-tool { width: 28px !important; height: 28px !important; }
}
#mission-body > *, #mission-composer { width: min(100%, 760px); max-width: 760px; margin-left: auto; margin-right: auto; }
#mission-body { padding: 0 24px; }
/* r5: el contenedor que se desplaza (el hilo de la conversacion) ocupa TODO el
   ancho del area del chat, hasta el borde derecho, con el hueco de las ventanas
   como relleno interior. Asi su barra queda en el extremo derecho, por fuera de
   las ventanas, y no aparece ninguna linea/barra entre la conversacion y ellas.
   El texto conserva su columna centrada con el mismo centro que calculaba el
   relleno del .col (24 + 16 px de margen + el ancho de las ventanas). */
#pane-mission-container #mission-body {
  width: calc(100% + var(--rc-width) + 16px);
  padding-right: calc(var(--rc-width) + 40px);
}
#central-container.cards-hidden #pane-mission-container #mission-body,
#central-container.cards-view-hidden #pane-mission-container #mission-body {
  width: 100%;
  padding-right: 24px;
}
/* r6: la pista unica, en el borde derecho del area. El dueno comparo las dos
   de r5 y prefirio la de la izquierda, pero esa no era una barra de
   desplazamiento: era el minimapa del transcript (#mission-minimap), cuya
   caja de viewport dibuja un borde con --accent y un relleno con --fg-subtle.
   Con las ventanas a la vista el minimapa se oculta (solo reaparece cuando
   las ventanas se pliegan, .cards-hidden): asi no hay dos pistas verticales.
   La barra del hilo conserva los tokens del tema y gana el peso visual de la
   referencia (pista de 10 px, pulgar redondeado de 6 px visibles). */
#central-container:not(.cards-hidden) #pane-mission-container #mission-minimap { display: none !important; }
#central-container.cards-hidden #pane-mission-container #mission-minimap { right: 12px; }
#pane-mission-container #mission-body::-webkit-scrollbar { width: 10px; }
#pane-mission-container #mission-body::-webkit-scrollbar-track { background: transparent; }
#pane-mission-container #mission-body::-webkit-scrollbar-thumb {
  background: var(--border-strong);
  border-radius: 999px;
  border: 2px solid transparent;
  background-clip: padding-box;
}
#pane-mission-container #mission-body::-webkit-scrollbar-thumb:hover {
  background: var(--fg-subtle);
  background-clip: padding-box;
}
/* El chat mantiene el ancho del lienzo. Solo sus turnos y compositor tienen maximo. */
.panel-secondary {
  display: flex; flex-direction: column; min-height: 0; min-width: 0;
  width: clamp(320px, 42vw, 640px); flex: 0 0 clamp(320px, 42vw, 640px);
  background: var(--bg-main); border-left: 1px solid var(--border);
}
.panel-secondary[data-collapsed='true'] { display: none; }
#chat-header { justify-content: space-between; padding: 10px 12px; }
.chat-host { flex: 1 1 auto; display: flex; flex-direction: column; min-height: 0; min-width: 0; overflow: hidden; }
.rc-tools {
  display: flex; align-items: center; justify-content: flex-end; gap: 4px;
  height: 36px; flex: 0 0 36px; padding: 0 4px;
}
.rc-tool {
  width: 28px; height: 28px;
  display: inline-flex; align-items: center; justify-content: center;
  background: transparent; border: 0; border-radius: 6px;
  color: var(--fg-muted); cursor: pointer;
}
.rc-tool:hover { background: var(--surface-2); color: var(--fg); }
.rc-tool[aria-pressed='true'] { background: var(--surface-2); color: var(--accent); }
.rc-tool:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

.rc-card {
  background: var(--bg-main);
  border: 1px solid var(--border);
  border-radius: 8px;
  flex: 0 0 auto;
  min-width: 0;
}
.rc-card__head {
  width: 100%; min-width: 0;
  display: flex; align-items: center; gap: 6px;
  padding: 8px 10px;
  background: transparent; border: 0; border-radius: 8px;
  color: var(--fg); font: inherit; font-size: 13px; font-weight: 600;
  text-align: left; cursor: pointer;
}
.rc-card__head:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
.rc-card__title { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rc-card__chevron { display: inline-flex; align-items: center; color: var(--fg-muted); flex: 0 0 auto; }
.rc-card__summary {
  flex: 1 1 0; min-width: 0;
  display: none; align-items: center; justify-content: flex-end; gap: 8px;
  overflow: hidden; white-space: nowrap;
  font-size: 12px; font-weight: 400; color: var(--fg-subtle);
}
.rc-card.is-folded .rc-card__summary { display: flex; }
.rc-card__summary .truncate { min-width: 0; }
.rc-summary__num { color: var(--fg-subtle); font-variant-numeric: tabular-nums; }
.rc-mini {
  display: inline-block; flex: 0 0 auto; width: 34px; height: 6px;
  border-radius: 999px; background: var(--surface-2); overflow: hidden;
}
.rc-mini__fill { display: block; height: 100%; border-radius: 999px; background: var(--accent); }
.rc-card__body { padding: 0 10px 10px; min-width: 0; }
.rc-card__body[hidden] { display: none !important; }
/* La Actividad es una ventana mas: el ChatPanel ocupa todo su cuerpo, con
   alto propio y su scroll interno (el tope evita que una traza larga empuje
   al resto de ventanas fuera de la columna). */
.rc-card--actividad .rc-card__body {
  display: flex; flex-direction: column;
  height: clamp(280px, 60vh, 720px); min-height: 0;
  padding: 0; overflow: hidden;
  border-top: 1px solid var(--border);
}
.rc-card--actividad .rc-card__body[hidden] { display: none !important; }
.rc-card--actividad #chat-header-info .section-label,
.rc-card--actividad #chat-status-pill { display: none; }

.rc-dim { color: var(--fg-subtle); }

/* Entorno: filas con icono; la carpeta padre va atenuada, en la MISMA linea
   que el proyecto y con elipsis (se acabo la «Ruta» duplicada y cortada). */
.rc-env { display: flex; flex-direction: column; gap: 2px; }
.rc-env__row {
  display: flex; align-items: center; gap: 8px;
  min-height: 30px; min-width: 0; font-size: 13px;
}
.rc-env__icon { display: inline-flex; align-items: center; flex: 0 0 auto; color: var(--fg-muted); }
.rc-env__value { flex: 0 1 auto; min-width: 0; color: var(--fg); }
.rc-env__name { max-width: 70%; }
.rc-env__parent { flex: 1 1 0; min-width: 0; font-size: 12px; }
.rc-env__parent::before { content: '· '; }
.rc-env__sync { flex: 0 0 auto; font-size: 12px; }
.rc-remote__state { font-size: 12px; }

.rc-files { display: flex; flex-direction: column; }
.rc-file {
  display: flex; align-items: center; gap: 10px;
  min-height: 28px; min-width: 0;
  padding: 2px 8px; margin: 0 -8px; width: calc(100% + 16px);
  background: none; border: 0; border-radius: 4px;
  color: var(--fg); font: inherit; font-size: 13px;
  text-align: left; cursor: pointer;
}
.rc-file:hover { background: var(--surface-2); }
.rc-file:focus-visible { outline: 2px solid var(--accent); outline-offset: 0; }
.rc-file__icon { display: inline-flex; align-items: center; flex: 0 0 auto; }
.rc-file__name { flex: 1 1 auto; min-width: 0; }
.rc-more {
  display: flex; align-items: center; gap: 6px;
  width: 100%; margin-top: 6px; padding: 8px 0 0;
  background: none; border: 0; border-top: 1px solid var(--border);
  color: var(--fg-muted); font: inherit; font-size: 13px;
  text-align: left; cursor: pointer;
}
.rc-more:hover { color: var(--fg); }
.rc-empty { color: var(--fg-subtle); font-size: 13px; line-height: 1.5; }

/* Cambios: «+A −R» y «Confirmar cambios» en la misma cabecera de la ventana. */
.rc-changes__head {
  display: flex; align-items: center; gap: 8px; min-width: 0;
  margin-bottom: 6px;
}
.rc-changes__counts { display: inline-flex; gap: 8px; font-size: 12px; font-weight: 600; flex: 0 0 auto; }
.rc-changes__actions { margin-left: auto; display: inline-flex; align-items: center; gap: 6px; min-width: 0; }
.rc-changes__add, .rc-change__add, .rc-task--done .rc-task__icon { color: var(--success); }
.rc-changes__del, .rc-change__del { color: var(--danger); }
.rc-iconbtn {
  width: 28px; height: 28px; flex: 0 0 auto;
  display: inline-flex; align-items: center; justify-content: center;
  background: transparent; border: 0; border-radius: 6px;
  color: var(--fg-muted); cursor: pointer;
}
.rc-iconbtn:hover { background: var(--surface-2); color: var(--fg); }
.rc-iconbtn:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.rc-changes__files { display: flex; flex-direction: column; }
.rc-change {
  display: flex; align-items: center; gap: 10px;
  min-height: 28px; min-width: 0;
  padding: 2px 8px; margin: 0 -8px; width: calc(100% + 16px);
  background: none; border: 0; border-radius: 4px;
  color: var(--fg); font: inherit; font-size: 13px;
  text-align: left; cursor: pointer;
}
.rc-change:hover { background: var(--surface-2); }
.rc-change:focus-visible { outline: 2px solid var(--accent); outline-offset: 0; }
.rc-change__icon { display: inline-flex; align-items: center; flex: 0 0 auto; }
.rc-change__name { flex: 1 1 auto; min-width: 0; }
.rc-change__counts { flex: 0 0 auto; display: inline-flex; gap: 8px; font-size: 12px; }
.rc-change__new { color: var(--fg-subtle); }
.rc-changes__more {
  display: flex; align-items: center; gap: 6px;
  width: 100%; margin-top: 6px; padding: 8px 0 0;
  background: none; border: 0; border-top: 1px solid var(--border);
  color: var(--fg-muted); font: inherit; font-size: 13px;
  text-align: left; cursor: pointer;
}
.rc-changes__more:hover { color: var(--fg); }
.rc-changes__error {
  margin: 4px 0; padding: 8px 10px;
  border: 1px solid var(--border-strong);
  border-left: 3px solid var(--danger);
  border-radius: 6px;
  color: var(--fg); font-size: 13px; line-height: 1.45;
  white-space: pre-wrap; word-break: break-word;
}
.rc-confirm {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  height: 30px; padding: 0 12px; min-width: 0; flex: 0 1 auto;
  background: var(--accent); border: 0; border-radius: 6px;
  color: var(--accent-contrast); font: inherit; font-size: 13px; font-weight: 600;
  cursor: pointer; white-space: nowrap;
}
.rc-confirm span { overflow: hidden; text-overflow: ellipsis; }
.rc-confirm:hover:not(:disabled) { filter: brightness(1.05); }
.rc-confirm:disabled { background: var(--surface-2); color: var(--fg-subtle); cursor: not-allowed; }
.rc-confirm:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

/* Contexto: «12 % usado · 121,2k / 1M» con barra y niveles del tema. */
.rc-context__head { display: flex; align-items: baseline; gap: 8px; min-width: 0; }
.rc-context__pct { flex: 0 0 auto; font-size: 16px; font-weight: 600; letter-spacing: -0.3px; }
.rc-context__label { flex: 1 1 0; min-width: 0; font-size: 12px; }
.rc-context__track {
  height: 8px; margin-top: 8px;
  background: var(--surface-2); border-radius: 999px; overflow: hidden;
}
.rc-context__fill { height: 100%; border-radius: 999px; background: var(--success); transition: width 160ms ease, background 160ms ease; }
.rc-context__fill--warn { background: var(--warning); }
.rc-context__fill--danger { background: var(--danger); }
.rc-context__rows { margin-top: 8px; }
.rc-ctxrow { display: flex; align-items: center; justify-content: space-between; gap: 8px; min-width: 0; padding: 3px 0; font-size: 13px; }
.rc-ctxrow__label { flex: 1 1 0; min-width: 0; }
.rc-ctxrow__value { flex: 0 0 auto; font-variant-numeric: tabular-nums; }

/* — indicador de contexto del compositor (misma fuente y mismos
   colores que la tarjeta «Contexto»): barra de 6 px, porcentaje y «Estimado». */
.ctx-meter { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; min-width: 0; }
.ctx-meter[hidden] { display: none; }
.ctx-meter__gauge { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; }
.ctx-meter__track { width: 56px; height: 6px; background: #232220; border-radius: 999px; overflow: hidden; }
.ctx-meter__fill { display: block; height: 100%; border-radius: 999px; transition: width 160ms ease, background 160ms ease; }
.ctx-meter__pct { font-weight: 600; font-variant-numeric: tabular-nums; }
.ctx-meter__label { color: var(--fg-subtle); }
.ctx-meter__warn { font-size: 12px; color: #C89246; }
.ctx-meter[data-nivel="critico"] .ctx-meter__warn { color: #C4553D; }

/* Tareas en segundo plano. */
.rc-task {
  display: flex; align-items: center; gap: 8px;
  min-height: 32px; min-width: 0; padding: 2px 0;
  font-size: 13px;
}
.rc-task + .rc-task { border-top: 1px solid var(--border); }
.rc-task__icon { display: inline-flex; align-items: center; color: var(--fg-muted); flex: 0 0 auto; }
.rc-task__name { flex: 1 1 auto; min-width: 0; }
.rc-task__time { flex: 0 0 auto; font-size: 12px; color: var(--fg-subtle); }
.rc-task__status { flex: 0 0 auto; font-size: 12px; }
.rc-task__stop {
  width: 28px; height: 28px; flex: 0 0 auto;
  display: inline-flex; align-items: center; justify-content: center;
  background: transparent; border: 1px solid var(--border); border-radius: 6px;
  color: var(--fg-muted); cursor: pointer;
}
.rc-task__stop:hover { background: color-mix(in srgb, var(--danger) 12%, transparent); border-color: var(--danger); color: var(--danger); }
.rc-task__stop:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.rc-tasks__finished {
  display: flex; align-items: center; justify-content: space-between; gap: 8px;
  width: 100%; margin-top: 6px; padding: 8px 0 0;
  background: none; border: 0; border-top: 1px solid var(--border);
  color: var(--fg-muted); font: inherit; font-size: 13px;
  text-align: left; cursor: pointer;
}
.rc-tasks__finished:hover { color: var(--fg); }
.rc-tasks__finished:focus-visible { outline: 2px solid var(--accent); outline-offset: 0; }
.rc-tasks__chevron { display: inline-flex; align-items: center; }
.rc-tasks__done-list { display: flex; flex-direction: column; margin-top: 4px; }

/* Modal de confirmacion: lista completa de archivos, mensaje editable y error
   de git visible sin cerrar el dialogo. */
.rc-modal {
  width: min(480px, calc(100vw - 48px));
  padding: 20px;
  background: var(--surface-1);
  border: 1px solid var(--border-strong);
  border-radius: 10px;
  color: var(--fg);
}
.rc-modal::backdrop { background: rgba(0, 0, 0, 0.55); }
.rc-modal__title { font-size: 17px; font-weight: 600; }
.rc-modal__subtitle { margin-top: 4px; font-size: 13px; color: var(--fg-subtle); }
.rc-modal__files {
  max-height: 180px; overflow-y: auto;
  margin: 12px 0; padding: 8px 10px;
  border: 1px solid var(--border);
  border-radius: 6px;
  font-size: 13px;
}
.rc-modal__file {
  padding: 2px 0; color: var(--fg-muted);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.rc-modal__label { display: block; margin-bottom: 6px; font-size: 13px; color: var(--fg-subtle); }
.rc-modal__message {
  width: 100%; box-sizing: border-box; resize: vertical;
  padding: 8px 10px; border-radius: 6px;
  border: 1px solid var(--border-strong);
  background: var(--bg-main); color: var(--fg);
  font: inherit; font-size: 14px;
}
.rc-modal__message:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.rc-modal__error {
  margin-top: 10px; padding: 8px 10px;
  border-left: 3px solid var(--danger);
  background: var(--surface-2); border-radius: 4px;
  color: var(--fg); font-size: 13px;
  white-space: pre-wrap; word-break: break-word;
}
.rc-modal__actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; }
.rc-modal__btn {
  height: 34px; padding: 0 16px;
  background: var(--surface-2);
  border: 1px solid var(--border-strong);
  border-radius: 6px; color: var(--fg);
  font: inherit; font-size: 14px; cursor: pointer;
}
.rc-modal__btn:hover:not(:disabled) { border-color: var(--accent); }
.rc-modal__btn:disabled { opacity: 0.6; cursor: not-allowed; }
.rc-modal__btn--primary {
  background: var(--accent); border-color: var(--accent);
  color: var(--accent-contrast); font-weight: 600;
}
.rc-modal__btn:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

/* Reapertura de los paneles plegados.
   El usuario reporto que la flecha de la columna derecha "practicamente se
   oculta" al plegarla: quedaba un icono tenue de 14px sobre fondo del mismo
   tono, en una franja de 32px. Aqui se le da cuerpo propio -- fondo, borde y
   color de acento -- y una franja algo mas ancha, para que se lea como un
   control y no como un adorno. */
.sidebar[data-collapsed='true'] {
  width: 38px; flex: 0 0 38px;
}
.sidebar[data-collapsed='true'] #btn-sidebar-collapse {
  width: 28px; height: 28px;
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 6px;
  color: var(--accent);
  opacity: 1;
}
.sidebar[data-collapsed='true'] #btn-sidebar-collapse:hover {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--accent-contrast);
}

/* (c) · Disposicion de la ventana (data-layout en html; la pone
   initLayout de layout.ts). A: la cabina de antes, sin secciones ni pie.
   B (por defecto, maqueta v2 pag. 1): un solo panel con una seccion plegable
   e independiente por vista, cada una con su contenido y sus botones, y pie con
   Configuracion y Ayuda. Plegado, solo queda la franja de iconos. */
#act-expand { display: none; }
.sidebar__sections, .sidebar__foot { display: none; }
/* Maqueta, .rail.narrow{display:none}: con el panel abierto NO hay franja de
   iconos (eso es de la IDE clasica). La franja de 52 px solo aparece con el
   panel plegado o cuando la ventana es estrecha (data-bp 860). */
html[data-layout='B'] .activity-bar { display: none; }
/* (e), peticion del duenno: como Claude, sin franja de iconos. La
   barra lateral se muestra u oculta con el boton de arriba a la izquierda
   (Ctrl+B); oculta, al pasar el raton por el boton aparece flotando. */
.titlebar__slot { display: none; }
html[data-layout='B'] .titlebar__slot { display: inline-flex; align-items: center; margin-left: -4px; }
html[data-layout='B'] .titlebar__slot #btn-sidebar-collapse {
  width: 28px; height: 26px; border-radius: 6px; color: var(--fg-subtle);
  background: transparent; border: 0; opacity: 1;
}
html[data-layout='B'] .titlebar__slot #btn-sidebar-collapse:hover,
html[data-layout='B'] .titlebar__slot #btn-sidebar-collapse[aria-expanded='true'] { background: var(--surface-2); color: var(--fg); }
html[data-layout='B'] .body-row { position: relative; }
html[data-layout='B'] .sidebar.is-peek,
html[data-layout='B'] .sidebar.is-peek-pinned {
  display: flex !important; position: absolute; top: 0; bottom: 0; left: 0; z-index: 40;
  width: 260px; flex: none; border-right: 1px solid var(--border-strong);
  box-shadow: 0 18px 50px color-mix(in srgb, var(--bg-main) 80%, transparent);
}
/* Barra de titulo, barra de estado y fila de la derecha como la maqueta: el
   navegador vive en la fila de la derecha, Configuracion en el pie del panel
   y el Monitor es una seccion del panel; en B no hay explorador en esa fila
   ni un segundo acceso a la paleta (la lupa de la barra de titulo). */
html[data-layout='B'] #btn-browser,
html[data-layout='B'] #status-monitor,
html[data-layout='B'] .rc-tool[data-rc-action='explorer'],
html[data-layout='B'] .rc-tool[data-rc-action='menu'] { display: none; }
html[data-layout='B'] .sidebar[data-collapsed='true'] { display: none; }
html[data-layout='B'] .sidebar > .sidebar__header { display: none; }
/* Peticion del duenno (8-nov): Sesiones arriba ocupando el alto y crece hacia
   abajo; Archivos, Busqueda, Spaces, MCP, Incidencias y Monitor abajo, y solo
   se despliegan si se abren (entonces crecen hacia arriba con su propio scroll). */
html[data-layout='B'] .sidebar__sections {
  display: flex; flex-direction: column; flex: 1 1 auto; min-height: 0; overflow-x: hidden; overflow-y: auto;
  padding: 2px 6px 6px;
}
/* R4 (censo del 9-nov): con varias secciones abiertas cada una se encogía hasta
   una fila (Archivos medía 43 px). Abierta, una sección conserva al menos ~4
   filas; si no caben todas, se desplaza el panel entero en vez de aplastarlas. */
html[data-layout='B'] .sidebar__sections .sb-sec.is-open { min-height: 120px; }
html[data-layout='B'] .sb-sec[data-view='agent'] { flex: 1 1 auto; min-height: 0; }
html[data-layout='B'] .sb-sec[data-view='agent'] > .sb-sec__body { flex: 1 1 auto; min-height: 0; overflow-y: auto; }
html[data-layout='B'] .sb-sec:not([data-view='agent']) { flex: 0 1 auto; min-height: 0; }
html[data-layout='B'] .sb-sec:not([data-view='agent']).is-open { max-height: 55%; }
html[data-layout='B'] .sb-sec:not([data-view='agent']) > .sb-sec__body { min-height: 0; overflow-y: auto; }
html[data-layout='B'] .sidebar > .sidebar__body { display: none; }
/* Seccion (maqueta .sec.nav): cabecera con marcador de 9 px, icono 14 y
   titulo 12,5 px; botones a la derecha siempre visibles; cuerpo propio. */
.sb-sec { display: flex; flex-direction: column; flex: 0 0 auto; margin-top: 4px; }
.sb-sec__head { display: flex; align-items: center; gap: 4px; padding-right: 4px; border-radius: 6px; }
.sb-sec__toggle {
  display: flex; align-items: center; gap: 6px; flex: 1 1 auto; min-width: 0;
  padding: 6px 8px; border: 0; background: transparent;
  color: var(--fg-muted); font: inherit; font-size: 12.5px; text-align: left; cursor: pointer;
}
.sb-sec__toggle::before { content: '▸'; font-size: 9px; width: 8px; flex: 0 0 auto; color: var(--fg-subtle); }
.sb-sec__toggle[aria-expanded='true']::before { content: '▾'; }
.sb-sec__toggle:focus-visible { outline: 1px solid var(--accent); outline-offset: -1px; border-radius: 6px; }
.sb-sec.is-open .sb-sec__toggle { color: var(--fg); }
.sb-sec__ico { display: inline-flex; flex: 0 0 auto; width: 16px; justify-content: center; color: var(--fg-subtle); }
.sb-sec__label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sb-sec__tools { display: inline-flex; align-items: center; gap: 2px; flex: 0 0 auto; }
.sb-sec__tools .icon-btn { width: 20px; height: 20px; border-radius: 5px; color: var(--fg-subtle); }
.sb-sec__dot { width: 7px; height: 7px; margin: 0 6px; border-radius: 50%; background: var(--fg-subtle); }
.sb-sec__dot.is-ok { background: var(--success); }
.sb-sec__body { display: flex; flex-direction: column; gap: 4px; padding: 2px 0 6px; }
.sb-sec__body[hidden] { display: none; }
.sb-sec__hint { padding: 2px 12px; font-size: 11.5px; color: var(--fg-subtle); }
.sb-sec__link { padding: 2px 12px; font-size: 11.5px; color: var(--highlight); text-decoration: none; cursor: pointer; }
.sb-sec__link:hover { text-decoration: underline; }

/* 9-nov: vista central «Spaces y sesiones» (Spaces sale del panel izquierdo). */
.catalog-view { display: flex; flex-direction: column; gap: 18px; max-width: 980px; margin: 0 auto; padding: 22px 24px 28px; color: var(--fg); }
.catalog-view__title { font-size: 18px; font-weight: 600; }
.catalog-view__lead { margin-top: 6px; max-width: 72ch; font-size: 12.5px; line-height: 1.55; color: var(--fg-muted); }
.catalog-view__block { display: flex; flex-direction: column; gap: 8px; min-width: 0; padding: 14px; background: var(--surface-1); border: 1px solid var(--border); border-radius: var(--radius-md); }
.catalog-view__cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 18px; }
.catalog-view__list { display: flex; flex-direction: column; gap: 2px; max-height: 420px; overflow-y: auto; }
.catalog-view__empty { padding: 6px 2px; font-size: 12px; }
.catalog-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; min-height: 34px; padding: 4px 8px; border-radius: 6px; }
.catalog-row:hover { background: var(--surface-2); }
.catalog-row__main { display: flex; flex-direction: column; min-width: 0; }
.catalog-row__title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12.5px; }
.catalog-row__meta { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 11px; color: var(--fg-subtle); }
#catalog-spaces > .col { padding: 0 !important; }
#catalog-spaces .btn { flex: 0 0 auto !important; }
/* En B los botones de crear y podar de Spaces estan en la cabecera. */
html[data-layout='B'] .sidebar__foot {
  display: flex; flex-direction: column; gap: 2px; flex: 0 0 auto;
  padding: 6px; border-top: 1px solid var(--border);
}
.sidebar__foot-item {
  display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 8px;
  border: 0; border-radius: 6px; background: transparent;
  color: var(--fg-muted); font: inherit; font-size: 12.5px; text-align: left; cursor: pointer;
}
.sidebar__foot-item:hover { background: var(--surface-2); color: var(--fg); }
.sidebar__foot-item svg { color: var(--fg-subtle); }
/* Orden de la franja en B, el de la maqueta: Monitor al final de las vistas;
   abajo Configuracion, Ayuda y (plegada) Desplegar panel. */
html[data-layout='B'] #act-monitor { order: 1; }
html[data-layout='B'] #act-settings { order: 2; margin-top: auto; }
html[data-layout='B'] #act-help { order: 3; margin-top: 0; }
html[data-layout='B'] #act-expand { order: 4; }
/* En B «Nueva conversacion» ya esta en la barra de pestanas: un solo sitio. */
html[data-layout='B'] #sb-new-chat { display: none; }
/* Boton unico «Archivo» de Sesiones y su menu (maqueta v2, archMenu). */
.sb-amenu { position: relative; display: inline-flex; }
.sb-amenu__pop {
  position: absolute; top: calc(100% + 4px); right: 0; z-index: 30;
  display: flex; flex-direction: column; gap: 2px; min-width: 220px; padding: 4px;
  background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px;
  box-shadow: 0 12px 32px color-mix(in srgb, var(--bg-main) 70%, transparent);
}
.sb-amenu__pop[hidden] { display: none; }
.sb-amenu__item {
  display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 10px;
  border: 0; border-radius: 6px; background: transparent; color: var(--fg-muted);
  font: inherit; font-size: 12.5px; text-align: left; white-space: nowrap; cursor: pointer;
}
.sb-amenu__item:hover, .sb-amenu__item:focus-visible { background: var(--surface-2); color: var(--fg); outline: none; }
.sb-amenu__item.is-active { color: var(--accent); }
/* Tarjetas de disposicion en Configuracion › Apariencia. */
.btn-layout { width: auto; text-align: left; cursor: pointer; }
.btn-layout[aria-checked='true'] { border-color: var(--highlight); }
.btn-layout:disabled { cursor: not-allowed; opacity: .55; }
.btn-layout:focus-visible { outline: 1px solid var(--accent); outline-offset: 2px; }

/* Terminal, Verificacion, Salida y Problemas comparten el dock opcional.
   Al cerrar desaparecen del layout; sus instancias siguen vivas. */
.panel-bottom {
  position: relative; flex: 1 1 auto; display: flex; flex-direction: column;
  width: 100%; min-width: 0; min-height: 0; background: var(--bg-main);
}
.panel-bottom[data-collapsed='true'] { display: none; }
.panel-bottom .panel-resize { display: none; }
/* Agarres de redimensionado. Franjas de 6px que se tinen al pasar por encima:
   antes no habia ninguna en toda la cabina y no se podia cambiar nada de sitio. */
.panel-resize { position: absolute; z-index: 3; background: transparent; }
.panel-resize:hover, .panel-resize.is-dragging { background: var(--accent); }
.panel-resize--v { top: -3px; left: 0; right: 0; height: 6px; cursor: ns-resize; }

/* La barra de pestañas ya no queda nunca vacía del todo: el conmutador
   Agente/Dev vive ahí (ver #app-mode-switch en layout.ts) y debe verse
   siempre, así que TabManager solo repinta #tab-items, no la barra entera. */
.tabs { justify-content: flex-start; }
#tab-items { display: flex; align-items: center; gap: 2px; min-width: 0; flex: 1 1 auto; overflow-x: auto; overflow-y: hidden; }
#tab-items::-webkit-scrollbar { height: 0; }

.status-bar {
  display: flex; align-items: center; justify-content: space-between;
  height: 26px; flex: 0 0 26px; padding: 0 12px;
  background: var(--bg-statusbar);
  border-top: 1px solid var(--border);
  font-size: ${tokens.typography.fontSizeXs};
  color: var(--fg-subtle);
}
.status-bar__group { display: flex; align-items: center; gap: 14px; }
.status-bar__item { display: inline-flex; align-items: center; gap: 6px; }
.status-bar__item--action { cursor: pointer; border-radius: 4px; padding: 1px 5px; margin: 0 -5px; }
.status-bar__item--action:hover { background: var(--surface-2); color: var(--fg); }
/* Modo de permisos sin confirmacion. Deliberadamente ruidoso: es lo unico que
   recuerda que el agente puede actuar solo. */
.status-bar__item--warn {
  background: var(--warning); color: #1a1200; font-weight: 600;
  border-radius: 4px; padding: 1px 7px; letter-spacing: .02em;
}

/* ------------------------------------------------------------ Primitivas */

.section-label {
  font-size: 10px; font-weight: 700;
  letter-spacing: 0.09em; text-transform: uppercase;
  color: var(--fg-subtle);
}

.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  height: 30px; padding: 0 12px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border-strong);
  background: var(--surface-2);
  color: var(--fg);
  font-size: ${tokens.typography.fontSizeSm}; font-weight: 500;
  white-space: nowrap;
  transition: background var(--motion-fast), border-color var(--motion-fast), color var(--motion-fast);
}
.btn:hover:not(:disabled) { background: var(--surface-3); }
.btn--primary {
  background: var(--accent); border-color: var(--accent); color: var(--accent-contrast); font-weight: 600;
}
.btn--primary:hover:not(:disabled) { background: var(--accent-hover); border-color: var(--accent-hover); }
.btn--ghost { background: transparent; border-color: transparent; color: var(--fg-muted); }
.btn--ghost:hover:not(:disabled) { background: var(--surface-2); color: var(--fg); }
.btn--danger { border-color: var(--danger); color: var(--danger); background: transparent; }
.btn--danger:hover:not(:disabled) { background: var(--danger); color: #fff; }
.btn--sm { height: 24px; padding: 0 8px; font-size: ${tokens.typography.fontSizeXs}; }
.btn--block { width: 100%; }

.icon-btn {
  position: relative;
  width: 26px; height: 26px;
  display: inline-flex; align-items: center; justify-content: center;
  border-radius: var(--radius-sm);
  color: var(--fg-subtle);
  transition: background var(--motion-fast), color var(--motion-fast);
}
.icon-btn:hover { background: var(--surface-2); color: var(--fg); }
/* el interruptor «Ver archivadas» marcado, como el icono activo de
   la barra de actividad. */
.icon-btn.is-active { background: var(--accent-soft); color: var(--accent); }

.chip {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 7px 13px;
  border-radius: var(--radius-pill, 999px);
  border: 1px solid var(--border-strong);
  background: var(--surface-1);
  color: var(--fg-muted);
  font-size: ${tokens.typography.fontSizeSm};
  transition: background var(--motion-fast), color var(--motion-fast), border-color var(--motion-fast);
}
.chip:hover { background: var(--surface-2); color: var(--fg); border-color: var(--accent); }

.pill {
  display: inline-flex; align-items: center; gap: 7px;
  padding: 4px 11px;
  border-radius: var(--radius-pill, 999px);
  border: 1px solid var(--border-strong);
  background: var(--surface-1);
  font-size: ${tokens.typography.fontSizeXs};
  color: var(--fg-muted);
  white-space: nowrap;
}
.pill__dot { width: 7px; height: 7px; border-radius: 50%; background: var(--fg-subtle); flex: 0 0 7px; }
.pill--online .pill__dot { background: var(--success); box-shadow: 0 0 0 3px color-mix(in srgb, var(--success) 22%, transparent); }
.pill--offline .pill__dot { background: var(--danger); }
.pill--warn .pill__dot { background: var(--warning); }

.badge {
  display: inline-flex; align-items: center;
  padding: 1px 7px; border-radius: var(--radius-pill, 999px);
  background: var(--surface-2); color: var(--fg-muted);
  font-size: 10px; font-weight: 600; letter-spacing: 0.02em;
}
.badge--accent { background: var(--accent-soft); color: var(--accent); }
.badge--success { background: color-mix(in srgb, var(--success) 16%, transparent); color: var(--success); }
.badge--danger { background: color-mix(in srgb, var(--danger) 16%, transparent); color: var(--danger); }
.badge--warning { background: color-mix(in srgb, var(--warning) 16%, transparent); color: var(--warning); }

.card {
  background: var(--surface-1);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  padding: 14px;
}
.card__title { font-size: ${tokens.typography.fontSizeMd}; font-weight: 600; color: var(--fg); }
.card__subtitle { font-size: ${tokens.typography.fontSizeSm}; color: var(--fg-muted); line-height: 1.5; }

.banner {
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  padding: 9px 14px;
  border-bottom: 1px solid var(--border);
  font-size: ${tokens.typography.fontSizeSm};
}
.banner--warning {
  background: color-mix(in srgb, var(--warning) 12%, var(--bg-main));
  color: var(--warning);
  border-bottom-color: color-mix(in srgb, var(--warning) 30%, transparent);
}
.banner--danger {
  background: color-mix(in srgb, var(--danger) 12%, var(--bg-main));
  color: var(--danger);
  border-bottom-color: color-mix(in srgb, var(--danger) 30%, transparent);
}

.input, .select, .textarea {
  width: 100%; height: 32px; padding: 0 10px;
  background: var(--surface-1);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm);
  color: var(--fg);
  font-size: ${tokens.typography.fontSizeSm};
  outline: none;
  transition: border-color var(--motion-fast), background var(--motion-fast);
}
.input::placeholder, .textarea::placeholder { color: var(--fg-subtle); }
.input:focus, .select:focus, .textarea:focus { border-color: var(--accent); }
.input:focus-visible, .select:focus-visible, .textarea:focus-visible {
  outline: 2px solid var(--accent); outline-offset: 2px;
}
.textarea { height: auto; padding: 8px 10px; resize: none; line-height: 1.5; }
.select { cursor: pointer; appearance: none; padding-right: 26px;
  background-image: linear-gradient(45deg, transparent 50%, currentColor 50%), linear-gradient(135deg, currentColor 50%, transparent 50%);
  background-position: right 12px center, right 7px center;
  background-size: 5px 5px, 5px 5px;
  background-repeat: no-repeat;
}
.select option { background: var(--surface-1); color: var(--fg); }

/* Configuración: jerarquía editorial compacta, con controles del sistema existente. */
.settings-workspace { min-width: 0; overflow: hidden; }
.settings-toolbar { justify-content: space-between; align-items: center; padding: 12px 20px; border-bottom: 1px solid var(--border); flex: 0 0 auto; }
.settings-workspace .settings-navigation { display: flex; flex-wrap: wrap; height: auto; flex: 0 0 auto; gap: 3px; padding: 8px 16px; border-bottom: 1px solid var(--border); background: var(--surface-1); overflow: visible; }
.settings-navigation .panel-tab { min-height: 34px; padding: 8px 10px; border-radius: var(--radius-sm); border-bottom: 0; white-space: normal; line-height: 1.4; }
.settings-navigation .panel-tab.is-active { background: var(--accent-soft); color: var(--accent); }
.settings-body { padding: 24px; min-width: 0; container-type: inline-size; }
.settings-content { max-width: 1100px; margin: 0 auto; min-width: 0; padding-bottom: 20px; }
.settings-heading { padding-bottom: 22px; }
.settings-heading h2 { margin: 0 0 6px; font-size: 22px; line-height: 1.3; font-weight: 600; letter-spacing: -.02em; color: var(--fg); }
.settings-heading p { margin: 0; color: var(--fg-muted); font-size: 13px; line-height: 1.6; max-width: 72ch; }
.settings-content .settings-card { padding: 20px !important; min-width: 0; border-radius: var(--radius-md); }
.settings-content .card__title { margin: 0; font-size: 14px; line-height: 1.5; }
.settings-content .card__subtitle { font-size: 12px; line-height: 1.6; }
.settings-content .card > .card__subtitle { margin-top: 6px; }
.settings-content .row { flex-wrap: wrap; row-gap: 8px; min-width: 0; }
.settings-content .col, .settings-content .grow, .settings-content .field { min-width: 0; }
.settings-content .field { max-width: 640px; }
.settings-content .field__label { font-size: 12px; font-weight: 600; color: var(--fg); }
.settings-content .field__hint { color: var(--fg-muted); line-height: 1.6; }
.settings-content .input, .settings-content .select, .settings-content .textarea { min-width: 0; max-width: 640px; font-size: 12px; }
.settings-content .row > .input { flex: 1 1 240px; width: auto; }
.settings-content .btn { min-height: 32px; white-space: normal; line-height: 1.4; flex-shrink: 0; }
.settings-content :is(button, input, select, textarea):focus-visible, .settings-navigation button:focus-visible, .settings-toolbar button:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
.settings-content :is(.btn-gov-mode, .btn-perm-mode, .btn-theme) { flex: 1 1 230px; min-width: min(230px, 100%) !important; }
.settings-content [aria-pressed="true"] { border-color: var(--accent); background: var(--accent-soft); }
.settings-content .list-item { min-width: 0; flex-wrap: wrap; gap: 8px; }
.settings-content .list-item__label { min-width: 0; overflow-wrap: anywhere; }
.settings-content .list-item__meta { white-space: normal; }
.settings-content .subtle, .settings-content .mono, .settings-content .card__subtitle { overflow-wrap: anywhere; }
.settings-content .empty-state { height: auto; min-height: 110px; padding: 22px 16px; border: 1px dashed var(--border); border-radius: var(--radius-md); gap: 10px; color: var(--fg-muted); text-align: center; }
.settings-content .empty-state > svg { color: var(--fg-subtle); }
.settings-content .empty-state .btn { margin-top: 4px; }
.settings-loading { display: flex; align-items: center; gap: 10px; color: var(--fg-muted); }
.settings-feedback { margin: 8px 0 0; font-size: 12px; line-height: 1.6; overflow-wrap: anywhere; }
.settings-feedback:empty { display: none; }
.settings-error { color: var(--danger); overflow-wrap: anywhere; }
.settings-content .settings-error.card { border-color: var(--danger); background: color-mix(in srgb, var(--danger) 7%, var(--surface-1)); }
.settings-callout { padding: 12px; border-left: 3px solid var(--warning); border-radius: var(--radius-sm); background: color-mix(in srgb, var(--warning) 8%, var(--surface-1)); color: var(--fg-muted); font-size: 12px; line-height: 1.6; }
.settings-remote { gap: 18px; }
.settings-form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; margin-top: 18px; }
.settings-form-grid > label { display: flex; flex-direction: column; gap: 7px; font-size: 12px; font-weight: 600; color: var(--fg); min-width: 0; }
.settings-form-grid label:has(input[type="checkbox"]) { flex-direction: row; align-items: center; grid-column: 1 / -1; font-weight: 400; }
.settings-form-grid input[type="checkbox"] { accent-color: var(--accent); flex-shrink: 0; }
.settings-form-wide { grid-column: 1 / -1; margin: 0; }
.settings-form-grid > .btn { justify-self: start; }
.settings-actions { gap: 8px; margin-top: 16px; }
.settings-state { padding: 8px 12px; border-radius: var(--radius-sm); background: var(--surface-2); font-size: 12px; color: var(--fg-muted); overflow-wrap: anywhere; }
.settings-receiver { display: flex; flex-direction: column; gap: 8px; padding: 16px 0; border-top: 1px solid var(--border); font-size: 12px; overflow-wrap: anywhere; }
.settings-receiver .row { gap: 8px; }
.settings-token { margin-top: 18px; }
@container (max-width: 640px) { .settings-form-grid { grid-template-columns: minmax(0, 1fr); } .settings-content .settings-card { padding: 16px !important; } }
/* Los puntos de ruptura de la cabina miden el ancho que LE QUEDA a la cabina
   (ventana menos la columna del navegador integrado), no el viewport: con el
   navegador abierto el viewport sigue entero. el atributo data-bp lo mantiene
   browser_bar.ts (BREAKPOINTS en browser_model.ts) en <html>. */
html[data-bp~='1024'] .settings-body { padding: 18px; }
html[data-bp~='1024'] .settings-toolbar { padding: 10px 16px; }
html[data-bp~='1024'] .settings-body { padding: 14px 18px; }
/* (e) · Configuracion como la pagina 5 de la maqueta (.set): indice
   agrupado de 230 px a la izquierda, contenido a la derecha, tarjetas .sc y
   filas .fr (titulo y explicacion a la izquierda, control a la derecha). */
.settings-toolbar__actions { gap: 8px; align-items: center; flex-wrap: nowrap; }
.settings-search {
  display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 10px;
  background: var(--surface-1); border: 1px solid var(--border-strong); border-radius: 7px; color: var(--fg-subtle);
}
.settings-search:focus-within { border-color: var(--accent); }
.settings-search input {
  width: 180px; border: 0; background: transparent; color: var(--fg); font: inherit; font-size: 12.5px; outline: none;
}
.settings-search input::placeholder { color: var(--fg-subtle); }
.settings-split { display: grid; grid-template-columns: 230px minmax(0, 1fr); flex: 1 1 auto; min-height: 0; container-type: inline-size; }
.settings-workspace .settings-navigation {
  display: flex; flex-direction: column; flex-wrap: nowrap; gap: 1px; height: auto; min-height: 0;
  padding: 10px 8px; overflow-y: auto; border-bottom: 0; border-right: 1px solid var(--border);
  background: var(--bg-sidebar);
}
.settings-nav__group {
  margin: 12px 8px 4px; font-size: 10.5px; font-weight: 600; letter-spacing: .08em;
  text-transform: uppercase; color: var(--fg-subtle);
}
.settings-nav__group:first-child { margin-top: 2px; }
.settings-nav__group[hidden], .settings-nav__item[hidden], .settings-nav__empty[hidden] { display: none; }
.settings-navigation .settings-nav__item {
  justify-content: flex-start; min-height: 0; padding: 5px 8px; border-radius: 6px;
  font-size: 12.5px; font-weight: 400; letter-spacing: 0; text-transform: none; color: var(--fg-muted); text-align: left;
}
.settings-navigation .settings-nav__item:hover { background: var(--surface-1); color: var(--fg); }
.settings-navigation .settings-nav__item.is-active { background: var(--surface-2); color: var(--fg); }
.settings-nav__empty { padding: 6px 8px; font-size: 12px; }
.settings-body { padding: 18px 26px; }
.settings-heading { padding-bottom: 14px; }
.settings-heading h2 { font-size: 17px; margin: 0 0 2px; letter-spacing: 0; }
.settings-heading p { font-size: 12px; color: var(--fg-subtle); }
.settings-content .settings-card {
  padding: 12px 14px !important; border-radius: 10px; background: var(--surface-1); border: 1px solid var(--border);
}
.settings-content .card__title { font-size: 13px; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.settings-content .card > .card__subtitle { margin-top: 2px; color: var(--fg-subtle); }
.settings-row {
  display: flex; align-items: center; gap: 12px; padding: 8px 0; border-top: 1px solid var(--border);
}
.settings-content .card__subtitle + .settings-row, .settings-content .card__title + .settings-row { margin-top: 8px; }
.settings-row:first-child { border-top: 0; }
.settings-row__k { flex: 1 1 auto; min-width: 0; }
.settings-row__k b { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; font-weight: 500; font-size: 12.5px; color: var(--fg); }
.settings-row__k small { display: block; font-size: 11px; color: var(--fg-subtle); line-height: 1.45; }
.settings-row__v { display: flex; align-items: center; justify-content: flex-end; gap: 6px; flex-wrap: wrap; flex: 0 1 auto; min-width: 0; }
.settings-row__v .input { width: 200px; flex: 0 1 200px; }
.settings-inline { display: inline-flex; align-items: center; gap: 4px; font-size: 11px; color: var(--fg-subtle); }
.settings-inline .input { width: 64px !important; flex: 0 0 64px !important; }
.settings-tag {
  display: inline-flex; align-items: center; gap: 3px; padding: 0 6px; border-radius: 99px;
  border: 1px solid var(--border-strong); color: var(--fg-subtle); font-size: 10px; font-weight: 500; white-space: nowrap;
}
.settings-tag--ok { color: var(--success); border-color: color-mix(in srgb, var(--success) 45%, transparent); }
.settings-tag--falta {
  border-radius: 4px; color: var(--danger); border-color: color-mix(in srgb, var(--danger) 55%, transparent);
  font-size: 9.5px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase;
}
.settings-files { display: inline-flex; flex-wrap: wrap; gap: 4px; justify-content: flex-end; }
.settings-files code { padding: 1px 6px; border-radius: 4px; background: var(--surface-2); font-family: var(--font-code); font-size: 11px; color: var(--fg); }
.settings-quota { display: inline-flex; flex-direction: column; gap: 2px; width: 110px; }
.settings-quota small { font-size: 10.5px; color: var(--fg-subtle); }
.settings-quota__bar { display: block; height: 4px; border-radius: 2px; background: var(--surface-3); overflow: hidden; }
.settings-quota__bar i { display: block; height: 100%; background: var(--success); }
.theme-swatches { display: inline-flex; border-radius: 4px; overflow: hidden; border: 1px solid var(--border-strong); flex: 0 0 auto; }
.theme-swatches i { display: block; width: 10px; height: 14px; }
/* Un solo indice (peticion del duenno, 8-nov): en A el de Configuracion ya esta
   en la barra lateral, asi que el interno se oculta; si la barra lateral no se
   ve (ventana estrecha, data-bp 860) vuelve el interno para no perder la navegacion. */
html[data-layout='A']:not([data-bp~='860']) .settings-split { grid-template-columns: minmax(0, 1fr); }
html[data-layout='A']:not([data-bp~='860']) .settings-workspace .settings-navigation { display: none; }
.settings-side-group { padding: 10px 8px 4px; }
.settings-side-group:first-child { padding-top: 2px; }

/* (e), segunda vuelta contra la maqueta (pag. 5): grupos del indice
   con su linea («General ———»), Disposicion a lo ancho, temas en losetas y lo
   elegido en el ambar de la maqueta (.way.on / .th.on). */
.settings-nav__group, .settings-side-group { display: flex; align-items: center; gap: 8px; }
.settings-nav__group::after, .settings-side-group::after {
  content: ''; flex: 1 1 auto; height: 0; border-top: 1px solid var(--border-strong);
}
.settings-layouts { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; margin-top: 10px; }
.settings-themes { display: grid; grid-template-columns: repeat(auto-fill, minmax(124px, 1fr)); gap: 8px; margin-top: 10px; }
.settings-choice {
  display: flex; flex-direction: column; align-items: stretch; gap: 6px; min-width: 0; padding: 8px;
  border: 1px solid var(--border-strong); border-radius: 9px; cursor: pointer; text-align: left;
  background: color-mix(in srgb, var(--bg-main) 55%, var(--surface-1)); color: var(--fg); font: inherit;
}
.settings-choice:hover:not(:disabled) { background: var(--surface-2); }
.settings-choice:focus-visible { outline: 1px solid var(--highlight); outline-offset: 2px; }
.settings-content .settings-choice[aria-checked='true'], .settings-content .settings-choice[aria-pressed='true'] {
  border-color: var(--highlight); background: color-mix(in srgb, var(--highlight) 9%, var(--surface-1));
}
.settings-choice:disabled { cursor: not-allowed; opacity: .55; }
.settings-choice svg { width: 100%; height: auto; display: block; border-radius: 6px; }
.settings-choice > b { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; font-size: 12.5px; font-weight: 600; }
.settings-choice > small { font-size: 11px; color: var(--fg-subtle); line-height: 1.4; }
.settings-theme__sw { display: flex; height: 38px; border-radius: 6px; overflow: hidden; border: 1px solid var(--border); }
.settings-theme__sw i { flex: 1 1 0; height: 100%; display: block; }
.settings-theme__name { font-size: 11.5px; color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.settings-choice[aria-pressed='true'] .settings-theme__name { color: var(--fg); }
@container (max-width: 560px) { .settings-layouts { grid-template-columns: minmax(0, 1fr); } }
/* Ventanas estrechas: el indice pasa a una fila encima del contenido. */
@container (max-width: 720px) {
  .settings-split { grid-template-columns: minmax(0, 1fr); grid-template-rows: auto minmax(0, 1fr); }
  .settings-workspace .settings-navigation {
    flex-direction: row; flex-wrap: wrap; gap: 3px; padding: 6px 10px; border-right: 0; border-bottom: 1px solid var(--border);
  }
  .settings-nav__group { display: none; }
  .settings-row { flex-wrap: wrap; }
  .settings-row__v { justify-content: flex-start; }
}
@container (max-width: 560px) {
  .settings-search input { width: 110px; }
}


.field { display: flex; flex-direction: column; gap: 5px; }
.field__label { font-size: ${tokens.typography.fontSizeXs}; font-weight: 500; color: var(--fg-muted); }
.field__hint { font-size: ${tokens.typography.fontSizeXs}; color: var(--fg-subtle); line-height: 1.5; }

.switch-group {
  display: inline-flex; padding: 3px; gap: 2px;
  background: var(--surface-1);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
}
.switch-group__item {
  display: inline-flex; align-items: center; gap: 5px;
  padding: 4px 12px; border-radius: 4px;
  font-size: ${tokens.typography.fontSizeXs}; font-weight: 500;
  color: var(--fg-subtle);
  transition: background var(--motion-fast), color var(--motion-fast);
}
.switch-group__item:hover { color: var(--fg); }
.switch-group__item.is-active { background: var(--surface-3); color: var(--fg); }

.tabs {
  display: flex; align-items: center; gap: 2px;
  height: 36px; flex: 0 0 36px; padding: 0 8px;
  border-bottom: 1px solid var(--border);
  overflow-x: auto; overflow-y: hidden;
}
.tabs::-webkit-scrollbar { height: 0; }
.tab {
  display: inline-flex; align-items: center; gap: 8px;
  height: 28px; padding: 0 10px;
  border-radius: var(--radius-sm);
  font-size: ${tokens.typography.fontSizeSm};
  color: var(--fg-subtle);
  white-space: nowrap;
  transition: background var(--motion-fast), color var(--motion-fast);
}
.tab:hover { background: var(--surface-1); color: var(--fg-muted); }
.tab.is-active { background: var(--surface-2); color: var(--fg); }
.tab__close { font-size: 10px; opacity: 0.55; border-radius: 3px; padding: 0 2px; }
.tab__close:hover { opacity: 1; background: var(--surface-3); }
.tab__popout { font-size: 11px; opacity: 0; border-radius: 3px; padding: 0 2px; cursor: pointer; }
.tab:hover .tab__popout, .tab.is-active .tab__popout { opacity: 0.55; }
.tab__popout:hover { opacity: 1 !important; background: var(--surface-3); }

/* E5.21/E5.22 — ventana secundaria: un único panel a pantalla completa.
   El nodo se MUEVE dentro de .ventana-unica (ver window_mode.ts), así que
   estos estilos solo compensan lo que perdía al salir del layout: altura,
   su propio fondo y las franjas internas que no aplican en modo aislado. */
.ventana-unica {
  position: fixed; inset: 0; display: flex; flex-direction: column;
  background: var(--bg); z-index: 40; min-height: 0;
}
.ventana-unica > * { flex: 1 1 auto; min-height: 0; min-width: 0; }
.ventana-unica > .titlebar { flex: 0 0 auto; }
.ventana-unica #panel-secondary { width: 100%; flex: 1 1 auto; border-left: 0; }
.ventana-unica > .panel-bottom { display: flex; flex-direction: column; height: 100%; }
.ventana-unica .panel-resize, .ventana-unica .panel-tabs { display: none; }
.ventana-unica #bottom-content { flex: 1 1 auto; padding: 0; }
.ventana-unica--vacia { align-items: center; justify-content: center; }
/* La barra de título sigue siendo el marco (drag/min/max/close); el resto
   del grupo izquierdo (marca/proyecto/space) no aplica a una vista aislada. */
body.ventana-secundaria .titlebar__group:first-child .pill,
body.ventana-secundaria #btn-command-palette,
body.ventana-secundaria #btn-settings { display: none; }

/* El panel ya no ocupa todo el ancho, asi que la fila de pestanas tiene que
   poder desbordarse en horizontal en vez de partir las etiquetas en tres
   lineas (le pasaba a "Salida del motor"). */
.panel-tabs {
  display: flex; align-items: center; gap: 16px;
  height: 32px; flex: 0 0 32px; padding: 0 12px;
  border-bottom: 1px solid var(--border);
  overflow: hidden;
}
/* El panel inferior separa pestañas (desplazables) y flecha (fija). */
#bottom-tabs { gap: 8px; padding: 0 6px 0 12px; }
/* La cuarta pestaña («Problemas») salía cortada como «P»: con 16px de hueco y
   etiquetas largas no cabían las cuatro en el panel derecho. Se aprieta el
   interlineado y se abrevia «Salida» (title completo en layout.ts), dejando el
   scroll horizontal como red de seguridad si la ventana se estrecha aún más. */
#bottom-tabs .panel-tabs__list { gap: 7px; }
#bottom-tabs .panel-tab { letter-spacing: 0.04em; }
.panel-tabs__list {
  display: flex; align-items: center; gap: 16px;
  flex: 1 1 auto; min-width: 0; height: 100%;
  overflow-x: auto; overflow-y: hidden;
}
.panel-tabs__list::-webkit-scrollbar { height: 0; }
/* Misma presencia que las flechas de sesiones y actividad plegadas: cuerpo
   propio para que se lea como control, no como adorno. */
.panel-tabs__toggle {
  flex: 0 0 auto; width: 24px; height: 24px;
  background: var(--surface-2); border: 1px solid var(--border);
  border-radius: 6px; color: var(--accent);
}
.panel-tabs__toggle:hover { background: var(--accent-soft); border-color: var(--border-strong); }

/* Hilo de conversación del modo Agente (fase 'chat' de MissionControl).
   Burbujas asimetricas: el usuario a la derecha con el color de acento, el
   agente a la izquierda sobre superficie. El ancho maximo va en ch y no en px
   para que la linea siga siendo legible a cualquier tamano de ventana. */
/* Zonas donde SI se puede seleccionar y copiar.
   El user-select:none de .app-shell existe para que arrastrar la ventana sin
   marco no pinte medio panel en azul, pero hereda a TODO. Se listan aqui las
   superficies cuyo contenido el usuario necesita poder copiar: ademas del
   hilo, el editor (un textarea sin clase, que sin esto no dejaba ni
   seleccionar codigo), el ledger, y los paneles de Monitor y Configuracion,
   donde vive lo que uno copia de verdad: hashes, rutas, mensajes de error y
   nombres de modelo.
   (Prohibidas las comillas invertidas dentro de este literal.) */
.chat-bubble, .md, .code-surface, .reasoning__body, #bottom-content,
.textarea, .input, #mission-body, #chat-body,
#code-textarea, #ledger-chain-list,
#pane-monitor-container, #pane-settings-container, #pane-mcp-container {
  user-select: text;
  -webkit-user-select: text;
  cursor: auto;
}

/* Resaltado de sintaxis del editor (capa <pre> bajo el textarea).
   Los colores salen de los tokens del tema, no de literales: asi el editor
   cambia de aspecto con el resto de la cabina en los 8 temas. */
.tok-kw  { color: var(--accent); font-weight: 600; }
.tok-str { color: var(--success); }
.tok-com { color: var(--fg-subtle); font-style: italic; }
.tok-num { color: var(--warning); }
.tok-key { color: var(--accent-2, var(--accent)); }

/* Markdown renderizado en las respuestas del agente. El modelo escribe con
   formato y hasta ahora se veian los asteriscos y las almohadillas en crudo. */
.md > *:first-child { margin-top: 0; }
.md > *:last-child { margin-bottom: 0; }
.md h1, .md h2, .md h3 { margin: 12px 0 6px; font-weight: 650; line-height: 1.3; }
.md h1 { font-size: 16px; }
.md h2 { font-size: 15px; }
.md h3 { font-size: 13.5px; }
.md p { margin: 8px 0; }
.md ul, .md ol { margin: 8px 0; padding-left: 20px; }
.md li { margin: 3px 0; }
.md strong { font-weight: 650; }
.md code {
  font-family: ${tokens.typography.fontCode};
  font-size: .92em; padding: 1px 5px; border-radius: 4px;
  background: var(--surface-2);
}
.md pre {
  margin: 8px 0; padding: 10px 12px; border-radius: var(--radius-sm);
  background: var(--surface-1); border: 1px solid var(--border);
  overflow-x: auto;
}
.md pre code { background: none; padding: 0; }
.md table { border-collapse: collapse; margin: 8px 0; display: block; overflow-x: auto; }
.md th, .md td { border: 1px solid var(--border); padding: 4px 10px; text-align: left; }
.md th { background: var(--surface-1); font-weight: 600; }
.md blockquote {
  margin: 8px 0; padding: 2px 0 2px 12px;
  border-left: 2px solid var(--border-strong); color: var(--fg-muted);
}

/* El hilo usa TODO el ancho disponible. No se centra ni se acota.
   Hubo un intento de acotarlo a una columna centrada y fue peor: el hueco
   dejaba de estar en el centro para aparecer a izquierda y derecha, o sea el
   mismo espacio perdido movido de sitio. Lo que sobraba no era el ancho del
   hilo sino el de las BURBUJAS, que se quedaban cortas y dejaban el centro
   vacío en cuanto una respuesta era larga. El ancho se controla abajo, en
   .chat-bubble. */
.chat-thread { display: flex; flex-direction: column; gap: 12px; }
.chat-turn { display: flex; }
.chat-turn--user { justify-content: flex-end; }
.chat-turn--assistant { justify-content: flex-start; }
/* USUARIO-NUEVO A3/A6/A7 (10-nov): las acciones de un fallo en línea
   (Reintentar, Heredar, otro modelo gratuito) van DEBAJO de la respuesta,
   no a su derecha. */
.chat-turn--assistant:has(> .chat-bubble--failed) { flex-wrap: wrap; }
.chat-turn--assistant:has(> .chat-bubble--failed) > .row { flex-basis: 100%; }
.chat-bubble {
  /* Sin tope en caracteres: la burbuja crece con su contenido hasta casi todo
     el ancho del hilo.

     El tope anterior (72ch) era el que dejaba el hueco del centro: con la
     ventana maximizada una respuesta larga se cortaba a media pantalla y el
     resto quedaba vacío. Un texto corto sigue siendo una burbuja corta —el
     ancho lo pone el contenido, no esta regla—, así que el color y el lado
     bastan para distinguir quién habla, como en cualquier chat.

     El 94% deja el margen justo para que se vea de qué lado está cada burbuja;
     al 100% las dos tocarían ambos bordes y esa señal se perdería. */
  max-width: 94%;
  padding: 10px 14px;
  border-radius: 14px;
  font-size: ${tokens.typography.fontSizeSm};
  line-height: 1.55;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
/* 22-09: la burbuja del usuario era un bloque del color de acento a todo
   contraste; con el acento hueso del tema negro deslumbraba en sesiones
   largas. Se distingue por superficie y filo, no por un bloque claro. */
.chat-turn--user .chat-bubble {
  background: var(--surface-2); color: var(--fg);
  border: 1px solid var(--border-strong);
  border-bottom-right-radius: 4px;
}
.chat-turn--assistant .chat-bubble {
  background: var(--surface-1); color: var(--fg);
  border: 1px solid var(--border);
  border-bottom-left-radius: 4px;
}
/* Un fallo del proveedor llega como un turno normal del agente (el planner
   responde sin tareas y con el motivo en 'understanding'). Sin marca visual se
   lee como si el agente hubiera contestado eso. La franja lo distingue sin
   sacar el mensaje de la conversación, que es la decisión D3. */
.chat-turn--assistant .chat-bubble--failed {
  border-left: 3px solid var(--danger);
}
/* B1 (tarea 4): la línea que DevAgents añade bajo la respuesta («Archivos
   cambiados…», «Sin cambios en archivos», «Esta vuelta no escribió ningún
   archivo»). Es un hecho del motor, no texto del modelo: va separada por un
   filo, más pequeña y con su propia etiqueta. */
.chat-facts {
  margin-top: 8px; padding-top: 6px;
  border-top: 1px dashed var(--border-strong);
  font-size: 11px; color: var(--fg-muted); white-space: normal;
}
.chat-facts__tag { font-weight: 600; margin-right: 6px; }
.chat-facts--warn { color: var(--warning); }

/* Autocompletado de menciones @archivo sobre el compositor. Se ancla al borde
   superior de la tarjeta y crece hacia arriba, que es donde hay sitio. */
.mention-popup {
  position: absolute; left: 10px; right: 10px; bottom: calc(100% + 6px);
  z-index: 20; max-height: 240px; overflow-y: auto;
  background: var(--bg-panel);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgba(0, 0, 0, .45);
  padding: 4px;
}
.mention-item {
  display: flex; align-items: baseline; gap: 8px;
  padding: 6px 10px; border-radius: var(--radius-sm);
  cursor: pointer; font-size: ${tokens.typography.fontSizeSm};
}
.mention-item:hover, .mention-item.is-active { background: var(--surface-2); }
.mention-item.is-active { box-shadow: inset 2px 0 0 var(--accent); }
.mention-item__name { color: var(--fg); font-weight: 500; flex: 0 0 auto; }
.mention-item__dir {
  color: var(--fg-subtle); font-size: 11px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; direction: rtl;
}

/* Selector de modelos estilo Devin: panel plegable sobre el compositor con
   lista buscable agrupada a la izquierda y roles/variantes a la derecha. */
.model-pop {
  position: absolute; left: 0; right: 0; bottom: calc(100% + 6px);
  z-index: 25; display: flex; max-height: min(560px, calc(100vh - 220px));
  background: var(--bg-panel);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgba(0, 0, 0, .45);
  overflow: hidden;
}
.model-pop__left {
  flex: 1 1 auto; display: flex; flex-direction: column; min-width: 0;
  border-right: 1px solid var(--border);
}
.model-pop__search { padding: 8px; border-bottom: 1px solid var(--border); }
.model-pop__list { overflow-y: auto; min-height: 0; padding: 4px; }
.model-pop__right {
  flex: 0 1 340px; min-width: 240px; padding: 12px; overflow-y: auto;
  display: flex; flex-direction: column; gap: 6px;
}
#mission-composer { container-type: inline-size; }
.model-pop__right > *, .model-advanced__body > *, .model-group__body > * { min-width: 0; max-width: 100%; }
.model-advanced, .model-group-ext, .model-group-vision {
  border-top: 1px solid var(--border); padding-top: 8px; border-radius: var(--radius-sm);
}
.model-advanced > summary, .model-group-ext > summary, .model-group-vision > summary, .external-cli-detail > summary {
  cursor: pointer; font-size: 12px; padding: 4px 0; color: var(--fg-muted);
}
.model-advanced > summary:focus-visible, .model-group-ext > summary:focus-visible, .model-group-vision > summary:focus-visible {
  outline: 2px solid var(--accent); outline-offset: 2px; border-radius: var(--radius-sm);
}
.model-advanced__body, .model-group__body {
  display: flex; flex-direction: column; gap: 6px; padding-top: 8px;
  border-radius: var(--radius-md);
}
.model-role-row { display: flex; flex-direction: column; gap: 2px; }
.model-role-hint { font-size: 11px; color: var(--fg-subtle); line-height: 1.4; }
.model-add-role__limit { margin: 0; align-self: center; white-space: nowrap; flex: none; }
.model-advanced__body .row, .model-role-actions { flex-wrap: wrap; gap: 6px; }
.model-role-actions { display: flex; margin: 6px 0; }
.model-role-actions .btn { white-space: normal; height: auto; min-height: 28px; }
.external-cli-summary { font-size: 12px; color: var(--fg-muted); overflow-wrap: anywhere; }
.external-cli-note { font-size: 11px; color: var(--fg-muted); margin-top: 2px; }
.external-cli-metadata { font-size: 11px; line-height: 1.5; overflow-wrap: anywhere; padding: 6px 0; }
.external-cli-detail .model-detail__label { display: block; }
#model-audit-warning { color: var(--warning); }
#model-groups-toggle { align-self: flex-start; margin: 4px 8px; }
html[data-bp~='760'] .model-pop { flex-wrap: wrap; max-height: calc(100vh - 180px); overflow-y: auto; }
html[data-bp~='760'] .model-pop__left { flex: 1 1 100%; border-right: 0; }
html[data-bp~='760'] .model-pop__list { max-height: 180px; }
html[data-bp~='760'] .model-pop__right { flex: 1 1 100%; min-width: 0; overflow-y: visible; border-top: 1px solid var(--border); }
/* (d): Modelo se apila segun SU ancho (la ventana es un
   contenedor), no segun el del compositor. */
.model-pop { container: modelpop / inline-size; flex-wrap: wrap; overflow-y: auto; }
.model-pop > .model-pop__left, .model-pop > .model-pop__right { max-height: 100%; }
@container modelpop (max-width: 619px) {
  .model-pop > .model-pop__left { flex: 1 1 100%; border-right: 0; }
  .model-pop > .model-pop__left > .model-pop__list { max-height: 180px; }
  .model-pop > .model-pop__right { flex: 1 1 100%; min-width: 0; overflow-y: visible; border-top: 1px solid var(--border); }
}
/* 006a — ventana «Modos», control segmentado y chips del compositor.
   Los controles reales siguen siendo los selects y casillas del motor; esto
   solo cambia cómo se presentan. */
.modes-pop {
  position: absolute; left: 0; bottom: calc(100% + 6px);
  z-index: 25; display: flex; flex-direction: column; gap: 10px;
  width: min(440px, calc(100vw - 80px));
  max-height: min(560px, calc(100vh - 220px)); overflow-y: auto;
  padding: 10px 12px;
  background: var(--bg-panel);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgba(0, 0, 0, .45);
}
#modes-picker-body { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.modes-section { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.modes-section__title {
  font-size: 10px; font-weight: 700; letter-spacing: .09em;
  text-transform: uppercase; color: var(--fg-subtle);
}
.modes-ways { display: flex; flex-direction: column; gap: 4px; }
.modes-way {
  display: flex; flex-direction: column; gap: 2px; align-items: flex-start;
  padding: 7px 10px; border: 1px solid var(--border); border-radius: 6px;
  background: var(--surface-1); color: var(--fg); text-align: left;
  font-size: 12px; line-height: 1.35;
}
.modes-way:hover:not(:disabled) { border-color: var(--accent); background: var(--surface-2); }
.modes-way.is-active { border-color: var(--accent); background: var(--accent-soft); }
.modes-way:disabled { opacity: .55; cursor: not-allowed; }
.modes-way b { display: flex; align-items: center; gap: 6px; font-weight: 600; }
.modes-way small { color: var(--fg-muted); font-size: 11px; line-height: 1.4; }
.modes-way__gap {
  color: var(--warn); border: 1px solid var(--warn); border-radius: 999px;
  padding: 0 6px; font-size: 10px; font-weight: 600; white-space: nowrap;
}
.modes-way:focus-visible, .seg__btn:focus-visible, .mode-chip__x:focus-visible {
  outline: 2px solid var(--accent); outline-offset: 1px;
}
.seg {
  display: inline-flex; flex-wrap: wrap; gap: 2px; padding: 2px;
  background: var(--surface-1); border: 1px solid var(--border); border-radius: 6px;
}
.seg__btn {
  height: 24px; padding: 0 8px; border-radius: 4px;
  color: var(--fg-muted); font-size: 11px; font-weight: 500; white-space: nowrap;
}
.seg__btn:hover { background: var(--surface-2); color: var(--fg); }
.seg__btn.is-active { background: var(--surface-3); color: var(--fg); box-shadow: inset 0 0 0 1px var(--border-strong); }
.seg__btn--risk { color: var(--warn); }
.seg__btn--risk.is-active { color: var(--warn); }
.modes-advanced { border-top: 1px solid var(--border); padding-top: 8px; }
.modes-advanced > summary { cursor: pointer; font-size: 12px; padding: 4px 0; color: var(--fg-muted); }
#modes-advanced-body { display: flex; flex-direction: column; gap: 10px; padding-top: 8px; min-width: 0; }
.modes-shortcuts {
  font-size: 11px; color: var(--fg-subtle); line-height: 1.6;
  border-top: 1px solid var(--border); padding-top: 8px;
}
.modes-shortcuts code {
  font-family: var(--font-code); background: var(--surface-2);
  border-radius: 4px; padding: 0 4px; font-size: 11px;
}
.composer-pick {
  height: 26px; padding: 0 10px;
  background: var(--surface-1);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm);
  color: var(--fg);
  font-size: ${tokens.typography.fontSizeSm};
  cursor: pointer; appearance: none; outline: none;
  transition: border-color var(--motion-fast), background var(--motion-fast);
}
.composer-pick:focus { border-color: var(--accent); }
.composer-pick:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
#composer-mode-chips { display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.mode-chip {
  display: inline-flex; align-items: center; gap: 4px; height: 24px;
  padding: 0 4px 0 8px; border: 1px solid var(--border); border-radius: 999px;
  background: var(--surface-1); color: var(--fg-muted);
  font-size: 11px; white-space: nowrap;
}
.mode-chip--risk {
  color: var(--warn);
  border-color: color-mix(in srgb, var(--warn) 55%, var(--border));
}
.mode-chip__x {
  width: 16px; height: 16px; display: inline-flex; align-items: center; justify-content: center;
  border-radius: 999px; color: inherit; font-size: 12px; line-height: 1;
}
.mode-chip__x:hover { background: var(--surface-2); color: var(--fg); }
/* (d) · Pagina 2 de la maqueta (Modos, Modelo y compositor). Las
   reglas siguen a las de la maqueta (.ways, .way, .opt, .sw, .seg, .ph, .grp,
   .role, .chip.mode, .chip.cbtn) traducidas a los tokens de la cabina. */
.sr-only {
  position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
  overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0;
}
.modes-pop, .model-pop { border-radius: 10px; }
.modes-section__title {
  margin: 8px 4px 2px; font-size: 10.5px; font-weight: 600; letter-spacing: .08em;
}
#modes-picker-body { gap: 4px; }
.modes-section { gap: 4px; }
.modes-ways { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 6px; margin: 2px 0 4px; }
.modes-way {
  gap: 2px; padding: 8px; border: 1px solid var(--border-strong); border-radius: 9px;
  background: var(--surface-1); cursor: pointer;
}
.modes-way:hover:not(:disabled) { border-color: var(--border-strong); background: var(--surface-2); }
.modes-way.is-active { border-color: var(--highlight); background: color-mix(in srgb, var(--highlight) 9%, var(--surface-1)); }
.modes-way:disabled { opacity: 1; cursor: not-allowed; }
.modes-way b { display: flex; flex-wrap: wrap; font-size: 12.5px; }
.modes-way small { font-size: 10.5px; line-height: 1.35; color: var(--fg-subtle); }
.modes-way__gap {
  color: var(--danger); border: 1px solid color-mix(in srgb, var(--danger) 55%, transparent); border-radius: 4px;
  padding: 0 5px; font-size: 9.5px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase;
}
.modes-opt { display: flex; align-items: center; gap: 10px; padding: 6px 4px; border-radius: 6px; cursor: pointer; }
.modes-opt.is-off { opacity: .4; cursor: not-allowed; }
.modes-opt__tx { flex: 1 1 auto; min-width: 0; cursor: inherit; }
.modes-opt__tx b { display: block; font-weight: 500; font-size: 12.5px; color: var(--fg); }
.modes-opt__tx small { display: block; font-size: 11px; color: var(--fg-subtle); line-height: 1.4; }
.modes-opt__tx code, .model-pop code {
  font-family: var(--font-code); font-size: 11px; color: var(--fg);
}
/* Interruptor (maqueta .sw): casilla real con aspecto de interruptor. */
input.sw {
  appearance: none; -webkit-appearance: none; position: relative; flex: 0 0 auto;
  width: 34px; height: 18px; margin: 0; border-radius: 99px; cursor: pointer;
  border: 1px solid var(--border-strong); background: var(--surface-1);
  transition: background var(--motion-fast), border-color var(--motion-fast);
}
input.sw::after {
  content: ''; position: absolute; top: 2px; left: 2px; width: 12px; height: 12px;
  box-sizing: border-box; border-radius: 50%;
  background: var(--surface-3); border: 1px solid var(--border-strong);
  transition: left var(--motion-fast), background var(--motion-fast);
}
input.sw:checked {
  background: color-mix(in srgb, var(--highlight) 14%, var(--surface-1));
  border-color: color-mix(in srgb, var(--highlight) 55%, transparent);
}
input.sw:checked::after { left: 18px; background: var(--highlight); border-color: var(--highlight); }
input.sw:disabled { opacity: .35; cursor: not-allowed; }
input.sw:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
/* Segmentados (maqueta .seg): sin relleno de fondo; el activo, tono suave. */
.seg { gap: 0; padding: 0; background: transparent; border: 1px solid var(--border-strong); border-radius: 7px; overflow: hidden; }
.seg__btn { height: auto; padding: 3px 9px; border-radius: 0; font-size: 11.5px; font-weight: 400; color: var(--fg-muted); }
.seg__btn.is-active { background: var(--accent-soft); color: var(--fg); box-shadow: none; }
.seg__btn--risk { color: var(--fg-muted); }
.seg__btn--risk.is-active {
  background: color-mix(in srgb, var(--danger) 20%, transparent);
  color: color-mix(in srgb, var(--danger) 45%, var(--fg));
}
.modes-link { color: var(--highlight); text-decoration: none; cursor: pointer; }
.modes-link:hover { text-decoration: underline; }
/* Configuracion avanzada y grupos de Modelo (maqueta .grp): marcador ▸/▾. */
.modes-advanced, .model-advanced, .model-group-ext, .model-group-vision {
  border-top: 1px solid var(--border); margin-top: 6px; padding-top: 4px;
}
.modes-advanced > summary, .model-advanced > summary, .model-group-ext > summary, .model-group-vision > summary {
  list-style: none; cursor: pointer; display: flex; align-items: center; gap: 6px;
  padding: 6px 4px; font-size: 12px; color: var(--fg-muted);
}
.modes-advanced > summary::-webkit-details-marker, .model-advanced > summary::-webkit-details-marker,
.model-group-ext > summary::-webkit-details-marker, .model-group-vision > summary::-webkit-details-marker { display: none; }
.modes-advanced > summary::before, .model-advanced > summary::before,
.model-group-ext > summary::before, .model-group-vision > summary::before { content: '▸'; font-size: 10px; color: var(--fg-subtle); }
.modes-advanced[open] > summary::before, .model-advanced[open] > summary::before,
.model-group-ext[open] > summary::before, .model-group-vision[open] > summary::before { content: '▾'; }
#modes-advanced-body { gap: 2px; padding-top: 2px; }
#modes-advanced-body .seg { margin: 2px 4px 4px; }
.modes-stepper { display: inline-flex; align-items: center; border: 1px solid var(--border-strong); border-radius: 7px; }
.modes-stepper button { padding: 2px 8px; border: 0; background: none; color: var(--fg-muted); cursor: pointer; }
.modes-stepper button:hover { color: var(--fg); }
.modes-stepper input {
  width: 22px; padding: 0; border: 0; background: transparent; color: var(--fg);
  font-size: 12px; text-align: center; -moz-appearance: textfield;
}
.modes-stepper input::-webkit-outer-spin-button, .modes-stepper input::-webkit-inner-spin-button { -webkit-appearance: none; margin: 0; }
.modes-shortcuts { border-top: 0; padding: 6px 4px 2px; }
.modes-shortcuts code { background: transparent; padding: 0; }
/* Modelo: rejilla de roles (maqueta .role). */
.model-role-grid {
  display: grid; grid-template-columns: 118px minmax(0, 1fr) auto; gap: 6px; align-items: center; margin: 4px 0;
}
.model-role-grid > label { font-size: 12px; color: var(--fg-muted); }
.model-role-grid > .model-role-grid__main { color: var(--fg); font-weight: 500; }
.model-role-grid > small, .model-role-grid > .model-role-hint {
  grid-column: 2 / 4; margin-top: -3px; font-size: 10.5px; color: var(--fg-subtle);
}
.model-role-grid > select { min-width: 0; width: 100%; }
/* 10-nov (propietario): en Configuración no se ve la franja «Nueva conversación /
   Agente / Dev»; su alto pasa al contenido. Se sale con la × de la barra. */
html[data-view='settings'] #tab-bar { display: none; }
/* Tarjetas de modo de Permisos: misma altura y alineadas arriba (la de Bypass,
   con su aviso, quedaba desplazada respecto a las otras tres). */
.perm-mode-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; align-items: stretch; }
.perm-mode-grid > * { margin: 0 !important; height: 100%; text-align: left; align-self: stretch; }
.settings-close { margin-left: 2px; }
/* 10-nov (propietario): «muy alejaditas las flechas». Van juntas, sin el hueco de
   10 px del grupo y más estrechas que un botón de ventana, como en VS Code. */
.titlebar__navpair { display: inline-flex; align-items: center; gap: 0; }
/* 10-nov (propietario): aprobaciones del Monitor como resumen corto; el comando
   completo queda plegado con su propio scroll. */
.approval-summary { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; overflow-wrap: anywhere; }
.approval-detail > summary { cursor: pointer; font-size: 11px; color: var(--fg-muted); width: fit-content; }
.approval-detail > pre { max-height: 200px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 11px; margin: 4px 0 0; padding: 6px 8px; background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius-sm); }
.titlebar__nav { width: 24px; }
.titlebar__nav:disabled { opacity: .35; cursor: default; }
.titlebar__nav:disabled:hover { background: transparent; }
/* 10-nov (revisión del panel derecho): #term-panes es una .row, que centra a
   sus hijos en vertical; el panel de la terminal no se estiraba (45 px de
   887) y xterm quedaba con UNA fila: se veía el prompt sobre la caja de
   entrada y nunca la salida de los comandos. */
#term-panes { align-items: stretch !important; }
#term-panes > .term-pane { align-self: stretch; }
/* F6: editor de atajos en Configuración › Acerca de y ayuda. */
.shortcuts-editor { border-top: 1px solid var(--border); padding: 10px 0 2px; }
.shortcuts-editor[hidden] { display: none; }
.shortcuts-editor__head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 8px; }
.shortcuts-editor__list { display: flex; flex-direction: column; max-height: 420px; overflow-y: auto; }
.shortcut-row { display: grid; grid-template-columns: 90px 1fr auto auto; align-items: center; gap: 10px; padding: 5px 4px; border-radius: 6px; }
.shortcut-row:hover { background: var(--surface-2); }
.shortcut-row.is-recording { background: var(--surface-2); outline: 1px solid var(--highlight); }
.shortcut-row__cat { color: var(--fg-muted); font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
.shortcut-row__label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.shortcut-row__kbd { font-family: var(--font-code, monospace); font-size: 11px; padding: 2px 7px; border: 1px solid var(--border-strong); border-radius: 5px; background: var(--surface-1, transparent); color: var(--fg); white-space: nowrap; }
.shortcut-row.is-recording .shortcut-row__kbd { color: var(--highlight); border-color: var(--highlight); }
.shortcut-row__actions { display: inline-flex; gap: 4px; align-items: center; }
/* mensajes en cola mientras el agente trabaja. */
.composer-queue { display: flex; flex-direction: column; gap: 4px; margin-bottom: 6px; }
.composer-queue[hidden] { display: none; }
.composer-queue__item {
  display: flex; align-items: center; gap: 8px; padding: 4px 8px;
  border: 1px dashed var(--border-strong); border-radius: var(--radius-sm, 6px);
  background: var(--surface-2); font-size: 12px; color: var(--fg-muted);
}
.composer-queue__tag { color: var(--highlight); font-weight: 600; flex: 0 0 auto; }
.composer-queue__text { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--fg); }
.composer-queue__x { flex: 0 0 auto; border: 0; background: transparent; color: var(--fg-muted); cursor: pointer; font-size: 14px; line-height: 1; padding: 0 2px; }
.composer-queue__x:hover { color: var(--fg); }
/* Compositor: botones Modos y Modelo como pastillas (maqueta .chip.cbtn) y
   chips de modo en tono ambar (maqueta .chip.mode). */
.composer-pick {
  height: auto !important; padding: 3px 10px; border-radius: 99px;
  background: var(--surface-2); border: 1px solid var(--border-strong);
  color: var(--fg); font-size: 12px; gap: 5px !important;
}
.composer-pick[aria-expanded='true'] { border-color: var(--highlight); }
.mode-chip {
  height: auto; padding: 2px 8px; gap: 2px;
  background: color-mix(in srgb, var(--highlight) 12%, var(--surface-1));
  border-color: color-mix(in srgb, var(--highlight) 35%, transparent);
  color: var(--fg);
}
.mode-chip--risk {
  background: color-mix(in srgb, var(--danger) 14%, var(--surface-1));
  border-color: color-mix(in srgb, var(--danger) 45%, transparent);
  color: var(--fg);
}
.mode-chip__x { width: auto; height: auto; padding: 0 0 0 4px; color: var(--fg-subtle); font-size: 11px; }
/* Modelo como la maqueta (.mp: 300px | 1fr): lista de 300 px y la derecha
   ocupa el resto (antes se quedaba en 340 px y dejaba un hueco vacio). La
   lista crece y «Volver a detectar» queda siempre visible abajo. Las filas
   del catalogo van en una sola linea (.mrow). Por debajo de 760 px se apilan
   como antes. */
.model-pop__left { flex: 0 0 300px; }
.model-pop > .model-pop__right { flex: 1 1 0; min-width: 0; }
.model-pop__left { min-height: 0; overflow: hidden; padding-bottom: 8px; }
.model-pop__left > .model-pop__list { flex: 1 1 auto; }
.model-pop__left > #btn-external-refresh { flex: 0 0 auto; margin: 6px 8px 0; }
.model-pop__left > #external-detection-status { flex: 0 0 auto; padding: 2px 10px 0; font-size: 11px; }
#model-list .model-item { flex-wrap: nowrap; gap: 6px; padding: 4px 6px; font-size: 12px; }
#model-list .model-item__name { flex: 1 1 0; }
/* Ventanas estrechas: las tres formas de trabajar en columna. */
html[data-bp~='760'] .modes-ways { grid-template-columns: 1fr; }
/* Compositor: si la fila se parte, «Enviar» sigue a la derecha (maqueta .crow con .sp). */
#mission-composer .row:has(> #btn-mission-send) { margin-left: auto; }
/* Barra de estado como la maqueta: una sola linea, lo que no cabe se recorta. */
.status-bar { overflow: hidden; gap: 14px; }
.status-bar__group { min-width: 0; overflow: hidden; }
.status-bar__item { white-space: nowrap; flex: 0 0 auto; }
/* Ventana Entorno en columnas estrechas: «Configurar control remoto» y su estado
   se parten en dos lineas en vez de salirse de la tarjeta. */
.rc-remote { flex-wrap: wrap; row-gap: 0; }
.sess-cat--none, .sess-del { display: inline-flex; align-items: center; justify-content: center; }


.model-detail__title { font-size: 12px; font-weight: 700; color: var(--fg); }
.model-detail__hint { font-size: 11px; color: var(--fg-subtle); line-height: 1.4; }
.model-detail__label {
  font-size: 10px; font-weight: 600; letter-spacing: .06em;
  text-transform: uppercase; color: var(--fg-muted); margin-top: 4px;
}
.model-detail__pins {
  margin-top: 6px; padding-top: 8px; border-top: 1px solid var(--border);
  font-size: 11px; color: var(--fg-muted); line-height: 1.6;
}
.model-group { border: none; }
.model-group > summary {
  display: flex; align-items: center; gap: 6px;
  padding: 6px 8px 2px; cursor: pointer; list-style: none; user-select: none;
  font-size: 10px; font-weight: 700; letter-spacing: .08em;
  text-transform: uppercase; color: var(--fg-muted);
}
.model-group > summary::-webkit-details-marker { display: none; }
.model-group > summary::before {
  content: '\\25B8'; font-size: 9px; transition: transform .12s;
}
.model-group[open] > summary::before { transform: rotate(90deg); }
.model-group__count { opacity: .55; font-weight: 500; text-transform: none; }
.model-item {
  display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
  width: 100%; border: 0; background: transparent; text-align: left; font-family: inherit;
  padding: 5px 10px; border-radius: var(--radius-sm);
  cursor: pointer; font-size: ${tokens.typography.fontSizeSm};
}
.model-item:hover, .model-item.is-active { background: var(--surface-2); }
.model-item.is-active { box-shadow: inset 2px 0 0 var(--accent); }
.model-item__name {
  flex: 1 1 140px; min-width: 0; color: var(--fg);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.model-item__ctx { font-size: 10px; color: var(--fg-subtle); flex: 0 0 auto; }
.model-tag {
  flex: 0 0 auto; font-size: 10px; padding: 0 6px; line-height: 16px;
  border-radius: 999px; border: 1px solid var(--border); color: var(--fg-muted);
}
.model-tag--free { color: var(--success); border-color: var(--success); }
.model-tag--fav { color: var(--highlight); border-color: var(--highlight); padding: 0 4px; }
.swarm-list {
  flex: 0 0 auto; max-height: 168px; overflow-y: auto; padding: 2px;
  background: var(--surface-1); border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm);
}
.swarm-item {
  display: flex; align-items: center; gap: 7px;
  padding: 4px 7px; border-radius: var(--radius-sm);
  cursor: pointer; font-size: 12px;
}
.swarm-list.is-disabled { opacity: .55; }
.swarm-list.is-disabled .swarm-item { cursor: default; }
.swarm-item:hover { background: var(--surface-2); }
.swarm-item.is-picked { background: var(--surface-2); }
.swarm-item input { margin: 0; cursor: inherit; flex: 0 0 auto; accent-color: var(--accent); }
.swarm-item__name {
  flex: 1 1 auto; min-width: 0;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.swarm-item__prov { flex: 0 0 auto; font-size: 10px; color: var(--fg-subtle); }
.model-tag--off { color: var(--danger); border-color: var(--danger); }
.model-empty { padding: 14px 10px; font-size: 12px; color: var(--fg-subtle); }
.model-blocked { padding: 5px 10px; font-size: 12px; color: var(--fg-subtle); cursor: default; }
.model-blocked__name { white-space: normal; overflow-wrap: anywhere; }

/* Bloque de razonamiento del modelo. Colapsado por defecto (<details> sin
   'open'): esta ahi para consultarlo, no para leerlo de corrido. */
.reasoning {
  margin: 4px 0;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  background: var(--surface-1);
}
.reasoning__summary {
  display: flex; align-items: center; gap: 6px;
  padding: 6px 10px; cursor: pointer;
  font-size: 11px; font-weight: 600; color: var(--fg-muted);
  list-style: none; user-select: none;
}
.reasoning__summary::-webkit-details-marker { display: none; }
.reasoning__summary:hover { color: var(--fg); }
.reasoning[open] .reasoning__summary { border-bottom: 1px solid var(--border); }
.reasoning__body {
  padding: 8px 10px;
  max-height: 260px; overflow-y: auto;
  font-size: 11px; line-height: 1.6;
  color: var(--fg-muted);
  white-space: pre-wrap; overflow-wrap: anywhere;
}

/* Texto largo colapsable (entendimiento, descripciones de tarea). Un prompt
   de miles de caracteres no debe ocupar la pantalla: extracto + «ver
   completo». */
.clamp-details > summary {
  cursor: pointer; list-style: none;
}
.clamp-details > summary::-webkit-details-marker { display: none; }
.clamp-details > summary .clamp-more { color: var(--accent); font-size: 11px; }
.clamp-details[open] > summary .clamp-more { display: none; }
.clamp-details__full {
  margin-top: 6px;
  white-space: pre-wrap; overflow-wrap: anywhere;
}
.task-desc { font-size: 13px; }

/* Responsive. La cabina se usa en ventanas muy distintas: en cuanto el area
   util se estrecha, la barra lateral y la columna de Actividad se afinan. */
html[data-bp~='1400'] .sidebar:not([data-collapsed='true']) { width: 220px; flex: 0 0 220px; }
html[data-bp~='1100'] .panel-secondary:not([data-collapsed='true']) { width: 48%; flex-basis: 48%; }
/* Con el navegador abierto la cabina se queda con menos de la mitad de la
   ventana: la navegación sigue en la barra de actividad y el chat y el editor
   conservan espacio. */
html[data-bp~='860'] .chat-bubble { max-width: 94%; }
html[data-bp~='860'] .sidebar { display: none; }
html[data-bp~='860'] .tabs { flex-wrap: wrap; height: auto; min-height: 36px; }
html[data-bp~='860'] #tab-items { flex-basis: 100%; }
html[data-bp~='860'] #mission-composer { padding: 8px !important; }
html[data-bp~='860'] .status-bar { overflow-x: auto; white-space: nowrap; }
/* La barra de título ocupa siempre la ventana entera: esta sí mide el viewport. */
@media (max-width: 860px) {
  .titlebar__project, .titlebar__sep { display: none; }
  .titlebar__group { gap: 4px; min-width: 0; }
}
.panel-tab {
  height: 32px; display: inline-flex; align-items: center;
  flex: 0 0 auto; white-space: nowrap;
  border-bottom: 2px solid transparent;
  font-size: 10px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase;
  color: var(--fg-subtle);
  transition: color var(--motion-fast), border-color var(--motion-fast);
}
.panel-tab:hover { color: var(--fg-muted); }
.panel-tab.is-active { color: var(--accent); border-bottom-color: var(--accent); }

.list-item {
  display: flex; align-items: center; gap: 8px;
  padding: 5px 8px; border-radius: var(--radius-sm);
  font-size: ${tokens.typography.fontSizeSm};
  color: var(--fg-muted);
  cursor: pointer;
  transition: background var(--motion-fast), color var(--motion-fast);
}
.list-item:hover { background: var(--surface-1); color: var(--fg); }
.list-item.is-active { background: var(--accent-soft); color: var(--accent); }
.list-item__icon { flex: 0 0 auto; width: 16px; display: flex; align-items: center; justify-content: center; color: var(--fg-subtle); }
/* La flecha de plegado es mas estrecha que el icono de tipo: asi la carpeta y
   su icono quedan alineados con los archivos del mismo nivel. */
.list-item__caret { width: 12px; color: var(--fg-subtle); }
.list-item__label { flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.list-item__meta { flex: 0 0 auto; font-size: 10px; color: var(--fg-subtle); }

/* S8 — buscador y borrado de la lista de sesiones.
   La × solo aparece al pasar por encima de la fila: con 215 sesiones, una
   columna de botones de borrar permanentes convierte la lista en un campo de
   minas, y lo que se busca es leerla. */
/* (c), maqueta v2: un solo campo con la lupa, el texto y el
   selector de categoria dentro. */
.sess-search { padding: 2px 4px 4px; }
.sess-search__field {
  display: flex; align-items: center; gap: 6px; padding: 5px 10px;
  background: var(--surface-1); border: 1px solid var(--border); border-radius: 7px;
  color: var(--fg-subtle);
}
.sess-search__field:focus-within { border-color: var(--accent); }
.sess-search__ico { display: inline-flex; flex: 0 0 auto; }
.sess-search input {
  flex: 1 1 auto; min-width: 0; padding: 0; border: 0; background: transparent;
  color: var(--fg); font-size: 12.5px; outline: none;
}
.sess-search input::placeholder { color: var(--fg-subtle); }
.sess-search select {
  flex: 0 1 auto; max-width: 96px; border: 0; background: transparent;
  color: var(--fg-subtle); font-size: 11.5px; cursor: pointer; outline: none;
}
.sess-search select option { background: var(--surface-1); color: var(--fg); }
/* Grupos plegables (maqueta .sec): mayusculas 11 px con marcador. */
.sess-group { margin-top: 4px; }
.sess-group__head {
  display: flex; align-items: center; gap: 6px; width: 100%; padding: 6px 8px;
  border: 0; background: transparent; cursor: pointer; text-align: left;
  font-size: 11px; font-weight: 400; letter-spacing: .08em;
}
.sess-group__head::before { content: '▾'; font-size: 9px; }
.sess-group__head[aria-expanded='false']::before { content: '▸'; }
.sess-group__head:focus-visible { outline: 1px solid var(--accent); outline-offset: -1px; border-radius: 6px; }
.sess-group__rows[hidden] { display: none; }
/* Punto de estado de cada sesion (maqueta .dot). */
.sess-dot { width: 7px; height: 7px; flex: 0 0 auto; margin: 0 2px; border-radius: 50%; background: var(--fg-subtle); }
.sess-dot--ok { background: var(--success); }
.sess-dot--bad { background: var(--danger); }
.sess-dot--warn { background: var(--warning); }
.sess-dot--run { background: var(--info); }
.sess-row:hover .list-item__meta { display: none; }
.sess-del {
  flex: 0 0 auto; visibility: hidden;
  width: 18px; height: 18px; line-height: 1;
  padding: 0; margin-left: 2px;
  background: transparent; color: var(--fg-subtle);
  border: none; border-radius: var(--radius-sm);
  cursor: pointer; font-size: 14px;
}
.sess-row:hover .sess-del { visibility: visible; }
.sess-del:hover { background: var(--danger); color: #fff; }

.empty-state {
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  gap: 10px; padding: 32px 20px; text-align: center;
  color: var(--fg-subtle); font-size: ${tokens.typography.fontSizeSm};
}
.empty-state__title { color: var(--fg-muted); font-weight: 500; }

.code-surface {
  font-family: var(--font-code);
  font-size: ${tokens.typography.fontSizeSm};
  line-height: 1.55;
  background: var(--bg-panel);
  color: var(--fg-muted);
}

/* ------------------------------------------------------------- Diff hunks */

.diff-toolbar {
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  padding: 10px 14px; flex: 0 0 auto;
  border-bottom: 1px solid var(--border);
}
.diff-hunks { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding: 14px; display: flex; flex-direction: column; gap: 12px; }
.diff-hunk { display: flex; flex-direction: column; gap: 8px; }
.diff-hunk.is-resolved { opacity: 0.55; }
.diff-hunk__header { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.diff-hunk__body {
  font-family: var(--font-code);
  font-size: 12px;
  line-height: 1.6;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  overflow-x: auto;
  padding: 2px 0;
}
.diff-line { display: flex; gap: 8px; padding: 0 8px; white-space: pre; }
.diff-line__no { flex: 0 0 40px; text-align: right; color: var(--fg-subtle); user-select: none; }
.diff-line__marker { flex: 0 0 14px; text-align: center; }
.diff-line--add { background: color-mix(in srgb, var(--success) 12%, transparent); color: var(--success); }
.diff-line--del { background: color-mix(in srgb, var(--danger) 12%, transparent); color: var(--danger); }
.diff-line--context { color: var(--fg-muted); }
.diff-hunk__error { color: var(--danger); font-size: 12px; }

.spinner {
  width: 12px; height: 12px; flex: 0 0 12px;
  border: 2px solid var(--border-strong);
  border-top-color: var(--accent);
  border-radius: 50%;
  animation: da-spin 0.7s linear infinite;
}
@keyframes da-spin { to { transform: rotate(360deg); } }

.shimmer {
  background: linear-gradient(90deg, var(--surface-1) 25%, var(--surface-2) 50%, var(--surface-1) 75%);
  background-size: 200% 100%;
  animation: da-shimmer 1.4s ease-in-out infinite;
}
@keyframes da-shimmer { to { background-position: -200% 0; } }

.scroll-y { overflow-y: auto; overflow-x: hidden; min-height: 0; }
.row { display: flex; align-items: center; gap: 8px; }
.col { display: flex; flex-direction: column; }
.grow { flex: 1 1 auto; min-width: 0; min-height: 0; }
.muted { color: var(--fg-muted); }
.subtle { color: var(--fg-subtle); }
.mono { font-family: var(--font-code); }
.truncate { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* Lectura de órdenes: una columna deliberadamente limitada evita que planes,
   resultados y tarjetas de artefactos se conviertan en líneas interminables. */
#mission-body > .col { width: min(760px, 100%); margin-inline: auto; }
/* 22-09 — pantalla de inicio: ramas que brotan del emblema (orbit_backdrop.ts).
   Capa detrás de todo, sin eventos, recortada al panel; el SVG lo coloca JS
   sobre el centro del emblema. Tenue a propósito: da profundidad, no compite
   con el texto. */
#mission-body { position: relative; z-index: 1; }
.orbit-layer { position: absolute; inset: 0; overflow: hidden; pointer-events: none; z-index: 0; color: var(--fg); }
.orbit-backdrop {
  position: absolute; left: 50%; top: 45%;
  width: 680px; height: 680px; transform: translate(-50%, -50%);
  -webkit-mask-image: radial-gradient(circle, #000 35%, transparent 70%);
          mask-image: radial-gradient(circle, #000 35%, transparent 70%);
}
.orbit-backdrop__ramas { opacity: 0.11; }
.orbit-backdrop__nodos { opacity: 0.16; }
.orbit-backdrop__pulse {
  opacity: 0.35; stroke-dasharray: 26 520;
  animation: orbitPulse 7s linear infinite;
}
@keyframes orbitPulse { from { stroke-dashoffset: 26; } to { stroke-dashoffset: -520; } }
@media (prefers-reduced-motion: reduce) { .orbit-backdrop__pulse { animation: none; opacity: 0; } }
#mission-body > .mission-idle { position: relative; z-index: 1; }
/* Latente: con conversación en curso la identidad sigue detrás, al borde de
   lo perceptible y quieta — sin pulsos. */
.orbit-layer--latente { opacity: 0.3; }
.orbit-layer--latente .orbit-backdrop__pulse { display: none; }
/* Con la ventana sin foco u oculta (otra aplicación delante, un juego a
   pantalla completa), la animación se detiene del todo: cero trabajo de
   pintado mientras el usuario hace otra cosa. Ver .app-inactiva en main.ts. */
.app-inactiva .orbit-backdrop__pulse { animation-play-state: paused; }
#mission-composer { width: min(760px, 100%); margin-inline: auto; box-sizing: border-box; }
html[data-bp~='620'] #mission-body > .col { width: 100%; }
html[data-bp~='620'] #mission-composer { width: 100%; }

/* --------------------------------------------------------------- Overlay */

.overlay {
  position: fixed; inset: 0; z-index: 1000;
  display: flex; align-items: flex-start; justify-content: center;
  padding-top: 12vh;
  background: rgba(0, 0, 0, 0.55);
  backdrop-filter: blur(3px);
}
.modal {
  width: min(560px, 92vw);
  max-height: 70vh;
  display: flex; flex-direction: column;
  background: var(--surface-1);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-lg);
  box-shadow: 0 24px 64px rgba(0, 0, 0, 0.5);
  overflow: hidden;
}
.modal__header {
  display: flex; align-items: center; justify-content: space-between;
  padding: 14px 16px; border-bottom: 1px solid var(--border);
}
.modal__title { font-size: ${tokens.typography.fontSizeLg}; font-weight: 600; }
.modal__body { padding: 16px; overflow-y: auto; display: flex; flex-direction: column; gap: 14px; }
.modal__footer {
  display: flex; align-items: center; justify-content: flex-end; gap: 8px;
  padding: 12px 16px; border-top: 1px solid var(--border);
}

/* E2.6 — «Ejecutar esto» en bloques de comando del chat */
/* — «Copiar» (y «Ejecutar esto») en la esquina superior derecha de
   cada bloque. Los botones viven juntos en .md-pre__tools; «Copiar» queda
   oculto hasta pasar el ratón por el bloque o enfocar cualquiera de sus
   botones con el teclado, y no se oculta nunca durante la confirmación. */
.md-pre { position: relative; }
.md-pre__tools {
  position: absolute; top: 6px; right: 6px; z-index: 1;
  display: flex; gap: 6px; align-items: center;
}
.md-cmd__run, .md-copy {
  padding: 3px 10px; font-size: 11px; font-weight: 600;
  background: var(--accent-soft); color: var(--accent);
  border: 1px solid var(--border-strong); border-radius: 6px;
  cursor: pointer; opacity: 0.85;
}
.md-copy { background: var(--surface-2); color: var(--fg-muted); opacity: 0; transition: opacity var(--motion-fast), background var(--motion-fast), color var(--motion-fast); }
.md-pre:hover .md-copy, .md-pre:focus-within .md-copy, .md-copy:focus-visible, .md-copy[data-copied="true"] { opacity: 1; }
.md-copy:hover { background: var(--surface-3); color: var(--fg); }
.md-copy[data-copied="true"] { background: var(--accent-soft); color: var(--accent); }
.md-cmd__run:hover { opacity: 1; background: var(--accent); color: var(--accent-contrast); }
.md-copy:focus-visible, .md-cmd__run:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.md-pre code { display: block; }
.md-pre__tools + code { padding-top: 22px; }

/* — resaltado en los bloques del chat con los mismos.tok-* del
   editor. Sobre surface-1 (fondo del bloque) el comentario con --fg-subtle y
   la cadena con --success no llegan a 4,5:1 en el tema claro; aqui se usan
   --fg-muted y una mezcla de --success con --fg, que si llegan en los 8 temas
   (comprobado en tests/code_copy_file_actions.test.cjs). */
.md-pre .tok-com { color: var(--fg-muted); }
.md-pre .tok-str { color: color-mix(in srgb, var(--success) 70%, var(--fg)); }

/* — Canvas y Diff del editor: en gris mientras no hay archivo. */
.editor-act { height: 20px; padding: 0 8px; }
.editor-act:disabled, .editor-act[aria-disabled="true"] { opacity: 0.45; cursor: not-allowed; color: var(--fg-subtle); }

/* — avisos de órdenes: contador, bandeja y toasts. Solo tokens. */
#btn-attention { position: relative; }
.attn-badge {
  position: absolute; top: 1px; right: 0; min-width: 14px; height: 14px; padding: 0 3px;
  border-radius: 7px; background: var(--highlight); color: var(--accent-contrast);
  font-size: 9px; font-weight: 700; line-height: 14px; text-align: center;
}
.attn-badge[hidden], .attn-tray[hidden] { display: none; }
.attn-tray {
  position: fixed; top: 38px; right: 8px; z-index: 9100; width: 340px; max-height: 70vh;
  display: flex; flex-direction: column;
  background: var(--bg-elevated, var(--bg-panel)); color: var(--fg);
  border: 1px solid var(--border-strong); border-radius: var(--radius-lg);
  box-shadow: 0 12px 32px rgba(0, 0, 0, 0.45); font-size: 12px;
}
.attn-tray__head, .attn-tray__foot { padding: 8px 12px; display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.attn-tray__head { border-bottom: 1px solid var(--border); }
.attn-tray__foot { border-top: 1px solid var(--border); flex-direction: column; align-items: flex-start; }
.attn-tray__hint { color: var(--fg-muted); font-size: 11px; line-height: 1.4; }
.attn-list { list-style: none; margin: 0; padding: 4px; overflow-y: auto; }
.attn-empty { padding: 12px; color: var(--fg-muted); line-height: 1.45; }
.attn-item {
  width: 100%; display: flex; flex-direction: column; gap: 2px; text-align: left;
  padding: 7px 10px; border-radius: var(--radius-sm); color: var(--fg-muted); background: transparent;
}
.attn-item:hover { background: var(--surface-2); }
.attn-item[data-read="false"] { color: var(--fg); background: var(--accent-soft); }
.attn-item[data-read="false"] .attn-item__what { font-weight: 650; }
.attn-item__sub { font-size: 11px; color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.attn-item:focus-visible, .attn-toast__open:focus-visible, .attn-toast__close:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.attn-toasts { position: fixed; right: calc(var(--browser-w, 0px) + 16px); bottom: 92px; z-index: 9000; display: flex; flex-direction: column; gap: 8px; align-items: flex-end; pointer-events: none; }
.attn-toast {
  pointer-events: auto; display: flex; align-items: flex-start; gap: 4px; max-width: 380px;
  background: var(--bg-elevated, var(--bg-panel)); color: var(--fg);
  border: 1px solid var(--border); border-left: 3px solid var(--accent); border-radius: 8px;
  box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35); font-size: 12px;
}
.attn-toast--done { border-left-color: var(--success); }
.attn-toast--failed { border-left-color: var(--danger); }
.attn-toast--approval, .attn-toast--question { border-left-color: var(--warning); }
.attn-toast__open { display: flex; flex-direction: column; gap: 2px; text-align: left; padding: 9px 4px 9px 12px; flex: 1; color: inherit; }
.attn-toast__open span { color: var(--fg-muted); }
.attn-toast__close { padding: 6px 10px; color: var(--fg-muted); font-size: 16px; line-height: 1; }

/* E2.10 — minimapa del transcript */
#mission-minimap {
  position: absolute; right: 2px; top: 6px; width: 10px;
  z-index: 5; pointer-events: auto;
}
.mmap-mark {
  position: absolute; left: 1px; right: 1px; display: block;
  background: var(--fg-subtle); opacity: 0.45; border-radius: 2px;
  cursor: pointer;
}
.mmap-mark:hover { opacity: 0.9; background: var(--accent); }
.mmap-vp {
  position: absolute; left: 0; right: 0; display: block;
  border: 1px solid var(--accent); border-radius: 3px; opacity: 0.8;
  pointer-events: none;
}

/* E2.17/E2.11 — menús contextuales propios (WebView2 no tiene nativos) */
.ctx-menu {
  position: fixed; z-index: 1000; min-width: 140px;
  background: var(--surface-2); border: 1px solid var(--border-strong);
  border-radius: 8px; padding: 4px; box-shadow: 0 12px 32px rgba(0,0,0,0.45);
  display: flex; flex-direction: column; gap: 2px;
}
.ctx-menu__item {
  text-align: left; padding: 6px 12px; font-size: 12px;
  background: none; border: none; color: var(--fg);
  border-radius: 5px; cursor: pointer;
}
.ctx-menu__item:hover { background: var(--accent-soft); color: var(--accent); }

/* E2.5/E2.11 — sesiones por aprobar, categorías y fork */
/* 22-09: «por aprobar» deja de ser naranja. Es una decisión pendiente, no una
   alarma: se marca con el acento (hueso en el tema negro) y un filo, que se
   distingue también sin color. */
.sess-row--pending { border-left: 2px solid var(--accent); }
.section-label--pending { padding: 8px 8px 4px; color: var(--fg); }
.badge--pending { background: transparent; color: var(--accent); border: 1px solid var(--border-strong); }
.badge--warn { background: color-mix(in srgb, var(--warning) 16%, transparent); color: var(--warning); }
.sess-cat {
  flex-shrink: 0; font-size: 10px; padding: 1px 6px; border-radius: 8px;
  background: var(--accent-soft); color: var(--accent); cursor: pointer;
  max-width: 90px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.sess-cat--none {
  visibility: hidden; background: none; color: var(--fg-subtle);
  border: 1px dashed var(--border-strong);
}
.sess-row:hover .sess-cat--none { visibility: visible; }
.sess-fork { visibility: hidden; padding: 2px; flex-shrink: 0; }
.sess-row:hover .sess-fork { visibility: visible; }
/* 22-09: en la barra de 220 px la fila se quedaba SIN TÍTULO. Los controles
   de hover (categoría, fork, borrar) estaban ocultos con visibility, que sigue
   reservando su hueco, y junto al chip y el estado se comían el ancho entero:
   el título se encogía a 0 px. Ahora los de hover no ocupan sitio hasta que
   se pasa por encima, el título tiene un mínimo, y el estado «planned» no se
   repite cuando ya lo dice el chip «por aprobar». */
.sess-row { overflow: hidden; }
.sess-row .list-item__label { flex: 1 1 0; min-width: 64px; }
.sess-row .badge { flex-shrink: 0; white-space: nowrap; }
.sess-row .sess-cat--none, .sess-row .sess-fork, .sess-row .sess-del, .sess-row .sess-archive { display: none; }
.sess-row:hover .sess-cat--none, .sess-row:hover .sess-fork, .sess-row:hover .sess-del, .sess-row:hover .sess-archive { display: inline-flex; }
.sess-row--pending .list-item__meta { display: none; }

/* E2.10 — el turno nuevo entra con un fundido corto (scroll anclado + fade) */
@keyframes chatTurnIn { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }
.chat-turn:last-child { animation: chatTurnIn 160ms ease-out; }

/* ---------------------------------------------------- Navegador integrado
   Columna de la derecha: la barra la pinta esta WebUI y el host coloca la
   página (WebView sin puente) justo debajo, en el rectángulo que deja la
   barra. --browser-w y --browser-bar-h los fija browser_bar.ts desde el estado
   del host; el host usa las mismas medidas en píxeles CSS por el DPI. */
.bsurf[hidden], .bbody[hidden], .bbar__progress[hidden] { display: none !important; }
.app-shell[data-browser='open'] > .body-row,
.app-shell[data-browser='open'] > .status-bar { margin-right: var(--browser-w, 0px); }
.bsurf {
  position: fixed; top: 36px; right: 0; bottom: 0;
  width: var(--browser-w, 0px);
  display: flex; flex-direction: column;
  background: var(--bg-main);
  box-shadow: inset 1px 0 0 var(--border);
  z-index: 60;
  user-select: none;
}
.bbar {
  position: relative; flex: 0 0 var(--browser-bar-h, 76px);
  height: var(--browser-bar-h, 76px);
  display: flex; flex-direction: column;
  background: var(--bg-titlebar);
  border-bottom: 1px solid var(--border);
  min-width: 0;
}
.bbar__tabs {
  display: flex; align-items: flex-end; gap: 2px;
  height: 34px; flex: 0 0 34px; padding: 0 6px 0 6px; min-width: 0;
}
.bbar__strip {
  display: flex; align-items: flex-end; gap: 2px;
  flex: 0 1 auto; min-width: 0; height: 100%;
  overflow-x: auto; overflow-y: hidden; scrollbar-width: none;
}
.bbar__strip::-webkit-scrollbar { display: none; }
.bbar__tabs > .bbar__btn:first-of-type { margin-left: 2px; }
.bbar__tabs > #bb-close { margin-left: auto; }
.bbar__btn {
  position: relative; flex: 0 0 auto;
  width: 28px; height: 28px;
  display: inline-flex; align-items: center; justify-content: center;
  border-radius: var(--radius-sm); color: var(--fg-muted);
  transition: background var(--motion-fast), color var(--motion-fast);
}
.bbar__tabs .bbar__btn { margin-bottom: 3px; }
.bbar__btn:hover:not(:disabled) { background: var(--surface-2); color: var(--fg); }
.bbar__btn:disabled { opacity: 0.38; }
.btab {
  position: relative; flex: 0 1 168px; min-width: 56px; max-width: 168px;
  height: 30px; display: flex; align-items: center; gap: 6px;
  padding: 0 4px 0 8px; margin-bottom: 0;
  border-radius: var(--radius-sm) var(--radius-sm) 0 0;
  color: var(--fg-muted); font-size: 12px; cursor: pointer;
  transition: background var(--motion-fast), color var(--motion-fast);
}
.btab:hover { background: var(--surface-1); color: var(--fg); }
.btab.is-active { background: var(--bg-main); color: var(--fg); box-shadow: inset 0 2px 0 var(--accent); }
.btab:focus-visible { outline-offset: -2px; }
.btab__mark {
  flex: 0 0 auto; width: 16px; height: 16px; border-radius: 4px;
  display: inline-flex; align-items: center; justify-content: center;
  background: var(--surface-2); color: var(--fg-muted);
  font-size: 10px; font-weight: 700; line-height: 1;
}
.btab__mark[data-trust='app'] { background: var(--accent-soft); color: var(--accent); }
.btab__mark[data-trust='approved'] { background: color-mix(in srgb, var(--success) 18%, transparent); color: var(--success); }
.btab__mark[data-trust='fixture'] { background: color-mix(in srgb, var(--info) 18%, transparent); color: var(--info); }
.btab.is-loading .btab__mark { animation: bbPulse 1.1s ease-in-out infinite; }
.btab__title { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.btab__x {
  flex: 0 0 auto; width: 20px; height: 20px; border-radius: 4px;
  display: inline-flex; align-items: center; justify-content: center;
  color: var(--fg-subtle); opacity: 0;
}
.btab:hover .btab__x, .btab.is-active .btab__x, .btab__x:focus-visible { opacity: 1; }
.btab__x:hover { background: var(--surface-3); color: var(--fg); }
.bbar__nav {
  display: flex; align-items: center; gap: 4px;
  flex: 1 1 auto; min-width: 0; padding: 0 6px;
  background: var(--bg-main);
}
.bbar__addr {
  flex: 1 1 0; min-width: 0; height: 28px;
  display: flex; align-items: center; gap: 6px;
  padding: 0 10px 0 8px;
  background: var(--surface-1); border: 1px solid var(--border); border-radius: var(--radius-pill);
  transition: border-color var(--motion-fast), background var(--motion-fast);
}
.bbar__addr:hover { border-color: var(--border-strong); }
.bbar__addr:focus-within { border-color: var(--accent); background: var(--bg-main); }
.bbar__origin {
  flex: 0 0 auto; display: inline-flex; align-items: center; gap: 5px;
  color: var(--fg-subtle); font-size: 11px; font-weight: 600; white-space: nowrap;
}
.bbar__origin[data-trust='app'] { color: var(--accent); }
.bbar__origin[data-trust='approved'] { color: var(--success); }
.bbar__origin[data-trust='fixture'] { color: var(--info); }
.bbar__origin[data-trust='blocked'] { color: var(--warning); }
.bbar__input {
  flex: 1 1 auto; min-width: 0; height: 100%; padding: 0;
  background: transparent; border: 0; outline: 0; color: var(--fg);
  font-size: 12px; user-select: text;
}
.bbar__input::placeholder { color: var(--fg-subtle); }
.bbar__reg { width: auto; padding: 0 8px; gap: 5px; font-size: 11px; font-weight: 600; }
.bbar__reg:not(:disabled) { color: var(--accent); }
.bbar__progress {
  position: absolute; left: 0; right: 0; bottom: 0; height: 2px; overflow: hidden;
  background: color-mix(in srgb, var(--accent) 18%, transparent);
}
.bbar__progress::before {
  content: ''; position: absolute; top: 0; bottom: 0; width: 40%;
  background: var(--accent); border-radius: 2px;
  animation: bbSlide 1.15s cubic-bezier(0.4, 0, 0.2, 1) infinite;
}
@keyframes bbSlide { from { left: -40%; } to { left: 100%; } }
@keyframes bbPulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.45; } }
@keyframes bbSpin { to { transform: rotate(360deg); } }
.bsurf .bbar__btn:focus-visible, .bbar__input:focus-visible { outline: none; }
.bsurf .bbar__btn:focus-visible { box-shadow: 0 0 0 2px var(--accent); }
@media (prefers-reduced-motion: reduce) {
  .bbar__progress::before { animation: none; left: 0; width: 100%; opacity: 0.6; }
  .btab.is-loading .btab__mark { animation: none; }
  .bcard__spin { animation: none; }
}
/* Columna estrecha: el sello del origen queda en el icono y «Registrar app»
   en su icono; el nombre completo sigue en el title y en aria-label. */
.bsurf { container-type: inline-size; }
@container (max-width: 400px) { .bbar__origin-label, .bbar__reg-label { display: none; } .bbar__reg { width: 28px; padding: 0; } }
/* Columna de ~200 px (ventana de 440): botones más compactos para que la
   dirección conserve sitio donde escribir. */
@container (max-width: 260px) {
  .bbar__nav { gap: 1px; padding: 0 3px; }
  .bbar__nav .bbar__btn, .bbar__reg { width: 24px; height: 24px; }
  .bbar__addr { padding: 0 6px 0 5px; gap: 4px; }
  .bbar__tabs { padding: 0 3px; }
  .btab { min-width: 40px; padding: 0 2px 0 5px; gap: 4px; }
}
.bbody {
  flex: 1 1 auto; min-height: 0; overflow: auto;
  display: flex; align-items: center; justify-content: center;
  padding: 24px 20px; background: var(--bg-main);
}
/* grafo de la orden sobre la maqueta v2, página 3 (verde
   terminó, azul en curso, ámbar sustituido, rojo falló, gris en espera,
   discontinuo omitido). El SVG mantiene su tamaño legible y se desplaza en
   horizontal en columnas estrechas. */
.ograph { display: flex; flex-direction: column; border: 1px solid var(--border); border-radius: var(--radius-md); background: var(--bg-elevated, var(--surface-1)); overflow: hidden; }
.ograph__bar { display: flex; align-items: center; gap: 8px; padding: 9px 12px; border-bottom: 1px solid var(--border); font-size: 12.5px; }
.ograph__bar b { white-space: nowrap; }
.ograph__sp { flex: 1 1 auto; }
.ograph__pill { font-size: 11px; padding: 1px 8px; border-radius: 99px; border: 1px solid var(--border-strong); color: var(--fg-muted); white-space: nowrap; }
.ograph__pill[data-state='running'] { color: var(--info); border-color: color-mix(in srgb, var(--info) 45%, transparent); }
.ograph__sw { display: inline-flex; align-items: center; gap: 8px; background: none; border: 0; padding: 0; cursor: pointer; font: inherit; font-size: 12px; color: var(--fg-muted); }
.ograph__tr { width: 34px; height: 18px; border-radius: 99px; border: 1px solid color-mix(in srgb, var(--accent) 55%, transparent); background: color-mix(in srgb, var(--accent) 14%, transparent); position: relative; flex: none; }
.ograph__tr::after { content: ""; position: absolute; top: 2px; left: 18px; width: 12px; height: 12px; border-radius: 50%; background: var(--accent); }
.ograph__canvas { overflow-x: auto; padding: 6px 8px 2px; }
.ograph__svg { display: block; width: 100%; min-width: 960px; height: auto; }
.ograph__lane { fill: rgba(255, 255, 255, 0.016); stroke: rgba(255, 255, 255, 0.07); stroke-dasharray: 3 4; }
.ograph__lanet { fill: var(--fg-muted); font: 10px var(--font-sans, inherit); letter-spacing: 0.1em; }
.ograph__hive { fill: color-mix(in srgb, var(--accent) 4%, transparent); stroke: color-mix(in srgb, var(--accent) 35%, transparent); stroke-dasharray: 5 4; }
.ograph__edge { stroke: var(--border-strong); stroke-width: 1.4; fill: none; }
.ograph__edge.done { stroke: color-mix(in srgb, var(--success) 60%, transparent); }
.ograph__edge.live { stroke: var(--info); stroke-dasharray: 4 5; animation: ographFlow 1s linear infinite; }
@keyframes ographFlow { to { stroke-dashoffset: -18; } }
.ograph__n { cursor: pointer; outline: none; }
.ograph__box { fill: var(--surface-2); stroke: var(--border-strong); stroke-width: 1.2; }
.ograph__n[data-state='done'] .ograph__box { stroke: var(--success); fill: color-mix(in srgb, var(--success) 7%, var(--surface-2)); }
.ograph__n[data-state='failed'] .ograph__box { stroke: var(--danger); fill: color-mix(in srgb, var(--danger) 8%, var(--surface-2)); }
.ograph__n[data-state='substituted'] .ograph__box { stroke: var(--warning); fill: color-mix(in srgb, var(--warning) 8%, var(--surface-2)); }
.ograph__n[data-state='running'] .ograph__box { stroke: var(--info); fill: color-mix(in srgb, var(--info) 8%, var(--surface-2)); }
.ograph__n[data-state='skip'] .ograph__box { stroke-dasharray: 4 4; fill: none; }
.ograph__n:hover .ograph__box, .ograph__n.sel .ograph__box, .ograph__n:focus-visible .ograph__box { stroke-width: 2.4; }
.ograph__t { fill: var(--fg); font: 12px var(--font-sans, inherit); }
.ograph__s { fill: var(--fg-muted); font: 10.5px var(--font-sans, inherit); }
.ograph__role { fill: var(--accent); font: 700 9.5px var(--font-sans, inherit); letter-spacing: 0.06em; }
.ograph__ic { fill: none; stroke: var(--node, var(--fg-muted)); stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
.ograph__ring { fill: none; stroke: var(--info); stroke-width: 1.5; stroke-dasharray: 20 12; transform-box: fill-box; transform-origin: center; animation: ographSpin 1s linear infinite; }
@keyframes ographSpin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { .ograph__edge.live, .ograph__ring { animation: none; } }
.ograph__legend { display: flex; gap: 14px; flex-wrap: wrap; color: var(--fg-muted); font-size: 11.5px; padding: 8px 12px; border-top: 1px solid var(--border); }
.ograph__legend span { display: inline-flex; gap: 6px; align-items: center; }
.ograph__detail { padding: 10px 12px; border-top: 1px solid var(--border); font-size: 12px; color: var(--fg-muted); min-height: 64px; }
.ograph__detail b { color: var(--fg); }
.ograph__actions { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
.ograph__dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; background: var(--node, var(--fg-muted)); flex: 0 0 auto; }
.ograph__dot[data-state='skip'] { background: none; border: 1px dashed var(--fg-muted); }
:is(.ograph, .ograph-dots) [data-state='done'] { --node: var(--success); }
:is(.ograph, .ograph-dots) [data-state='failed'] { --node: var(--danger); }
:is(.ograph, .ograph-dots) [data-state='substituted'] { --node: var(--warning); }
:is(.ograph, .ograph-dots) [data-state='running'] { --node: var(--info); }
[data-centro='1'] .ograph { position: sticky; top: 0; z-index: 3; box-shadow: 0 6px 16px rgba(0, 0, 0, 0.35); }
[data-centro='1'] .ograph [data-graph-act='hide'] { display: none; }
.ograph-dots { display: flex; align-items: center; gap: 5px; flex-wrap: wrap; padding: 2px 2px 4px; }
.modes-graph { display: flex; align-items: flex-start; gap: 8px; cursor: pointer; }
.modes-graph input { margin-top: 3px; }
/* Imagen fija de la página mientras una capa de la cabina (bandeja, menú,
   paleta, modal) pisa su rectángulo: la vista nativa se oculta debajo. */
.bbody[data-kind='cover'] { padding: 0; background-repeat: no-repeat; background-size: 100% 100%; }
.bcard { max-width: 380px; width: 100%; display: flex; flex-direction: column; align-items: center; gap: 10px; text-align: center; }
.bcard__icon {
  width: 56px; height: 56px; border-radius: var(--radius-lg);
  display: flex; align-items: center; justify-content: center;
  background: var(--surface-1); color: var(--fg-muted);
}
.bbody[data-kind='error'] .bcard__icon { color: var(--danger); background: color-mix(in srgb, var(--danger) 12%, transparent); }
.bbody[data-kind='blocked'] .bcard__icon, .bbody[data-kind='waiting'] .bcard__icon { color: var(--warning); background: color-mix(in srgb, var(--warning) 12%, transparent); }
.bcard__title { font-size: 15px; font-weight: 600; color: var(--fg); }
.bcard__text { font-size: 12px; line-height: 1.55; color: var(--fg-muted); overflow-wrap: anywhere; }
.bcard__meta { font-size: 11px; color: var(--fg-subtle); overflow-wrap: anywhere; user-select: text; }
.bcard code, .bdlg code { font-family: var(--font-code); font-size: 11px; }
.bcard__actions { display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; margin-top: 6px; }
.bcard__hints { list-style: none; display: flex; flex-direction: column; gap: 4px; margin-top: 4px; font-size: 11px; color: var(--fg-subtle); text-align: left; }
.bcard__spin {
  width: 22px; height: 22px; border-radius: 50%;
  border: 2px solid var(--border-strong); border-top-color: var(--accent);
  animation: bbSpin 0.9s linear infinite;
}
/* Diálogo de aprobación de un origen: pertenece a la cabina, la página no lo
   ve ni lo puede responder. Se centra sobre la columna del navegador. */
.bdlg {
  position: fixed; inset: 0; z-index: 9600;
  display: flex; align-items: center; justify-content: center;
  padding: 24px 16px 24px calc(100vw - var(--browser-w, 0px) + 16px);
  background: rgba(0, 0, 0, 0.55);
}
.bdlg__card {
  width: 100%; max-width: 420px; display: flex; flex-direction: column; gap: 10px;
  padding: 18px 20px; background: var(--surface-2); color: var(--fg);
  border: 1px solid var(--border-strong); border-left: 3px solid var(--accent);
  border-radius: var(--radius-md); box-shadow: 0 18px 50px rgba(0, 0, 0, 0.5);
}
.bdlg__head { display: flex; align-items: center; gap: 8px; color: var(--accent); }
.bdlg__head h2 { font-size: 14px; font-weight: 600; color: var(--fg); }
.bdlg__origin {
  display: block; padding: 8px 10px; border-radius: var(--radius-sm);
  background: var(--bg-main); border: 1px solid var(--border);
  overflow-wrap: anywhere; user-select: text;
}
.bdlg__by, .bdlg__text { font-size: 12px; line-height: 1.5; color: var(--fg-muted); }
.bdlg__by strong { color: var(--fg); }
.bdlg__actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 4px; }
`;

let injected = false;

export function injectStylesheet(): void {
  if (injected) return;
  const style = document.createElement('style');
  style.id = 'devagents-stylesheet';
  style.textContent = CSS + BOOT_SPLASH_CSS;
  document.head.appendChild(style);
  injected = true;
}
