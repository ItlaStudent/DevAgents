// entrega C · splitTerminal con DOM real en Chromium por CDP.
// Ronda 2: además de los cuatro criterios de la ronda 1, cubre
//   R2-1 ruta xterm real del panel 2 (window.Terminal simulado),
//   R2-2 guarda de reentrada de split() y revalidacion tras el spawn,
//   R2-3 ResizeObserver del panel 2 desconectado en unsplit(),
//   R2-4 aislamiento del estado ANSI, cambio de sesion y stop con division.
// El modulo se compila en memoria con esbuild (no escribe dist/) y el backend
// de terminal es un doble: no abre la cabina ni usa datos del usuario.
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const esbuild = require('esbuild');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');
const root = path.resolve(__dirname, '../../..');
const profiles = path.join(root, '.zig-cache/cab005c-browser');
fs.mkdirSync(profiles, { recursive: true });
const profile = fs.mkdtempSync(path.join(profiles, 'profile-'));

const bundle = esbuild.buildSync({
  absWorkingDir: root,
  tsconfigRaw: JSON.parse(fs.readFileSync(path.join(root, 'shell/webui/tsconfig.json'), 'utf8')),
  entryPoints: [path.join(__dirname, '../src/terminal/xterm_terminal.ts')],
  bundle: true, format: 'iife', globalName: 'XtermModule', platform: 'browser',
  write: false, logLevel: 'silent',
});
const source = bundle.outputFiles[0].text;

const browser = spawn(resolveBrowser(), ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`,
  '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
const pending = new Map(), errors = [];
let buffer = '', sequence = 0, session, stderr = '';
browser.stderr.on('data', data => { stderr += data; });
const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
browser.on('error', fail);
browser.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
browser.stdio[4].on('data', data => {
  buffer += data.toString();
  let end;
  while ((end = buffer.indexOf('\0')) >= 0) {
    const message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
    if (message.method === 'Runtime.exceptionThrown' || (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error')) errors.push(message);
    const request = pending.get(message.id);
    if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
  }
});
function send(method, params = {}, sessionId = session) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 15000);
    pending.set(id, { resolve, reject, timer });
    browser.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
  });
}
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}

const results = [];
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  results.push({ name, ok, actual, expected });
  return ok;
}
function checkMatch(name, text, re) {
  const ok = re.test(text);
  results.push({ name, ok, actual: String(text).slice(0, 120), expected: String(re) });
  return ok;
}
function checkNoMatch(name, text, re) {
  const ok = !re.test(text);
  results.push({ name, ok, actual: String(text).slice(0, 120), expected: 'no ' + String(re) });
  return ok;
}

async function main() {
  try {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
    const result = await evaluate(`(async () => {
      document.body.innerHTML = '<h1>CK-CAB-005 C: splitTerminal R2</h1>'
        + '<div id="terminal" style="height:400px"></div>'
        + '<div id="terminal2" style="height:400px"></div>'
        + '<div id="terminal3" style="height:400px"></div>';
      const factory = new Function(${JSON.stringify(source)} + '\\nreturn XtermModule;');
      window.XtermModule = factory();

      // --- Contador de intervalos vivos (R2-2: «un intervalo») --------------
      const tracked = new Set();
      const origSetInterval = window.setInterval.bind(window);
      const origClearInterval = window.clearInterval.bind(window);
      window.setInterval = (...args) => { const h = origSetInterval(...args); tracked.add(h); return h; };
      window.clearInterval = (h) => { tracked.delete(h); origClearInterval(h); };
      window.liveIntervals = () => tracked.size;

      // --- Doble del backend -----------------------------------------------
      const freshSession = id => ({ terminalId: id, shellPath: 'cmd.exe', cols: 80, rows: 25, running: true, mode: 'conpty' });
      const host = {
        texts: new Map([[42, 'CAB005C_PREVIA\\r\\n']]), writes: [], kills: [], spawns: 0, nextId: 43,
        failSpawn: false, spawnDelay: 0, terminals: [freshSession(42)],
      };
      const resetHost = (marker) => {
        host.texts = new Map([[42, marker + '\\r\\n']]);
        host.writes = []; host.kills = []; host.spawns = 0; host.nextId = 43;
        host.failSpawn = false; host.spawnDelay = 0; host.terminals = [freshSession(42)];
      };
      window.bridgeClient = { send: async (kind, payload) => {
        if (kind === 'pty.read' && payload && payload.list) return { payload: { terminals: host.terminals.slice() } };
        throw new Error('bridge inesperado: ' + kind);
      } };
      window.terminalCore = {
        ptyRead: async (id, offset) => {
          if (!host.texts.has(id)) host.texts.set(id, '');
          const bytes = new TextEncoder().encode(host.texts.get(id));
          return { data: new TextDecoder().decode(bytes.slice(offset)), offset: bytes.length };
        },
        ptyWrite: async (id, data) => { host.writes.push({ id, data }); },
        ptyResize: async () => ({}),
        ptyKill: async (id) => { host.kills.push(id); host.terminals = host.terminals.filter(t => t.terminalId !== id); },
        ptySpawn: async () => {
          if (host.failSpawn) throw new Error('sin cupo para otra PTY');
          if (host.spawnDelay) await new Promise(resolve => setTimeout(resolve, host.spawnDelay));
          host.spawns++;
          const id = host.nextId++;
          host.terminals.push(freshSession(id));
          return { terminalId: id, mode: 'conpty' };
        },
      };
      window.host = host;

      // ======================================================================
      // Instancia 1: los cuatro criterios de la ronda 1 + ANSI + selector + stop
      // ======================================================================
      const container1 = document.querySelector('#terminal');
      window.terminal = new XtermModule.XtermTerminal(container1, window.terminalCore);
      await terminal.start();
      terminal.stopPolling();
      const panes1 = () => [...container1.querySelectorAll('.term-pane')];
      const before = { id: terminal.terminalId, running: terminal.running, sessions: terminal.sessions.map(s => s.terminalId), panes: panes1().length };

      // Criterio 4 (parte que falla): solo hay una sesion y el backend no deja crear otra.
      host.failSpawn = true;
      const failed = await terminal.split();
      const failedState = { failed, panes: panes1().length, sessions: terminal.sessions.map(s => s.terminalId),
        running: terminal.running, writes: host.writes.length, kills: host.kills.length };

      // Criterio 1: dividir crea la segunda sesion y deja dos paneles atados a sesiones distintas.
      host.failSpawn = false;
      const ok = await terminal.split();
      terminal.stopSplitPolling();
      const splitState = { ok, spawns: host.spawns, sessions: terminal.sessions.map(s => s.terminalId),
        panes: panes1().map(p => ({ id: p.id, terminalId: p.dataset.terminalId })),
        primary: terminal.terminalId, splitId: terminal.splitTerminalId };

      // Criterio 2: aislamiento de entrada y de salida.
      const paneA = container1.querySelector('#term-pane');
      const paneB = container1.querySelector('#term-pane-2');
      paneA.querySelector('#term-input').value = 'echo SOLO_A';
      paneA.querySelector('#term-input').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      paneB.querySelector('#term-input-2').value = 'echo SOLO_B';
      paneB.querySelector('#term-input-2').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      await new Promise(resolve => setTimeout(resolve, 30));
      const writes = host.writes.map(w => ({ id: w.id, data: w.data }));
      host.texts.set(42, host.texts.get(42) + 'SALIDA_SOLO_A\\r\\n');
      host.texts.set(43, host.texts.get(43) + 'SALIDA_SOLO_B\\r\\n');
      await terminal.pollOnce();
      await terminal.pollSplitOnce();
      const textA = paneA.querySelector('#term-output-plain').textContent;
      const textB = paneB.querySelector('#term-output-plain-2').textContent;

      // R2-4 (i): el estado ANSI de un panel no tiñe al otro. \\x1b[31m en A;
      // en B solo texto plano, que debe salir sin ningun estilo.
      host.texts.set(42, host.texts.get(42) + '\\x1b[31mROJO_SOLO_A\\r\\n');
      host.texts.set(43, host.texts.get(43) + 'PLANO_SOLO_B\\r\\n');
      await terminal.pollOnce();
      await terminal.pollSplitOnce();
      const ansiA = paneA.querySelector('#term-output-plain').innerHTML;
      const ansiB = paneB.querySelector('#term-output-plain-2').innerHTML;

      // Criterio 3: deshacer la division no mata ninguna PTY y se puede volver a ver.
      const killsBefore = host.kills.length;
      terminal.unsplit();
      const unsplitState = { panes: panes1().length, sessions: terminal.sessions.map(s => s.terminalId),
        running: terminal.running, kills: host.kills.length, textA: paneA.querySelector('#term-output-plain').textContent };
      const spawnsBefore = host.spawns;
      terminal.stopPolling();
      const again = await terminal.split();
      terminal.stopSplitPolling();
      const paneB2 = container1.querySelector('#term-pane-2');
      paneB2.querySelector('#term-input-2').value = 'echo OTRA_VEZ';
      paneB2.querySelector('#term-input-2').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      await new Promise(resolve => setTimeout(resolve, 30));
      const resplitState = { again, panes: panes1().length, spawns: host.spawns, spawnsBefore,
        sessions: terminal.sessions.map(s => s.terminalId), splitId: terminal.splitTerminalId,
        lastWrite: host.writes[host.writes.length - 1], kills: host.kills.length, killsBefore };

      // R2-4 (ii a): cambiar de sesion en el selector con la division abierta.
      const sel = container1.querySelector('#term-session');
      const selectorBefore = { value: sel.value, options: [...sel.options].map(o => o.value) };
      sel.value = '43';
      sel.dispatchEvent(new Event('change'));
      await new Promise(resolve => setTimeout(resolve, 30));
      const selectorState = { options: [...sel.options].map(o => o.value), value: sel.value,
        primaryId: terminal.terminalId, primaryDataset: container1.querySelector('#term-pane').dataset.terminalId,
        panes: panes1().length, pane2: !!container1.querySelector('#term-pane-2'),
        live: window.liveIntervals(), running: terminal.running };

      // R2-4 (ii b): stop() con la division abierta: sin intervalos ni paneles.
      terminal.stopPolling();
      const okStopSplit = await terminal.split();
      const liveWithSplit = window.liveIntervals();
      terminal.stop();
      const stopState = { okStopSplit, panes: panes1().length, pane2: !!container1.querySelector('#term-pane-2'),
        live: window.liveIntervals(), liveWithSplit, kills: [...host.kills],
        sessions: terminal.sessions.map(s => s.terminalId), running: terminal.running };

      // ======================================================================
      // Instancia 2 (container2): R2-2 reentrada y revalidacion tras el spawn
      // ======================================================================
      const container2 = document.querySelector('#terminal2');
      resetHost('T2_PREVIA');
      const t2 = new XtermModule.XtermTerminal(container2, window.terminalCore);
      await t2.start();
      t2.stopPolling();
      const panes2 = () => [...container2.querySelectorAll('.term-pane')];

      // R2-2: dos split() SIN esperar a la primera: solo un spawn, un panel y un intervalo.
      host.spawnDelay = 40;
      const p1 = t2.split();
      const p2 = t2.split();
      const [d1, d2] = await Promise.all([p1, p2]);
      host.spawnDelay = 0;
      const reentrant = { d1, d2, spawns: host.spawns,
        pane2Count: container2.querySelectorAll('#term-pane-2').length, panes: panes2().length,
        sessions: t2.sessions.map(s => s.terminalId), live: window.liveIntervals() };
      t2.unsplit();
      t2.stopSplitPolling();

      // R2-2 (ii): el usuario para la terminal mientras se espera el spawn:
      // no se monta panel y la PTY nueva no queda huérfana (se mata).
      resetHost('T2B_PREVIA');
      const t2b = new XtermModule.XtermTerminal(container2, window.terminalCore);
      await t2b.start();
      t2b.stopPolling();
      host.spawnDelay = 60;
      const ps = t2b.split();
      await new Promise(resolve => setTimeout(resolve, 15));
      t2b.stop();
      const stopDuringOk = await ps;
      host.spawnDelay = 0;
      const stopDuring = { ok: stopDuringOk, kills: [...host.kills], sessions: t2b.sessions.map(s => s.terminalId),
        pane2: !!container2.querySelector('#term-pane-2'), panes: panes2().length,
        live: window.liveIntervals(), running: t2b.running };

      // ======================================================================
      // Instancia 3 (container3): R2-1 xterm real en el panel 2 y R2-3 observer
      // ======================================================================
      resetHost('T3_PREVIA');
      // Doble de xterm.js: basta con open/onData/write/dispose para el camino del panel.
      window.Terminal = class {
        constructor(opts) { this.options = opts || {}; this.cols = 80; this.rows = 25; this.written = ''; this.disposed = false; this.host = null; }
        open(hostEl) { this.host = hostEl; const el = document.createElement('div'); el.className = 'xterm'; hostEl.appendChild(el); }
        onData(cb) { this.dataCb = cb; }
        onResize(cb) { this.resizeCb = cb; }
        write(data) { this.written += data; }
        clear() {}
        reset() {}
        focus() {}
        dispose() { this.disposed = true; if (this.host) this.host.innerHTML = ''; }
        loadAddon() {}
      };
      let roLive = 0;
      const OrigRO = window.ResizeObserver;
      window.ResizeObserver = class extends OrigRO {
        constructor(cb) { super(cb); roLive++; }
        disconnect() { roLive--; super.disconnect(); }
      };
      window.roLive = () => roLive;

      const container3 = document.querySelector('#terminal3');
      const t3 = new XtermModule.XtermTerminal(container3, window.terminalCore);
      await t3.start();
      t3.stopPolling();
      const roAfterStart = window.roLive();
      const primaryHasXterm = !!container3.querySelector('#term-output .xterm');
      const ok3 = await t3.split();
      const pane2el = container3.querySelector('#term-pane-2');
      const xtermPanel2 = !!pane2el.querySelector('#term-output-2 .xterm');
      const plainHidden = pane2el.querySelector('#term-output-plain-2').style.display === 'none';
      const roAfterSplit = window.roLive();
      const splitXRef = t3.splitXterm;
      // C3-2: el montaje .xterm no basta: ejercer ambos sentidos del transporte.
      t3.stopSplitPolling();
      t3.xterm.dataCb('VENDOR_INPUT_A');
      splitXRef.dataCb('VENDOR_INPUT_B');
      await Promise.resolve();
      const vendorWrites = host.writes.slice();
      const primaryWrittenBefore = t3.xterm.written.length;
      const secondaryWrittenBefore = splitXRef.written.length;
      host.texts.set(42, host.texts.get(42) + 'VENDOR_OUTPUT_A\\r\\n');
      host.texts.set(43, (host.texts.get(43) || '') + 'VENDOR_OUTPUT_B\\r\\n');
      await t3.pollOnce();
      await t3.pollSplitOnce();
      const vendorOutput = { primary: t3.xterm.written.slice(primaryWrittenBefore),
        secondary: splitXRef.written.slice(secondaryWrittenBefore) };
      t3.unsplit();
      const unsplitX = { pane2: !!container3.querySelector('#term-pane-2'), disposed: !!splitXRef?.disposed,
        ro: window.roLive(), sessions: t3.sessions.map(s => s.terminalId), kills: host.kills.length, spawns: host.spawns };
      const again3 = await t3.split();
      const reuseState = { again3, spawns: host.spawns, sessions: t3.sessions.map(s => s.terminalId),
        splitId: t3.splitTerminalId, xterm2: !!container3.querySelector('#term-pane-2 #term-output-2 .xterm') };
      t3.stop();

      // C3-1: A cancelada y B pendiente, ordenadas solo por resolutores.
      // En el código defectuoso A llega a su primera lectura; corregida,
      // termina antes de leer. La barrera admite ambas rutas sin temporizadores.
      const deferred = () => {
        let resolve;
        const promise = new Promise(r => { resolve = r; });
        return { promise, resolve };
      };
      resetHost('C3_CARRERA');
      const raceContainer = document.createElement('div');
      document.body.appendChild(raceContainer);
      const raceCore = { ...window.terminalCore };
      const race = new XtermModule.XtermTerminal(raceContainer, raceCore);
      await race.start();
      race.stopPolling();
      const raceRoBefore = window.roLive();
      const spawnA = deferred(), spawnB = deferred();
      const readA = deferred(), readB = deferred();
      const startedA = deferred(), startedB = deferred();
      const spawnQueue = [spawnA, spawnB];
      let raceSpawns = 0;
      raceCore.ptySpawn = () => spawnQueue[raceSpawns++].promise;
      raceCore.ptyRead = (id, offset) => {
        if (id === 42) return window.terminalCore.ptyRead(id, offset);
        (id === 43 ? startedA : startedB).resolve();
        return (id === 43 ? readA : readB).promise;
      };
      const firstSplit = race.split();
      race.unsplit();
      const secondSplit = race.split();
      spawnA.resolve({ terminalId: 43, mode: 'conpty' });
      await Promise.race([firstSplit, startedA.promise]);
      // El finally de A no puede liberar la guarda que ahora pertenece a B.
      const guardWhileBSpawns = race.splitting;
      spawnB.resolve({ terminalId: 44, mode: 'conpty' });
      await Promise.race([secondSplit, startedB.promise]);
      const duplicatePanes = [...raceContainer.querySelectorAll('#term-pane-2')];
      readA.resolve({ data: 'ANTIGUA_43', offset: 10 });
      readB.resolve({ data: 'ACTUAL_44', offset: 9 });
      const splitResults = await Promise.all([firstSplit, secondSplit]);
      const raceLive = window.liveIntervals();
      const writesBeforeRace = host.writes.length;
      const primaryInput = raceContainer.querySelector('#term-input');
      primaryInput.value = 'PRIMARY_42';
      primaryInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      for (const pane of duplicatePanes) pane.querySelector('#term-input-2').value = 'PANEL_' + pane.dataset.terminalId;
      duplicatePanes[0].querySelector('#term-input-2').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      await Promise.resolve();
      const raceXterm = race.splitXterm;
      const raceState = { spawns: raceSpawns, splitResults, guardWhileBSpawns,
        paneSessions: duplicatePanes.map(p => p.dataset.terminalId),
        sessions: race.sessions.map(s => s.terminalId), kills: [...host.kills],
        writes: host.writes.slice(writesBeforeRace), live: raceLive,
        firstPaneId: Number(duplicatePanes[0].dataset.terminalId),
        written: raceXterm?.written || '' };
      race.unsplit();
      const raceCleanup = { panes: raceContainer.querySelectorAll('#term-pane-2').length,
        isSplit: race.isSplit(), live: window.liveIntervals(),
        secondaryObserverCount: window.roLive() - raceRoBefore,
        disposed: raceXterm.disposed, poll: race.splitPollHandle,
        observer: race.splitResizeObserver, xterm: race.splitXterm,
        sessions: race.sessions.map(s => s.terminalId), kills: [...host.kills] };
      race.stop();

      // C3-1 post-lectura: A ya montó pero su lectura sigue pendiente al cerrar.
      // Su finally termina mientras B está leyendo y debe respetar ambas guardas.
      resetHost('C3_LECTURA');
      const readContainer = document.createElement('div');
      document.body.appendChild(readContainer);
      const readCore = { ...window.terminalCore };
      const readingRace = new XtermModule.XtermTerminal(readContainer, readCore);
      await readingRace.start();
      readingRace.stopPolling();
      const readRoBefore = window.roLive();
      const oldRead = deferred(), newRead = deferred();
      const oldReadStarted = deferred(), newReadStarted = deferred();
      const readIds = [];
      readCore.ptyRead = (id, offset) => {
        if (id === 42) return window.terminalCore.ptyRead(id, offset);
        readIds.push(id);
        (id === 43 ? oldReadStarted : newReadStarted).resolve();
        return (id === 43 ? oldRead : newRead).promise;
      };
      const pendingOld = readingRace.split();
      await oldReadStarted.promise;
      const oldVendor = readingRace.splitXterm;
      readingRace.unsplit();
      const pendingNew = readingRace.split();
      await newReadStarted.promise;
      oldRead.resolve({ data: 'NO_FILTRAR_43', offset: 13 });
      const oldResult = await pendingOld;
      const guardAfterOld = { splitting: readingRace.splitting, reading: readingRace.splitReading,
        sessions: readingRace.sessions.map(s => s.terminalId) };
      await readingRace.pollSplitOnce();
      newRead.resolve({ data: 'LECTURA_44', offset: 10 });
      const newResult = await pendingNew;
      const newVendor = readingRace.splitXterm;
      const readRace = { oldResult, newResult, guardAfterOld, readIds,
        sessions: readingRace.sessions.map(s => s.terminalId), kills: [...host.kills],
        panes: [...readContainer.querySelectorAll('#term-pane-2')].map(p => p.dataset.terminalId),
        written: newVendor.written, oldDisposed: oldVendor.disposed };
      readingRace.unsplit();
      const readCleanup = { panes: readContainer.querySelectorAll('#term-pane-2').length,
        live: window.liveIntervals(), secondaryObservers: window.roLive() - readRoBefore,
        disposed: newVendor.disposed, reading: readingRace.splitReading };
      readingRace.stop();

      return { before, failedState, splitState, writes, textA, textB, ansiA, ansiB,
        unsplitState, resplitState, selectorBefore, selectorState, stopState,
        reentrant, stopDuring, roAfterStart, primaryHasXterm, ok3, xtermPanel2, plainHidden,
        roAfterSplit, unsplitX, reuseState, vendorWrites, vendorOutput,
        raceState, raceCleanup, readRace, readCleanup, errorsInPage: [] };
    })()`);

    // --- Ronda 1: los cuatro criterios ------------------------------------
    check('R1 before', result.before, { id: 42, running: true, sessions: [42], panes: 1 });
    check('R1 sin cupo: false', result.failedState.failed, false);
    check('R1 sin cupo: un panel', result.failedState.panes, 1);
    check('R1 sin cupo: sin sesion inventada', result.failedState.sessions, [42]);
    check('R1 sin cupo: sigue viva', result.failedState.running, true);
    check('R1 sin cupo: sin kills', result.failedState.kills, 0);
    check('R1 sin cupo: sin writes', result.failedState.writes, 0);

    check('R1 split true', result.splitState.ok, true);
    check('R1 split crea la segunda PTY', result.splitState.spawns, 1);
    check('R1 sesiones [42,43]', result.splitState.sessions, [42, 43]);
    check('R1 dos paneles', result.splitState.panes.length, 2);
    check('R1 cada panel con su sesion', result.splitState.panes.map(p => p.terminalId), ['42', '43']);
    check('R1 primaria 42', result.splitState.primary, 42);
    check('R1 split 43', result.splitState.splitId, 43);

    check('R1 writes por PTY', result.writes, [{ id: 42, data: 'echo SOLO_A\r\n' }, { id: 43, data: 'echo SOLO_B\r\n' }]);
    checkMatch('R1 salida A en A', result.textA, /SALIDA_SOLO_A/);
    checkNoMatch('R1 salida B NO en A', result.textA, /SALIDA_SOLO_B/);
    checkMatch('R1 salida B en B', result.textB, /SALIDA_SOLO_B/);
    checkNoMatch('R1 salida A NO en B', result.textB, /SALIDA_SOLO_A/);

    check('R1 unsplit deja un panel', result.unsplitState.panes, 1);
    check('R1 unsplit no borra sesiones', result.unsplitState.sessions, [42, 43]);
    check('R1 unsplit primaria viva', result.unsplitState.running, true);
    check('R1 unsplit sin kills', result.unsplitState.kills, 0);
    checkMatch('R1 panel primario conserva salida', result.unsplitState.textA, /SALIDA_SOLO_A/);

    check('R1 re-split true', result.resplitState.again, true);
    check('R1 re-split dos paneles', result.resplitState.panes, 2);
    check('R1 re-split sin spawn nuevo', result.resplitState.spawns, 1);
    check('R1 re-split sesiones', result.resplitState.sessions, [42, 43]);
    check('R1 re-split misma sesion', result.resplitState.splitId, 43);
    check('R1 re-split escribe en 43', result.resplitState.lastWrite, { id: 43, data: 'echo OTRA_VEZ\r\n' });
    check('R1 re-split sin kills', result.resplitState.kills, 0);

    // --- R2-1: el panel 2 usa xterm real cuando el vendor esta cargado -----
    check('R2-1 primaria monta xterm', result.primaryHasXterm, true);
    check('R2-1 split devuelve true (vendor)', result.ok3, true);
    check('R2-1 el panel 2 termina con .xterm', result.xtermPanel2, true);
    check('R2-1 el fallback del panel 2 se oculta', result.plainHidden, true);
    check('R2-1 re-split reutiliza y vuelve a montar xterm', result.reuseState, { again3: true, spawns: 1, sessions: [42, 43], splitId: 43, xterm2: true });

    // --- R2-3: el ResizeObserver del panel 2 se desconecta en unsplit -----
    check('R2-3 observer primario al construir', result.roAfterStart, 1);
    check('R2-3 observer del panel 2 al dividir', result.roAfterSplit, 2);
    check('R2-3 unsplit retira panel, desconecta observer y no mata PTY', result.unsplitX,
      { pane2: false, disposed: true, ro: 1, sessions: [42, 43], kills: 0, spawns: 1 });

    // --- R2-2: guarda de reentrada y revalidacion tras el spawn -----------
    check('R2-2 solo la primera llamada divide', result.reentrant, { d1: true, d2: false, spawns: 1, pane2Count: 1, panes: 2, sessions: [42, 43], live: 1 });
    check('R2-2 parar durante el spawn aborta sin montar', result.stopDuring,
      { ok: false, kills: [42, 43], sessions: [42], pane2: false, panes: 1, live: 0, running: false });

    // --- R2-4: ANSI aislado, selector y stop con division -----------------
    checkMatch('R2-4 ANSI rojo solo en A', result.ansiA, /color:var\(--danger\)/);
    checkNoMatch('R2-4 el panel B no se tiñe con el rojo de A', result.ansiB, /color:/);
    checkNoMatch('R2-4 el panel B muestra su texto plano', result.ansiB, /ROJO_SOLO_A/);
    checkMatch('R2-4 el panel B muestra PLANO_SOLO_B', result.ansiB, /PLANO_SOLO_B/);

    check('R2-4 selector con division: opciones', result.selectorBefore.options, ['42', '43']);
    check('R2-4 selector con division abierta: la vista sigue unica', result.selectorState,
      { options: ['42', '43'], value: '43', primaryId: 43, primaryDataset: '43', panes: 1, pane2: false, live: 1, running: true });

    check('R2-4 dividir tras el cambio usa la otra sesion sin spawn', result.stopState.okStopSplit, true);
    check('R2-4 con division el intervalo de la vista dividida esta vivo', result.stopState.liveWithSplit, 1);
    check('R2-4 stop con division: sin panel dividido ni intervalos', result.stopState,
      { okStopSplit: true, panes: 1, pane2: false, live: 0, liveWithSplit: 1, kills: [43], sessions: [42, 43], running: false });

    console.log('C3_RACE=' + JSON.stringify(result.raceState));
    check('C3-1 A cancelada false y B true', result.raceState.splitResults, [false, true]);
    check('C3-1 solo dos spawns controlados', result.raceState.spawns, 2);
    check('C3-1 el finally antiguo conserva la guarda de B', result.raceState.guardWhileBSpawns, true);
    check('C3-1 un secundario sin ids duplicados ligado a 44', result.raceState.paneSessions, ['44']);
    check('C3-1 43 no entra en sessions', result.raceState.sessions, [42, 44]);
    check('C3-1 mata solo la PTY 43 invalidada', result.raceState.kills, [43]);
    check('C3-1 cada input escribe su texto a su PTY', result.raceState.writes,
      [{ id: 42, data: 'PRIMARY_42\r\n' }, { id: 44, data: 'PANEL_44\r\n' }]);
    check('C3-1 el primer secundario envia su propio input', result.raceState.writes[1],
      { id: result.raceState.firstPaneId, data: 'PANEL_' + result.raceState.firstPaneId + '\r\n' });
    check('C3-1 solo un intervalo secundario', result.raceState.live, 1);
    checkMatch('C3-1 salida actual llega a 44', result.raceState.written, /ACTUAL_44/);
    checkNoMatch('C3-1 salida cancelada no llega a 44', result.raceState.written, /ANTIGUA_43/);
    check('C3-1 unsplit limpia todos los recursos secundarios y conserva sesiones', result.raceCleanup,
      { panes: 0, isSplit: false, live: 0, secondaryObserverCount: 0, disposed: true,
        poll: null, observer: null, xterm: null, sessions: [42, 44], kills: [43] });
    check('C3-1 invalidacion durante lectura A false B true',
      [result.readRace.oldResult, result.readRace.newResult], [false, true]);
    check('C3-1 finally antiguo no libera montaje ni lectura de B', result.readRace.guardAfterOld,
      { splitting: true, reading: true, sessions: [42] });
    check('C3-1 cada lectura se hace una sola vez', result.readRace.readIds, [43, 44]);
    check('C3-1 tras lectura solo 44 queda activa', result.readRace.sessions, [42, 44]);
    check('C3-1 tras lectura se mata 43 invalidada', result.readRace.kills, [43]);
    check('C3-1 tras lectura un solo secundario', result.readRace.panes, ['44']);
    checkMatch('C3-1 lectura nueva llega a su panel', result.readRace.written, /LECTURA_44/);
    checkNoMatch('C3-1 lectura antigua no contamina el panel nuevo', result.readRace.written, /NO_FILTRAR_43/);
    check('C3-1 vendor anterior queda dispuesto', result.readRace.oldDisposed, true);
    check('C3-1 cerrar tras lectura no deja recursos', result.readCleanup,
      { panes: 0, live: 0, secondaryObservers: 0, disposed: true, reading: false });

    check('C3-2 xterm primaria escribe exactamente a PTY 42', result.vendorWrites.filter(w => w.id === 42),
      [{ id: 42, data: 'VENDOR_INPUT_A' }]);
    check('C3-2 xterm secundaria escribe exactamente a PTY 43', result.vendorWrites.filter(w => w.id === 43),
      [{ id: 43, data: 'VENDOR_INPUT_B' }]);
    check('C3-2 solo las dos escrituras esperadas', result.vendorWrites.length, 2);
    check('C3-2 salida exacta en xterm primaria', result.vendorOutput.primary, 'VENDOR_OUTPUT_A\r\n');
    check('C3-2 salida exacta en xterm secundaria', result.vendorOutput.secondary, 'VENDOR_OUTPUT_B\r\n');
    checkNoMatch('C3-2 salida secundaria ausente en primaria', result.vendorOutput.primary, /VENDOR_OUTPUT_B/);
    checkNoMatch('C3-2 salida primaria ausente en secundaria', result.vendorOutput.secondary, /VENDOR_OUTPUT_A/);

    check('consola del navegador sin errores', errors.map(e => e.method), []);

    const failed = results.filter(r => !r.ok);
    for (const r of results) {
      console.log((r.ok ? 'ok   ' : 'FAIL ') + r.name + (r.ok ? '' : ' :: actual=' + JSON.stringify(r.actual) + ' expected=' + JSON.stringify(r.expected)));
    }
    if (failed.length) {
      console.error('FALLAN ' + failed.length + '/' + results.length + ' comprobaciones: ' + failed.map(r => r.name).join(' | '));
      process.exitCode = 1;
    } else {
      console.log('PASS ' + results.length + '/' + results.length + ' CK-CAB-005 C split C3: generaciones, transporte xterm y regresion R1/R2');
    }
  } finally {
    browser.kill();
    await new Promise(resolve => { if (browser.exitCode !== null) resolve(); else browser.once('exit', resolve); });
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
