import * as esbuild from 'esbuild';

// S8: compila session_groups.ts a CJS para probar el agrupado y la busqueda
// sin DOM. La trampa que cubre es la de segundos-vs-milisegundos, que no rompe
// la pantalla: solo mete las 215 sesiones en el mismo monton.
await esbuild.build({
  entryPoints: ['src/session_groups.ts'],
  bundle: true,
  outfile: 'dist/session_groups.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled session_groups to dist/session_groups.test.cjs');

for (const [entry, outfile, format, globalName] of [
  ['src/app/view_router.ts', 'dist/session_archive.browser.test.js', 'iife', 'SessionArchiveTest'],
  ['src/bridge/core_api.ts', 'dist/session_archive.api.test.cjs', 'cjs', undefined],
]) {
  await esbuild.build({ entryPoints: [entry], bundle: true, outfile, format, globalName, platform: 'browser' });
}
