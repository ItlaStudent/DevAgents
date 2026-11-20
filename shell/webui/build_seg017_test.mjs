import * as esbuild from 'esbuild';

// empaqueta, para Chromium, los componentes migrados a los helpers
// de html.ts (catálogo/sesiones, verificación, timeline, paleta y barra del
// navegador) junto con los helpers, para probar con datos hostiles en DOM real.
await esbuild.build({
  stdin: {
    contents: [
      "export { CatalogSessionsPanel } from './src/panes/catalog_sessions';",
      "export { VerificationPanel } from './src/panes/verification_panel';",
      "export { Timeline } from './src/components/timeline';",
      "export { CommandPalette } from './src/components/command_palette';",
      "export { BrowserBar } from './src/browser/browser_bar';",
      "export { ViewRouter } from './src/app/view_router';",
      "export { html, raw, joinHtml, setHtml, SafeHtml, asSafeHtml } from './src/design/html';",
    ].join('\n'),
    resolveDir: process.cwd(),
    sourcefile: 'seg017-entry.ts',
    loader: 'ts',
  },
  bundle: true,
  outfile: 'dist/seg017.test.js',
  format: 'iife',
  globalName: 'Seg',
  platform: 'browser',
  minify: false,
});
console.log('compiled seg017 entry to dist/seg017.test.js');
