//! Gate funcional de navegador (BGATE-1).
//!
//! ## Por qué existe
//!
//! La orden 437 entregó cuatro archivos sintácticamente válidos, con `exit 0` en
//! su propia prueba y un auditor LLM dispuesto a firmarlos, y aun así la
//! calculadora no calculaba: `index.html` declara `<button type="button"
//! id="calculate">` y `app.js` escucha el `submit` del formulario. Ninguno de
//! los controles que había podía ver eso. El test generado construía un DOM
//! simulado —por el mismo flujo que escribió el código— y comprobaba su propia
//! simulación; el hash de artefactos comparaba memoria contra memoria.
//!
//! Este gate no simula nada: copia el entregable, le inyecta un guion PROPIO del
//! motor (este archivo, versionado y con pruebas, no generado por un modelo),
//! abre la página en el Edge instalado en modo headless y observa qué pasa de
//! verdad al pulsar cada control. Un control que no produce NINGÚN efecto
//! observable —ni cambio en el DOM, ni excepción, ni error de JS— es un defecto
//! concreto, atribuible a archivos concretos, no una opinión.
//! antes de declararlo muerto se busca también un efecto en secuencias cortas,
//! comparadas con y sin ese control sobre documentos nuevos.
//!
//! ## Por qué así y no con CDP ni con un navegador embebido
//!
//! Edge headless abre una ventana de aplicacion sin interfaz. El guion publica
//! el veredicto en el registro y la cierra al terminar. Se usa tiempo real:
//! el avance virtual disparaba los timeouts antes de cargar las muestras de
//! origen opaco. Sin WebSocket, sin puerto de depuración abierto,
//! sin dependencia de runtime nueva (ADR-B011 no autoriza ninguna) y sin
//! reutilizar el host propio de la cabina, que puede estar sirviendo al usuario.

const std = @import("std");
const executor = @import("executor.zig");
const workspace = @import("workspace.zig");
const confined_fs = @import("confined_fs.zig");

const windows = std.os.windows;

const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, n: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;
const GetFileAttributesA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;
}.GetFileAttributesA else @import("providers").posix_files.GetFileAttributesA;
const Sleep = @import("platform.zig").sleep;
const GetTickCount64 = @import("platform.zig").ticks;
const GetSystemTimeAsFileTime = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetSystemTimeAsFileTime(time: *windows.FILETIME) callconv(.winapi) void;
}.GetSystemTimeAsFileTime else @import("platform.zig").filetime;
const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFF_FFFF;
const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const FILE_SHARE_READ: u32 = 0x0000_0001;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

/// Nombre de la carpeta de trabajo del gate DENTRO de la carpeta de la orden.
/// Va ahí, y no en %TEMP%, por dos razones: el `cwd` del proceso hijo tiene que
/// caer dentro del workspace (política del executor) y el usuario tiene que
/// poder abrir exactamente lo que se ejecutó.
pub const GATE_DIR_NAME = ".devagents-gate";

/// Flags fijos con los que se lanza el navegador del gate. Son política de
/// seguridad, no preferencia: E3.39-E los verificó empíricamente (2026-09-20)
/// y cada uno existe para cerrar o documentar un vector concreto:
///
/// * `--no-sandbox`: sin esto, en este equipo Edge headless muere antes de
///   ejecutar nada (registro de CERO bytes, exit 0). Medido el 2026-09-08 con
///   y sin el flag, dentro y fuera del job object. Es el mismo requisito que
///   tienen los CI de Chromium. Queda anotado como lo que es: una caja menos,
///   compensada por el resto de esta lista.
/// * SIN `--allow-file-access-from-files`: con ese flag la página del gate
///   podía hacer `fetch("file:///C:/Windows/win.ini")` y leer su contenido —
///   vector de lectura/exfiltración de archivos locales confirmado con la
///   copia del gate tal cual se generaba. El gate no lo necesita: la página
///   se carga por URL file:// (navegación, permitida) y el veredicto viaja
///   por el registro de Chromium, no por XHR.
/// * `--proxy-server=127.0.0.1:1` + `--proxy-bypass-list="<-loopback>"`: la
///   página ejecuta código del entregable; sin salida de red real no puede
///   enviar `fetch`/`sendBeacon` a ningún servidor (ni siquiera localhost:
///   el bypass de loopback se ELIMINA con `<-loopback>` para que localhost
///   también pase por el proxy muerto). `--disable-background-networking`
///   solo calla los servicios internos de Chrome, NO la red iniciada por la
///   página — comprobado empíricamente con un mock en 127.0.0.1.
/// * El resto silencia arranque/ruido: perfil desechable por orden, sin
///   extensiones, sin sync, sin first-run.
///
/// Cualquier cambio aquí tiene que pasar por el test
/// `GATE_STATIC_FLAGS cierran file:// y la red de la pagina (E3.39-E)` y por
/// una verificación empírica igual que la de E3.39-E.
pub const GATE_STATIC_FLAGS = [_][]const u8{
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--disable-sync",
    "--disable-background-networking",
    // Sin caja de Chromium (ver docstring). Compensado por: página local copiada
    // por el motor, sin red de página (proxy muerto abajo), perfil desechable,
    // job object que mata al proceso al cerrarse y plazo duro de 20 s.
    "--no-sandbox",
    "--enable-logging",
    // Todo el tráfico de la página muere en un proxy inexistente. La lista de
    // bypass por defecto de Chromium excluye loopback del proxy; `<-loopback>`
    // retira esa excepción para que `fetch("http://127.0.0.1:...")` también
    // falle. El veredicto del gate viaja por `--log-file`, no por red.
    "--proxy-server=127.0.0.1:1",
    "--proxy-bypass-list=<-loopback>",
};

/// Nombre del guion conductor dentro de la copia. Empieza por `devagents_` para
/// que no colisione con un archivo del entregable.
pub const DRIVER_NAME = "devagents_browser_gate.js";

/// Marca que el guion publica en el DOM (tambien permite leer volcados previos).
const RESULT_ID = "devagents-gate-result";

/// Guion conductor. Es del MOTOR: no lo escribe ningún modelo, no se regenera
/// por orden y sus reglas son las mismas para todo entregable.
///
/// Tres decisiones que no son cosméticas:
///
/// 1. Se cancela la navegación por defecto en fase de CAPTURA (`submit` y click
///    sobre `<a href>`). `preventDefault` en captura NO detiene la propagación:
///    el manejador de la página se ejecuta igual, y lo único que se evita es que
///    el documento se recargue y se lleve por delante el resultado a medias.
/// 2. Los campos se rellenan ANTES de cada pulsación, con valores deterministas.
///    Un botón que sólo hace algo con datos dentro no puede quedar como muerto
///    por haber sido pulsado en vacío.
/// 3. La instantánea incluye los valores VIVOS de los campos, no sólo el HTML:
///    `innerHTML` no refleja lo que el JS escribe en `input.value`, y sin eso un
///    botón «Borrar» que sí funciona figuraría como muerto.
pub const DRIVER_JS =
    \\/* DevAgents browser gate v1 - conductor propio del motor.
    \\   Ejercita cada control de la pagina REAL en un navegador REAL y publica
    \\   hechos observables como JSON dentro del documento. */
    \\(function driver(probe, processDeadline) {
    \\  var R = { v: 1, errors: [], controls: [], fields: 0, navigation_blocked: 0 };
    \\  // Captura anterior a los clics. Cada muestra vuelve a ejecutar scripts en
    \\  // un origen opaco nuevo, con la misma URL base y los mismos flags de red.
    \\  var pristine = document.documentElement.outerHTML;
    \\  var wallNow = Date.now.bind(Date);
    \\  window.addEventListener('error', function (e) {
    \\    R.errors.push(String((e && e.message) || e));
    \\  });
    \\  window.addEventListener('unhandledrejection', function (e) {
    \\    R.errors.push('unhandledrejection: ' + String((e && e.reason) || ''));
    \\  });
    \\  document.addEventListener('submit', function (e) {
    \\    R.navigation_blocked++;
    \\    e.preventDefault();
    \\  }, true);
    \\  document.addEventListener('click', function (e) {
    \\    var t = e.target;
    \\    if (t && t.closest && t.closest('a[href]')) {
    \\      R.navigation_blocked++;
    \\      e.preventDefault();
    \\    }
    \\  }, true);
    \\
    \\  function label(el) {
    \\    var id = el.id ? '#' + el.id : (el.name ? '[name=' + el.name + ']' : '');
    \\    var txt = String(el.textContent || el.value || '').trim().slice(0, 40);
    \\    return el.tagName.toLowerCase() + id + (txt ? ' "' + txt + '"' : '');
    \\  }
    \\
    \\  function fields() {
    \\    return Array.prototype.slice.call(document.querySelectorAll('input, select, textarea'));
    \\  }
    \\
    \\  function seed(variant) {
    \\    var n = 0;
    \\    fields().forEach(function (el, i) {
    \\      var type = String(el.type || '').toLowerCase();
    \\      var tag = el.tagName.toLowerCase();
    \\      if (tag === 'select') {
    \\        if (el.options.length) { el.selectedIndex = variant ? Math.min(1, el.options.length - 1) : 0; n++; }
    \\      } else if (type === 'number' || type === 'range') {
    \\        el.value = variant ? (i === 0 ? '7' : '4') : (i === 0 ? '6' : '3'); n++;
    \\      } else if (type === 'checkbox' || type === 'radio') {
    \\        el.checked = !variant; n++;
    \\      } else if (type !== 'submit' && type !== 'button' && type !== 'reset' && type !== 'hidden') {
    \\        el.value = variant ? 'devagents-dos' : 'devagents'; n++;
    \\      }
    \\      try {
    \\        el.dispatchEvent(new Event('input', { bubbles: true }));
    \\        el.dispatchEvent(new Event('change', { bubbles: true }));
    \\      } catch (err) { /* un campo sin eventos no invalida la pasada */ }
    \\    });
    \\    if (!variant) R.fields = n;
    \\    return n;
    \\  }
    \\
    \\  // La salida observable SIN los valores de los campos. Compararla entre
    \\  // dos pasadas con entradas DISTINTAS dice si el control procesa lo que
    \\  // el usuario le da o produce siempre lo mismo: es el falso verde que
    \\  // demostro la auditoria del 09-09 (una calculadora que devolvia 999
    \\  // para 6+3 aprobaba igual que una correcta).
    \\  function salidaFiltrada() {
    \\    var t = textos();
    \\    var out = {};
    \\    Object.keys(t).forEach(function (k) {
    \\      if (k.slice(-8) !== ' [valor]') out[k] = t[k];
    \\    });
    \\    return out;
    \\  }
    \\
    \\  function mapasIguales(a, b) {
    \\    var ka = Object.keys(a), kb = Object.keys(b);
    \\    if (ka.length !== kb.length) return false;
    \\    for (var i = 0; i < ka.length; i++) {
    \\      if (a[ka[i]] !== b[ka[i]]) return false;
    \\    }
    \\    return true;
    \\  }
    \\
    \\  // Que algo cambie no dice QUE cambio. Sin esto, una calculadora que
    \\  // devuelve 999 para 6+3 aprueba igual que una correcta: las dos "hacen
    \\  // algo". Se recogen los textos hoja para poder contar el resultado
    \\  // observado, no solo su existencia.
    \\  function textos() {
    \\    var out = {};
    \\    var todos = document.body.querySelectorAll('*');
    \\    for (var i = 0; i < todos.length; i++) {
    \\      var el = todos[i];
    \\      if (el.children.length) continue;
    \\      var t = String(el.textContent || '').trim();
    \\      if (!t || t.length > 120) continue;
    \\      out[label(el)] = t;
    \\    }
    \\    fields().forEach(function (el) {
    \\      var v = String(el.value === undefined ? '' : el.value);
    \\      if (v.length && v.length <= 120) out[label(el) + ' [valor]'] = v;
    \\    });
    \\    return out;
    \\  }
    \\
    \\  function diferencias(antes, despues) {
    \\    var claves = {};
    \\    Object.keys(antes).forEach(function (k) { claves[k] = 1; });
    \\    Object.keys(despues).forEach(function (k) { claves[k] = 1; });
    \\    var cambios = [];
    \\    Object.keys(claves).forEach(function (k) {
    \\      var a = antes[k] === undefined ? '' : antes[k];
    \\      var d = despues[k] === undefined ? '' : despues[k];
    \\      if (a !== d) cambios.push(k + ': "' + a + '" -> "' + d + '"');
    \\    });
    \\    if (!cambios.length) return '';
    \\    var texto = cambios.slice(0, 3).join(' | ');
    \\    if (cambios.length > 3) texto += ' (+' + (cambios.length - 3) + ' mas)';
    \\    return texto;
    \\  }
    \\
    \\  function snapshot() {
    \\    var vals = fields().map(function (el) {
    \\      if (el.tagName.toLowerCase() === 'select') return el.selectedIndex + ':' + el.value;
    \\      if (el.type === 'checkbox' || el.type === 'radio') return String(el.checked);
    \\      return String(el.value);
    \\    });
    \\    return document.body.innerHTML + '\u0000' + vals.join('\u0001');
    \\  }
    \\
    \\  function controls() {
    \\    return Array.prototype.slice.call(document.querySelectorAll(
    \\      'button, input[type=submit], input[type=button], input[type=reset], [role=button], a[href]'
    \\    ));
    \\  }
    \\
    \\  function publish() {
    \\    var el = document.createElement('script');
    \\    el.type = 'application/json';
    \\    el.id = 'devagents-gate-result';
    \\    el.textContent = JSON.stringify(R);
    \\    document.body.appendChild(el);
    \\    document.title = 'devagents-gate-done';
    \\    // Segundo canal, el que no depende de que el proceso tenga consola.
    \\    try { console.log('DEVAGENTS_GATE_RESULT ' + JSON.stringify(R)); } catch (e) {}
    \\    window.close();
    \\  }
    \\
    \\  function start() {
    \\    if (probe) { runProbe(); return; }
    \\    var list = controls();
    \\    var salidas = [];    // salida filtrada tras pulsar el control i
    \\    var elementos = [];  // el propio control i, para la segunda pasada
    \\    seed(0);
    \\    var i = 0;
    \\    function step() {
    \\      if (i >= list.length) { variacion(); return; }
    \\      var el = list[i++];
    \\      var idx = R.controls.length;
    \\      var name = label(el);
    \\      var before = snapshot();
    \\      var textosAntes = textos();
    \\      var errs = R.errors.length;
    \\      var threw = null;
    \\      try { el.click(); } catch (e) { threw = String((e && e.message) || e); }
    \\      setTimeout(function () {
    \\        var after = snapshot();
    \\        R.controls.push({
    \\          control: name,
    \\          changed_dom: before !== after,
    \\          threw: threw,
    \\          errors: R.errors.length - errs,
    \\          cambio: diferencias(textosAntes, textos())
    \\        });
    \\        salidas[idx] = salidaFiltrada();
    \\        elementos[idx] = el;
    \\        seed(0);
    \\        step();
    \\      }, 0);
    \\    }
    \\    // Segunda pasada, con OTRAS entradas, sobre los controles que cambiaron
    \\    // el DOM. `entrada_ignorada` no altera el veredicto —el alcance sigue
    \\    // siendo efecto observable, y hay controles correctos con salida
    \\    // constante («Borrar»)— pero el hecho se publica: la salida no vario
    \\    // con la entrada, asi que ese control no puede estar procesandola.
    \\    function variacion() {
    \\      if (!R.fields) { contexto(); return; }
    \\      var j = 0;
    \\      function vstep() {
    \\        if (j >= R.controls.length) { contexto(); return; }
    \\        var idx = j++;
    \\        var c = R.controls[idx];
    \\        var el = elementos[idx];
    \\        if (!c.changed_dom || !el || !el.isConnected) { vstep(); return; }
    \\        seed(1);
    \\        try { el.click(); } catch (e) {}
    \\        setTimeout(function () {
    \\          if (mapasIguales(salidas[idx], salidaFiltrada())) c.entrada_ignorada = true;
    \\          vstep();
    \\        }, 0);
    \\      }
    \\      vstep();
    \\    }
    \\    step();
    \\  }
    \\
    \\  // Una sonda NO publica un veredicto: devuelve hechos al conductor padre.
    \\  // Cada secuencia empieza tras load con globals y DOM reinicializados.
    \\  function runProbe() {
    \\    var list = controls(), i = 0;
    \\    function reply(output) {
    \\      parent.postMessage({ nonce: probe.nonce, output: output, errors: R.errors }, '*');
    \\    }
    \\    seed(0);
    \\    function next() {
    \\      if (i >= probe.sequence.length) {
    \\        reply(textos());
    \\        return;
    \\      }
    \\      var el = list[probe.sequence[i++]];
    \\      if (!el || !el.isConnected) { reply(null); return; }
    \\      try { el.click(); } catch (e) { R.errors.push(String(e)); }
    \\      setTimeout(next, 0);
    \\    }
    \\    next();
    \\  }
    \\
    \\  function contexto() {
    \\    // Limites globales: 8 candidatos, 24 apoyos, 192 documentos, 768
    \\    // clics y 8000 ms cooperativos; cada documento tiene 1000 ms.
    \\    // No paran bucles sincronos: los corta el executor fuera del navegador.
    \\    // Solo arrancar con 8000 ms + 2000 ms de reserva hasta su plazo nativo.
    \\    // Agotar un limite NO demuestra efecto: el control sigue siendo muerto.
    \\    var candidates = [], anchors = [], list = controls();
    \\    R.controls.forEach(function (c, i) {
    \\      if (!c.changed_dom && !c.threw && !c.errors) candidates.push(i);
    \\      if (c.changed_dom && !c.threw && !c.errors && anchors.length < 2) anchors.push(i);
    \\    });
    \\    if (!candidates.length || !anchors.length || R.errors.length) { publish(); return; }
    \\    if (!Number.isFinite(processDeadline) || processDeadline - wallNow() < 10000) {
    \\      R.context_limit = 'sin presupuesto: se requieren 8000 ms mas 2000 ms de reserva';
    \\      publish(); return;
    \\    }
    \\    var finished = false, frame = null, timer = null, receive = null, count = 0, ci = 0;
    \\    var deadline = performance.now() + 8000;
    \\    function finish() {
    \\      if (finished) return;
    \\      finished = true;
    \\      clearTimeout(totalTimer);
    \\      clearTimeout(timer);
    \\      if (receive) window.removeEventListener('message', receive);
    \\      if (frame) frame.remove();
    \\      R.context_probes = count;
    \\      publish();
    \\    }
    \\    var totalTimer = setTimeout(finish, 8000);
    \\    function sample(sequence, done) {
    \\      if (finished) return;
    \\      if (count >= 192 || performance.now() >= deadline || processDeadline - wallNow() <= 2000) {
    \\        R.context_limit = 'presupuesto contextual agotado'; finish(); return;
    \\      }
    \\      count++;
    \\      // Reutiliza el CONTENEDOR, nunca el documento ni su heap, evitando
    \\      // acumular renderers bajo el job del executor. Cada navegacion
    \\      // reemplaza la entrada de historial y crea otro Window/DOM opaco.
    \\      var child = frame || document.createElement('iframe'), settled = false;
    \\      var nonce = Array.prototype.join.call(crypto.getRandomValues(new Uint32Array(4)), '-');
    \\      frame = child;
    \\      child.style.cssText = 'position:fixed;left:-10000px;width:1024px;height:768px';
    \\      child.setAttribute('aria-hidden', 'true');
    \\      child.setAttribute('sandbox', 'allow-scripts allow-forms');
    \\      child.name = '';
    \\      function complete(result) {
    \\        if (settled || finished) return;
    \\        settled = true;
    \\        clearTimeout(timer);
    \\        window.removeEventListener('message', receive);
    \\        receive = null;
    \\        if (result && result.errors.length) {
    \\          R.errors = R.errors.concat(result.errors);
    \\          finish();
    \\          return;
    \\        }
    \\        done(result && result.output);
    \\      }
    \\      receive = function (event) {
    \\        var data = event.data;
    \\        if (event.origin !== 'null' || event.source !== child.contentWindow ||
    \\            !data || data.nonce !== nonce || !Array.isArray(data.errors) ||
    \\            (data.output !== null && (typeof data.output !== 'object' || Array.isArray(data.output)))) return;
    \\        complete(data);
    \\      };
    \\      window.addEventListener('message', receive);
    \\      timer = setTimeout(function () {
    \\        R.errors.push('sondeo contextual sin respuesta en 1000 ms: posible cuelgue de la pagina');
    \\        finish();
    \\      }, 1000);
    \\      // El conductor va inline: el origen opaco no puede leer el archivo
    \\      // file:// del motor. No se abre acceso al padre ni a almacenamiento.
    \\      var source = '(' + driver.toString() + ')(' + JSON.stringify({ sequence: sequence, nonce: nonce }) + ',0);';
    \\      source = source.replace(/<\/script/gi, '<\\/script');
    \\      var sampleHtml = pristine.replace('<script src="devagents_browser_gate.js"></script>', function () {
    \\        return '<script>' + source + '</script>';
    \\      });
    \\      var base = document.createElement('base');
    \\      base.href = document.baseURI;
    \\      sampleHtml = sampleHtml.replace(/<head(?:\s[^>]*)?>/i, function (head) { return head + base.outerHTML; });
    \\      var dataUrl = 'data:text/html;charset=utf-8,' + encodeURIComponent(sampleHtml);
    \\      // srcdoc acumula historial conjunto: Chromium luego rechaza
    \\      // window.close(). replace evita ese bloqueo sin abrir permisos.
    \\      if (!child.isConnected) { child.src = dataUrl; document.body.appendChild(child); }
    \\      else child.contentWindow.location.replace(dataUrl);
    \\    }
    \\    function candidate() {
    \\      if (finished) return;
    \\      if (ci >= Math.min(8, candidates.length)) { clearTimeout(totalTimer); finish(); return; }
    \\      var target = candidates[ci++], support = 0, mode = 0;
    \\      var a = anchors[0], b = anchors[anchors.length - 1];
    \\      function trial() {
    \\        if (finished) return;
    \\        if (support >= Math.min(24, list.length)) { candidate(); return; }
    \\        var y = support;
    \\        // Inserta X entre entradas o al final de una secuencia preparada.
    \\        // No se reconocen etiquetas, operadores ni funciones de la pagina.
    \\        var without = mode ? [a, y, b] : [a, b, y];
    \\        var withTarget = mode ? [a, y, b, target] : [a, target, b, y];
    \\        mode = 1 - mode;
    \\        if (!mode) support++;
    \\        if (y === target) { trial(); return; }
    \\        sample(without, function (baseline) {
    \\          if (!baseline) { candidate(); return; }
    \\          sample(withTarget, function (observed) {
    \\            if (!observed) { candidate(); return; }
    \\            if (mapasIguales(baseline, observed)) { trial(); return; }
    \\            // Orden alternado sin X, con X, sin X, con X. Las DOS ramas
    \\            // deben reproducirse; una diferencia accidental no prueba causa.
    \\            sample(without, function (repeated) {
    \\              if (!repeated || !mapasIguales(baseline, repeated)) { trial(); return; }
    \\              sample(withTarget, function (repeatedTarget) {
    \\                if (!repeatedTarget || !mapasIguales(observed, repeatedTarget)) { trial(); return; }
    \\                var c = R.controls[target];
    \\                c.changed_context = true;
    \\                c.cambio = 'contexto [' + withTarget.map(function (i) { return label(list[i]); }).join(', ') +
    \\                  '] frente a [' + without.map(function (i) { return label(list[i]); }).join(', ') +
    \\                  ']: ' + diferencias(baseline, observed);
    \\                candidate();
    \\              });
    \\            });
    \\          });
    \\        });
    \\      }
    \\      trial();
    \\    }
    \\    candidate();
    \\  }
    \\
    \\  if (document.readyState === 'complete') setTimeout(start, 0);
    \\  else window.addEventListener('load', function () { setTimeout(start, 0); });
    \\})(null, Number(window.devagentsGateDeadline || 0));
    \\
;

/// Rutas canónicas de los navegadores comprobables, en orden de preferencia.
/// WebView2 —requisito de la cabina— viene del runtime de Edge, así que en un
/// equipo capaz de abrir DevAgents `msedge.exe` existe y es el primer candidato.
/// Chrome queda como respaldo porque hay instalaciones de Edge que arrancan,
/// salen con código 0 y no escriben NI UN BYTE —ni el volcado del DOM, ni el
/// registro de Chromium, ni siquiera `--version`— (medido el 2026-09-16 en este
/// equipo con perfil limpio dentro y fuera del job object del motor). Si no hay
/// ninguno, el gate lo DICE (no aprueba por defecto).
const BROWSER_CANDIDATES = [_][]const u8{
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
};

pub const Verdict = enum {
    /// Todos los controles observados produjeron algún efecto y no hubo errores JS.
    pass,
    /// Al menos un control no produjo efecto alguno, o la página lanzó errores.
    fail,
    /// No se pudo comprobar. NO es un aprobado.
    not_run,
};

pub const ControlObservation = struct {
    control: []const u8,
    changed_dom: bool,
    /// Efecto causal observado solo tras una secuencia en documentos nuevos.
    changed_context: bool = false,
    threw: ?[]const u8,
    errors: u32,
    /// QUE cambio al pulsarlo, no solo que cambiara algo. Vacio cuando no
    /// cambio nada. Es lo que permite leer «6 + 3 dio 999» en vez de «hizo
    /// algo», y por tanto lo unico que hace juzgable la correccion.
    cambio: []const u8 = "",
    /// La salida fue identica con DOS juegos de entradas distintos: el control
    /// no puede estar procesando lo que el usuario le da. Es un HECHO que se
    /// publica, no un veredicto —hay controles correctos con salida constante
    /// («Borrar»)— pero un falso verde deja de ser invisible.
    entrada_ignorada: bool = false,

    /// Sin efecto inmediato ni causal en contexto, ni excepción/error de JS.
    /// La ausencia de prueba contextual conserva el rechazo de la orden 437.
    pub fn isDead(self: ControlObservation) bool {
        return !self.changed_dom and !self.changed_context and self.threw == null and self.errors == 0;
    }
};

pub const Result = struct {
    ran: bool = false,
    verdict: Verdict = .not_run,
    /// Por qué no se pudo comprobar, cuando `ran == false`. Vacío si corrió.
    reason: []const u8 = "",
    /// Página realmente abierta (nombre de archivo), vacía si no hubo.
    page: []const u8 = "",
    /// Binario usado. Se informa para que la evidencia diga con qué se comprobó.
    browser: []const u8 = "",
    /// Carpeta con la copia ejecutada. El usuario puede abrirla tal cual.
    gate_dir: []const u8 = "",
    controls: []ControlObservation = &.{},
    js_errors: [][]const u8 = &.{},
    fields_seeded: u32 = 0,
    /// Huella de los bytes LEÍDOS DE DISCO de cada archivo del entregable, con
    /// su nombre. No es el hash de los artefactos en memoria: ese comparaba lo
    /// que el modelo dijo consigo mismo.
    files_digest: u64 = 0,
    files_checked: usize = 0,

    pub fn deadControls(self: Result) usize {
        var n: usize = 0;
        for (self.controls) |c| {
            if (c.isDead()) n += 1;
        }
        return n;
    }

    /// Controles cuya salida no vario con dos entradas distintas.
    pub fn invariantControls(self: Result) usize {
        var n: usize = 0;
        for (self.controls) |c| {
            if (c.entrada_ignorada) n += 1;
        }
        return n;
    }

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        for (self.controls) |c| {
            allocator.free(c.control);
            if (c.threw) |t| allocator.free(t);
            if (c.cambio.len > 0) allocator.free(c.cambio);
        }
        allocator.free(self.controls);
        for (self.js_errors) |e| allocator.free(e);
        allocator.free(self.js_errors);
        if (self.reason.len > 0) allocator.free(self.reason);
        if (self.page.len > 0) allocator.free(self.page);
        if (self.browser.len > 0) allocator.free(self.browser);
        if (self.gate_dir.len > 0) allocator.free(self.gate_dir);
    }
};

/// ¿Existe este ejecutable en disco? `candidate` es una ruta absoluta fija.
fn browserExists(candidate: []const u8) bool {
    var buf: [512]u8 = undefined;
    if (candidate.len >= buf.len) return false;
    @memcpy(buf[0..candidate.len], candidate);
    buf[candidate.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&buf);
    return GetFileAttributesA(z) != INVALID_FILE_ATTRIBUTES;
}

/// Localiza el navegador preferido. Devuelve un préstamo de
/// `BROWSER_CANDIDATES` (no liberar).
pub fn findBrowser() ?[]const u8 {
    for (BROWSER_CANDIDATES) |candidate| {
        if (browserExists(candidate)) return candidate;
    }
    return null;
}

/// ¿Este entregable es una página web comprobable? Lo es cuando entre los
/// archivos hay un `.html`/`.htm`. Se elige `index.html` si está.
pub fn pickPage(files: []const workspace.OrderFile) ?[]const u8 {
    var first: ?[]const u8 = null;
    for (files) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, "index.html")) return f.name;
        const ext = std.fs.path.extension(f.name);
        if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) {
            if (first == null) first = f.name;
        }
    }
    return first;
}

/// Inserta la etiqueta del conductor justo antes de `</body>`; si no hay body
/// cerrado (HTML parcial, que es legal), se añade al final. El archivo original
/// no se toca nunca: esto opera sobre la COPIA.
pub fn injectDriver(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const tag = "<script src=\"" ++ DRIVER_NAME ++ "\"></script>";
    if (indexOfIgnoreCase(html, "</body>")) |at| {
        return std.fmt.allocPrint(allocator, "{s}{s}\n{s}", .{ html[0..at], tag, html[at..] });
    }
    return std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ html, tag });
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Convierte una ruta de Windows en una URL `file://` que el navegador acepte.
///
/// No es cosmética. La carpeta del proyecto se llama «Proyecto - DevAgents
/// DevAgents», con espacios, y `std.fs.path.join` une con `\`. Pasarle eso tal cual
/// a Edge —`file:///C:\…\Proyecto - DevAgents Beats\…\index.html`— hace que la
/// página NO cargue: el navegador arranca, escribe su registro de arranque, no
/// ejecuta el conductor y sale con código 0. Desde fuera se ve exactamente
/// igual que «la comprobación no encontró nada», y el gate se saltaba solo.
///
/// Medido el 2026-09-08: la misma carpeta, el mismo navegador y los mismos
/// argumentos publican el veredicto en cuanto los espacios van como `%20`.
///
/// Se codifica todo lo que no sea del conjunto no reservado, dejando pasar `/`
/// (separador ya normalizado) y `:` (la letra de unidad).
pub fn fileUrl(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file:///");
    for (path) |c| {
        const seguro = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/', ':' => true,
            else => false,
        };
        if (c == '\\') {
            try out.append(allocator, '/');
        } else if (seguro) {
            try out.append(allocator, c);
        } else {
            var buf: [3]u8 = undefined;
            const hex = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch continue;
            try out.appendSlice(allocator, hex);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Marca con la que el conductor publica su veredicto por la consola del
/// navegador. Es el canal FIABLE.
pub const LOG_MARKER = "DEVAGENTS_GATE_RESULT ";

/// Extrae el JSON del registro de Chromium (`--enable-logging --log-file=…`).
///
/// ## Por qué el registro y no la salida estándar
///
/// `--dump-dom` escribe por `stdout`, y Chromium sólo enciende esa salida
/// cuando el proceso tiene CONSOLA. El motor lanza a sus hijos con
/// `CREATE_NO_WINDOW` —no queremos abrirle una ventana negra al usuario cada
/// vez que se comprueba una página—, así que el volcado llegaba VACÍO: exit 0,
/// cero bytes, y el gate se saltaba solo. Medido el 2026-09-08: la misma orden
/// devuelve el DOM lanzada desde PowerShell (que sí tiene consola) y nada
/// lanzada desde el motor o desde un shell sin consola.
///
/// El registro de Chromium sí es un archivo, y ahí van los `console.log` de la
/// página. Una línea tiene esta forma:
///
///     [...:INFO:CONSOLE(1)] "DEVAGENTS_GATE_RESULT {…}", source: file:///… (1)
///
/// Se toma la ÚLTIMA (una recarga dejaría dos) y se corta por el sufijo que
/// añade el propio registro.
pub fn extractResultFromLog(log: []const u8) ?[]const u8 {
    var at: ?usize = null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, log, from, LOG_MARKER)) |found| {
        at = found;
        from = found + LOG_MARKER.len;
    }
    const start = (at orelse return null) + LOG_MARKER.len;
    const line_end = std.mem.indexOfScalarPos(u8, log, start, '\n') orelse log.len;
    const line = log[start..line_end];
    const suffix = "\", source:";
    const end = std.mem.lastIndexOf(u8, line, suffix) orelse line.len;
    const json_text = std.mem.trim(u8, line[0..end], " \t\r\n");
    return if (json_text.len == 0) null else json_text;
}

/// Extrae el JSON publicado por el conductor del volcado del DOM.
pub fn extractResultJson(dump: []const u8) ?[]const u8 {
    const marker = "id=\"" ++ RESULT_ID ++ "\"";
    const at = std.mem.indexOf(u8, dump, marker) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, dump, at, '>') orelse return null;
    const start = gt + 1;
    const end = std.mem.indexOfPos(u8, dump, start, "</script>") orelse return null;
    if (end < start) return null;
    return std.mem.trim(u8, dump[start..end], " \t\r\n");
}

/// Convierte el JSON del conductor en observaciones tipadas.
pub fn parseObservations(allocator: std.mem.Allocator, json_text: []const u8, out: *Result) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return error.InvalidGateJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidGateJson;

    if (root.object.get("fields")) |f| {
        if (f == .integer and f.integer >= 0) out.fields_seeded = @intCast(f.integer);
    }

    var controls = std.ArrayList(ControlObservation).empty;
    errdefer {
        for (controls.items) |c| {
            allocator.free(c.control);
            if (c.threw) |t| allocator.free(t);
            if (c.cambio.len > 0) allocator.free(c.cambio);
        }
        controls.deinit(allocator);
    }
    if (root.object.get("controls")) |list| {
        if (list == .array) {
            for (list.array.items) |item| {
                if (item != .object) continue;
                const name_val = item.object.get("control") orelse continue;
                if (name_val != .string) continue;
                const changed = if (item.object.get("changed_dom")) |c| (c == .bool and c.bool) else false;
                const contextual = if (item.object.get("changed_context")) |c| (c == .bool and c.bool) else false;
                var threw: ?[]const u8 = null;
                if (item.object.get("threw")) |t| {
                    if (t == .string) threw = try allocator.dupe(u8, t.string);
                }
                var errs: u32 = 0;
                if (item.object.get("errors")) |e| {
                    if (e == .integer and e.integer > 0) errs = @intCast(e.integer);
                }
                var cambio: []const u8 = "";
                if (item.object.get("cambio")) |cv| {
                    if (cv == .string and cv.string.len > 0) cambio = try allocator.dupe(u8, cv.string);
                }
                var ignorada = false;
                if (item.object.get("entrada_ignorada")) |ig| {
                    if (ig == .bool) ignorada = ig.bool;
                }
                try controls.append(allocator, .{
                    .control = try allocator.dupe(u8, name_val.string),
                    .changed_dom = changed,
                    .changed_context = contextual,
                    .threw = threw,
                    .errors = errs,
                    .cambio = cambio,
                    .entrada_ignorada = ignorada,
                });
            }
        }
    }

    var errors = std.ArrayList([]const u8).empty;
    errdefer {
        for (errors.items) |e| allocator.free(e);
        errors.deinit(allocator);
    }
    if (root.object.get("errors")) |list| {
        if (list == .array) {
            for (list.array.items) |item| {
                if (item != .string) continue;
                try errors.append(allocator, try allocator.dupe(u8, item.string));
            }
        }
    }

    out.controls = try controls.toOwnedSlice(allocator);
    out.js_errors = try errors.toOwnedSlice(allocator);
    out.ran = true;
    out.verdict = if (out.deadControls() > 0 or out.js_errors.len > 0) .fail else .pass;
}

fn writeWhole(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const h = CreateFileA(z.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE_VALUE) return error.WriteFailed;
    defer _ = CloseHandle(h);
    var off: usize = 0;
    while (off < data.len) {
        var written: u32 = 0;
        const chunk: u32 = @intCast(@min(data.len - off, @as(usize, 1 << 20)));
        if (WriteFile(h, data.ptr + off, chunk, &written, null) == 0) return error.WriteFailed;
        if (written == 0) return error.WriteFailed;
        off += written;
    }
}

fn prepareGateCopies(allocator: std.mem.Allocator, root: *const confined_fs.Root, files: []const workspace.OrderFile, page: []const u8) !struct { digest: u64, count: usize } {
    try root.createDirPath(GATE_DIR_NAME);
    var hasher = std.hash.Wyhash.init(0);
    var count: usize = 0;
    var page_copied = false;
    for (files) |f| {
        if (std.mem.eql(u8, f.name, GATE_DIR_NAME)) continue;
        const body = root.readFileAlloc(allocator, f.name, 8 << 20) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        defer allocator.free(body);
        const destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ GATE_DIR_NAME, f.name });
        defer allocator.free(destination);
        if (std.ascii.eqlIgnoreCase(f.name, page)) {
            const injected = try injectDriver(allocator, body);
            defer allocator.free(injected);
            try root.writeFile(destination, injected);
            page_copied = true;
        } else {
            try root.writeFile(destination, body);
        }
        hasher.update(f.name);
        hasher.update(body);
        count += 1;
    }
    if (!page_copied) return error.GatePageMissing;
    try root.writeFile(GATE_DIR_NAME ++ "/" ++ DRIVER_NAME, DRIVER_JS);
    return .{ .digest = hasher.final(), .count = count };
}

fn resetGateProfile(root: *const confined_fs.Root, io: std.Io) !void {
    root.removeTree(io, GATE_DIR_NAME ++ "/profile") catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
}

/// Corre el gate sobre la carpeta de un entregable ya materializado.
///
/// `order_dir` es la carpeta REAL en disco (`…\orden-N`). Se leen sus archivos
/// del disco —no artefactos en memoria—, se copian a `order_dir\.devagents-gate`
/// y se abre ahí la página. El entregable no se toca.
pub fn run(
    allocator: std.mem.Allocator,
    order_dir: []const u8,
    timeout_ms: u32,
) !Result {
    var result = Result{};
    errdefer result.deinit(allocator);

    const files = workspace.listOrderFilesIn(allocator, order_dir) catch {
        result.reason = try allocator.dupe(u8, "no se pudo listar la carpeta del entregable");
        return result;
    };
    defer {
        for (files) |f| f.deinit(allocator);
        allocator.free(files);
    }

    const page = pickPage(files) orelse {
        result.reason = try allocator.dupe(u8, "el entregable no contiene una pagina HTML");
        return result;
    };

    var available: [BROWSER_CANDIDATES.len][]const u8 = undefined;
    var n_available: usize = 0;
    for (BROWSER_CANDIDATES) |candidate| {
        if (browserExists(candidate)) {
            available[n_available] = candidate;
            n_available += 1;
        }
    }
    if (n_available == 0) {
        result.reason = try allocator.dupe(u8, "no se encontro ningun navegador comprobable (Edge ni Chrome)");
        return result;
    }

    var root = try confined_fs.Root.initMutation(allocator, order_dir);
    defer root.deinit();
    const copied = try prepareGateCopies(allocator, &root, files, page);
    result.files_digest = copied.digest;
    result.files_checked = copied.count;
    const gate_dir = try std.fs.path.join(allocator, &.{ order_dir, GATE_DIR_NAME });
    result.gate_dir = gate_dir;
    const page_path = try std.fs.path.join(allocator, &.{ gate_dir, page });
    defer allocator.free(page_path);
    const url = try fileUrl(allocator, page_path);
    defer allocator.free(url);

    const profile = try std.fs.path.join(allocator, &.{ gate_dir, "profile" });
    defer allocator.free(profile);
    {
        // Heap allocation keeps the large I/O runtime off the DLL host stack.
        const threaded = try allocator.create(std.Io.Threaded);
        defer allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        try resetGateProfile(&root, threaded.io());
    }
    const profile_arg = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{profile});
    defer allocator.free(profile_arg);

    // --app permite cerrar la ventana headless desde publish(). El tiempo
    // virtual con --dump-dom expira antes de recibir postMessage de un iframe
    // opaco, incluso aunque la pagina sea correcta (R2).
    const app_arg = try std.fmt.allocPrint(allocator, "--app={s}", .{url});
    defer allocator.free(app_arg);

    // Canal fiable: el registro de Chromium es un ARCHIVO y no depende de que el
    // proceso tenga consola (ver `extractResultFromLog`).
    const log_path = try std.fs.path.join(allocator, &.{ gate_dir, "gate.log" });
    defer allocator.free(log_path);
    const log_arg = try std.fmt.allocPrint(allocator, "--log-file={s}", .{log_path});
    defer allocator.free(log_arg);

    // El sandbox del verificador se ancla a la carpeta REAL del entregable
    // (`order_dir`), no a la raiz efectiva del hilo. B3-SPACE-PER-ORDER lo
    // demostro en la orden #457: el override thread-local de la orden apunta al
    // worktree del space, pero los hilos worker escriben los artefactos en la
    // raiz global; con la raiz del hilo, `gate_dir` quedaba fuera del sandbox y
    // el gate moria con PathOutsideSandbox sin llegar a comprobar nada.
    // `order_dir` viene de rutas ya persistidas (la escritura paso su propia
    // validacion de sandbox) y `gate_dir` siempre cuelga de el.
    const ws_root = order_dir;

    const args = GATE_STATIC_FLAGS ++ [_][]const u8{
        log_arg,
        profile_arg,
        app_arg,
    };

    const policy = executor.Policy{
        .workspace_root = ws_root,
        .timeout_ms = timeout_ms,
        .max_output_bytes = 2 * 1024 * 1024,
        .origin = .local,
    };

    result.page = try allocator.dupe(u8, page);

    // Dos intentos. Un navegador recién cerrado deja procesos apagándose, y el
    // siguiente arranque puede salir con código 0 sin llegar a abrir la página:
    // medido el 2026-09-08 con dos comprobaciones seguidas, la primera publica
    // su veredicto y la segunda sale muda. Un gate que se salta por eso deja de
    // comprobar justo cuando alguien acaba de arreglar algo.
    //
    // El segundo intento va al OTRO navegador cuando existe: un arranque mudo
    // por estado residual no se contagia entre vendors, y un Edge roto de
    // fábrica (orden #515) deja de tumbar el gate entero. `result.browser`
    // registra el binario que produjo la observación —la trazabilidad es parte
    // del veredicto—.
    //
    // Reintentar NO ablanda el criterio: un control muerto sigue siendo un
    // control muerto en cualquiera de los dos intentos. Lo único que se
    // reintenta es la ARRANCADA.
    var intento: usize = 0;
    while (intento < 2) : (intento += 1) {
        if (intento > 0) Sleep(1500);

        const browser = available[@min(intento, n_available - 1)];
        if (result.browser.len > 0) allocator.free(result.browser);
        result.browser = try allocator.dupe(u8, browser);

        // Plazo ABSOLUTO anterior al spawn: incluye arranque y ambas pasadas,
        // no concede otros 6 s al empezar contexto. El executor sigue siendo
        // el limite real ante JS sincrono que impide ejecutar temporizadores.
        var ft: windows.FILETIME = undefined;
        GetSystemTimeAsFileTime(&ft);
        const unix_ms = ((@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime) / 10_000 -| 11_644_473_600_000;
        const timed_driver = try std.fmt.allocPrint(allocator, "window.devagentsGateDeadline={d};\n{s}", .{ unix_ms + timeout_ms, DRIVER_JS });
        defer allocator.free(timed_driver);
        try root.writeFile(GATE_DIR_NAME ++ "/" ++ DRIVER_NAME, timed_driver);

        const run_result = executor.runVerifierPinned(allocator, policy, browser, &args, gate_dir) catch |e| {
            if (result.reason.len > 0) allocator.free(result.reason);
            result.reason = try std.fmt.allocPrint(allocator, "el navegador {s} no pudo ejecutarse: {s}", .{ std.fs.path.basename(browser), @errorName(e) });
            continue;
        };
        defer run_result.deinit(allocator);

        // Nunca admitir un PASS parcial/antiguo del registro tras matar un
        // navegador colgado. El timeout no es una arrancada muda reintentable.
        if (run_result.timed_out) {
            if (result.reason.len > 0) allocator.free(result.reason);
            result.reason = try std.fmt.allocPrint(allocator, "cuelgue o falta de respuesta de la pagina: plazo externo del navegador agotado ({d} ms); proceso terminado sin reintento", .{timeout_ms});
            result.ran = true;
            result.verdict = .fail;
            return result;
        }

        // Registro primero: es el canal que funciona con o sin consola. El
        // volcado del DOM queda como respaldo para no perder una pasada que sí
        // lo trajo.
        const log_body: ?[]u8 = root.readFileAlloc(allocator, GATE_DIR_NAME ++ "/gate.log", 8 << 20) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        defer if (log_body) |b| allocator.free(b);

        const json_text = (if (log_body) |b| extractResultFromLog(b) else null) orelse
            extractResultJson(run_result.stdout);

        if (json_text) |texto_json| {
            if (result.reason.len > 0) {
                allocator.free(result.reason);
                result.reason = "";
            }
            parseObservations(allocator, texto_json, &result) catch {
                result.reason = try allocator.dupe(u8, "el resultado del gate no es JSON valido");
                return result;
            };
            return result;
        }

        if (result.reason.len > 0) allocator.free(result.reason);
        result.reason = try std.fmt.allocPrint(
            allocator,
            "el navegador no publico resultado (intento {d}, {s}, exit {d}, {d} bytes de DOM, {d} bytes de registro)",
            .{ intento + 1, std.fs.path.basename(browser), run_result.exit_code, run_result.stdout.len, if (log_body) |b| b.len else 0 },
        );
    }
    return result;
}

/// Texto legible del defecto, para la evidencia del auditor y la descripción de
/// la corrección. Nombra los controles muertos, que es lo único accionable.
pub fn describeFailure(allocator: std.mem.Allocator, result: Result) ![]u8 {
    if (result.reason.len > 0) return std.fmt.allocPrint(allocator, "BROWSER_GATE_FAILED: {s}", .{result.reason});
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "BROWSER_GATE_FAILED: la pagina se abrio en un navegador real y ");
    var dead_first = true;
    for (result.controls) |c| {
        if (!c.isDead()) continue;
        if (dead_first) {
            try out.appendSlice(allocator, "estos controles no producen ningun efecto al pulsarlos: ");
            dead_first = false;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try out.appendSlice(allocator, c.control);
    }
    if (dead_first) {
        try out.appendSlice(allocator, "la ejecucion produjo errores de JavaScript");
    }
    if (result.js_errors.len > 0) {
        try out.appendSlice(allocator, ". Errores de JavaScript: ");
        for (result.js_errors, 0..) |e, i| {
            if (i > 0) try out.appendSlice(allocator, " | ");
            try out.appendSlice(allocator, e);
        }
    }
    try out.appendSlice(
        allocator,
        ". Revisa que el manejador escuche el MISMO evento y el MISMO elemento que declara el HTML entregado" ++
            " (por ejemplo: un <button type=\"button\"> no dispara el 'submit' del formulario).",
    );
    return out.toOwnedSlice(allocator);
}

// ── Pruebas ────────────────────────────────────────────────────────────

test "BGATE-1: pickPage prefiere index.html sobre otro HTML" {
    const allocator = std.testing.allocator;
    const files = [_]workspace.OrderFile{
        .{ .name = try allocator.dupe(u8, "otra.html"), .size = 1 },
        .{ .name = try allocator.dupe(u8, "index.html"), .size = 1 },
        .{ .name = try allocator.dupe(u8, "app.js"), .size = 1 },
    };
    defer for (files) |f| f.deinit(allocator);
    try std.testing.expectEqualStrings("index.html", pickPage(&files).?);
}

test "BGATE-1: pickPage devuelve null sin HTML" {
    const allocator = std.testing.allocator;
    const files = [_]workspace.OrderFile{
        .{ .name = try allocator.dupe(u8, "app.js"), .size = 1 },
    };
    defer for (files) |f| f.deinit(allocator);
    try std.testing.expect(pickPage(&files) == null);
}

test "BGATE-1: injectDriver entra antes de </body> y no borra nada" {
    const allocator = std.testing.allocator;
    const html = "<html><body><p>hola</p></body></html>";
    const out = try injectDriver(allocator, html);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, DRIVER_NAME) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<p>hola</p>") != null);
    const script_at = std.mem.indexOf(u8, out, DRIVER_NAME).?;
    const body_at = std.mem.indexOf(u8, out, "</body>").?;
    try std.testing.expect(script_at < body_at);
}

test "BGATE-1: injectDriver tolera HTML sin </body>" {
    const allocator = std.testing.allocator;
    const out = try injectDriver(allocator, "<p>parcial</p>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, DRIVER_NAME) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<p>parcial</p>") != null);
}

test "BGATE-1: extractResultJson recupera el JSON del volcado" {
    const dump =
        "<html><body><script type=\"application/json\" id=\"devagents-gate-result\">" ++
        "{\"v\":1,\"controls\":[]}</script></body></html>";
    const json_text = extractResultJson(dump).?;
    try std.testing.expectEqualStrings("{\"v\":1,\"controls\":[]}", json_text);
    try std.testing.expect(extractResultJson("<html></html>") == null);
}

test "BGATE-1: la URL del entregable escapa los espacios de la carpeta del proyecto" {
    const allocator = std.testing.allocator;
    const url = try fileUrl(allocator, "C:\\Workspace\\Usuario\\Proyecto - DevAgents\\orden-437\\index.html");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "file:///C:/Workspace/Usuario/Proyecto%20-%20DevAgents/orden-437/index.html",
        url,
    );
    // Sin espacios ni caracteres raros, la URL es la de siempre.
    const simple = try fileUrl(allocator, "C:\\ws\\index.html");
    defer allocator.free(simple);
    try std.testing.expectEqualStrings("file:///C:/ws/index.html", simple);
    // Un `#` sin escapar cortaria la ruta y cargaria otra pagina.
    const raro = try fileUrl(allocator, "C:\\ws\\a#b\\index.html");
    defer allocator.free(raro);
    try std.testing.expectEqualStrings("file:///C:/ws/a%23b/index.html", raro);
}

test "BGATE-1: el veredicto se lee del registro cuando el volcado llega vacio" {
    // Linea REAL del registro de Chromium: asi la escribe con --enable-logging.
    const log =
        "[16044:9548:0908/163300.123:INFO:CONSOLE(1)] " ++
        "\"DEVAGENTS_GATE_RESULT {\"v\":1,\"controls\":[]}\", source: file:///C:/ws/index.html (1)\n";
    const json_text = extractResultFromLog(log).?;
    try std.testing.expectEqualStrings("{\"v\":1,\"controls\":[]}", json_text);
}

test "BGATE-1: con dos publicaciones manda la ultima" {
    const log =
        "[..] \"DEVAGENTS_GATE_RESULT {\"v\":1,\"fields\":1}\", source: file:///a (1)\n" ++
        "[..] \"DEVAGENTS_GATE_RESULT {\"v\":1,\"fields\":9}\", source: file:///a (1)\n";
    try std.testing.expectEqualStrings("{\"v\":1,\"fields\":9}", extractResultFromLog(log).?);
}

test "BGATE-1: un registro sin la marca no inventa un veredicto" {
    try std.testing.expect(extractResultFromLog("[..] INFO: nada que ver\n") == null);
    try std.testing.expect(extractResultFromLog("") == null);
}

test "BGATE-1: el conductor publica por los dos canales" {
    // Si alguien quita el console.log, el gate vuelve a depender de que el
    // proceso tenga consola — que es exactamente el fallo que se corrigio.
    try std.testing.expect(std.mem.indexOf(u8, DRIVER_JS, LOG_MARKER) != null);
    try std.testing.expect(std.mem.indexOf(u8, DRIVER_JS, RESULT_ID) != null);
}

test "BGATE-1: un control sin efecto observable es el defecto de la orden 437" {
    const allocator = std.testing.allocator;
    // Salida REAL del conductor sobre los artefactos de la orden 437.
    const json_text =
        \\{"v":1,"errors":[],"controls":[
        \\{"control":"button#calculate \"Calcular\"","changed_dom":false,"threw":null,"errors":0},
        \\{"control":"button#clear \"Borrar\"","changed_dom":true,"threw":null,"errors":0}],
        \\"fields":3}
    ;
    var result = Result{};
    defer result.deinit(allocator);
    try parseObservations(allocator, json_text, &result);
    try std.testing.expect(result.ran);
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expectEqual(@as(usize, 1), result.deadControls());
    try std.testing.expectEqual(@as(u32, 3), result.fields_seeded);

    const text = try describeFailure(allocator, result);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "button#calculate") != null);
    // Que «Borrar» funcione no compensa que «Calcular» no haga nada.
    try std.testing.expect(std.mem.indexOf(u8, text, "button#clear") == null);
}

test "BGATE-1: el gate dice QUE cambio, no solo que cambiara algo" {
    // Hallazgo H1 de la auditoria independiente del motor (09-09): una
    // calculadora que devuelve 999 para 6+3 aprobaba igual que una correcta,
    // porque las dos «hacen algo». El gate sigue midiendo alcance —no puede
    // saber que 6+3 son 9 sin que alguien se lo diga—, pero ahora publica el
    // valor observado, que es lo que hace juzgable la correccion aguas abajo.
    const allocator = std.testing.allocator;
    const json_text =
        \\{"v":1,"errors":[],"controls":[
        \\{"control":"button#calculate \"Calcular\"","changed_dom":true,"threw":null,"errors":0,
        \\ "cambio":"output#result: \"\" -> \"999\""}],
        \\"fields":3}
    ;
    var result = Result{};
    defer result.deinit(allocator);
    try parseObservations(allocator, json_text, &result);
    try std.testing.expectEqual(Verdict.pass, result.verdict);
    // Aprueba —el control reacciona— pero la evidencia lleva el 999 encima.
    try std.testing.expect(std.mem.indexOf(u8, result.controls[0].cambio, "999") != null);
}

test "BGATE-1: la salida constante con entradas distintas se publica como hecho" {
    // C1 (auditoría independiente del motor, 09-09): la calculadora que
    // devolvía 999 para 6+3 aprobaba porque «algo cambiaba». La segunda pasada
    // con otras entradas lo convierte en hecho visible: `entrada_ignorada`.
    // NO tumba el veredicto —el alcance sigue siendo efecto observable— pero
    // ya no es un verde invisible.
    const allocator = std.testing.allocator;
    const json_text =
        \\{"v":1,"errors":[],"controls":[
        \\{"control":"button#calculate \"Calcular\"","changed_dom":true,"threw":null,"errors":0,
        \\ "cambio":"output#result: \"\" -> \"999\"","entrada_ignorada":true}],
        \\"fields":3}
    ;
    var result = Result{};
    defer result.deinit(allocator);
    try parseObservations(allocator, json_text, &result);
    try std.testing.expectEqual(Verdict.pass, result.verdict);
    try std.testing.expect(result.controls[0].entrada_ignorada);
    try std.testing.expectEqual(@as(usize, 1), result.invariantControls());
}

test "BGATE-1: un control muerto no inventa un cambio" {
    const allocator = std.testing.allocator;
    const json_text =
        \\{"v":1,"errors":[],"controls":[
        \\{"control":"button#calculate","changed_dom":false,"threw":null,"errors":0,"cambio":""}],
        \\"fields":3}
    ;
    var result = Result{};
    defer result.deinit(allocator);
    try parseObservations(allocator, json_text, &result);
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expectEqualStrings("", result.controls[0].cambio);
}

test "BGATE-1: la misma pagina con el manejador correcto aprueba" {
    const allocator = std.testing.allocator;
    const json_text =
        \\{"v":1,"errors":[],"controls":[
        \\{"control":"button#calculate \"Calcular\"","changed_dom":true,"threw":null,"errors":0},
        \\{"control":"button#clear \"Borrar\"","changed_dom":true,"threw":null,"errors":0}],
        \\"fields":3}
    ;
    var result = Result{};
    defer result.deinit(allocator);
    try parseObservations(allocator, json_text, &result);
    try std.testing.expectEqual(Verdict.pass, result.verdict);
    try std.testing.expectEqual(@as(usize, 0), result.deadControls());
}

test "BGATE-1: un error de JavaScript tumba el gate aunque todo cambie el DOM" {
    const allocator = std.testing.allocator;
    const json_text =
        \\{"v":1,"errors":["module is not defined"],"controls":[
        \\{"control":"button#go","changed_dom":true,"threw":null,"errors":1}],"fields":1}
    ;
    var result = Result{};
    defer result.deinit(allocator);
    try parseObservations(allocator, json_text, &result);
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expectEqual(@as(usize, 0), result.deadControls());
    const text = try describeFailure(allocator, result);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "module is not defined") != null);
}

test "BGATE-1: sin resultado publicado el veredicto NO es aprobado" {
    const result = Result{};
    try std.testing.expectEqual(Verdict.not_run, result.verdict);
    try std.testing.expect(!result.ran);
}

// ── Contención de la página del gate (E3.39-E) ─────────────────────────
//
// El gate ejecuta código del ENTREGABLE dentro del navegador. La política de
// flags es lo único que separa a esa página del disco y de la red del equipo.
// Verificado empíricamente el 2026-09-20: con `--allow-file-access-from-files`
// la página leía `C:\Windows\win.ini` y lo enviaba por POST a un mock en
// 127.0.0.1; `--disable-background-networking` NO frenaba nada de eso.

test "E3.39-E: GATE_STATIC_FLAGS cierran file:// y la red de la pagina" {
    var tiene_no_sandbox = false;
    var tiene_proxy_muerto = false;
    var tiene_loopback_dentro = false;
    for (GATE_STATIC_FLAGS) |flag| {
        // El flag que permitía leer C:\Windows\win.ini por fetch/XHR.
        try std.testing.expect(std.mem.indexOf(u8, flag, "allow-file-access") == null);
        // Ningún puerto de depuración abierto en el navegador del gate.
        try std.testing.expect(std.mem.indexOf(u8, flag, "remote-debugging") == null);
        if (std.mem.eql(u8, flag, "--no-sandbox")) tiene_no_sandbox = true;
        if (std.mem.eql(u8, flag, "--proxy-server=127.0.0.1:1")) tiene_proxy_muerto = true;
        if (std.mem.eql(u8, flag, "--proxy-bypass-list=<-loopback>")) tiene_loopback_dentro = true;
    }
    try std.testing.expect(tiene_no_sandbox);
    // El par proxy-muerto/bypass es lo que impide a la página hacer fetch o
    // sendBeacon a cualquier destino, incluido localhost.
    try std.testing.expect(tiene_proxy_muerto);
    try std.testing.expect(tiene_loopback_dentro);
}

/// Página hostil: si el navegador le deja leer file://, crea un botón que el
/// conductor encontrará y pulsará. Con la contención correcta el XHR falla y
/// el control jamás existe — el gate no ve ningún control.
const PAGINA_EXFIL_HTML =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="UTF-8"><title>exfil</title></head>
    \\<body>
    \\<script>
    \\try {
    \\  var xhr = new XMLHttpRequest();
    \\  xhr.open('GET', 'file:///C:/Windows/win.ini', false);
    \\  xhr.send();
    \\  if (xhr.responseText && xhr.responseText.length > 0) {
    \\    var b = document.createElement('button');
    \\    b.id = 'exfil-leak-btn';
    \\    b.textContent = 'exfil';
    \\    b.onclick = function() { document.body.dataset.leak = '1'; };
    \\    document.body.appendChild(b);
    \\  }
    \\} catch (e) { /* lectura bloqueada: comportamiento correcto */ }
    \\</script>
    \\</body></html>
;

test "E3.39-E E2E: la pagina del gate no puede leer archivos locales" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el gate de navegador solo busca Edge/Chrome en rutas de Windows; en Linux no esta disponible (L12, Fase 2)");
    if (findBrowser() == null) {
        std.debug.print("BGATE E2E: no hay navegador instalado\n", .{});
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;

    var root_buf: [4096]u8 = undefined;
    const ws_root = workspace.effectiveRoot(&root_buf);
    // La raíz S2 no existe si este filtro corre solo, pero bajo la suite YA
    // existe: alguna prueba previa la creó con la ACL heredada del temporal del
    // runner. `ensureExternalRoot` la somete al gate de la CLI externa
    // (`checkAcl` -> `CliWritableByOthers`, external_cli_policy.zig:309) y
    // abortaba ESTA prueba de seguridad ANTES de abrir el navegador (medido el
    // 16-oct en test-core completo: 1658/1659). La carpeta del fixture no es una
    // instalación de CLI externa: se prepara como el resto de E2E del gate
    // (`prepararEntregable`), creando la raíz y la carpeta del entregable con
    // `CreateDirectoryA` directamente. La aserción que importa —que la página no
    // pueda leer archivos locales— no se toca ni se relaja.
    {
        const root_z = try allocator.dupeZ(u8, ws_root);
        defer allocator.free(root_z);
        _ = CreateDirectoryA(root_z.ptr, null);
    }
    const dir = try std.fs.path.join(allocator, &.{ ws_root, "gate-e339-exfil" });
    defer allocator.free(dir);
    {
        const dir_z = try allocator.dupeZ(u8, dir);
        defer allocator.free(dir_z);
        _ = CreateDirectoryA(dir_z.ptr, null);
    }
    const html_path = try std.fs.path.join(allocator, &.{ dir, "index.html" });
    defer allocator.free(html_path);
    try writeWhole(allocator, html_path, PAGINA_EXFIL_HTML);

    var res = try run(allocator, dir, 20_000);
    defer res.deinit(allocator);
    if (!res.ran) {
        std.debug.print("browser gate no pudo correr: {s}\n", .{res.reason});
        return error.SkipZigTest;
    }
    // Si la página hubiera podido leer win.ini habría creado el botón y el
    // conductor lo habría pulsado: controls estaría no vacío y llevaría su id.
    for (res.controls) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c.control, "exfil-leak") == null);
    }
}

// ── Reproducción de la orden 437 contra un navegador real ──────────────
//
// Estos dos casos no comprueban el parser: lanzan el Edge instalado sobre los
// MISMOS archivos que entregó la orden 437 y sobre la variante con el manejador
// corregido. Es la única forma de afirmar que este gate distingue el producto
// roto del reparado, y no sólo que sabe leer un JSON.
//
// Si el equipo no tiene Edge, el caso se salta explícitamente: un gate que no
// pudo correr NO es un aprobado, ni aquí ni en producción.

const ORDEN_437_HTML =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head><meta charset="UTF-8"><title>Calculadora Web</title></head>
    \\<body>
    \\    <form id="calculator">
    \\        <input type="number" id="a" placeholder="Primer numero">
    \\        <select id="op"><option value="+">Suma</option><option value="-">Resta</option></select>
    \\        <input type="number" id="b" placeholder="Segundo numero">
    \\        <button type="button" id="calculate">Calcular</button>
    \\        <button type="button" id="clear">Borrar</button>
    \\        <output id="result"></output>
    \\    </form>
    \\    <script src="app.js"></script>
    \\</body>
    \\</html>
;

/// Tal cual lo entregó la orden 437: el manejador cuelga del `submit` del
/// formulario, que un `<button type="button">` no dispara nunca.
const ORDEN_437_APP_JS =
    \\const calculate = (a, op, b) => (op === '+' ? a + b : a - b);
    \\document.querySelector('form#calculator').addEventListener('submit', (event) => {
    \\  event.preventDefault();
    \\  const a = parseFloat(document.querySelector('input#a').value) || 0;
    \\  const b = parseFloat(document.querySelector('input#b').value) || 0;
    \\  document.querySelector('output#result').textContent = calculate(a, document.querySelector('select#op').value, b);
    \\});
    \\document.querySelector('button#clear').addEventListener('click', () => {
    \\  document.querySelector('input#a').value = '';
    \\  document.querySelector('input#b').value = '';
    \\  document.querySelector('output#result').textContent = '';
    \\});
;

/// La misma pieza con el único cambio que la orden necesitaba: escuchar el
/// click del botón que el HTML declara de verdad.
const ORDEN_437_APP_JS_CORREGIDO =
    \\const calculate = (a, op, b) => (op === '+' ? a + b : a - b);
    \\document.querySelector('button#calculate').addEventListener('click', () => {
    \\  const a = parseFloat(document.querySelector('input#a').value) || 0;
    \\  const b = parseFloat(document.querySelector('input#b').value) || 0;
    \\  document.querySelector('output#result').textContent = calculate(a, document.querySelector('select#op').value, b);
    \\});
    \\document.querySelector('button#clear').addEventListener('click', () => {
    \\  document.querySelector('input#a').value = '';
    \\  document.querySelector('input#b').value = '';
    \\  document.querySelector('output#result').textContent = '';
    \\});
;

/// La pieza de la auditoría del 09-09: el manejador escucha el click correcto
/// y la página «hace algo», pero devuelve 999 para cualquier entrada. Con la
/// segunda pasada de entradas el gate lo publica como `entrada_ignorada`.
const FALSO_VERDE_APP_JS =
    \\document.querySelector('button#calculate').addEventListener('click', () => {
    \\  document.querySelector('output#result').textContent = '999';
    \\});
    \\document.querySelector('button#clear').addEventListener('click', () => {
    \\  document.querySelector('input#a').value = '';
    \\  document.querySelector('input#b').value = '';
    \\  document.querySelector('output#result').textContent = '';
    \\});
;

fn prepararEntregable(allocator: std.mem.Allocator, nombre: []const u8, app_js: []const u8) ![]u8 {
    var root_buf: [4096]u8 = undefined;
    const ws_root = workspace.effectiveRoot(&root_buf);
    {
        const root_z = try allocator.dupeZ(u8, ws_root);
        defer allocator.free(root_z);
        _ = CreateDirectoryA(root_z.ptr, null);
    }
    const dir = try std.fs.path.join(allocator, &.{ ws_root, nombre });
    errdefer allocator.free(dir);
    {
        const dir_z = try allocator.dupeZ(u8, dir);
        defer allocator.free(dir_z);
        _ = CreateDirectoryA(dir_z.ptr, null);
    }
    const html_path = try std.fs.path.join(allocator, &.{ dir, "index.html" });
    defer allocator.free(html_path);
    const js_path = try std.fs.path.join(allocator, &.{ dir, "app.js" });
    defer allocator.free(js_path);
    try writeWhole(allocator, html_path, ORDEN_437_HTML);
    try writeWhole(allocator, js_path, app_js);
    return dir;
}

test "BGATE-1 E2E: el navegador real reprueba la orden 437 y aprueba su correccion" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el gate de navegador solo busca Edge/Chrome en rutas de Windows; en Linux no esta disponible (L12, Fase 2)");
    if (findBrowser() == null) {
        std.debug.print("BGATE E2E: no hay navegador instalado\n", .{});
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;

    // 1. Tal como se entregó: «Calcular» no hace nada.
    const dir_roto = try prepararEntregable(allocator, "gate-437-roto", ORDEN_437_APP_JS);
    defer allocator.free(dir_roto);
    var roto = try run(allocator, dir_roto, 20_000);
    defer roto.deinit(allocator);
    if (!roto.ran) {
        // Sin navegador utilizable no se afirma nada: se dice y se salta.
        std.debug.print("browser gate no pudo correr: {s}\n", .{roto.reason});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(Verdict.fail, roto.verdict);
    try std.testing.expectEqual(@as(usize, 1), roto.deadControls());
    try std.testing.expectEqualStrings("index.html", roto.page);
    // La huella corresponde a los DOS archivos leídos del disco.
    try std.testing.expectEqual(@as(usize, 2), roto.files_checked);
    try std.testing.expect(roto.files_digest != 0);

    const detalle = try describeFailure(allocator, roto);
    defer allocator.free(detalle);
    try std.testing.expect(std.mem.indexOf(u8, detalle, "calculate") != null);

    // 2. Con el manejador que el HTML sí dispara: los dos controles reaccionan.
    const dir_ok = try prepararEntregable(allocator, "gate-437-corregido", ORDEN_437_APP_JS_CORREGIDO);
    defer allocator.free(dir_ok);
    var ok = try run(allocator, dir_ok, 20_000);
    defer ok.deinit(allocator);
    if (!ok.ran) {
        std.debug.print("BGATE E2E: la pasada corregida no publico resultado: {s}\n", .{ok.reason});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(Verdict.pass, ok.verdict);
    try std.testing.expectEqual(@as(usize, 0), ok.deadControls());
    try std.testing.expectEqual(@as(usize, 2), ok.controls.len);
    // Los bytes comprobados son distintos: el gate no reutilizó la pasada anterior.
    try std.testing.expect(ok.files_digest != roto.files_digest);
    // C1: la calculadora correcta responde distinto a 6+3 que a 7-4 — el
    // control de cálculo NO sale marcado como de entrada ignorada.
    for (ok.controls) |c| {
        if (std.mem.indexOf(u8, c.control, "calculate") != null)
            try std.testing.expect(!c.entrada_ignorada);
    }
}

test "BGATE-1 E2E: el falso verde de la auditoría queda publicado" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el gate de navegador solo busca Edge/Chrome en rutas de Windows; en Linux no esta disponible (L12, Fase 2)");
    if (findBrowser() == null) {
        std.debug.print("BGATE E2E: no hay navegador instalado\n", .{});
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;

    // La calculadora que devuelve 999 para todo: pasa el efecto observable,
    // pero la segunda pasada con otras entradas delata la salida constante.
    const dir_999 = try prepararEntregable(allocator, "gate-falso-verde", FALSO_VERDE_APP_JS);
    defer allocator.free(dir_999);
    var fv = try run(allocator, dir_999, 20_000);
    defer fv.deinit(allocator);
    if (!fv.ran) {
        std.debug.print("browser gate no pudo correr: {s}\n", .{fv.reason});
        return error.SkipZigTest;
    }
    // El alcance no cambia: el control sí reacciona — el veredicto es pass.
    try std.testing.expectEqual(Verdict.pass, fv.verdict);
    var marcado = false;
    for (fv.controls) |c| {
        if (std.mem.indexOf(u8, c.control, "calculate") != null and c.entrada_ignorada) marcado = true;
    }
    try std.testing.expect(marcado);
    try std.testing.expect(fv.invariantControls() >= 1);
}

fn runCalc876Fixture(name: []const u8, html: []const u8) !Result {
    return runGateFixture(name, html, 20_000);
}

fn runGateFixture(name: []const u8, html: []const u8, timeout_ms: u32) !Result {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el gate de navegador solo busca Edge/Chrome en rutas de Windows; en Linux no esta disponible (L12, Fase 2)");
    const a = std.testing.allocator;
    const dir = try prepararEntregable(a, name, "// fixture de navegador");
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "index.html" });
    defer a.free(path);
    try writeWhole(a, path, html);
    var result = try run(a, dir, timeout_ms);
    errdefer result.deinit(a);
    std.debug.print("CK-MOT-024 {s}: ran={} verdict={s} dead={d} js_errors={d} browser={s} reason={s}\n", .{
        name, result.ran, @tagName(result.verdict), result.deadControls(), result.js_errors.len, result.browser, result.reason,
    });
    for (result.controls) |c| std.debug.print("  {s}: changed={} dead={} cambio={s}\n", .{ c.control, c.changed_dom, c.isDead(), c.cambio });
    for (result.js_errors) |e| std.debug.print("  JS: {s}\n", .{e});
    if (!std.mem.eql(u8, name, "gate-876-v2") and result.js_errors.len > 0) {
        var root = try confined_fs.Root.initMutation(a, dir);
        defer root.deinit();
        const log = try root.readFileAlloc(a, GATE_DIR_NAME ++ "/gate.log", 1 << 20);
        defer a.free(log);
        std.debug.print("R2 CHROMIUM LOG:\n{s}\n", .{log});
    }
    // No SkipZigTest: estas pruebas requieren observaciones del navegador real.
    try std.testing.expect(result.ran);
    return result;
}

test "CK-MOT-024 calculadora v1 correcta aprueba con efectos en contexto" {
    var result = try runCalc876Fixture("gate-876-v1", @embedFile("fixtures/browser_gate/index-v1-correcta.html"));
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 17), result.controls.len);
    try std.testing.expectEqual(@as(usize, 0), result.js_errors.len);
    try std.testing.expectEqual(@as(usize, 0), result.deadControls());
    try std.testing.expectEqual(Verdict.pass, result.verdict);
    var contextual: usize = 0;
    for (result.controls) |c| {
        if (std.mem.eql(u8, c.control, "button \"+\"") or
            std.mem.eql(u8, c.control, "button \"/\"") or
            std.mem.eql(u8, c.control, "button \"=\""))
        {
            try std.testing.expect(!c.changed_dom);
            try std.testing.expect(c.changed_context);
            try std.testing.expect(std.mem.startsWith(u8, c.cambio, "contexto ["));
            contextual += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), contextual);
}

fn expectCalc876DeadPlus(replacement: []const u8, name: []const u8) !void {
    const a = std.testing.allocator;
    const original = @embedFile("fixtures/browser_gate/index-v1-correcta.html");
    const handler = "onclick=\"setOperation('+')\"";
    const at = std.mem.indexOf(u8, original, handler).?;
    const html = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ original[0..at], replacement, original[at + handler.len ..] });
    defer a.free(html);
    var result = try runCalc876Fixture(name, html);
    defer result.deinit(a);
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expectEqual(@as(usize, 1), result.deadControls());
    try std.testing.expectEqual(@as(usize, 0), result.js_errors.len);
    for (result.controls) |c| {
        if (std.mem.indexOf(u8, c.control, "\"+\"") != null) {
            try std.testing.expect(c.isDead());
            return;
        }
    }
    return error.PlusControlMissing;
}

test "CK-MOT-024 calculadora con manejador de mas vacio falla" {
    try expectCalc876DeadPlus("onclick=\"\"", "gate-876-noop");
}

test "CK-MOT-024 calculadora sin manejador de mas falla" {
    try expectCalc876DeadPlus("", "gate-876-no-handler");
}

test "CK-MOT-024 calculadora v2 rota falla por errores JS" {
    var result = try runCalc876Fixture("gate-876-v2", @embedFile("fixtures/browser_gate/index-v2-reparacion-rota.html"));
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expect(result.js_errors.len > 0);
}

test "CK-MOT-024 evidencia contextual no oculta errores JS y ausencia conserva FAIL" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "{\"errors\":[],\"controls\":[{\"control\":\"X\",\"changed_dom\":false}]}",
        "{\"errors\":[\"SyntaxError\"],\"controls\":[{\"control\":\"X\",\"changed_dom\":false,\"changed_context\":true}]}",
    }, 0..) |json, i| {
        var result = Result{};
        defer result.deinit(a);
        try parseObservations(a, json, &result);
        try std.testing.expectEqual(Verdict.fail, result.verdict);
        try std.testing.expectEqual(i == 1, result.controls[0].changed_context);
        try std.testing.expectEqual(@as(usize, if (i == 0) 1 else 0), result.deadControls());
    }
}

test "CK-MOT-024 R2 salida aleatoria no rescata X sin manejador" {
    const a = std.testing.allocator;
    var html = std.ArrayList(u8).empty;
    defer html.deinit(a);
    try html.appendSlice(a, "<html><body><output id='out'>0</output><span id='noise'></span>");
    // La masa estable permite reproducir el falso PASS anterior: sin X se
    // repite 'stable', con X aparece un valor aleatorio NO reproducible.
    // 24 apoyos dan 48 secuencias; el valor aleatorio tiene precision completa.
    for (0..24) |_| try html.appendSlice(a, "<button onclick='out.textContent=++n'>A</button>");
    try html.appendSlice(a, "<button id='dead'>X</button><script>var n=0;" ++
        "noise.textContent=Math.random()<2/3?'stable':String(Math.random());</script></body></html>");
    var result = try runCalc876Fixture("gate-r2-random", html.items);
    defer result.deinit(a);
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expectEqual(@as(usize, 0), result.js_errors.len);
    try std.testing.expectEqual(@as(usize, 1), result.deadControls());
    try std.testing.expect(result.controls[24].isDead());
}

test "CK-MOT-024 R2 muestras no acceden al padre ni a localStorage" {
    const a = std.testing.allocator;
    const original = @embedFile("fixtures/browser_gate/index-v1-correcta.html");
    const attack =
        "<script>if(window!==window.top){if(window.name)throw new Error('sample name leaked');window.name='sample-only';var blocked=0;" ++
        "try{parent.document.body.dataset.breach='yes';" ++
        "parent.dispatchEvent(new ErrorEvent('error',{message:'sample accessed parent'}));}catch(e){blocked++;}" ++
        "try{localStorage.setItem('gate-r2-sample','breach');" ++
        "parent.dispatchEvent(new ErrorEvent('error',{message:'sample accessed storage'}));}catch(e){blocked++;}" ++
        "parent.postMessage({nonce:'wrong',output:{},errors:['forged sample']},'*');" ++
        "if(blocked!==2)throw new Error('sample isolation failed');}</script>";
    const at = std.mem.indexOf(u8, original, "</body>").?;
    const html = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ original[0..at], attack, original[at..] });
    defer a.free(html);
    var result = try runCalc876Fixture("gate-r2-isolation", html);
    defer result.deinit(a);
    try std.testing.expectEqual(Verdict.pass, result.verdict);
    try std.testing.expectEqual(@as(usize, 0), result.js_errors.len);
    try std.testing.expectEqual(@as(usize, 0), result.deadControls());
}

test "CK-MOT-024 R2 no inicia contexto sin presupuesto reservado" {
    var result = try runGateFixture("gate-r2-budget", @embedFile("fixtures/browser_gate/index-v1-correcta.html"), 5_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expect(result.deadControls() >= 1);
    for (result.controls) |c| try std.testing.expect(!c.changed_context);
}

test "CK-MOT-024 R2 bucle sincrono falla por plazo externo sin reintento" {
    const started = GetTickCount64();
    var result = try runGateFixture("gate-r2-hang", "<html><body><button onclick='while(true){}'>Loop</button></body></html>", 4_000);
    defer result.deinit(std.testing.allocator);
    const elapsed = GetTickCount64() - started;
    std.debug.print("R2 HANG elapsed_ms={d} timeout_ms=4000 reason={s}\n", .{ elapsed, result.reason });
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expect(std.mem.indexOf(u8, result.reason, "plazo externo") != null);
    const description = try describeFailure(std.testing.allocator, result);
    defer std.testing.allocator.free(description);
    try std.testing.expect(std.mem.indexOf(u8, description, "cuelgue") != null);
    try std.testing.expect(elapsed < 7_000);
}

test "CK-MOT-024 R2 bucle en muestra contextual falla dentro del plazo" {
    const started = GetTickCount64();
    var result = try runGateFixture("gate-r2-context-hang", "<html><body><output id='out'>0</output><button onclick='out.textContent=++n'>A</button>" ++
        "<button onclick='if(window!==window.top){while(true){}}'>X</button><script>var n=0;</script></body></html>", 12_000);
    defer result.deinit(std.testing.allocator);
    const elapsed = GetTickCount64() - started;
    std.debug.print("R2 CONTEXT HANG elapsed_ms={d} timeout_ms=12000 reason={s}\n", .{ elapsed, result.reason });
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    var hang_reported = std.mem.indexOf(u8, result.reason, "plazo externo") != null;
    for (result.js_errors) |e| {
        if (std.mem.indexOf(u8, e, "posible cuelgue") != null) hang_reported = true;
    }
    try std.testing.expect(hang_reported);
    try std.testing.expect(elapsed < 15_000);
}

test "SEC-FS browser gate prepares confined copies and removes only its profile without browser" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "order");
    try tmp.dir.writeFile(io, .{ .sub_path = "order/index.html", .data = "<html><body>fixture</body></html>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "order/app.js", .data = "const fixture = true;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "outside unchanged" });
    const path = try tmp.dir.realPathFileAlloc(io, "order", a);
    defer a.free(path);
    var root = try confined_fs.Root.initMutation(a, path);
    defer root.deinit();
    const files = [_]workspace.OrderFile{
        .{ .name = "index.html", .size = 0 },
        .{ .name = "app.js", .size = 0 },
    };
    const copied = try prepareGateCopies(a, &root, &files, "index.html");
    try std.testing.expectEqual(@as(usize, 2), copied.count);
    const page = try root.readFileAlloc(a, GATE_DIR_NAME ++ "/index.html", 4096);
    defer a.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, DRIVER_NAME) != null);
    const original = try root.readFileAlloc(a, "index.html", 4096);
    defer a.free(original);
    try std.testing.expectEqualStrings("<html><body>fixture</body></html>", original);
    const driver = try root.readFileAlloc(a, GATE_DIR_NAME ++ "/" ++ DRIVER_NAME, 1 << 20);
    defer a.free(driver);
    try std.testing.expectEqualStrings(DRIVER_JS, driver);
    try std.testing.expectError(error.SandboxDenied, prepareGateCopies(a, &root, &.{.{ .name = "../outside.txt", .size = 0 }}, "../outside.txt"));
    try root.writeFile(GATE_DIR_NAME ++ "/profile/nested/state", "stale profile");
    try resetGateProfile(&root, io);
    try std.testing.expectError(error.FileNotFound, root.open(GATE_DIR_NAME ++ "/profile"));
    try resetGateProfile(&root, io);
    const outside = try tmp.dir.readFileAlloc(io, "outside.txt", a, .limited(4096));
    defer a.free(outside);
    try std.testing.expectEqualStrings("outside unchanged", outside);
}
