import './build_ux_test.mjs';
import './build_prv004_test.mjs';
import { transform } from 'esbuild';
import { readFile, writeFile } from 'node:fs/promises';
for (const [source, name] of [
  ['src/bridge/client.ts', 'bridge_client_prv003'],
  ['src/components/onboarding_help.ts', 'onboarding_prv003'],
  // Tanda 4: el informe de `doctor` que pinta el tutorial.
  ['src/components/doctor_view.ts', 'doctor_view_prv003'],
]) {
  const result = await transform(await readFile(source, 'utf8'), { loader: 'ts', format: 'cjs', target: 'es2020' });
  if (result.warnings.length) throw Error(JSON.stringify(result.warnings));
  await writeFile(`dist/${name}.test.cjs`, result.code);
}
