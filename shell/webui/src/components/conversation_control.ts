import { BridgeClient } from '../bridge/client';
import { notice } from '../design/notice';
import { escapeText, escapeAttribute } from '../design/html';

export interface ConversationSession {
  orderId: number;
  parentOrderId?: number | null;
  title: string;
  category: string;
  status: 'running' | 'interrupted' | 'resumable' | 'completed';
  checkpointJson?: string;
}

export class ConversationControl {
  private bridgeClient: BridgeClient;
  private currentSession: ConversationSession | null = null;
  private isReadOnlyPlanMode = false;

  constructor(bridgeClient: BridgeClient) {
    this.bridgeClient = bridgeClient;
  }

  public setReadOnlyPlanMode(enabled: boolean): void {
    this.isReadOnlyPlanMode = enabled;
    const badge = document.getElementById('plan-readonly-badge');
    if (badge) {
      badge.style.display = enabled ? 'inline-block' : 'none';
    }
  }

  public isReadOnly(): boolean {
    return this.isReadOnlyPlanMode;
  }

  // E1: Fork de conversación
  public async forkConversation(parentOrderId: number, newTitle?: string): Promise<ConversationSession> {
    console.log(`[ConversationControl] Forking order #${parentOrderId}...`);
    const res = await this.bridgeClient.send<
      { parentOrderId: number; title: string },
      { newOrderId: number; title: string; status: string }
    >('conversation.fork', {
      parentOrderId,
      title: newTitle || `Fork de Orden #${parentOrderId}`
    });

    const session: ConversationSession = {
      orderId: res.newOrderId,
      parentOrderId: parentOrderId,
      title: res.title,
      category: 'Forks',
      status: 'completed'
    };

    this.currentSession = session;
    return session;
  }

  // E2 & E3: Reanudar turno interrumpido desde checkpoint_json
  public async resumeTurn(orderId: number, checkpointJson: string): Promise<boolean> {
    console.log(`[ConversationControl] Resuming order #${orderId} from checkpoint...`);
    const res = await this.bridgeClient.send<
      { orderId: number; checkpointJson: string },
      { success: boolean; status: string }
    >('conversation.resume', {
      orderId,
      checkpointJson
    });

    if (res.success && this.currentSession) {
      this.currentSession.status = 'running';
    }
    return res.success;
  }

  // E4: Edición in-place de plan de tareas
  public renderEditablePlan(container: HTMLElement, planId: number, tasks: { id: number; description: string }[]): void {
    container.innerHTML = `
      <div style="border:1px solid var(--border-subtle, #333); border-radius:6px; padding:10px; background:var(--bg-surface-1, #18191c); margin-top:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
          <span style="font-weight:700; font-size:12px; color:var(--accent-primary, #7c5cff);">Plan #${escapeText(planId)} (Edición in-place)</span>
          <span id="plan-readonly-badge" style="display:${this.isReadOnlyPlanMode ? 'inline-block' : 'none'}; padding:2px 6px; background:#ff9f1c; color:#000; border-radius:4px; font-weight:700; font-size:10px;">SOLO LECTURA</span>
        </div>

        <div id="plan-tasks-list" style="display:flex; flex-direction:column; gap:6px;">
          ${tasks.map((t, idx) => `
            <div style="display:flex; items-center; gap:6px;">
              <span style="font-size:11px; color:var(--fg-muted, #888); font-weight:600;">T${idx + 1}.</span>
              <input type="text" value="${escapeAttribute(t.description)}" data-task-idx="${idx}" ${this.isReadOnlyPlanMode ? 'disabled' : ''} style="flex:1; background:var(--bg-surface-0, #111); border:1px solid var(--border-subtle, #444); color:var(--fg-default, #fff); padding:4px 8px; border-radius:4px; font-size:12px;" />
            </div>
          `).join('')}
        </div>

        <div style="display:flex; justify-content:flex-end; gap:8px; margin-top:10px;">
          <button id="btn-recalculate-plan" title="Recalcular el plan con el estado actual" ${this.isReadOnlyPlanMode ? 'disabled' : ''} style="padding:4px 10px; background:var(--bg-surface-2, #333); color:var(--fg-default, #fff); border:1px solid var(--border-subtle, #555); border-radius:4px; font-size:11px; cursor:pointer;">
            Recalcular tareas
          </button>
          <button id="btn-approve-edited-plan" title="Aprobar el plan editado y ejecutarlo" ${this.isReadOnlyPlanMode ? 'disabled' : ''} style="padding:4px 12px; background:var(--accent); color:var(--accent-contrast); border:none; border-radius:4px; font-weight:600; font-size:11px; cursor:pointer;">
            Aprobar plan
          </button>
        </div>
      </div>
    `;

    container.querySelector('#btn-recalculate-plan')?.addEventListener('click', () => {
      console.log(`[ConversationControl] Plan #${planId} recalculating...`);
      notice(`Recalculando el plan #${planId}…`, 'info');
    });

    container.querySelector('#btn-approve-edited-plan')?.addEventListener('click', () => {
      console.log(`[ConversationControl] Plan #${planId} approved.`);
      notice(`Aprobando el plan #${planId}…`, 'info');
    });
  }
}
