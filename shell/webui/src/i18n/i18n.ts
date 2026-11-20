/**
 * F3 (10-nov): idioma de la interfaz (español / inglés).
 *
 * La cabina está escrita en español. En inglés, un traductor en vivo cambia
 * los textos visibles (nodos de texto y los atributos title, placeholder y
 * aria-label) usando el diccionario `en.ts`: frases exactas y, para las que
 * llevan números o nombres, patrones. Lo que aún no está en el diccionario se
 * queda en español; `untranslated()` lo lista para ir completándolo.
 *
 * No toca: contenido del usuario (editor, terminal, mensajes de la
 * conversación y respuestas de los modelos) — van marcados con
 * `data-no-i18n` o están dentro de Monaco/xterm.
 */
import { EN_EXACT, EN_PATTERNS } from './en';

export type Lang = 'es' | 'en';
export const LANG_STORAGE_KEY = 'devagents.lang.v1';

const ATTRS = ['title', 'placeholder', 'aria-label'] as const;
// Títulos de sesión y de orden son texto del usuario: nunca se traducen.
const SKIP_SELECTOR = '[data-no-i18n], .sess-row .list-item__label, .catalog-row__title, .space-row .mono, [data-mon-scroll="sesiones"], .attn-item__sub, .attn-toast__open span, .monaco-editor, .xterm, #term-output-plain, .chat-turn--user, .chat-turn__body, .md-body, code, pre, kbd, textarea, input[type=text]:not([placeholder])';

let current: Lang = 'es';
let observer: MutationObserver | null = null;
const missing = new Set<string>();
/** Texto original de cada nodo traducido, para poder volver a español. */
const originals = new WeakMap<Node, string>();
const originalAttrs = new WeakMap<Element, Map<string, string>>();

export function getLang(): Lang {
  return current;
}

export function savedLang(): Lang {
  try {
    return window.localStorage.getItem(LANG_STORAGE_KEY) === 'en' ? 'en' : 'es';
  } catch {
    return 'es';
  }
}

/** Traduce una cadena (sin espacios alrededor). Devuelve null si no hay traducción. */
export function translate(text: string): string | null {
  // Los párrafos de las plantillas llevan saltos de línea y sangría dentro:
  // se comparan con los espacios reducidos a uno.
  const key = text.trim().replace(/\s+/g, ' ');
  if (!key || !/[A-Za-zÁÉÍÓÚÑáéíóúñ]/.test(key)) return null;
  const exact = EN_EXACT[key];
  if (exact !== undefined) return exact;
  for (const [re, rep] of EN_PATTERNS) {
    if (re.test(key)) return key.replace(re, rep as string);
  }
  return null;
}

function skip(el: Element | null): boolean {
  return !!el?.closest?.(SKIP_SELECTOR);
}

function translateTextNode(node: Text): void {
  const parent = node.parentElement;
  if (!parent || skip(parent)) return;
  const raw = node.nodeValue ?? '';
  const base = originals.get(node) ?? raw;
  const t = translate(base);
  if (t === null) {
    const k = base.trim().replace(/\s+/g, ' ');
    if (k && /[áéíóúñ¿¡]|\b(el|la|los|las|de|del|para|con|sin|una?|que|en)\b/i.test(k) && k.length < 160) missing.add(k);
    return;
  }
  if (!originals.has(node)) originals.set(node, raw);
  const lead = base.match(/^\s*/)?.[0] ?? '';
  const trail = base.match(/\s*$/)?.[0] ?? '';
  const next = lead + t + trail;
  if (node.nodeValue !== next) node.nodeValue = next;
}

// Los atributos (placeholder, title) de un campo de texto sí son interfaz,
// aunque su contenido sea del usuario.
const ATTR_SKIP_SELECTOR = SKIP_SELECTOR.replace(', textarea', '');
function translateAttrs(el: Element): void {
  if (el.closest?.(ATTR_SKIP_SELECTOR)) return;
  for (const a of ATTRS) {
    const saved = originalAttrs.get(el)?.get(a);
    const value = saved ?? el.getAttribute(a);
    if (!value) continue;
    const t = translate(value);
    if (t === null) continue;
    let m = originalAttrs.get(el);
    if (!m) { m = new Map(); originalAttrs.set(el, m); }
    if (!m.has(a)) m.set(a, value);
    if (el.getAttribute(a) !== t) el.setAttribute(a, t);
  }
}

function walk(root: Node): void {
  if (root.nodeType === Node.TEXT_NODE) { translateTextNode(root as Text); return; }
  if (root.nodeType !== Node.ELEMENT_NODE) return;
  const el = root as Element;
  translateAttrs(el);
  if (skip(el)) return;
  const tw = document.createTreeWalker(el, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  let n: Node | null = tw.nextNode();
  while (n) {
    if (n.nodeType === Node.TEXT_NODE) translateTextNode(n as Text);
    else translateAttrs(n as Element);
    n = tw.nextNode();
  }
}

function restoreAll(): void {
  const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  let n: Node | null = tw.nextNode();
  while (n) {
    if (n.nodeType === Node.TEXT_NODE) {
      const o = originals.get(n);
      if (o !== undefined) { n.nodeValue = o; originals.delete(n); }
    } else {
      const m = originalAttrs.get(n as Element);
      if (m) { for (const [a, v] of m) (n as Element).setAttribute(a, v); originalAttrs.delete(n as Element); }
    }
    n = tw.nextNode();
  }
}

/** Fija el idioma, lo guarda y traduce (o restaura) toda la cabina. */
export function setLang(lang: Lang): void {
  current = lang;
  try { window.localStorage.setItem(LANG_STORAGE_KEY, lang); } catch { /* comodidad opcional */ }
  document.documentElement.lang = lang;
  if (lang === 'en') {
    walk(document.body);
    if (!observer) {
      observer = new MutationObserver((records) => {
        if (current !== 'en') return;
        for (const r of records) {
          if (r.type === 'characterData') {
            const node = r.target as Text;
            // Un texto que cambió desde el código es un original nuevo.
            if (originals.has(node) && node.nodeValue !== translate(originals.get(node) ?? '')) originals.delete(node);
            translateTextNode(node);
          } else if (r.type === 'attributes') {
            const el = r.target as Element;
            const m = originalAttrs.get(el);
            const name = r.attributeName ?? '';
            if (m?.has(name) && el.getAttribute(name) !== translate(m.get(name) ?? '')) m.delete(name);
            translateAttrs(el);
          } else {
            r.addedNodes.forEach((n) => walk(n));
          }
        }
      });
      observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: [...ATTRS] });
    }
  } else {
    observer?.disconnect();
    observer = null;
    restoreAll();
  }
  document.dispatchEvent(new CustomEvent('devagents:lang-changed', { detail: lang }));
}

/** Arranque: aplica el idioma guardado. */
export function initI18n(): void {
  current = savedLang();
  if (current === 'en') setLang('en');
}

/** Textos vistos sin traducción (diagnóstico para completar el diccionario). */
export function untranslated(): string[] {
  return [...missing].sort();
}
