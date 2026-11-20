import * as esbuild from 'esbuild';
await esbuild.build({
  tsconfigRaw: {}, entryPoints: ['src/version_check.ts'], bundle: true,
  outfile: 'dist/version.test.cjs', format: 'cjs', platform: 'node',
  define: { __DEVAGENTS_BUILD_IDENTITY__: JSON.stringify('0.1.0+0123456789ab/abi1.bus1.ui1') } });
