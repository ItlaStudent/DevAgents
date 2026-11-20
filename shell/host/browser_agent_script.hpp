#pragma once
// Script FIJO del host para las acciones del agente en el navegador integrado
// (browser_snapshot, browser_find, browser_text scope=ref, y la preparación de
// browser_click / browser_type / browser_key / browser_scroll).
//
// - Se evalúa en un MUNDO AISLADO de la página (Page.createIsolatedWorld): el
//   JavaScript de la página no ve ni puede alterar el registro de referencias.
// - El modelo nunca aporta código: solo elige una operación de la lista cerrada
//   y sus argumentos viajan como datos JSON (segundo parámetro), nunca
//   interpolados en el texto del script.
// - La entrada real (ratón, teclas, texto) la despacha el host por CDP `Input`;
//   aquí solo se localiza y se comprueba el destino.
// - No devuelve valores de campos sensibles (contraseñas, pago) ni permite
//   escribir en ellos: `sensitive_field_denied`.
// - Todo lo que devuelve es contenido de página: datos no confiables.
namespace beats {
namespace browser_agent {
inline constexpr const char *Script = R"js(async (op, a) => {
  const G = globalThis;
  const S = G.__devagents || (G.__devagents = { n: 0, sid: '', els: [], rev: 1 });
  // Auditoría B-1: un campo sensible se marca por identidad, no por su
  // type/autocomplete actuales. La página puede cambiar type=password a
  // text entre dos snapshots y el valor ya no sería detectable; el WeakSet
  // (que vive en este mundo aislado entre llamadas) y el observador de
  // atributos lo mantienen cerrado una vez visto como sensible.
  if (!S.sensitive) S.sensitive = new WeakSet();
  if (!S.hooked) {
    S.hooked = true;
    const bump = () => { S.rev += 1; };
    addEventListener('scroll', bump, true);
    addEventListener('resize', bump, true);
    const markLive = (el) => {
      if (!el || !el.getAttribute) return;
      const type = (el.getAttribute('type') || '').toLowerCase();
      const auto = (el.getAttribute('autocomplete') || '').toLowerCase();
      if (type === 'password' || /(^|\s)(cc-|current-password|new-password|one-time-code)/.test(auto)) S.sensitive.add(el);
    };
    if (document.documentElement) {
      for (const el of document.querySelectorAll('input')) markLive(el);
      new MutationObserver((muts) => {
        for (const m of muts) {
          const el = m.target;
          if (!el || el.tagName !== 'INPUT') continue;
          if (m.attributeName === 'type' && String(m.oldValue || '').toLowerCase() === 'password') { S.sensitive.add(el); continue; }
          markLive(el);
        }
      }).observe(document.documentElement, { attributes: true, attributeOldValue: true, attributeFilter: ['type', 'autocomplete'], subtree: true });
    }
  }
  const fail = (code) => JSON.stringify({ ok: false, code });
  const done = (result) => JSON.stringify({ ok: true, result }).toWellFormed();
  const clean = (s, n) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim().slice(0, n);
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) !== 0;
  };
  const sensitiveNow = (el) => {
    if (!el || !el.getAttribute) return false;
    const type = (el.getAttribute('type') || '').toLowerCase();
    const auto = (el.getAttribute('autocomplete') || '').toLowerCase();
    return type === 'password' || /(^|\s)(cc-|current-password|new-password|one-time-code)/.test(auto);
  };
  const sensitive = (el) => {
    if (!el || !el.getAttribute) return false;
    if (S.sensitive.has(el)) return true;
    if (sensitiveNow(el)) { S.sensitive.add(el); return true; }
    return false;
  };
  const editable = (el) => {
    if (!el) return false;
    if (el.isContentEditable) return true;
    if (el.tagName === 'TEXTAREA') return !el.readOnly && !el.disabled;
    if (el.tagName !== 'INPUT' || el.readOnly || el.disabled) return false;
    return ['text', 'search', 'email', 'url', 'tel', 'number', 'password', ''].includes((el.getAttribute('type') || '').toLowerCase());
  };
  const role = (el) => {
    const explicit = el.getAttribute('role');
    if (explicit) return clean(explicit, 40);
    const t = el.tagName;
    if (t === 'A') return 'link';
    if (t === 'BUTTON' || t === 'SUMMARY') return 'button';
    if (t === 'SELECT') return 'combobox';
    if (t === 'TEXTAREA') return 'textbox';
    if (t === 'INPUT') {
      const k = (el.getAttribute('type') || 'text').toLowerCase();
      if (k === 'checkbox' || k === 'radio') return k;
      if (k === 'button' || k === 'submit' || k === 'reset' || k === 'image') return 'button';
      return k === 'range' ? 'slider' : 'textbox';
    }
    if (/^H[1-6]$/.test(t)) return 'heading';
    if (t === 'IMG') return 'img';
    if (t === 'LABEL') return 'label';
    return el.isContentEditable ? 'textbox' : 'generic';
  };
  const name = (el) => {
    let n = el.getAttribute('aria-label') || '';
    if (!n) {
      const ids = el.getAttribute('aria-labelledby');
      if (ids) n = ids.split(/\s+/).map((i) => (document.getElementById(i) || {}).textContent || '').join(' ');
    }
    if (!n && el.labels && el.labels.length) n = el.labels[0].textContent;
    if (!n && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) n = el.getAttribute('placeholder') || el.getAttribute('name') || '';
    if (!n && el.tagName === 'INPUT' && /^(button|submit|reset)$/i.test(el.getAttribute('type') || '')) n = el.value;
    if (!n && el.tagName === 'IMG') n = el.getAttribute('alt') || '';
    if (!n) n = el.innerText || el.textContent || el.getAttribute('title') || '';
    return clean(n, 100);
  };
  const describe = (el, index) => {
    const r = el.getBoundingClientRect();
    const o = { ref: 'e' + index, role: role(el), name: name(el), x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
    const t = el.tagName;
    if (t === 'INPUT' || t === 'TEXTAREA' || t === 'SELECT') {
      const k = (el.getAttribute('type') || '').toLowerCase();
      if (k === 'checkbox' || k === 'radio') o.checked = !!el.checked;
      else if (sensitive(el)) o.sensitive = true;
      else o.value = clean(el.value, 100);
      // 13-nov (T6): opciones de un desplegable, para browser_fill_form
      // kind=select con value {option_ref}. Nunca las de un campo sensible.
      if (t === 'SELECT' && !o.sensitive)
        o.options = Array.from(el.options).slice(0, 50).map((op, i) => ({ ref: 'o' + i, label: clean(op.label || op.text, 80), selected: !!op.selected }));
      if (el.disabled) o.disabled = true;
    }
    if (t === 'A' && el.href) o.href = String(el.href).slice(0, 200);
    return o;
  };
  const SELECTOR = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=switch],[role=option],[role=textbox],[role=combobox],[onclick],[contenteditable=""],[contenteditable=true],h1,h2,h3';
  const LIMIT = 150;
  const collect = () => {
    S.n += 1;
    S.sid = 's' + S.n + '-' + Math.random().toString(36).slice(2, 8);
    S.els = [];
    let more = false;
    for (const el of document.querySelectorAll(SELECTOR)) {
      if (!visible(el)) continue;
      if (S.els.length >= LIMIT) { more = true; break; }
      S.els.push(el);
    }
    return more;
  };
  const head = () => ({
    snapshot_id: S.sid, view_revision: S.rev,
    url: String(location.href).slice(0, 2048), title: clean(document.title, 160),
    viewport_w: innerWidth, viewport_h: innerHeight,
    scroll_x: Math.round(scrollX), scroll_y: Math.round(scrollY),
    page_h: Math.round(document.documentElement ? document.documentElement.scrollHeight : 0),
  });
  // Presupuesto de bytes: el resultado completo debe caber holgado en 128 KiB.
  const listed = (els, base) => {
    const encoder = new TextEncoder();
    const list = [];
    let bytes = 0;
    let cut = false;
    els.forEach((el, i) => {
      if (cut) return;
      const item = describe(el, base + i);
      const size = encoder.encode(JSON.stringify(item)).length + 1;
      if (bytes + size > 70000) { cut = true; return; }
      bytes += size;
      list.push(item);
    });
    return { list, cut };
  };
  const resolve = (t) => {
    if (!t || typeof t !== 'object') return { code: 'invalid_arguments' };
    if (typeof t.ref === 'string') {
      if (t.snapshot_id !== S.sid) return { code: 'stale_reference' };
      const el = /^e\d{1,4}$/.test(t.ref) ? S.els[Number(t.ref.slice(1))] : null;
      if (!el || !el.isConnected) return { code: 'stale_reference' };
      return { el };
    }
    if (typeof t.x === 'number' && typeof t.y === 'number') {
      if (t.view_revision !== S.rev) return { code: 'stale_view' };
      const el = document.elementFromPoint(t.x, t.y);
      return el ? { el, x: t.x, y: t.y } : { code: 'element_not_found' };
    }
    return { code: 'backend_unsupported' };
  };
  const point = (r) => {
    const el = r.el;
    if (r.x == null) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    if (!visible(el)) return { code: 'not_visible' };
    if (el.disabled) return { code: 'not_interactable' };
    const b = el.getBoundingClientRect();
    const x = r.x != null ? r.x : Math.min(Math.max(b.left + b.width / 2, 1), innerWidth - 1);
    const y = r.y != null ? r.y : Math.min(Math.max(b.top + b.height / 2, 1), innerHeight - 1);
    const hit = document.elementFromPoint(x, y);
    if (!hit) return { code: 'not_visible' };
    if (hit !== el && !el.contains(hit) && !hit.contains(el)) return { code: 'occluded' };
    return { x: Math.round(x * 100) / 100, y: Math.round(y * 100) / 100 };
  };
  const settle = () => new Promise((r) => setTimeout(r, 60));

  if (op === 'snapshot') {
    const more = collect();
    const { list, cut } = listed(S.els, 0);
    return done({ ...head(), elements: list, truncated: more || cut });
  }
  if (op === 'find') {
    const q = (a && a.query) || {};
    collect();
    const exact = q.exact === true;
    const norm = (s) => clean(s, 4000).toLowerCase();
    const same = (have, want) => (exact ? norm(have) === norm(want) : norm(have).includes(norm(want)));
    if (typeof q.text === 'string') {
      // Elementos no interactivos cuyo texto propio contiene lo buscado.
      const known = new Set(S.els);
      const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
      let scanned = 0;
      for (let node = walker.nextNode(); node && scanned < 20000 && S.els.length < 400; node = walker.nextNode()) {
        scanned += 1;
        const parent = node.parentElement;
        if (!parent || known.has(parent) || !same(node.nodeValue, q.text) || !visible(parent)) continue;
        known.add(parent);
        S.els.push(parent);
      }
    }
    const matches = [];
    const refs = [];
    S.els.forEach((el, i) => {
      if (matches.length >= 50) return;
      if (typeof q.role === 'string' && role(el).toLowerCase() !== q.role.toLowerCase()) return;
      if (typeof q.name === 'string' && !same(name(el), q.name)) return;
      if (typeof q.text === 'string' && !same(el.innerText || el.textContent || el.value || '', q.text)) return;
      matches.push(el);
      refs.push(i);
    });
    const encoder = new TextEncoder();
    const out = [];
    let bytes = 0;
    for (let i = 0; i < matches.length; i += 1) {
      const item = describe(matches[i], refs[i]);
      bytes += encoder.encode(JSON.stringify(item)).length + 1;
      if (bytes > 70000) break;
      out.push(item);
    }
    return done({ ...head(), matches: out, truncated: out.length < matches.length });
  }
  if (op === 'text') {
    const r = resolve(a && a.target);
    if (r.code) return fail(r.code);
    if (sensitive(r.el)) return fail('sensitive_field_denied');
    const text = String(r.el.innerText || r.el.value || r.el.textContent || '');
    return done({ text: text.slice(0, 8000), url: String(location.href).slice(0, 2048), truncated: text.length > 8000 });
  }
  if (op === 'point') {
    const r = resolve(a && a.target);
    if (r.code) return fail(r.code);
    const p = point(r);
    if (p.code) return fail(p.code);
    return done({ x: p.x, y: p.y, role: role(r.el), name: name(r.el), view_revision: S.rev });
  }
  if (op === 'typeprep') {
    const r = resolve(a && a.target);
    if (r.code) return fail(r.code);
    let el = r.el;
    if (el.tagName === 'LABEL' && el.control) el = el.control;
    if (sensitive(el)) return fail('sensitive_field_denied');
    if (!editable(el)) return fail('not_editable');
    if (!visible(el)) return fail('not_visible');
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    el.focus();
    if (el.isContentEditable) {
      const range = document.createRange();
      range.selectNodeContents(el);
      if (a.mode !== 'replace') range.collapse(false);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    } else if (a.mode === 'replace') {
      el.select();
      // Un campo que ya tiene texto y se sustituye por vacío: se borra aquí.
      if (a.empty === true && el.value !== '') {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
        if (setter && setter.set) setter.set.call(el, ''); else el.value = '';
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
    } else {
      try { const n = el.value.length; el.setSelectionRange(n, n); } catch (_) { /* type=number/email no admiten rango */ }
    }
    return done({ role: role(el), name: name(el), focused: document.activeElement === el });
  }
  if (op === 'keyprep') {
    if (a && a.target) {
      const r = resolve(a.target);
      if (r.code) return fail(r.code);
      let el = r.el;
      if (el.tagName === 'LABEL' && el.control) el = el.control;
      if (!visible(el)) return fail('not_visible');
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      if (typeof el.focus === 'function') el.focus();
    }
    const active = document.activeElement;
    return done({ sensitive: sensitive(active), role: active ? role(active) : '', name: active ? name(active) : '' });
  }
  if (op === 'scroll') {
    let target = null;
    if (a && a.target) {
      const r = resolve(a.target);
      if (r.code) return fail(r.code);
      target = r.el;
    }
    const before = target ? [target.scrollLeft, target.scrollTop] : [scrollX, scrollY];
    if (target) target.scrollBy({ left: a.dx, top: a.dy, behavior: 'instant' });
    else scrollBy({ left: a.dx, top: a.dy, behavior: 'instant' });
    await settle();
    const after = target ? [target.scrollLeft, target.scrollTop] : [scrollX, scrollY];
    return done({ ...head(), moved_x: Math.round(after[0] - before[0]), moved_y: Math.round(after[1] - before[1]) });
  }
  if (op === 'state') {
    // browser_hover: duration_ms (0-2000) es la espera tras mover el ratón.
    const ms = a && typeof a.ms === 'number' ? Math.min(Math.max(a.ms, 0), 2000) : 60;
    await new Promise((r) => setTimeout(r, ms));
    return done(head());
  }
  // 13-nov (T6): browser_wait. Espera dentro de la página hasta `budget` ms
  // (máx. 3000) y devuelve met=false si aún no se cumple; el host repite hasta
  // el plazo de la petición, que termina en `timeout`.
  if (op === 'wait') {
    const budget = Math.min(Math.max(Number(a && a.budget) || 0, 0), 3000);
    const cond = a && a.condition;
    const t0 = Date.now();
    const check = () => {
      // time: espera fija; el host suma tramos hasta duration_ms.
      if (cond === 'time') return { met: Date.now() - t0 >= budget };
      if (cond === 'load') return { met: document.readyState === 'complete' };
      if (cond === 'url') return { met: typeof a.expected === 'string' && String(location.href).includes(a.expected) };
      const t = a.target;
      if (t && typeof t.ref === 'string' && cond === 'hidden') {
        if (t.snapshot_id !== S.sid) return { code: 'stale_reference' };
        const el = /^e\d{1,4}$/.test(t.ref) ? S.els[Number(t.ref.slice(1))] : null;
        if (!el) return { code: 'stale_reference' };
        return { met: !el.isConnected || !visible(el) };
      }
      const r = resolve(t);
      if (r.code) return { code: r.code };
      if (cond === 'visible') return { met: visible(r.el) };
      if (cond === 'hidden') return { met: !visible(r.el) };
      if (cond === 'text') {
        if (sensitive(r.el)) return { code: 'sensitive_field_denied' };
        return { met: typeof a.expected === 'string' && clean(r.el.innerText || r.el.value || r.el.textContent || '', 100000).includes(clean(a.expected, 4096)) };
      }
      return { code: 'invalid_arguments' };
    };
    for (;;) {
      const c = check();
      if (c.code) return fail(c.code);
      if (c.met || Date.now() - t0 >= budget) return done({ ...head(), met: c.met, condition: cond });
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  // 13-nov (T6): browser_fill_form. Se comprueban TODOS los campos antes de
  // escribir ninguno: un campo sensible o no editable para el formulario
  // entero sin efectos a medias.
  const formTarget = (f) => {
    const r = resolve(f && f.target);
    if (r.code) return r;
    let el = r.el;
    if (el.tagName === 'LABEL' && el.control) el = el.control;
    if (sensitive(el)) return { code: 'sensitive_field_denied' };
    const type = (el.getAttribute('type') || '').toLowerCase();
    if (f.kind === 'text' && !editable(el)) return { code: 'not_editable' };
    if ((f.kind === 'checkbox' || f.kind === 'radio') && !(el.tagName === 'INPUT' && type === f.kind)) return { code: 'not_editable' };
    if (f.kind === 'select') {
      if (el.tagName !== 'SELECT') return { code: 'not_editable' };
      const ref = f.value && f.value.option_ref;
      if (typeof ref !== 'string' || !/^o\d{1,2}$/.test(ref) || Number(ref.slice(1)) >= Math.min(el.options.length, 50)) return { code: 'element_not_found' };
    }
    if (el.disabled) return { code: 'not_interactable' };
    if (!visible(el)) return { code: 'not_visible' };
    return { el };
  };
  if (op === 'formcheck') {
    const fields = (a && Array.isArray(a.fields)) ? a.fields : [];
    if (!fields.length) return fail('invalid_arguments');
    for (const f of fields) {
      const r = formTarget(f);
      if (r.code) return fail(r.code);
    }
    return done({ fields: fields.length });
  }
  if (op === 'checkprep') {
    const r = formTarget(a);
    if (r.code) return fail(r.code);
    const want = a.value === true;
    if (!!r.el.checked === want) return done({ changed: false, checked: want });
    // Un botón de opción marcado no se desmarca con un clic.
    if (a.kind === 'radio' && !want) return fail('not_interactable');
    const p = point({ el: r.el });
    if (p.code) return fail(p.code);
    return done({ changed: true, x: p.x, y: p.y });
  }
  if (op === 'selectopt') {
    const r = formTarget(a);
    if (r.code) return fail(r.code);
    const index = Number(a.value.option_ref.slice(1));
    const el = r.el;
    if (el.selectedIndex !== index) {
      el.focus();
      el.selectedIndex = index;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    return done({ selected: clean(el.options[index].label || el.options[index].text, 80), index });
  }
  // 13-nov (T6): browser_screenshot scope=ref|rect. Recorte en píxeles CSS
  // del documento (Page.captureScreenshot clip).
  if (op === 'shotprep') {
    let box;
    if (a && a.target) {
      const r = resolve(a.target);
      if (r.code) return fail(r.code);
      r.el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      if (!visible(r.el)) return fail('not_visible');
      const b = r.el.getBoundingClientRect();
      box = { x: b.left, y: b.top, width: b.width, height: b.height };
    } else if (a && a.rect) {
      if (a.view_revision !== S.rev) return fail('stale_view');
      box = { x: a.rect.x, y: a.rect.y, width: a.rect.width, height: a.rect.height };
    } else return fail('invalid_arguments');
    const x = Math.max(box.x, 0), y = Math.max(box.y, 0);
    const w = Math.min(box.x + box.width, innerWidth) - x, h = Math.min(box.y + box.height, innerHeight) - y;
    if (!(w >= 1 && h >= 1)) return fail('not_visible');
    const round = (n) => Math.round(n * 100) / 100;
    return done({ x: round(x + scrollX), y: round(y + scrollY), width: round(w), height: round(h), view_revision: S.rev });
  }
  return fail('backend_unsupported');
})js";

// T6 (13-nov-2026): browser_debug_js. Se evalúa en OTRO mundo aislado
// ("devagents-debug"), nunca en el del registro de referencias. Antes del
// código del modelo, este mundo cierra (solo para sí mismo: cada mundo aislado
// tiene sus propios prototipos) lo que el gobierno no permite:
// - leer o escribir el valor de campos de contraseña o de pago (T12 M1: por
//   identidad, aunque se cambie su type; también por FormData, el atributo
//   value, clonarlos o serializar su HTML);
// - leer cookies o el almacenamiento web (localStorage, sessionStorage,
//   indexedDB, caches) de la página;
// - llegar a otro marco (contentWindow/contentDocument; los marcos del mismo
//   origen reciben los mismos cierres antes de cada código);
// - enviar formularios saltándose la página, abrir ventanas o diálogos;
// - pasar código al mundo de la página (<script>, iframes, atributos on*,
//   javascript:, HTML crudo, document.write).
// El código llega como dato (un string JSON), nunca interpolado.
inline constexpr const char *DebugScript = R"js(async (code, ms) => {
  const G = globalThis;
  if (!Object.prototype.hasOwnProperty.call(G, '__devagentsDebugGuard')) {
    // T12 M1: un campo es sensible por identidad, no por su `type` actual.
    // Todo input que haya sido contraseña o pago alguna vez queda marcado
    // (barrido antes de cada código del modelo, observador de atributos
    // entre llamadas y marca previa a cualquier cambio de `type`), y sigue
    // cerrado aunque después pase a type=text.
    const marked = new WeakSet();
    const sensitiveNow = (el) => {
      if (!el || el.tagName !== 'INPUT' || !el.getAttribute) return false;
      const type = (el.getAttribute('type') || '').toLowerCase();
      const auto = (el.getAttribute('autocomplete') || '').toLowerCase();
      return type === 'password' || /(^|\s)(cc-|current-password|new-password|one-time-code)/.test(auto);
    };
    const markIf = (el) => { if (sensitiveNow(el)) marked.add(el); };
    const secret = (el) => {
      if (!el || el.tagName !== 'INPUT') return false;
      if (marked.has(el)) return true;
      if (sensitiveNow(el)) { marked.add(el); return true; }
      return false;
    };
    // Recorre un árbol (y sus raíces de sombra abiertas) llamando a `visit`
    // con cada input; `visit` devuelve true para parar.
    const eachInput = (root, visit) => {
      if (!root) return false;
      if (root.tagName === 'INPUT' && visit(root)) return true;
      if (!root.querySelectorAll) return false;
      for (const el of root.querySelectorAll('*')) {
        if (el.tagName === 'INPUT' && visit(el)) return true;
        if (el.shadowRoot && eachInput(el.shadowRoot, visit)) return true;
      }
      return false;
    };
    const sweep = (root) => { eachInput(root, (el) => { markIf(el); return false; }); };
    const hasSecret = (root) => eachInput(root, (el) => secret(el));
    const hasSecretValueAttr = (root) => eachInput(root, (el) => secret(el) && el.hasAttribute('value'));
    const deny = (what) => { const e = new Error('devagents:' + what); e.devagents = what; throw e; };
    const guard = (proto, name, check) => {
      const d = proto && Object.getOwnPropertyDescriptor(proto, name);
      if (!d) return;
      if (d.get || d.set) {
        Object.defineProperty(proto, name, {
          configurable: false, enumerable: d.enumerable,
          get: d.get && function () { check(this, 'get', []); return d.get.call(this); },
          set: d.set && function (v) { check(this, 'set', [v]); return d.set.call(this, v); },
        });
      } else if (typeof d.value === 'function') {
        Object.defineProperty(proto, name, {
          configurable: false, writable: false, enumerable: d.enumerable,
          value: function (...args) { check(this, 'call', args); return d.value.apply(this, args); },
        });
      }
    };
    const guardedWindows = new WeakSet();
    const tag = /^(script|iframe|frame|object|embed)$/i;
    const frameTag = /^(iframe|frame|object|embed)$/i;
    const attribute = (name, value) => /^on/i.test(String(name)) || (/^(src|href|action|formaction|data|srcdoc)$/i.test(String(name)) && /^\s*(javascript|data):/i.test(String(value))) || /^srcdoc$/i.test(String(name));
    const isValueName = (name) => String(name).toLowerCase() === 'value';
    const ownerOf = (node) => (node && node.nodeType === 2 ? node.ownerElement : null);
    const install = (W) => {
      if (guardedWindows.has(W)) return;
      guardedWindows.add(W);
      // T12B M-2 (auditor 3): el constructor nativo de FormData seguía
      // alcanzable por `Object.getPrototypeOf(new FormData()).constructor` y
      // sus valores se podían sacar serializando. Se captura el getter nativo
      // del valor antes de cerrarlo (para comparar FormData de otro mundo) y
      // se mapea cada instancia construida aquí a su formulario.
      const nativeInputValue = Object.getOwnPropertyDescriptor(W.HTMLInputElement.prototype, 'value').get;
      const nativeFormData = W.FormData;
      const nativeEntries = nativeFormData && Object.getOwnPropertyDescriptor(nativeFormData.prototype, 'entries')
        ? Object.getOwnPropertyDescriptor(nativeFormData.prototype, 'entries').value : null;
      const formOf = new WeakMap();
      const sensitiveFormData = new WeakSet();
      const secretValues = () => {
        const vals = new Set();
        eachInput(W.document, (el) => {
          if (secret(el)) {
            const v = nativeInputValue.call(el);
            if (typeof v === 'string' && v) vals.add(v);
          }
          return false;
        });
        return vals;
      };
      const formDataHasSecret = (fd) => {
        if (!fd) return false;
        if (sensitiveFormData.has(fd)) return true;
        const form = formOf.get(fd);
        if (form !== undefined && form !== null) {
          if (hasSecret(form) || Array.from(form.elements || []).some(secret)) {
            sensitiveFormData.add(fd);
            return true;
          }
        }
        const vals = secretValues();
        if (vals.size === 0 || !nativeEntries) return false;
        try {
          for (const [, v] of nativeEntries.call(fd)) if (typeof v === 'string' && vals.has(v)) return true;
        } catch (e) { if (!(e instanceof W.TypeError)) throw e; }
        return false;
      };
      const bodyHasSecret = (body) => body !== null && typeof body === 'object' && formDataHasSecret(body);
      const field = (el) => { if (secret(el)) deny('sensitive_field_denied'); };
      for (const n of ['value', 'defaultValue', 'valueAsNumber', 'valueAsDate', 'select', 'setRangeText', 'setSelectionRange', 'showPicker'])
        guard(W.HTMLInputElement.prototype, n, field);
      // Antes de cambiar el tipo, la marca: deja de ser password pero no de ser secreto.
      guard(W.HTMLInputElement.prototype, 'type', (el, kind) => { if (kind === 'set') markIf(el); });
      // El atributo value (valor inicial) de un campo sensible tampoco se lee.
      for (const n of ['getAttribute', 'getAttributeNode']) guard(W.Element.prototype, n, (el, kind, args) => { if (isValueName(args[0]) && secret(el)) deny('sensitive_field_denied'); });
      for (const n of ['getAttributeNS', 'getAttributeNodeNS']) guard(W.Element.prototype, n, (el, kind, args) => { if (isValueName(args[1]) && secret(el)) deny('sensitive_field_denied'); });
      for (const n of ['value', 'nodeValue', 'textContent']) {
        guard(n === 'value' ? W.Attr.prototype : W.Node.prototype, n, (node, kind) => {
          const owner = ownerOf(node);
          if (!owner) return;
          if (kind === 'get' && isValueName(node.name) && secret(owner)) deny('sensitive_field_denied');
          if (kind === 'set') markIf(owner);
        });
      }
      // Copiar un campo copia su valor vivo: no se clona ni importa un árbol
      // con campos sensibles (ni marcos, que darían prototipos sin cerrar).
      const copyCheck = (node) => {
        if (hasSecret(node)) deny('sensitive_field_denied');
        if (node && ((node.tagName && frameTag.test(node.tagName)) || (node.querySelector && node.querySelector('iframe,frame,object,embed')))) deny('script_injection');
      };
      guard(W.Node.prototype, 'cloneNode', (node) => copyCheck(node));
      for (const n of ['importNode', 'adoptNode']) guard(W.Document.prototype, n, (doc, kind, args) => copyCheck(args[0]));
      // FormData lee el valor vivo de los controles del formulario.
      if (nativeFormData) {
        const Guarded = function FormData(form, submitter) {
          if (!new.target) throw new TypeError("Failed to construct 'FormData': Please use the 'new' operator");
          if (form !== undefined && form !== null) {
            if (hasSecret(form)) deny('sensitive_field_denied');
            for (const el of (form.elements || [])) if (secret(el)) deny('sensitive_field_denied');
          }
          const fd = Reflect.construct(nativeFormData, arguments.length > 0 ? [form, submitter].slice(0, arguments.length) : [], new.target);
          if (form !== undefined && form !== null) formOf.set(fd, form);
          return fd;
        };
        Guarded.prototype = nativeFormData.prototype;
        // T12B M-2: `Object.getPrototypeOf(new FormData()).constructor` debe
        // devolver el envuelto; si devolviera el nativo, se salta el cierre.
        Object.defineProperty(nativeFormData.prototype, 'constructor', { configurable: false, writable: false, value: Guarded });
        Object.defineProperty(W, 'FormData', { configurable: false, writable: false, value: Guarded });
        // Leer o iterar un FormData que lleva valores de un campo sensible se
        // deniega, aunque la instancia venga de otro mundo (se compara por
        // valor con el getter nativo capturado arriba).
        for (const n of ['get', 'getAll', 'entries', 'values', 'forEach', 'has', 'keys']) {
          const d = Object.getOwnPropertyDescriptor(nativeFormData.prototype, n);
          if (!d || typeof d.value !== 'function') continue;
          Object.defineProperty(nativeFormData.prototype, n, {
            configurable: false, writable: false, enumerable: d.enumerable,
            value: function (...args) { if (formDataHasSecret(this)) deny('sensitive_field_denied'); return d.value.apply(this, args); },
          });
        }
        const it = Object.getOwnPropertyDescriptor(nativeFormData.prototype, Symbol.iterator);
        if (it && typeof it.value === 'function') {
          Object.defineProperty(nativeFormData.prototype, Symbol.iterator, {
            configurable: false, writable: false, enumerable: it.enumerable,
            value: function (...args) { if (formDataHasSecret(this)) deny('sensitive_field_denied'); return it.value.apply(this, args); },
          });
        }
      }
      // T12B M-2: serializar un FormData sensible por Response/Request/fetch,
      // XMLHttpRequest.send o navigator.sendBeacon también se deniega.
      const wrapBodyCtor = (name, bodyOf) => {
        const Native = W[name];
        if (typeof Native !== 'function') return;
        const Wrapped = function (...args) {
          if (!new.target) return Native.apply(this, args);
          if (bodyHasSecret(bodyOf(args))) deny('sensitive_field_denied');
          return Reflect.construct(Native, args, new.target);
        };
        Wrapped.prototype = Native.prototype;
        Object.defineProperty(Native.prototype, 'constructor', { configurable: true, writable: true, value: Wrapped });
        Object.defineProperty(W, name, { configurable: false, writable: false, value: Wrapped });
      };
      wrapBodyCtor('Response', (args) => args[0]);
      wrapBodyCtor('Request', (args) => (args[1] && typeof args[1] === 'object' ? args[1].body : undefined));
      if (typeof W.fetch === 'function') {
        const nativeFetch = W.fetch;
        Object.defineProperty(W, 'fetch', { configurable: false, writable: false, value: function (input, init) {
          if (init && typeof init === 'object' && bodyHasSecret(init.body)) deny('sensitive_field_denied');
          return nativeFetch.apply(this, arguments);
        } });
      }
      if (W.XMLHttpRequest) {
        const d = Object.getOwnPropertyDescriptor(W.XMLHttpRequest.prototype, 'send');
        if (d && typeof d.value === 'function') Object.defineProperty(W.XMLHttpRequest.prototype, 'send', {
          configurable: false, writable: false, enumerable: d.enumerable,
          value: function (body) { if (bodyHasSecret(body)) deny('sensitive_field_denied'); return d.value.call(this, body); },
        });
      }
      guard(W.Navigator && W.Navigator.prototype, 'sendBeacon', (nav, kind, args) => { if (bodyHasSecret(args[1])) deny('sensitive_field_denied'); });
      // Serializar el HTML incluiría el atributo value de un campo sensible.
      for (const n of ['innerHTML', 'outerHTML']) guard(W.Element.prototype, n, (el, kind) => {
        if (kind === 'set') deny('script_injection');
        if (hasSecretValueAttr(el)) deny('sensitive_field_denied');
      });
      guard(W.Element.prototype, 'getHTML', (el) => { if (hasSecretValueAttr(el)) deny('sensitive_field_denied'); });
      guard(W.ShadowRoot.prototype, 'innerHTML', (el, kind) => {
        if (kind === 'set') deny('script_injection');
        if (hasSecretValueAttr(el)) deny('sensitive_field_denied');
      });
      if (W.XMLSerializer) guard(W.XMLSerializer.prototype, 'serializeToString', (s, kind, args) => { if (hasSecretValueAttr(args[0])) deny('sensitive_field_denied'); });
      // Cookies y almacenamiento web de la página: cerrados en debug_js.
      guard(W.Document.prototype, 'cookie', () => deny('storage_denied'));
      for (const n of ['localStorage', 'sessionStorage', 'indexedDB', 'caches', 'cookieStore']) {
        guard(W, n, () => deny('storage_denied'));
        guard(W.Window && W.Window.prototype, n, () => deny('storage_denied'));
      }
      if (W.Storage) for (const n of ['getItem', 'setItem', 'removeItem', 'clear', 'key', 'length']) guard(W.Storage.prototype, n, () => deny('storage_denied'));
      // Otro marco daría prototipos sin estos cierres.
      for (const C of [W.HTMLIFrameElement, W.HTMLFrameElement, W.HTMLObjectElement])
        if (C) for (const n of ['contentWindow', 'contentDocument', 'getSVGDocument']) guard(C.prototype, n, () => deny('script_injection'));
      if (W.HTMLEmbedElement) guard(W.HTMLEmbedElement.prototype, 'getSVGDocument', () => deny('script_injection'));
      for (const n of ['DOMParser', 'XSLTProcessor']) if (W[n]) Object.defineProperty(W, n, { configurable: false, writable: false, value: function () { deny('script_injection'); } });
      if (W.Document.parseHTMLUnsafe) Object.defineProperty(W.Document, 'parseHTMLUnsafe', { configurable: false, writable: false, value: () => deny('script_injection') });
      guard(W.HTMLFormElement.prototype, 'submit', () => deny('form_submit'));
      guard(W.HTMLFormElement.prototype, 'requestSubmit', () => deny('form_submit'));
      for (const n of ['open', 'alert', 'confirm', 'prompt', 'print'])
        Object.defineProperty(W, n, { configurable: false, writable: false, value: () => deny('window_or_dialog') });
      guard(W.Document.prototype, 'createElement', (doc, kind, args) => { if (tag.test(String(args[0]))) deny('script_injection'); });
      guard(W.Document.prototype, 'createElementNS', (doc, kind, args) => { if (tag.test(String(args[1]).split(':').pop())) deny('script_injection'); });
      guard(W.Element.prototype, 'setAttribute', (el, kind, args) => { markIf(el); if (attribute(args[0], args[1])) deny('script_injection'); });
      guard(W.Element.prototype, 'setAttributeNS', (el, kind, args) => { markIf(el); if (attribute(args[1], args[2])) deny('script_injection'); });
      for (const n of ['removeAttribute', 'removeAttributeNS', 'toggleAttribute', 'setAttributeNode', 'setAttributeNodeNS', 'removeAttributeNode'])
        guard(W.Element.prototype, n, (el) => markIf(el));
      guard(W.Element.prototype, 'setHTMLUnsafe', () => deny('script_injection'));
      guard(W.Element.prototype, 'insertAdjacentHTML', () => deny('script_injection'));
      for (const n of ['write', 'writeln', 'open']) guard(W.Document.prototype, n, () => deny('script_injection'));
      guard(W.Range.prototype, 'createContextualFragment', () => deny('script_injection'));
      for (const n of ['href', 'src', 'action', 'formAction']) {
        for (const proto of [W.HTMLAnchorElement.prototype, W.HTMLIFrameElement.prototype, W.HTMLFormElement.prototype, W.HTMLButtonElement.prototype, W.HTMLInputElement.prototype])
          guard(proto, n, (el, kind, args) => { if (kind === 'set' && /^\s*javascript:/i.test(String(args[0]))) deny('script_injection'); });
      }
      // Entre llamadas, la propia página puede pasar una contraseña a texto
      // («mostrar contraseña»): el observador la marca por su valor anterior.
      const observer = new W.MutationObserver((records) => {
        for (const r of records) {
          if (r.type === 'attributes') {
            if (r.target.tagName === 'INPUT' && r.attributeName === 'type' && String(r.oldValue || '').toLowerCase() === 'password') marked.add(r.target);
            markIf(r.target);
          } else for (const n of r.addedNodes) sweep(n);
        }
      });
      observer.observe(W.document, { subtree: true, childList: true, attributes: true, attributeOldValue: true, attributeFilter: ['type', 'autocomplete'] });
      sweep(W.document);
    };
    install(G);
    // Antes de cada código del modelo: barrido del documento (con sus raíces
    // de sombra abiertas) y cierres también en los marcos del mismo origen.
    Object.defineProperty(G, '__devagentsDebugSweep', { value: () => {
      sweep(document);
      for (let i = 0; i < G.length; i++) {
        let w;
        try { w = G[i]; if (!w.document) continue; } catch (e) { continue; }
        install(w);
        sweep(w.document);
      }
    } });
    Object.defineProperty(G, '__devagentsDebugSecret', { value: secret });
    Object.defineProperty(G, '__devagentsDebugGuard', { value: true });
  }
  G.__devagentsDebugSweep();
  const secretField = G.__devagentsDebugSecret;
  const show = (v) => {
    if (v === undefined) return 'undefined';
    if (v === null || typeof v !== 'object') return typeof v === 'string' ? v : String(v);
    if (typeof Element !== 'undefined' && v instanceof Element) {
      if (v.tagName === 'INPUT' && secretField(v)) return '<input sensible>';
      return '<' + v.tagName.toLowerCase() + (v.id ? '#' + v.id : '') + (typeof v.className === 'string' && v.className ? '.' + v.className.trim().split(/\s+/).join('.') : '') + '>';
    }
    try { return JSON.stringify(v, null, 1); } catch (e) { return String(v); }
  };
  const cap = (s) => { s = String(s); return s.length > 8000 ? s.slice(0, 8000) + '…' : s; };
  // Tope para lo que el código espera (una promesa que nunca se resuelve):
  // Runtime.evaluate solo corta la ejecución síncrona.
  const limit = typeof ms === 'number' && ms > 0 ? Math.min(ms, 2000) : 2000;
  let timer;
  try {
    const value = await Promise.race([
      (async () => (0, eval)(String(code)))(),
      new Promise((_, reject) => { timer = setTimeout(() => reject({ devagentsTimeout: true }), limit); }),
    ]).finally(() => clearTimeout(timer));
    return JSON.stringify({ ok: true, result: { threw: false, type: value === null ? 'null' : typeof value, value: cap(show(value)) } });
  } catch (e) {
    if (e && e.devagentsTimeout === true) return JSON.stringify({ ok: false, code: 'timeout' });
    if (e && e.devagents === 'sensitive_field_denied') return JSON.stringify({ ok: false, code: 'sensitive_field_denied' });
    if (e && e.devagents) return JSON.stringify({ ok: true, result: { threw: true, blocked: e.devagents, value: 'No permitido en browser_debug_js: ' + e.devagents } });
    return JSON.stringify({ ok: true, result: { threw: true, value: cap((e && e.stack) || e) } });
  }
})js";
} // namespace browser_agent
} // namespace beats
