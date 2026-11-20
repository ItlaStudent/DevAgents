import { tokens } from '../design/tokens';
import { html as safeHtml, joinHtml, setHtml } from '../design/html';
import { effectiveShortcut } from '../app/keybindings';

export interface CommandItem {
  id: string;
  label: string;
  category?: string;
  shortcut?: string;
  action: () => void;
}

export class CommandPalette {
  private overlayElem!: HTMLElement;
  private inputElem!: HTMLInputElement;
  private listElem!: HTMLElement;
  private commands: CommandItem[] = [];
  private filteredCommands: CommandItem[] = [];
  private selectedIndex: number = 0;

  constructor() {
    this.createPaletteDOM();
    this.bindGlobalKeyboard();
  }

  private createPaletteDOM() {
    this.overlayElem = document.createElement('div');
    this.overlayElem.id = 'command-palette-overlay';
    this.overlayElem.style.cssText = `
      display: none;
      position: fixed;
      top: 0;
      left: 0;
      width: 100vw;
      height: 100vh;
      background: rgba(0, 0, 0, 0.65);
      backdrop-filter: blur(4px);
      z-index: 9999;
      align-items: flex-start;
      justify-content: center;
      padding-top: 80px;
    `;

    this.overlayElem.innerHTML = `
      <div style="width: 580px; max-width: 90vw; background: ${tokens.color.surface3}; border: 1px solid ${tokens.color.borderStrong}; border-radius: 6px; box-shadow: 0 12px 32px rgba(0,0,0,0.5); overflow: hidden; display: flex; flex-direction: column;">
        <div style="padding: 10px; border-bottom: 1px solid ${tokens.color.border}; display: flex; align-items: center; background: ${tokens.color.surface2};">
          <span style="color: ${tokens.color.accent}; font-weight: bold; margin-right: 8px; font-size: 14px;">></span>
          <input id="cmd-palette-input" type="text" placeholder="Escribe un comando..." style="flex: 1; background: transparent; border: none; outline: none; color: ${tokens.color.textPrimary}; font-family: var(--font-ui); font-size: 13px;" />
          <span style="font-size: 11px; color: ${tokens.color.textMuted}; background: ${tokens.color.surface3}; padding: 2px 6px; border-radius: 3px;">Esc para cerrar</span>
        </div>
        <div id="cmd-palette-list" style="max-height: 320px; overflow-y: auto; padding: 6px 0;"></div>
      </div>
    `;

    document.body.appendChild(this.overlayElem);

    this.inputElem = this.overlayElem.querySelector('#cmd-palette-input')!;
    this.listElem = this.overlayElem.querySelector('#cmd-palette-list')!;

    this.overlayElem.addEventListener('click', (e) => {
      if (e.target === this.overlayElem) {
        this.hide();
      }
    });

    this.inputElem.addEventListener('input', () => {
      this.filterCommands(this.inputElem.value);
    });

    this.inputElem.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        this.hide();
      } else if (e.key === 'ArrowDown') {
        e.preventDefault();
        this.selectedIndex = Math.min(this.selectedIndex + 1, this.filteredCommands.length - 1);
        this.renderList();
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        this.selectedIndex = Math.max(this.selectedIndex - 1, 0);
        this.renderList();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        if (this.filteredCommands[this.selectedIndex]) {
          const item = this.filteredCommands[this.selectedIndex];
          this.hide();
          item.action();
        }
      }
    });
  }

  private bindGlobalKeyboard() {
    window.addEventListener('keydown', (e) => {
      // Ctrl+Shift+P es el atajo (personalizable) del comando palette.show
      // (app/keybindings.ts); Ctrl+P queda como acceso fijo, como en VS Code.
      if ((e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === 'p') {
        e.preventDefault();
        this.show();
      }
    });
  }

  public registerCommands(items: CommandItem[]) {
    this.commands = items;
  }

  public show() {
    this.overlayElem.style.display = 'flex';
    this.inputElem.value = '';
    this.filterCommands('');
    setTimeout(() => this.inputElem.focus(), 50);
  }

  public hide() {
    this.overlayElem.style.display = 'none';
  }

  private filterCommands(query: string) {
    const q = query.toLowerCase().trim();
    if (!q) {
      this.filteredCommands = [...this.commands];
    } else {
      this.filteredCommands = this.commands.filter(
        (c) => c.label.toLowerCase().includes(q) || (c.category && c.category.toLowerCase().includes(q))
      );
    }
    this.selectedIndex = 0;
    this.renderList();
  }

  private renderList() {
    if (this.filteredCommands.length === 0) {
      this.listElem.innerHTML = `<div style="padding: 12px; color: ${tokens.color.textMuted}; text-align: center; font-size: 12px;">No hay comandos que coincidan</div>`;
      return;
    }

    const rows = this.filteredCommands.map((cmd, idx) => {
      const isSelected = idx === this.selectedIndex;
      const bg = isSelected ? tokens.color.accent : 'transparent';
      const color = isSelected ? tokens.color.accentContrast : tokens.color.textPrimary;

      return safeHtml`
        <div class="cmd-item" data-idx="${idx}" style="padding: 8px 14px; background: ${bg}; color: ${color}; display: flex; align-items: center; justify-content: space-between; cursor: pointer; font-size: 13px;">
          <div style="display: flex; align-items: center; gap: 8px;">
            ${cmd.category ? safeHtml`<span style="font-size: 11px; opacity: 0.7; font-weight: 500;">[${cmd.category}]</span>` : ''}
            <span>${cmd.label}</span>
          </div>
          ${effectiveShortcut(cmd.id, cmd.shortcut) ? safeHtml`<span style="font-size: 11px; opacity: 0.7; font-family: ${tokens.typography.fontCode};">${effectiveShortcut(cmd.id, cmd.shortcut)}</span>` : ''}
        </div>
      `;
    });

    setHtml(this.listElem, joinHtml(rows));

    const items = this.listElem.querySelectorAll('.cmd-item');
    items.forEach((el) => {
      el.addEventListener('click', (e) => {
        const idx = parseInt((e.currentTarget as HTMLElement).getAttribute('data-idx') || '0', 10);
        if (this.filteredCommands[idx]) {
          const cmd = this.filteredCommands[idx];
          this.hide();
          cmd.action();
        }
      });
    });
  }
}
