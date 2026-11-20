import { html, joinHtml, setHtml } from '../design/html';
export interface ModelCatalogEntry {
  id: string;
  name: string;
  provider: string;
  isFree: boolean;
  contextWindow: number;
  latencyMs: number;
}

export interface SessionEntry {
  id: string;
  title: string;
  messageCount: number;
  updatedAt: string;
  conversationId?: string | null;
}

/** Texto externo dentro de un template HTML: títulos de sesión y catálogo no son markup. */


export class CatalogSessionsPanel {
  private container: HTMLElement;
  private catalog: ModelCatalogEntry[] = [];
  private sessions: SessionEntry[] = [];
  private onReplaySession?: (id: string, conversationId?: string | null) => void;

  constructor(container: HTMLElement) {
    this.container = container;
    this.render();
  }

  public setCatalog(catalog: ModelCatalogEntry[]): void {
    this.catalog = [...catalog];
    this.renderCatalog();
  }

  public setSessions(sessions: SessionEntry[]): void {
    this.sessions = [...sessions];
    this.renderSessions();
  }

  public setOnReplaySession(cb: (id: string, conversationId?: string | null) => void): void {
    this.onReplaySession = cb;
  }

  /**
 * 9-nov (propietario: «el apartado de espacios se ve mal»): Spaces deja de ser una
   * sección del panel izquierdo y vive aquí, arriba, con el porqué a la vista:
   * cada orden ya crea el suyo sola. Debajo, historial y modelos en dos
   * columnas (una en ventanas estrechas), con los colores del tema y no con
   * literales (#238636, #1f6feb) que ignoraban el tema elegido.
   */
  private render(): void {
    this.container.innerHTML = `
      <div class="catalog-view">
        <header class="catalog-view__head">
          <h2 class="catalog-view__title">Spaces y sesiones</h2>
          <p class="catalog-view__lead">Cada orden que mandas desde el chat en un repositorio git trabaja en su propio space: una rama y una carpeta aparte, para que tu copia no se toque hasta que lo apruebes. No hace falta crearlos; aquí puedes crear uno a mano, archivarlos o podar los viejos.</p>
        </header>
        <section class="catalog-view__block" aria-label="Spaces">
          <div id="catalog-spaces"></div>
        </section>
        <div class="catalog-view__cols">
          <section class="catalog-view__block">
            <h3 class="section-label">Historial de sesiones</h3>
            <div id="sessions-list" class="catalog-view__list"></div>
          </section>
          <section class="catalog-view__block">
            <h3 class="section-label">Modelos disponibles</h3>
            <div id="catalog-list" class="catalog-view__list"></div>
          </section>
        </div>
      </div>
    `;
  }

  /** Donde main.ts monta el panel de Spaces (SpacesPanel necesita el CoreApi). */
  public spacesHost(): HTMLElement | null {
    return this.container.querySelector<HTMLElement>('#catalog-spaces');
  }

  private renderCatalog(): void {
    const listEl = this.container.querySelector('#catalog-list');
    if (!listEl) return;

    if (this.catalog.length === 0) {
      listEl.innerHTML = '<div class="subtle catalog-view__empty">Sin modelos todavía: configura una clave, una CLI u Ollama en Configuración.</div>';
      return;
    }
    setHtml(listEl, joinHtml(this.catalog
      .map((m) => html`
        <div class="catalog-row">
          <div class="catalog-row__main">
            <span class="catalog-row__title">${m.name}</span>
            <span class="catalog-row__meta">${m.provider} · ${Number(m.contextWindow).toLocaleString()} ctx</span>
          </div>
          <span class="badge ${m.isFree ? 'badge--success' : 'badge--accent'}">${m.isFree ? 'Gratis' : 'Pago'}</span>
        </div>
      `)));
  }

  private renderSessions(): void {
    const listEl = this.container.querySelector('#sessions-list');
    if (!listEl) return;

    if (this.sessions.length === 0) {
      listEl.innerHTML = '<div class="subtle catalog-view__empty">Todavía no hay sesiones.</div>';
      return;
    }
    setHtml(listEl, joinHtml(this.sessions
      .map((s) => html`
        <div class="catalog-row">
          <div class="catalog-row__main">
            <span class="catalog-row__title">${s.title}</span>
            <span class="catalog-row__meta">${s.messageCount} mensajes${s.updatedAt ? ' · ' : ''}${s.updatedAt}</span>
          </div>
          <button data-id="${s.id}" data-conversation="${s.conversationId}" class="btn btn--sm btn-replay" title="Repetir esta sesión como referencia">Repetir</button>
        </div>
      `)));

    listEl.querySelectorAll('.btn-replay').forEach((btn) => {
      btn.addEventListener('click', () => {
        const id = btn.getAttribute('data-id');
        if (id && this.onReplaySession) {
          this.onReplaySession(id, btn.getAttribute('data-conversation'));
        }
      });
    });
  }
}
