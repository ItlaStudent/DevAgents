import { transform } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';

// Solo transpila: permite probar el compositor con costuras DOM sin arrancar
// el host ni cargar Monaco/xterm. El módulo de imágenes es código de producto.
await mkdir('dist', { recursive: true });
for (const [source, name] of [
  ['src/image_attachments.ts', 'image_attachments'],
  ['src/panes/mission_control.ts', 'mission_control_attachments'],
  ['src/bridge/core_api.ts', 'core_api_attachments'],
  ['src/design/html.ts', 'html_attachments'],
]) {
  const result = await transform(await readFile(source, 'utf8'), { loader: 'ts', format: 'cjs', target: 'es2020' });
  if (result.warnings.length) throw new Error(JSON.stringify(result.warnings));
  await writeFile(`dist/${name}.test.cjs`, result.code);
  console.log(`compiled ${source} to dist/${name}.test.cjs`);
}
