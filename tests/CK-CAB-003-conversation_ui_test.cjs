// tramo 1 — conversación continua. Arnés: Chromium real por CDP
// (mismo patrón que tests/right_cards_ui_test.cjs). Carga el MissionControlPanel
// REAL compilado como IIFE (shell/webui/build_cab003_test.mjs) con un núcleo
// simulado y comprueba el DOM:
//   (a) terminar la orden 1 y enviar la 2 NO borra los bloques de la 1;
//   (b) loadSession de una conversación con 3 órdenes pinta las 3, en orden;
//   (b2) las órdenes antiguas no piden sus eventos hasta desplegarse (cota);
//   (c) «nueva conversación» deja el hilo vacío;
//   (d) los botones de un bloque anterior no actúan sobre la orden en curso.
//   (r3) la charla se queda como burbujas y solo el trabajo se pliega como
//        bloque, tanto en vivo como al reabrir la sesión (orden mezclado).
// CAB003_BUNDLE permite apuntar a otro bundle (el compilado desde main = rojo).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const PAGE = String.raw`
window.waitFor = async (fn, ms = 8000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (fn()) return true; } catch (e) {} await new Promise(r => setTimeout(r, 25)); }
  return false;
};
window.mkCore = (cfg) => {
  const log = { dispatch: [], restore: [], eventsAsked: [], plansAsked: [], checkpoint: [], submit: [], options: [], cancel: [] };
  const base = {
    status: async () => ({ running: true, engineReady: true, keyCount: 1, initError: '' }),
    orderPreflight: async () => ({ allowed: true, issues: [], message: '' }),
    submitOrder: async (text, project, conv, options) => { const id = cfg.nextIds.shift(); log.submit.push([id, conv]); log.options.push(options); return { orderId: id }; },
    cancelOrder: async (id) => { log.cancel.push(id); return { cancelled: true }; },
    pollPlan: async () => ({ done: true, ok: true }),
    getPlan: async (id) => { log.plansAsked.push(id); if (cfg.planErrors && cfg.planErrors[id]) throw new Error('plan boom ' + id); return cfg.plans[id] || { understanding: '', tasks: [] }; },
    orderEvents: async (id, since) => { log.eventsAsked.push(id); return (cfg.events[id] || []).filter(e => e.id > (since || 0)); },
    orderStatus: async () => ({ status: 5 }),
    orderWorktree: async () => null,
    // B1d: en Directo también se toma al enviar, antes de que exista la orden.
    createCheckpoint: async () => { const id = log.submit.length ? log.submit[log.submit.length - 1][0] : cfg.nextIds[0]; log.checkpoint.push(id); return { sha: 'sha' + id + 'aaaaaaaaaaaa', untrackedCount: 0 }; },
    restoreCheckpoint: async (sha, root) => { log.restore.push(sha); return { restored: true }; },
    dispatchOrder: async (id) => { log.dispatch.push(id); return {}; },
    pollDispatch: async (id) => ({ done: cfg.holdDispatch !== id, ok: true }),
    keepAwake: async () => {},
    prs: async () => [],
    conversationMessages: async () => cfg.messages || [],
    listSessions: async () => cfg.sessions || [],
  };
  const core = new Proxy(base, { get: (t, k) => (k in t ? t[k] : async () => { throw new Error('sin stub: ' + String(k)); }) });
  return { core, log };
};
window.mount = (core) => {
  document.body.innerHTML = '<div id="host" style="width:900px;height:700px"></div>';
  const panel = new MC003.MissionControlPanel(document.getElementById('host'), core);
  return panel;
};
window.body = () => document.getElementById('mission-body');
window.priorIds = () => Array.from(document.querySelectorAll('details[data-prior-order]')).map(d => Number(d.dataset.priorOrder));
`;

module.exports = async function cab003ConversationUi() {
  const bundlePath = process.env.CAB003_BUNDLE || path.join(__dirname, '../shell/webui/dist/mission_control.cab003.test.js');
  const bundle = fs.readFileSync(bundlePath, 'utf8');
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-rel-cab003-'));
  const executable = process.env.DEVAGENTS_TEST_BROWSER || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  const html = path.join(profile, 'cab003.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session;
  const pending = new Map();
  let stderr = '';
  child.stderr.on('data', data => { stderr += data; });
  const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      const request = pending.get(message.id);
      if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 30000);
      pending.set(id, { resolve, reject, timer });
      child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error('page: ' + JSON.stringify(result.exceptionDetails.exception?.description || result.exceptionDetails));
    return result.result.value;
  }

  // Los fallos se acumulan: en el rojo se ven TODOS los criterios rotos, no solo el primero.
  const failures = [];
  const results = [];
  function check(name, ok, detail) {
    results.push([name, !!ok]);
    if (ok) console.log(`  ok: ${name}`);
    else { failures.push(name); console.error(`  FAIL: ${name}${detail === undefined ? '' : ' -> ' + (typeof detail === 'string' ? detail : JSON.stringify(detail))}`); }
  }
  const guard = async (name, fn) => {
    try { await fn(); } catch (e) { check(name + ' (sin excepción)', false, String(e.message || e).slice(0, 300)); }
  };

  try {
    const { targetId } = await send('Target.createTarget', { url: pathToFileURL(html).href }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    {
      // Esperar a que el documento pedido sustituya al about:blank inicial: con
      // solo readyState, la navegación podía llegar después y borrar el estado
      // ya montado (rojos intermitentes del 13 y 14-nov, update_ui y right_cards).
      const deadline = Date.now() + 10000;
      const ready = () => evaluate("location.href!=='about:blank' && document.readyState==='complete' && document.head!==null")
        .catch(error => { if (/context was destroyed|Cannot find context/i.test(error.message)) return false; throw error; });
      while (!await ready()) {
        if (Date.now() >= deadline) throw new Error('Timeout esperando el documento de la prueba');
        await new Promise(resolve => setTimeout(resolve, 25));
      }
    }
    await evaluate(bundle + '\nwindow.MC003 = MC003; true');
    await evaluate(PAGE + ';true');

    // Datos comunes: orden 1 = trabajo con 2 tareas, archivo y punto de control;
    // orden 2 = charla; orden 3 = otro plan con tareas.
    const dataset = `({
      nextIds: [1, 2, 3],
      plans: {
        1: { understanding: 'Entiendo: una calculadora web', tasks: [
          { id: 't1', task_type: 'code', department: 'programacion', description: 'Crear index.html', depends_on: [] },
          { id: 't2', task_type: 'code', department: 'programacion', description: 'Crear app.js', depends_on: [] } ] },
        2: { understanding: 'Respuesta de la orden dos', tasks: [] },
        3: { understanding: 'Entiendo: ajustar los estilos', tasks: [ { id: 't1', task_type: 'code', department: 'programacion', description: 'Ajustar css', depends_on: [] } ] },
      },
      events: {
        1: [
          { id: 1, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\\\work\\\\index.html', content: '<main>ok</main>' } },
          { id: 2, ts: 2, source: 'worker', kind: 'task_done', payload: { task_id: 't1', success: true, model_used: 'm1' } },
          { id: 3, ts: 3, source: 'worker', kind: 'order_done', payload: { completed: 2, failed: 0 } },
        ],
        3: [ { id: 30, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\\\work\\\\style.css', content: 'a{}' } } ],
      },
    })`;

    // ---- (a) + (c) + (d): flujo vivo de tres órdenes en la misma conversación ----
    await guard('CK-CAB-003 (a) flujo vivo', async () => {
      await evaluate(`(async () => {
        window.CFG = ${dataset};
        const m = mkCore(CFG); window.L = m.log; window.P = mount(m.core);
        await P.submit('crea una calculadora');
        await waitFor(() => !!document.querySelector('#btn-approve'));
        document.querySelector('#btn-approve').click();
        await waitFor(() => P.phase === 'done');
        return true; })()`);
      const done = await evaluate(`({ phase: P.phase, revert: document.querySelectorAll('#btn-revert').length })`);
      check('CK-CAB-003 (a) precondición: orden 1 terminada con su Punto de control', done.phase === 'done' && done.revert === 1, done);

      await evaluate(`(async () => { await P.submit('segunda pregunta'); await waitFor(() => P.phase === 'chat'); return true; })()`);
      const a = await evaluate(`(() => {
        const d = document.querySelector('details[data-prior-order="1"]');
        return {
          phase: P.phase,
          blocks: priorIds(),
          open: d ? d.open : null,
          summary: d ? d.querySelector('summary').textContent.replace(/\\s+/g, ' ').trim() : '',
          title: d ? d.title : '',
          text: d ? d.textContent : '',
          hasRevert: !!document.querySelector('details[data-prior-order="1"] [data-prior-revert="1"]'),
          bodyText: body().textContent,
          liveUser: Array.from(document.querySelectorAll('#mission-body > div > .chat-thread .chat-bubble')).map(b => b.textContent.trim()),
        };
      })()`);
      check('CK-CAB-003 (a) el bloque de la orden 1 sigue en el DOM tras enviar la 2', a.blocks.includes(1), a.blocks);
      check('CK-CAB-003 (a) el bloque está plegado automáticamente', a.open === false, a.open);
      // USUARIO-NUEVO A7 (10-nov, decisión del propietario): el grupo plegado dice lo
      // que hizo el agente («Escribió 1 archivo · ejecutó 1 tarea»), no «Orden
      // #1 · Hecha · 2 tareas»; el número de orden queda en el `title` y dentro.
      check('CK-CAB-003 (a) línea de resumen con lo que hizo y el número de orden en el title', /^Escribió 1 archivo · ejecutó 1 tarea/.test(a.summary) && a.title === 'Orden #1' && a.text.includes('Orden #1'), { summary: a.summary, title: a.title });
      // A7: el mensaje del usuario queda FUERA del grupo, en el hilo, antes de él.
      check('CK-CAB-003 (a) conserva mensaje (en el hilo), Entendimiento, Plan, Actividad y Punto de control (en el grupo)',
        a.bodyText.indexOf('crea una calculadora') >= 0 && a.bodyText.indexOf('crea una calculadora') < a.bodyText.indexOf('Orden #1') && !a.text.includes('crea una calculadora') &&
        ['Entendimiento', 'Entiendo: una calculadora web', 'Plan propuesto · 2 tareas', 'index.html', 'Punto de control', 'Revertir los archivos'].every(t => a.text.includes(t)), a.text.slice(0, 400));
      check('CK-CAB-003 (a) Revertir de la orden 1 sigue ofreciéndose', a.hasRevert, a.hasRevert);
      check('CK-CAB-003 (a) la orden nueva aparece debajo (mensaje y respuesta en el hilo vivo)', a.bodyText.indexOf('segunda pregunta') > a.bodyText.indexOf('Orden #1') && a.bodyText.includes('Respuesta de la orden dos'), a.bodyText.slice(0, 300));
      check('CK-CAB-003 (a) las cadenas de la orden 1 no cuelgan de ids de la orden viva', (await evaluate(`document.querySelectorAll('details[data-prior-order] [id]').length`)) === 0);

      // r2 P1: cancelar la confirmación deja intacto el punto de control.
      await evaluate(`document.querySelector('[data-prior-revert="1"]').click(); true`);
      const confirmation = await evaluate(`(() => {
        const d = document.querySelector('[role="dialog"]');
        const out = { text: d?.textContent || '', restores: L.restore.length };
        d?.querySelector('button').click();
        return out;
      })()`);
      check('CK-CAB-003 r2 P1 confirmar nombra orden y hash antes de restaurar', confirmation.text.includes('orden #1') && confirmation.text.includes('sha1aaaaaaaaaaaa') && confirmation.restores === 0, confirmation);
      check('CK-CAB-003 r2 P1 cancelar no restaura ni consume el punto de control', (await evaluate(`L.restore.length === 0 && !!document.querySelector('[data-prior-revert="1"]')`)));
      // El rojo anterior restaura sin preguntar; se repone el dato del fixture para
      // que los demás casos reproduzcan fallos independientes en la misma corrida.
      await evaluate(`L.restore.length = 0; P.priorOrders[0].checkpointMsg = ''; P.renderBody(); true`);

      // Una confirmación abierta también se invalida si empieza otra orden.
      await evaluate(`document.querySelector('[data-prior-revert="1"]').click(); true`);
      // (d) tercera orden: observar planificación real antes de que resuelva el plan.
      await evaluate(`window.nextSubmit = P.submit('ajusta los estilos'); true`);
      await evaluate(`waitFor(() => P.phase === 'planning')`);
      await evaluate(`document.querySelector('[role="dialog"] button:last-child')?.click(); true`);
      check('CK-CAB-003 r2 P1 vuelve a comprobar orden activa después de confirmar', await evaluate(`L.restore.length === 0`));
      await evaluate(`L.restore.length = 0; P.priorOrders[0].checkpointMsg = ''; P.renderBody(); true`);
      const planning = await evaluate(`(() => {
        const b = document.querySelector('[data-prior-revert="1"]');
        b?.click();
        return { phase: P.phase, disabled: b?.disabled, title: b?.title, restores: L.restore.length, dialog: !!document.querySelector('[role="dialog"]') };
      })()`);
      check('CK-CAB-003 r2 P1 restauración bloqueada y explicada mientras planifica', planning.phase === 'planning' && planning.disabled && /orden.*activa/i.test(planning.title) && planning.restores === 0 && !planning.dialog, planning);
      await evaluate(`L.restore.length = 0; P.priorOrders[0].checkpointMsg = ''; true`);
      await evaluate(`(async () => { await nextSubmit; await waitFor(() => !!document.querySelector('#btn-approve')); return true; })()`);
      const d = await evaluate(`(() => ({
        approveButtons: document.querySelectorAll('#btn-approve').length,
        approveInsidePrior: document.querySelectorAll('details[data-prior-order] #btn-approve').length,
        priorHasApproveText: Array.from(document.querySelectorAll('details[data-prior-order] button')).filter(b => /aprobar|ejecutar|cancelar|detener|aclar/i.test(b.textContent)).length,
        blocks: priorIds(),
      }))()`);
      check('CK-CAB-003 (d) un único botón Aprobar y ejecutar, el de la orden en curso', d.approveButtons === 1 && d.approveInsidePrior === 0, d);
      check('CK-CAB-003 (d) ningún bloque anterior ofrece aprobar, ejecutar ni cancelar', d.priorHasApproveText === 0, d);
      check('CK-CAB-003 r3 las órdenes 1 (trabajo) sigue como bloque y la 2 (charla) no', d.blocks.includes(1) && !d.blocks.includes(2), d.blocks);
      check('CK-CAB-003 r3 la charla viva archivada queda como burbujas visibles, sin bloque', await evaluate(`(() => {
        const visible = Array.from(document.querySelectorAll('.chat-bubble')).filter(b => !b.closest('details[data-prior-order]')).map(b => b.textContent.trim());
        return !document.querySelector('details[data-prior-order="2"]') && visible.includes('segunda pregunta') && visible.includes('Respuesta de la orden dos');
      })()`));

      await guard('CK-CAB-003 (d) botones de bloques anteriores', async () => {
      await evaluate(`(async () => {
        document.querySelector('details[data-prior-order="1"]').open = true;
        await new Promise(r => setTimeout(r, 50));
        document.querySelector('[data-prior-revert="1"]').click();
        return true; })()`);
      const rev = await evaluate(`({ restore: L.restore, dispatch: L.dispatch, msg: document.querySelector('details[data-prior-order="1"]').textContent.includes('Archivos restaurados') })`);
      check('CK-CAB-003 r2 P1 esperando aprobación: Revertir anterior deshabilitado sin restaurar', rev.restore.length === 0 && await evaluate(`document.querySelector('[data-prior-revert="1"]').disabled`), rev);
      check('CK-CAB-003 (d) tocar el bloque anterior no aprueba ni despacha la orden en curso', rev.dispatch.length === 1 && rev.dispatch[0] === 1, rev.dispatch);
      await evaluate(`L.restore.length = 0; P.priorOrders[0].checkpointMsg = ''; CFG.holdDispatch = 3; true`);
      await evaluate(`(async () => { document.querySelector('#btn-approve').click(); await waitFor(() => L.dispatch.length === 2); return true; })()`);
      const ap = await evaluate(`({ dispatch: L.dispatch, restore: L.restore })`);
      check('CK-CAB-003 (d) Aprobar de la orden en curso despacha la orden 3 y no la 1', ap.dispatch[1] === 3 && ap.dispatch.filter(x => x === 1).length === 1 && ap.restore.length === 0, ap);
      const running = await evaluate(`(async () => {
        const b = document.querySelector('[data-prior-revert="1"]');
        b?.click();
        // También se prueba la defensa del manejador, evitando depender solo de disabled.
        await P.revertPrior(1);
        return { phase: P.phase, disabled: b?.disabled, title: b?.title, restores: L.restore.length, dialog: !!document.querySelector('[role="dialog"]') };
      })()`);
      check('CK-CAB-003 r2 P1 orden nueva EJECUTANDO bloquea clic y manejador de restauración', running.phase === 'running' && running.disabled && /orden.*activa/i.test(running.title) && running.restores === 0 && !running.dialog, running);
      await evaluate(`(async () => { L.restore.length = 0; P.priorOrders[0].checkpointMsg = ''; CFG.holdDispatch = 0; await waitFor(() => P.phase === 'done'); return true; })()`);
      // Ahora sí se permite restaurar, después de aceptar la confirmación real.
      await evaluate(`document.querySelector('[data-prior-revert="1"]').click(); true`);
      const accepted = await evaluate(`(() => {
        const d = document.querySelector('[role="dialog"]');
        const out = { text: d?.textContent || '', restores: L.restore.length };
        d?.querySelector('button:last-child').click();
        return out;
      })()`);
      await evaluate(`waitFor(() => L.restore.length === 1)`);
      check('CK-CAB-003 r2 P1 aceptar restaura SU hash y no el de la orden en curso', accepted.restores === 0 && accepted.text.includes('sha1aaaaaaaaaaaa') && await evaluate(`L.restore.length === 1 && L.restore[0] === 'sha1aaaaaaaaaaaa' && L.dispatch.join(',') === '1,3'`), accepted);
      });

      // (c) nueva conversación
      await evaluate(`(async () => { await waitFor(() => P.phase === 'done'); P.newConversation(); return true; })()`);
      const c = await evaluate(`({ phase: P.phase, blocks: priorIds(), bubbles: document.querySelectorAll('.chat-bubble').length, text: body().textContent })`);
      check('CK-CAB-003 (c) nueva conversación: hilo vacío (sin bloques ni burbujas)', c.blocks.length === 0 && c.bubbles === 0 && !c.text.includes('crea una calculadora') && c.phase === 'idle', c);
    });

    // Integración VER1-002 + CAB-003: modo Plan, charla, historial y Cancelar
    // se ejercitan en la misma instancia mediante los controles reales.
    await guard('integración Plan y conversación continua', async () => {
      await evaluate(`(async () => {
        const task = { id: 't', task_type: 'code', department: 'programacion', description: 'trabajo combinado', depends_on: [] };
        const m = mkCore({ nextIds: [71, 72, 73], events: {}, plans: {
          71: { wait_for_plan_approval: true, understanding: 'primer trabajo', tasks: [task] },
          72: { understanding: 'respuesta intermedia combinada', tasks: [] },
          73: { wait_for_plan_approval: true, understanding: 'plan para cancelar', tasks: [task] },
        } });
        window.LI = m.log; window.PI = mount(m.core);
        const toggle = document.querySelector('#wait-plan-approval');
        toggle.checked = true; toggle.dispatchEvent(new Event('change', { bubbles: true }));
        await PI.submit('primer trabajo combinado');
        await waitFor(() => !!document.querySelector('#btn-approve'));
        return true;
      })()`);
      check('integración: Plan viaja al motor y espera sin despachar', await evaluate(`LI.options[0].waitForPlanApproval === true && LI.dispatch.length === 0 && body().textContent.includes('esperando tu aprobación')`));
      await evaluate(`(async () => {
        document.querySelector('#btn-approve').click(); await waitFor(() => PI.phase === 'done');
        await PI.submit('charla intermedia combinada'); await waitFor(() => PI.phase === 'chat');
        await PI.submit('segundo trabajo combinado'); await waitFor(() => PI.phase === 'awaiting-approval');
        return true;
      })()`);
      check('integración: trabajo previo plegado, charla visible y plan actual pendiente', await evaluate(`
        document.querySelector('details[data-prior-order="71"]')?.open === false &&
        !document.querySelector('details[data-prior-order="72"]') &&
        body().textContent.includes('respuesta intermedia combinada') &&
        LI.submit.every(row => row[1] === LI.submit[0][1]) &&
        LI.options[2].waitForPlanApproval === true && LI.dispatch.join(',') === '71'
      `));
      await evaluate(`PI.revertPrior(71); true`);
      check('integración: Revertir anterior bloqueado mientras espera el plan', await evaluate(`document.querySelector('[data-prior-revert="71"]').disabled && LI.restore.length === 0 && !document.querySelector('[role="dialog"]')`));
      await evaluate(`(async () => { document.querySelector('#btn-discard').click(); await waitFor(() => LI.cancel.includes(73) && PI.orderId === 0); return true; })()`);
      check('integración: Cancelar llega al motor sin ejecutar y conserva conversación', await evaluate(`
        LI.cancel.join(',') === '73' && LI.dispatch.join(',') === '71' &&
        !!document.querySelector('details[data-prior-order="71"]') &&
        !document.querySelector('details[data-prior-order="73"]') &&
        body().textContent.includes('charla intermedia combinada') &&
        body().textContent.includes('segundo trabajo combinado')
      `));
      await evaluate(`document.querySelector('[data-prior-revert="71"]').click(); true`);
      check('integración: Revertir vuelve a pedir confirmación tras cancelar', await evaluate(`document.querySelector('[role="dialog"]')?.textContent.includes('orden #71') && LI.restore.length === 0`));
      await evaluate(`document.querySelector('[role="dialog"] button')?.click(); localStorage.removeItem('devagents.waitPlanApproval.v1'); true`);
    });

    // ---- (b) y (b2): reabrir una sesión con varias órdenes ----
    await guard('CK-CAB-003 (b) loadSession', async () => {
      const load = `({
        sessions: [
          { id: 99, status_text: 'done', created_at: 900, conversation_id: 'conv-otra' },
          { id: 15, status_text: 'done', created_at: 105, conversation_id: 'conv-A' },
          { id: 14, status_text: 'failed', created_at: 104, conversation_id: 'conv-A' },
          { id: 13, status_text: 'done', created_at: 103, conversation_id: 'conv-A' },
          { id: 12, status_text: 'done', created_at: 102, conversation_id: 'conv-A' },
          { id: 11, status_text: 'done', created_at: 101, conversation_id: 'conv-A' },
          { id: 10, status_text: 'done', created_at: 100, conversation_id: 'conv-A' },
        ],
        messages: [10, 11, 12, 13, 14, 15].flatMap(n => [
          { order_id: n, role: 'user', content: 'pedido de la orden ' + n },
          { order_id: n, role: 'assistant', content: 'respuesta de la orden ' + n } ]),
        plans: Object.fromEntries([10, 11, 12, 13, 14, 15].map(n => [n, { understanding: 'Entendimiento ' + n, tasks: [ { id: 't', task_type: 'code', department: 'programacion', description: 'tarea ' + n, depends_on: [] } ] }])),
        events: Object.fromEntries([10, 11, 12, 13, 14, 15].map(n => [n, [ { id: n * 10, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\\\w\\\\f' + n + '.txt', content: 'x' } } ]])),
        nextIds: [],
      })`;
      await evaluate(`(async () => {
        const m = mkCore(${load}); window.L2 = m.log; window.P2 = mount(m.core);
        await P2.loadSession(12, 'conv-A');
        return true; })()`);
      const b = await evaluate(`(() => ({
        blocks: priorIds(),
        opens: Array.from(document.querySelectorAll('details[data-prior-order]')).map(d => d.open),
        order: ['pedido de la orden 10', 'pedido de la orden 11', 'pedido de la orden 12', 'pedido de la orden 13', 'pedido de la orden 14', 'pedido de la orden 15'].map(t => body().textContent.indexOf(t)),
        activeOrder: P2.orderId,
        live: !!document.querySelector('#turn-activity') || body().textContent.includes('Entendimiento 15'),
        summary: Array.from(document.querySelectorAll('details[data-prior-order] summary')).map(s => s.textContent.replace(/\\s+/g, ' ').trim()),
        failed14: (() => { const d = document.querySelector('details[data-prior-order="14"]'); return d ? { title: d.title, summary: d.querySelector('summary').textContent.replace(/\\s+/g, ' ').trim() } : null; })(),
      }))()`);
      check('CK-CAB-003 (b) abrir una sesión pinta todas las órdenes del hilo, en orden (5 bloques anteriores)', JSON.stringify(b.blocks) === '[10,11,12,13,14]', b.blocks);
      check('CK-CAB-003 (b) las anteriores plegadas', b.opens.every(o => o === false), b.opens);
      check('CK-CAB-003 (b) la última orden (la 15) es la activa y está desplegada', b.activeOrder === 15 && b.live, { active: b.activeOrder, live: b.live });
      check('CK-CAB-003 (b) mensajes de las 6 órdenes presentes y en orden cronológico', b.order.every((x, i) => x >= 0 && (i === 0 || x > b.order[i - 1])), b.order);
      check('CK-CAB-003 (b) no incluye órdenes de otra conversación', !(await evaluate(`body().textContent.includes('orden 99') || P2.priorOrders.some(p => p.orderId === 99)`)));
      // A7 (10-nov): el estado distinto de «Hecha» va como insignia en la línea
      // del grupo; el número, en el title.
      check('CK-CAB-003 (b) la orden fallida lleva su estado en el resumen', !!b.failed14 && /Fallida/.test(b.failed14.summary) && b.failed14.title === 'Orden #14' && !b.summary.some((s, i) => i !== 4 && /Fallida/.test(s)), { failed14: b.failed14, summary: b.summary });

      // (b2) cota: con 6 órdenes y PRIOR_EVENTS_KEEP=3 las más antiguas no piden eventos hasta desplegarse
      const asked = await evaluate(`Array.from(new Set(L2.eventsAsked))`);
      check('CK-CAB-003 (b2) los eventos de las órdenes antiguas (10 y 11) NO se cargan de golpe', !asked.includes(10) && !asked.includes(11), asked);
      check('CK-CAB-003 (b2) sí se cargan los de las más recientes (12, 13, 14) y la activa (15)', [12, 13, 14, 15].every(n => asked.includes(n)), asked);
      await evaluate(`(async () => { document.querySelector('details[data-prior-order="10"]').open = true; await waitFor(() => L2.eventsAsked.includes(10)); await waitFor(() => document.querySelector('details[data-prior-order="10"]').textContent.includes('f10.txt')); return true; })()`);
      const lazy = await evaluate(`({ asked: L2.eventsAsked.includes(10), shown: document.querySelector('details[data-prior-order="10"]').textContent.includes('f10.txt'), open: document.querySelector('details[data-prior-order="10"]').open })`);
      check('CK-CAB-003 (b2) al desplegar la orden 10 se piden sus eventos, se pinta su actividad y sigue abierta', lazy.asked && lazy.shown && lazy.open, lazy);

      // sesión legacy / núcleo sin listSessions: se abre solo la orden pedida
      await evaluate(`(async () => {
        const m = mkCore({ messages: [ { order_id: 5, role: 'user', content: 'solo esta' } ], plans: {}, events: {}, sessions: [], nextIds: [] });
        window.P3 = mount(m.core); await P3.loadSession(5); return true; })()`);
      const legacy = await evaluate(`({ blocks: priorIds(), text: body().textContent.includes('solo esta') })`);
      check('CK-CAB-003 (b) sesión sin conversation_id: se abre sola, sin bloques anteriores', legacy.blocks.length === 0 && legacy.text, legacy);
    });

    // ---- r3: charla → charla → trabajo → charla, en vivo ----
    await guard('CK-CAB-003 r3 flujo vivo charla-charla-trabajo-charla', async () => {
      await evaluate(`(async () => {
        const m = mkCore({
          nextIds: [40, 41, 42, 43],
          plans: {
            40: { understanding: 'respuesta uno', tasks: [] },
            41: { understanding: 'respuesta dos', tasks: [] },
            42: { understanding: 'Entendimiento trabajo', tasks: [ { id: 't', task_type: 'code', department: 'programacion', description: 'trabajo r3', depends_on: [] } ] },
            43: { understanding: 'respuesta final', tasks: [] },
          },
          events: { 42: [ { id: 420, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\\\w\\\\r3.txt', content: 'x' } } ] },
          sessions: [40, 41, 42, 43].map(id => ({ id, status_text: 'done', created_at: id, conversation_id: 'conv-r3' })),
          messages: [40, 41, 42, 43].flatMap(order_id => [
            { order_id, role: 'user', content: 'pregunta ' + order_id },
            { order_id, role: 'assistant', content: 'respuesta ' + order_id },
          ]),
        });
        window.LR3 = m.log; window.PR3 = mount(m.core);
        await PR3.submit('hola uno'); await waitFor(() => PR3.phase === 'chat');
        await PR3.submit('hola dos'); await waitFor(() => PR3.phase === 'chat');
        await PR3.submit('haz el trabajo'); await waitFor(() => !!document.querySelector('#btn-approve'));
        document.querySelector('#btn-approve').click();
        await waitFor(() => PR3.phase === 'done');
        await PR3.submit('charla final'); await waitFor(() => PR3.phase === 'chat');
        return true; })()`);
      const live = await evaluate(`(() => {
        const d = document.querySelector('details[data-prior-order="42"]');
        const visible = Array.from(document.querySelectorAll('.chat-bubble')).filter(b => !b.closest('details[data-prior-order]')).map(b => b.textContent.trim());
        const text = body().textContent;
        return {
          blocks: priorIds(),
          summary: d ? d.querySelector('summary').textContent.replace(/\\s+/g, ' ').trim() : '',
          title: d ? d.title : '',
          open: d ? d.open : null,
          visible,
          chatBlocks: [40, 41, 43].filter(n => !!document.querySelector('details[data-prior-order="' + n + '"]')),
          order: ['hola uno', 'hola dos', 'Orden #42', 'charla final'].map(t => text.indexOf(t)),
        };
      })()`);
      check('CK-CAB-003 r3 en vivo: solo la orden con tareas se pliega (bloque 42)', JSON.stringify(live.blocks) === '[42]' && live.chatBlocks.length === 0, live);
      // A7 (10-nov): resumen de lo hecho; el número de orden, en el title.
      check('CK-CAB-003 r3 en vivo: el bloque de trabajo está plegado con su resumen', live.open === false && live.summary.startsWith('Escribió 1 archivo') && live.title === 'Orden #42', live);
      check('CK-CAB-003 r3 en vivo: las dos charlas y la final son burbujas siempre visibles', ['hola uno', 'respuesta uno', 'hola dos', 'respuesta dos', 'charla final', 'respuesta final'].every(t => live.visible.includes(t)), live.visible);
      check('CK-CAB-003 r3 en vivo: orden cronológico burbujas → bloque → orden nueva', live.order.every((x, i) => x >= 0 && (i === 0 || x > live.order[i - 1])), live.order);
      const reloaded = await evaluate(`(async () => { await PR3.loadSession(42, 'conv-r3'); return true; })()`);
      check('CK-CAB-003 r3 en vivo: reabrir la sesión reproduce burbujas + bloque en orden', reloaded && await evaluate(`(() => {
        const d = document.querySelector('details[data-prior-order="42"]');
        const visible = Array.from(document.querySelectorAll('.chat-bubble')).filter(b => !b.closest('details[data-prior-order]')).map(b => b.textContent.trim());
        return !!d && !d.open && JSON.stringify(priorIds()) === '[42]' && visible.includes('pregunta 40') && visible.includes('pregunta 41') && visible.includes('pregunta 43');
      })()`));
    });

    // ---- B1 (tarea 4): la línea de hechos del motor va aparte del texto del modelo ----
    await guard('B1 tarea 4 línea de archivos cambiados bajo la respuesta', async () => {
      await evaluate(`(async () => {
        const m = mkCore({
          nextIds: [60, 61],
          plans: {
            60: { understanding: 'He creado saludo.py.\\n\\n[DevAgents] Archivos cambiados: saludo.py.', tasks: [] },
            61: { understanding: 'He creado el archivo hola.py.\\n\\n[DevAgents] Esta vuelta no escribió ningún archivo.', tasks: [] },
          },
          events: {}, sessions: [], messages: [],
        });
        window.PB1 = mount(m.core);
        await PB1.submit('crea saludo.py'); await waitFor(() => PB1.phase === 'chat');
        await PB1.submit('crea hola.py'); await waitFor(() => PB1.phase === 'chat' && document.querySelectorAll('.chat-facts').length >= 2);
        return true; })()`);
      const facts = await evaluate(`(() => Array.from(document.querySelectorAll('.chat-turn--assistant .chat-bubble')).filter(b => b.querySelector('.chat-facts')).map(b => {
        const f = b.querySelector('.chat-facts');
        const clone = b.cloneNode(true); clone.querySelector('.chat-facts').remove();
        return { said: clone.textContent.trim(), facts: f.textContent.replace(/\\s+/g, ' ').trim(), warn: f.classList.contains('chat-facts--warn') };
      }))()`);
      check('B1 tarea 4: «Archivos cambiados» va en su propia línea del sistema', facts.some(f => f.said === 'He creado saludo.py.' && f.facts === 'DevAgents Archivos cambiados: saludo.py.' && !f.warn), facts);
      check('B1 tarea 4: afirmar archivos sin escribirlos muestra el aviso del sistema', facts.some(f => f.said === 'He creado el archivo hola.py.' && f.facts === 'DevAgents Esta vuelta no escribió ningún archivo.' && f.warn), facts);
      check('B1 tarea 4: la marca interna no se ve en el texto del modelo', facts.every(f => !f.said.includes('[DevAgents]')), facts);
    });

    // ---- B1d (tarea 4, 11-nov): punto de control por vuelta en Directo ----
    await guard('B1 tarea 4 B1d Revertir por vuelta en Directo', async () => {
      await evaluate(`(async () => {
        try { localStorage.setItem('devagents.workmode.v1', 'directo'); } catch (e) {}
        const wrote = (said, files) => said + '\\n\\n[DevAgents] Archivos cambiados: ' + files + '.';
        const fw = (id, p) => ({ id, ts: 1, source: 'directo', kind: 'file_written', payload: { file_path: 'C:\\\\w\\\\' + p, content: 'x' } });
        window.CFGD = {
          nextIds: [80, 81, 82],
          plans: {
            80: { understanding: wrote('He creado saludo.txt y cambiado app.py.', 'saludo.txt, app.py'), tasks: [] },
            81: { understanding: 'Hola, ¿en qué te ayudo?', tasks: [] },
            82: { understanding: wrote('He creado b.txt.', 'b.txt'), tasks: [] },
          },
          events: { 80: [fw(800, 'saludo.txt'), fw(801, 'app.py')], 82: [fw(820, 'b.txt')] },
          sessions: [], messages: [],
        };
        const m = mkCore(CFGD); window.LD = m.log; LD.seq = []; LD.changed = 0;
        const submitOrder = m.core.submitOrder;
        m.core.createCheckpoint = async () => { const id = CFGD.nextIds[0]; LD.seq.push('checkpoint ' + id); return { sha: 'sha' + id + 'bbbbbbbbbbbb', root: 'C:\\\\w', untrackedCount: 0 }; };
        m.core.submitOrder = async (...a) => { LD.seq.push('submit ' + CFGD.nextIds[0]); return submitOrder(...a); };
        m.core.restoreCheckpoint = async (sha) => { LD.restore.push(sha); return { restored: 2, deleted: 1, removedDirs: 0, notDeleted: [] }; };
        document.addEventListener('devagents:workspace-changed', () => { LD.changed++; });
        window.PD = mount(m.core);
        await PD.submit('crea saludo.txt y cambia app.py'); await waitFor(() => PD.phase === 'chat');
        return true; })()`);
      const first = await evaluate(`({
        seq: LD.seq.slice(),
        rows: document.querySelectorAll('.turn-checkpoint').length,
        revertInRow: !!document.querySelector('.turn-checkpoint #btn-revert'),
        bigCard: Array.from(document.querySelectorAll('.card .card__title')).some(t => t.textContent.trim() === 'Punto de control'),
        afterReply: (() => { const r = document.querySelector('.turn-checkpoint'); const b = Array.from(document.querySelectorAll('.chat-turn--assistant')).pop(); return !!(r && b && (b.compareDocumentPosition(r) & Node.DOCUMENT_POSITION_FOLLOWING)); })(),
      })`);
      check('B1 tarea 4 B1d: en Directo el punto de control se toma ANTES de enviar', JSON.stringify(first.seq) === '["checkpoint 80","submit 80"]', first.seq);
      check('B1 tarea 4 B1d: Directo con escrituras muestra «Revertir los archivos», compacto bajo la respuesta', first.rows === 1 && first.revertInRow && !first.bigCard && first.afterReply, first);

      await evaluate(`(async () => { await PD.submit('Hola'); await waitFor(() => PD.phase === 'chat' && LD.submit.length === 2); return true; })()`);
      const hola = await evaluate(`(() => {
        const rows = Array.from(document.querySelectorAll('.turn-checkpoint'));
        return {
          current: !!document.querySelector('#btn-revert'),
          prior80: !!document.querySelector('.turn-checkpoint [data-prior-revert="80"]'),
          prior80Outside: !!document.querySelector('[data-prior-revert="80"]') && !document.querySelector('details [data-prior-revert="80"]'),
          rows: rows.length,
          noCheckpointText: body().textContent.includes('Sin punto de control'),
        };
      })()`);
      check('B1 tarea 4 B1d: una vuelta sin escrituras («Hola») no muestra Revertir', !hola.current && hola.rows === 1 && !hola.noCheckpointText, hola);
      check('B1 tarea 4 B1d: la vuelta anterior conserva SU Revertir, fuera del grupo plegado', hola.prior80 && hola.prior80Outside, hola);

      await evaluate(`(async () => { await PD.submit('crea b.txt'); await waitFor(() => PD.phase === 'chat' && LD.submit.length === 3); return true; })()`);
      const third = await evaluate(`({
        current: !!document.querySelector('.turn-checkpoint #btn-revert'),
        prior80: !!document.querySelector('[data-prior-revert="80"]'),
        prior81: !!document.querySelector('[data-prior-revert="81"]'),
        kinds: PD.priorOrders.map(p => p.orderId + ':' + p.kind + ':' + (p.checkpoint ? p.checkpoint.sha : '-')),
      })`);
      check('B1 tarea 4 B1d: tras otra vuelta con escrituras, las dos vueltas que escribieron tienen su Revertir y el «Hola» no', third.current && third.prior80 && !third.prior81, third);
      check('B1 tarea 4 B1d: el «Hola» sigue siendo charla, sin punto de control', third.kinds.includes('81:chat:-') && third.kinds.includes('80:work:sha80bbbbbbbbbbbb'), third.kinds);

      // Revertir una vuelta ANTERIOR: confirmación que lo dice, su hash y cifras.
      await evaluate(`document.querySelector('[data-prior-revert="80"]').click(); true`);
      const dlg = await evaluate(`(async () => { await waitFor(() => !!document.querySelector('[role="dialog"]')); const d = document.querySelector('[role="dialog"]'); const out = { text: d.textContent, restores: LD.restore.length }; d.querySelector('button:last-child').click(); return out; })()`);
      check('B1 tarea 4 B1d: la confirmación de una vuelta anterior dice que vuelve a antes de ESA vuelta', dlg.restores === 0 && dlg.text.includes('sha80bbbbbbbbbbbb') && dlg.text.includes('antes de ESA vuelta') && dlg.text.includes('crea saludo.txt y cambia app.py'), dlg.text);
      await evaluate(`waitFor(() => LD.restore.length === 1 && body().textContent.includes('2 restaurados, 1 borrado.'))`);
      const after = await evaluate(`({ restore: LD.restore.slice(), changed: LD.changed, msg: Array.from(document.querySelectorAll('.turn-checkpoint')).map(r => r.textContent.replace(/\\s+/g, ' ').trim()) })`);
      check('B1 tarea 4 B1d: revertir la vuelta anterior restaura SU punto de control y da cifras', after.restore[0] === 'sha80bbbbbbbbbbbb' && after.msg.some(t => t.includes('2 restaurados, 1 borrado.')), after);
      check('B1 tarea 4 B1d: tras revertir se avisa para que «Cambios» relea el proyecto', after.changed === 1, after.changed);

      // Revertir la vuelta EN CURSO: también confirma y usa su hash.
      await evaluate(`document.querySelector('#btn-revert').click(); true`);
      await evaluate(`(async () => { await waitFor(() => !!document.querySelector('[role="dialog"]')); document.querySelector('[role="dialog"] button:last-child').click(); await waitFor(() => LD.restore.length === 2); return true; })()`);
      const cur = await evaluate(`({ restore: LD.restore.slice(), changed: LD.changed, text: body().textContent })`);
      check('B1 tarea 4 B1d: revertir la vuelta en curso usa su hash y muestra las cifras', cur.restore[1] === 'sha82bbbbbbbbbbbb' && cur.changed === 2 && (cur.text.match(/2 restaurados, 1 borrado./g) || []).length === 2, cur.restore);
      await evaluate(`PD.newConversation(); true`);
    });

    await guard('B1 tarea 4 B1d sin git', async () => {
      await evaluate(`(async () => {
        try { localStorage.setItem('devagents.workmode.v1', 'directo'); } catch (e) {}
        const m = mkCore({
          nextIds: [90, 91],
          plans: {
            90: { understanding: 'Hola, ¿en qué te ayudo?', tasks: [] },
            91: { understanding: 'He creado c.txt.\\n\\n[DevAgents] Archivos cambiados: c.txt.', tasks: [] },
          },
          events: {}, sessions: [], messages: [],
        });
        window.LG = m.log;
        m.core.createCheckpoint = async () => { LG.checkpoint.push(1); throw new Error('El punto de control necesita que la carpeta de trabajo sea un repositorio git. fatal: not a git repository'); };
        window.PG = mount(m.core);
        await PG.submit('Hola'); await waitFor(() => PG.phase === 'chat');
        return true; })()`);
      const noGit = await evaluate(`({ submitted: LG.submit.length, tried: LG.checkpoint.length, rows: document.querySelectorAll('.turn-checkpoint').length, cards: Array.from(document.querySelectorAll('#mission-body .card')).filter(c => /punto de control|repositorio/i.test(c.textContent)).length, text: /punto de control|Iniciar git/i.test(body().textContent) })`);
      check('B1 tarea 4 B1d: sin git y sin escrituras se envía y no hay tarjeta ni aviso', noGit.submitted === 1 && noGit.tried === 1 && noGit.rows === 0 && noGit.cards === 0 && !noGit.text, noGit);
      await evaluate(`(async () => { await PG.submit('crea c.txt'); await waitFor(() => PG.phase === 'chat' && LG.submit.length === 2); return true; })()`);
      const wroteNoGit = await evaluate(`({ row: !!document.querySelector('.turn-checkpoint'), text: (document.querySelector('.turn-checkpoint') || {}).textContent || '', init: !!document.querySelector('.turn-checkpoint #btn-git-init'), revert: !!document.querySelector('#btn-revert') })`);
      check('B1 tarea 4 B1d: sin git y con escrituras dice «Sin punto de control» con «Iniciar git aquí»', wroteNoGit.row && wroteNoGit.text.includes('Sin punto de control') && wroteNoGit.init && !wroteNoGit.revert, wroteNoGit);
      await evaluate(`PG.newConversation(); true`);
    });

    // ---- B1e (11-nov): cabecera de Directo, Revertir tras run_command, cifras ----
    await guard('B1e Directo: cabecera, comandos y singular', async () => {
      await evaluate(`(async () => {
        try { localStorage.setItem('devagents.workmode.v1', 'directo'); } catch (e) {}
        const ran = (id, extra) => ({ id, ts: 1, source: 'worker', kind: 'native_tool_result_v1', payload: Object.assign({ tool_name: 'run_command', task_id: 'directo' }, extra) });
        window.CFGE = {
          nextIds: [95, 96, 97],
          plans: {
            95: { understanding: 'He ejecutado el script.\\n\\n[DevAgents] Sin escrituras directas en esta vuelta: se ejecutaron 1 comando(s), que pueden haber cambiado archivos.', tasks: [] },
            96: { understanding: 'No pude ejecutar el comando.', tasks: [] },
            97: { understanding: 'Hola.', tasks: [] },
          },
          events: {
            95: [ran(950, { exit_code: 0, stdout: '', stderr: '', timed_out: false })],
            96: [ran(960, { error: 'permission_required', detail: 'rechazado' })],
          },
          sessions: [], messages: [],
        };
        const m = mkCore(CFGE); window.LE = m.log; LE.hold = true;
        m.core.restoreCheckpoint = async (sha) => { LE.restore.push(sha); return { restored: 0, deleted: 1, removedDirs: 0, notDeleted: [], indexRestored: false, indexNote: 'otro proceso de git tiene bloqueado el índice (index.lock)' }; };
        const pollPlan = m.core.pollPlan;
        m.core.pollPlan = async (id) => (id === 97 && LE.hold ? { done: false } : pollPlan(id));
        window.PE = mount(m.core);
        await PE.submit('ejecuta el script'); await waitFor(() => PE.phase === 'chat');
        return true; })()`);
      const cmd = await evaluate(`({ revert: !!document.querySelector('.turn-checkpoint #btn-revert'), text: (document.querySelector('.turn-checkpoint') || {}).textContent || '' })`);
      check('B1e: una vuelta que solo ejecutó un comando ofrece «Revertir los archivos»', cmd.revert && cmd.text.includes('Punto de control'), cmd);

      await evaluate(`(async () => { document.querySelector('#btn-revert').click(); await waitFor(() => !!document.querySelector('[role="dialog"]')); document.querySelector('[role="dialog"] button:last-child').click(); await waitFor(() => LE.restore.length === 1); return true; })()`);
      const one = await evaluate(`(async () => { await waitFor(() => body().textContent.includes('borrado')); return body().textContent.replace(/\\s+/g, ' '); })()`);
      check('B1e: «Revertir» dice «0 restaurados, 1 borrado» (singular), nunca «1 borrados»', one.includes('0 restaurados, 1 borrado.') && !one.includes('1 borrados'), one.slice(0, 300));
      check('CK-PUB-011: si el host no pudo devolver el índice de git, «Revertir» lo dice con su motivo', one.includes('El índice de git no se tocó: otro proceso de git tiene bloqueado el índice (index.lock).'), one.slice(0, 400));

      await evaluate(`(async () => { await PE.submit('ejecuta algo prohibido'); await waitFor(() => PE.phase === 'chat' && LE.submit.length === 2); return true; })()`);
      const denied = await evaluate(`({ revert: !!document.querySelector('#btn-revert') })`);
      check('B1e: un comando rechazado (no llegó a correr) no ofrece Revertir', !denied.revert, denied);

      // Mientras el modelo responde (sin directo_started_v1 todavía), la
      // cabecera no habla de plan ni de revisión.
      await evaluate(`(async () => { PE.submit('Hola'); await waitFor(() => PE.phase === 'planning' && LE.submit.length === 3); return true; })()`);
      const head = await evaluate(`(() => { const h = document.querySelector('#mission-body .row'); return { text: (h || {}).textContent ? h.textContent.replace(/\\s+/g, ' ') : '', all: body().textContent }; })()`);
      check('B1e: en Directo la cabecera dice que responde el modelo, sin «plan→» ni «Revisión por decidir»',
        head.all.includes('Respondiendo') && head.all.includes('responde ') && !head.all.includes('plan→') && !head.all.includes('Revisión por decidir') && !head.all.includes('Planificando'), head.text);
      await evaluate(`(async () => { LE.hold = false; await waitFor(() => PE.phase === 'chat'); PE.newConversation(); return true; })()`);
    });

    // ---- (tanda 1, 12-nov): la aprobación de un comando se contesta en el hilo ----
    await guard('CK-PUB-011 aprobación en el hilo', async () => {
      const r = await evaluate(`(async () => {
        const m = mkCore({ nextIds: [], events: {}, plans: {}, sessions: [], messages: [] });
        m.log.resolved = [];
        m.core.resolveApproval = async (id, approved) => { m.log.resolved.push([id, approved]); return {}; };
        const P = mount(m.core);
        P.orderId = 60;
        P.events = [
          { id: 1, ts: 1, source: 'superagente', kind: 'task_started', payload: { task_id: 'directo' } },
          { id: 2, ts: 2, source: 'superagente', kind: 'approval_needed', payload: { approval_id: 41, tool: 'run_command', reason: 'Aprobar este comando exacto: git mv a b' } },
        ];
        P.setPhase('running'); P.renderBody();
        const card = document.querySelector('[data-thread-approval="41"]');
        const before = { card: !!card, approve: !!document.querySelector('[data-thread-approve="41"]'), reject: !!document.querySelector('[data-thread-reject="41"]') };
        document.querySelector('[data-thread-approve="41"]').click();
        await waitFor(() => m.log.resolved.length === 1);
        await waitFor(() => document.querySelector('[data-thread-approve="41"]')?.disabled === true);
        const busy = { disabled: document.querySelector('[data-thread-approve="41"]')?.disabled === true };
        P.events.push({ id: 3, ts: 3, source: 'core', kind: 'approval_resolved', payload: { approval_id: 41, approved: true } });
        P.renderBody();
        const after = { card: !!document.querySelector('[data-thread-approval="41"]') };
        P.newConversation();
        return { before, busy, after, resolved: m.log.resolved };
      })()`);
      check('CK-PUB-011: la tarjeta de aprobación del hilo trae Aprobar y Rechazar', r.before.card && r.before.approve && r.before.reject, r);
      check('CK-PUB-011: Aprobar en el hilo resuelve esa solicitud y desactiva los botones', JSON.stringify(r.resolved) === '[[41,true]]' && r.busy.disabled, r);
      check('CK-PUB-011: resuelta en el motor, la tarjeta sale del hilo', !r.after.card, r);
    });

    // ---- P1-4 (11-nov): la madre no ofrece «Reintentar» si ninguna hija sin auditar conserva su copia ----
    await guard('P1-4 Reintentar de la madre sin copia de trabajo', async () => {
      const r = await evaluate(`(async () => {
        const m = mkCore({ nextIds: [], events: {}, plans: {}, sessions: [], messages: [] });
        const P = mount(m.core);
        const line = (id, kind, child, index, extra) => ({ id, ts: 1, source: 'superagente', kind, payload: Object.assign({ index, child_order_id: child, unaudited: true }, extra) });
        P.orderId = 70;
        P.events = [
          line(1, 'delegation_subtask_finished_v1', 71, 1, { retryable: true, worktree: '.devagents/spaces/orden-70-d1' }),
          line(2, 'delegation_subtask_finished_v1', 72, 2, { retryable: true, worktree: '.devagents/spaces/orden-70-d2' }),
        ];
        P.setPhase('audit-unavailable'); P.renderBody();
        const both = { retry: !!document.querySelector('#btn-audit-retry'), blocked: !!document.querySelector('#audit-not-retryable') };
        // Reintento: la 1 ya no tiene copia; la 2 sigue reintentable → se ofrece.
        P.events.push(line(3, 'delegation_audit_retry_v1', 71, 1, { retryable: false, error: 'su copia de trabajo ya no existe; vuelve a pedir la subtarea', worktree: null }));
        P.renderBody();
        const one = { retry: !!document.querySelector('#btn-audit-retry'), blocked: !!document.querySelector('#audit-not-retryable') };
        // Ninguna conserva su copia → sin «Reintentar», con el motivo de cada una.
        P.events.push(line(4, 'delegation_audit_retry_v1', 72, 2, { retryable: false, error: 'su copia de trabajo ya no existe; vuelve a pedir la subtarea', worktree: null }));
        P.renderBody();
        const card = document.querySelector('#audit-not-retryable');
        const none = { retry: !!document.querySelector('#btn-audit-retry'), blocked: !!card, text: card ? card.textContent.replace(/\\s+/g, ' ') : '', reset: !!document.querySelector('#btn-mission-reset') };
        // Una orden sin delegación sigue ofreciendo su «Reintentar auditoría».
        P.events = [{ id: 9, ts: 1, source: 'worker', kind: 'task_audit_unavailable_v1', payload: { task_id: 't2' } }];
        P.renderBody();
        const plain = { retry: !!document.querySelector('#btn-audit-retry') };
        P.newConversation();
        return { both, one, none, plain };
      })()`);
      check('P1-4: con hijas reintentables se ofrece «Reintentar auditoría»', r.both.retry && !r.both.blocked && r.one.retry && !r.one.blocked, r);
      check('P1-4: si ninguna hija sin auditar conserva su copia, no hay «Reintentar» y se dice por qué', !r.none.retry && r.none.blocked && r.none.reset && r.none.text.includes('Subtarea 1: su copia de trabajo ya no existe; vuelve a pedir la subtarea') && r.none.text.includes('Subtarea 2:'), r.none);
      check('P1-4: una orden sin delegación conserva su «Reintentar auditoría»', r.plain.retry, r.plain);
    });

    // ---- P1-8 (11-nov): reabrir una conversación de Directo que escribió: sin «Revertir» muerto ni error ----
    await guard('P1-8 historial de Directo sin puntos de control en memoria', async () => {
      await evaluate(`(async () => {
        try { localStorage.setItem('devagents.workmode.v1', 'directo'); } catch (e) {}
        const wrote = (said, files) => said + '\\n\\n[DevAgents] Archivos cambiados: ' + files + '.';
        const fw = (id, p) => ({ id, ts: 1, source: 'directo', kind: 'file_written', payload: { file_path: 'C:\\\\w\\\\' + p, content: 'x' } });
        const m = mkCore({
          nextIds: [],
          sessions: [60, 61, 62].map(id => ({ id, status_text: 'done', created_at: id, conversation_id: 'conv-p18' })),
          messages: [
            { order_id: 60, role: 'user', content: 'crea a.txt' }, { order_id: 60, role: 'assistant', content: wrote('He creado a.txt.', 'a.txt') },
            { order_id: 61, role: 'user', content: 'Hola' }, { order_id: 61, role: 'assistant', content: 'Hola.' },
            { order_id: 62, role: 'user', content: 'crea b.txt' }, { order_id: 62, role: 'assistant', content: wrote('He creado b.txt.', 'b.txt') },
          ],
          plans: {
            60: { understanding: wrote('He creado a.txt.', 'a.txt'), tasks: [] },
            61: { understanding: 'Hola.', tasks: [] },
            62: { understanding: wrote('He creado b.txt.', 'b.txt'), tasks: [] },
          },
          events: { 60: [fw(600, 'a.txt')], 62: [fw(620, 'b.txt')] },
        });
        window.LP18 = m.log;
        window.PP18 = mount(m.core); await PP18.loadSession(62, 'conv-p18'); return true;
      })()`);
      const h = await evaluate(`(() => {
        const text = body().textContent;
        const buttons = Array.from(document.querySelectorAll('#mission-body button')).filter(b => /Revertir/.test(b.textContent));
        return {
          phase: PP18.phase,
          revertButtons: buttons.length,
          priorRevert: document.querySelectorAll('[data-prior-revert]').length,
          currentRevert: !!document.querySelector('#btn-revert'),
          rows: document.querySelectorAll('.turn-checkpoint').length,
          noCheckpoint: /Sin punto de control/.test(text),
          errors: ['No se pudo', 'Error', 'undefined', 'null'].filter(t => text.includes(t)),
          restores: LP18.restore.length,
          said: text.includes('He creado a.txt.') && text.includes('He creado b.txt.'),
        };
      })()`);
      check('P1-8: al reabrir Directo, las vueltas antiguas no muestran un «Revertir» sin punto de control', h.revertButtons === 0 && h.priorRevert === 0 && !h.currentRevert && h.rows === 0, h);
      check('P1-8: al reabrir Directo no aparece «Sin punto de control» ni un error', !h.noCheckpoint && h.errors.length === 0 && h.restores === 0, h);
      check('P1-8: las respuestas de las vueltas siguen visibles', h.said && (h.phase === 'chat' || h.phase === 'done'), h);
      await evaluate(`PP18.newConversation(); true`);
    });

    // ---- T1-R1 (12-nov, vivo): reabrir una vuelta de «DevAgents» sin auditar (orden 35) ----
    // (A) el motor no tiene plan de una vuelta sin planificador y responde
    // «no plan available»: no es un fallo, y las hijas sin auditar se ofrecen
    // a reintentar. (B) la vuelta anterior de OTRA conversación tomó un punto
    // de control en otro proyecto: la sesión reabierta no puede ofrecerlo.
    await evaluate(`window.T1R1 = (cfg) => {
      const line = (id, kind, child, index, extra) => ({ id, ts: 1, source: 'superagente', kind, payload: Object.assign({ index, child_order_id: child, unaudited: true }, extra) });
      const m = mkCore({
        nextIds: [40],
        sessions: [{ id: 35, status_text: 'audit_unavailable', created_at: 35, conversation_id: 'conv-35' }],
        messages: [ { order_id: 35, role: 'user', content: 'divide el trabajo en dos' }, { order_id: 35, role: 'assistant', content: 'Delegué dos subtareas.' } ],
        plans: { 40: { understanding: 'He creado otro.txt.\\n\\n[DevAgents] Archivos cambiados: otro.txt.', tasks: [] } },
        events: {
          // Como en vivo: una hija integrada (la vuelta «escribió») y otra sin auditar.
          35: cfg.children.map((c, i) => line(350 + i, c.kind || 'delegation_subtask_finished_v1', c.child, c.index, c.extra))
            .concat([{ id: 359, ts: 2, source: 'superagente', kind: 'delegation_finished_v1', payload: { integrated: 1, total: 2 } }]),
          40: [ { id: 400, ts: 1, source: 'directo', kind: 'file_written', payload: { file_path: 'C:\\\\tmp\\\\angel-t1-qa\\\\otro.txt', content: 'x' } } ],
        },
      });
      m.core.orderStatus = async (id) => ({ status: id === 35 ? 11 : 5 });
      const getPlan = m.core.getPlan;
      m.core.getPlan = async (id) => {
        if (id === 35) { m.log.plansAsked.push(id); throw new Error(cfg.planError || 'da_plan_get_json: no plan available'); }
        return getPlan(id);
      };
      m.core.createCheckpoint = async () => { m.log.checkpoint.push(40); return { sha: 'shaAJENO40cccccccccc', root: 'C:\\\\tmp\\\\angel-t1-qa', untrackedCount: 0 }; };
      return m;
    }; true`);
    const t1r1State = `(P) => ({
      phase: P.phase,
      loadError: body().textContent.includes('No se pudo cargar'),
      retry: !!document.querySelector('#btn-audit-retry'),
      notRetryable: !!document.querySelector('#audit-not-retryable'),
      revert: !!document.querySelector('#btn-revert'),
      rows: document.querySelectorAll('.turn-checkpoint').length,
      foreignSha: body().textContent.includes('shaAJENO40'),
      checkpointText: /Punto de control/.test(body().textContent),
      reply: body().textContent.includes('Delegué dos subtareas.'),
    })`;

    await guard('T1-R1 (A) reabrir una vuelta de DevAgents sin auditar', async () => {
      const r = await evaluate(`(async () => {
        const st = ${t1r1State};
        const out = {};
        const run = async (key, cfg) => {
          const m = T1R1(cfg); const P = mount(m.core);
          await P.loadSession(35, 'conv-35');
          out[key] = Object.assign(st(P), { asked: m.log.plansAsked.includes(35) });
          P.newConversation();
        };
        await run('retryable', { children: [
          { child: 36, index: 1, extra: { retryable: true, worktree: '.devagents/spaces/orden-35-d1' } },
          { child: 37, index: 2, extra: { unaudited: false } } ] });
        await run('blocked', { children: [
          { child: 36, index: 1, extra: { retryable: false, error: 'su copia de trabajo ya no existe; vuelve a pedir la subtarea' } } ] });
        await run('audited', { children: [ { child: 36, index: 1, extra: { unaudited: false } } ] });
        await run('otherError', { planError: 'da_plan_get_json: database is locked', children: [
          { child: 36, index: 1, extra: { retryable: true } } ] });
        return out;
      })()`);
      check('T1-R1 (A): «no plan available» no es un fallo de la sesión reabierta', r.retryable.asked && !r.retryable.loadError && r.retryable.reply, r.retryable);
      check('T1-R1 (A): con una hija sin auditar reintentable, la sesión reabierta ofrece «Reintentar auditoría»', r.retryable.phase === 'audit-unavailable' && r.retryable.retry && !r.retryable.notRetryable, r.retryable);
      check('T1-R1 (A): si ninguna hija sin auditar es reintentable, se dice por qué y no hay «Reintentar»', r.blocked.phase === 'audit-unavailable' && !r.blocked.retry && r.blocked.notRetryable && !r.blocked.loadError, r.blocked);
      check('T1-R1 (A): sin hijas sin auditar ni tareas propias, se reabre como conversación', r.audited.phase === 'chat' && !r.audited.retry && !r.audited.loadError && r.audited.reply, r.audited);
      check('T1-R1 (A): cualquier otro error al leer el plan sigue fallando como antes', r.otherError.phase === 'error' && r.otherError.loadError && !r.otherError.retry, r.otherError);
    });

    await guard('T1-R1 (B) la sesión reabierta no hereda el punto de control de otra conversación', async () => {
      const r = await evaluate(`(async () => {
        try { localStorage.setItem('devagents.workmode.v1', 'directo'); } catch (e) {}
        const st = ${t1r1State};
        const out = {};
        const run = async (key, cfg) => {
          const m = T1R1(cfg); const P = mount(m.core);
          // Vuelta de Directo en otro proyecto que escribe: deja su «Revertir».
          await P.submit('crea otro.txt'); await waitFor(() => P.phase === 'chat');
          out[key + 'Before'] = st(P);
          // Sin «Nueva conversación»: se abre la sesión 35 desde la barra lateral.
          await P.loadSession(35, 'conv-35');
          out[key] = st(P);
          P.newConversation();
        };
        await run('reopen', { children: [ { child: 36, index: 1, extra: { retryable: true } } ] });
        await run('chat', { children: [ { child: 36, index: 1, extra: { unaudited: false } } ] });
        await run('failed', { planError: 'da_plan_get_json: database is locked', children: [ { child: 36, index: 1, extra: { retryable: true } } ] });
        return out;
      })()`);
      check('T1-R1 (B): la vuelta de la otra conversación sí tenía su «Revertir»', r.reopenBefore.revert && r.reopenBefore.foreignSha, r.reopenBefore);
      check('T1-R1 (B): reabierta sin auditar, no muestra el punto de control ajeno', r.reopen.phase === 'audit-unavailable' && !r.reopen.revert && r.reopen.rows === 0 && !r.reopen.foreignSha && !r.reopen.checkpointText, r.reopen);
      check('T1-R1 (B): reabierta como conversación, tampoco', r.chat.phase === 'chat' && !r.chat.revert && r.chat.rows === 0 && !r.chat.foreignSha, r.chat);
      check('T1-R1 (B): si la carga falla, la pantalla de error no ofrece el punto de control ajeno', r.failed.phase === 'error' && r.failed.loadError && !r.failed.revert && !r.failed.foreignSha && !r.failed.checkpointText, r.failed);
    });

    // ---- r3: la misma mezcla al reabrir una sesión del historial ----
    await guard('CK-CAB-003 r3 carga histórica charla-charla-trabajo-charla', async () => {
      await evaluate(`(async () => {
        const m = mkCore({
          nextIds: [], events: { 42: [ { id: 420, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\\\w\\\\r3.txt', content: 'x' } } ] },
          sessions: [40, 41, 42, 43].map(id => ({ id, status_text: 'done', created_at: id, conversation_id: 'conv-r3' })),
          messages: [40, 41, 42, 43].flatMap(order_id => [
            { order_id, role: 'user', content: 'pregunta ' + order_id },
            { order_id, role: 'assistant', content: 'respuesta ' + order_id },
          ]),
          plans: {
            40: { understanding: 'respuesta 40', tasks: [] },
            41: { understanding: 'respuesta 41', tasks: [] },
            42: { understanding: 'Entendimiento 42', tasks: [ { id: 't', description: 'trabajo 42', depends_on: [] } ] },
            43: { understanding: 'respuesta 43', tasks: [] },
          },
        });
        window.P5 = mount(m.core); await P5.loadSession(43, 'conv-r3'); return true;
      })()`);
      const history = await evaluate(`(() => {
        const d = document.querySelector('details[data-prior-order="42"]');
        const visible = Array.from(document.querySelectorAll('.chat-bubble')).filter(b => !b.closest('details[data-prior-order]')).map(b => b.textContent.trim());
        const text = body().textContent;
        return {
          ids: priorIds(), active: P5.orderId,
          kinds: P5.priorOrders.map(p => p.kind),
          summary: d ? d.querySelector('summary').textContent.replace(/\\s+/g, ' ').trim() : '',
          title: d ? d.title : '',
          open: d ? d.open : null,
          visible,
          chatBlocks: [40, 41, 43].filter(n => !!document.querySelector('details[data-prior-order="' + n + '"]')),
          order: ['pregunta 40', 'pregunta 41', 'Orden #42', 'pregunta 43'].map(t => text.indexOf(t)),
        };
      })()`);
      check('CK-CAB-003 r3 historial: tres charlas como burbujas y un solo bloque de trabajo', history.active === 43 && JSON.stringify(history.ids) === '[42]' && JSON.stringify(history.kinds) === '["chat","chat","work"]' && history.chatBlocks.length === 0, history);
      check('CK-CAB-003 r3 historial: el bloque de trabajo está plegado con su resumen', history.open === false && history.summary.startsWith('Escribió 1 archivo') && history.title === 'Orden #42', history);
      check('CK-CAB-003 r3 historial: burbujas de las tres charlas presentes y visibles', ['pregunta 40', 'respuesta 40', 'pregunta 41', 'respuesta 41', 'pregunta 43', 'respuesta 43'].every(t => history.visible.includes(t)), history.visible);
      check('CK-CAB-003 r3 historial: orden cronológico burbujas → bloque → charla activa', history.order.every((x, i) => x >= 0 && (i === 0 || x > history.order[i - 1])), history.order);
      const again = await evaluate(`(async () => { await P5.loadSession(42, 'conv-r3'); return true; })()`);
      check('CK-CAB-003 r3 historial: recargar otra orden del hilo repite burbujas + un bloque', again && await evaluate(`(() => {
        const visible = Array.from(document.querySelectorAll('.chat-bubble')).filter(b => !b.closest('details[data-prior-order]')).map(b => b.textContent.trim());
        return P5.orderId === 43 && JSON.stringify(priorIds()) === '[42]' && P5.priorOrders.filter(p => p.kind === 'chat').length === 2 && visible.includes('pregunta 43') && visible.includes('respuesta 43');
      })()`));
      await evaluate(`P5.newConversation(); true`);
      check('CK-CAB-003 r3 nueva conversación sigue vacía (sin bloques ni burbujas)', await evaluate(`priorIds().length === 0 && document.querySelectorAll('.chat-bubble').length === 0`));
    });
    // ---- r4 P1: un hilo de más de 40 órdenes clasifica TODAS (charla vieja = mensaje) ----
    await guard('CK-CAB-003 r4 P1 hilo largo clasifica la charla antigua', async () => {
      await evaluate(`(async () => {
        const ids = Array.from({ length: 43 }, (_, i) => i + 1);
        const plans = {};
        ids.forEach((id) => {
          plans[id] = id === 1
            ? { understanding: 'charla vieja', tasks: [] }
            : { understanding: 'trabajo ' + id, tasks: [ { id: 't', task_type: 'code', department: 'programacion', description: 't ' + id, depends_on: [] } ] };
        });
        const m = mkCore({
          nextIds: [],
          sessions: ids.map((id) => ({ id, status_text: 'done', created_at: id, conversation_id: 'conv-r4' })),
          messages: ids.flatMap((order_id) => [
            { order_id, role: 'user', content: 'viejo usuario ' + order_id },
            { order_id, role: 'assistant', content: 'viejo agente ' + order_id },
          ]),
          plans,
          events: Object.fromEntries(ids.map((id) => [id, [ { id: id * 10, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\\\w\\\\f' + id + '.txt', content: 'x' } } ]])),
        });
        window.LR4 = m.log; window.PR4 = mount(m.core);
        await PR4.loadSession(43, 'conv-r4');
        return true; })()`);
      const p1 = await evaluate(`(() => {
        const old = PR4.priorOrders.find(p => p.orderId === 1);
        const visible = Array.from(document.querySelectorAll('.chat-bubble')).filter(b => !b.closest('details[data-prior-order]')).map(b => b.textContent.trim());
        return {
          priors: PR4.priorOrders.length,
          oldKind: old ? old.kind : null,
          oldBlock: !!document.querySelector('details[data-prior-order="1"]'),
          visibleOld: visible.includes('viejo usuario 1') && visible.includes('viejo agente 1'),
          workBlock: !!document.querySelector('details[data-prior-order="42"]'),
          askedOldPlan: LR4.plansAsked.includes(1),
          askedOldEvents: LR4.eventsAsked.includes(1),
        };
      })()`);
      check('CK-CAB-003 r4 P1 un hilo de más de 40 órdenes tiene 42 anteriores', p1.priors === 42, p1);
      check('CK-CAB-003 r4 P1 la charla antigua se clasifica como charla y se lee su plan', p1.oldKind === 'chat' && p1.askedOldPlan, p1);
      check('CK-CAB-003 r4 P1 la charla antigua se muestra como mensaje, no como bloque de trabajo', !p1.oldBlock && p1.visibleOld, p1);
      check('CK-CAB-003 r4 P1 el trabajo reciente sigue plegado como bloque', p1.workBlock, p1);
      check('CK-CAB-003 r4 P1 la cota de eventos sigue: la orden antigua no pide sus eventos', !p1.askedOldEvents, p1);
    });

    // ---- r4 P2: un getPlan que falla NO convierte la orden en charla ----
    await guard('CK-CAB-003 r4 P2 un getPlan que falla no convierte la orden en charla', async () => {
      await evaluate(`(async () => {
        const m = mkCore({
          nextIds: [],
          sessions: [1, 2, 3].map((id) => ({ id, status_text: 'done', created_at: id, conversation_id: 'conv-r4b' })),
          messages: [1, 2, 3].flatMap((order_id) => [
            { order_id, role: 'user', content: 'm ' + order_id },
            { order_id, role: 'assistant', content: 'r ' + order_id },
          ]),
          plans: { 1: { understanding: 'charla', tasks: [] }, 2: { understanding: 'tenia tareas', tasks: [] } },
          planErrors: { 2: true },
          events: {},
        });
        window.LR4B = m.log; window.PR4B = mount(m.core);
        await PR4B.loadSession(3, 'conv-r4b');
        return true; })()`);
      const p2 = await evaluate(`(() => {
        const bad = PR4B.priorOrders.find(p => p.orderId === 2);
        const good = PR4B.priorOrders.find(p => p.orderId === 1);
        const visible = Array.from(document.querySelectorAll('.chat-bubble')).filter(b => !b.closest('details[data-prior-order]')).map(b => b.textContent.trim());
        const d = document.querySelector('details[data-prior-order="2"]');
        return {
          badKind: bad ? bad.kind : null,
          badBlock: !!d,
          badErrorShown: d ? /No se pudo leer el plan/.test(d.textContent) : false,
          badAsMessage: visible.includes('m 2'),
          goodKind: good ? good.kind : null,
        };
      })()`);
      // A7 (10-nov): el mensaje del usuario ya no va dentro del grupo de
      // trabajo, sino en el hilo, antes de él; lo que se exige es que la orden
      // siga siendo trabajo (grupo con su fallo de lectura), no charla.
      check('CK-CAB-003 r4 P2 un getPlan que falla no convierte la orden en charla', p2.badKind === 'work' && p2.badBlock && p2.badAsMessage, p2);
      check('CK-CAB-003 r4 P2 el fallo del plan se muestra en su bloque', p2.badErrorShown, p2);
      check('CK-CAB-003 r4 P2 la charla real (getPlan correcto) sigue siendo mensaje', p2.goodKind === 'chat', p2);
    });

    // ---- USUARIO-NUEVO A7 (10-nov): dos «Hola» fallidos y uno bueno se leen como conversación ----
    await guard('USUARIO-NUEVO A7 fallos conversacionales', async () => {
      await evaluate(`(async () => {
        const fail = 'Directo: Codex no arrancó porque tienes instrucciones personales.';
        const m = mkCore({
          nextIds: [],
          sessions: [50, 51, 52].map((id) => ({ id, status_text: id === 52 ? 'done' : 'failed', created_at: id, conversation_id: 'conv-a7' })),
          messages: [
            { order_id: 50, role: 'user', content: 'Hola' },
            { order_id: 51, role: 'user', content: 'Hola otra vez' },
            { order_id: 52, role: 'user', content: 'Hola por fin' },
            { order_id: 52, role: 'assistant', content: 'Hola, ¿en qué te ayudo?' },
          ],
          plans: { 50: { understanding: fail, tasks: [] }, 51: { understanding: fail, tasks: [] }, 52: { understanding: 'Hola, ¿en qué te ayudo?', tasks: [] } },
          events: {
            50: [ { id: 500, ts: 1, source: 'directo', kind: 'directo_finished_v1', payload: { ok: false, error: 'PersonalContextIsolationUnavailable' } } ],
            51: [ { id: 510, ts: 1, source: 'directo', kind: 'directo_finished_v1', payload: { ok: false, error: 'PersonalContextIsolationUnavailable' } } ],
            52: [ { id: 520, ts: 1, source: 'directo', kind: 'directo_finished_v1', payload: { ok: true } } ],
          },
        });
        window.PA7 = mount(m.core); await PA7.loadSession(52, 'conv-a7'); return true; })()`);
      const a7 = await evaluate(`(() => {
        const text = body().textContent;
        const failed = Array.from(document.querySelectorAll('.chat-bubble--failed')).map(b => b.textContent.trim());
        return {
          blocks: priorIds(),
          kinds: PA7.priorOrders.map(p => p.kind),
          failed,
          order: ['Hola', 'Hola otra vez', 'Hola por fin', 'Hola, ¿en qué te ayudo?'].map(t => text.indexOf(t)),
          noise: ['Orden #50', 'Orden #51', 'Entendimiento', 'Trabajó durante', 'evento(s) del motor', 'sin clasificar', 'Todavía no hay operaciones', '0 tareas'].filter(t => text.includes(t)),
          group: !!document.querySelector('#turn-activity'),
        };
      })()`);
      check('USUARIO-NUEVO A7 ningún turno conversacional fallido se envuelve en «Orden #N»', a7.blocks.length === 0 && JSON.stringify(a7.kinds) === '["chat","chat"]', a7);
      check('USUARIO-NUEVO A7 cada fallo se ve una vez, como respuesta en línea', a7.failed.length === 2 && a7.failed.every(t => t.startsWith('Directo: Codex no arrancó')), a7.failed);
      check('USUARIO-NUEVO A7 el hilo es continuo y en orden', a7.order.every((x, i) => x >= 0 && (i === 0 || x > a7.order[i - 1])), a7.order);
      check('USUARIO-NUEVO A7 sin operaciones no se pinta grupo ni contadores del motor', !a7.group && a7.noise.length === 0, a7.noise);
    });
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); }
    finally {
      if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
      fail(Error('Browser closed'));
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    }
  }
  const total = results.length;
  if (failures.length) {
    console.error(`CK-CAB-003 UI TEST: ${failures.length} FAIL de ${total}`);
    assert.fail(`CK-CAB-003: ${failures.length} comprobaciones fallidas`);
  }
  console.log(`PASS CK-CAB-003 conversación continua: ${total} comprobaciones sobre DOM real en Chromium (bloques de trabajo plegados que sobreviven al envío, charla como burbujas en vivo y al reabrir, recarga de toda la conversación con cota de eventos, nueva conversación vacía, botones de bloques anteriores aislados de la orden en curso).`);
};

if (require.main === module) module.exports().catch(error => { console.error(error.message || error); process.exitCode = 1; });
