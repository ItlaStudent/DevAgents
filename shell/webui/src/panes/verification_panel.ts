import { html, joinHtml, setHtml } from '../design/html';

export interface VerificationItem {
  id: string;
  item: string;
  verdict: 'PASS' | 'FAIL' | 'BUILD PASS' | 'REOPEN';
  evidencePath: string;
}

export interface LedgerBlock {
  index: number;
  hash: string;
  prevHash: string;
  action: string;
  model: string;
  timestamp: string;
}

export class VerificationPanel {
  private container: HTMLElement;
  private verifications: VerificationItem[] = [];
  private ledgerBlocks: LedgerBlock[] = [];

  constructor(container: HTMLElement) {
    this.container = container;
    this.render();
  }

  public setVerifications(items: VerificationItem[]): void {
    this.verifications = [...items];
    this.renderVerifications();
  }

  public setLedger(blocks: LedgerBlock[]): void {
    this.ledgerBlocks = [...blocks];
    this.renderLedger();
  }

  private render(): void {
    this.container.innerHTML = `
      <div style="display:flex; flex-direction:column; height:100%; font-family:var(--font-sans); background:var(--bg-surface-0); color:var(--fg-default);">
        <div style="padding:8px 12px; border-bottom:1px solid var(--border-subtle); background:var(--bg-surface-1); font-weight:600; font-size:13px;">
          Verification, Ledger & Governance
        </div>

        <div style="display:flex; flex:1; overflow:hidden;">
          <div style="width:50%; border-right:1px solid var(--border-subtle); overflow-y:auto; padding:10px; display:flex; flex-direction:column; gap:8px;">
            <div style="font-weight:600; font-size:12px; color:var(--fg-muted);">Verification Ledger Status</div>
            <div id="verification-items-list" style="display:flex; flex-direction:column; gap:6px;"></div>
          </div>

          <div style="width:50%; overflow-y:auto; padding:10px; display:flex; flex-direction:column; gap:8px;">
            <div style="font-weight:600; font-size:12px; color:var(--fg-muted);">Cryptographic Audit Ledger</div>
            <div id="ledger-chain-list" style="display:flex; flex-direction:column; gap:6px;"></div>
          </div>
        </div>
      </div>
    `;
  }

  private renderVerifications(): void {
    const listEl = this.container.querySelector('#verification-items-list');
    if (!listEl) return;

    setHtml(listEl, joinHtml(this.verifications
      .map((v) => {
        let color = '#238636';
        if (v.verdict === 'FAIL' || v.verdict === 'REOPEN') color = '#da3633';

        return html`
          <div style="padding:6px 8px; border-radius:4px; border:1px solid var(--border-subtle); background:var(--bg-surface-1); font-size:11px; display:flex; justify-content:space-between; align-items:center;">
            <div>
              <span style="font-weight:600; margin-right:6px;">${v.item}</span>
              <span style="color:var(--fg-muted); font-size:10px;">${v.evidencePath}</span>
            </div>
            <span style="padding:2px 6px; border-radius:3px; background:${color}; color:#fff; font-weight:700; font-size:10px;">${v.verdict}</span>
          </div>
        `;
      })));
  }

  private renderLedger(): void {
    const listEl = this.container.querySelector('#ledger-chain-list');
    if (!listEl) return;

    setHtml(listEl, joinHtml(this.ledgerBlocks
      .map((b) => {
        return html`
          <div style="padding:6px 8px; border-radius:4px; border:1px solid var(--border-subtle); background:var(--bg-surface-1); font-family:monospace; font-size:10px; display:flex; flex-direction:column; gap:2px;">
            <div style="display:flex; justify-content:space-between; color:var(--accent-primary);">
              <span>#${b.index} [${b.action}]</span>
              <span>${b.model}</span>
            </div>
            <div style="color:var(--fg-muted); overflow:hidden; text-overflow:ellipsis;">Hash: ${b.hash}</div>
            <div style="color:var(--fg-subtle); overflow:hidden; text-overflow:ellipsis;">Prev: ${b.prevHash}</div>
          </div>
        `;
      })));
  }
}
