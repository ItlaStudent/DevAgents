/**
 * — acciones del editor que solo tienen sentido con un archivo
 * abierto (Canvas y Diff).
 *
 * El estado NO se guarda: se calcula cada vez a partir de la ruta que el editor
 * tiene abierta en ese instante (`MonacoEditor.filePath`). Un flag aparte
 * («hayArchivo») se habría podido desincronizar al cerrar la última pestaña,
 * al fallar una apertura o al guardar como; la ruta, no.
 *
 * Los botones se pintan deshabilitados (`disabled` + `aria-disabled`) y con un
 * tooltip que explica el motivo, para que no parezcan rotos.
 */

export type FileActionId = 'canvas' | 'diff';

interface FileActionDef {
  id: FileActionId;
  /** Nombre visible y accesible del botón. */
  label: string;
  /** Texto tras «Abre un archivo para usar …». */
  needs: string;
  /** Tooltip cuando la acción está disponible. */
  hint: string;
}

export const FILE_ACTIONS: readonly FileActionDef[] = [
  { id: 'canvas', label: 'Canvas', needs: 'Canvas', hint: 'Canvas: ver el resultado en el navegador integrado' },
  { id: 'diff', label: 'Diff', needs: 'Diff', hint: 'Diff: revisar los cambios de este archivo por bloques (Ctrl+Shift+D)' },
];

/** Tooltip de una acción según haya o no archivo abierto. */
export function fileActionTitle(def: FileActionDef, filePath: string): string {
  return filePath ? def.hint : `Abre un archivo para usar ${def.needs}`;
}

/** Marcado inicial: todo en gris hasta que `syncFileActions` diga lo contrario. */
export function fileActionsMarkup(): string {
  return FILE_ACTIONS.map(
    (a) =>
      `<button type="button" class="btn btn--sm editor-act" id="editor-act-${a.id}" data-act="${a.id}" ` +
      `disabled aria-disabled="true" aria-label="${a.label}" title="${fileActionTitle(a, '')}">${a.label}</button>`
  ).join('');
}

/** Los botones de acción que `fileActionsMarkup` pintó dentro de `root`. */
export function fileActionButtons(root: ParentNode): HTMLButtonElement[] {
  return Array.from(root.querySelectorAll<HTMLButtonElement>('.editor-act[data-act]'));
}

/** Pone cada botón en el estado que corresponde a la ruta abierta (vacía = ninguna). */
export function syncFileActions(buttons: readonly HTMLButtonElement[], filePath: string): void {
  const hasFile = filePath !== '';
  for (const btn of buttons) {
    const def = FILE_ACTIONS.find((a) => a.id === btn.dataset.act);
    if (!def) continue;
    btn.disabled = !hasFile;
    btn.setAttribute('aria-disabled', hasFile ? 'false' : 'true');
    btn.title = fileActionTitle(def, filePath);
  }
}
