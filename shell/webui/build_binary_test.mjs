import * as esbuild from 'esbuild';

// 22-09: compila editor/binario.ts a CJS. Cubre el catalog.db que se abría
// como texto (y se podía guardar encima, corrompiéndolo).
await esbuild.build({
  entryPoints: ['src/editor/binario.ts'],
  bundle: true,
  outfile: 'dist/binario.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
await esbuild.build({
  entryPoints: ['src/editor/monaco_color.ts'],
  bundle: true,
  outfile: 'dist/monaco_color.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled editor/binario and editor/monaco_color to dist/*.test.cjs');
