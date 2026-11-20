import * as esbuild from 'esbuild';

// Compila chat_activity.ts aisladamente a CJS para probar la lógica real de la
// divulgación progresiva sin arrancar la cabina.
await esbuild.build({
  entryPoints: ['src/chat_activity.ts'],
  bundle: true,
  outfile: 'dist/chat_activity.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled chat_activity to dist/chat_activity.test.cjs');
