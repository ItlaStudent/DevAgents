let failed = 0;
function assert(name, condition, detail) {
  if (condition) console.log(`  ok: ${name}`);
  else {
    failed += 1;
    console.error(`  FAIL: ${name}${detail ? ` -> ${detail}` : ''}`);
  }
}

class FakeElement {
  constructor() { this.style = {}; this.innerHTML = ''; this.children = []; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  addEventListener() {}
  setAttribute() {}
  appendChild(child) { this.children.push(child); return child; }
  remove() {}
  get childElementCount() { return this.children.length; }
  get firstElementChild() { return this.children[0] || null; }
}

const missionBody = new FakeElement();
const missionContainer = new FakeElement();
missionContainer.querySelector = (selector) => selector === '#mission-body' ? missionBody : null;
const storage = new Map();
global.document = {
  dispatchEvent() {},
  addEventListener() {},
  querySelector() { return null; },
  getElementById() { return null; },
  createElement() { return new FakeElement(); },
  body: new FakeElement(),
};
global.window = {
  requestAnimationFrame(fn) { fn(); },
  setInterval() { return 1; },
  clearInterval() {},
  setTimeout() {},
  localStorage: { getItem(key) { return storage.get(key) ?? null; }, setItem(key, value) { storage.set(key, String(value)); } },
};
global.localStorage = global.window.localStorage;
global.requestAnimationFrame = (fn) => fn();

const { CatalogSessionsPanel } = require('../shell/webui/dist/catalog_sessions.repair.test.cjs');
const { MissionControlPanel } = require('../shell/webui/dist/mission_control.repair.test.cjs');
const { ChatPanel } = require('../shell/webui/dist/chat_panel.repair.test.cjs');
const { artifactAction } = require('../shell/webui/dist/file_runtime.repair.test.cjs');

const catalogList = new FakeElement();
const sessionsList = new FakeElement();
let replayListener;
sessionsList.querySelectorAll = () => [{
  getAttribute: (name) => name === 'data-id' ? '416' : 'conv-mtj8xolw-8vkgrk',
  addEventListener: (_kind, listener) => { replayListener = listener; },
}];
const catalogHost = new FakeElement();
catalogHost.querySelector = (selector) => selector === '#catalog-list' ? catalogList : selector === '#sessions-list' ? sessionsList : null;
const catalog = new CatalogSessionsPanel(catalogHost);
let replayed = [];
catalog.setOnReplaySession((id, conversationId) => { replayed = [id, conversationId]; });
catalog.setSessions([{ id: '416', title: '<b id="hostile">orden</b>', messageCount: 0, updatedAt: '', conversationId: 'conv-mtj8xolw-8vkgrk' }]);
replayListener();
assert('CatalogSessions renderiza el título como texto escapado', !sessionsList.innerHTML.includes('<b id='), sessionsList.innerHTML);
assert('Replay del componente real entrega id y conversation_id', replayed[0] === '416' && replayed[1] === 'conv-mtj8xolw-8vkgrk', JSON.stringify(replayed));

const changesHost = new FakeElement();
changesHost.querySelectorAll = () => [];
const changesBox = new FakeElement();
const rightPanel = Object.create(ChatPanel.prototype);
rightPanel.container = { querySelector: (selector) => selector === '#chat-changes-list' ? changesHost : selector === '#chat-changes' ? changesBox : null };
rightPanel.changed = new Map([['C:\\web\\app.js', 'file_written'], ['C:\\cli\\report.js', 'file_written'], ['C:\\misc\\unknown.js', 'file_written'], ['C:\\cli\\run.cmd', 'file_written']]);
rightPanel.artifactEvents = [
  { id: 1, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\app.js', content: 'document.querySelector("#app")' } },
  { id: 2, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\index.html', content: '<script src="app.js"></script>' } },
  { id: 3, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\cli\\report.js', content: 'require("fs")' } },
  { id: 4, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\misc\\unknown.js', content: 'const x = 1;' } },
  { id: 5, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\cli\\run.cmd', content: '@echo off' } },
];
rightPanel.renderChanges();
assert('panel derecho ofrece navegador y conserva abrir JavaScript DOM en editor', changesHost.innerHTML.includes('data-preview="C:\\web\\index.html"') && changesHost.innerHTML.includes('data-open="C:\\web\\app.js"') && !changesHost.innerHTML.includes('data-run="C:\\web\\app.js"'), changesHost.innerHTML);
assert('panel derecho conserva triángulo Node y bloquea JavaScript desconocido', changesHost.innerHTML.includes('data-run="C:\\cli\\report.js"') && !changesHost.innerHTML.includes('data-run="C:\\misc\\unknown.js"'), changesHost.innerHTML);
assert('panel derecho conserva el lanzamiento CMD con runner vacío válido', changesHost.innerHTML.includes('data-run="C:\\cli\\run.cmd"') && changesHost.innerHTML.includes('data-runner=""'), changesHost.innerHTML);

const harvested = Object.create(ChatPanel.prototype);
harvested.changed = new Map();
harvested.workers = new Map();
harvested.harvest({ kind: 'file_written', payload: { file_path: 'C:\\web\\app.js' } });
harvested.harvest({ kind: 'shell_command', payload: { file: 'app.js' } });
harvested.harvest({ kind: 'exec_skipped', payload: { file: 'C:\\web\\app.js' } });
harvested.harvest({ kind: 'task_started', payload: { task_id: 't1', provider: 'Cohere', model: 'model-a' } });
harvested.harvest({ kind: 'task_done', payload: { task_id: 't1', model_used: 'model-a' } });
harvested.harvest({ kind: 'task_audit', payload: { task_id: 1, provider: 'auditor', model: 'model-a' } });
assert('actividad no duplica archivos con metadatos del executor', harvested.changed.size === 1 && harvested.changed.get('C:\\web\\app.js') === 'file_written');
assert('ledger no inventa otro worker y conserva proveedor conocido', harvested.workers.size === 1 && harvested.workers.get('t1') === 'Cohere · model-a');

harvested.harvest({ kind: 'task_failed', payload: { task_id: 't2', provider: 'Cohere', model_used: 'deterministic' } });
harvested.harvest({ kind: 'task_failed', payload: { task_id: 't3', provider: 'Cohere', model_used: 'not-run' } });
assert('ejecutor local y tarea sin ejecutar no se atribuyen al proveedor', harvested.workers.get('t2') === 'Ejecutor local' && harvested.workers.get('t3') === 'Sin ejecutar');
harvested.harvest({ kind: 'task_done', payload: { task_id: 't1', provider: 'Otro', model_used: 'model-b' } });
assert('actividad conserva la atribución final cuando cambia el proveedor/modelo', harvested.workers.get('t1') === 'Otro · model-b');

const planActivity = Object.create(ChatPanel.prototype);
planActivity.elPlan = new FakeElement();
planActivity.currentPlan = {
  title: 'Plan propuesto',
  tasks: [{
    department: 'programación',
    contract_fields: [{ name: 'filename', value: 'app.js' }],
    description: 'Implementar una calculadora web con validación de división por cero, interfaz accesible, pruebas Node y los cuatro archivos requeridos por el criterio de aceptación.',
    depends_on: ['diseño'],
  }],
};
planActivity.orderPhase = 'awaiting-approval';
planActivity.renderPlan();
assert('actividad resume una tarea larga y deja el texto completo en detalle accesible', planActivity.elPlan.innerHTML.includes('<span>app.js</span>') && planActivity.elPlan.innerHTML.includes('plan-activity-summary') && planActivity.elPlan.innerHTML.includes('Ver detalle') && planActivity.elPlan.innerHTML.includes('depende de diseño') && planActivity.elPlan.innerHTML.includes('criterio de aceptación'), planActivity.elPlan.innerHTML);

const rewrittenDom = artifactAction([
  { id: 20, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\rewrite\\app.js', content: 'require("fs")' } },
  { id: 21, ts: 2, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\rewrite\\app.js', content: 'document.body.textContent = require("x");' } },
], 'C:\\rewrite\\app.js');
assert('última escritura DOM prevalece sobre runtime Node anterior', rewrittenDom.runner === null && !rewrittenDom.page, JSON.stringify(rewrittenDom));
const falseCompanion = artifactAction([
  { id: 22, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\app.js', content: 'require("fs")' } },
  { id: 23, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\sub\\index.html', content: '<script src="app.js"></script>' } },
  { id: 24, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\index.html', content: '<script src="app.js.map"></script>' } },
], 'C:\\web\\app.js');
assert('HTML de subcarpeta o app.js.map no pasa por compañero local', falseCompanion.runner === 'node' && !falseCompanion.page, JSON.stringify(falseCompanion));
const indirectBrowser = artifactAction([
  { id: 25, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\app.js', content: 'document.body.textContent = "ok";' } },
  { id: 26, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\index.html', content: '<script src="sub/app.js"></script><script src="../app.js"></script>' } },
], 'C:\\web\\app.js');
assert('DOM sin referencia HTML local exacta no abre página equivocada', indirectBrowser.runner === null && !indirectBrowser.page, JSON.stringify(indirectBrowser));

(async () => {
  const events = [{ id: 220, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\work\\index.html' } }];
  const activity = [];
  const core = {
    status: async () => ({ running: true, engineReady: true, keyCount: 1, initError: '' }),
    conversationMessages: async () => [],
    orderEvents: async () => events,
    orderStatus: async () => ({ status: 5 }),
    keepAwake: async () => {},
  };
  const mission = new MissionControlPanel(missionContainer, core, { onActivity: (kind, data) => activity.push([kind, data]) });
  await mission.loadSession(416, 'conv-mtj8xolw-8vkgrk');
  assert('loadSession conserva conversation_id GUI para la continuación', mission.conversationId === 'conv-mtj8xolw-8vkgrk', mission.conversationId);
  assert('loadSession rehidrata eventos aunque no existan mensajes persistidos', mission.events.length === 1, String(mission.events.length));
  assert('loadSession vuelve a publicar artefactos en actividad', activity.some(([kind, data]) => kind === 'events' && data.length === 1), JSON.stringify(activity));
  assert('centro de mando pinta el artefacto rehidratado', missionBody.innerHTML.includes('index.html'), missionBody.innerHTML);
  assert('sesión done reabierta recupera la fase done', mission.phase === 'done', mission.phase);
  assert('sesión done reabierta ofrece Enviar a GitHub', missionBody.innerHTML.includes('id="btn-ship"'), missionBody.innerHTML.slice(-300));

  const legacy = new MissionControlPanel(missionContainer, core);
  await legacy.loadSession(426);
  assert('sesión legacy sin conversation_id usa hilo posterior estable', legacy.conversationId === 'orden-426', legacy.conversationId);

  let resolveOld;
  const raceCore = {
    status: core.status,
    conversationMessages: (id) => id === 1 ? new Promise((resolve) => { resolveOld = resolve; }) : Promise.resolve([]),
    orderEvents: async (id) => [{ id, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: `C:\\work\\${id}.html` } }],
    orderStatus: core.orderStatus,
  };
  const race = new MissionControlPanel(missionContainer, raceCore);
  const oldLoad = race.loadSession(1, 'conv-old');
  // Simula una segunda apertura que ya pasó el guard de interfaz: el epoch
  // sigue impidiendo que la lectura lenta anterior reemplace la nueva.
  race.phase = 'idle';
  await race.loadSession(2, 'conv-new');
  resolveOld([]);
  await oldLoad;
  assert('carga vieja no pisa la sesión abierta después', race.conversationId === 'conv-new', race.conversationId);
  assert('carga vieja no reemplaza sus artefactos', race.events[0].id === 2, String(race.events[0].id));

  const errorCore = { status: core.status, conversationMessages: async () => [], orderEvents: async () => { throw new Error('events unavailable'); }, orderStatus: core.orderStatus };
  const errorMission = new MissionControlPanel(missionContainer, errorCore);
  await errorMission.loadSession(9, 'conv-error');
  assert('fallo de orderEvents queda visible como error de carga', errorMission.phase === 'error' && errorMission.errorText.includes('events unavailable'), errorMission.errorText);

  const plannedCore = { status: core.status, conversationMessages: async () => [{ role: 'user', content: 'crea el módulo' }], orderEvents: async () => [], orderStatus: async () => ({ status: 2 }), getPlan: async () => ({ tasks: [{ id: 't1', task_type: 'code', department: 'dev', description: 'crear', depends_on: [] }] }) };
  const planned = new MissionControlPanel(missionContainer, plannedCore);
  await planned.loadSession(33, 'conv-plan');
  assert('sesión planned reabierta muestra aprobación sin ejecutar', planned.phase === 'awaiting-approval' && planned.plan.tasks.length === 1, `${planned.phase}/${planned.plan?.tasks?.length}`);

  planned.events = [
    { id: 4, ts: 1, source: 'superagente', kind: 'planner_fallback', payload: { reason: 'mock_planner' } },
    { id: 5, ts: 2, source: 'core', kind: 'plan_edited', payload: {} },
  ];
  assert('evento durable plan_edited reemplaza la etiqueta de respaldo tras reabrir', planned.planTasksMarkup(planned.plan.tasks).includes('Plan inicial local, ajustado') && !planned.planTasksMarkup(planned.plan.tasks).includes('Se utilizó el plan de respaldo'), planned.planTasksMarkup(planned.plan.tasks));

  // CHAT-PD-1: estas comprobaciones vivían sobre `renderActionCards`, que la
  // divulgación progresiva sustituyó. Lo que garantizan no ha cambiado — un
  // bloqueo se ve, una herramienta dice su código de salida, una prueba sin
  // ejecutar no pasa por buena y un artefacto conserva su botón —, así que se
  // conservan enteras contra el renderizador nuevo.
  planned.events = [{ id: 5, ts: 1, source: 'governance', kind: 'governance_blocked_v1', payload: { reason: 'Free bloquea el modelo fijado o seleccionado; no se envio la solicitud' } }];
  assert('bloqueo de gobernanza queda visible entre los resultados', planned.renderActivity().includes('Free bloquea el modelo fijado'), planned.renderActivity());

  planned.events = [
    { id: 6, ts: 1, source: 'native-tools', kind: 'native_tool_session_stopped_v1', payload: { reason: 'Cancelada por el usuario durante la herramienta' } },
    { id: 7, ts: 1, source: 'native-tools', kind: 'native_tool_session_failed_v1', payload: { reason: 'La herramienta local rechazó el permiso' } },
  ];
  const nativeToolErrors = planned.renderActivity();
  assert('parada y fallo de herramientas nativas quedan visibles con su razón', nativeToolErrors.includes('La sesión de herramientas nativas se detuvo') && nativeToolErrors.includes('Cancelada por el usuario durante la herramienta') && nativeToolErrors.includes('La sesión de herramientas nativas falló') && nativeToolErrors.includes('La herramienta local rechazó el permiso'), nativeToolErrors);

  planned.events = [{ id: 8, ts: 1, source: 'native-tools', kind: 'native_tool_result_v1', payload: { tool_name: 'run_command', task_id: 't1', exit_code: 0, stdout: 'archivo creado', stderr: '', timed_out: false } }];
  const nativeToolSuccess = planned.renderActivity();
  assert('resultado nativo exitoso conserva stdout y no reclama atención', nativeToolSuccess.includes('run_command terminó correctamente') && nativeToolSuccess.includes('archivo creado') && !nativeToolSuccess.includes('var(--danger)'), nativeToolSuccess);

  planned.events = [{ id: 9, ts: 1, source: 'native-tools', kind: 'native_tool_result_v1', payload: { tool_name: 'run_command', task_id: 't2', exit_code: 2, stdout: 'salida parcial', stderr: 'permiso denegado', timed_out: false } }];
  const nativeToolFailure = planned.renderActivity();
  assert('resultado nativo fallido queda fijo con código, stdout y stderr', nativeToolFailure.includes('run_command terminó con código 2') && nativeToolFailure.includes('salida parcial') && nativeToolFailure.includes('permiso denegado'), nativeToolFailure);

  planned.events = [{ id: 10, ts: 1, source: 'native-tools', kind: 'native_tool_result_v1', payload: { tool_name: 'run_command', task_id: 't3', exit_code: 0, stdout: 'demasiado tarde', stderr: '', timed_out: true } }];
  assert('timeout nativo no anuncia éxito', planned.renderActivity().includes('run_command superó el tiempo límite') && !planned.renderActivity().includes('terminó correctamente'), planned.renderActivity());

  planned.events = [{ id: 30, ts: 1, source: 'planner', kind: 'planner_fallback', payload: { reason: 'mock_planner' } }];
  assert('plan de respaldo se identifica antes de aprobar', planned.planTasksMarkup([]).includes('Plan local del motor'), planned.planTasksMarkup([]));

  // Incidencia del prompt extenso: el plan local debe decir POR QUÉ no hubo
  // modelo, no solo «se usó el respaldo» — y nunca el código de máquina.
  planned.events = [{ id: 30, ts: 1, source: 'planner', kind: 'planner_fallback', payload: { reason: 'mock_planner', detail: 'no hay ningún proveedor con clave activa para planificar — configura una en Configuración' } }];
  const avisoLocal = planned.planTasksMarkup([]);
  assert('el aviso de plan local lleva la causa real del fallback', avisoLocal.includes('clave activa') && !avisoLocal.includes('mock_planner'), avisoLocal);

  // El prompt entero incrustado en understanding/descripción no debe ocupar la
  // pantalla: texto largo va plegado tras un extracto expandible.
  const ordenLarga = 'Orden: "'.padEnd(600, 'x') + '". Objetivo: programar.';
  const clamped = planned.clampedMarkup(ordenLarga);
  assert('un entendimiento largo se pliega tras un extracto', clamped.includes('clamp-details') && clamped.includes('ver completo') && !clamped.includes('summary class="card__subtitle">' + ordenLarga), clamped.slice(0, 300));
  const descLarga = planned.planTasksMarkup([{ id: 't1', task_type: 'code', department: 'dev', description: ordenLarga, depends_on: [] }]);
  assert('una descripción de tarea larga se pliega igual', descLarga.includes('clamp-details'), descLarga.slice(0, 200));
  const corta = planned.clampedMarkup('texto breve');
  assert('un texto breve NO se pliega', !corta.includes('clamp-details'), corta);
  planned.events = [{ id: 31, ts: 1, source: 'executor', kind: 'test_evidence_v1', payload: { task_id: 'qa', producer_task_id: 'app', producer_revision: '18ac02', command: 'node test_app.js', ran: true, exit_code: 1, stdout: '2+3=3', stderr: 'Expected 5', timed_out: false } }];
  const qaFailed = planned.renderActivity();
  assert('prueba funcional fallida visible con comando, revisión y salida real', qaFailed.includes('falló (código 1)') && qaFailed.includes('node test_app.js') && qaFailed.includes('18ac02') && qaFailed.includes('Expected 5'), qaFailed);
  planned.events[0].payload = { ...planned.events[0].payload, ran: false, exit_code: 0 };
  const qaNotRun = planned.renderActivity();
  assert('prueba sin ejecutar no es éxito aunque exit_code sea cero', qaNotRun.includes('sin ejecutar') && qaNotRun.includes('Sin ejecutar'), qaNotRun);
  planned.events[0].payload = { ...planned.events[0].payload, ran: true, exit_code: 0, stdout: 'PASS 6 assertions', stderr: '' };
  const qaPassed = planned.renderActivity();
  assert('prueba ejecutada correcta se pliega y conserva evidencia', qaPassed.includes('Pruebas de app: correctas') && qaPassed.includes('PASS 6 assertions') && qaPassed.includes('18ac02'), qaPassed);

  planned.events = [
    { id: 8, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\app.js', content: 'document.querySelector("#app").textContent = "ok";' } },
    { id: 9, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\index.html', content: '<main id="app"></main><script src="app.js"></script>' } },
  ];
  let webCards = planned.renderActivity();
  assert('JavaScript DOM comprobado ofrece ver su página HTML', webCards.includes('Ver página') && webCards.includes('data-abrir="C:\\web\\index.html"'), webCards);
  assert('JavaScript DOM comprobado no emite devagents:run-file', !webCards.includes('data-ejecutar="C:\\web\\app.js"'), webCards);

  planned.events = [
    { id: 10, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\web\\index.html', content: '<main>resultado</main>' } },
  ];
  const directHtmlCard = planned.renderActivity();
  assert('HTML terminado abre su propia página exacta', directHtmlCard.includes('>Ver página</button>') && directHtmlCard.includes('data-abrir="C:\\web\\index.html"') && !directHtmlCard.includes('>Abrir</button>'), directHtmlCard);

  planned.events = [
    { id: 10, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\cli\\report.js', content: '#!/usr/bin/env node\nconst fs = require("fs"); process.stdout.write("ok");' } },
  ];
  let nodeCards = planned.renderActivity();
  assert('JavaScript CLI con evidencia Node conserva Ejecutar', nodeCards.includes('data-ejecutar="C:\\cli\\report.js"'), nodeCards);

  planned.events = [
    { id: 11, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\misc\\unknown.js', content: 'const value = 1;' } },
  ];
  let unknownCards = planned.renderActivity();
  assert('JavaScript sin evidencia de runtime no se manda a Node', !unknownCards.includes('data-ejecutar="C:\\misc\\unknown.js"') && unknownCards.includes('data-abrir="C:\\misc\\unknown.js"'), unknownCards);

  planned.events = [
    { id: 12, ts: 1, source: 'worker', kind: 'file_written', payload: { file_path: 'C:\\out\\resultado.html' } },
    { id: 13, ts: 1, source: 'worker', kind: 'order_done', payload: { completed: 2, failed: 0 } },
    { id: 14, ts: 1, source: 'worker', kind: 'task_done', payload: { task_id: 'a', success: true, model_used: 'terra' } },
    { id: 15, ts: 1, source: 'audit', kind: 'task_audit', payload: { task_id: 'a', verdict: 'PASS', notes: 'correcto' } },
    { id: 16, ts: 1, source: 'audit', kind: 'task_audit', payload: { task_id: 'b', verdict: 'FAIL', notes: 'falta prueba' } },
  ];
  const verificationCards = planned.renderActivity();
  assert('la auditoría FAIL reclama atención FUERA del bloque plegable', verificationCards.indexOf('La auditoría rechazó b') < verificationCards.indexOf('<details id="turn-activity"'), verificationCards);
  assert('el PASS no se convierte en bloqueo', !verificationCards.includes('La auditoría rechazó a'), verificationCards);
  assert('el artefacto conserva su botón dentro de la actividad', verificationCards.includes('data-abrir="C:\\out\\resultado.html"'), verificationCards);
  // USUARIO-NUEVO A7 (10-nov): la línea del grupo dice QUÉ hizo («Escribió 1
  // archivo · ejecutó 1 tarea · auditó 2 tareas»), ya no «N acciones», y los
  // contadores de eventos del motor no se pintan en la conversación.
  assert('el resumen del turno dice lo que hizo y no cuenta eventos', verificationCards.includes('Escribió 1 archivo · ejecutó 1 tarea · auditó 2 tareas') && !verificationCards.includes('evento(s) del motor'), verificationCards);

  planned.events = [
    { id: 6, ts: 1, source: 'router', kind: 'task_provider_failed', payload: { provider: 'fallido', model: 'm', status: 'empty' } },
    { id: 7, ts: 1, source: 'worker', kind: 'order_failed', payload: { cause: 'sin proveedor' } },
  ];
  planned.activityOpen = null;
  let providerCards = planned.renderActivity();
  // A7 (10-nov): «Falló · Probó 1 proveedor» en vez de «Falló tras 0 s».
  assert('un turno fallido se pliega solo y sigue diciendo que falló', providerCards.includes('Falló · ') && !providerCards.includes('<details id="turn-activity" open'), providerCards);
  assert('el fallo de la orden queda a la vista aunque la actividad esté plegada', providerCards.includes('La orden terminó con errores'), providerCards);
  planned.activityOpen = true;
  providerCards = planned.renderActivity();
  assert('el detalle abierto por el usuario se respeta tras repintar', providerCards.includes('<details id="turn-activity" open'), providerCards);
  assert('el intento de proveedor sigue dentro del detalle', providerCards.includes('Proveedor fallido'), providerCards);
  planned.activityOpen = false;
  assert('el detalle cerrado por el usuario también se respeta', !planned.renderActivity().includes('<details id="turn-activity" open'), planned.renderActivity());
  planned.activityOpen = null;

  // H-1 (auditoría de la cabina, 09-09): el contador de fuera prometía «y N
  // bloqueo(s) más, dentro de la actividad» y dentro no se pintaba ninguno.
  planned.events = [
    { id: 40, ts: 1, source: 'w', kind: 'shell_command', payload: { task_id: 'a', command: 'node uno.js', status: 'done', exit_code: 1, stderr: 'falla uno' } },
    { id: 41, ts: 2, source: 'w', kind: 'shell_command', payload: { task_id: 'b', command: 'node dos.js', status: 'done', exit_code: 1, stderr: 'falla dos' } },
    { id: 42, ts: 3, source: 'w', kind: 'shell_command', payload: { task_id: 'c', command: 'node tres.js', status: 'done', exit_code: 1, stderr: 'falla tres' } },
    { id: 43, ts: 4, source: 'w', kind: 'shell_command', payload: { task_id: 'd', command: 'node cuatro.js', status: 'done', exit_code: 1, stderr: 'falla cuatro' } },
    { id: 44, ts: 5, source: 'w', kind: 'shell_command', payload: { task_id: 'e', command: 'node cinco.js', status: 'done', exit_code: 1, stderr: 'falla cinco' } },
  ];
  planned.activityOpen = true;
  const muchosBloqueos = planned.renderActivity();
  assert('con más de tres bloqueos, el contador dice cuántos quedan', muchosBloqueos.includes('y 2 bloqueo(s) más, dentro de la actividad'), muchosBloqueos.slice(0, 400));
  assert('y esos dos ESTÁN dentro de la actividad, no sólo en el contador', muchosBloqueos.includes('node cuatro.js') && muchosBloqueos.includes('node cinco.js'), 'los bloqueos 4 y 5 no se pintan dentro del bloque');
  assert('el detalle marca cuáles ya se ven arriba para no contarlos dos veces', muchosBloqueos.includes('ya visible arriba'), muchosBloqueos.slice(0, 400));
  assert('el recuento de bloqueos del detalle es el real', muchosBloqueos.includes('5 bloqueo(s) sin resolver'), muchosBloqueos.slice(0, 400));
  planned.activityOpen = null;
  planned.events = [];

  let blockedMessageCalls = 0;
  let blockedEventCalls = 0;
  const blockedCore = {
    status: core.status,
    conversationMessages: async () => { blockedMessageCalls += 1; return []; },
    orderEvents: async () => { blockedEventCalls += 1; return []; },
    orderStatus: core.orderStatus,
  };
  const blocked = new MissionControlPanel(missionContainer, blockedCore);
  blocked.phase = 'running';
  blocked.orderId = 77;
  blocked.conversationId = 'conv-activa';
  await blocked.loadSession(99, 'conv-ajena');
  assert('loadSession bloqueada durante running conserva la orden activa', blocked.phase === 'running' && blocked.orderId === 77 && blocked.conversationId === 'conv-activa', `${blocked.phase}/${blocked.orderId}/${blocked.conversationId}`);
  assert('loadSession bloqueada durante running no consulta la conversación ajena', blockedMessageCalls === 0 && blockedEventCalls === 0, `${blockedMessageCalls}/${blockedEventCalls}`);
  blocked.newConversation();
  assert('nuevo chat bloqueado conserva una orden viva', blocked.phase === 'running' && blocked.orderId === 77 && blocked.conversationId === 'conv-activa', `${blocked.phase}/${blocked.orderId}/${blocked.conversationId}`);

  const cancelButton = new FakeElement();
  const cancelContainer = new FakeElement();
  cancelContainer.querySelector = (selector) => selector === '#mission-body' ? missionBody : selector === '#btn-mission-cancel' ? cancelButton : null;
  const cancelCore = { status: core.status, cancelOrder: async () => { throw new Error('dispatch no activo'); } };
  const cancelling = new MissionControlPanel(cancelContainer, cancelCore);
  cancelling.phase = 'running';
  cancelling.orderId = 31;
  cancelling.pollHandle = 7;
  await cancelling.cancel();
  assert('fallo al cancelar conserva seguimiento de la orden activa', cancelling.phase === 'running' && cancelling.orderId === 31 && cancelling.pollHandle === 7, `${cancelling.phase}/${cancelling.orderId}/${cancelling.pollHandle}`);
  assert('fallo al cancelar deja una acción visible de reintento', cancelButton.textContent === 'Reintentar detener', cancelButton.textContent);

  const acceptedButton = new FakeElement();
  const acceptedContainer = new FakeElement();
  acceptedContainer.querySelector = (selector) => selector === '#mission-body' ? missionBody : selector === '#btn-mission-cancel' ? acceptedButton : null;
  const accepted = new MissionControlPanel(acceptedContainer, { status: core.status, cancelOrder: async () => ({ cancelled: true }) });
  accepted.phase = 'running';
  accepted.orderId = 32;
  accepted.pollHandle = 8;
  await accepted.cancel();
  assert('solicitud de cancelación aceptada espera el terminal sin abandonar sondeo', accepted.phase === 'running' && accepted.orderId === 32 && accepted.pollHandle === 8 && acceptedButton.textContent === 'Deteniendo…', `${accepted.phase}/${accepted.orderId}/${accepted.pollHandle}/${acceptedButton.textContent}`);

  let resolveCancel;
  const lateCancel = new MissionControlPanel(acceptedContainer, { status: core.status, cancelOrder: () => new Promise((resolve) => { resolveCancel = resolve; }) });
  lateCancel.phase = 'running';
  lateCancel.orderId = 34;
  const pendingCancel = lateCancel.cancel();
  lateCancel.reset();
  resolveCancel({ cancelled: true });
  await pendingCancel;
  assert('respuesta tardía de cancelación no altera una sesión reiniciada', lateCancel.phase !== 'running' && !lateCancel.cancelPending, `${lateCancel.phase}/${lateCancel.cancelPending}`);

  let resolvePlan;
  const latePlanCore = { status: core.status, orderEvents: async () => [], pollPlan: async () => ({ done: true, ok: true }), getPlan: () => new Promise((resolve) => { resolvePlan = resolve; }) };
  const latePlan = new MissionControlPanel(missionContainer, latePlanCore);
  latePlan.phase = 'planning';
  latePlan.orderId = 35;
  const pendingPlan = latePlan.waitForPlan(0, 35);
  await new Promise((resolve) => setTimeout(resolve, 450));
  latePlan.reset();
  resolvePlan({ tasks: [{ id: 'late' }] });
  await pendingPlan;
  assert('getPlan tardío no pisa un reinicio', latePlan.plan === null && latePlan.phase !== 'awaiting-approval', `${latePlan.phase}/${JSON.stringify(latePlan.plan)}`);

  let stalePollCalls = 0;
  let resolveSubmission;
  const staleCore = {
    status: core.status,
    orderPreflight: async () => ({ allowed: true, issues: [], message: '' }),
    submitOrder: () => new Promise((resolve) => { resolveSubmission = resolve; }),
    pollPlan: async () => { stalePollCalls += 1; return { done: true, ok: true }; },
  };
  const stale = new MissionControlPanel(missionContainer, staleCore);
  const delayedSubmit = stale.submit('orden que responde tarde');
  await new Promise((resolve) => setImmediate(resolve));
  stale.reset();
  resolveSubmission({ orderId: 88 });
  await delayedSubmit;
  assert('respuesta tardía de submit no revive una planificación descartada', stale.phase !== 'planning' && stale.orderId === 0 && stalePollCalls === 0, `${stale.phase}/${stale.orderId}/${stalePollCalls}`);

  const draftInput = new FakeElement();
  draftInput.value = 'borrador que no se debe perder';
  draftInput.listeners = {};
  draftInput.addEventListener = (kind, listener) => { draftInput.listeners[kind] = listener; };
  const sendButton = new FakeElement();
  sendButton.addEventListener = (_kind, listener) => { sendButton.listener = listener; };
  const busyBody = new FakeElement();
  const busyContainer = new FakeElement();
  busyContainer.querySelector = (selector) => {
    if (selector === '#mission-body') return busyBody;
    if (selector === '#mission-composer-input') return draftInput;
    if (selector === '#btn-mission-send') return sendButton;
    return null;
  };
  const busy = new MissionControlPanel(busyContainer, core);
  busy.phase = 'planning';
  sendButton.listener();
  // (10-nov): con el agente ocupado el mensaje ya no se queda en el
  // compositor, pasa a la cola «En cola» y sale solo al terminar. Lo que se
  // comprueba sigue siendo que el texto no se pierde ni se envía a destiempo.
  assert('compositor ocupado pasa el borrador a la cola sin enviarlo', busy.sendQueue.length === 1 && busy.sendQueue[0] === 'borrador que no se debe perder' && busy.phase === 'planning', `${JSON.stringify(busy.sendQueue)}/${busy.phase}`);
  // Con adjuntos no se puede encolar: el borrador se queda en el compositor.
  draftInput.value = 'borrador con adjunto';
  busy.attachments = [{ name: 'a.png' }];
  sendButton.listener();
  assert('compositor ocupado con adjunto conserva el borrador', draftInput.value === 'borrador con adjunto' && busy.sendQueue.length === 1, `${draftInput.value}/${busy.sendQueue.length}`);
  busy.attachments = [];

  const sentInput = new FakeElement();
  sentInput.value = 'orden larga que había expandido el compositor';
  sentInput.style.height = '150px';
  sentInput.addEventListener = () => {};
  const sentButton = new FakeElement();
  sentButton.addEventListener = (_kind, listener) => { sentButton.listener = listener; };
  const sentContainer = new FakeElement();
  sentContainer.querySelector = (selector) => {
    if (selector === '#mission-body') return new FakeElement();
    if (selector === '#mission-composer-input') return sentInput;
    if (selector === '#btn-mission-send') return sentButton;
    return null;
  };
  const sent = new MissionControlPanel(sentContainer, { status: core.status, orderPreflight: async () => ({ allowed: true, issues: [], message: '' }), submitOrder: async () => ({ orderId: 91 }) });
  sentButton.listener();
  assert('enviar vacía y contrae el compositor expandido', sentInput.value === '' && sentInput.style.height === 'auto', `${sentInput.value}/${sentInput.style.height}`);

  // la orden interna de compactacion no debe nacer como sesion del
  // usuario. El motor oculta del historial toda orden cuyo project_id empieza
  // por el prefijo interno "__" (core/src/session_store.zig:36 y :169;
  // core/src/c_api.zig:6611). Si compactConversation envia la orden con el
  // proyecto "default", su prompt interno ("Resume la siguiente conversacion
  // en un parrafo denso...") aparece en la barra lateral y en el historial como
  // si lo hubiera escrito el usuario — el defecto reportado en agosto.
  let compactSubmit = null;
  const compactCore = {
    status: core.status,
    submitOrder: async (text, project, conversationId) => {
      compactSubmit = { text, project, conversationId };
      return { orderId: 601 };
    },
    pollPlan: async () => ({ done: true, ok: true }),
    getPlan: async () => ({ understanding: 'El usuario construyo una calculadora web con dos botones.' }),
  };
  const compactMission = new MissionControlPanel(missionContainer, compactCore);
  compactMission.turns = [
    { role: 'user', text: 'crea una calculadora web' },
    { role: 'assistant', text: 'hecha' },
  ];
  await compactMission.compactConversation();
  assert(
    'CK-CAB-011: la orden de compactacion se envia con un proyecto interno (prefijo __) para no aparecer como sesion del usuario',
    typeof compactSubmit?.project === 'string' && compactSubmit.project.startsWith('__'),
    JSON.stringify(compactSubmit)
  );
  assert(
    'CK-CAB-011: el hilo local se reemplaza por el resumen (la orden interna no se pierde)',
    compactMission.turns.length === 1 && /Resumen de lo anterior/.test(compactMission.turns[0].text),
    JSON.stringify(compactMission.turns)
  );

  // D8: clarificacion end-to-end — el plan con needs_clarification pinta el
  // formulario, y «Enviar respuestas» manda un ARRAY de {question_id, answer},
  // el unico contrato que parseClarificationAnswers acepta en el motor (un dict
  // {id: respuesta} se rechaza con invalid answers JSON).
  const clarifyBody = new FakeElement();
  const clarifyContainer = new FakeElement();
  let sendAnswersListener = null;
  const clarifyField = { dataset: { answer: 'target-language' }, value: 'Zig' };
  clarifyBody.querySelector = (selector) => {
    if (selector === '#btn-send-answers') return { addEventListener: (_k, l) => { sendAnswersListener = l; } };
    return null;
  };
  clarifyBody.querySelectorAll = (selector) => selector === '[data-answer]' ? [clarifyField] : [];
  clarifyContainer.querySelector = (selector) => selector === '#mission-body' ? clarifyBody : null;
  let answered = null;
  let clarifyPlansFetched = 0;
  const clarifyCore = {
    status: core.status,
    orderPreflight: async () => ({ allowed: true, issues: [], message: '' }),
    orderEvents: async () => [],
    orderStatus: async () => ({ status: 1 }),
    submitOrder: async () => ({ orderId: 555 }),
    pollPlan: async () => ({ done: true, ok: true }),
    getPlan: async () => (++clarifyPlansFetched === 1
      ? { understanding: 'Voy a construir el proyecto', needs_clarification: true, questions: [{ id: 'target-language', text: '¿En que lenguaje?', options: ['C', 'C++', 'Zig'] }] }
      : { understanding: 'Modulo en Zig', needs_clarification: false, tasks: [{ id: 't1', task_type: 'code', department: 'dev', description: 'crear', depends_on: [] }] }),
    answerOrder: async (_id, answers) => { answered = answers; return { accepted: true }; },
  };
  const clarify = new MissionControlPanel(clarifyContainer, clarifyCore);
  await clarify.submit('crea un proyecto');
  assert('plan clarifying pone la fase en espera de respuestas', clarify.phase === 'clarifying', clarify.phase);
  assert('el formulario lista la pregunta con sus opciones', clarifyBody.innerHTML.includes('lenguaje') && clarifyBody.innerHTML.includes('data-answer="target-language"') && clarifyBody.innerHTML.includes('option value="Zig"'), clarifyBody.innerHTML);
  assert('el boton Enviar respuestas quedo cableado', typeof sendAnswersListener === 'function', String(sendAnswersListener));
  sendAnswersListener();
  await new Promise((r) => setTimeout(r, 700));
  assert('la respuesta viaja como ARRAY de {question_id, answer}', Array.isArray(answered) && answered.length === 1 && answered[0].question_id === 'target-language' && answered[0].answer === 'Zig', JSON.stringify(answered));
  assert('tras responder el plan resuelto pasa a aprobacion', clarify.phase === 'awaiting-approval' && clarify.plan.tasks.length === 1, clarify.phase + '/' + JSON.stringify(clarify.plan));

  // D9: la fase local se reconcilia con el estado real del motor — si la orden
  // falla por otra vía el panel deja de mostrar «Plan listo para aprobar».
  const failCore = { status: core.status, orderEvents: async () => [], orderStatus: async () => ({ status: 6 }), getPlan: async () => ({}) };
  const failPanel = new MissionControlPanel(missionContainer, failCore);
  failPanel.orderId = 77;
  failPanel.setPhase('awaiting-approval');
  await failPanel.reconcileOrderStatus(77);
  assert('orden fallida por otra vía saca al panel de awaiting-approval', failPanel.phase === 'error', failPanel.phase);

  const runCore = { status: core.status, orderEvents: async () => [], orderStatus: async () => ({ status: 4 }), pollDispatch: async () => ({ done: false }) };
  const runPanel = new MissionControlPanel(missionContainer, runCore);
  runPanel.orderId = 78;
  runPanel.setPhase('awaiting-approval');
  await runPanel.reconcileOrderStatus(78);
  assert('orden despachada por otra vía pasa el panel a running', runPanel.phase === 'running', runPanel.phase);

  const clCore = {
    status: core.status,
    conversationMessages: async () => [],
    orderEvents: async () => [],
    orderStatus: async () => ({ status: 1 }),
    getPlan: async () => ({ needs_clarification: true, questions: [{ id: 'target-language', text: 'lenguaje?', options: ['C', 'Zig'] }] })
  };
  const clPanel = new MissionControlPanel(missionContainer, clCore);
  await clPanel.loadSession(88, 'conv-cl');
  assert('sesión clarifying reabierta muestra el formulario de preguntas', clPanel.phase === 'clarifying' && clPanel.plan.questions.length === 1, clPanel.phase);

  const restoreBody = new FakeElement();
  const restoreContainer = new FakeElement();
  let restoreClick;
  restoreBody.querySelector = selector => selector === '#btn-workspace-restore'
    ? {addEventListener: (_kind, handler) => { restoreClick = handler; }} : null;
  restoreContainer.querySelector = selector => selector === '#mission-body' ? restoreBody : null;
  let repairs = 0;
  let repairOrder;
  const restoreCore = {
    status: core.status,
    restoreWorkspacePermissions: async orderId => {
      repairs += 1; repairOrder = orderId;
      return {restored:true,root:'C:/fixture/devagents-workspace',message:'Permisos restaurados; orden detenida'};
    },
  };
  const repairPanel = new MissionControlPanel(restoreContainer, restoreCore);
  repairPanel.orderId = 990;
  repairPanel.events = [{id:1,ts:1,source:'fixture',kind:'external_agent_finished',payload:{error:'snapshot: fallo; etapa=raiz; ruta=.; error=CliWritableByOthers; win32=0; escritores=grupo CodexSandboxUsers; SID sintético sin cuenta; otro escritor; accion=workspace_acl_restore'}}];
  repairPanel.setPhase('error');
  repairPanel.renderBody();
  assert('B2 render/poll nunca restaura automáticamente', repairs === 0);
  assert('B2 UI ofrece botón y muestra escritores', restoreBody.innerHTML.includes('Restaurar permisos del espacio') && restoreBody.innerHTML.includes('CodexSandboxUsers') && restoreBody.innerHTML.includes('SID sintético sin cuenta') && restoreBody.innerHTML.includes('otro escritor'));
  assert('B2 acción explícita tiene controlador', typeof restoreClick === 'function');
  restoreClick();
  await new Promise(resolve => setImmediate(resolve));
  assert('B2 clic restaura solo espacio de la orden', repairs === 1 && repairOrder === 990);
  assert('B2 éxito conserva error/orden detenida y confirma raíz', repairPanel.phase === 'error' && restoreBody.innerHTML.includes('C:/fixture/devagents-workspace') && restoreBody.innerHTML.includes('orden detenida'));
  restoreClick();
  await new Promise(resolve => setImmediate(resolve));
  assert('B2 botón restaurado no repite ni despacha', repairs === 1 && repairPanel.phase === 'error');
  const reopenedCore = {
    ...restoreCore,
    conversationMessages: async () => [],
    orderEvents: async () => repairPanel.events,
    orderStatus: async () => ({status:6}),
  };
  const reopenedRepair = new MissionControlPanel(restoreContainer, reopenedCore);
  await reopenedRepair.loadSession(990, 'fixture-b2-reopened');
  assert('B2 reabrir orden fallida conserva reparación y causa sin ejecutar', reopenedRepair.phase === 'error' && restoreBody.innerHTML.includes('Restaurar permisos del espacio') && restoreBody.innerHTML.includes('CodexSandboxUsers') && repairs === 1);

  // 22-09: toda hoja de estilos tiene que vivir en <head>. La cabina reescribe
  // el <body> al pintar el diseño y una <link> dentro de él desaparece: le pasó
  // a xterm.css desde D5 (terminal con sus piezas internas a la vista).
  const indexHtml = require('fs').readFileSync(require('path').join(__dirname, '..', 'shell', 'webui', 'public', 'index.html'), 'utf8');
  const cuerpo = indexHtml.slice(indexHtml.indexOf('</head>'));
  const cabeza = indexHtml.slice(0, indexHtml.indexOf('</head>'));
  assert('ninguna <link rel="stylesheet"> vive en <body>', !/<link[^>]+rel="stylesheet"/.test(cuerpo));
  assert('xterm.css se carga desde <head>', /<link[^>]+href="vendor\/xterm\/xterm\.css"/.test(cabeza));

  console.log(failed === 0 ? 'UI REPAIR TEST PASS' : `UI REPAIR TEST FAIL: ${failed}`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((error) => { console.error(error); process.exit(1); });
