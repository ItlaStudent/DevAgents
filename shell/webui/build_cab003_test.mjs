import * as esbuild from 'esbuild';
import * as path from 'node:path';

// compila el MissionControlPanel REAL como IIFE de navegador para
// el comprobador tests/conversation_ui_test.cjs (Chromium por CDP).
// CAB003_SRC / CAB003_OUT permiten compilar OTRA copia del fuente (p. ej. la de
// main extraida con `git archive`) para sacar el rojo sin tocar el indice.
const src = process.env.CAB003_SRC || 'src';
const out = process.env.CAB003_OUT || 'dist/mission_control.cab003.test.js';
await esbuild.build({
  entryPoints: [path.join(src, 'panes', 'mission_control.ts')],
  bundle: true,
  outfile: out,
  format: 'iife',
  globalName: 'MC003',
  platform: 'browser',
  nodePaths: [path.resolve('node_modules')],
  minify: false,
});
console.log(`compiled ${src}/panes/mission_control.ts to ${out}`);
