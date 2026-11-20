/** Solicita el panel derecho; ViewRouter conserva el DOM y la sesion PTY. */
export function toggleTerminalPanel(): void {
  toggleRightPanel('terminal');
}

/** ViewRouter conserva los hosts y la PTY al ocultar el panel. */
export function toggleRightPanel(kind: string): void {
  document.dispatchEvent(new CustomEvent('devagents:panel-request', { detail: { kind, toggle: true } }));
}
