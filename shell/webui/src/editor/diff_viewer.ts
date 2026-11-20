import { escapeText as esc } from '../design/html';
import { CoreApi } from '../bridge/core_api';
import { BridgeClient } from '../bridge/client';
import { icons } from '../design/icons';

/**
 * Visor de diffs con aceptación/rechazo por hunk.
 *
 * Hasta ahora un agente podía escribir en el repositorio sin que nadie
 * revisara nada: el `HunkManager` del host ya sabe aceptar/rechazar, pero no
 * había ninguna interfaz que lo llamara. Este componente calcula el diff por
 * líneas (LCS) entre el archivo actual y el contenido propuesto, lo agrupa en
 * hunks con contexto, y deja que el usuario decida hunk a hunk.
 *
 * Detalle importante del backend (visto en `shell/host/bridge.cpp` y
 * `hunk_manager.cpp`): `hunk.accept`/`hunk.reject` aplican únicamente el rango
 * de líneas del hunk indicado (`startLine`, `originalLineCount`, `newLineCount`)
 * sobre el archivo en disco, así que aquí se envían solo las líneas de ese
 * hunk. El host valida que el rango siga coincidiendo con el original y
 * rechaza la escritura si el archivo cambió desde el diff.
 * Además viaja `baseFileContent` con el original completo del diff: el
 * rechazo de un hunk de solo borrado necesita ese contexto para comprobar que
 * las líneas vecinas del punto de reinserción no cambiaron (sin él, el host
 * falla sin escribir). Los nombres de campo coinciden con `core_api.ts`.
 */

export interface DiffHunk {
  id: number;
  startLine: number;
  originalLines: string[];
  newLines: string[];
}

type OpType = 'equal' | 'add' | 'del';

interface DiffOp {
  type: OpType;
  text: string;
  origLineNo?: number;
  newLineNo?: number;
}

type Resolution = 'pending' | 'accepted' | 'rejected';

interface WorkingHunk extends DiffHunk {
  endLine: number;
  addedCount: number;
  removedCount: number;
  opsStart: number;
  opsEnd: number;
  resolution: Resolution;
  error: string | null;
}

const CONTEXT_LINES = 3;
const MAX_HUNKS = 200;
// Por encima de esto el cuadro de LCS (m*n) deja de ser razonable en el
// hilo de UI; en vez de colgar el navegador se trata el archivo como un
// reemplazo total (un único hunk con todo eliminado + todo añadido).
const MAX_LCS_CELLS = 4_000_000;

/** Diff por líneas mediante subsecuencia común más larga (LCS), sin dependencias. */
function computeDiffOps(origLines: string[], newLines: string[]): DiffOp[] {
  const m = origLines.length;
  const n = newLines.length;

  if (m * n > MAX_LCS_CELLS) {
    const ops: DiffOp[] = [];
    origLines.forEach((text, i) => ops.push({ type: 'del', text, origLineNo: i + 1 }));
    newLines.forEach((text, j) => ops.push({ type: 'add', text, newLineNo: j + 1 }));
    return ops;
  }

  const dp: Int32Array[] = new Array(m + 1);
  for (let i = 0; i <= m; i++) dp[i] = new Int32Array(n + 1);
  for (let i = m - 1; i >= 0; i--) {
    const row = dp[i];
    const nextRow = dp[i + 1];
    for (let j = n - 1; j >= 0; j--) {
      row[j] =
        origLines[i] === newLines[j] ? nextRow[j + 1] + 1 : Math.max(nextRow[j], row[j + 1]);
    }
  }

  const ops: DiffOp[] = [];
  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (origLines[i] === newLines[j]) {
      ops.push({ type: 'equal', text: origLines[i], origLineNo: i + 1, newLineNo: j + 1 });
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      ops.push({ type: 'del', text: origLines[i], origLineNo: i + 1 });
      i++;
    } else {
      ops.push({ type: 'add', text: newLines[j], newLineNo: j + 1 });
      j++;
    }
  }
  while (i < m) {
    ops.push({ type: 'del', text: origLines[i], origLineNo: i + 1 });
    i++;
  }
  while (j < n) {
    ops.push({ type: 'add', text: newLines[j], newLineNo: j + 1 });
    j++;
  }
  return ops;
}

/** Agrupa las operaciones no-iguales en hunks contiguos con contexto a cada lado. */
function buildHunks(ops: DiffOp[]): WorkingHunk[] {
  const changeIdx: number[] = [];
  ops.forEach((op, idx) => {
    if (op.type !== 'equal') changeIdx.push(idx);
  });
  if (!changeIdx.length) return [];

  const groups: Array<[number, number]> = [];
  let gs = changeIdx[0];
  let ge = changeIdx[0];
  for (let k = 1; k < changeIdx.length; k++) {
    const idx = changeIdx[k];
    if (idx - ge <= CONTEXT_LINES * 2) {
      ge = idx;
    } else {
      groups.push([gs, ge]);
      gs = idx;
      ge = idx;
    }
  }
  groups.push([gs, ge]);

  let nextId = 1;
  return groups.map(([changeStart, changeEnd]) => {
    const start = Math.max(0, changeStart - CONTEXT_LINES);
    const end = Math.min(ops.length - 1, changeEnd + CONTEXT_LINES);
    const slice = ops.slice(start, end + 1);
    const originalLines = slice.filter((o) => o.type !== 'add').map((o) => o.text);
    const newLines = slice.filter((o) => o.type !== 'del').map((o) => o.text);
    const addedCount = slice.filter((o) => o.type === 'add').length;
    const removedCount = slice.filter((o) => o.type === 'del').length;

    const origNos = slice.map((o) => o.origLineNo).filter((x): x is number => x !== undefined);
    const newNos = slice.map((o) => o.newLineNo).filter((x): x is number => x !== undefined);
    const startLine = origNos[0] ?? newNos[0] ?? 1;
    const endLine = origNos[origNos.length - 1] ?? newNos[newNos.length - 1] ?? startLine;

    const hunk: WorkingHunk = {
      id: nextId++,
      startLine,
      endLine,
      originalLines,
      newLines,
      addedCount,
      removedCount,
      opsStart: start,
      opsEnd: end,
      resolution: 'pending',
      error: null,
    };
    return hunk;
  });
}

/**
 * Preview de SOLO LECTURA del diff entre `original` y `proposed` con los
 * mismos hunks y estilos del visor — sin botones de decisión ni escritura.
 * Lo usa la tarjeta comparativa de Best-of-N (E5.18): la fusión real la hace
 * el motor con «Elegir este» (archivos completos), no hunk a hunk.
 */
export function previewHtml(original: string, proposed: string): string {
  const ops = computeDiffOps(
    original.length ? original.split('\n') : [],
    proposed.length ? proposed.split('\n') : []
  );
  const hunks = buildHunks(ops);
  if (!hunks.length) {
    return '<div class="empty-state"><span class="empty-state__title">Sin diferencias</span></div>';
  }
  const shown = hunks.slice(0, MAX_HUNKS);
  const parts: string[] = [];
  if (hunks.length > shown.length) {
    parts.push(
      `<div class="banner banner--warning"><span>Se muestran los primeros ${MAX_HUNKS} hunks de ${hunks.length}.</span></div>`
    );
  }
  for (const h of shown) {
    const lines = ops
      .slice(h.opsStart, h.opsEnd + 1)
      .map((op) => {
        const marker = op.type === 'add' ? '+' : op.type === 'del' ? '-' : ' ';
        const lineNo = op.type === 'add' ? op.newLineNo : op.origLineNo;
        const cls =
          op.type === 'add' ? 'diff-line--add' : op.type === 'del' ? 'diff-line--del' : 'diff-line--context';
        return `<div class="diff-line ${cls}">
            <span class="diff-line__no">${lineNo ?? ''}</span>
            <span class="diff-line__marker">${marker}</span>
            <span>${esc(op.text)}</span>
          </div>`;
      })
      .join('');
    const rangeLabel =
      h.startLine === h.endLine ? `Línea ${h.startLine}` : `Líneas ${h.startLine}-${h.endLine}`;
    parts.push(`<div class="card diff-hunk">
        <div class="diff-hunk__header"><div class="row" style="gap:8px">
          <span class="mono subtle" style="font-size:11px">${rangeLabel}</span>
          <span class="badge badge--success">+${h.addedCount}</span>
          <span class="badge badge--danger">-${h.removedCount}</span>
        </div></div>
        <div class="diff-hunk__body">${lines}</div>
      </div>`);
  }
  return `<div class="diff-hunks">${parts.join('')}</div>`;
}

export class DiffViewer {
  private container: HTMLElement;
  private core: CoreApi;

  private path = '';
  private ops: DiffOp[] = [];
  private hunks: WorkingHunk[] = [];
  /** Original completo del diff: contexto que el host verifica al rechazar. */
  private originalFileContent = '';
  private truncatedTotal: number | null = null;
  private globalError: string | null = null;
  private loading = false;
  private focusedHunk = -1;

  /** Sin wrap: los extremos permanecen enfocados y no salen del visor. */
  public navigateHunk(direction: 1 | -1): void {
    if (this.loading || this.globalError || !this.hunks.length) return;
    this.focusedHunk = this.focusedHunk < 0
      ? (direction > 0 ? 0 : this.hunks.length - 1)
      : Math.max(0, Math.min(this.hunks.length - 1, this.focusedHunk + direction));
    const id = this.hunks[this.focusedHunk].id;
    const target = this.container.querySelector<HTMLElement>(`[data-hunk-id="${id}"]`);
    target?.focus({ preventScroll: true });
    target?.scrollIntoView({ block: 'center', behavior: 'auto' });
  }

  private onResolved: ((path: string, accepted: number, rejected: number) => void) | null = null;

  constructor(container: HTMLElement, core: CoreApi | BridgeClient) {
    this.container = container;
    this.core = core instanceof CoreApi ? core : new CoreApi(core);
    this.renderEmpty('Sin cambios que revisar', 'Aún no se cargó ningún archivo para comparar.');
  }

  setOnResolved(cb: (path: string, accepted: number, rejected: number) => void): void {
    this.onResolved = cb;
  }

  /** Calcula los hunks entre el contenido actual del archivo y el propuesto. */
  async showDiff(path: string, proposedContent: string): Promise<void> {
    this.focusedHunk = -1;
    this.path = path;
    this.globalError = null;
    this.truncatedTotal = null;
    this.loading = true;
    this.render();

    let originalContent = '';
    try {
      const doc = await this.core.openDoc(path);
      originalContent = doc?.content ?? '';
    } catch {
      // El archivo no existe o no se pudo leer: se trata como archivo nuevo,
      // es decir, contenido original vacío -> un único hunk "todo añadido".
      originalContent = '';
    }
    this.originalFileContent = originalContent;

    try {
      const origLines = originalContent.length ? originalContent.split('\n') : [];
      const newLines = proposedContent.length ? proposedContent.split('\n') : [];
      this.ops = computeDiffOps(origLines, newLines);
      const allHunks = buildHunks(this.ops);
      if (allHunks.length > MAX_HUNKS) {
        this.truncatedTotal = allHunks.length;
        this.hunks = allHunks.slice(0, MAX_HUNKS);
      } else {
        this.hunks = allHunks;
      }
    } catch (e) {
      this.globalError = String(e instanceof Error ? e.message : e);
      this.hunks = [];
      this.ops = [];
    }

    this.loading = false;
    this.render();
  }

  clear(): void {
    this.path = '';
    this.ops = [];
    this.hunks = [];
    this.originalFileContent = '';
    this.truncatedTotal = null;
    this.globalError = null;
    this.loading = false;
    this.renderEmpty('Sin cambios que revisar', 'Aún no se cargó ningún archivo para comparar.');
  }

  // ------------------------------------------------------------ Resolución

  /**
   * Línea del hunk en el archivo actual: `startLine` está calculada sobre el
   * archivo original del diff, así que se desplaza por las líneas netas que
   * añadieron o quitaron los hunks anteriores ya aceptados. Los rechazados y
   * pendientes conservan el original y no desplazan nada.
   */
  private currentStartLine(hunk: WorkingHunk): number {
    let offset = 0;
    for (const other of this.hunks) {
      if (other === hunk) break;
      if (other.opsStart >= hunk.opsStart) continue;
      if (other.resolution === 'accepted') {
        offset += other.newLines.length - other.originalLines.length;
      }
    }
    return hunk.startLine + offset;
  }

  private async resolveHunk(hunk: WorkingHunk, accept: boolean): Promise<void> {
    if (hunk.resolution !== 'pending') return;
    const target: Resolution = accept ? 'accepted' : 'rejected';
    const range = {
      startLine: this.currentStartLine(hunk),
      originalLineCount: hunk.originalLines.length,
      newLineCount: hunk.newLines.length,
    };
    hunk.error = null;
    try {
      if (accept) {
        await this.core.acceptHunk(
          this.path,
          hunk.id,
          hunk.originalLines.join('\n'),
          hunk.newLines.join('\n'),
          range,
          this.originalFileContent
        );
      } else {
        await this.core.rejectHunk(
          this.path,
          hunk.id,
          hunk.originalLines.join('\n'),
          hunk.newLines.join('\n'),
          range,
          this.originalFileContent
        );
      }
      hunk.resolution = target;
      this.notifyResolved();
    } catch (e) {
      hunk.error = String(e instanceof Error ? e.message : e);
    }
    this.render();
  }

  private async resolveAll(accept: boolean): Promise<void> {
    const pending = this.hunks.filter((h) => h.resolution === 'pending');
    for (const hunk of pending) {
      // Secuencial: cada reconstrucción de contenido depende del estado que
      // dejó la iteración anterior.
      // eslint-disable-next-line no-await-in-loop
      await this.resolveHunk(hunk, accept);
    }
  }

  private notifyResolved(): void {
    if (!this.onResolved) return;
    const accepted = this.hunks.filter((h) => h.resolution === 'accepted').length;
    const rejected = this.hunks.filter((h) => h.resolution === 'rejected').length;
    this.onResolved(this.path, accepted, rejected);
  }

  // ------------------------------------------------------------- Render

  private renderEmpty(title: string, message: string): void {
    this.container.innerHTML = `
      <div class="col" style="height:100%">
        <div class="diff-toolbar">
          <span class="section-label">Revisión de cambios</span>
          ${this.path ? `<span class="mono subtle" style="font-size:11px">${esc(this.path)}</span>` : ''}
        </div>
        <div class="empty-state grow">
          ${icons.check(28)}
          <span class="empty-state__title">${esc(title)}</span>
          <span>${esc(message)}</span>
        </div>
      </div>`;
  }

  private render(): void {
    if (this.loading) {
      this.container.innerHTML = `
        <div class="col" style="height:100%">
          <div class="diff-toolbar">
            <span class="section-label">Revisión de cambios</span>
            <span class="mono subtle" style="font-size:11px">${esc(this.path)}</span>
          </div>
          <div class="empty-state grow">
            <span class="spinner"></span>
            <span>Calculando diferencias…</span>
          </div>
        </div>`;
      return;
    }

    if (this.globalError) {
      this.container.innerHTML = `
        <div class="col" style="height:100%">
          <div class="diff-toolbar">
            <span class="section-label">Revisión de cambios</span>
            <span class="mono subtle" style="font-size:11px">${esc(this.path)}</span>
          </div>
          <div class="empty-state grow">
            <span style="color:var(--danger)">${esc(this.globalError)}</span>
          </div>
        </div>`;
      return;
    }

    if (!this.hunks.length) {
      this.renderEmpty(
        'El archivo propuesto es idéntico al actual',
        this.path ? `No hay diferencias que revisar en ${this.path}.` : 'No hay diferencias que revisar.'
      );
      return;
    }

    const pendingCount = this.hunks.filter((h) => h.resolution === 'pending').length;
    const totalAdded = this.hunks.reduce((acc, h) => acc + h.addedCount, 0);
    const totalRemoved = this.hunks.reduce((acc, h) => acc + h.removedCount, 0);

    const warningHtml = this.truncatedTotal
      ? `<div class="banner banner--warning">
           <span>${icons.alert(14)} Se muestran los primeros ${MAX_HUNKS} hunks de ${this.truncatedTotal}. El resto del archivo se conserva sin cambios hasta que se revise por separado.</span>
         </div>`
      : '';

    const hunksHtml = this.hunks.map((h) => this.renderHunk(h)).join('');

    this.container.innerHTML = `
      <div class="col" style="height:100%">
        <div class="diff-toolbar">
          <div class="col" style="gap:2px">
            <span class="section-label">Revisión de cambios</span>
            <span class="mono subtle" style="font-size:11px">${esc(this.path)}</span>
          </div>
          <div class="row" style="gap:8px">
            <span class="badge badge--success">+${totalAdded}</span>
            <span class="badge badge--danger">-${totalRemoved}</span>
            <span class="badge" id="diff-pending-badge">${pendingCount} pendiente${pendingCount === 1 ? '' : 's'}</span>
            <button class="btn btn--sm btn--primary" id="diff-accept-all" title="Aceptar todos los cambios pendientes" ${pendingCount ? '' : 'disabled'}>${icons.check(13)} Aceptar todo</button>
            <button class="btn btn--sm" id="diff-reject-all" title="Rechazar todos los cambios pendientes" ${pendingCount ? '' : 'disabled'}>${icons.close(13)} Rechazar todo</button>
          </div>
        </div>
        ${warningHtml}
        <div class="diff-hunks">
          ${hunksHtml}
        </div>
      </div>`;

    this.bind();
  }

  private renderHunk(hunk: WorkingHunk): string {
    const slice = this.ops.slice(hunk.opsStart, hunk.opsEnd + 1);
    const linesHtml = slice
      .map((op) => {
        const marker = op.type === 'add' ? '+' : op.type === 'del' ? '-' : ' ';
        const lineNo = op.type === 'add' ? op.newLineNo : op.origLineNo;
        const cls =
          op.type === 'add' ? 'diff-line--add' : op.type === 'del' ? 'diff-line--del' : 'diff-line--context';
        return `<div class="diff-line ${cls}">
            <span class="diff-line__no">${lineNo ?? ''}</span>
            <span class="diff-line__marker">${marker}</span>
            <span>${esc(op.text)}</span>
          </div>`;
      })
      .join('');

    const rangeLabel = hunk.startLine === hunk.endLine ? `Línea ${hunk.startLine}` : `Líneas ${hunk.startLine}-${hunk.endLine}`;

    const resolvedBadge =
      hunk.resolution === 'accepted'
        ? '<span class="badge badge--success">aceptado</span>'
        : hunk.resolution === 'rejected'
          ? '<span class="badge badge--danger">rechazado</span>'
          : '';

    const actionsHtml =
      hunk.resolution === 'pending'
        ? `<button class="btn btn--primary btn--sm" data-action="accept" data-hunk="${hunk.id}" title="Aceptar este cambio">${icons.check(13)} Aceptar</button>
           <button class="btn btn--sm" data-action="reject" data-hunk="${hunk.id}" title="Rechazar este cambio">${icons.close(13)} Rechazar</button>`
        : `<button class="btn btn--primary btn--sm" title="Aceptar este cambio" disabled>${icons.check(13)} Aceptar</button>
           <button class="btn btn--sm" title="Rechazar este cambio" disabled>${icons.close(13)} Rechazar</button>`;

    const errorHtml = hunk.error
      ? `<div class="diff-hunk__error">${esc(hunk.error)}</div>`
      : '';

    return `
      <div class="card diff-hunk ${hunk.resolution !== 'pending' ? 'is-resolved' : ''}" data-hunk-id="${hunk.id}" tabindex="-1" aria-label="${esc(rangeLabel)}">
        <div class="diff-hunk__header">
          <div class="row" style="gap:8px">
            <span class="mono subtle" style="font-size:11px">${esc(rangeLabel)}</span>
            <span class="badge badge--success">+${hunk.addedCount}</span>
            <span class="badge badge--danger">-${hunk.removedCount}</span>
          </div>
          ${resolvedBadge}
        </div>
        <div class="diff-hunk__body">${linesHtml}</div>
        <div class="row" style="gap:8px">${actionsHtml}</div>
        ${errorHtml}
      </div>`;
  }

  private bind(): void {
    this.container.querySelectorAll<HTMLElement>('[data-hunk-id]').forEach((element, index) => {
      element.addEventListener('focusin', () => { this.focusedHunk = index; });
    });
    this.container.querySelector('#diff-accept-all')?.addEventListener('click', () => {
      void this.resolveAll(true);
    });
    this.container.querySelector('#diff-reject-all')?.addEventListener('click', () => {
      void this.resolveAll(false);
    });
    this.container.querySelectorAll<HTMLElement>('[data-action="accept"]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const hunk = this.hunks.find((h) => h.id === Number(btn.dataset.hunk));
        if (hunk) void this.resolveHunk(hunk, true);
      });
    });
    this.container.querySelectorAll<HTMLElement>('[data-action="reject"]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const hunk = this.hunks.find((h) => h.id === Number(btn.dataset.hunk));
        if (hunk) void this.resolveHunk(hunk, false);
      });
    });
  }
}
