// DOM/CSS de producto en Chromium instalado; CoreApi sintética, sin host ni proveedores.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { build } = require('esbuild');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

async function run() {
  const tempRoot = path.resolve(__dirname, '../../../.zig-cache/cab031-tmp');
  fs.mkdirSync(tempRoot, {recursive:true});
  const profile = fs.mkdtempSync(path.join(tempRoot, 'beats-cab031-'));
  const executable = resolveBrowser();
  const fixture = path.join(profile, 'settings.html');
  fs.writeFileSync(fixture, '<!doctype html><html lang="es"><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-sandbox', '--disable-gpu', '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', sequence = 0, session, stderr = '';
  const pending = new Map();
  const errors = [];
  const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
  child.stderr.on('data', data => { stderr += data; });
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails);
      const request = pending.get(message.id);
      if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
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
  async function settled() {
    await evaluate(`new Promise((resolve,reject)=>{let tries=0;const poll=()=>{const b=document.querySelector('#settings-body');if(b?.getAttribute('aria-busy')==='false')resolve();else if(++tries>200)reject(Error('Sección no termina de cargar'));else setTimeout(poll,10)};poll()})`);
  }
  async function open(section) {
    await evaluate(`document.querySelector('[data-section="${section}"]').click()`);
    await settled();
  }
  async function action(expression, method) {
    await evaluate(`window.calls=[];${expression}`);
    await evaluate('new Promise(resolve=>setTimeout(resolve,50))');
    assert(await evaluate(`window.calls.some(call=>call.method===${JSON.stringify(method)})`), `ACTION ${method} no llega al CoreApi sintético`);
  }
  const stubbed = {
    './version_check': 'export async function checkVersion(){return true}',
    './bridge/core_api': 'export class CoreApi { constructor(){return window.fixtureCore} }',
    './bridge/client': `export class BridgeClient {onPush(){return ()=>{}} async send(method,args){window.fixtureBridge.push({method,args});return method==='core.models.list'?{payload:''}:{} }}`,
  };
  const generic = ['MonacoEditor','DiffViewer','VerificationPanel','CatalogSessionsPanel','McpPanel','IssuesPanel','HelpPanel','OnboardingModal','ConversationControl','UiActionDispatcher','XtermTerminal'];
  const genericSource = `export function previewHtml(){throw Error('previewHtml fuera del escenario CAB031')};class Stub {constructor(){return new Proxy(this,{get:(o,k)=>k in o?o[k]:(()=>undefined)})}};`+generic.map(n=>`export {Stub as ${n}}`).join(';');
  stubbed.mission = `import { MissionControlPanel as Real } from ${JSON.stringify(path.join(__dirname,'../src/panes/mission_control.ts'))};
    class Stub {isBusy(){return false}getActiveOrderId(){return window.fixtureOrderId}refreshStatus(){}setMode(){}async loadSession(){}setSlashExtras(){} }
    class Instrumented extends Real { constructor(...args){super(...args);window.fixtureMission=this;} }
    export const MissionControlPanel = location.search.includes('vg2=1') ? Instrumented : Stub;`;
  const irrelevant = /(?:monaco_editor|diff_viewer|verification_panel|catalog_sessions|mcp_panel|issues_panel|onboarding_help|conversation_control|ui_actions|xterm_terminal)$/;
  // El empaquetado también puede fallar: ya hay un navegador que cerrar.
  try {
  const compiled = await build({entryPoints:[path.join(__dirname,'../src/main.ts')],bundle:true,write:false,format:'iife',platform:'browser',plugins:[{name:'native-fixtures',setup(b){
    b.onResolve({filter:/.*/},args=>{
      if(stubbed[args.path]&&args.importer.endsWith('main.ts'))return {path:args.path,namespace:'fixture'};
      if(args.path==='./panes/mission_control'&&args.importer.endsWith('main.ts'))return {path:'mission',namespace:'fixture'};
      if(irrelevant.test(args.path))return {path:'generic',namespace:'fixture'};
    });
    b.onLoad({filter:/.*/,namespace:'fixture'},args=>({contents:args.path==='generic'?genericSource:stubbed[args.path],loader:'js',resolveDir:path.join(__dirname,'../src')}));
  }}]});
  const bundle=compiled.outputFiles[0].text;
  const failures=[];
  async function capture(name){
    if(!process.env.CAB031_EVIDENCE)return;
    const prefix=path.join(process.env.CAB031_EVIDENCE,name);
    fs.writeFileSync(prefix+'.txt','FIXTURE SINTÉTICO. Host y motor doblados.\n'+await evaluate('document.body.innerText'));
    const shot=await send('Page.captureScreenshot',{format:'png'});
    fs.writeFileSync(prefix+'.png',Buffer.from(shot.data,'base64'));
  }
  async function section(name,fn){
    if(process.env.CAB031_ONLY&&!name.startsWith(process.env.CAB031_ONLY+' '))return;
    try{await fn();if(!name.startsWith('7 VG2'))await capture('fixture-'+name[0]);console.log('PASS '+name)}
    catch(e){failures.push(name+': '+e.message);console.error('FAIL '+name+': '+e.stack)}
  }
  const pause=()=>evaluate('new Promise(r=>setTimeout(r,80))');
  async function click(selector){
    assert(await evaluate(`!!document.querySelector(${JSON.stringify(selector)})`),'Control real existe: '+selector);
    await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'center'})`); await pause();
    const point=await evaluate(`(()=>{const e=document.querySelector(${JSON.stringify(selector)}),r=e.getBoundingClientRect();if(!r.width||!r.height)throw Error('Control oculto');return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    for(const type of ['mousePressed','mouseReleased'])await send('Input.dispatchMouseEvent',{type,...point,button:'left',clickCount:1});
    await pause();
  }
  async function boot(query=''){
    const {targetId}=await send('Target.createTarget',{url:pathToFileURL(fixture).href+query},undefined);
    session=(await send('Target.attachToTarget',{targetId,flatten:true},undefined)).sessionId;
    await send('Runtime.enable');
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
    await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
    await evaluate(`(()=>{
      localStorage.clear();localStorage.setItem('devagents.onboarded','1');
      window.fixtureBridge=[];window.fixtureCalls=[];window.fixtureRoot='C:/fixture/Proyecto-31';window.fixtureRemote=false;window.fixtureQuota=0;window.fixtureApprovalError=false;window.fixtureOrderId=31;
      window.fixtureApprovals=[{id:310,order_id:31,description:'CAB031 aprobar script',command_prefix:'worktree_script',args_json:'{}'}];
      window.fixtureIntervals=[];window.setInterval=(fn,ms)=>{window.fixtureIntervals.push({fn,ms});return window.fixtureIntervals.length};window.clearInterval=()=>{};
      // chrome --headless=new reporta document.hidden=true; la cabina simulada esta visible.
      Object.defineProperty(document,'hidden',{configurable:true,get:()=>false});
      window.fixtureCore=new Proxy({}, {get:(_,method)=>async(...args)=>{
        window.fixtureCalls.push({method,args});
        if(method==='pendingApprovals'&&window.fixtureMonitorGate)await window.fixtureMonitorGate;
        if(method==='controlProcess')return args[0]==='stop'?{state:'stopped'}:{state:'running',log:{text:'vg2 salida',more:false}};
        if(method==='listDir'&&window.fixtureRootError)throw Error('CAB031 raíz inaccesible');
        if(method==='remoteStatus'&&window.fixtureRemoteError)throw Error('CAB031 remoto inaccesible');
        if(method==='pendingApprovals'&&window.fixtureApprovalError)throw Error('CAB031 cola inaccesible');
        if(method==='resolveApproval'){window.fixtureApprovals=window.fixtureApprovals.filter(r=>r.id!==args[0]);return {}}
        const values={listDir:{root:window.fixtureRoot,entries:[]},gitBranch:{isRepo:true,branch:'fixture'},gitStatus:{isRepo:true,files:[]},remoteStatus:{running:window.fixtureRemote,url:'',pid:0},
          listSessions:[],listProviders:[],listKeys:[],listArtifacts:[],pendingApprovals:window.fixtureApprovals,health:[],specialists:[],ledger:[],modelScores:[],evolution:{},
          status:{version:'0.1.0-fixture',workspaceRoot:window.fixtureWorkspaceRoot ?? window.fixtureRoot,engineReady:true,pid:31,providerCount:0,keyCount:0,governanceMode:'hybrid'},catalogInfo:{model_count:0},getGovernance:{mode:'hybrid'},getBudget:{authorized:0},getUsageWeek:{},
          listWebhooks:[],plugins:[],pluginsDir:{path:'C:/fixture/plugins'},skills:[],mounts:[],memoryContext:{},getPlanModel:{provider:'',model:''},getModelSelection:[],
          getCliQuotas:[{cli:'codex',format:'fixture',five_hour:{used_percent:window.fixtureQuota,reset_at:null},daily:{used_percent:null,reset_at:null},weekly:{used_percent:null,reset_at:null}}],
          pickWorkspace:{cancelled:true}};
        if(!(method in values))throw Error('CoreApi fixture sin preparar: '+String(method));return values[method];
      }});
      window.settingsSubscriptions=0;const add=document.addEventListener.bind(document);document.addEventListener=(name,...args)=>{if(name==='devagents:settings-section')window.settingsSubscriptions++;return add(name,...args)};
    })()`);
    await evaluate(bundle);
    await evaluate("document.dispatchEvent(new Event('DOMContentLoaded'))");
    await pause();
    assert(await evaluate('!!window.router'),'main inicializado');
    return session;
  }
    const primary=await boot();
    await section('1 titulo usa Entorno, se actualiza y no inventa selector',async()=>{
      assert.equal(await evaluate("document.querySelector('#project-name').textContent"),'Proyecto-31');
      assert.equal(await evaluate("document.querySelector('#space-selector')"),null);
      await evaluate("window.fixtureRoot='C:/fixture/'+ 'Proyecto-muy-largo-'.repeat(15);window.rightCards.refreshEnvironment()");await pause();
      assert(await evaluate("document.querySelector('#project-name').getBoundingClientRect().right<document.querySelector('#btn-attention').getBoundingClientRect().left"),'nombre largo no desplaza controles de ventana');
      await evaluate('window.fixtureRootError=true;window.rightCards.refreshEnvironment()');await pause();
      assert.equal(await evaluate("document.querySelector('#project-name').textContent"),'—','no presenta un proyecto obsoleto al fallar');
      await evaluate("window.fixtureRootError=false;window.fixtureRoot='C:/fixture/Segundo <proyecto>';window.rightCards.refreshEnvironment()");await pause();
      assert(await evaluate("document.querySelector('#project-name').textContent===document.querySelector('.rc-env__name').textContent&&document.querySelector('#project-name').textContent==='Segundo <proyecto>'&&!document.querySelector('#project-name script')"));
    });
    await section('2 campana incluye cola inicial, clic llega a Monitor y resuelve',async()=>{
      assert.equal(await evaluate("document.querySelector('#attention-count').textContent"),'1');
      await click('#btn-attention');
      await capture('fixture-2-pendientes');
      assert(await evaluate("document.querySelector('#attention-list').innerText.includes('CAB031 aprobar script')"));
      // La cabina real recibe las lecturas del Monitor después del clic y
      // puede encolar otro refresco antes de que termine el primero.
      await evaluate('window.fixtureMonitorGate=new Promise(r=>window.releaseMonitor=r);true');
      await click('#attention-list [data-key="engine-approval:310"]');
      assert.equal(await evaluate('window.router.getCurrent()'),'monitor');
      assert.equal(await evaluate(`!!document.querySelector('[data-approve="310"]')`),false,'Monitor aún espera la lectura nativa');
      await evaluate('window.fixtureIntervals.filter(i=>i.ms===5000).at(-1).fn();window.fixtureMonitorGate=null;window.releaseMonitor()');await pause();
      assert(await evaluate(`!!document.querySelector('[data-approve="310"]')`));
      assert.equal(await evaluate('document.activeElement.dataset.approve'),'310','solicitud enfocada tras cargar Monitor');
      await evaluate('window.fixtureIntervals.filter(i=>i.ms===5000).at(-1).fn()');await pause();
      assert.equal(await evaluate('document.activeElement.dataset.approve'),'310','auto-refresco conserva foco de la solicitud');
      // R3: en la cabina real el repintado DURANTE loading (startAutoRefresh
      // o refresh encolado) destruye el botón enfocado mientras los datos
      // viejos siguen en this.approvals. El foco no debe perderse en ese
      // repintado intermedio: si la fila sigue en el DOM, se re-enfoca.
      await evaluate('window.fixtureMonitorGate=new Promise(r=>window.releaseMonitor2=r);void window.monitorPanel.refresh();true');
      await pause(30);
      assert.equal(await evaluate('document.activeElement.dataset.approve'),'310','foco se conserva en el repintado intermedio durante loading');
      await evaluate('window.fixtureMonitorGate=null;window.releaseMonitor2()');await pause();
      assert.equal(await evaluate('document.activeElement.dataset.approve'),'310','foco tras completar el refresco en vuelo');
      // R4 (el segundo auditor lote AD P2): una actualización quita la fila enfocada, el
      // usuario mueve el foco a otro control del Monitor y otra
      // actualización devuelve la fila: el Monitor no debe devolverle por
      // sorpresa el foco a esa solicitud.
      await evaluate('window.fixtureApprovals=[];window.fixtureIntervals.filter(i=>i.ms===5000).at(-1).fn()');await pause();
      await click('#mon-auto');
      assert.notEqual(await evaluate('document.activeElement.dataset.approve'),'310','otro control del Monitor mantiene el foco del usuario una vez perdida la fila');
      await evaluate("window.fixtureApprovals=[{id:310,order_id:31,description:'CAB031 aprobar script',command_prefix:'worktree_script',args_json:'{}'}];window.fixtureIntervals.filter(i=>i.ms===5000).at(-1).fn()");await pause();
      assert.notEqual(await evaluate('document.activeElement.dataset.approve'),'310','la fila que vuelve no roba el foco que el usuario movió');
      await click('#mon-refresh');
      assert.notEqual(await evaluate('document.activeElement.dataset.approve'),'310','refresco no devuelve el foco a una solicitud que el usuario dejó');
      await click('#btn-attention');await click('#attention-list [data-key="engine-approval:310"]');
      assert.equal(await evaluate('document.activeElement.dataset.approve'),'310','solicitud enfocada si Monitor ya estaba abierto');
      await click('[data-reject="310"]');
      assert(await evaluate("window.fixtureCalls.some(c=>c.method==='resolveApproval'&&c.args[0]===310&&c.args[1]===false)"));
      await evaluate('Promise.all(window.fixtureIntervals.filter(i=>i.fn.name==="pollAttention").map(i=>i.fn()))');await pause();
      assert.equal(await evaluate("document.querySelector('#attention-count').hidden"),true);
      await evaluate(`window.fixtureApprovals=[null,{id:-1},{approval_id:311,description:'<script>CAB031</script>'},{id:311,description:'<script>CAB031</script>'}];Promise.all(window.fixtureIntervals.filter(i=>i.fn.name==="pollAttention").map(i=>i.fn()))`);await pause();
      await click('#btn-attention');
      assert.equal(await evaluate("document.querySelector('#attention-count').textContent"),'1','cola deduplicada y solo ids válidos');
      assert(await evaluate("document.querySelector('#attention-list').textContent.includes('Solicitud #311')&&!document.querySelector('#attention-list script')&&!document.querySelector('#attention-list').textContent.includes('Orden #0')"));
      assert.equal(await evaluate("document.querySelector('#attention-read-all').disabled"),true,'solo cola pendiente: no ofrecer marcar leído sin efecto');
      assert(await evaluate("document.querySelector('#btn-attention').getAttribute('aria-label').includes('aprobaciones pendientes')"));
      await click('#attention-read-all');
      assert.equal(await evaluate("document.querySelector('#attention-count').textContent"),'1','leer no resuelve una solicitud');
      await evaluate('window.fixtureApprovalError=true;Promise.all(window.fixtureIntervals.filter(i=>i.fn.name==="pollAttention").map(i=>i.fn()))');await pause();
      assert(await evaluate("document.querySelector('#attention-list [role=alert]').textContent.includes('CAB031 cola inaccesible')"),'fallo de cola visible');
      assert.equal(await evaluate("document.querySelector('#attention-count').textContent"),'1','error no finge cola vacía');
      await evaluate('window.fixtureApprovalError=false;window.fixtureApprovals=[];Promise.all(window.fixtureIntervals.filter(i=>i.fn.name==="pollAttention").map(i=>i.fn()))');await pause();
      assert.equal(await evaluate("document.querySelector('#attention-count').hidden"),true);
      await click('#btn-attention');
    });
    // (c): la cabina arranca en B (maqueta v2): con el panel abierto no hay franja de
    // iconos ni engranaje en la barra de título. Se llega a Agente con su botón de la barra de
    // pestañas (#mode-agent) y a Configuración desde el pie del panel (#sb-foot-settings).
    await section('3 remoto es enlace honesto, clic llega al ajuste y refleja estado',async()=>{
      await click('#mode-agent');
      assert.equal(await evaluate("document.querySelector('.rc-switch')"),null);
      assert.equal(await evaluate("document.querySelector('[data-rc-configure-remote]').textContent.trim()"),'Configurar control remoto');
      await click('[data-rc-configure-remote]');
      assert.equal(await evaluate('window.router.getCurrent()'),'settings');
      assert(await evaluate("!!document.querySelector('#remote-start')"));
      assert(!await evaluate("window.fixtureCalls.some(c=>c.method==='remoteStart'||c.method==='remoteStop')"));
      await evaluate('window.fixtureRemote=true;window.rightCards.refreshEnvironment()');await pause();
      assert.equal(await evaluate("document.querySelector('.rc-remote__state').textContent"),'Activado');
      await evaluate('window.fixtureRemoteError=true;window.rightCards.refreshEnvironment()');await pause();
      assert.equal(await evaluate("document.querySelector('.rc-remote__state').textContent"),'Desconocido','error no conserva un estado viejo');
      await evaluate('window.fixtureRemoteError=false;window.rightCards.refreshEnvironment()');await pause();
    });
    await section('4 indices de catorce secciones iguales, un oyente y una seleccion',async()=>{
      // El índice lateral de Configuración es de A · IDE clásica; en B el índice son las pestañas.
      await evaluate("document.dispatchEvent(new CustomEvent('devagents:set-layout',{detail:'A'}))");await pause();
      await click('#act-settings');
      assert.equal(await evaluate('window.settingsSubscriptions'),1);
      const lists=await evaluate(`({side:[...document.querySelectorAll('#sidebar-body [data-settings-section]')].map(e=>e.dataset.settingsSection),tabs:[...document.querySelectorAll('#settings-tabs [data-section]')].map(e=>e.dataset.section)})`);
      assert.equal(lists.side.length,14);assert(lists.side.includes('rules')&&lists.side.includes('accounts'),'T7: Reglas del proyecto y Cuentas de CLI en el índice');assert.deepEqual(lists.side,lists.tabs);
      await evaluate('window.sectionRenders=0;const orig=window.settingsPanel.showSection.bind(window.settingsPanel);window.settingsPanel.showSection=s=>{window.sectionRenders++;return orig(s)}');
      await click('#sidebar-body [data-settings-section="remote"]');
      assert.equal(await evaluate('window.sectionRenders'),1);
      assert(await evaluate("!!document.querySelector('#remote-start')"));
      // Un solo índice en A (petición del propietario): el interno no se ve; se acciona por programa.
      assert.equal(await evaluate("document.querySelector('#settings-tabs').getBoundingClientRect().width"),0,'En A el índice interno de Configuración se oculta');
      await evaluate("document.querySelector('#settings-tabs [data-section=\"plugins\"]').click()");await pause();
      assert.equal(await evaluate("document.querySelector('#sidebar-body [aria-current=page]')?.dataset.settingsSection"),'plugins');
      await evaluate("document.dispatchEvent(new CustomEvent('devagents:set-layout',{detail:'B'}))");await pause();
    });
    await section('5 clic popout real llega al puente y secundaria monta la Conversación visible',async()=>{
      // 10-nov: dentro de Configuración no se ve la franja Agente/Dev; se sale con su «×».
      if(await evaluate("document.documentElement.dataset.view==='settings'")){await click('#btn-settings-close');assert.notEqual(await evaluate('document.documentElement.dataset.view'),'settings','la × cierra Configuración');}
      await click('#mode-agent');
      await click('[data-rc-action="activity"]');
      await click('#chat-btn-popout');
      await click('#chat-btn-collapse');
      const request=await evaluate("window.fixtureBridge.find(c=>c.method==='window.open')");
      assert.deepEqual(request,{method:'window.open',args:{vista:'conversacion',order_id:31}});
      try { await boot('?ventana=31&vista=conversacion&order=31');
      assert(await evaluate("!!document.querySelector('#ventana-unica #pane-mission-container')&&!document.querySelector('#ventana-unica #panel-secondary')&&!document.querySelector('.ventana-unica--vacia')"),'la secundaria monta la conversación real, no Actividad ni un hueco');
      assert(await evaluate("(()=>{const e=document.querySelector('#ventana-unica #pane-mission-container'),s=getComputedStyle(e);return s.display!=='none'&&e.getBoundingClientRect().width>0})()"),'pane-mission-container visible');
      assert(await evaluate("!document.querySelector('#ventana-unica #chat-btn-popout')"),'el popout real del chat no aparece en la secundaria (su panel es panel-secondary)');
      await evaluate("(()=>{const b=document.createElement('button');b.id='chat-btn-popout';b.title='Abrir en ventana nueva (fixture CAB032)';b.dataset.cab032Fixture='1';b.textContent='fixture';document.querySelector('#ventana-unica').appendChild(b)})()");
      await pause();
      assert(await evaluate("(()=>{const e=document.querySelector('#ventana-unica #chat-btn-popout[data-cab032-fixture=\"1\"]');return !!e&&getComputedStyle(e).display==='none'})()"),'fixture #chat-btn-popout existe dentro de la secundaria y el observer lo oculta');
      assert.equal(await evaluate("getComputedStyle(document.querySelector('#panel-bottom')).display"),'none','la ventana de conversación no revela una terminal plegada');
      assert(await evaluate("document.querySelector('#pane-mission-container').getBoundingClientRect().width>=innerWidth-1"),'la conversación ocupa el ancho de su ventana');
      await send('Emulation.setDeviceMetricsOverride',{width:1024,height:800,deviceScaleFactor:1,mobile:false});
      assert(await evaluate("document.querySelector('#pane-mission-container').getBoundingClientRect().width>=innerWidth-1"),'la conversación ocupa el ancho incluso en breakpoint estrecho');
      await capture('fixture-5-secundaria');
      } finally { session=primary; }
    });
    await section('6 sin huerfanos, aviso CLI visible, ocho destinos y cambio carpeta visible',async()=>{
      for(const [file,event] of [['../src/main.ts','devagents:open-path'],['../src/panes/right_cards.ts','devagents:space-changed'],['../src/components/cli_quota.ts','devagents:cli-quota-warning']])assert(!fs.readFileSync(path.join(__dirname,file),'utf8').includes(event),'evento huérfano retirado '+event);
      await evaluate('window.fixtureQuota=95;Promise.all(window.fixtureIntervals.filter(i=>i.ms===30000).map(i=>i.fn()))');await pause();
      assert(await evaluate("document.querySelector('#beats-notices')?.innerText.includes('Codex: cuota de 5 h al 95 %')"));
      const commands=await evaluate('window.commandPalette.commands.filter(c=>c.id.startsWith("view.")).map(c=>c.id)');
      assert.deepEqual(commands.sort(),['agent','explorer','settings','mcp','monitor','search','spaces','issues'].map(v=>'view.'+v).sort());
      for(const view of ['agent','explorer','settings','mcp','monitor','search','spaces','issues']){
        await click('#btn-command-palette');
        await evaluate(`document.querySelector('#cmd-palette-input').value=${JSON.stringify('Ir a: ')};document.querySelector('#cmd-palette-input').dispatchEvent(new Event('input',{bubbles:true}))`);
        const index=await evaluate(`window.commandPalette.filteredCommands.findIndex(c=>c.id==='view.${view}')`);
        await click('#cmd-palette-list .cmd-item:nth-child('+(index+1)+')');
        assert.equal(await evaluate('window.router.getCurrent()'),view);
      }
      await click('#mode-agent');await click('[data-rc-change-workspace]');
      assert(await evaluate("window.fixtureCalls.some(c=>c.method==='pickWorkspace')"));
    });
    await section('7 VG2 carpeta sin autorización, fallo de Ejecutar y control del proceso en tarjeta',async()=>{
      await boot('?vg2=1');
      await evaluate("window.fixtureWorkspaceRoot='';window.fixtureIntervals.find(i=>i.fn.name==='syncStatus')?.fn();Promise.all(window.fixtureIntervals.filter(i=>i.ms===5000).map(i=>i.fn()))");await pause();
      assert(await evaluate("document.querySelector('.workspace-warning')?.hidden===false"));
      await capture('VG2-ui-carpeta');
      await click('.workspace-warning button');
      assert(await evaluate("window.fixtureCalls.some(c=>c.method==='pickWorkspace')"));
      await evaluate(`(() => {
        window.fixtureRootError=true;
        window.fixtureWorkspaceRoot=window.fixtureRoot;
        document.dispatchEvent(new CustomEvent('devagents:workspace-changed'));
        const mission=window.fixtureMission;
        mission.activityOpen=true;
        mission.phase='running';
        mission.events=[
          {id:11,kind:'file_written',ts:1,payload_json:JSON.stringify({file_path:'C:/fixture/Proyecto-31/reloj.py',task_id:'vg2'})},
          {id:12,kind:'native_tool_result_v1',ts:2,payload_json:JSON.stringify({tool_name:'run_command',task_id:'vg2',process_id:'vg2-fixture',lease_generation:2,state:'running',background:true,ok:true,exe:'python'})}
        ];
        if(!mission.container.querySelector('#mission-events')){
          const activity=document.createElement('div');activity.id='mission-events';mission.container.prepend(activity);
        }
        mission.container.querySelector('#mission-events').style.maxWidth='760px';
        mission.paintEvents();
      })()`);
      await click('#mission-events [data-ejecutar]');
      assert.match(await evaluate("document.querySelector('#mission-events [data-ejecutar]').parentElement.querySelector('[data-run-status]').textContent"),/CAB031 raíz inaccesible/, JSON.stringify(await evaluate("window.fixtureCalls.slice(-8)")));
      await capture('VG2-ui-ejecutar');
      await click('[data-process-action="logs"]');
      assert.match(await evaluate("document.querySelector('[data-process-card]').innerText"),/vg2 salida/);
      await capture('VG2-ui-salida');
      await click('[data-process-action="stop"]');
      assert(await evaluate("document.querySelector('[data-process-action=stop]').disabled"));
      assert.match(await evaluate("document.querySelector('[data-process-card]').innerText"),/Proceso detenido/);
      await capture('VG2-ui-detenido');
    });
    assert.deepEqual(errors,[],'sin excepciones de Chromium');
    assert.equal(failures.length,0,failures.join('\n'));
    console.log('PASS CAB031: main, layout, router, tarjetas, ajustes, campana, Monitor, chat y paleta reales; motor/host sintéticos; cabina pendiente');
  }finally{
    try{if(child.exitCode===null)await send('Browser.close',{},undefined)}finally{
      if(child.exitCode===null)await new Promise(r=>{child.once('exit',r);setTimeout(()=>{if(child.exitCode===null)child.kill()},3000).unref()});
      fail(Error('Browser closed'));
      // El perfil pertenece exclusivamente a esta prueba.
      fs.rmSync(profile,{recursive:true,force:true,maxRetries:10,retryDelay:200});
    }
  }
}
module.exports=run;
if(require.main===module)run().catch(error=>{console.error(error);process.exitCode=1});
