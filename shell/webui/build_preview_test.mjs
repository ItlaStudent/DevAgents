import { transform } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';

await mkdir('dist', { recursive: true });
for (const [source, name] of [
  ['src/preview_elements.ts', 'preview_elements'],
  ['src/image_attachments.ts', 'image_attachments_preview'],
  ['src/panes/chat_panel.ts', 'chat_panel_preview'],
  ['src/ui_actions.ts', 'ui_actions_preview'],
  ['src/design/html.ts', 'html_preview'],
]) {
  const result = await transform(await readFile(source, 'utf8'), { loader: 'ts', format: 'cjs', target: 'es2020' });
  if (result.warnings.length) throw new Error(JSON.stringify(result.warnings));
  await writeFile(`dist/${name}.test.cjs`, result.code);
  console.log(`compiled ${source} to dist/${name}.test.cjs`);
}
