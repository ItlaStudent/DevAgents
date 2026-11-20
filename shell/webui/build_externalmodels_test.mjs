import * as esbuild from 'esbuild';
await esbuild.build({entryPoints:['src/external_models.ts'],bundle:true,outfile:'dist/external_models.test.cjs',format:'cjs',platform:'node'});
console.log('compiled external_models');
