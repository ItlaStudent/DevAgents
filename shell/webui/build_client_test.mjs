import * as esbuild from 'esbuild';

// Compila bridge/client.ts aisladamente a CJS para probar el plazo de
// BridgeClient.send sin arrancar la cabina (host mudo => rechazo visible).
await esbuild.build({
  entryPoints: ['src/bridge/client.ts'],
  bundle: true,
  outfile: 'dist/bridge_client.test.cjs',
  format: 'cjs',
  platform: 'node',
  minify: false,
});
console.log('compiled bridge/client to dist/bridge_client.test.cjs');
