// Only the orchestrator runs this against the cabin. No orders, probes or saves.
// Puerto de la cabina de PRUEBA: 9333 (otro sólo con --permitir-puerto); exige título/marca DevAgents.
// Modo autónomo: node tools/cdp_relevo_scenarios.mjs <carpeta-evidencia> <etiqueta> [--permitir-puerto]
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const sections = ['providers', 'models', 'governance', 'permissions', 'hooks', 'remote', 'skills', 'plugins', 'memory', 'appearance', 'about'];
const samples = [
  ['html', 'html', '<!-- comentario -->\n<div class="demo">Hola</div>'],
  ['css', 'css', '/* comentario */\n.demo { color: #ab1234; width: 42px; }'],
  ['js', 'javascript', '// comentario\nconst nombre = "demo"; function sumar(x) { return x + 42; }'],
  ['ts', 'typescript', '// comentario\ninterface Persona { nombre: string }\nconst n: number = 42;'],
  ['tsx', 'typescript', '// comentario\nconst n: number = 42; const nodo = <div title="demo">{n}</div>;'],
  ['json', 'json', '{"nombre":"demo", "numero":42, "activo":true}'],
  ['md', 'markdown', '# Título\n**demo** [enlace](https://example.invalid)\n`42`'],
  ['py', 'python', '# comentario\ndef sumar(x: int):\n    return "demo", x + 42'],
  ['zig', 'zig', '// comentario\nconst std = @import("std");\npub fn sumar(x: u32) u32 { return x + 42; }'],
  ['c', 'c', '/* comentario */\nint sumar(int x) { const char *s = "demo"; return x + 42; }'],
  ['h', 'c', '/* comentario */\n#define DEMO 42\nint sumar(int x);'],
  ['cpp', 'cpp', '// comentario\nclass Demo { public: int n = 42; const char *s = "demo"; };'],
  ['rs', 'rust', '// comentario\nfn sumar(x: i32) -> i32 { let s = "demo"; x + 42 }'],
  ['go', 'go', '// comentario\npackage demo\nfunc sumar(x int) int { return x + 42 }'],
  ['java', 'java', '// comentario\nclass Demo { String s = "demo"; int n = 42; }'],
  ['sh', 'shell', '# comentario\nn=42\necho "demo"'],
  ['ps1', 'powershell', '# comentario\n$n = 42\nWrite-Host "demo"'],
  ['yaml', 'yaml', '# comentario\nnombre: "demo"\nnumero: 42\nactivo: true'],
  ['toml', 'toml', '[demo]\nnombre = "demo"\nnumero = 42'],
  ['sql', 'sql', '-- comentario\nSELECT nombre, 42 FROM demo WHERE nombre = \'demo\';'],
  ['xml', 'xml', '<!-- comentario -->\n<demo nombre="demo">42</demo>'],
];

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

// lógica pura del sondeo de estabilización y del conteo de colores renderizados.
// Colores distintos visibles de una lectura, normalizados y ordenados.
export function coloresDeLectura(lectura) {
  if (!lectura || typeof lectura !== 'object' || !Array.isArray(lectura.colores)) throw new TypeError('Lectura del editor inválida');
  return [...new Set(lectura.colores.filter(Boolean))].sort();
}
// Firma invariante del estado renderizado: host, líneas, spans mtk visibles y colores vistos.
export function firmaRender(lectura) {
  if (!lectura || typeof lectura !== 'object' || !Array.isArray(lectura.colores)) throw new TypeError('Lectura del editor inválida');
  return JSON.stringify({
    hostVisible: lectura.hostVisible === true,
    lineasVisibles: lectura.lineasVisibles|0,
    spansVisibles: lectura.spansVisibles|0,
    colores: coloresDeLectura(lectura),
  });
}
// Estabilización: la firma de dos lecturas consecutivas idénticas. `firma` inyectable para
// demostrar con una mutación que romper esta lógica pone las pruebas en rojo.
export function estableEnDosLecturas(previa, ultima, firma = firmaRender) {
  if (previa == null || ultima == null) return false;
  return firma(previa) === firma(ultima);
}
// Conteo de colores distintos visibles en una lectura.
export function contarColores(lectura) {
  return coloresDeLectura(lectura).length;
}
// Lector del DOM renderizado que se inyecta en la página (misma función que se prueba en Node).
export function lecturaEditorDom() {
  const spans = () => [...document.querySelectorAll('#editor-monaco-host span[class*=mtk]')].filter(el => el.getClientRects().length > 0);
  return {
    hostVisible: (() => { const h = document.querySelector('#editor-monaco-host'); return !!h && h.getClientRects().length > 0; })(),
    lineasVisibles: [...document.querySelectorAll('#editor-monaco-host .view-line')].filter(el => el.getClientRects().length > 0).length,
    spansVisibles: spans().length,
    colores: [...new Set(spans().map(el => getComputedStyle(el).color))],
  };
}
// Sondeo real por frames: dos firmas iguales seguidas o plazo agotado. Se inyecta en la
// página vía toString() y las pruebas la ejecutan directamente con un lector sintético.
export function sondearEditor({ leer, plazoMs = 3000, ahora = () => Date.now(), programar = fn => requestAnimationFrame(fn), cancelar = id => cancelAnimationFrame(id), firma = firmaRender }) {
  if (typeof leer !== 'function') throw new TypeError('Sondeo sin lector');
  const plazo = ahora() + plazoMs;
  const lecturas = [];
  return new Promise(fin => {
    let terminado = false;
    let frame = null;
    const terminar = resultado => {
      if (terminado) return;
      terminado = true;
      clearTimeout(temporizador);
      if (frame != null) cancelar(frame);
      fin(resultado);
    };
    // El plazo también vence cuando requestAnimationFrame deja de entregar callbacks.
    const temporizador = setTimeout(() => terminar({ lecturas, vencido: true, estable: false }), plazoMs);
    const paso = () => {
      if (terminado) return;
      frame = null;
      let lectura;
      try { lectura = leer(); } catch (error) { terminar({ lecturas, error: String((error && error.message) || error).slice(0, 120) }); return; }
      lecturas.push(lectura);
      const ultima = lecturas[lecturas.length - 1];
      const previa = lecturas[lecturas.length - 2];
      const util = ultima.hostVisible === true && (ultima.spansVisibles|0) > 0;
      if (previa && estableEnDosLecturas(previa, ultima, firma) && util) { terminar({ lecturas, vencido: false, estable: true }); return; }
      if (ahora() >= plazo) { terminar({ lecturas, vencido: true, estable: false }); return; }
      frame = programar(paso);
    };
    frame = programar(paso);
  });
}
// Expresión CDP que ejecuta en la página la MISMA lógica exportada (sin copia inline).
export function expresionSondeoEditor(plazoMs = 3000) {
  return `(() => {
    const coloresDeLectura = ${coloresDeLectura.toString()};
    const firmaRender = ${firmaRender.toString()};
    const estableEnDosLecturas = ${estableEnDosLecturas.toString()};
    const lecturaEditorDom = ${lecturaEditorDom.toString()};
    const sondearEditor = ${sondearEditor.toString()};
    return sondearEditor({ leer: lecturaEditorDom, plazoMs: ${Number(plazoMs)} });
  })()`;
}
// Reduce las lecturas del sondeo a {ultima, previa, vueltas, estable, vencido}.
// `vencido` llega del sondeo en página: plazo de 3 s agotado sin dos lecturas útiles seguidas.
export function sintetizarSondeo(lecturas, vencido = false) {
  if (!Array.isArray(lecturas) || lecturas.length === 0) throw new TypeError('Sondeo sin lecturas');
  const ultima = lecturas[lecturas.length - 1];
  const previa = lecturas.length > 1 ? lecturas[lecturas.length - 2] : null;
  return { ultima, previa, vueltas: lecturas.length, estable: estableEnDosLecturas(previa, ultima), vencido: vencido === true };
}
// Fila de la matriz de editor: datos medidos a partir del sondeo y de la página.
export function filaEditor(datos) {
  if (!datos || typeof datos !== 'object') throw new TypeError('Datos de fila inválidos');
  const { extension, tema, escala, languageId, estado, tiposToken, sondeo } = datos;
  if (!extension || !tema || !escala || typeof languageId !== 'string') throw new TypeError('Fila con extensión/tema/escala/languageId ausentes');
  if (!sondeo || !sondeo.ultima) throw new TypeError('Fila sin resultado de sondeo');
  const lectura = sondeo.ultima;
  const colores = coloresDeLectura(lectura);
  return {
    extension, tema, escala, languageId,
    estado: estado ?? null,
    hostVisible: lectura.hostVisible === true,
    lineasVisibles: lectura.lineasVisibles|0,
    spansVisibles: lectura.spansVisibles|0,
    colores,
    tiposToken: [...(tiposToken || [])].filter(Boolean),
    estable: sondeo.estable === true,
    vencido: sondeo.vencido === true,
    vueltas: sondeo.vueltas|0,
    monocromo: contarColores(lectura) <= 1,
  };
}
// Veredicto de la fila: MISMA medición del render que usa el resumen (sin copia inline).
export function veredictoFila(fila) {
  if (!fila || typeof fila !== 'object') throw new TypeError('Fila inválida');
  const colores = Array.isArray(fila.colores) ? contarColores(fila) : 0;
  return fila.estable === true && fila.hostVisible === true && (fila.lineasVisibles|0) > 0 &&
    (fila.spansVisibles|0) > 0 && colores > 1 ? 'OK' : 'FALLA';
}
// Motivos de fallo de una fila severa (diagnóstico exigido por el encargo).
export function motivosDeFila(fila) {
  if (!fila || typeof fila !== 'object') throw new TypeError('Fila inválida');
  const motivos = [];
  const colores = Array.isArray(fila.colores) ? contarColores(fila) : 0;
  if (fila.hostVisible !== true) motivos.push('host invisible');
  if (!(fila.lineasVisibles > 0)) motivos.push('sin líneas visibles');
  if (!(fila.spansVisibles > 0)) motivos.push('sin spans mtk visibles');
  if (colores < 2) motivos.push(`colores=${colores} (se exige >1)`);
  if (fila.estable !== true) motivos.push('firma inestable al vencer el plazo');
  if (fila.estado === 'TEXT') motivos.push('estado');
  return motivos;
}
// Resumen agregado de la matriz: totales y por bloque tema-escala.
export function resumenEditor(filas) {
  if (!Array.isArray(filas)) throw new TypeError('Filas inválidas');
  const bloques = {};
  for (const f of filas) {
    const clave = `${f.tema}-${f.escala}`;
    const bloque = bloques[clave] || (bloques[clave] = { total: 0, ok: 0, fallos: [] });
    bloque.total++;
    if (f.veredicto === 'OK') bloque.ok++;
    else bloque.fallos.push(f.extension);
  }
  return {
    total: filas.length,
    ok: filas.filter(f => f.veredicto === 'OK').length,
    fallos: filas.filter(f => f.veredicto !== 'OK').length,
    bloques,
  };
}
// Tabla de texto (CSV con ;) de la matriz, para el resumen humano.
export function tablaEditorTexto(filas) {
  if (!Array.isArray(filas)) throw new TypeError('Filas inválidas');
  const corte = (valor, maximo) => (valor == null ? '' : String(valor).slice(0, maximo));
  const plano = valor => valor == null ? '' : String(valor);
  const lineas = [['tema', 'escala', 'ext', 'veredicto', 'host', 'lineas', 'spans', 'colores', 'tipos', 'estable', 'vencido', 'motivos'].join(';')];
  for (const f of filas) {
    lineas.push([plano(f.tema), plano(f.escala), plano(f.extension), plano(f.veredicto), plano(f.hostVisible), plano(f.lineasVisibles), plano(f.spansVisibles),
      corte(f.colores && f.colores.join('|'), 160), corte(f.tiposToken && f.tiposToken.join('|'), 100), plano(f.estable), plano(f.vencido),
      corte(f.motivos && f.motivos.join('|'), 160)].join(';'));
  }
  return lineas.join('\n') + '\n';
}

export async function runRelevoScenarios({ send, evaluate, wait, click, key, output, report }) {
  const literal = JSON.stringify;
  const temp = mkdtempSync(join(tmpdir(), 'beats-relevo-editor-'));
  const paths = samples.map(([ext, language, content]) => {
    const path = join(temp, `demo.${ext}`);
    writeFileSync(path, content, 'utf8');
    return { ext, language, content, path };
  });
  let saved;
  // Clipped surfaces only: the conversation/history never enters a capture.
  async function physicalClick(selector) {
    const point = await evaluate(`(() => {const r=document.querySelector(${literal(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, ...point, button: 'left', clickCount: 1 });
  }
  async function paletteToggle() {
    await click('#btn-command-palette');
    await evaluate("(() => {const input=document.querySelector('#cmd-palette-input');input.value='Mostrar u ocultar el panel de actividad';input.dispatchEvent(new Event('input',{bubbles:true}));input.focus()})()");
    await key('Enter', 13);
  }
  async function capture(selector, label, canonical) {
    const snapshot = await evaluate(`(() => {
      const root=document.querySelector(${literal(selector)});if(!root)throw Error('Superficie ausente');
      const r=root.getBoundingClientRect();
      const canonical=${literal(canonical)};
      const label=canonical?[root,...root.querySelectorAll('*')].find(el=>!el.children.length&&el.textContent.trim()===canonical):null;
      const transform=label?getComputedStyle(label).textTransform:'';
      const renderedCanonical=label?.getClientRects().length?(transform==='uppercase'?canonical.toLocaleUpperCase('es'):transform==='lowercase'?canonical.toLocaleLowerCase('es'):canonical):null;
      return {innerText:root.innerText, renderedCanonical, accessibleName:root.querySelector('#chat-btn-collapse')?.getAttribute('aria-label')||'', rect:{x:r.x,y:r.y,width:r.width,height:r.height},
        viewport:{width:innerWidth,height:innerHeight}, overflow:root.scrollWidth>root.clientWidth+1};
    })()`);
    if (canonical) assert(snapshot.renderedCanonical && snapshot.innerText.includes(snapshot.renderedCanonical), `Texto canónico ausente: ${canonical}`);
    assert(!snapshot.overflow && snapshot.rect.width > 0 && snapshot.rect.height > 0, 'Superficie invisible o con desborde');
    assert(snapshot.rect.x >= -1 && snapshot.rect.y >= -1 && snapshot.rect.x + snapshot.rect.width <= snapshot.viewport.width + 1 && snapshot.rect.y + snapshot.rect.height <= snapshot.viewport.height + 1, 'Superficie fuera del viewport');
    const image = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false, clip: { ...snapshot.rect, scale: 1 } });
    writeFileSync(`${output}-${label}.png`, Buffer.from(image.data, 'base64'));
    writeFileSync(`${output}-${label}-innerText.txt`, snapshot.innerText);
    if (snapshot.accessibleName) writeFileSync(`${output}-${label}-aria.txt`, snapshot.accessibleName);
    report.captures.push({ label, ...snapshot, innerText: undefined });
    console.log(`CAPTURE=${label} PNG+innerText`);
  }
  // Sondeo dentro de la página: la MISMA lógica exportada, inyectada sin copia inline.
  const plazoEditorMs = 3000;
  const sondeoEnPagina = expresionSondeoEditor(plazoEditorMs);
  try {
    await wait('!!window.activeEditor && !!window.settingsPanel && !!window.router', 'objetos de cabina disponibles');
    saved = await evaluate(`({theme:window.themeManager.getCurrentThemeId(),view:window.router.getCurrent(),
      activity:document.querySelector('#panel-secondary').dataset.collapsed==='true',
      activityStorage:localStorage.getItem('devagents.panel.right'),
      settings:window.settingsPanel.section, discoveryTried:window.settingsPanel.autoDiscoverTried,
      tab:window.tabManager.getActiveTab()?.id||null})`);
    // Presentation traversal must not trigger provider discovery.
    await evaluate('window.settingsPanel.autoDiscoverTried=true');
    for (const width of [1024, 1440]) for (const scale of [1, 1.5]) {
      const sizeLabel = `${width}-${scale===1?'100':'150'}`;
      await send('Emulation.setDeviceMetricsOverride', { width: Math.round(width/scale), height: Math.round(960/scale), deviceScaleFactor: scale, mobile: false });
      // Titlebar, visible rail and command palette share one transition.
      if (await evaluate("document.querySelector('#panel-secondary').dataset.collapsed==='true'")) await click('#chat-btn-collapse');
      await physicalClick('#chat-btn-collapse');
      const control = await evaluate(`(() => {
        const p=document.querySelector('#panel-secondary'), b=document.querySelector('#chat-btn-collapse'), r=b.getBoundingClientRect();
        const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);
        return {collapsed:p.dataset.collapsed==='true', visible:r.width>0&&r.height>0&&r.x>=0&&r.right<=innerWidth,
          reachable:hit===b||b.contains(hit),title:b.title,aria:b.getAttribute('aria-expanded'),
          titleAria:document.querySelector('#btn-toggle-panel').getAttribute('aria-expanded'),
          popoutHidden:getComputedStyle(document.querySelector('#chat-btn-popout')).display==='none'};
      })()`);
      assert(control.collapsed && control.visible && control.reachable && control.popoutHidden, 'Riel colapsado no accesible');
      assert.equal(control.title, 'Desplegar panel de actividad');
      assert.equal(control.aria, 'false'); assert.equal(control.titleAria, 'false');
      // The collapsed rail has no body text; its canonical accessible name was
      // asserted above. Save the empty innerText honestly, along with geometry.
      await capture('#panel-secondary', `${sizeLabel}-actividad-colapsada`, '');
      await physicalClick('#chat-btn-collapse');
      assert(await evaluate("document.querySelector('#panel-secondary').dataset.collapsed==='false'"), 'Flecha visible no despliega');
      // Capture only the header to keep the owner's historical events private.
      await capture('#chat-header', `${sizeLabel}-actividad-desplegada`, 'Actividad');
      await click('#btn-toggle-panel');
      assert(await evaluate("document.querySelector('#chat-btn-collapse').title==='Desplegar panel de actividad'"), 'Barra de título desincronizada');
      await click('#btn-toggle-panel');
      await paletteToggle();
      assert(await evaluate("document.querySelector('#panel-secondary').dataset.collapsed==='true'"), 'Paleta desincronizada');
      await paletteToggle();
      report.scenarios.push({ activityWidth: width, scale, ...control });
      for (const section of sections) {
        await evaluate(`document.dispatchEvent(new CustomEvent('devagents:settings-section',{detail:${literal(section)}}))`);
        await wait(`document.querySelector('.settings-content')?.dataset.settingsSection===${literal(section)} && document.querySelector('#settings-body')?.getAttribute('aria-busy')==='false'`, `Configuración ${section}`);
        assert(await evaluate("!!document.querySelector('.settings-content .card')"), `Sin tarjetas: ${section}`);
        assert(!(await evaluate("!!document.querySelector('.settings-content [role=alert]')")), `Error visible en ${section}; comprobar el motor`);
        // Do not serialize input values or one-time remote credentials.
        await evaluate(`(() => {window.__relevoMasks=[];for(const el of document.querySelectorAll('#pane-settings-container input,#remote-once')){window.__relevoMasks.push([el,el.style.visibility]);el.style.visibility='hidden';}})()`);
        try { await capture('#pane-settings-container', `${sizeLabel}-config-${section}`, 'Configuración'); }
        finally { await evaluate("for(const [el,value] of window.__relevoMasks){el.style.visibility=value} delete window.__relevoMasks"); }
        await evaluate("document.querySelector('#settings-tabs button.is-active').focus()");
        await key('Tab', 9);
        assert(await evaluate("document.activeElement.matches(':focus-visible')"), `Sin foco visible ${section}`);
        report.scenarios.push({ settings: section, width, scale, rendered: true });
      }
    }
    // matriz de 21 extensiones × black/light × 100/150 con medición del
    // DOM renderizado, sondeo por frames y diagnóstico propio; NO se detiene en el primer fallo.
    const filas = [];
    try {
      for (const theme of ['black', 'light']) for (const scale of [1, 1.5]) {
        const esc = scale === 1 ? '100' : '150';
        await send('Emulation.setDeviceMetricsOverride', { width: Math.round(1440/scale), height: Math.round(960/scale), deviceScaleFactor: scale, mobile: false });
        await evaluate(`window.themeManager.applyTheme(${literal(theme)})`);
        for (const sample of paths) {
          const fila = { extension: sample.ext, tema: theme, escala: esc, veredicto: 'PENDIENTE', motivos: [] };
          filas.push(fila);
          try {
            await evaluate(`document.dispatchEvent(new CustomEvent('devagents:open-file',{detail:${literal(sample.path)}}))`);
            await wait(`window.activeEditor.getFilePath()===${literal(sample.path)} && window.activeEditor.getValue()===${literal(sample.content)} && !!window.activeEditor.monacoEd`, `abrir .${sample.ext} con puente real`);
            await wait(`window.monaco.editor.tokenize(${literal(sample.content)},${literal(sample.language)}).flat().some(t=>t.type)`, `gramática ${sample.language}`);
            const salida = await evaluate(sondeoEnPagina);
            const languageId = await evaluate(`window.activeEditor.monacoEd.getModel().getLanguageId()`);
            const estado = await evaluate(`document.querySelector('#editor-lang').textContent`);
            const tiposToken = (await evaluate(`[...new Set(window.monaco.editor.tokenize(${literal(sample.content)},${literal(sample.language)}).flat().map(t=>t.type))]`)).filter(Boolean);
            if (salida.error) fila.errorSondeo = salida.error;
            const sondeo = sintetizarSondeo(salida.lecturas || [], salida.vencido === true);
            Object.assign(fila, filaEditor({ extension: sample.ext, tema: theme, escala: esc, languageId, estado, tiposToken, sondeo }));
            assert.equal(fila.languageId, sample.language, `Detección .${sample.ext}`);
            fila.veredicto = veredictoFila(fila);
            if (fila.veredicto === 'FALLA') fila.motivos = motivosDeFila(fila);
            if (fila.veredicto === 'FALLA') console.log(`EDITOR FALLA ${tema}-${esc}-${sample.ext}: ${fila.motivos.join('; ')}`);
            try {
              await capture('#monaco-editor-container', `editor-${theme}-${esc}-${sample.ext}`, fila.estado);
              fila.captura = 'ok';
            } catch (errorCaptura) {
              fila.captura = `fallida: ${String(errorCaptura.message || errorCaptura).slice(0, 100)}`;
            }
            report.scenarios.push({ editor: sample.ext, theme, scale, ...fila });
          } catch (error) {
            fila.veredicto = 'FALLA';
            fila.motivos = [String(error.message || error).slice(0, 160)];
            report.scenarios.push({ editor: sample.ext, theme, scale, ...fila });
          }
        }
      }
    } finally {
      const resumen = resumenEditor(filas);
      report.editorMatriz = { resumen, filas };
      writeFileSync(`${output}-resumen-editor.json`, JSON.stringify({ resumen, filas }, null, 2));
      writeFileSync(`${output}-resumen-editor.txt`, tablaEditorTexto(filas));
      console.log(`RESUMEN editor: ${resumen.ok}/${resumen.total} ok; fallos=${resumen.fallos}; detalle=${output}-resumen-editor.json`);
    }
    return { total: filas.length, ok: filas.filter(f => f.veredicto === 'OK').length, falladas: filas.filter(f => f.veredicto !== 'OK').length };
  } finally {
    let restoreError;
    try {
      if (saved) {
        await evaluate(`(() => {
          const paths=${literal(paths.map(p => p.path))};for(const t of [...window.tabManager.getTabs()])if(paths.includes(t.path))window.tabManager.closeTab(t.id);
          const tab=window.tabManager.getTabs().find(t=>t.id===${literal(saved.tab)});if(tab)window.tabManager.openTab(tab.path,tab.title);
          window.themeManager.applyTheme(${literal(saved.theme)});
          window.settingsPanel.showSection(${literal(saved.settings)});window.router.show(${literal(saved.view)});
          window.settingsPanel.autoDiscoverTried=${literal(saved.discoveryTried)};
          const b=document.querySelector('#chat-btn-collapse');if((document.querySelector('#panel-secondary').dataset.collapsed==='true')!==${literal(saved.activity)})b.click();
          const value=${literal(saved.activityStorage)};value===null?localStorage.removeItem('devagents.panel.right'):localStorage.setItem('devagents.panel.right',value);
        })()`);
        await send('Emulation.clearDeviceMetricsOverride');
        report.relevoRestored = true;
      }
    } catch (error) { restoreError = error; report.relevoRestored = false; }
    rmSync(temp, { recursive: true, force: true });
    console.log('EDITOR_FIXTURE_REMOVED=true');
    if (restoreError) throw restoreError;
  }
}

// Sesión CDP del modo autónomo (réplica deliberada del andamiaje de cdp_ux_cabina.mjs;
// los dos drivers funcionan independientes y no comparten estado).
const argumentos = process.argv.slice(2);
const permitirPuerto = argumentos.includes('--permitir-puerto');
const port = process.env.DEVAGENTS_CDP_PORT || '9333';
const pause = ms => new Promise(resolvePause => setTimeout(resolvePause, ms));
export async function conectarRelevo() {
  validarPuertoPrueba(port, permitirPuerto);
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(10000) });
  assert(response.ok, `CDP HTTP ${response.status}`);
  const page = (await response.json()).find(p => p.type === 'page' && !p.url.includes('ventana='));
  assert(page, 'Cabina principal no disponible');
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  const pending = new Map();
  const errors = [];
  let nextId = 0;
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
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
  const send = (method, params = {}) => new Promise((resolveRequest, reject) => {
    const id = ++nextId;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 20000);
    pending.set(id, { resolve: resolveRequest, reject, timer });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    assert(!result.exceptionDetails, 'Evaluación CDP falló; no se exporta su contenido externo');
    return result.result.value;
  };
  const wait = async (expression, label, milliseconds = 20000) => {
    const until = Date.now() + milliseconds;
    while (Date.now() < until) {
      if (await evaluate(expression)) return;
      await pause(100);
    }
    throw new Error(`Timeout: ${label}`);
  };
  const click = async selector => {
    await evaluate(`(() => {const el=document.querySelector(${JSON.stringify(selector)});if(!el)throw Error('Control ausente');el.click();})()`);
    await pause(80);
  };
  const key = async (name, virtualKey, modifiers = 0) => {
    await send('Input.dispatchKeyEvent', { type: 'keyDown', key: name, code: name, windowsVirtualKeyCode: virtualKey, modifiers, ...(name === 'Enter' ? { text: '\r' } : {}) });
    await send('Input.dispatchKeyEvent', { type: 'keyUp', key: name, code: name, windowsVirtualKeyCode: virtualKey, modifiers });
    await pause(80);
  };
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
    send, evaluate, wait, click, key, errors,
    cerrar: () => { for (const request of pending.values()) clearTimeout(request.timer); socket.close(); },
  };
}

async function autonomo() {
  const posicionales = argumentos.filter(a => a !== '--permitir-puerto');
  const [carpeta, etiqueta] = posicionales;
  console.log(`COMMAND: node tools/cdp_relevo_scenarios.mjs ${carpeta || ''} ${etiqueta || ''}`.trimEnd());
  assert(posicionales.length === 2 && carpeta && etiqueta, 'Uso: node tools/cdp_relevo_scenarios.mjs <carpeta-evidencia> <etiqueta> [--permitir-puerto]');
  assert(/^\w[\w .-]*$/.test(etiqueta), 'Etiqueta con caracteres fuera de letra/dígito/espacio/punto/guion');
  validarPuertoPrueba(port, permitirPuerto);
  mkdirSync(resolve(carpeta), { recursive: true });
  const output = join(resolve(carpeta), etiqueta);
  const helpers = await conectarRelevo();
  const { send, evaluate, wait, click, key, errors, cerrar } = helpers;
  const report = { modo: 'relevo-autonomo', captures: [], scenarios: [] };
  try {
    const relevo = await runRelevoScenarios({ send, evaluate, wait, click, key, output, report });
    report.errors = errors;
    if (errors.length) {
      report.status = 'FAIL';
      report.resumen = `errores de consola=${errors.length}`;
      process.exitCode = 1;
    } else if (relevo.falladas) {
      report.status = 'FAIL';
      report.resumen = `editor fallas=${relevo.falladas}/${relevo.total}`;
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
    writeFileSync(`${output}.json`, JSON.stringify(report, null, 2));
    cerrar();
    console.log(`REPORT=${output}.json`);
    console.log(`EXIT_CODE=${process.exitCode || 0}`);
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  autonomo().catch(error => { console.error(error.message); console.log('EXIT_CODE=1'); process.exitCode = 1; });
}
