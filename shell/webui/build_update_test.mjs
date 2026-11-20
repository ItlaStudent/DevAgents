import * as esbuild from 'esbuild';

// Tanda 5 (F0.4): empaqueta para Chromium el aviso y la tarjeta reales del
// actualizador (components/update_view.ts) con las alertas de esquina
// (design/alerts.ts), para tests/update_ui_test.cjs (DOM real por CDP).
await esbuild.build({
  stdin: {
    contents: [
      "export { UpdateController, renderUpdateSettings, updateAlert } from './src/components/update_view';",
      "export { raiseAlert, clearAlert, activeAlertIds } from './src/design/alerts';",
    ].join('\n'),
    resolveDir: process.cwd(),
    sourcefile: 'update-entry.ts',
    loader: 'ts',
  },
  bundle: true,
  outfile: 'dist/update_ui.test.js',
  format: 'iife',
  globalName: 'Upd',
  platform: 'browser',
  minify: false,
});
console.log('compiled update entry to dist/update_ui.test.js');
