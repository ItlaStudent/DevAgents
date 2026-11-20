/**
 * E5.21/E5.22 — modo ventana secundaria.
 *
 * El host abre ventanas extra navegando a `index.html?ventana=<id>&vista=<vista>`
 * (más `path` o `order` según la vista). La cabina corre entera y, al final,
 * este módulo mueve el panel pedido a un contenedor propio y oculta el
 * `.app-shell` completo: la ventana secundaria muestra UNA sola superficie,
 * sin barra de actividad ni paneles duplicados.
 *
 * Se monta por REUBICACIÓN de nodo, no por CSS sobre el layout principal:
 * los paneles ya construidos (terminal ConPTY viva, editor Monaco, chat con
 * su transcript) conservan sus listeners, su estado y sus ResizeObserver —
 * reparentarlos no los reconstruye. Esconder el shell en lugar de no
 * construirlo mantiene intacto el orden de arranque, que toca medio main.ts.
 */

/** Vistas que el host sabe abrir (espejo de ParseOpenWindow en app_windows.cpp). */
export const SECONDARY_VIEWS = ['editor', 'terminal', 'conversacion', 'monitor'] as const;
export type SecondaryView = (typeof SECONDARY_VIEWS)[number];

export interface WindowQuery {
  /** Id de ventana que asigna el supervisor (>1; el 1 es la principal). */
  ventana: number;
  vista: SecondaryView;
  /** `editor`: ruta del archivo; `conversacion`: id de la orden. */
  path: string;
  order: number;
}

/**
 * Lee la query de la URL. Devuelve null cuando NO es ventana secundaria:
 * sin `vista`, o con una `vista` que el host no genera. Una `vista`
 * desconocida no monta nada — mejor la cabina normal que una ventana en
 * blanco sin diagnóstico.
 */
export function parseWindowQuery(search: string): WindowQuery | null {
  let params: URLSearchParams;
  try {
    params = new URLSearchParams(search || '');
  } catch {
    return null;
  }
  const vista = params.get('vista') || '';
  if (!vista) return null;
  if (!(SECONDARY_VIEWS as readonly string[]).includes(vista)) return null;
  const ventana = Number(params.get('ventana') || '0');
  const order = Number(params.get('order') || params.get('order_id') || '0');
  return {
    ventana: Number.isFinite(ventana) && ventana > 0 ? ventana : 0,
    vista: vista as SecondaryView,
    path: params.get('path') || '',
    order: Number.isFinite(order) && order > 0 ? order : 0,
  };
}

/**
 * — qué superficie monta cada vista secundaria. `sidePanel` es el
 * contenido del panel inferior que hay que montar de forma perezosa ANTES de
 * mover el panel (terminal: sin `showSidePanel('terminal')` no hay xterm ni
 * sesión); null cuando no hace falta montar nada extra (la conversación se
 * pobla con `router.show('agent')`: su transcript y compositor viven en
 * #pane-mission-container, no en el panel de actividad).
 */
export function secondaryMountPlan(vista: SecondaryView): { paneId: string; sidePanel: string | null } {
  switch (vista) {
    case 'terminal':
      return { paneId: 'panel-bottom', sidePanel: 'terminal' };
    case 'conversacion':
      return { paneId: 'pane-mission-container', sidePanel: null };
    case 'editor':
      return { paneId: 'monaco-editor-container', sidePanel: null };
    case 'monitor':
      return { paneId: 'pane-monitor-container', sidePanel: null };
  }
}

/**
 * Mueve `paneId` a un contenedor a pantalla completa y oculta el shell.
 * Devuelve el nodo movido (o null si no existe — el llamador decide qué
 * enseñar entonces). La clase en `body` deja una marca para estilos y para
 * que las pruebas/CDP distingan el modo sin tocar el DOM.
 */
export function mountSecondaryView(paneId: string): HTMLElement | null {
  const pane = document.getElementById(paneId);
  if (!pane) return null;
  const app = document.getElementById('beats-app');
  const host = document.createElement('div');
  host.className = 'ventana-unica';
  host.id = 'ventana-unica';
  // La barra de título sale del shell junto al panel: es el marco sin ventana
  // de Win32 — sin ella la secundaria no se podía arrastrar ni cerrar. Los
  // listeners de main.ts ya están atados al elemento y sobreviven al reparent.
  const titlebar = app?.querySelector<HTMLElement>('.titlebar');
  if (titlebar) host.appendChild(titlebar);
  pane.style.display = '';
  host.appendChild(pane);
  document.body.appendChild(host);
  document.body.classList.add('ventana-secundaria');
  // D5: dentro de una secundaria no se abren más ventanas ni se
  // cierra el panel lateral (la ✕ vaciaba la ventana). Se OCULTAN, no se
  // borran: los listeners siguen atados y la principal no se ve afectada.
  hideNestedWindowControls(host);
  if (app) app.style.display = 'none';
  return pane;
}

/** D5 — recorre el host y esconde popout/cierre sin tocar listeners. */
function hideNestedWindowControls(root: HTMLElement): void {
  applyHiddenWindowControls(root);
  // D5 debe sobrevivir a los repintados: MonitorPanel.refresh (y el
  // auto-refresco) reemplazan el innerHTML y recrean #mon-popout. Un barrido
  // único no basta. Se observa SOLO el host de la secundaria y se reaplica la
  // misma regla a los nodos insertados o recreados; la principal queda fuera.
  if (typeof MutationObserver === 'undefined') return;
  const observer = new MutationObserver(() => applyHiddenWindowControls(root));
  observer.observe(root, { childList: true, subtree: true });
}

function applyHiddenWindowControls(root: HTMLElement): void {
  const visit = (node: HTMLElement): void => {
    for (let i = 0; i < node.children.length; i++) {
      const kid = node.children[i] as HTMLElement;
      const title = kid.title || '';
      if (kid.id === 'btn-popout-bottom' || kid.id === 'btn-close-side-panel' || title.includes('ventana nueva')) {
        kid.style.display = 'none';
      }
      visit(kid);
    }
  };
  visit(root);
}

/** Vista pedida pero sin panel montable: se muestra el motivo, no un hueco. */
export function mountSecondaryFallback(vista: string): void {
  mountSecondaryViewPlaceholder(vista);
}

function mountSecondaryViewPlaceholder(vista: string): void {
  const app = document.getElementById('beats-app');
  const host = document.createElement('div');
  host.className = 'ventana-unica ventana-unica--vacia';
  host.id = 'ventana-unica';
  const titlebar = app?.querySelector<HTMLElement>('.titlebar');
  if (titlebar) host.appendChild(titlebar);
  const el = document.createElement('div');
  el.className = 'empty-state';
  const title = document.createElement('span');
  title.className = 'empty-state__title';
  title.textContent = `Vista no disponible: ${vista}`;
  const sub = document.createElement('span');
  sub.textContent = 'La ventana secundaria no encontró su panel. Revisa la consola.';
  el.appendChild(title);
  el.appendChild(sub);
  host.appendChild(el);
  document.body.appendChild(host);
  document.body.classList.add('ventana-secundaria');
  if (app) app.style.display = 'none';
}
