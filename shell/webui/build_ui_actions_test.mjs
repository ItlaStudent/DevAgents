import * as esbuild from 'esbuild';

// Compila src/ui_actions.ts aisladamente a CJS para probar el allowlist del
// dispatcher sin arrancar la cabina (tests/ui_actions_test.cjs lo ejercita).
await esbuild.build({
  entryPoints: ['src/ui_actions.ts'],
  bundle: true,
  outfile: 'dist/ui_actions.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled ui_actions to dist/ui_actions.test.cjs');
