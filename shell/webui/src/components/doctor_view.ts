/**
 * Tanda 4 (F0.5,): el informe de `doctor` en la cabina. El motor
 * comprueba carpeta de datos, disco, WebView2, git, las CLI de terceros con su
 * sesión, las claves guardadas y Ollama en local, sin lanzar ninguna orden.
 * Lo mismo que `devagents-core.exe doctor`.
 *
 * Todo el texto llega del motor y se pinta con textContent, nunca como HTML.
 */
import { tokens } from '../design/tokens';

export interface DoctorCheck {
  id: string;
  status: 'ok' | 'aviso' | 'falla';
  title: string;
  detail: string;
  fix: string;
}

export interface DoctorReport {
  version: number;
  ready: boolean;
  checks: DoctorCheck[];
}

export function isDoctorReport(value: unknown): value is DoctorReport {
  if (!value || typeof value !== 'object') return false;
  const r = value as Partial<DoctorReport>;
  return typeof r.ready === 'boolean' && Array.isArray(r.checks);
}

/** Resumen de una línea: listo, o cuántas cosas fallan o avisan. */
export function doctorSummary(report: DoctorReport): string {
  const fails = report.checks.filter((c) => c.status === 'falla').length;
  const warns = report.checks.filter((c) => c.status === 'aviso').length;
  if (report.ready) return warns ? `Listo para la primera orden (${warns} aviso${warns === 1 ? '' : 's'}).` : 'Listo para la primera orden.';
  return `Falta${fails === 1 ? '' : 'n'} ${fails} cosa${fails === 1 ? '' : 's'} antes de la primera orden.`;
}

/**
 * Pinta el informe dentro de `host`. `onlyProblems` deja fuera las filas ok
 * (el tutorial muestra solo lo que hay que arreglar).
 */
export function renderDoctor(host: HTMLElement, report: DoctorReport, onlyProblems = false): void {
  host.replaceChildren();
  host.setAttribute('data-doctor-ready', report.ready ? '1' : '0');
  const rows = onlyProblems ? report.checks.filter((c) => c.status !== 'ok') : report.checks;
  for (const check of rows) {
    const row = document.createElement('div');
    row.className = 'doctor-row';
    row.dataset.doctorId = check.id;
    row.dataset.doctorStatus = check.status;
    row.style.cssText = 'display:flex; flex-direction:column; gap:2px; padding:4px 0;';
    const head = document.createElement('div');
    head.style.cssText = 'display:flex; gap:6px; align-items:baseline;';
    const mark = document.createElement('span');
    mark.textContent = check.status === 'ok' ? '✓' : check.status === 'aviso' ? '!' : '✕';
    mark.style.cssText = `font-weight:700; width:12px; color:${check.status === 'ok' ? tokens.color.success : check.status === 'aviso' ? tokens.color.warning : tokens.color.danger};`;
    mark.setAttribute('aria-label', check.status);
    const title = document.createElement('b');
    title.textContent = check.title;
    const detail = document.createElement('span');
    detail.textContent = check.detail;
    detail.style.cssText = `color:${tokens.color.textSecondary}; overflow-wrap:anywhere;`;
    head.append(mark, title, detail);
    row.append(head);
    if (check.fix && check.status !== 'ok') {
      const fix = document.createElement('div');
      fix.className = 'doctor-fix';
      fix.textContent = check.fix;
      fix.style.cssText = `margin-left:18px; color:${tokens.color.textMuted}; font-size:11px; overflow-wrap:anywhere;`;
      row.append(fix);
    }
    host.append(row);
  }
}
