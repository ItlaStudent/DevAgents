// tests/window_mode_test.cjs - E5.22: parser de la query de ventana
// secundaria y montaje aislado del panel. Corre en Node con un DOM mínimo.
//
// c2: la prueba carga la FUENTE TypeScript con el eliminador de
// tipos nativo de Node (no hay node_modules/esbuild en este worktree) y
// ejecuta la función REAL activateSecondaryWindow extraída de main.ts.
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

const ROOT = path.resolve(__dirname, '..');
const SRC = path.join(ROOT, 'shell', 'webui', 'src');

// ── MutationObserver mínimo: avisa a los observadores del subárbol ──────────
const OBSERVERS = new Set();
class MockMutationObserver {
  constructor(cb) {
    this.cb = cb;
    this.target = null;
    OBSERVERS.add(this);
  }
  observe(target) {
    this.target = target;
  }
  disconnect() {
    OBSERVERS.delete(this);
    this.target = null;
  }
  takeRecords() {
    return [];
  }
}
const isInside = (node, target) => {
  let n = node;
  while (n) {
    if (n === target) return true;
    n = n.parent;
  }
  return false;
};
const notifyMutation = (node) => {
  for (const observer of [...OBSERVERS]) {
    if (!observer.target || !isInside(node, observer.target)) continue;
    const obs = observer;
    queueMicrotask(() => {
      try {
        obs.cb([{ type: 'childList', target: node }], obs);
      } catch {
        // La aserción del test es la que diagnostica.
      }
    });
  }
};
global.MutationObserver = MockMutationObserver;

// ── DOM mínimo (con innerHTML que dispara al observador) ───────────────────
class El {
  constructor(id = '') {
    this.id = id;
    this.children = [];
    this.parent = null;
    this.style = {};
    this.dataset = {};
    this.listeners = {};
    this.className = '';
    this.title = '';
    this.scrollTop = 0;
    this.ownerDocument = null;
    this.classList = {
      _s: new Set(),
      add: (c) => this.classList._s.add(c),
      contains: (c) => this.classList._s.has(c),
    };
  }
  appendChild(child) {
    if (child.parent) {
      const i = child.parent.children.indexOf(child);
      if (i >= 0) child.parent.children.splice(i, 1);
    }
    this.children.push(child);
    child.parent = this;
    notifyMutation(this);
    return child;
  }
  walk() {
    return [this, ...this.children.flatMap((c) => c.walk())];
  }
  contains(node) {
    let n = node;
    while (n) {
      if (n === this) return true;
      n = n.parent;
    }
    return false;
  }
  querySelector(sel) {
    if (sel.startsWith('#')) return this.walk().find((e) => e.id === sel.slice(1)) || null;
    if (sel.startsWith('.')) {
      const cls = sel.slice(1);
      return this.walk().find((e) => e.classList._s.has(cls) || e.className.split(/\s+/).includes(cls)) || null;
    }
    return null;
  }
  querySelectorAll() {
    return [];
  }
  addEventListener(type, fn) {
    this.listeners[type] = fn;
  }
  set innerHTML(html) {
    this.html = html;
    this.children = [];
    for (const m of html.matchAll(/<button\b([^>]*)>/g)) {
      const attrs = m[1];
      const btn = new El((attrs.match(/\bid="([^"]*)"/) || [])[1] || '');
      btn.ownerDocument = this.ownerDocument;
      btn.title = (attrs.match(/\btitle="([^"]*)"/) || [])[1] || '';
      this.appendChild(btn);
    }
    notifyMutation(this);
  }
  get innerHTML() {
    return this.html || '';
  }
}

const makeDocument = () => {
  const events = [];
  const doc = {
    body: new El('body'),
    activeElement: null,
    events,
    createElement() {
      const el = new El();
      el.ownerDocument = doc;
      return el;
    },
    getElementById(id) {
      return doc.body.walk().find((e) => e.id === id) || null;
    },
    dispatchEvent(event) {
      events.push({ type: event.type, detail: event.detail });
    },
  };
  doc.body.ownerDocument = doc;
  return doc;
};

// ── Carga del BUNDLE que compila la puerta ────────────────────────────────
// c3/P2-1: las comprobaciones de window_mode consumen el artefacto
// generado por shell/webui/build_windowmode_test.mjs, no la fuente TypeScript.
// Si falta el bundle o es anterior a la fuente se falla: nunca se mide un
// artefacto viejo como si fuera el build actual.
const stripTs = (source) => stripTypeScriptTypes(source, { mode: 'transform' });
const withoutExports = (js) => js.replace(/^export\s+(?=(?:const|function|class|let|var)\b)/gm, '');

const BUNDLE_ENV = 'WM_BUNDLE_PATH';
const EXPECTED_EXPORTS = ['parseWindowQuery', 'SECONDARY_VIEWS', 'secondaryMountPlan', 'mountSecondaryView', 'mountSecondaryFallback'];

const bundlePath = () => {
  const raw = process.env[BUNDLE_ENV] || path.join('shell', 'webui', 'dist', 'window_mode.test.cjs');
  return path.isAbsolute(raw) ? raw : path.join(ROOT, raw);
};

const failFast = (message) => {
  console.error(`window_mode_test: ${message}`);
  process.exit(2);
};

const bundleFile = () => {
  const file = bundlePath();
  let stat;
  try {
    stat = fs.statSync(file);
  } catch {
    failFast(`bundle no encontrado en ${file}; ejecuta: cd shell/webui; node build_windowmode_test.mjs`);
  }
  const sourceStat = fs.statSync(path.join(SRC, 'window_mode.ts'));
  if (stat.mtimeMs + 1000 < sourceStat.mtimeMs) {
    failFast(`bundle desactualizado (${file}); recompila con: cd shell/webui; node build_windowmode_test.mjs`);
  }
  return file;
};

const bundleCode = () => fs.readFileSync(bundleFile(), 'utf8');

const monitorCode = () => {
  const src = fs.readFileSync(path.join(SRC, 'panes', 'monitor_panel.ts'), 'utf8');
  let js = stripTs(src);
  js = js.replace(/^import\s+\{([\s\S]*?)\}\s+from\s+['"]([^'"]+)['"];?/gm, (m, names, id) => {
    const binding = names.replace(/\bas\b/g, ':').replace(/\s+/g, ' ').trim();
    return `const { ${binding} } = require('${id}');`;
  });
  js = withoutExports(js);
  js += '\nmodule.exports = { MonitorPanel };\n';
  return js;
};

const loadWindowMode = (documentObj) => {
  const moduleObj = { exports: {} };
  const context = {
    module: moduleObj,
    exports: moduleObj.exports,
    document: documentObj,
    MutationObserver: MockMutationObserver,
    queueMicrotask,
    URLSearchParams,
    Number,
    console,
  };
  vm.createContext(context);
  vm.runInContext(bundleCode(), context, { filename: bundlePath() });
  for (const name of EXPECTED_EXPORTS) {
    assert.ok(name in moduleObj.exports, `el bundle no exporta ${name}`);
  }
  return moduleObj.exports;
};

global.document = makeDocument();
const wm = loadWindowMode(global.document);

const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

let passed = 0;
const check = (name, fn) => {
  fn();
  passed++;
  console.log(`  ok ${name}`);
};

// ── parseWindowQuery ──────────────────────────────────────────────────────
check('sin query no es secundaria', () => {
  assert.strictEqual(wm.parseWindowQuery(''), null);
  assert.strictEqual(wm.parseWindowQuery('?'), null);
});

check('ventana sin vista no es secundaria', () => {
  assert.strictEqual(wm.parseWindowQuery('?ventana=2'), null);
});

check('vista conocida monta modo secundario', () => {
  const q = wm.parseWindowQuery('?ventana=2&vista=terminal');
  assert.strictEqual(q.vista, 'terminal');
  assert.strictEqual(q.ventana, 2);
  assert.strictEqual(q.order, 0);
  assert.strictEqual(q.path, '');
});

check('editor conserva la ruta Windows con barras', () => {
  const q = wm.parseWindowQuery('?ventana=3&vista=editor&path=C%3A%5Cproj%5Ca%20b.ts');
  assert.strictEqual(q.vista, 'editor');
  assert.strictEqual(q.path, 'C:\\proj\\a b.ts');
});

check('conversacion acepta order y order_id', () => {
  assert.strictEqual(wm.parseWindowQuery('?ventana=2&vista=conversacion&order=41').order, 41);
  assert.strictEqual(wm.parseWindowQuery('?vista=conversacion&order_id=7').order, 7);
});

check('vista desconocida no es secundaria', () => {
  assert.strictEqual(wm.parseWindowQuery('?ventana=2&vista=shell'), null);
  assert.strictEqual(wm.parseWindowQuery('?vista=../../etc/passwd'), null);
});

check('valores corruptos no rompen el parser', () => {
  const q = wm.parseWindowQuery('?ventana=abc&vista=monitor&order=x');
  assert.strictEqual(q.vista, 'monitor');
  assert.strictEqual(q.ventana, 0);
  assert.strictEqual(q.order, 0);
});

check('query ilegible devuelve null', () => {
  assert.strictEqual(wm.parseWindowQuery(null), null);
});

// ── DOM mínimo para probar el montaje ─────────────────────────────────────
const doc = global.document;
const app = new El('beats-app');
app.ownerDocument = doc;
const bar = new El();
bar.classList.add('titlebar');
bar.ownerDocument = doc;
app.appendChild(bar);
const pane = new El('panel-bottom');
pane.ownerDocument = doc;
app.appendChild(pane);
// D5: controles que NO deben sobrevivir a la ventana secundaria.
const btnPopout = new El('btn-popout-bottom');
btnPopout.ownerDocument = doc;
pane.appendChild(btnPopout);
const btnCloseSide = new El('btn-close-side-panel');
btnCloseSide.ownerDocument = doc;
pane.appendChild(btnCloseSide);
const btnPopoutHeader = new El();
btnPopoutHeader.title = 'abrir en ventana nueva';
btnPopoutHeader.ownerDocument = doc;
pane.appendChild(btnPopoutHeader);
doc.body.appendChild(app);

check('mountSecondaryView mueve el panel y oculta el shell', () => {
  const out = wm.mountSecondaryView('panel-bottom');
  assert.strictEqual(out, pane);
  assert.strictEqual(app.style.display, 'none');
  const host = document.getElementById('ventana-unica');
  assert.ok(host, 'existe #ventana-unica');
  assert.ok(host.children.includes(pane), 'el panel vive en el host aislado');
  assert.ok(document.body.classList._s.has('ventana-secundaria'));
});

check('la barra de título viaja con la ventana (drag/min/max/close)', () => {
  const host = document.getElementById('ventana-unica');
  assert.ok(host.children.includes(bar), 'titlebar reparentada al host');
  assert.ok(!app.children.includes(bar));
});

check('panel inexistente devuelve null sin tocar el shell', () => {
  app.style.display = '';
  assert.strictEqual(wm.mountSecondaryView('no-existe'), null);
});

// ── r1 · D1/D2 (plan de montaje) y D5 (ocultar controles) ──────
let failures = 0;
const checkFail = (name, fn) => {
  try {
    fn();
    passed++;
    console.log(`  ok ${name}`);
  } catch (e) {
    failures++;
    console.log(`  FAIL ${name}: ${e.message}`);
  }
};
const checkFailAsync = async (name, fn) => {
  try {
    await fn();
    passed++;
    console.log(`  ok ${name}`);
  } catch (e) {
    failures++;
    console.log(`  FAIL ${name}: ${e.message}`);
  }
};
const findIn = (root, pred) => {
  const stack = [root];
  while (stack.length) {
    const n = stack.pop();
    if (pred(n)) return n;
    stack.push(...n.children);
  }
  return null;
};

checkFail('D1: secondaryMountPlan(terminal) pide sidePanel terminal', () => {
  const plan = wm.secondaryMountPlan('terminal');
  assert.strictEqual(plan.paneId, 'panel-bottom');
  assert.strictEqual(plan.sidePanel, 'terminal');
});

checkFail('D2: secondaryMountPlan(conversacion) monta pane-mission-container, no panel-secondary', () => {
  const plan = wm.secondaryMountPlan('conversacion');
  assert.strictEqual(plan.paneId, 'pane-mission-container');
  assert.notStrictEqual(plan.paneId, 'panel-secondary');
  assert.strictEqual(plan.sidePanel, null);
});

checkFail('secondaryMountPlan: editor y monitor apuntan a sus paneles', () => {
  assert.strictEqual(wm.secondaryMountPlan('editor').paneId, 'monaco-editor-container');
  assert.strictEqual(wm.secondaryMountPlan('monitor').paneId, 'pane-monitor-container');
});

checkFail('D5: tras mountSecondaryView el popout y la ✕ dentro de #ventana-unica quedan ocultos', () => {
  const host = document.getElementById('ventana-unica');
  assert.ok(host, 'existe #ventana-unica (montaje previo)');
  const popout = findIn(host, (e) => e.id === 'btn-popout-bottom');
  assert.ok(popout, 'el ⧉ inferior viajó con el panel');
  assert.strictEqual(popout.style.display, 'none', 'btn-popout-bottom oculto');
  const close = findIn(host, (e) => e.id === 'btn-close-side-panel');
  assert.ok(close, 'la ✕ del panel viajó con el panel');
  assert.strictEqual(close.style.display, 'none', 'btn-close-side-panel oculto');
  const header = findIn(host, (e) => e.title === 'abrir en ventana nueva');
  assert.ok(header, 'el ⧉ de cabecera viajó con el panel');
  assert.strictEqual(header.style.display, 'none', '⧉ de cabecera oculto');
});

// ── c2 · P2-1: un control recreado DESPUÉS sigue oculto ────────
const activationSource = () => {
  const main = fs.readFileSync(path.join(SRC, 'main.ts'), 'utf8');
  const start = main.indexOf('  const activateSecondaryWindow =');
  const marker = '\n  };';
  const end = main.indexOf(marker, start) + marker.length;
  assert.ok(start >= 0 && end > start, 'activateSecondaryWindow localizada en main.ts');
  return main.slice(start, end);
};

// ── c2 · P2-2: activación REAL con colaboradores controlados ───
const runActivation = (source, query) => {
  const calls = [];
  const state = { pane: null, title: '' };
  const code = stripTs(source) + '\nglobalThis.__activate = activateSecondaryWindow;';
  const context = {
    calls,
    state,
    document: {
      get title() {
        return state.title;
      },
      set title(value) {
        state.title = value;
      },
    },
    secondaryMountPlan: wm.secondaryMountPlan,
    router: {
      showSidePanel: (kind) => calls.push('side:' + kind),
      show: (kind) => calls.push('show:' + kind),
    },
    mountSecondaryView: (id) => {
      calls.push('mount:' + id);
      state.pane = { dataset: {} };
      return state.pane;
    },
    mountSecondaryFallback: (vista) => calls.push('fallback:' + vista),
    window: { dispatchEvent: (event) => calls.push('event:' + event.type) },
    Event: class Event {
      constructor(type) {
        this.type = type;
      }
    },
    openSession: (id) => calls.push('session:' + id),
    activeEditor: null,
    monitorPanel: null,
  };
  vm.createContext(context);
  vm.runInContext(code, context, { filename: 'main.ts#activateSecondaryWindow' });
  context.__activate(query);
  return { calls, pane: state.pane, title: state.title };
};

const expectTerminal = (result) => {
  const side = result.calls.indexOf('side:terminal');
  const mount = result.calls.indexOf('mount:panel-bottom');
  const resize = result.calls.indexOf('event:resize');
  assert.ok(side >= 0, 'terminal debe montar showSidePanel(terminal)');
  assert.ok(mount >= 0, 'terminal debe montar panel-bottom');
  assert.ok(side < mount, 'showSidePanel(terminal) debe ir ANTES de mover el panel');
  assert.ok(resize > mount, 'el resize debe ir DESPUÉS del montaje');
  assert.strictEqual(result.pane.dataset.collapsed, 'false', 'terminal debe desplegar el panel');
};

const expectConversation = (result, order) => {
  assert.ok(result.calls.includes('show:agent'), 'conversación debe poblar con router.show(agent)');
  assert.ok(result.calls.includes('mount:pane-mission-container'), 'conversación debe montar pane-mission-container');
  assert.ok(!result.calls.includes('side:activity'), 'conversación no debe montar activity');
  assert.ok(!result.calls.includes('mount:panel-secondary'), 'conversación no debe montar panel-secondary');
  if (order > 0) {
    assert.ok(result.calls.includes('session:' + order), 'order>0 debe abrir su sesión');
  } else {
    assert.ok(!result.calls.some((c) => c.startsWith('session:')), 'order=0 no debe abrir sesión');
  }
};

const mutate = (source, before, after) => {
  assert.ok(source.includes(before), `mutación localizable: ${before}`);
  return source.replace(before, after);
};

const expectDetected = (label, mutated, query, checker) => {
  let failure = null;
  try {
    checker(runActivation(mutated, query));
  } catch (e) {
    failure = e;
  }
  if (!failure) throw new Error(`mutación NO detectada: ${label}`);
  console.log(`  MUTACION DETECTADA ${label}: ${String(failure.message).split('\n')[0]}`);
};

// c3/P3: cada mutación de c2 se puede ejecutar en su propio
// proceso con --discrimination=<id>, que devuelve un código de salida propio.
// Así la evidencia no confunde "detección interna" con "proceso rojo".
const DISCRIMINATIONS = [
  {
    id: 'sin-showSidePanel',
    exit: 41,
    checkName: 'P2-2 discriminación: retirar showSidePanel hace fallar la terminal',
    label: 'main.ts sin showSidePanel',
    query: { vista: 'terminal', ventana: 2, order: 0, path: '' },
    mutate: (source) => mutate(source, 'if (plan.sidePanel) router.showSidePanel(plan.sidePanel);', 'if (plan.sidePanel) void 0;'),
    check: expectTerminal,
  },
  {
    id: 'sin-resize',
    exit: 42,
    checkName: 'P2-2 discriminación: retirar resize hace fallar la terminal',
    label: 'main.ts sin resize',
    query: { vista: 'terminal', ventana: 2, order: 0, path: '' },
    mutate: (source) => mutate(source, "window.dispatchEvent(new Event('resize'));", 'void 0;'),
    check: expectTerminal,
  },
  {
    id: 'conversacion-panel-secondary',
    exit: 43,
    checkName: 'P2-2 discriminación: montar la conversación en panel-secondary hace fallar',
    label: 'main.ts conversación a panel-secondary',
    query: { vista: 'conversacion', ventana: 2, order: 41, path: '' },
    mutate: (source) => mutate(
      source,
      'const pane = mountSecondaryView(plan.paneId);',
      "const pane = mountSecondaryView(q.vista === 'conversacion' ? 'panel-secondary' : plan.paneId);",
    ),
    check: (result) => expectConversation(result, 41),
  },
  {
    id: 'sin-openSession',
    exit: 44,
    checkName: 'P2-2 discriminación: retirar openSession hace fallar order>0',
    label: 'main.ts sin openSession',
    query: { vista: 'conversacion', ventana: 2, order: 41, path: '' },
    mutate: (source) => mutate(source, 'if (q.order > 0) void openSession(q.order);', 'void 0;'),
    check: (result) => expectConversation(result, 41),
  },
  {
    id: 'sin-show-agent',
    exit: 45,
    checkName: 'P2-2 discriminación: retirar router.show(agent) hace fallar la conversación',
    label: 'main.ts sin show(agent)',
    query: { vista: 'conversacion', ventana: 2, order: 0, path: '' },
    mutate: (source) => mutate(source, "router.show('agent' as ViewId);", 'void 0;'),
    check: (result) => expectConversation(result, 0),
  },
  {
    id: 'terminal-tras-montaje',
    exit: 46,
    checkName: 'P2-2 discriminación: inicializar la terminal DESPUÉS de mover el panel falla por orden',
    label: 'main.ts terminal inicializada tras el montaje',
    query: { vista: 'terminal', ventana: 2, order: 0, path: '' },
    mutate: (source) => {
      const moved = mutate(source, 'if (plan.sidePanel) router.showSidePanel(plan.sidePanel);', 'if (plan.sidePanel) void 0;');
      return mutate(moved, 'const pane = mountSecondaryView(plan.paneId);', 'const pane = mountSecondaryView(plan.paneId); if (plan.sidePanel) router.showSidePanel(plan.sidePanel);');
    },
    check: expectTerminal,
  },
];

const DISCRIMINATION_ARG = process.argv.find((arg) => arg.startsWith('--discrimination='));
const DISCRIMINATION_ID = DISCRIMINATION_ARG ? DISCRIMINATION_ARG.slice('--discrimination='.length) : null;

const runDiscrimination = () => {
  const disc = DISCRIMINATIONS.find((d) => d.id === DISCRIMINATION_ID);
  if (!disc) {
    console.error(`window_mode_test: discriminación desconocida "${DISCRIMINATION_ID}"`);
    process.exitCode = 90;
    return;
  }
  let failure = null;
  try {
    disc.check(runActivation(disc.mutate(activationSource()), disc.query));
  } catch (e) {
    failure = e;
  }
  if (failure) {
    console.log(`DISCRIMINACION ${disc.id} DETECTADA (exit ${disc.exit}): ${String(failure.message).split('\n')[0]}`);
    process.exitCode = disc.exit;
    return;
  }
  console.log(`DISCRIMINACION ${disc.id} NO DETECTADA (exit 97)`);
  process.exitCode = 97;
};

if (DISCRIMINATION_ID) {
  runDiscrimination();
} else {
(async () => {
  await checkFailAsync('D5: control recreado tras el montaje sigue oculto (observador del host)', async () => {
    const host = document.getElementById('ventana-unica');
    assert.ok(host, 'existe #ventana-unica');
    // Reemplazo real: el panel vacía sus hijos y crea de nuevo los controles.
    pane.children = [];
    const renewedPopout = new El('btn-popout-bottom');
    renewedPopout.ownerDocument = doc;
    pane.appendChild(renewedPopout);
    const renewedHeader = new El();
    renewedHeader.title = 'abrir en ventana nueva';
    renewedHeader.ownerDocument = doc;
    pane.appendChild(renewedHeader);
    await settle();
    assert.ok(findIn(host, (e) => e === renewedPopout), 'el control recreado existe');
    assert.strictEqual(renewedPopout.style.display, 'none', 'popout recreado debe seguir oculto');
    assert.strictEqual(renewedHeader.style.display, 'none', '⧉ de cabecera recreado debe seguir oculto');
  });

  await checkFailAsync('D5: un control equivalente FUERA de #ventana-unica no se altera', async () => {
    const outside = new El('btn-popout-bottom');
    outside.ownerDocument = doc;
    app.appendChild(outside);
    await settle();
    assert.notStrictEqual(outside.style.display, 'none', 'la principal conserva su popout');
  });

  // P2-1 · ciclo real del Monitor: paint original -> montaje -> refresh.
  await checkFailAsync('P2-1: el #mon-popout recreado por MonitorPanel.refresh sigue oculto', async () => {
    const doc2 = makeDocument();
    const app2 = new El('beats-app');
    app2.ownerDocument = doc2;
    const bar2 = new El();
    bar2.classList.add('titlebar');
    bar2.ownerDocument = doc2;
    app2.appendChild(bar2);
    const pane2 = new El('pane-monitor-container');
    pane2.ownerDocument = doc2;
    app2.appendChild(pane2);
    doc2.body.appendChild(app2);

    const iconProxy = new Proxy({}, { get: () => () => '' });
    const htmlStub = {
      escapeText: (v) => String(v),
      escapeAttribute: (v) => String(v),
      html: () => '',
      joinHtml: () => '',
      raw: () => '',
    };
    const moduleObj = { exports: {} };
    const context = {
      module: moduleObj,
      exports: moduleObj.exports,
      document: doc2,
      MutationObserver: MockMutationObserver,
      queueMicrotask,
      URLSearchParams,
      Number,
      console,
      window: {
        setInterval: () => 0,
        clearInterval: () => {},
        setTimeout: (fn, ms) => setTimeout(fn, ms),
        clearTimeout: (id) => clearTimeout(id),
      },
      CustomEvent: class CustomEvent {
        constructor(type, opts) {
          this.type = type;
          this.detail = opts && opts.detail;
        }
      },
      require: (id) => {
        if (id.endsWith('/icons')) return { icons: iconProxy };
        if (id.endsWith('/html')) return htmlStub;
        return {};
      },
    };
    vm.createContext(context);
    vm.runInContext(bundleCode(), context, { filename: bundlePath() });
    const wm2 = moduleObj.exports;
    for (const name of EXPECTED_EXPORTS) {
      assert.ok(name in wm2, `el bundle no exporta ${name}`);
    }
    const panelModule = { exports: {} };
    context.module = panelModule;
    context.exports = panelModule.exports;
    vm.runInContext(monitorCode(), context, { filename: 'monitor_panel.ts' });
    const MonitorPanel = panelModule.exports.MonitorPanel;

    const core = {};
    for (const name of ['status', 'catalogInfo', 'listSessions', 'pendingApprovals', 'health', 'specialists', 'ledger', 'modelScores', 'evolution']) {
      core[name] = async () => (name === 'status' ? { engineReady: true } : name === 'evolution' ? {} : []);
    }
    const panel = Object.create(MonitorPanel.prototype);
    Object.assign(panel, {
      container: pane2,
      core,
      loading: false,
      refreshPending: false,
      errors: {},
      status: { engineReady: true },
      autoRefreshOn: false,
      autoRefreshMs: 5000,
      timer: null,
      approvalToFocus: null,
      approvalFocusRestore: null,
      focusRetryTimer: null,
      suppressApprovalFocus: false,
      catalog: null,
      sessions: [],
      approvals: [],
      health: [],
      specialists: [],
      ledger: [],
      modelScores: [],
      evolution: null,
      evolutionError: null,
    });
    for (const name of ['renderResumen', 'renderSesiones', 'renderAprobaciones', 'renderSalud', 'renderEspecialistas', 'renderEvolucion', 'renderLedger']) {
      panel[name] = () => '';
    }

    panel.paint();
    const first = doc2.getElementById('mon-popout');
    assert.ok(first, 'MON: mon-popout inicial');

    wm2.mountSecondaryView('pane-monitor-container');
    assert.strictEqual(first.style.display, 'none', 'MON: mon-popout oculto al montar');

    await panel.refresh();
    await settle();

    const next = doc2.getElementById('mon-popout');
    assert.ok(next, 'MON: mon-popout recreado por refresh');
    assert.notStrictEqual(next, first, 'MON: el refresh reemplazó el nodo');
    assert.strictEqual(next.style.display, 'none', 'D5: mon-popout debe seguir oculto tras refresh');
    assert.strictEqual(typeof next.listeners.click, 'function', 'MON: listener del popout conservado');
    next.listeners.click();
    assert.ok(
      doc2.events.some((e) => e.type === 'devagents:open-window' && e.detail && e.detail.vista === 'monitor'),
      'MON: el botón recreado mantiene su listener',
    );
  });

  // P2-2 · la función REAL de main.ts, sin mutar, cumple el cableado.
  const realActivation = activationSource();
  checkFail('P2-2: terminal real pide sidePanel ANTES del montaje y hace resize DESPUÉS', () => {
    expectTerminal(runActivation(realActivation, { vista: 'terminal', ventana: 2, order: 0, path: '' }));
  });
  checkFail('P2-2: conversación real usa agent + pane-mission-container y abre order>0', () => {
    expectConversation(runActivation(realActivation, { vista: 'conversacion', ventana: 2, order: 41, path: '' }), 41);
  });
  checkFail('P2-2: conversación real con order=0 no abre sesión', () => {
    expectConversation(runActivation(realActivation, { vista: 'conversacion', ventana: 2, order: 0, path: '' }), 0);
  });

  console.log('\n  -- ROJO DE DISCRIMINACIÓN (mutaciones solo en memoria) --');
  for (const disc of DISCRIMINATIONS) {
    checkFail(disc.checkName, () => {
      expectDetected(disc.label, disc.mutate(realActivation), disc.query, disc.check);
    });
  }

  console.log(`\nwindow_mode: ${passed} checks OK, ${failures} FAIL`);
  if (failures) process.exitCode = 1;
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
}
