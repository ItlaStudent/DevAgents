import { escapeText as esc, escapeAttribute } from '../design/html';
import { CoreApi } from '../bridge/core_api';
import { icons } from '../design/icons';

interface McpTool {
  name?: string;
  description?: string;
}

const PRESETS: Array<{ label: string; argv: string[]; hint: string; resolveWithHostDir?: boolean }> = [
  {
    label: 'Servidor MCP local (stdio)',
    argv: ['node', 'server.js'],
    hint: 'Cualquier servidor MCP que hable stdio en este equipo.',
  },
  {
    label: 'DevAgents MCP (motor propio)',
    // PRUEBA DE USUARIO 31-08: el preset mandaba 'devagents-mcp.exe' a secas
    // y el spawn lo buscaba en el CWD de la cabina — que no es el directorio
    // del binario cuando se lanza desde el explorador o desde otra carpeta.
    // El argv se RESUELVE AL USAR el preset (ver applyPreset): la ruta la
    // reporta el host por 'app.exedir', la única fuente fiable (WebView2
    // virtualiza el origen de la página).
    argv: [],
    hint: 'Expone el propio motor DevAgents como servidor MCP.',
    resolveWithHostDir: true,
  },
];

/**
 * Conectores MCP.
 *
 * El motor incluye cliente MCP nativo (da_mcp_*), pero la cabina no lo
 * alcanzaba: los símbolos ni siquiera estaban en la tabla de exports del DLL.
 * Este panel permite lanzar un servidor MCP por stdio, listar sus tools e
 * invocarlas, que es la vía para orquestar modelos externos desde DevAgents.
 */
export class McpPanel {
  private container: HTMLElement;
  private core: CoreApi | null;
  private tools: McpTool[] = [];
  private connected = false;

  constructor(container: HTMLElement, core?: CoreApi) {
    this.container = container;
    this.core = core ?? null;
    this.render();
    void this.refresh();
  }

  public async refresh(): Promise<void> {
    if (!this.core) return;
    try {
      const st = await this.core.mcpStatus();
      this.connected = !!st.connected;
      this.tools = this.connected ? ((await this.core.mcpTools()) as McpTool[]) : [];
    } catch {
      this.connected = false;
      this.tools = [];
    }
    this.render();
  }

  private render(): void {
    // Misma retícula que el Monitor: todo el ancho disponible con un tope de
    // lectura, centrado. Antes era `max-width:860px` sin `width` ni margen:
    // la tarjeta quedaba estrecha y pegada a la izquierda, dejando vacía la
    // mitad derecha de la pestaña.
    this.container.innerHTML = `
      <div class="col" style="gap:16px;padding:20px;max-width:1100px;width:100%;margin:0 auto">

        <div class="row" style="justify-content:space-between">
          <div class="col" style="gap:4px">
            <span style="font-size:15px;font-weight:600">Conectores MCP</span>
            <span class="card__subtitle">
              Conecta un servidor MCP por stdio para que el superagente pueda usar sus herramientas
              como parte de un plan.
            </span>
          </div>
          <span class="pill ${this.connected ? 'pill--online' : 'pill--offline'}">
            <span class="pill__dot"></span>${this.connected ? 'Conectado' : 'Sin conexión'}
          </span>
        </div>

        <div class="card col" style="gap:12px">
          <span class="section-label">Conectar servidor</span>
          <div class="field">
            <span class="field__label">Comando (argumentos separados por espacios)</span>
            <input class="input" id="mcp-argv" placeholder="npx -y @modelcontextprotocol/server-filesystem C:\\ruta" />
            <span class="field__hint">Se ejecuta como proceso hijo y se habla con él por stdio.</span>
          </div>
          <div class="field">
            <span class="field__label">Directorio de trabajo (opcional)</span>
            <input class="input" id="mcp-cwd" placeholder="Dejar vacío para usar el workspace actual" />
          </div>
          <div class="row" style="gap:8px;flex-wrap:wrap">
            ${PRESETS.map(
              (p, i) => `<button class="chip" data-preset="${i}" title="${escapeAttribute(p.hint)}">${esc(p.label)}</button>`
            ).join('')}
          </div>
          <div class="row" style="gap:8px">
            <button class="btn btn--primary" id="mcp-connect" title="Conectar con el servidor MCP">${icons.plug(13)} Conectar</button>
            <button class="btn" id="mcp-disconnect" title="Cerrar la conexión MCP" ${this.connected ? '' : 'disabled'}>Desconectar</button>
            <button class="btn btn--ghost" id="mcp-refresh" title="Recargar la lista de herramientas del servidor">${icons.refresh(13)} Actualizar</button>
          </div>
          <div id="mcp-feedback"></div>
        </div>

        <div class="card col" style="gap:10px">
          <span class="section-label">Acceso desde una IDE externa</span>
          <span class="subtle" style="font-size:11px">
            El servidor propio (devagents-mcp) exige autenticación para las tools que mutan estado,
            ejecutan procesos o tocan gobernanza. Pasa este token en <code>initialize.params.token</code>
            o llama la tool <code>authenticate</code>; las tools de lectura funcionan sin él.
          </span>
          <div class="row" style="gap:8px;align-items:center">
            <button class="btn" id="mcp-token-reveal" title="Mostrar u ocultar el token de sesión">Mostrar token</button>
            <button class="btn btn--ghost" id="mcp-token-copy" title="Copiar el token al portapapeles" disabled>Copiar</button>
          </div>
          <pre class="code-surface" id="mcp-token-value" style="padding:8px;border-radius:var(--radius-sm);display:none;user-select:all"></pre>
          <div id="mcp-token-feedback"></div>
        </div>

        <div class="card col" style="gap:10px">
          <span class="section-label">Herramientas expuestas (${this.tools.length})</span>
          ${
            this.tools.length
              ? this.tools
                  .map(
                    (t) => `<div class="row" style="gap:10px;align-items:flex-start">
                      <span class="list-item__icon" style="margin-top:2px">${icons.plug(13)}</span>
                      <div class="col grow" style="gap:2px">
                        <span class="mono" style="font-size:12px">${esc(String(t.name ?? ''))}</span>
                        <span class="subtle" style="font-size:11px">${esc(String(t.description ?? ''))}</span>
                      </div>
                      <button class="btn btn--sm" data-tool="${escapeAttribute(String(t.name ?? ''))}" title="Ejecutar esta herramienta con los argumentos indicados">Ejecutar</button>
                    </div>`
                  )
                  .join('')
              : '<span class="subtle">Conecta un servidor para ver sus herramientas.</span>'
          }
        </div>

        <div class="card col" id="mcp-invoke-card" style="gap:10px;display:none">
          <span class="section-label">Invocar herramienta</span>
          <div class="field">
            <span class="field__label">Herramienta</span>
            <input class="input" id="mcp-tool-name" placeholder="nombre_de_la_tool" />
          </div>
          <div class="field">
            <span class="field__label">Argumentos (JSON)</span>
            <textarea class="textarea" id="mcp-tool-args" rows="3">{}</textarea>
          </div>
          <button class="btn btn--primary" id="mcp-invoke" title="Ejecutar la herramienta seleccionada" style="align-self:flex-start">${icons.play(13)} Ejecutar</button>
          <pre class="code-surface" id="mcp-result" style="padding:10px;border-radius:var(--radius-sm);white-space:pre-wrap;max-height:240px;overflow:auto"></pre>
        </div>

      </div>`;

    this.bind();
  }

  private bind(): void {
    const argv = this.container.querySelector<HTMLInputElement>('#mcp-argv');
    const cwd = this.container.querySelector<HTMLInputElement>('#mcp-cwd');
    const feedback = this.container.querySelector<HTMLElement>('#mcp-feedback');

    this.container.querySelectorAll<HTMLElement>('[data-preset]').forEach((el) => {
      el.addEventListener('click', async () => {
        const p = PRESETS[Number(el.dataset.preset)];
        if (!p || !argv) return;
        if ('resolveWithHostDir' in p && p.resolveWithHostDir) {
          // El host es la única fuente fiable de su propio directorio.
          // Camino directo por el puente, resuelve con {payload:{dir}}.
          // (El BridgeClient global no está importado aquí a propósito: el
          // panel ya habla por this.core; para app.exedir se usa el raw.)
          // (El BridgeClient global no está importado aquí a propósito: el
          // panel ya habla por this.core; para app.exedir se usa el raw.)
          const raw = await new Promise<{ dir?: string }>((resolve) => {
            const wv = (window as unknown as {
              chrome?: { webview?: { addEventListener: Function; removeEventListener: Function; postMessage: Function } };
            }).chrome?.webview;
            if (!wv) {
              resolve({});
              return;
            }
            const h = (ev: Event) => {
              const m = (ev as unknown as { data: { id: number; payload?: { dir?: string } } }).data;
              if (m && m.id === 900001) {
                wv.removeEventListener('message', h);
                resolve(m.payload ?? {});
              }
            };
            wv.addEventListener('message', h);
            wv.postMessage(
              JSON.stringify({ id: 900001, kind: 'app.exedir', payload: {} })
            );
            setTimeout(() => resolve({}), 4000);
          });
          const dir = raw.dir ?? '';
          // MEDIDO 31-08: la ruta absoluta con espacios falla en el spawn de
          // este Zig, pero el exe PELADO + cwd=dir del host conecta (verificado
          // en vivo, evidencia 07-mcp-*). Es además el patrón de consola:
          // nombre del binario + directorio de trabajo.
          argv.value = 'devagents-mcp.exe';
          const cwdInput = this.container.querySelector<HTMLInputElement>('#mcp-cwd');
          if (cwdInput) cwdInput.value = dir;
          return;
        }
        argv.value = p.argv.join(' ');
      });
    });

    this.container.querySelector('#mcp-connect')?.addEventListener('click', async () => {
      if (!this.core || !argv) return;
      const parts = argv.value.trim().split(/\s+/).filter(Boolean);
      if (!parts.length) {
        this.say(feedback, 'Indica el comando del servidor MCP.', 'danger');
        return;
      }
      this.say(feedback, 'Conectando…', 'muted');
      try {
        await this.core.mcpConnect(parts, cwd?.value.trim() || '');
        this.say(feedback, 'Servidor conectado.', 'success');
        await this.refresh();
      } catch (e) {
        this.say(feedback, String(e), 'danger');
      }
    });

    this.container.querySelector('#mcp-disconnect')?.addEventListener('click', async () => {
      if (!this.core) return;
      try {
        await this.core.mcpDisconnect();
        await this.refresh();
      } catch (e) {
        this.say(feedback, String(e), 'danger');
      }
    });

    this.container.querySelector('#mcp-refresh')?.addEventListener('click', () => void this.refresh());

    const tokenValue = this.container.querySelector<HTMLElement>('#mcp-token-value');
    const tokenCopy = this.container.querySelector<HTMLButtonElement>('#mcp-token-copy');
    const tokenFeedback = this.container.querySelector<HTMLElement>('#mcp-token-feedback');
    this.container.querySelector('#mcp-token-reveal')?.addEventListener('click', async () => {
      if (!this.core || !tokenValue) return;
      try {
        const r = await this.core.mcpAuthToken();
        tokenValue.textContent = r.token || '(sin token resuelto — runtime :memory: sin DEVAGENTS_MCP_TOKEN)';
        tokenValue.style.display = '';
        if (tokenCopy) tokenCopy.disabled = !r.token;
      } catch (e) {
        this.say(tokenFeedback, String(e), 'danger');
      }
    });
    tokenCopy?.addEventListener('click', async () => {
      const text = tokenValue?.textContent || '';
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        this.say(tokenFeedback, 'Token copiado.', 'success');
      } catch {
        this.say(tokenFeedback, 'No se pudo copiar — selecciona el texto manualmente.', 'danger');
      }
    });

    const invokeCard = this.container.querySelector<HTMLElement>('#mcp-invoke-card');
    this.container.querySelectorAll<HTMLElement>('[data-tool]').forEach((el) => {
      el.addEventListener('click', () => {
        const nameInput = this.container.querySelector<HTMLInputElement>('#mcp-tool-name');
        if (nameInput) nameInput.value = el.dataset.tool || '';
        if (invokeCard) invokeCard.style.display = '';
        nameInput?.focus();
      });
    });

    this.container.querySelector('#mcp-invoke')?.addEventListener('click', async () => {
      const name = this.container.querySelector<HTMLInputElement>('#mcp-tool-name')?.value.trim();
      const argsRaw = this.container.querySelector<HTMLTextAreaElement>('#mcp-tool-args')?.value || '{}';
      const out = this.container.querySelector<HTMLElement>('#mcp-result');
      if (!this.core || !name || !out) return;
      let args: unknown;
      try {
        args = JSON.parse(argsRaw);
      } catch {
        out.textContent = 'Los argumentos no son JSON válido.';
        return;
      }
      out.textContent = 'Ejecutando…';
      try {
        out.textContent = await this.core.mcpCall(name, args);
      } catch (e) {
        out.textContent = String(e);
      }
    });
  }

  private say(host: HTMLElement | null, text: string, kind: 'muted' | 'success' | 'danger'): void {
    if (!host) return;
    const color =
      kind === 'success' ? 'var(--success)' : kind === 'danger' ? 'var(--danger)' : 'var(--fg-muted)';
    host.textContent = text;
    host.style.color = color;
    host.style.fontSize = '12px';
  }
}
