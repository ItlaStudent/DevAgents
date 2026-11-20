import * as esbuild from 'esbuild';

// DS-UI2 (16-oct-2026): compila a CJS los módulos reales que toca la segunda
// tanda de pulido, para poder asertarlos sin DOM completo.
for (const [entry, outfile] of [
  ['src/design/status_labels.ts', 'dist/status_labels.dsui2.test.cjs'],
  ['src/design/stylesheet.ts', 'dist/stylesheet.dsui2.test.cjs'],
  ['src/layout/layout.ts', 'dist/layout.dsui2.test.cjs'],
  ['src/panes/mission_control.ts', 'dist/mission_control.dsui2.test.cjs'],
  ['src/panes/monitor_panel.ts', 'dist/monitor_panel.dsui2.test.cjs'],
  ['src/app/refresh_coalescer.ts', 'dist/refresh_coalescer.dsui2.test.cjs'],
]) {
  await esbuild.build({ entryPoints: [entry], bundle: true, outfile, format: 'cjs', platform: 'node', minify: false });
  console.log(`compiled ${entry} to ${outfile}`);
}
