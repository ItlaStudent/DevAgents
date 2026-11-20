import { CoreApi, IssueItem, IssueRequest } from '../bridge/core_api';

/** Issue content is rendered as text, never markup or executable instructions. */
export class IssuesPanel {
  private selected: IssueRequest | null = null;
  private busy = false;

  constructor(private container: HTMLElement, private core: CoreApi,
    private onImport: (request: IssueRequest, prompt: string) => void) {
    container.innerHTML = `<section class="col" style="gap:14px;padding:20px;max-width:920px;margin:auto">
      <h2>Incidencias</h2>
      <p class="subtle">El contenido externo es dato no confiable. Importar no envía una orden. El comportamiento del modelo no se puede garantizar.</p>
      <div class="col" style="gap:8px">
        <label>Fuente <select class="input" id="issues-source">
          <option value="github">GitHub</option><option value="gitea">Gitea</option><option value="gitlab">GitLab</option>
          <option value="linear">Linear</option><option value="jira">Jira Cloud</option>
          ${devFixtures() ? '<option value="fixture">Fuente simulada (datos sintéticos)</option>' : ''}
        </select></label>
        <label>Servidor <input class="input" id="issues-base" value="https://github.com" spellcheck="false"></label>
        <label>Repositorio / proyecto / equipo <input class="input" id="issues-project" spellcheck="false"></label>
        <button class="btn" id="issues-list">Listar incidencias</button>
      </div>
      <div class="subtle" id="issues-status" role="status" aria-live="polite">Las credenciales se gestionan en Configuración > Proveedores; no se muestran aquí.</div>
      <div class="col" style="gap:8px" id="issues-results"></div>
      <section class="col" style="gap:10px" id="issues-detail" hidden>
        <h3 id="issues-title"></h3>
        <div class="subtle" id="issues-url" style="overflow-wrap:anywhere"></div>
        <pre class="code-surface" id="issues-body" style="white-space:pre-wrap;overflow-wrap:anywhere;max-height:300px;overflow:auto;padding:12px"></pre>
        <button class="btn btn--primary" id="issues-import">Crear orden desde incidencia</button>
        <label>Comentario explícito <textarea class="textarea" id="issues-comment-body" rows="3" maxlength="32768"></textarea></label>
        <button class="btn" id="issues-comment">Comentar en la incidencia</button>
      </section>
    </section>`;
    this.el<HTMLSelectElement>('issues-source').addEventListener('change', () => {
      const source = this.el<HTMLSelectElement>('issues-source').value;
      const bases: Record<string, string> = { github: 'https://github.com', gitea: '', gitlab: 'https://gitlab.com',
        linear: 'https://api.linear.app', jira: '', fixture: 'https://fixtures.invalid' };
      this.el<HTMLInputElement>('issues-base').value = bases[source] ?? '';
      if (source === 'fixture') this.el<HTMLInputElement>('issues-project').value = 'Astra/devagents-sandbox';
      this.selected = null;
      this.el('issues-detail').hidden = true;
      this.el('issues-results').replaceChildren();
    });
    this.el('issues-list').addEventListener('click', () => void this.run(async () => {
      this.selected = null;
      this.el('issues-detail').hidden = true;
      const request = this.request();
      const result = await this.core.issuesList(request);
      const items = result.issues;
      if (!Array.isArray(items)) throw new Error('Respuesta de incidencias inválida.');
      const results = this.el('issues-results');
      results.replaceChildren();
      for (const item of items) {
        const button = document.createElement('button');
        button.className = 'btn';
        button.dataset.issueId = String(item.id);
        button.textContent = `${item.id} · ${item.title}`;
        button.addEventListener('click', () => void this.run(async () => {
          this.selected = null;
          this.el('issues-detail').hidden = true;
          const reference = { ...request, issue_id: String(item.id) };
          this.showIssue(await this.core.issueRead(reference));
          this.selected = reference;
          return 'Incidencia leída como dato no confiable.';
        }));
        results.appendChild(button);
      }
      return `${items.length} incidencias · primera página (máximo ${result.limit})${request.fixture ? ' · FUENTE SIMULADA, datos sintéticos' : ''}.`;
    }));
    this.el('issues-import').addEventListener('click', () => void this.run(async () => {
      if (!this.selected) throw new Error('Elige una incidencia.');
      const draft = await this.core.issuePrompt(this.selected);
      if (typeof draft.prompt !== 'string' || !draft.prompt.trim()) throw new Error('El motor no devolvió un bloque de datos.');
      this.onImport(this.selected, draft.prompt);
      return 'Borrador importado. Revisa el compositor antes de enviar.';
    }));
    // The only path to comment is this explicit click; listing, reading and importing never call it.
    this.el('issues-comment').addEventListener('click', () => void this.run(async () => {
      if (!this.selected) throw new Error('Elige una incidencia.');
      const body = this.el<HTMLTextAreaElement>('issues-comment-body').value.trim();
      if (!body) throw new Error('El comentario está vacío.');
      const result = await this.core.issueComment(this.selected, body);
      if (result.posted !== true) throw new Error('El motor no confirmó el comentario.');
      this.el<HTMLTextAreaElement>('issues-comment-body').value = '';
      return 'Comentario enviado por acción explícita.';
    }));
  }

  private el<T extends HTMLElement = HTMLElement>(id: string): T {
    const node = this.container.querySelector<T>(`#${id}`);
    if (!node) throw new Error(`Control de incidencias ausente: ${id}`);
    return node;
  }

  private request(): IssueRequest {
    const source = this.el<HTMLSelectElement>('issues-source').value;
    const base_url = this.el<HTMLInputElement>('issues-base').value.trim();
    const project = this.el<HTMLInputElement>('issues-project').value.trim();
    if (!project || !base_url) throw new Error('Indica el servidor y el proyecto.');
    return { source: source === 'fixture' ? 'gitea' : source as IssueRequest['source'], base_url, project,
      ...(source === 'fixture' ? { fixture: true } : {}) };
  }

  private showIssue(item: IssueItem): void {
    this.el('issues-title').textContent = item.title;
    this.el('issues-url').textContent = item.url;
    this.el('issues-body').textContent = item.body;
    this.el<HTMLTextAreaElement>('issues-comment-body').value = '';
    this.el('issues-detail').hidden = false;
  }

  private async run(action: () => Promise<string>): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.container.querySelectorAll<HTMLButtonElement>('button').forEach(button => { button.disabled = true; });
    this.el('issues-status').textContent = 'Consultando el motor…';
    try {
      this.el('issues-status').textContent = await action();
    } catch (error) {
      this.el('issues-status').textContent = `Error: ${String(error)}`;
    } finally {
      this.busy = false;
      this.container.querySelectorAll<HTMLButtonElement>('button').forEach(button => { button.disabled = false; });
    }
  }
}

/** 9-nov (censo de salida): la fuente simulada es para probar el flujo sin red;
 *  a un usuario le parecía una fuente más. Solo se ofrece en modo desarrollo
 *  (`localStorage['devagents.dev.fixtures'] = '1'`). */
function devFixtures(): boolean {
  try { return localStorage.getItem('devagents.dev.fixtures') === '1'; } catch { return false; }
}
