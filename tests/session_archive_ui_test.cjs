// — la barra de actividad con la barra lateral plegada.
//
// Bug: con `.sidebar[data-collapsed='true']`, pulsar `.activity-bar__item`
// cambiaba la vista pero la barra seguía en su franja plegada, así que parecía
// que no pasaba nada. Debe desplegarse mostrando ESE panel y persistir el
// estado con la misma clave de localStorage, icono y título que el botón de
// plegar; con la barra ya desplegada el comportamiento no cambia.
//
// DOM/CSS de producto en Chromium instalado; CoreApi sintética, sin host ni
// motor. Desde shell/webui: node tests/activity_collapse.test.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('./browser_resolver.cjs');

module.exports = async function sessionArchive() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-archivo-'));
  const executable = resolveBrowser();
  const html = path.join(profile, 'cab020.html');
  fs.writeFileSync(html, '<!doctype html><html lang="es"><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-sandbox', '--disable-gpu', '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map();
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
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 60000);
      pending.set(id, { resolve, reject, timer });
      child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  async function click(selector) {
    const point = await evaluate(`(() => {const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
    for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, ...point, button: 'left', clickCount: 1 });
  }
  // (c): «Archivar historial anterior…» y «Ver archivadas» viven en el menú
  // del botón único «Archivo» (maqueta v2): se abre como lo haría el usuario.
  async function archivo(selector) { await click('#sb-archive-menu'); await click(selector); }
  try {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await evaluate(fs.readFileSync(path.join(__dirname, '../shell/webui/dist/session_archive.browser.test.js'), 'utf8'));
    await evaluate(`(() => {
      document.body.innerHTML='<div id="sidebar-actions"></div><div id="sidebar-body"></div>';
      const today=new Date(); today.setHours(0,0,0,0);
      window.cutoff=Math.floor(today.getTime()/1000);
      window.calls=[];
      window.rows=[{id:1,title:'Antigua',status_text:'done',created_at:cutoff-100,archived_at:0},{id:2,title:'Archivada',status_text:'failed',created_at:cutoff-200,archived_at:100},{id:3,title:'Viva',status_text:'running',created_at:cutoff+10,archived_at:0}];
      const core={
        listSessions:async mode=>{calls.push(['list',mode]);return rows;},
        archiveSession:async(id,archived)=>{calls.push(['one',id,archived]);rows.find(r=>r.id===id).archived_at=archived?100:0;return {archived};},
        previewArchiveBefore:async before=>{calls.push(['preview',before]);return {count:1};},
        archiveBefore:async(before,count)=>{calls.push(['mass',before,count]);rows[0].archived_at=100;return {count:1};}
      };
      window.router=new SessionArchiveTest.ViewRouter(core);
      router.renderSessions(document.getElementById('sidebar-body'),document.getElementById('sidebar-actions'));
    })()`);
    const settle=()=>evaluate('new Promise(r=>setTimeout(r,50))');
    await settle();
    assert(await evaluate(`document.querySelector('[data-order="1"]')!==null && document.querySelector('[data-order="2"]')===null`),'CK-CAB-003 archivo barra oculta archivadas');
    console.log('PASS CK-CAB-003 archivo barra oculta archivadas');
    assert(await evaluate(`!document.querySelector('[data-archive="3"]')`),'CK-CAB-003 archivo no ofrece archivar viva');
    await archivo('#sb-show-archived'); await settle();
    assert(await evaluate(`document.querySelector('[data-order="2"]')!==null && document.querySelector('[data-order="1"]')===null`),'CK-CAB-003 archivo Ver archivadas');
    assert(await evaluate(`document.querySelector('[data-restore="2"]')!==null`));
    await evaluate("document.querySelectorAll('.sess-group__head[aria-expanded=\"false\"]').forEach(b=>b.click())"); await settle();
    await click('[data-restore="2"]'); await settle();
    assert(await evaluate(`calls.some(c=>c[0]==='one' && c[1]===2 && c[2]===false) && !document.querySelector('[data-order="2"]')`));
    console.log('PASS CK-CAB-003 archivo Ver archivadas y Restaurar');
    await archivo('#sb-show-archived'); await settle();
    await archivo('#sb-archive-before'); await settle();
    assert(await evaluate(`document.querySelector('[role="dialog"] input').value===new Date(cutoff*1000).getFullYear()+'-'+String(new Date(cutoff*1000).getMonth()+1).padStart(2,'0')+'-'+String(new Date(cutoff*1000).getDate()).padStart(2,'0')`));
    assert(await evaluate(`!calls.some(c=>c[0]==='mass')`));
    await click('[role="dialog"] button:last-child'); await settle();
    assert(await evaluate(`document.querySelector('[role="dialog"]').textContent.includes('1 sesión')`),'recuento previo visible');
    assert(await evaluate(`document.activeElement.textContent==='Cancelar' && !calls.some(c=>c[0]==='mass')`),'cancelar tiene foco; aún no hay mutación');
    await click('[role="dialog"] button:first-child'); await settle();
    assert(await evaluate(`!calls.some(c=>c[0]==='mass')`));
    await archivo('#sb-archive-before'); await settle();
    await click('[role="dialog"] button:last-child'); await settle();
    await click('[role="dialog"] button:last-child'); await settle();
    assert(await evaluate(`calls.filter(c=>c[0]==='mass').length===1 && calls.find(c=>c[0]==='mass')[1]===cutoff && calls.find(c=>c[0]==='mass')[2]===1`));
    console.log('PASS CK-CAB-003 archivo confirmación masiva explícita con recuento y corte de hoy');
    // (c): los grupos de fecha son plegables y solo el primero arranca abierto;
    // se despliegan como lo haría el usuario antes de pulsar una fila de otro grupo.
    await evaluate("document.querySelectorAll('.sess-group__head[aria-expanded=\"false\"]').forEach(b=>b.click())"); await settle();
    await click('[data-archive="2"]'); await settle();
    assert(await evaluate(`calls.some(c=>c[0]==='one' && c[1]===2 && c[2]===true)`));
    await archivo('#sb-show-archived'); await settle();
    console.log('TEXTO DOM SINTÉTICO: '+await evaluate('document.body.innerText'));
    if(process.env.DEVAGENTS_ARCHIVE_EVIDENCE){
      const dir=process.env.DEVAGENTS_ARCHIVE_EVIDENCE;
      fs.writeFileSync(path.join(dir,'archivo-dom-sol.txt'),await evaluate('document.body.innerText'));
      const shot=await send('Page.captureScreenshot',{format:'png'});
      fs.writeFileSync(path.join(dir,'archivo-dom-sol.png'),Buffer.from(shot.data,'base64'));
    }
    console.log('PASS CK-CAB-003 archivo clic individual y lista vacía conserva interruptor');
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
