import { transform } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
await mkdir('dist', { recursive: true });
for (const [source, name] of [
  ['src/panes/mission_control.ts', 'mission_plan'],
  ['src/bridge/core_api.ts', 'core_plan'],
  ['src/design/html.ts', 'html_plan'],
  ['src/design/icons.ts', 'icons_plan'],
  ['src/design/stylesheet.ts', 'style_plan'],
  ['src/design/tokens.ts', 'tokens_plan'],
  ['src/design/theme_registry.ts', 'theme_plan'],
  ['src/design/status_labels.ts', 'labels_plan'],
  ['src/panes/auto_compact.ts', 'auto_plan'],
  ['src/panes/context_usage.ts', 'context_plan'],
  ['src/design/code_copy.ts', 'code_copy_plan'],
  ['src/chat_activity.ts', 'activity_plan'],
  ['src/panes/order_graph.ts', 'order_graph_plan'],
]) {
  const result = await transform(await readFile(source, 'utf8'), { loader: 'ts', format: 'cjs', target: 'es2020' });
  if (result.warnings.length) throw Error(JSON.stringify(result.warnings));
  await writeFile(`dist/${name}.test.cjs`, result.code);
}
