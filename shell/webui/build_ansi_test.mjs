import * as esbuild from 'esbuild';

// D5: compila el parser ANSI SGR a CJS para probarlo sin DOM. Se entregó el
// 2026-08-15 sin una sola prueba (lo anotó la auditoría de ese día); esta es
// la red que pedía P-2 del encargo de la sesión 2.
//
// `xterm_terminal.ts` arrastra `core_api` y los iconos, que tocan `window`.
// Se marcan como externos: lo que se prueba es `ansiToHtml`, que es pura.
await esbuild.build({
  entryPoints: ['src/terminal/xterm_terminal.ts'],
  bundle: true,
  outfile: 'dist/ansi.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled xterm_terminal to dist/ansi.test.cjs');
