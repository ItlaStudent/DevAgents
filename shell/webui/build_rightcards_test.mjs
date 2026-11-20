import * as esbuild from 'esbuild';

// E1/E2 (+ r2): compila a CJS el componente real de la columna
// derecha y la hoja de estilos (para el arnes de Chromium del comprobador
// tests/right_cards_ui_test.cjs). r2 anade el layout real y el ViewRouter real
// (iife) para comprobar que la Terminal es un panel propio y que ocultarla no
// pierde la sesion pty.
for (const [entry, outfile] of [
  ['src/panes/right_cards.ts', 'dist/right_cards.test.cjs'],
  ['src/design/stylesheet.ts', 'dist/right_cards_styles.test.cjs'],
]) {
  await esbuild.build({ entryPoints: [entry], bundle: true, outfile, format: 'cjs', platform: 'node', minify: false });
  console.log(`compiled ${entry} to ${outfile}`);
}
for (const [entry, outfile, globalName] of [
  ['src/layout/layout.ts', 'dist/right_cards_layout.test.js', 'RcLayoutTest'],
  ['src/app/view_router.ts', 'dist/right_cards_router.test.js', 'RcRouterTest'],
  ['src/app/terminal_toggle.ts', 'dist/right_cards_toggle.test.js', 'RcToggleTest'],
]) {
  await esbuild.build({ entryPoints: [entry], bundle: true, outfile, format: 'iife', globalName, platform: 'browser', minify: false });
  console.log(`compiled ${entry} to ${outfile}`);
}
