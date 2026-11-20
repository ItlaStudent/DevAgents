// tests/live_harness_audit_test.cjs
//
// E3.31 — Regresión de «tests que mienten» (R14 aplicada a tests/**).
//
// En E3 se encontraron drivers de veredicto en tests/live que devolvían
// process.exit(0) sin importar el resultado observado:
//   - s21_acceptance.mjs decidía «completada» por /finaliz/i sobre el texto de
//     la página — un «finalizó con errores» contaba como éxito — y cerraba con
//     exit(0) incondicional.
//   - cdp_test_chat.cjs salía 0 aunque la respuesta nunca llegara en 35 s.
//   - cdp_test_reasoning.cjs salía 0 en timeout (sin result-card tras 180 s).
//   - cdp_verify_dedup.cjs salía 0 con hasDuplicates=true en su propio informe.
//   - cdp_verify_fixes.cjs salía 0 sin comprobar que el modo cambió a 'chat'.
//   - tests/c_api_consumer.c esperaba el campo «question_id» en el JSON del
//     plan (el contrato D8 emite questions[].id) y respondía con un id fijo
//     «q1» que el planner no reconoce (real: «target-language»).
//
// Este test es un análisis estático: si alguien reintroduce la heurística de
// texto, borra el camino de fallo o hardcodea el id, la suite falla aquí.
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const LIVE = path.join(ROOT, 'tests', 'live');

let failures = 0;
function check(cond, msg) {
  if (cond) { console.log('  PASS:', msg); }
  else { console.error('  FAIL:', msg); failures++; }
}
function read(p) { return fs.readFileSync(p, 'utf8'); }

console.log('=== LIVE HARNESS AUDIT (E3.31) ===\n');

// ── C consumer.c: contrato D8 (questions[].id) y respuesta real ─────
console.log('c_api_consumer.c');
{
  const src = read(path.join(ROOT, 'tests', 'c_api_consumer.c'));
  check(src.includes('first_question_id'), 'extrae el id real del JSON');
  check(!src.includes('\\"q1\\"'),
        'sin id de pregunta hardcodeado («q1» no existe en el planner)');
  check(!src.includes('strstr(json, "question_id")'),
        'sin chequeo de campo question_id en JSON (esquema viejo)');
}

// Live drivers ship only in the development tree. Always check the C consumer.
if (!fs.existsSync(LIVE)) {
  console.log('Live drivers absent from this source distribution.');
  console.log(`\n=== Results: ${failures} failures ===`);
  process.exit(failures > 0 ? 1 : 0);
}

// ── 1. s21_acceptance.mjs: veredicto por fase real, no por texto ───────────
console.log('1. s21_acceptance.mjs');
{
  const src = read(path.join(LIVE, 's21_acceptance.mjs'));
  check(!/\/finaliz/i.test(src.replace(/\/\/[^\n]*/g, '')),
        'sin heurística /finaliz/i (fuera de comentarios)');
  check(!/body\.textContent[\s\S]{0,200}finaliz/.test(src),
        'no decide por document.body.textContent');
  check(/missionControl\?*\.{1,2}phase|missionControl\.phase/.test(src),
        'lee window.missionControl.phase');
  check(/TERMINAL\s*=\s*\[/.test(src) &&
        /'done'/.test(src) && /'error'/.test(src) &&
        /'failed'/.test(src) && /'cancelled'/.test(src),
        'fases terminales explícitas (done/error/failed/cancelled)');
  check(/process\.exit\((1|verdict|failures)\b/.test(src) || /exitCode\s*=\s*(1|verdict|failures)/.test(src),
        'camino de fallo con exit no-cero (literal o por veredicto)');
}

// ── 2. Drivers de veredicto: flag + exit(1) antes del exit(0) final ────────
console.log('\n2. drivers con veredicto');
const verdictDrivers = [
  { f: 'cdp_test_chat.cjs', marks: ['responded', 'process.exit(1)'] },
  { f: 'cdp_test_reasoning.cjs', marks: ['hasResultCard', 'process.exit(1)'] },
  { f: 'cdp_verify_dedup.cjs', marks: ['hasDuplicates', 'process.exit(1)'] },
  { f: 'cdp_verify_fixes.cjs', marks: ['afterMode', 'process.exit(1)'] },
];
for (const d of verdictDrivers) {
  const src = read(path.join(LIVE, d.f));
  for (const m of d.marks)
    check(src.includes(m), `${d.f} conserva ${m}`);
  // El exit(0) final debe venir DESPUÉS de un exit(1) de veredicto (no solo el
  // del catch): si el único exit(1) es el de main().catch, el driver puede
  // volver a ser falso-verde.
  const exits1 = [...src.matchAll(/process\.exit\(1\)/g)].length;
  const exits0 = [...src.matchAll(/process\.exit\(0\)/g)].length;
  check(exits0 >= 1 && exits1 >= 2,
        `${d.f}: ${exits1} caminos exit(1) (veredicto + catch) antes del exit(0)`);
}

// ── 3. Barrido global del anti-patrón en tests/live ────────────────────────
console.log('\n3. anti-patrón global en tests/live');
{
  const files = fs.readdirSync(LIVE).filter((f) => /\.(cjs|mjs)$/.test(f));
  for (const f of files) {
    const src = read(path.join(LIVE, f));
    // Completar por texto de página es la mentira original: el veredicto debe
    // venir del estado del motor (phase/status), no de strings renderizados.
    check(
      !/textContent[\s\S]{0,120}\/(order_done|completada|finaliz)/.test(src) &&
        !/\/(order_done\|completada\|finaliz)/i.test(src),
      `${f}: sin detección de completado por texto de página`);
  }
}

console.log(`\n=== Results: ${failures} failures ===`);
process.exit(failures > 0 ? 1 : 0);
