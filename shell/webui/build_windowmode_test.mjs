import * as esbuild from 'esbuild';

// Compila src/window_mode.ts aislado a CJS para probar el parser de la query
// y el montaje aislado sin arrancar la cabina (tests/window_mode_test.cjs).
await esbuild.build({
  entryPoints: ['src/window_mode.ts'],
  bundle: true,
  outfile: 'dist/window_mode.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled window_mode to dist/window_mode.test.cjs');
