// Sólo coordinador, cabina reconstruida, vista la sala de diseño, DEVAGENTS_CDP_PORT=9333.
// node tools/cdp_ux_cabina.mjs <carpeta-evidencia> <etiqueta> [--relevo] [--permitir-puerto]
// No crea órdenes, no cambia modelos/pines y no ejecuta sondas de proveedor.
// Sólo captura #model-picker: ningún texto ni imagen del historial exterior.
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runRelevoScenarios } from './cdp_relevo_scenarios.mjs';

const preferenceKey = 'devagents.cabin.disclosure.v1';
const argumentos = process.argv.slice(2);
const permitirPuerto = argumentos.includes('--permitir-puerto');
const [carpeta, etiqueta, mode] = argumentos.filter(a => a !== '--permitir-puerto');
const output = carpeta && etiqueta ? join(resolve(carpeta), etiqueta) : undefined;
const port = process.env.DEVAGENTS_CDP_PORT || '9333';
const pause = ms => new Promise(resolvePause => setTimeout(resolvePause, ms));
const literal = value => JSON.stringify(value);

// Puerta P1-a: la cabina de PRUEBA es 9333; otro puerto exige --permitir-puerto explícito.
export const PUERTO_PRUEBA = '9333';
export function validarPuertoPrueba(puerto, permitido = false) {
  const texto = typeof puerto === 'number' ? String(puerto) : puerto;
  if (typeof texto !== 'string' || !/^\d+$/.test(texto)) throw new Error('Puerto CDP inválido');
  const numero = Number(texto);
  if (numero < 1 || numero > 65535) throw new Error('Puerto CDP inválido');
  if (numero !== Number(PUERTO_PRUEBA) && permitido !== true) {
    throw new Error(`Puerto CDP ${numero}: sólo se admite la cabina de prueba ${PUERTO_PRUEBA}; usa --permitir-puerto de forma explícita`);
  }
  return numero;
}

// Puerta P1-a: la página CDP debe identificarse como cabina de DevAgents antes de actuar.
export function esCabinaDevAgents(identidad) {
  if (!identidad || typeof identidad !== 'object') return false;
  const titulo = typeof identidad.titulo === 'string' ? identidad.titulo : '';
  return /devagents/i.test(titulo) || identidad.marca === true;
}

// lógica pura de la secuencia esperada de flechas (orden DOM, sin envolver).
// `todos`: registros {kind:'encabezado'|'opcion', grupoAbierto:boolean} en orden DOM.
// Devuelve los objetivos de flechas: encabezados siempre, opciones sólo de grupos abiertos.
export function elementosDeFlechas(todos) {
  if (!Array.isArray(todos)) throw new TypeError('Se espera una lista ordenada del DOM');
  return todos.filter(e => e && (e.kind === 'encabezado' || (e.kind === 'opcion' && e.grupoAbierto === true)));
}

// desplazamiento sin envolver en extremos (ArrowDown/ArrowUp sobre la secuencia).
export function sinEnvolver(cantidad, actual, abajo) {
  if (!Number.isInteger(cantidad) || cantidad < 1 || !Number.isInteger(actual)) throw new TypeError('Se espera longitud entera positiva e índice entero');
  if (actual < 0 || actual >= cantidad) throw new RangeError('Índice fuera de la secuencia');
  const siguiente = abajo ? actual + 1 : actual - 1;
  return siguiente < 0 || siguiente >= cantidad ? actual : siguiente;
}

// Fábrica de sesión CDP, compartida con el modo autónomo de cdp_relevo_scenarios.mjs.
// Devuelve helpers y `errors` (contador de errores de consola/excepción de la página).
export async function conectarCabina() {
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(10000) });
  assert(response.ok, `CDP HTTP ${response.status}`);
  const page = (await response.json()).find(p => p.type === 'page' && !p.url.includes('ventana='));
  assert(page, 'Cabina principal no disponible');
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  const pending = new Map();
  const errors = [];
  let nextId = 0;
  let loadGeneration = 0;
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Page.loadEventFired') ++loadGeneration;
    // Registrar cantidad/tipo; el texto externo de consola podría contener historial.
    if (message.method === 'Runtime.exceptionThrown' ||
        (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error')) {
      errors.push({ method: message.method, timestamp: message.params.timestamp });
    }
    const request = pending.get(message.id);
    if (request) {
      clearTimeout(request.timer);
      pending.delete(message.id);
      message.error ? request.reject(new Error(JSON.stringify(message.error))) : request.resolve(message.result);
    }
  };
  await new Promise((resolveConnect, reject) => {
    const timer = setTimeout(() => reject(new Error('CDP connect timeout')), 10000);
    socket.onopen = () => { clearTimeout(timer); resolveConnect(); };
    socket.onerror = () => { clearTimeout(timer); reject(new Error('CDP connect error')); };
  });
  async function send(method, params = {}) {
    return new Promise((resolveRequest, reject) => {
      const id = ++nextId;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 20000);
      pending.set(id, { resolve: resolveRequest, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    assert(!result.exceptionDetails, 'Evaluación CDP falló; no se exporta su contenido externo');
    return result.result.value;
  }
  async function wait(expression, label, milliseconds = 20000) {
    const until = Date.now() + milliseconds;
    while (Date.now() < until) {
      if (await evaluate(expression)) return;
      await pause(100);
    }
    throw new Error(`Timeout: ${label}`);
  }
  async function click(selector) {
    await evaluate(`(() => {const el=document.querySelector(${literal(selector)});if(!el)throw Error('Control ausente');el.click();})()`);
    await pause(80);
  }
  async function key(name, virtualKey, modifiers = 0) {
    await send('Input.dispatchKeyEvent', { type: 'keyDown', key: name, code: name, windowsVirtualKeyCode: virtualKey, modifiers, ...(name === 'Enter' ? { text: '\r' } : {}) });
    await send('Input.dispatchKeyEvent', { type: 'keyUp', key: name, code: name, windowsVirtualKeyCode: virtualKey, modifiers });
    await pause(80);
  }
  await send('Runtime.enable');
  await send('Page.enable');
  // Antes de pulsar nada: verificar que el target es la cabina de DevAgents.
  const hastaIdentidad = Date.now() + 5000;
  let identidad = null;
  while (Date.now() < hastaIdentidad) {
    identidad = await evaluate(`(() => ({titulo:document.title||'',marca:!!document.querySelector('#model-picker,#btn-command-palette,#editor-monaco-host')}))()`);
    if (esCabinaDevAgents(identidad)) break;
    await pause(100);
  }
  assert(esCabinaDevAgents(identidad), `La página CDP no es la cabina de DevAgents (título: ${JSON.stringify(identidad && identidad.titulo || '')})`);
  return {
    socket, send, evaluate, wait, click, key, errors, conteoRecargas: () => loadGeneration,
    cerrar: () => { for (const request of pending.values()) clearTimeout(request.timer); socket.close(); },
  };
}

async function main() {
  console.log(`COMMAND: node tools/cdp_ux_cabina.mjs ${carpeta || ''} ${etiqueta || ''} ${mode || ''}`.trimEnd());
  assert(output && carpeta && etiqueta, 'Uso: node tools/cdp_ux_cabina.mjs <carpeta-evidencia> <etiqueta> [--relevo]');
  assert(/^\w[\w .-]*$/.test(etiqueta), 'Etiqueta con caracteres fuera de letra/dígito/espacio/punto/guion');
  assert(!mode || mode === '--relevo', 'Modo desconocido; usa --relevo');
  assert(argumentos.filter(a => a !== '--permitir-puerto').length <= 3, 'Argumentos desconocidos');
  validarPuertoPrueba(port, permitirPuerto);
  mkdirSync(resolve(carpeta), { recursive: true });
  const helpers = await conectarCabina();
  const { send, evaluate, wait, click, key, errors, conteoRecargas, cerrar } = helpers;
  const report = { captures: [], scenarios: [], uxCombos: [] };
  let saved;
  try {
    if (mode === '--relevo') {
      const relevo = await runRelevoScenarios({ send, evaluate, wait, click, key, output, report });
      assert.equal(errors.length, 0, 'Errores de consola/excepciones durante relevo');
      report.errors = errors;
      const fallidas = report.uxCombos.filter(c => c.veredicto === 'FALLA');
      if (relevo.falladas || fallidas.length) {
        report.status = 'FAIL';
        report.resumen = `editor fallas=${relevo.falladas}/${relevo.total}; combos fallidas=${fallidas.length}`;
        process.exitCode = 1;
      } else {
        report.status = 'PASS';
      }
      return;
    }
    await wait("!!document.querySelector('#btn-model-picker')", 'Sala inicial');
    saved = await evaluate(`(() => ({disclosure:localStorage.getItem(${literal(preferenceKey)}),
      search:document.querySelector('#model-search')?.value||'',
      open:document.querySelector('#model-picker')?.getClientRects().length>0,
      focusId:document.activeElement?.id||'',
      roles:['#sel-model','#sel-model-exec','#sel-model-audit'].map(s=>document.querySelector(s)?.value)}))()`);
    for (const width of [1280, 1600]) for (const scale of [1, 1.5]) {
      const label = `${width}-${scale === 1 ? '100' : '150'}`;
      const ingreso = { label, ancho: width, escala: scale, veredicto: 'PENDIENTE', totalChecks: 0, fallas: [], error: null };
      report.uxCombos.push(ingreso);
      const resultados = [];
      try {
        // Zoom con reflujo: viewport CSS reducido, DPR aumentado; el ancho físico permanece.
        await send('Emulation.setDeviceMetricsOverride', { width: Math.round(width / scale), height: Math.round(960 / scale), deviceScaleFactor: scale, mobile: false });
        await evaluate(`localStorage.setItem(${literal(preferenceKey)},'{}')`);
        await reload();
        await search('');
        const state = await checkAria();
        assert(state.every(g => g.open === (g.key === 'favorites')), 'Grupos no colapsados por defecto salvo Favoritos');
        assert.equal(await evaluate("document.querySelector('#model-advanced').open"), false, 'Avanzado no colapsado por defecto');
        await capture(`${label}-basico-colapsado`);
        await click('#model-groups-toggle');
        assert((await checkAria()).every(g => g.open), 'Expandir todo no abre todos');
        await capture(`${label}-selector-expandido`);
        // foco inicial y flechas verificados por separado; cada comprobación se
        // registra (índice, tecla, esperado, activo) y la combinación no aborta ni corta el resto.
        const controls = "[...document.querySelectorAll('#model-list summary, #model-list .model-item')]";
        const activos = `${controls}.filter(el=>el.tagName==='SUMMARY'||el.closest('details')?.open===true)`;
        const registros = await evaluate(`(() => ${controls}.map(el => {const d=el.closest('details');return {kind:el.tagName==='SUMMARY'?'encabezado':'opcion',tag:el.tagName,rol:el.getAttribute('role')||'',grupo:d?.dataset.group||'',grupoAbierto:d?.open===true,dataVal:el.dataset?.val||'',texto:(el.textContent||'').trim().slice(0,60)};}))()`);
        const secuencia = elementosDeFlechas(registros).map((e, i) => ({ ...e, posicion: i }));
        const medida = await evaluate(`${activos}.length`);
        assert.equal(medida, secuencia.length, `Divergencia DOM/secuencia pura (${medida} vs ${secuencia.length})`);
        const evaluarActivo = () => evaluate(`(() => {const a=document.activeElement;if(!a||a===document.body)return{fuera:true};const d=a.closest&&a.closest('details');return{fuera:false,tag:a.tagName||'',id:a.id||'',rol:a.getAttribute('role')||'',grupo:d?d.dataset.group||'':'',grupoAbierto:d?d.open===true:null,dataVal:(a.dataset||{}).val||'',tabIndex:a.tabIndex,texto:(a.textContent||'').trim().slice(0,60)};})()`);
        const comprobar = async (check, indice, tecla, esperado, fn) => {
          try {
            await fn();
            resultados.push({ check, indice: indice ?? null, tecla: tecla ?? null, ok: true });
          } catch (error) {
            let activo = null;
            try { activo = await evaluarActivo(); } catch (diagnostico) { activo = { diagnostico: String(diagnostico).slice(0, 120) }; }
            const fallo = String(error.message || error).replace(/\s+/g, ' ').slice(0, 200);
            resultados.push({ check, indice: indice ?? null, tecla: tecla ?? null, ok: false, esperado: esperado || null, activo, fallo });
            console.log(`CHECK ${check}: FALLA - ${fallo}`);
          }
        };
        await evaluate("document.querySelector('#model-search').focus()");
        await comprobar('foco:punto unico de Tab', null, null, { puntoUnico: true }, async () => {
          assert.equal(await evaluate(`${activos}.filter(el=>el.tabIndex===0).length`), 1, 'No hay punto de Tab en la lista expandida');
        });
        await comprobar('foco:Tab Expandir todo', null, 'Tab', { id: 'model-groups-toggle' }, async () => {
          await key('Tab', 9);
          assert.equal(await evaluate("document.activeElement.id"), 'model-groups-toggle', 'Tab desde busqueda no llega a Expandir todo');
        });
        await comprobar('foco:Tab primer encabezado', 0, 'Tab', secuencia[0] ?? null, async () => {
          await key('Tab', 9);
          assert.equal(await evaluate(`${activos}.indexOf(document.activeElement)`), 0, 'Tab no entra por el primer encabezado');
        });
        for (let i = 0; i < secuencia.length; i++) {
          const es = secuencia[i];
          await comprobar(`flecha:ArrowDown@${i}`, i, i ? 'ArrowDown' : 'llegada(sin tecla)', es, async () => {
            if (i) await key('ArrowDown', 40);
            assert.equal(await evaluate(`${activos}.indexOf(document.activeElement)`), i, 'Orden de flechas en grupos/opciones incorrecto');
          });
        }
        const ultima = secuencia.length - 1;
        await comprobar(`flecha:ArrowDown@${ultima} sin-envolver`, ultima, 'ArrowDown', secuencia[ultima] ?? null, async () => {
          await key('ArrowDown', 40);
          assert.equal(await evaluate(`${activos}.indexOf(document.activeElement)`), sinEnvolver(secuencia.length, ultima, true), 'ArrowDown en el último índice envuelve o pierde el foco');
        });
        await comprobar('foco:Tab hacia btn-external-refresh', null, 'Tab', { id: 'btn-external-refresh' }, async () => {
          await key('Tab', 9);
          assert.equal(await evaluate("document.activeElement.id"), 'btn-external-refresh', 'Tab no llega al botón de refresco');
        });
        await comprobar('foco:Shift+Tab retorno ultimo control', ultima, 'Shift+Tab', secuencia[ultima] ?? null, async () => {
          await key('Tab', 9, 8);
          assert.equal(await evaluate(`${activos}.indexOf(document.activeElement)`), ultima, 'Shift+Tab no retorna al último control enfocado');
        });
        for (let i = ultima - 1; i >= 0; i--) {
          const es = secuencia[i];
          await comprobar(`flecha:ArrowUp@${i}`, i, 'ArrowUp', es, async () => {
            await key('ArrowUp', 38);
            assert.equal(await evaluate(`${activos}.indexOf(document.activeElement)`), i, 'Orden inverso de flechas incorrecto');
          });
        }
        await comprobar('flecha:ArrowUp@0 sin-envolver', 0, 'ArrowUp', secuencia[0] ?? null, async () => {
          await key('ArrowUp', 38);
          assert.equal(await evaluate(`${activos}.indexOf(document.activeElement)`), sinEnvolver(secuencia.length, 0, false), 'ArrowUp en el primer índice envuelve o pierde el foco');
        });
        await comprobar('foco:Shift+Tab Expandir todo', null, 'Shift+Tab', { id: 'model-groups-toggle' }, async () => {
          await key('Tab', 9, 8);
          assert.equal(await evaluate("document.activeElement.id"), 'model-groups-toggle', 'Shift+Tab no retorna a Expandir todo');
        });
        await comprobar('foco:Shift+Tab busqueda', null, 'Shift+Tab', { id: 'model-search' }, async () => {
          await key('Tab', 9, 8);
          assert.equal(await evaluate("document.activeElement.id"), 'model-search', 'Shift+Tab no retorna a la búsqueda');
        });
        report.scenarios.push({ label, secuenciaEsperada: secuencia.length, rovingTabindex: true, reverseTab: true });
        await click('#model-groups-toggle');
        assert((await checkAria()).every(g => !g.open), 'Colapsar todo no cierra todos');
        assert(await evaluate(`${controls}.filter(el=>el.tagName==='BUTTON').every(el=>el.tabIndex===-1)`), 'Opciones colapsadas enfocables');
        assert.equal(await evaluate(`${controls}.filter(el=>el.tabIndex===0).length`), 1);
        const provider = (await groups()).find(g => g.key.startsWith('provider:'));
        assert(provider, 'Sin grupo proveedor para verificar persistencia');
        const summary = `#model-list details[data-group=${literal(provider.key)}] > summary`;
        await evaluate(`document.querySelector(${literal(summary)}).focus()`);
        await key('Enter', 13);
        await wait(`document.querySelector(${literal(summary)}).parentElement.open`, 'Enter abre grupo');
        await key('ArrowDown', 40);
        assert.equal(await evaluate("document.activeElement.matches('#model-list button.model-item')"), true, 'Flecha abajo no enfoca modelo');
        await key('ArrowUp', 38);
        assert.equal(await evaluate(`document.activeElement===document.querySelector(${literal(summary)})`), true, 'Flecha arriba no vuelve al grupo');
        const focus = await evaluate("(() => {const s=getComputedStyle(document.activeElement);return {visible:document.activeElement.matches(':focus-visible'),outline:s.outlineStyle,width:s.outlineWidth,shadow:s.boxShadow};})()");
        assert(focus.visible && ((focus.outline !== 'none' && parseFloat(focus.width) > 0) || focus.shadow !== 'none'), 'Foco de teclado sin indicación visible');
        await key('ArrowLeft', 37);
        assert.equal((await groups()).find(g => g.key === provider.key)?.open, false, 'Flecha izquierda no colapsa');
        await key('ArrowRight', 39);
        assert.equal((await checkAria()).find(g => g.key === provider.key)?.open, true, 'Flecha derecha no expande');
        const persisted = await evaluate(`localStorage.getItem(${literal(preferenceKey)})`);
        const query = await evaluate(`document.querySelector(${literal(summary)}).parentElement.querySelector('.model-item__name').textContent.trim()`);
        await search(query);
        assert((await checkAria()).every(g => g.open), 'Búsqueda no abre grupos con coincidencias');
        assert.equal(await evaluate(`localStorage.getItem(${literal(preferenceKey)})`), persisted, 'Búsqueda altera preferencias guardadas');
        await capture(`${label}-busqueda`);
        await search('');
        await click('#model-advanced > summary');
        await wait("document.querySelector('#model-advanced').open && document.querySelector('#model-advanced > summary').getAttribute('aria-expanded')==='true'", 'avanzado abierto accesible');
        await reload();
        assert.equal((await checkAria()).find(g => g.key === provider.key)?.open, true, 'Grupo abierto no recordado tras recargar');
        assert.equal(await evaluate("document.querySelector('#model-advanced').open"), true, 'Avanzado no recordado tras recargar');
        await capture(`${label}-recordado-avanzado`);
        await click(summary);
        await click('#model-advanced > summary');
        await reload();
        assert.equal((await checkAria()).find(g => g.key === provider.key)?.open, false, 'Grupo cerrado no recordado tras recargar');
        assert.equal(await evaluate("document.querySelector('#model-advanced').open"), false, 'Avanzado cerrado no recordado tras recargar');
        await capture(`${label}-recordado-cerrado`);
        await click('#model-advanced > summary');
        const agent = await evaluate("document.querySelector('#model-list button.model-item[data-val^=\"agent:\"]')?.dataset.val||null");
        assert(agent, 'Sin fila CLI para verificar tarjeta y botones');
        await search('');
        await evaluate(`(() => {const b=[...document.querySelectorAll('#model-list button.model-item')].find(el=>el.dataset.val===${literal(agent)});b.closest('details').open=true;b.click();})()`);
        await wait("!!document.querySelector('#external-model-detail .external-cli-detail')", 'detalle CLI montado');
        assert.equal(await evaluate("document.querySelector('.external-cli-detail').open"), false, 'Detalle CLI no compacto por defecto');
        await evaluate("document.querySelector('#external-model-detail').scrollIntoView({block:'nearest'})");
        await capture(`${label}-cli-compacta`);
        await click('#external-model-detail .external-cli-detail > summary');
        await capture(`${label}-cli-detalle`);
        await evaluate("document.querySelector('#model-search').focus()");
        await key('Escape', 27);
        assert.equal(await evaluate("document.querySelector('#model-picker').getClientRects().length"), 0, 'Escape no cierra selector');
        assert.equal(await evaluate("document.activeElement.id"), 'btn-model-picker', 'Escape no devuelve foco al botón');
        report.scenarios.push({ label, physicalWidth: width, cssViewport: Math.round(width / scale), scale, provider: provider.key, focus, persistedAfterReload: true });
      } catch (error) {
        ingreso.error = String(error).replace(/\s+/g, ' ').slice(0, 300);
      } finally {
        ingreso.totalChecks = resultados.length;
        if (ingreso.error) ingreso.veredicto = 'FALLA';
        else {
          ingreso.fallas = resultados.filter(r => !r.ok);
          ingreso.veredicto = ingreso.fallas.length ? 'FALLA' : 'OK';
        }
        console.log(`COMBO ${label}: ${ingreso.veredicto} (${ingreso.fallas.length + (ingreso.error ? 1 : 0)} fallas de ${ingreso.totalChecks} comprobaciones)`);
      }
    }
    await open();
    const roles = await evaluate("['#sel-model','#sel-model-exec','#sel-model-audit'].map(s=>document.querySelector(s)?.value)");
    assert.deepEqual(roles, saved.roles, 'Roles cambiaron durante prueba de presentación');
    report.rolesUnchanged = true;
    assert.equal(errors.length, 0, 'Errores de consola/excepciones durante la prueba');
    report.errors = errors;
    const fallidas = report.uxCombos.filter(c => c.veredicto !== 'OK');
    if (fallidas.length) {
      report.status = 'FAIL';
      report.uxFallas = fallidas.map(c => ({ label: c.label, motivo: c.error || `${c.fallas.length} de ${c.totalChecks}` }));
      console.error(`${fallidas.length} combinaciones con fallas: ${report.uxFallas.map(f => `${f.label}(${f.motivo})`).join('; ')}`);
      process.exitCode = 1;
    } else {
      report.status = 'PASS';
    }
  } catch (error) {
    report.status = 'FAIL';
    report.failure = String(error);
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    try {
      if (saved) {
        await evaluate(`(() => {const key=${literal(preferenceKey)};const value=${literal(saved.disclosure)};value===null?localStorage.removeItem(key):localStorage.setItem(key,value);})()`);
        await send('Emulation.clearDeviceMetricsOverride');
        await reload();
        await search(saved.search);
        if (!saved.open) await click('#btn-model-picker');
        if (saved.focusId) await evaluate(`document.getElementById(${literal(saved.focusId)})?.focus()`);
        assert.equal(await evaluate(`localStorage.getItem(${literal(preferenceKey)})`), saved.disclosure, 'Restauración de preferencia incompleta');
        report.restored = true;
      }
    } catch (error) {
      report.restored = false;
      report.status = 'FAIL';
      report.restorationFailure = String(error);
      console.error('Restauración falló:', error.message);
      process.exitCode = 1;
    }
    writeFileSync(`${output}.json`, JSON.stringify(report, null, 2));
    cerrar();
    console.log(`REPORT=${output}.json`);
    console.log(`EXIT_CODE=${process.exitCode || 0}`);
  }
  async function capture(label) {
    await pause(100);
    const snapshot = await evaluate(`(() => {
      const root=document.querySelector('#model-picker');const r=root.getBoundingClientRect();
      const visible=el=>el.getClientRects().length>0;
      const containers=[root,...root.querySelectorAll('.model-pop__left,.model-pop__right,.model-role-actions')].filter(visible);
      const overflow=containers.filter(el=>el.scrollWidth>el.clientWidth+1).map(el=>el.id||el.className);
      const buttons=[...root.querySelectorAll('button.btn')].filter(visible).map(el=>{
        const b=el.getBoundingClientRect();const p=el.parentElement.getBoundingClientRect();
        return {id:el.id,left:b.left,right:b.right,parentLeft:p.left,parentRight:p.right,scrollWidth:el.scrollWidth,clientWidth:el.clientWidth};
      });
      return {innerText:root.innerText,rect:{x:r.x,y:r.y,width:r.width,height:r.height},viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio},overflow,buttons};
    })()`);
    assert(snapshot.innerText.includes('Modelo y roles'), 'Captura sin texto canónico del panel');
    assert(snapshot.rect.width > 0 && snapshot.rect.height > 0, 'Panel no renderizado');
    assert(snapshot.rect.x >= -1 && snapshot.rect.y >= -1 &&
      snapshot.rect.x + snapshot.rect.width <= snapshot.viewport.width + 1 &&
      snapshot.rect.y + snapshot.rect.height <= snapshot.viewport.height + 1, 'Panel cortado fuera del viewport');
    assert.deepEqual(snapshot.overflow, [], 'Desborde horizontal real en panel');
    assert(snapshot.buttons.every(b => b.left >= b.parentLeft - 1 && b.right <= b.parentRight + 1 && b.scrollWidth <= b.clientWidth + 1), 'Botón cortado o texto desbordado');
    const png = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false,
      clip: { ...snapshot.rect, scale: 1 } });
    writeFileSync(`${output}-${label}.png`, Buffer.from(png.data, 'base64'));
    writeFileSync(`${output}-${label}-innerText.txt`, snapshot.innerText);
    report.captures.push({ label, ...snapshot, innerText: undefined });
    console.log(`CAPTURE ${label}: picker-only PNG + innerText; overflow=0; buttons=${snapshot.buttons.length}`);
  }
  async function search(value) {
    await evaluate(`(() => {const el=document.querySelector('#model-search');el.value=${literal(value)};el.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await pause(100);
  }
  async function open() {
    await wait("!!document.querySelector('#btn-model-picker')", 'Sala montada');
    const isOpen = await evaluate("document.querySelector('#model-picker')?.getClientRects().length > 0");
    if (!isOpen) await click('#btn-model-picker');
    await wait("document.querySelectorAll('#model-list .model-group').length > 0", 'catálogo disponible');
    await wait("document.querySelector('#btn-model-picker')?.getAttribute('aria-expanded') === 'true'", 'aria-expanded del panel');
  }
  async function reload() {
    const before = conteoRecargas();
    await send('Page.reload', { ignoreCache: true });
    const until = Date.now() + 20000;
    while (conteoRecargas() === before && Date.now() < until) await pause(100);
    assert(conteoRecargas() > before, 'Recarga sin evento Page.loadEventFired');
    await wait("document.readyState === 'complete' && !!document.querySelector('#btn-model-picker')", 'recarga terminada');
    await open();
  }
  async function groups() {
    return evaluate("[...document.querySelectorAll('#model-list .model-group')].map(d=>({key:d.dataset.group,open:d.open,aria:d.querySelector('summary')?.getAttribute('aria-expanded')}))");
  }
  async function checkAria() {
    assert(await evaluate(`(() => {
      const picker = document.querySelector('#model-picker');
      if (picker.getAttribute('role') !== 'group' || picker.getAttribute('aria-labelledby') !== 'model-picker-title' || !document.getElementById('model-picker-title')?.textContent.trim()) return false;
      if (!document.querySelector('#model-search').getAttribute('aria-label')) return false;
      const controls = [...picker.querySelectorAll('summary'), document.querySelector('#model-groups-toggle')];
      return controls.every(el => {
        const id = el.getAttribute('aria-controls');
        return id && document.getElementById(id) && (el.tagName !== 'SUMMARY' || el.getAttribute('aria-expanded') === String(el.parentElement.open));
      });
    })()`), 'Nombre/rol/vinculos ARIA ausentes o estado incoherente');
    const state = await groups();
    assert(state.length > 0, 'Sin grupos medidos');
    assert(state.every(g => g.aria === String(g.open)), 'aria-expanded no refleja el plegado');
    return state;
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(error => { console.error(error.message); console.log('EXIT_CODE=1'); process.exitCode = 1; });
}
