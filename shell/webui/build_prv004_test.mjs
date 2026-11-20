import { transform } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
await mkdir('dist', { recursive: true });
for (const [source, name] of [
  ['src/panes/mission_control.ts', 'mission_control_ux'],
  ['src/design/html.ts', 'html_ux'],
  ['src/external_models.ts', 'external_models'],
  ['src/panes/settings_memory.ts', 'settings_prv004'],
  ['src/bridge/core_api.ts', 'core_api_prv004'],
  ['src/panes/order_graph.ts', 'order_graph_ux'],
]) {
  const result = await transform(await readFile(source, 'utf8'), { loader: 'ts', format: 'cjs', target: 'es2020' });
  if (result.warnings.length) throw new Error(JSON.stringify(result.warnings));
  await writeFile(`dist/${name}.test.cjs`, result.code);
}
