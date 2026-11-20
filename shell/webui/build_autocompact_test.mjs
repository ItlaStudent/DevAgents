import * as esbuild from 'esbuild';

// D6: compila la decisión de compactación automática a CJS para probar el
// umbral, la cuenta atrás y el «posponer» sin DOM. El umbral llevaba desde su
// implementación sin una sola prueba (P-2 del encargo de la sesión 2).
await esbuild.build({
  entryPoints: ['src/panes/auto_compact.ts'],
  bundle: true,
  outfile: 'dist/auto_compact.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled auto_compact to dist/auto_compact.test.cjs');
