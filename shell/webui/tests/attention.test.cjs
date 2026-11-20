// — avisos de órdenes y bandeja de no leídos. DOM real en Chromium
// por CDP (mismo arnés que code_copy/cabina_ux_browser). Los dobles: almacenamiento
// en memoria, Notification, foco de ventana y apertura de la orden.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

module.exports = async function attention() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-ux-attn-'));
  const executable = process.env.DEVAGENTS_TEST_BROWSER || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  const html = path.join(profile, 'attn.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map();
  const browserErrors = [];
  child.stderr.on('data', data => { stderr += data; });
  const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      if (message.method === 'Runtime.exceptionThrown') browserErrors.push(message);
      const request = pending.get(message.id);
      if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 15000);
      pending.set(id, { resolve, reject, timer });
      child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  const wait = ms => evaluate(`new Promise(resolve => setTimeout(resolve, ${ms}))`);
  async function click(selector) {
    await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({ block: 'center' })`);
    const point = await evaluate(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...point });
    for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, ...point, button: 'left', clickCount: 1 });
    await wait(60);
  }
  const failures = [];
  const step = async (name, fn) => { try { await fn(); console.log('PASS CK-COMP-011 ' + name); } catch (error) { failures.push(name + ': ' + error.message); } };
  try {
    const url = pathToFileURL(html).href;
    const { targetId } = await send('Target.createTarget', { url }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
    const deadline = Date.now() + 10000;
    const ready = () => evaluate(`location.href===${JSON.stringify(url)} && document.readyState==='complete' && document.head!==null`)
      .catch(error => { if (/context was destroyed|Cannot find context/i.test(error.message)) return false; throw error; });
    while (!await ready()) {
      assert(Date.now() < deadline, `Timeout waiting for document: ${url}`);
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    await send('Emulation.setDeviceMetricsOverride', { width: 1100, height: 700, deviceScaleFactor: 1, mobile: false });
    const names = ['attention_ux', 'alerts_ux', 'status_labels_ux', 'layout_ux', 'stylesheet_ux', 'tokens_ux', 'html_ux'];
    const sources = Object.fromEntries(names.map(name => [name, fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8')]));
    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)};
      const imports={'../design/notice':{notice(){}},'../design/icons':{brandMark:()=>'',icons:new Proxy({},{get:()=>()=>''})}};
      const cache={};
      function load(name){if(cache[name])return cache[name];const mod={exports:{}};new Function('module','exports','require',sources[name])(mod,mod.exports,n=>imports[n]||{});return cache[name]=mod.exports;}
      imports['./tokens']=load('tokens_ux');imports['../design/html']=load('html_ux');imports['../design/status_labels']=load('status_labels_ux');imports['../design/alerts']=load('alerts_ux');window.__alerts=imports['../design/alerts'];
      load('stylesheet_ux').injectStylesheet();
      load('layout_ux').renderLayout(document.body);
      window.A=load('attention_ux');
      window.mem={};window.memThrows=false;window.errors=[];window.opens=[];window.openOk=true;window.focused=true;window.natives=[];window.natObjs={};
      window.NotifyPermission='denied';
      window.FakeN=function(title,opts){window.natives.push({title,body:opts&&opts.body,tag:opts&&opts.tag});this.close=()=>{};window.natObjs[opts.tag]=this;};
      Object.defineProperty(window.FakeN,'permission',{get:()=>window.NotifyPermission});
      window.make=()=>{
        const c=new window.A.AttentionCenter({
          storage:()=>{if(window.memThrows)throw new Error('almacenamiento denegado');return {getItem:k=>window.mem[k]??null,setItem:(k,v)=>{window.mem[k]=v;}};},
          now:()=>Date.UTC(2026,9,19,14,5,0),isFocused:()=>window.focused,notification:()=>window.FakeN,
          openOrder:async(id,conv)=>{window.opens.push([id,conv]);return window.openOk;},onError:m=>window.errors.push(m)});
        return c;
      };
      window.center=window.make();
      window.tray=new window.A.AttentionTray(window.center,document.getElementById('btn-attention'));
    })()`);
    const S = (order_id, status_text, extra = {}) => ({ order_id, status_text, title: 'Tarea ' + order_id, ...extra });
    const observe = list => evaluate(`window.center.observe(${JSON.stringify(list)})`);
    const toasts = () => evaluate("[...document.querySelectorAll('#attention-toasts .attn-toast')].map(t => ({ order: t.dataset.order, event: t.dataset.event, role: t.getAttribute('role'), text: t.textContent }))");

    await step('el botón de la barra existe y arranca sin contador', async () => {
      assert.equal(await evaluate("!!document.querySelector('#btn-attention')"), true, 'layout trae #btn-attention');
      assert.equal(await evaluate("document.querySelector('#attention-count').hidden"), true);
      assert.equal(await evaluate("document.querySelector('#btn-attention').getAttribute('aria-label')"), 'Avisos: nada sin leer');
    });

    await step('la primera lectura es línea base: nada pendiente al arrancar avisa', async () => {
      await observe([S(1, 'running'), S(2, 'running'), S(3, 'running'), S(4, 'running'), S(9, 'clarifying'), S(8, 'done')]);
      assert.deepEqual(await toasts(), []);
      assert.equal(await evaluate('window.center.unreadCount()'), 0);
    });

    await step('por defecto: terminar y fallar no lanzan toast (11-nov); los dos quedan en la campana', async () => {
      const probe = await evaluate(`(async()=>{
        const mem={}; const c=new window.A.AttentionCenter({storage:()=>({getItem:k=>mem[k]??null,setItem:(k,v)=>{mem[k]=v;}}),
          now:()=>Date.UTC(2026,9,19,14,5,0),isFocused:()=>true,notification:()=>null,openOrder:async()=>true});
        const before=document.querySelectorAll('#attention-toasts .attn-toast').length;
        c.observe([{order_id:71,status_text:'running'},{order_id:72,status_text:'running'}]);
        c.observe([{order_id:71,status_text:'done'},{order_id:72,status_text:'failed'}]);
        const added=[...document.querySelectorAll('#attention-toasts .attn-toast')].slice(before).map(t=>t.dataset.event);
        document.querySelectorAll('#attention-toasts .attn-toast[data-order="71"],#attention-toasts .attn-toast[data-order="72"]').forEach(t=>t.remove());
        return {added, list:c.list().map(i=>i.event).sort()};
      })()`);
      assert.deepEqual(probe.added, [], 'el fallo de una orden no es un aviso de sistema');
      assert.deepEqual(probe.list, ['done', 'failed'], 'los dos quedan en la campana');
    });

    await step('un aviso por evento y orden: terminó, falló, pregunta, pide aprobación', async () => {
      // Con «Avisar cuando termine cada orden» activado (Configuración › Avisos).
      await evaluate("window.mem['devagents.notify.done.v1']='1'");
      await observe([S(1, 'done', { conversation_id: 'c-1' }), { order_id: 2, status: 6, title: 'Tarea 2' }, S(3, 'clarifying'), S(4, 'awaiting_approval'), S(9, 'clarifying'), S(8, 'done')]);
      const t = (await toasts()).sort((a, b) => a.order - b.order);
      assert.deepEqual(t.map(x => [x.order, x.event]), [['1', 'done'], ['3', 'question'], ['4', 'approval']], 'el fallo va solo a la campana');
      assert.deepEqual(t.map(x => x.role), ['status', 'status', 'status']);
      assert.match(t[0].text, /Orden #1 terminó/);
      assert.match(t[1].text, /Orden #3 te hace una pregunta/); assert.match(t[2].text, /Orden #4 pide aprobación/);
      assert.equal(await evaluate("(window.__alerts.activeAlertIds()).filter(id=>id.startsWith('attention:')).length"), 0, 'y nunca a la esquina');
      assert.equal(await evaluate('window.center.unreadCount()'), 4);
    });

    await step('el sondeo repite los mismos estados y no hay avisos duplicados', async () => {
      for (let i = 0; i < 3; i++) await observe([S(1, 'done'), { order_id: 2, status: 6 }, S(3, 'clarifying'), S(4, 'awaiting_approval'), S(9, 'clarifying'), S(8, 'done')]);
      assert.equal((await toasts()).length, 3);
      assert.equal(await evaluate('window.center.list().length'), 4);
      // Un estado que sale del conjunto y vuelve a entrar tampoco duplica la clave.
      await observe([S(1, 'done'), S(3, 'running')]); await observe([S(3, 'clarifying')]);
      assert.equal(await evaluate('window.center.list().length'), 4);
    });

    await step('contador y bandeja: orden, tipo y hora', async () => {
      assert.equal(await evaluate("document.querySelector('#attention-count').textContent"), '4');
      assert.equal(await evaluate("document.querySelector('#attention-count').hidden"), false);
      assert.equal(await evaluate("document.querySelector('#btn-attention').getAttribute('aria-label')"), 'Avisos: 4 sin leer');
      assert.equal(await evaluate("document.querySelector('#attention-tray').hidden"), true);
      await click('#btn-attention');
      assert.equal(await evaluate("document.querySelector('#attention-tray').hidden"), false);
      assert.equal(await evaluate("document.querySelector('#btn-attention').getAttribute('aria-expanded')"), 'true');
      const rows = await evaluate("[...document.querySelectorAll('#attention-list .attn-item')].map(r => ({ order: r.dataset.order, event: r.dataset.event, read: r.dataset.read, what: r.querySelector('.attn-item__what').textContent, time: r.querySelector('time').textContent, sub: r.querySelector('.attn-item__sub').textContent }))");
      assert.equal(rows.length, 4);
      const r4 = rows.find(r => r.order === '4');
      assert.equal(r4.what, 'Orden #4 · Pide aprobación'); assert.match(r4.time, /^\d{2}:\d{2}$/); assert.match(r4.sub, /Tarea 4/);
      assert.deepEqual(rows.map(r => r.read), ['false', 'false', 'false', 'false']);
    });

    await step('clic en una fila abre la orden exacta y la marca leída', async () => {
      await click('#attention-list .attn-item[data-order="3"]');
      assert.deepEqual(await evaluate('window.opens'), [[3, null]]);
      assert.equal(await evaluate("document.querySelector('#attention-count').textContent"), '3');
      assert.equal(await evaluate("document.querySelector('#attention-tray').hidden"), true, 'la bandeja se cierra al abrir');
      await click('#btn-attention');
      assert.equal(await evaluate("document.querySelector('#attention-list .attn-item[data-order=\"3\"]').dataset.read"), 'true');
      assert.equal(await evaluate("document.querySelector('#attention-list .attn-item[data-order=\"4\"]').dataset.read"), 'false');
      // Conserva el hilo de la orden: la 1 trae conversation_id.
      await click('#attention-list .attn-item[data-order="1"]');
      assert.deepEqual((await evaluate('window.opens')).at(-1), [1, 'c-1']);
    });

    await step('si la orden no se pudo abrir, sigue sin leer', async () => {
      await evaluate('window.openOk=false');
      await click('#btn-attention');
      await click('#attention-list .attn-item[data-order="2"]');
      assert.deepEqual((await evaluate('window.opens')).at(-1), [2, null]);
      assert.equal(await evaluate("document.querySelector('#attention-list .attn-item[data-order=\"2\"]').dataset.read"), 'false');
      assert.equal(await evaluate("document.querySelector('#attention-count').textContent"), '2');
      await evaluate('window.openOk=true');
    });

    await step('clic en el toast abre la orden y se retira', async () => {
      await click('#attention-toasts .attn-toast[data-order="4"] .attn-toast__open');
      assert.deepEqual((await evaluate('window.opens')).at(-1), [4, null]);
      assert.equal(await evaluate("document.querySelectorAll('#attention-toasts .attn-toast[data-order=\"4\"]').length"), 0);
      assert.equal(await evaluate('window.center.unreadCount()'), 1);
    });

    await step('persistencia de leídos por orden en localStorage y reinicio sin repetir avisos', async () => {
      const saved = JSON.parse(await evaluate("window.mem['devagents.attention.v1']"));
      assert.deepEqual(saved.items.map(i => [i.orderId, i.read]).sort(), [[1, true], [2, false], [3, true], [4, true]]);
      await evaluate("document.querySelectorAll('#attention-toasts .attn-toast').forEach(t => t.remove())");
      await evaluate('window.center2=window.make()');
      assert.equal(await evaluate('window.center2.unreadCount()'), 1);
      await evaluate("window.center2.observe([{order_id:1,status_text:'running'},{order_id:2,status_text:'running'}])");
      await evaluate("window.center2.observe([{order_id:1,status_text:'done'},{order_id:2,status_text:'failed'}])");
      assert.deepEqual(await toasts(), [], 'las claves guardadas no vuelven a avisar tras reiniciar');
      assert.equal(await evaluate('window.center2.list().length'), 4);
    });

    await step('almacenamiento denegado: no rompe, avisa por onError y sigue en memoria', async () => {
      await evaluate("window.memThrows=true;window.errors.length=0;window.center3=window.make()");
      await evaluate("window.center3.observe([{order_id:70,status_text:'running'}]);window.center3.observe([{order_id:70,status_text:'failed',title:'x'}])");
      assert.equal(await evaluate('window.center3.unreadCount()'), 1);
      assert(await evaluate('window.errors.length') >= 1, 'el fallo de almacenamiento se comunica');
      await evaluate('window.memThrows=false');
    });

    await step('notificación nativa: solo sin foco, con permiso, y respeta el ajuste', async () => {
      const fresh = () => evaluate("window.mem={'devagents.notify.done.v1':'1'};window.natives.length=0;window.opens.length=0;window.c=window.make();window.c.observe([{order_id:5,status_text:'running'},{order_id:6,status_text:'running'},{order_id:7,status_text:'running'},{order_id:8,status_text:'running'}]);0");
      const fire = list => evaluate(`window.c.observe(${JSON.stringify(list)})`);
      // Con foco: no hay nativa aunque haya permiso.
      await fresh(); await evaluate("window.focused=true;window.NotifyPermission='granted'");
      await fire([S(5, 'done')]); assert.equal(await evaluate('window.natives.length'), 0, 'con foco no hay nativa');
      // Sin foco y con permiso: una por evento.
      await evaluate('window.focused=false');
      await fire([S(5, 'done'), S(6, 'failed'), S(7, 'clarifying'), S(8, 'planned')]);
      const n = await evaluate('window.natives');
      assert.deepEqual(n.map(x => x.title).sort(), ['Orden #6 falló', 'Orden #7 te hace una pregunta', 'Orden #8 pide aprobación'].sort(), 'el 5 ya estaba avisado con foco; el resto, uno cada uno');
      assert.deepEqual(n.map(x => x.tag).sort(), ['6:failed', '7:question', '8:approval']);
      // La nativa abre la orden exacta al pulsarla.
      await evaluate("window.natObjs['8:approval'].onclick({})"); await wait(30);
      assert.deepEqual((await evaluate('window.opens')).at(-1), [8, null]);
      // Ajuste desactivado: sin nativa, pero toast sí.
      await fresh(); await evaluate("document.querySelectorAll('#attention-toasts .attn-toast').forEach(t => t.remove())");
      await evaluate('window.tray.toggle(true)');
      assert.equal(await evaluate("document.querySelector('#attention-native').checked"), true);
      assert.equal(await evaluate("document.querySelector('#attention-native').disabled"), false);
      assert.equal(await evaluate("document.querySelector('#attention-native-hint').textContent"), '');
      await evaluate('window.tray2=null');
      // El tray enlazado a window.center: se prueba el ajuste sobre ese centro.
      await evaluate("window.center.observe([{order_id:5,status_text:'running'}])");
      await click('#attention-native');
      assert.equal(await evaluate('window.center.nativeEnabled()'), false);
      assert.equal(JSON.parse(await evaluate("window.mem['devagents.attention.v1']")).native, false, 'el ajuste se persiste');
      await evaluate('window.natives.length=0');
      await evaluate("window.center.observe([{order_id:5,status_text:'done',title:'z'}])");
      assert.equal(await evaluate('window.natives.length'), 0, 'ajuste apagado: no hay nativa');
      assert.equal((await toasts()).length, 1, 'pero el toast sí sale');
      await click('#attention-native');
      assert.equal(await evaluate('window.center.nativeEnabled()'), true);
      // Host que deniega permisos (el actual): casilla deshabilitada y explicación; nunca se pide permiso.
      await evaluate("window.NotifyPermission='denied';window.tray.toggle(false);window.tray.toggle(true)");
      assert.equal(await evaluate("document.querySelector('#attention-native').disabled"), true);
      assert.match(await evaluate("document.querySelector('#attention-native-hint').textContent"), /no concede notificaciones/);
      await evaluate('window.natives.length=0');
      await evaluate("window.center.observe([{order_id:6,status_text:'running'}]);window.center.observe([{order_id:6,status_text:'failed'}])");
      assert.equal(await evaluate('window.natives.length'), 0, 'sin permiso del host solo hay toast');
    });

    await step('marcar todo como leído y Escape cierra la bandeja', async () => {
      await evaluate('window.tray.toggle(true)');
      assert(await evaluate('window.center.unreadCount()') > 0);
      await click('#attention-read-all');
      assert.equal(await evaluate('window.center.unreadCount()'), 0);
      assert.equal(await evaluate("document.querySelector('#attention-count').hidden"), true);
      await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
      await wait(40);
      assert.equal(await evaluate("document.querySelector('#attention-tray').hidden"), true);
    });

    await step('seguridad: un título hostil no genera elementos', async () => {
      await evaluate("window.center.observe([{order_id:99,status_text:'running'}]);window.center.observe([{order_id:99,status_text:'failed',title:'<img src=x onerror=1><script>1</script>'}]);window.tray.toggle(true)");
      assert.equal(await evaluate("document.querySelectorAll('#attention-tray img, #attention-tray script, #attention-toasts img, #attention-toasts script').length"), 0);
      assert.match(await evaluate("document.querySelector('#attention-list .attn-item[data-order=\"99\"] .attn-item__sub').textContent"), /<img src=x/);
    });

    await step('alertas de esquina (propietario 10-nov): un botón por color, agrupadas, con contador, y se retiran', async () => {
      const r = await evaluate(`(async()=>{
        const al=window.__alerts;
        const dots=()=>[...document.querySelectorAll('#devagents-alerts .da-alert')].map(g=>({level:g.dataset.level,count:g.querySelector('.da-alert-count').textContent,items:g.querySelectorAll('.da-alert-item').length}));
        al.raiseAlert({id:'t:e1',level:'error',title:'Fallo uno'});
        al.raiseAlert({id:'t:w1',level:'warn',title:'Aviso uno'});
        al.raiseAlert({id:'t:e2',level:'error',title:'Fallo dos'});
        al.raiseAlert({id:'t:e3',level:'error',title:'<img src=x onerror=1>'});
        const three=dots();
        const firstIsRed=document.querySelector('#devagents-alerts').firstElementChild.dataset.level;
        const hostile=document.querySelectorAll('#devagents-alerts img').length;
        document.querySelector('#devagents-alerts .da-alert[data-level="error"] .da-alert-item[data-alert-id="t:e1"] [data-alert-read]').click();
        const afterRead=dots();
        al.raiseAlert({id:'t:e1',level:'error',title:'Fallo uno'});
        const dismissedStays=al.activeAlertIds().includes('t:e1');
        al.clearAlert('t:w1');al.clearAlert('t:e2');al.clearAlert('t:e3');
        await new Promise(res=>setTimeout(res,250));
        return {three,firstIsRed,hostile,afterRead,dismissedStays,end:dots()};
      })()`);
      assert.deepEqual(r.three, [{ level: 'error', count: '3', items: 3 }, { level: 'warn', count: '', items: 1 }], 'rojo y ámbar a la vez; tres rojas en un solo botón');
      assert.equal(r.firstIsRed, 'error', 'el rojo queda en la esquina');
      assert.equal(r.hostile, 0, 'los textos no generan HTML');
      assert.deepEqual(r.afterRead, [{ level: 'error', count: '2', items: 2 }, { level: 'warn', count: '', items: 1 }], 'Entendido quita solo esa alerta');
      assert.equal(r.dismissedStays, false, 'una alerta leída no vuelve con el mismo texto');
      assert.deepEqual(r.end, [], 'sin alertas no queda ningún botón');
    });

    assert.deepEqual(browserErrors, [], 'sin excepciones en el navegador');
    assert.deepEqual(failures, [], ['Pruebas CK-COMP-011 en rojo:', ...failures].join(String.fromCharCode(10)));
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); }
    finally {
      if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
      fail(Error('Browser closed'));
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    }
  }
};

if (require.main === module) module.exports().catch(error => { console.error(error); process.exitCode = 1; });
