/**
 * Diálogo modal de confirmación.
 *
 * `window.confirm()` no vale aquí: WebView2 lo desactiva junto con `prompt()`,
 * y aunque funcionara no permite explicar qué se está aceptando — que es justo
 * lo que hace falta cuando lo que se acepta es que el agente deje de pedir
 * permiso.
 *
 * Devuelve una promesa que resuelve `true` solo si el usuario pulsa el botón de
 * confirmar. Escape y clic fuera equivalen a cancelar, nunca a aceptar: en un
 * diálogo de riesgo, el descuido tiene que caer del lado seguro.
 */

export interface PromptOptions {
  title: string;
  /** Línea de contexto bajo el título (por ejemplo, dónde se va a crear). */
  label?: string;
  placeholder?: string;
  initial?: string;
}

/**
 * Pide un texto. Resuelve con la cadena, o `null` si se cancela.
 *
 * `window.prompt()` NO sirve: WebView2 lo desactiva por defecto, así que no
 * aparece nada y devuelve null en silencio. `SpacesPanel` lo usaba y por eso su
 * botón de crear no hacía nada.
 *
 * Si el nombre trae una extensión, la selección inicial cubre solo la parte del
 * nombre: escribir encima no se lleva por delante el `.py` de una plantilla.
 */
export function promptModal(opts: PromptOptions): Promise<string | null> {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.style.cssText =
      'position:fixed;inset:0;z-index:9500;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;padding:24px';

    const card = document.createElement('div');
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-modal', 'true');
    card.style.cssText = [
      'max-width:460px',
      'width:100%',
      'background:var(--bg-elevated, var(--bg-panel))',
      'color:var(--text)',
      'border:1px solid var(--border)',
      'border-left:3px solid var(--accent)',
      'border-radius:10px',
      'padding:18px 20px',
      'box-shadow:0 18px 50px rgba(0,0,0,.5)',
      'display:flex',
      'flex-direction:column',
      'gap:10px',
    ].join(';');

    const h = document.createElement('div');
    h.style.cssText = 'font-weight:600;font-size:14px';
    h.textContent = opts.title;
    card.appendChild(h);

    if (opts.label) {
      const l = document.createElement('div');
      l.style.cssText =
        'font-size:11px;line-height:1.45;color:var(--text-muted, var(--text));word-break:break-all';
      l.textContent = opts.label;
      card.appendChild(l);
    }

    const input = document.createElement('input');
    input.className = 'input mono';
    input.value = opts.initial || '';
    if (opts.placeholder) input.placeholder = opts.placeholder;
    card.appendChild(input);

    const row = document.createElement('div');
    row.style.cssText = 'display:flex;gap:8px;margin-top:4px;justify-content:flex-end';
    const cancel = document.createElement('button');
    cancel.className = 'btn';
    cancel.textContent = 'Cancelar';
    const okBtn = document.createElement('button');
    okBtn.className = 'btn';
    okBtn.textContent = 'Crear';
    row.appendChild(cancel);
    row.appendChild(okBtn);
    card.appendChild(row);
    overlay.appendChild(card);
    document.body.appendChild(overlay);

    input.focus();
    const punto = input.value.lastIndexOf('.');
    if (punto > 0) input.setSelectionRange(0, punto);
    else input.select();

    let done = false;
    const cerrar = (valor: string | null): void => {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      overlay.remove();
      resolve(valor);
    };
    function onKey(ev: KeyboardEvent): void {
      if (ev.key === 'Escape') {
        ev.preventDefault();
        cerrar(null);
      }
    }
    document.addEventListener('keydown', onKey, true);
    input.addEventListener('keydown', (ev) => {
      if ((ev as KeyboardEvent).key === 'Enter') {
        ev.preventDefault();
        const v = input.value.trim();
        if (v) cerrar(v);
      }
    });
    cancel.addEventListener('click', () => cerrar(null));
    okBtn.addEventListener('click', () => {
      const v = input.value.trim();
      if (v) cerrar(v);
    });
    overlay.addEventListener('click', (ev) => {
      if (ev.target === overlay) cerrar(null);
    });
  });
}

export interface ConfirmOptions {
  title: string;
  /** Párrafos del cuerpo. Se insertan como TEXTO, no como HTML. */
  paragraphs: string[];
  confirmLabel: string;
  cancelLabel?: string;
  /** Pinta el botón de confirmar como acción peligrosa. */
  danger?: boolean;
}

export function confirmModal(opts: ConfirmOptions): Promise<boolean> {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.style.cssText = [
      'position:fixed',
      'inset:0',
      'z-index:9500',
      'background:rgba(0,0,0,.55)',
      'display:flex',
      'align-items:center',
      'justify-content:center',
      'padding:24px',
    ].join(';');

    const card = document.createElement('div');
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-modal', 'true');
    card.style.cssText = [
      'max-width:520px',
      'width:100%',
      'background:var(--bg-elevated, var(--bg-panel))',
      'color:var(--text)',
      'border:1px solid var(--border)',
      'border-left:3px solid ' + (opts.danger ? 'var(--danger)' : 'var(--accent)'),
      'border-radius:10px',
      'padding:18px 20px',
      'box-shadow:0 18px 50px rgba(0,0,0,.5)',
      'display:flex',
      'flex-direction:column',
      'gap:10px',
    ].join(';');

    const h = document.createElement('div');
    h.style.cssText = 'font-weight:600;font-size:14px';
    h.textContent = opts.title;
    card.appendChild(h);

    for (const p of opts.paragraphs) {
      const el = document.createElement('div');
      el.style.cssText = 'font-size:12px;line-height:1.5;color:var(--text-muted, var(--text))';
      // textContent: el cuerpo puede llevar una ruta o el texto de un error.
      el.textContent = p;
      card.appendChild(el);
    }

    const row = document.createElement('div');
    row.style.cssText = 'display:flex;gap:8px;margin-top:6px;justify-content:flex-end';

    const cancel = document.createElement('button');
    cancel.className = 'btn';
    cancel.textContent = opts.cancelLabel || 'Cancelar';

    const confirm = document.createElement('button');
    confirm.className = opts.danger ? 'btn btn--danger' : 'btn';
    confirm.textContent = opts.confirmLabel;

    row.appendChild(cancel);
    row.appendChild(confirm);
    card.appendChild(row);
    overlay.appendChild(card);
    document.body.appendChild(overlay);

    // El foco arranca en CANCELAR, no en confirmar: pulsar Enter por inercia no
    // debe activar la acción peligrosa.
    cancel.focus();

    let done = false;
    const cerrar = (valor: boolean): void => {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      overlay.remove();
      resolve(valor);
    };

    function onKey(ev: KeyboardEvent): void {
      if (ev.key === 'Escape') {
        ev.preventDefault();
        cerrar(false);
      }
    }

    document.addEventListener('keydown', onKey, true);
    cancel.addEventListener('click', () => cerrar(false));
    confirm.addEventListener('click', () => cerrar(true));
    overlay.addEventListener('click', (ev) => {
      // Solo el clic en el fondo cierra; dentro de la tarjeta, no.
      if (ev.target === overlay) cerrar(false);
    });
  });
}
