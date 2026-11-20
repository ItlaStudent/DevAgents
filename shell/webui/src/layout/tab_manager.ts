import { escapeText as escapeHtml } from '../design/html';


export interface Tab {
  id: string;
  title: string;
  path: string;
  isDirty: boolean;
  isPinned: boolean;
  isPreview: boolean;
}

export class TabManager {
  private tabs: Tab[] = [];
  private activeTabId: string | null = null;
  private container: HTMLElement | null = null;
  private itemsHost: HTMLElement | null = null;
  private onSelectCallbacks: Array<(tab: Tab) => void> = [];
  private onCloseCallbacks: Array<(tab: Tab) => void> = [];
  private onPopoutCallbacks: Array<(tab: Tab) => void> = [];

  constructor(container?: HTMLElement) {
    if (container) {
      this.container = container;
      this.itemsHost = this.resolveItemsHost(container);
    }
  }

  public setContainer(container: HTMLElement) {
    this.container = container;
    this.itemsHost = this.resolveItemsHost(container);
    this.render();
  }

  /**
   * `#tab-bar` ya no es solo la lista de pestañas: el conmutador Agente/Dev
   * (siempre visible) vive ahí como hermano de `#tab-items`. Repintar solo
   * `#tab-items` evita borrar el conmutador en cada apertura/cierre de
   * pestaña. Si el contenedor no trae ese hijo (arneses de prueba antiguos),
   * se usa el propio contenedor como antes.
   */
  private resolveItemsHost(container: HTMLElement): HTMLElement {
    return container.querySelector<HTMLElement>('#tab-items') || container;
  }

  public onTabSelect(cb: (tab: Tab) => void) {
    this.onSelectCallbacks.push(cb);
  }

  /**
   * H3 — cerrar una pestaña tiene que avisar a quien guarda su estado.
   *
   * El editor conserva por ruta el texto sin guardar y la posición del cursor.
   * Sin este aviso esos datos sobrevivían al cierre: cerrabas una pestaña con
   * cambios, la volvías a abrir, y en vez del archivo del disco te encontrabas
   * el borrador viejo, marcado como modificado y sin forma de deshacerlo.
   */
  public onTabClose(cb: (tab: Tab) => void) {
    this.onCloseCallbacks.push(cb);
  }

  /** E5.22 — «Abrir en ventana nueva»: el clic en ⧉ lleva la ruta, main decide. */
  public onTabPopout(cb: (tab: Tab) => void) {
    this.onPopoutCallbacks.push(cb);
  }

  public openTab(path: string, title: string, isPreview = false): Tab {
    const existing = this.tabs.find((t) => t.path === path);
    if (existing) {
      if (!isPreview && existing.isPreview) {
        existing.isPreview = false;
      }
      this.activeTabId = existing.id;
      this.render();
      this.notifySelect(existing);
      return existing;
    }

    if (isPreview) {
      const previewIndex = this.tabs.findIndex((t) => t.isPreview);
      if (previewIndex !== -1) {
        this.tabs.splice(previewIndex, 1);
      }
    }

    const newTab: Tab = {
      id: 'tab-' + Math.random().toString(36).substr(2, 9),
      title,
      path,
      isDirty: false,
      isPinned: false,
      isPreview,
    };

    this.tabs.push(newTab);
    this.activeTabId = newTab.id;
    this.render();
    this.notifySelect(newTab);
    return newTab;
  }

  public closeTab(id: string) {
    const index = this.tabs.findIndex((t) => t.id === id);
    if (index !== -1) {
      const [closed] = this.tabs.splice(index, 1);
      for (const cb of this.onCloseCallbacks) cb(closed);
      if (this.activeTabId === id) {
        if (this.tabs.length > 0) {
          const nextIndex = Math.min(index, this.tabs.length - 1);
          this.activeTabId = this.tabs[nextIndex].id;
          this.notifySelect(this.tabs[nextIndex]);
        } else {
          this.activeTabId = null;
        }
      }
      this.render();
    }
  }

  public getTabs(): Tab[] {
    return this.tabs;
  }

  public getActiveTab(): Tab | null {
    return this.tabs.find((t) => t.id === this.activeTabId) || null;
  }

  /** Refleja el foco de un panel sin volver a abrir su archivo. */
  public focusPath(path: string): void {
    const tab = this.tabs.find(t => t.path === path);
    if (!tab || tab.id === this.activeTabId) return;
    this.activeTabId = tab.id;
    this.render();
  }

  public setDirty(id: string, isDirty: boolean) {
    const tab = this.tabs.find((t) => t.id === id);
    if (tab) {
      tab.isDirty = isDirty;
      this.render();
    }
  }

  public render() {
    if (!this.container || !this.itemsHost) return;

    // Antes, sin pestañas la barra entera se ocultaba (regla .tabs[data-empty])
    // para no dejar una franja vacía con aspecto de bug. Ahora la barra
    // siempre aloja el conmutador Agente/Dev, así que `data-empty` queda solo
    // como bandera informativa y ya no oculta nada.
    this.container.dataset.empty = this.tabs.length === 0 ? 'true' : 'false';
    if (this.tabs.length === 0) {
      this.itemsHost.innerHTML = '';
      return;
    }

    let html = '';
    for (const t of this.tabs) {
      const isActive = t.id === this.activeTabId;
      html += `
        <div class="tab tab-item${isActive ? ' is-active' : ''}" data-id="${t.id}">
          <span>${escapeHtml(t.title)}</span>
          ${t.isDirty ? `<span style="color: var(--warning); font-size: 9px;">&#9679;</span>` : ''}
          <span class="tab__popout btn-popout-tab" data-id="${t.id}" title="Abrir en ventana nueva">&#10697;</span>
          <span class="tab__close btn-close-tab" data-id="${t.id}">&#10005;</span>
        </div>
      `;
    }

    this.itemsHost.innerHTML = html;

    const items = this.itemsHost.querySelectorAll('.tab-item');
    items.forEach((item) => {
      item.addEventListener('click', (e) => {
        const id = (e.currentTarget as HTMLElement).getAttribute('data-id');
        if (id) {
          this.activeTabId = id;
          this.render();
          const tab = this.tabs.find((t) => t.id === id);
          if (tab) this.notifySelect(tab);
        }
      });
    });

    const popoutBtns = this.itemsHost.querySelectorAll('.btn-popout-tab');
    popoutBtns.forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const id = (e.currentTarget as HTMLElement).getAttribute('data-id');
        const tab = this.tabs.find((t) => t.id === id);
        if (tab) for (const cb of this.onPopoutCallbacks) cb(tab);
      });
    });

    const closeBtns = this.itemsHost.querySelectorAll('.btn-close-tab');
    closeBtns.forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const id = (e.currentTarget as HTMLElement).getAttribute('data-id');
        if (id) this.closeTab(id);
      });
    });
  }

  private notifySelect(tab: Tab) {
    for (const cb of this.onSelectCallbacks) {
      cb(tab);
    }
  }
}
