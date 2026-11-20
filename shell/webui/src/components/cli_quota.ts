import type { CoreApi } from '../bridge/core_api';
import { notice } from '../design/notice';

export interface QuotaWindow { used_percent: number | null; reset_at: number | null; }
export interface CliQuota {
  cli: 'codex' | 'claude-code';
  format: string;
  status: string;
  five_hour: QuotaWindow;
  daily: QuotaWindow;
  weekly: QuotaWindow;
}
export function unknownQuota(cli: CliQuota['cli']): CliQuota {
  return { cli, format: 'sin verificar', status: 'desconocido', five_hour: { used_percent: null, reset_at: null }, daily: { used_percent: null, reset_at: null }, weekly: { used_percent: null, reset_at: null } };
}
export function quotaLevel(w: QuotaWindow): 'unknown' | 'normal' | 'warning' | 'exhausted' {
  const p = w.used_percent;
  return p === null || !Number.isFinite(p) || p < 0 || p > 100 ? 'unknown' : p >= 100 ? 'exhausted' : p >= 80 ? 'warning' : 'normal';
}

/** Presentation only: the native dispatch boundary enforces the quota. */
export class CliQuotaStatus {
  private readonly root = document.createElement('details');
  private readonly summary = document.createElement('summary');
  private readonly body = document.createElement('div');
  private timer: ReturnType<typeof setInterval> | null = null;
  private busy = false;
  private queued = false;
  private stopped = false;
  private readonly announced = new Set<string>();
  constructor(private readonly core: Pick<CoreApi, 'getCliQuotas'>, host: HTMLElement) {
    this.root.className = 'cli-quota';
    this.summary.textContent = 'Cuotas CLI: sin datos';
    this.body.className = 'cli-quota__body';
    this.body.setAttribute('aria-live', 'polite');
    this.root.append(this.summary, this.body);
    host.append(this.root);
    this.render([unknownQuota('codex'), unknownQuota('claude-code')]);
  }
  start(): void {
    this.stopped = false;
    if (this.timer !== null) return;
    void this.refresh();
    this.timer = setInterval(() => { if (!document.hidden) void this.refresh(); }, 30000);
  }
  stop(): void {
    this.stopped = true;
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
  }
  async refresh(): Promise<void> {
    if (this.busy) { this.queued = true; return; }
    this.busy = true;
    try {
      const quotas = await this.core.getCliQuotas();
      if (!this.stopped) this.render(quotas);
    } catch (e) {
      if (!this.stopped) {
        this.render([unknownQuota('codex'), unknownQuota('claude-code')]);
        this.summary.title = `No se pudo consultar la cuota: ${String(e)}`;
      }
    } finally {
      this.busy = false;
      if (this.queued && !this.stopped) { this.queued = false; void this.refresh(); }
    }
  }
  render(quotas: CliQuota[]): void {
    this.body.replaceChildren();
    const labels: string[] = [];
    const active = new Set<string>();
    for (const cli of ['codex', 'claude-code'] as const) {
      const s = quotas.find(q => q.cli === cli) ?? unknownQuota(cli);
      const display = cli === 'codex' ? 'Codex' : 'Claude Code';
      const section = document.createElement('section');
      const heading = document.createElement('strong');
      heading.textContent = display;
      const format = document.createElement('small');
      format.textContent = `Formato ${s.format}`;
      section.append(heading, format);
      let max: number | null = null;
      for (const [key, label] of [['five_hour', '5 h'], ['daily', 'Diaria'], ['weekly', 'Semanal']] as const) {
        const w = s[key] ?? { used_percent: null, reset_at: null };
        const level = quotaLevel(w);
        const row = document.createElement('div');
        row.className = 'cli-quota__row';
        row.dataset.level = level;
        const text = document.createElement('span');
        const reset = w.reset_at !== null && Number.isFinite(w.reset_at) ? new Date(w.reset_at * 1000).toLocaleString([], { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }) : 'desconocido';
        text.textContent = `${label}: ${level === 'unknown' ? 'desconocido' : `${w.used_percent} %`} · Reinicio: ${reset}${level === 'exhausted' ? ' · CLI omitida: cuota agotada' : ''}`;
        row.append(text);
        if (level !== 'unknown') {
          max = Math.max(max ?? 0, w.used_percent!);
          const bar = document.createElement('progress');
          bar.max = 100;
          bar.value = w.used_percent!;
          bar.setAttribute('aria-label', `${display}, ${label}: ${w.used_percent} % usado`);
          row.append(bar);
        }
        if (level === 'warning' || level === 'exhausted') {
          const id = `${cli}:${key}:${w.reset_at}:${level}`;
          active.add(id);
          if (!this.announced.has(id)) {
            const message = `${display}: cuota de ${label} ${level === 'exhausted' ? 'agotada; se omitirá esta CLI' : `al ${w.used_percent} %`}. Reinicio: ${reset}. Formato ${s.format}.`;
            notice(message, level === 'exhausted' ? 'error' : 'info', 10000);
          }
        }
        section.append(row);
      }
      // 9-nov: «Codex: desconocido» se leía como el estado de la CLI, no de su
      // cuota (la barra lo decía justo después de usarla con éxito).
      labels.push(`${display}: ${max === null ? 'sin datos' : `${max} %`}`);
      this.body.append(section);
    }
    this.announced.clear();
    for (const id of active) this.announced.add(id);
    this.summary.textContent = labels.length ? `Cuotas · ${labels.join(' · ')}` : 'Cuotas CLI: sin datos';
    this.summary.title = 'Cuotas de suscripción de fuentes locales. Abrir para ver ventanas y reinicios.';
  }
}
