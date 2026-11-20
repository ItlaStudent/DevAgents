import { escapeText as esc, escapeAttribute } from '../design/html';
import { CoreApi, SpaceItem, WorktreeConfigStatus } from '../bridge/core_api';
import { icons } from '../design/icons';
import { notice } from '../design/notice';

/**
 * Spaces: un git worktree por orden.
 *
 * `core/src/spaces.zig` crea la rama `devagents/<nombre>`, el worktree bajo
 * `.devagents/spaces/<nombre>` (antes `.beats`) y su fila en runtime.db desde F5. Lo que faltaba era
 * todo el camino de vuelta: no existía export `da_space*`, ni handler en el
 * puente, ni llamador — y la vista "Spaces" acababa listando MONTAJES.
 *
 * La versión anterior de este archivo era un prototipo y nadie lo importaba,
 * así que nada de esto se notaba: colores en crudo (`#2563eb`, `#334155`) que
 * ignoraban el tema, textos en inglés, un botón "Ship & Merge" sin nada
 * detrás, y tres kinds (`space.create`, `space.prune`, `ship.merge`) que no
 * existen en el puente. Pedía el nombre con `window.prompt()`, que WebView2
 * desactiva por defecto: no aparecía nada y devolvía null en silencio.
 */
export class SpacesPanel {
  private container: HTMLElement;
  private core: CoreApi;
  private projectId: string;
  private spaces: SpaceItem[] = [];
  private loading = true;
  private error = '';
  /** E5.05: estado de `.devagents/worktree.json` del proyecto (inspección). */
  private configStatus: WorktreeConfigStatus | null = null;
  private configError = '';
  /** Se abre al pulsar "Nuevo space" y se cierra al crear o cancelar. */
  private creating = false;
  /** true cuando la barra lateral ya muestra otra vista: no volver a pintar. */
  private detached = false;

  constructor(container: HTMLElement, core: CoreApi, projectId = 'default') {
    this.container = container;
    this.core = core;
    this.projectId = projectId;
    void this.refresh();
  }

  /**
   * El refresh() del constructor sigue en vuelo cuando el usuario cambia de
   * pestaña; sin desenganche el render posterior estampa la lista de spaces
   * sobre la barra lateral de la vista nueva.
   */
  /** Carpeta abierta (`fs.list`), para separar los spaces de aquí y los de otras carpetas. */
  private root = '';

  public detach(): void {
    this.detached = true;
  }

  /** Recarga desde el motor y repinta. */
  public async refresh(): Promise<void> {
    this.loading = true;
    this.render();
    try {
      const [spacesR, configR, rootR] = await Promise.allSettled([
        this.core.spaces(this.projectId),
        this.core.worktreeConfig(this.projectId),
        this.core.listDir(''),
      ]);
      this.root = rootR.status === 'fulfilled' ? String(rootR.value?.root || '') : '';
      if (spacesR.status === 'fulfilled') {
        this.spaces = spacesR.value;
        this.error = '';
      } else {
        this.error = String(spacesR.reason);
        this.spaces = [];
      }
      // La tarjeta de configuración es aparte: su fallo no debe tumbar la
      // lista de spaces (la inspección es información, no el dato central).
      if (configR.status === 'fulfilled') {
        this.configStatus = configR.value;
        this.configError = '';
      } else {
        this.configStatus = null;
        this.configError = String(configR.reason);
      }
    } finally {
      this.loading = false;
      this.render();
    }
  }


  private fecha(epochSeconds: number): string {
    if (!epochSeconds) return '—';
    // El motor sella en segundos; Date espera milisegundos.
    return new Date(epochSeconds * 1000).toLocaleString();
  }

  private render(): void {
    if (this.detached) return;
    // Un solo space en modo degradado basta para avisar: significa que el
    // proyecto no es un repositorio git, así que el aislamiento es por copia de
    // directorio, sin rama y sin posibilidad de fusionar.
    const degradado = this.spaces.some((s) => s.isNonGitDegraded);

    this.container.innerHTML = `
      <div class="col" style="gap:12px;padding:12px">
        <!-- Encabezado en COLUMNA, no en fila.
             Este panel vive en la barra lateral, que es estrecha. Con título,
             descripción y botones en la misma fila, el reparto de espacio
             recortaba las etiquetas: "Podar" se leía "Poda…" y la descripción
             quedaba en una columna de dos palabras por línea. Apilar cuesta una
             fila de alto y hace que se lea a cualquier ancho. -->
        <div class="col" style="gap:8px">
          <div class="col" style="gap:2px;min-width:0">
            <span class="section-label">Spaces</span>
            <span class="subtle" style="font-size:11px">
              Cada orden del agente trabaja en su propia rama y su propio directorio.
            </span>
          </div>
          <!-- flex-wrap: con el panel muy estrecho los botones se apilan en vez
               de encogerse hasta perder su texto. flex:1 1 auto reparte el ancho
               sobrante entre los dos cuando caben en la misma línea. -->
          <div class="row" style="gap:6px;flex-wrap:wrap">
            <button class="btn" id="space-new" title="Crear un espacio de trabajo nuevo" style="flex:1 1 auto;min-width:0;justify-content:center">
              ${icons.plus(14)}<span>Nuevo space</span>
            </button>
            <button class="btn" id="space-prune" style="flex:1 1 auto;min-width:0;justify-content:center"
                    title="Borra los spaces archivados y poda los worktrees colgantes">
              ${icons.trash(14)}<span>Podar</span>
            </button>
          </div>
        </div>

        ${
          degradado
            ? `<div class="card" style="border-left:3px solid var(--danger);padding:10px 12px">
                 <strong>Modo degradado sin git.</strong>
                 <span class="subtle">Este proyecto no es un repositorio, así que el aislamiento
                 es por copia de directorio: no hay rama y no se puede fusionar.</span>
               </div>`
            : ''
        }

        ${this.tarjetaConfig()}

        ${
          this.creating
            ? `<div class="card row" style="gap:8px;padding:10px 12px;align-items:center">
                 <input class="input mono" id="space-name" placeholder="nombre-del-space" style="flex:1" />
                 <button class="btn" id="space-create-ok" title="Crear el espacio con el nombre indicado">Crear</button>
                 <button class="btn" id="space-create-cancel" title="Cancelar la creación">Cancelar</button>
               </div>`
            : ''
        }

        <div id="space-msg" class="subtle" style="font-size:11px"></div>

        ${this.cuerpo()}
      </div>`;

    this.enlazar();
  }

  private cuerpo(): string {
    if (this.loading) {
      return '<div class="subtle" style="padding:8px">Consultando spaces…</div>';
    }
    if (this.error) {
      return `<div class="empty-state" style="color:var(--danger)">${esc(this.error)}</div>`;
    }
    if (this.spaces.length === 0) {
      return `<div class="empty-state">
                ${icons.spaces(22)}
                <span class="empty-state__title">Ningún space activo</span>
                <span>Se crea uno por orden automáticamente, o puedes crearlo tú
                para aislar un trabajo concreto.</span>
              </div>`;
    }
    // Censo del 9-nov (R2): la lista mezclaba los spaces de TODAS las carpetas
    // (también los heredados de DevAgents, con rutas que ya no existen) en tarjetas
    // grandes. Como la maqueta: filas compactas de la carpeta actual y, aparte y
    // plegados, los de otras carpetas, que se pueden archivar o podar igual.
    const aqui = this.spaces.filter((s) => this.esDeAqui(s));
    const otros = this.spaces.filter((s) => !this.esDeAqui(s));
    const filas = (xs: SpaceItem[], propio: boolean): string => xs.map((s) => this.fila(s, propio)).join('');
    const vacioAqui = aqui.length === 0
      ? `<div class="subtle" style="font-size:11px;padding:2px 4px">Ningún space en esta carpeta. Se crea uno por orden automáticamente, o puedes crearlo tú.</div>`
      : '';
    const plegados = otros.length
      ? `<details class="space-otros"><summary class="subtle" style="font-size:11px;cursor:pointer;padding:2px 4px">${otros.length} de otras carpetas</summary>
           <div class="col" style="gap:2px;margin-top:4px">${filas(otros, false)}</div></details>`
      : '';
    return `<div class="col" style="gap:2px">${vacioAqui}${filas(aqui, true)}${plegados}</div>`;
  }

  /** La ruta del worktree cae dentro de la carpeta abierta (sin distinguir mayúsculas). */
  private esDeAqui(s: SpaceItem): boolean {
    if (!this.root) return true;
    const norm = (x: string): string => x.replace(/\//g, '\\').replace(/\\+$/, '').toLowerCase();
    const raiz = norm(this.root).replace(/\\devagents-workspace$/, '');
    const ruta = norm(s.worktreePath || '');
    return ruta === raiz || ruta.startsWith(raiz + '\\');
  }

  /**
   * E5.05: estado de `.devagents/worktree.json` para este proyecto. Tres
   * estados honestos: válido (copias + setup + timeout), inválido (con la
   * causa exacta del parser) o ausente (con las sugerencias por lockfiles
   * que el motor anuncia en `worktree_setup_suggested` — nunca se ejecutan).
   */
  private tarjetaConfig(): string {
    if (this.configError) {
      return `<div class="card" style="border-left:3px solid var(--danger);padding:10px 12px">
        <strong>Preparación del worktree.</strong>
        <span class="subtle">No se pudo consultar la configuración: ${esc(this.configError)}</span>
      </div>`;
    }
    const c = this.configStatus;
    if (!c) return '';
    if (c.exists && !c.valid) {
      return `<div class="card" style="border-left:3px solid var(--danger);padding:10px 12px">
        <strong>.devagents/worktree.json no es válido.</strong>
        <span class="subtle">${esc(c.detail || 'El parser lo rechazó.')}</span>
        <span class="subtle" style="font-size:11px">Toda orden que necesite space fallará con esta causa hasta corregirlo.</span>
      </div>`;
    }
    if (c.exists && c.valid) {
      const partes: string[] = [];
      partes.push(c.copy.length === 1 ? '1 archivo a copiar' : `${c.copy.length} archivos a copiar`);
      const setup = c.setup_windows ?? c.setup_posix;
      if (setup) partes.push(`setup <span class="mono">${esc(setup)}</span>`);
      partes.push(`timeout ${c.timeout_s} s`);
      return `<div class="card col" style="gap:4px;padding:10px 12px">
        <div class="row" style="gap:6px;align-items:center">
          <span class="pill">worktree.json</span>
          <strong>Preparación configurada</strong>
        </div>
        <span class="subtle" style="font-size:11px">${partes.join(' · ')}</span>
        <span class="subtle" style="font-size:11px">El setup pide aprobación la primera vez y cada vez que cambie su hash.</span>
      </div>`;
    }
    // Sin archivo: sugerencias por lockfiles (las mismas que emite el evento
    // worktree_setup_suggested en la orden). Nunca se ejecutan solas.
    const sugs = c.suggestions
      .map((s) => `<span class="mono">${esc(s.command)}</span> <span class="subtle">(por ${esc(s.lockfile)})</span>`)
      .join('<br>');
    return `<div class="card col" style="gap:4px;padding:10px 12px">
      <div class="row" style="gap:6px;align-items:center">
        <span class="pill">worktree.json</span>
        <strong>Sin preparación configurada</strong>
      </div>
      <span class="subtle" style="font-size:11px">El worktree nace vacío: sin copias ni script de setup.</span>
      ${sugs ? `<span class="subtle" style="font-size:11px">El motor sugiere por tus lockfiles:<br>${sugs}</span>` : ''}
    </div>`;
  }

  /** Fila compacta (maqueta v2, `.item.indent`): punto, «nombre · rama» y archivar. */
  private fila(s: SpaceItem, propio: boolean): string {
    const titulo = `${s.worktreePath}\nRama ${s.branch} · creado ${this.fecha(s.createdAt)}${s.isNonGitDegraded ? '\nModo degradado sin git' : ''}`;
    return `<div class="row space-row" style="gap:8px;align-items:center;min-height:26px;padding:2px 4px;border-radius:6px" title="${escapeAttribute(titulo)}">
        <i class="dot ${propio ? 'ok' : ''}" aria-hidden="true" style="width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:${propio ? 'var(--success, #5fb36b)' : 'var(--fg-subtle)'}"></i>
        <span class="mono truncate" style="flex:1 1 auto;min-width:0;font-size:12px">${esc(s.name)} · ${esc(s.branch)}</span>
        <button class="icon-btn space-archive" data-id="${escapeAttribute(s.id)}" style="flex:0 0 auto"
                title="Retirar worktree y archivar" aria-label="Retirar worktree y archivar ${escapeAttribute(s.name)}">${icons.trash(13)}</button>
      </div>`;
  }

  private tarjeta(s: SpaceItem): string {
    return `
      <div class="card col" style="gap:6px;padding:10px 12px">
        <!-- flex-wrap tambien aqui: el nombre del space puede ser largo y en la
             barra lateral competia con el boton por el ancho, dejando ambos
             ilegibles. Ahora el boton baja a su propia linea si hace falta. -->
        <div class="row" style="justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap">
          <div class="row" style="gap:8px;align-items:center;min-width:0;flex:1 1 140px">
            <span class="list-item__icon" style="flex:0 0 auto">${icons.spaces(14)}</span>
            <span class="mono truncate" style="font-weight:600;min-width:0">${esc(s.name)}</span>
            <span class="pill" style="flex:0 0 auto">${s.kind === 'order' ? 'orden' : 'checkout principal'}</span>
          </div>
          <button class="btn space-archive" data-id="${escapeAttribute(s.id)}" style="flex:0 0 auto"
                  title="Retira el worktree y archiva el space">
            ${icons.trash(13)}<span>Archivar</span>
          </button>
        </div>
        <div class="col" style="gap:2px">
          <span class="subtle mono truncate" style="font-size:11px" title="${escapeAttribute(s.worktreePath)}">
            ${esc(s.worktreePath)}
          </span>
          <span class="subtle" style="font-size:11px">
            Rama <span class="mono">${esc(s.branch)}</span> · creado ${esc(this.fecha(s.createdAt))}
          </span>
        </div>
      </div>`;
  }

  private enlazar(): void {
    const msg = this.container.querySelector<HTMLElement>('#space-msg');
    const fallo = (e: unknown): void => {
      if (msg) {
        msg.textContent = String(e);
        msg.style.color = 'var(--danger)';
      }
    };

    this.container.querySelector('#space-new')?.addEventListener('click', () => {
      this.creating = true;
      this.render();
      this.container.querySelector<HTMLInputElement>('#space-name')?.focus();
    });

    this.container.querySelector('#space-create-cancel')?.addEventListener('click', () => {
      this.creating = false;
      this.render();
    });

    const crear = (): void => {
      const input = this.container.querySelector<HTMLInputElement>('#space-name');
      const name = input?.value.trim();
      if (!name) return;
      void this.core
        .createSpace(name, this.projectId)
        .then((s) => {
          this.creating = false;
          notice(`Space «${s.name}» creado en la rama ${s.branch}`, 'ok');
          return this.refresh();
        })
        .catch(fallo);
    };

    this.container.querySelector('#space-create-ok')?.addEventListener('click', crear);
    this.container.querySelector('#space-name')?.addEventListener('keydown', (ev) => {
      const k = ev as KeyboardEvent;
      if (k.key === 'Enter') crear();
      if (k.key === 'Escape') {
        this.creating = false;
        this.render();
      }
    });

    this.container.querySelectorAll<HTMLElement>('.space-archive').forEach((el) => {
      el.addEventListener('click', () => {
        const id = Number(el.dataset.id || 0);
        if (!id) return;
        void this.core
          .archiveSpace(id)
          .then(() => this.refresh())
          .catch(fallo);
      });
    });

    this.container.querySelector('#space-prune')?.addEventListener('click', () => {
      void this.core
        .pruneSpaces(this.projectId)
        .then((r) => {
          // Se dice el número aunque sea cero: "no había nada que podar" es
          // información, y un botón que no responde parece roto.
          notice(
            r.pruned > 0
              ? `${r.pruned} space(s) archivado(s) eliminado(s).`
              : 'No había spaces archivados que podar.',
            r.pruned > 0 ? 'ok' : 'info'
          );
          return this.refresh();
        })
        .catch(fallo);
    });
  }
}
