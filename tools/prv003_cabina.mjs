// Cabin acceptance helpers shared by the simulated browser tests and CDP driver.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

// Use the planner's supported imperative ("Ejecutar" is not an execution
// intent and would require an LLM/key in the isolated, credential-free fixture).
export const SELF_REVIEW_ORDER = 'Ejecuta cmd /c echo PRV003';

export async function checkSelfReviewedOrder({ evaluate, wait, click, capture }) {
  await evaluate(`document.querySelector('#mission-composer-input').value=${JSON.stringify(SELF_REVIEW_ORDER)};document.querySelector('#mission-composer-input').dispatchEvent(new Event('input',{bubbles:true}))`);
  await click('#btn-mission-send');
  await wait("!!document.querySelector('[data-order-review]')");
  await wait("/Autorrevisada/.test(document.querySelector('[data-order-review]')?.textContent ?? '')");
  assert.doesNotMatch(await evaluate("document.querySelector('[data-order-review]').textContent"), /Auditada/);
  await wait("!!document.querySelector('#btn-approve')");
  await capture('05-orden-autorrevisada-efectiva-sin-ejecutar');
}

export async function validateDataDir(value = process.env.BEATS_DATA_DIR) {
  assert(value && path.isAbsolute(value), 'BEATS_DATA_DIR must be an absolute existing isolated directory');
  const defaults = [path.join(os.homedir(), 'AppData/Local/DevAgents')];
  if (process.env.LOCALAPPDATA) defaults.push(path.join(process.env.LOCALAPPDATA, 'DevAgents-Angel'));
  const overlapsDefault = candidate => defaults.some(root => {
    const a = path.resolve(candidate).toLowerCase(), b = path.resolve(root).toLowerCase();
    return a === b || a.startsWith(b + path.sep) || b.startsWith(a + path.sep);
  });
  assert(!overlapsDefault(value), 'BEATS_DATA_DIR must not overlap the default user data directory');
  let canonical;
  try {
    assert((await fs.stat(value)).isDirectory());
    canonical = await fs.realpath(value);
  } catch (cause) { throw Error('BEATS_DATA_DIR must be an existing directory', { cause }); }
  assert(!overlapsDefault(canonical), 'BEATS_DATA_DIR resolves into the default user data directory');
  return canonical;
}

export async function runWithRestoration({ run, restore, timeoutMs = 120000, restoreTimeoutMs = 30000, signal }) {
  const runController = new AbortController();
  const interrupt = () => runController.abort(signal.reason ?? Error('Interrupted'));
  signal?.addEventListener('abort', interrupt, { once: true });
  if (signal?.aborted) interrupt();
  const timer = setTimeout(() => runController.abort(Error(`CDP exceeded ${timeoutMs} ms`)), timeoutMs);
  const aborted = new Promise((_, reject) => {
    const fail = () => reject(runController.signal.reason);
    if (runController.signal.aborted) fail();
    else runController.signal.addEventListener('abort', fail, { once: true });
  });
  let failure;
  try { await Promise.race([Promise.resolve().then(() => run(runController.signal)), aborted]); }
  catch (error) { failure = error; }
  finally { clearTimeout(timer); signal?.removeEventListener('abort', interrupt); }
  // Late continuations from the run cannot make UI changes during restoration.
  runController.abort(Error('Run ended; restoration in progress'));
  const restoreController = new AbortController();
  let restoreTimer;
  try {
    await Promise.race([
      Promise.resolve().then(() => restore(restoreController.signal)),
      new Promise((_, reject) => {
        restoreTimer = setTimeout(() => {
          const error = Error('restauración incompleta: restoration deadline exceeded');
          restoreController.abort(error); reject(error);
        }, restoreTimeoutMs);
      }),
    ]);
  } catch (cause) {
    const error = Error(`restauración incompleta: ${cause.message}`, { cause });
    error.exitCode = 2;
    throw error;
  } finally { clearTimeout(restoreTimer); }
  if (failure) throw failure;
}

// Shared with the browser regression: same controls and native-host envelopes.
export async function checkModelAutomatic({ evaluate, wait, click, select, capture }) {
  // A fresh isolated WebView profile opens the welcome modal. Use its real
  // control before mixing native select events and physical mouse input.
  if (await evaluate("!!document.querySelector('#onboarding-modal-root') && getComputedStyle(document.querySelector('#onboarding-modal-root')).display!=='none'")) {
    await click('#btn-onboarding-skip');
    await wait("getComputedStyle(document.querySelector('#onboarding-modal-root')).display==='none'");
  }
  if (await evaluate("getComputedStyle(document.querySelector('#model-picker')).display==='none'")) {
    await click('#btn-model-picker');
    await wait("getComputedStyle(document.querySelector('#model-picker')).display!=='none'");
  }
  const model = await evaluate("[...document.querySelector('#sel-model').options].find(o=>o.value&&!o.disabled).value");
  await select('#sel-model', model);
  await wait(`document.querySelector('#sel-model').dataset.committed===${JSON.stringify(model)}`);
  await wait("/Revisión por decidir/.test(document.querySelector('#model-audit-warning').textContent)");
  assert.doesNotMatch(await evaluate("document.querySelector('#model-audit-warning').textContent"), /Autorrevisada|Auditada/);
  await capture('01-modelo-revision-por-decidir');
  await evaluate("document.querySelector('#model-search').value='sin-resultados-prv003';document.querySelector('#model-search').dispatchEvent(new Event('input'))");
  await click('#model-list [data-val=""]');
  await wait("document.querySelector('#sel-model').value==='' && document.querySelector('#sel-model').dataset.committed===''");
  await capture('02-automatico-sin-reinicio');
  return model;
}

async function main() {
  // This guard precedes output creation, CDP discovery and all UI mutations.
  const dataDir = await validateDataDir();
  const output = path.resolve(process.argv[2] || 'zig-out/test-evidence/prv003-cdp');
  await fs.mkdir(output, { recursive: true });
  const stateFile = path.join(output, 'restoration.json');
  const state = { dataDir, status: 'restauración incompleta', reason: 'run in progress' };
  await fs.writeFile(stateFile, JSON.stringify(state, null, 2));
  const controller = new AbortController();
  const onInterrupt = signal => controller.abort(Error(`Interrupted: ${signal}`));
  const onSigint = () => onInterrupt('SIGINT'), onSigterm = () => onInterrupt('SIGTERM');
  process.on('SIGINT', onSigint); process.on('SIGTERM', onSigterm);
  let socket, original;
  const errors = [];
  let call, evalPage;
  let successful = false;
  try {
    await runWithRestoration({ signal: controller.signal,
      run: async signal => {
        const targets = await (await fetch(`http://127.0.0.1:${process.env.BEATS_DEVTOOLS_PORT || '9333'}/json/list`, { signal: AbortSignal.any([signal, AbortSignal.timeout(10000)]) })).json();
        for (const target of targets.filter(t => t.type === 'page' && t.webSocketDebuggerUrl)) {
          signal.throwIfAborted();
          const ws = new WebSocket(target.webSocketDebuggerUrl);
          socket = ws;
          await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(Error('CDP connect timeout')), 10000);
            ws.onopen = () => { clearTimeout(timer); resolve(); };
            ws.onerror = error => { clearTimeout(timer); reject(error); };
          });
          let next = 0;
          const pending = new Map();
          ws.onclose = () => {
            for (const request of pending.values()) request.reject(Error('CDP socket closed'));
          };
          ws.onmessage = ({ data }) => {
            const message = JSON.parse(data);
            if (message.method === 'Runtime.exceptionThrown' || (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error')) errors.push(message);
            const request = pending.get(message.id);
            if (!request) return;
            message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result);
          };
          call = (method, params = {}, operationSignal) => new Promise((resolve, reject) => {
            operationSignal?.throwIfAborted();
            const id = ++next;
            const finish = (fn, value) => { clearTimeout(timer); operationSignal?.removeEventListener('abort', abort); pending.delete(id); fn(value); };
            const abort = () => finish(reject, operationSignal.reason);
            const timer = setTimeout(() => finish(reject, Error(`CDP timeout: ${method}`)), 10000);
            operationSignal?.addEventListener('abort', abort, { once: true });
            pending.set(id, { resolve: value => finish(resolve, value), reject: error => finish(reject, error) });
            try { ws.send(JSON.stringify({ id, method, params })); } catch (error) { finish(reject, error); }
          });
          evalPage = async (expression, operationSignal) => {
            const result = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, operationSignal);
            if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
            return result.result.value;
          };
          const readyDeadline = Date.now() + 15000;
          let ready = false;
          while (!ready && Date.now() < readyDeadline) {
            try { ready = await evalPage("!!document.querySelector('#mission-composer')", signal); }
            catch (error) { if (!/context was destroyed|Cannot find context/i.test(error.message)) throw error; }
            if (!ready) await delay(100, undefined, { signal });
          }
          if (ready) break;
          ws.close(); socket = null;
        }
        assert(socket, 'No live MissionControl target');
        const { send, evaluate, wait, click, select, capture } = controls(signal);
        await send('Runtime.enable');
        await evaluate("document.querySelector('#model-picker').style.display==='none' && document.querySelector('#btn-model-picker').click()");
        await wait("document.querySelector('#sel-model option[value]:not([value=\"\"]):not(:disabled)') !== null");
        original = await evaluate(`({base:document.querySelector('#sel-model').value,
          roles:[...document.querySelectorAll('#model-role-rows select')].map(e=>({role:e.dataset.role,value:e.value})),
          swarm:document.querySelector('#chk-swarm-enabled').checked,
          deterministic:document.querySelector('#chk-deterministic').checked,
          waitApproval:document.querySelector('#wait-plan-approval').checked,
          draft:document.querySelector('#mission-composer-input').value,
          advanced:document.querySelector('#model-advanced').open})`);
        await evaluate("document.querySelector('#model-advanced').open=true");
        for (const role of original.roles) {
          await click(`[data-remove-role="${role.role}"]`); await wait(`!document.querySelector('[data-role="${role.role}"]')`);
        }
        const model = await checkModelAutomatic({ evaluate, wait, click, select, capture });
        await evaluate("document.querySelector('#model-search').value='';document.querySelector('#model-search').dispatchEvent(new Event('input'));document.querySelector('#model-advanced').open=true");
        if (!await evaluate("document.querySelector('#chk-swarm-enabled').checked")) await click('#chk-swarm-enabled');
        await wait("document.querySelector('#chk-swarm-enabled').checked");
        for (const role of ['exec', 'audit', 'second_audit', 'programmer', 'sidekick']) {
          await select('#sel-add-role', role); await click('#btn-add-role');
          const selector = `[data-role="${role}"]`;
          await wait(`!!document.querySelector(${JSON.stringify(selector)})`);
          const choice = await evaluate(`[...document.querySelector(${JSON.stringify(selector)}).options].find(o=>o.value&&!o.disabled)?.value`);
          assert(choice, `No eligible model for ${role}`);
          await select(selector, choice);
          await evaluate("document.dispatchEvent(new Event('devagents:models-changed'))");
          await wait(`document.querySelector(${JSON.stringify(selector)})?.dataset.committed===${JSON.stringify(choice)}`);
          assert.equal(await evaluate("document.querySelector('#chk-swarm-enabled').checked"), true);
          await capture('03-rol-' + role);
          await click(`[data-remove-role="${role}"]`); await wait(`!document.querySelector(${JSON.stringify(selector)})`);
        }
        await capture('04-roles-quitados-enjambre-activo');
        // Pure execution intent uses deterministicExecutePlan (no planner LLM).
        // Keep explicit approval enabled: plan and route, never dispatch a command.
        assert.equal(original.draft, '', 'Isolated cabin must start with an empty draft');
        await select('#sel-model', model);
        await wait(`document.querySelector('#sel-model').dataset.committed===${JSON.stringify(model)}`);
        if (await evaluate("document.querySelector('#chk-swarm-enabled').checked")) await click('#chk-swarm-enabled');
        if (!await evaluate("document.querySelector('#wait-plan-approval').checked")) await click('#wait-plan-approval');
        await checkSelfReviewedOrder({ evaluate, wait, click, capture });
        assert.equal(errors.length, 0, JSON.stringify(errors));
        successful = true;
      },
      restore: async signal => {
        if (original) {
          const { evaluate, wait, click, select } = controls(signal);
          await evaluate("document.querySelector('#model-picker').style.display==='none' && document.querySelector('#btn-model-picker').click();document.querySelector('#model-advanced').open=true");
          for (const role of await evaluate("[...document.querySelectorAll('#model-role-rows select')].map(e=>e.dataset.role)")) {
            await click(`[data-remove-role="${role}"]`); await wait(`!document.querySelector('[data-role="${role}"]')`);
          }
          await select('#sel-model', original.base);
          await wait(`document.querySelector('#sel-model').dataset.committed===${JSON.stringify(original.base)}`);
          for (const { role, value } of original.roles) {
            await select('#sel-add-role', role); await click('#btn-add-role');
            await wait(`!!document.querySelector('[data-role="${role}"]')`);
            await select(`[data-role="${role}"]`, value);
            await wait(`document.querySelector('[data-role="${role}"]')?.dataset.committed===${JSON.stringify(value)}`);
          }
          for (const [id, value] of [['#chk-swarm-enabled', original.swarm], ['#chk-deterministic', original.deterministic], ['#wait-plan-approval', original.waitApproval]]) {
            if (await evaluate(`document.querySelector('${id}').checked`) !== value) await click(id);
            await wait(`document.querySelector('${id}').checked===${value}`);
          }
          await evaluate("document.dispatchEvent(new Event('devagents:models-changed'))");
          await wait(`document.querySelector('#chk-swarm-enabled').checked===${original.swarm} && document.querySelector('#chk-deterministic').checked===${original.deterministic}`);
          await evaluate(`document.querySelector('#model-advanced').open=${original.advanced}`);
        }
        state.status = 'restored'; state.reason = original ? 'pins and switches confirmed after refresh' : 'no UI mutations';
        await fs.writeFile(stateFile, JSON.stringify(state, null, 2));
      },
    });
    if (successful) console.log('PASS CDP C2/C3/C4: Automático, five roles, swarm independent, neutral composer and effective self-reviewed order (planned without dispatch); restoration confirmed; captures saved.');
  } catch (error) {
    if (error.exitCode === 2) { state.status = 'restauración incompleta'; state.reason = error.message; }
    state.runError = error.message;
    try { await fs.writeFile(stateFile, JSON.stringify(state, null, 2)); }
    catch (writeError) { console.error(`Cannot persist restoration status: ${writeError.message}`); }
    throw error;
  } finally {
    process.removeListener('SIGINT', onSigint); process.removeListener('SIGTERM', onSigterm);
    socket?.close();
    try { await fs.writeFile(path.join(output, 'console-errors.json'), JSON.stringify(errors, null, 2)); }
    catch (error) {
      if (state.status === 'restauración incompleta') error.exitCode = 2;
      throw error;
    }
  }

  function controls(signal) {
    const send = (method, params = {}) => call(method, params, signal);
    const evaluate = expression => evalPage(expression, signal);
    const wait = async expression => {
      const deadline = Date.now() + 10000;
      while (!await evaluate(expression)) {
        assert(Date.now() < deadline, `UI timeout: ${expression}`);
        await delay(100, undefined, { signal });
      }
    };
    const click = async selector => {
      const point = await evaluate(`(() => {const e=document.querySelector(${JSON.stringify(selector)});if(!e)throw Error('Missing control');e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
      for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, ...point, button: 'left', clickCount: 1 });
    };
    const select = (selector, value) => evaluate(`(() => {const e=document.querySelector(${JSON.stringify(selector)});e.value=${JSON.stringify(value)};e.dispatchEvent(new Event('change',{bubbles:true}));})()`);
    const capture = async name => {
      const text = await evaluate("document.body.innerText");
      await fs.writeFile(path.join(output, name + '.txt'), text);
      const screenshot = await send('Page.captureScreenshot', { format: 'png' });
      await fs.writeFile(path.join(output, name + '.png'), Buffer.from(screenshot.data, 'base64'));
    };
    return { send, evaluate, wait, click, select, capture };
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => { console.error(error.message); process.exitCode = error.exitCode ?? 1; });
}
