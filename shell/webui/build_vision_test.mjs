import { transform } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';

await mkdir('dist', { recursive: true });
for (const [source, name] of [
  ['src/panes/mission_control.ts', 'mission_control_vision'],
  ['src/bridge/core_api.ts', 'core_api_vision'],
]) {
  const result = await transform(await readFile(source, 'utf8'), { loader: 'ts', format: 'cjs', target: 'es2020' });
  if (result.warnings.length) throw new Error(JSON.stringify(result.warnings));
  await writeFile(`dist/${name}.test.cjs`, result.code);
  console.log(`compiled ${source} to dist/${name}.test.cjs`);
}
