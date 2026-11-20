import * as esbuild from 'esbuild';
import { writeFileSync } from 'fs';

// Compila ui_diag.ts aisladamente a CJS para probar la lógica real.
await esbuild.build({
  entryPoints: ['src/ui_diag.ts'],
  bundle: true,
  outfile: 'dist/ui_diag.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled ui_diag to dist/ui_diag.test.cjs');
