import { build, transform } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
await mkdir('dist', { recursive: true });
for (const [source, name] of [
  ['src/panes/mission_control.ts', 'mission_control_ux'],
  ['src/design/stylesheet.ts', 'stylesheet_ux'],
  ['src/design/theme_registry.ts', 'theme_registry_ux'],
  ['src/design/tokens.ts', 'tokens_ux'],
  ['src/design/html.ts', 'html_ux'],
  // cabina_ux.test.cjs carga order_graph_ux: lo compila su propio paso, no el
  // de build_prv004_test.mjs (dependencia oculta destapada en la tanda 6).
  ['src/panes/order_graph.ts', 'order_graph_ux'],
  ['src/external_models.ts', 'external_models'],
  // /014: bloques de código con «Copiar» y Canvas/Diff del editor.
  ['src/design/markdown.ts', 'markdown_ux'],
  ['src/design/code_copy.ts', 'code_copy_ux'],
  ['src/editor/file_actions.ts', 'file_actions_ux'],
  ['src/editor/monaco_editor.ts', 'monaco_editor_ux'],
  // resaltado de los bloques de codigo del chat.
  ['src/editor/highlight.ts', 'highlight_ux'],
  ['src/panes/auto_compact.ts', 'auto_compact_ux'],
  // avisos de ordenes y bandeja de no leidos.
  ['src/components/attention.ts', 'attention_ux'],
  ['src/design/status_labels.ts', 'status_labels_ux'],
  // propietario (10-nov): alertas que se pliegan en un punto «!».
  ['src/design/alerts.ts', 'alerts_ux'],
  ['src/layout/layout.ts', 'layout_ux'],
]) {
  const result = await transform(await readFile(source, 'utf8'), { loader: 'ts', format: 'cjs', target: 'es2020' });
  if (result.warnings.length) throw new Error(JSON.stringify(result.warnings));
  await writeFile(`dist/${name}.test.cjs`, result.code);
  console.log(`compiled ${source}`);
}

// el indicador de contexto del compositor y la tarjeta «Contexto»
// se prueban contra los módulos reales. Se empaquetan (con sus imports) para
// poder cargarlos en Chromium junto a la hoja de estilos real.
for (const [entry, outfile] of [
  ['src/panes/context_usage.ts', 'dist/context_usage.test.cjs'],
  ['src/panes/right_cards.ts', 'dist/ctx_right_cards.test.cjs'],
  ['src/design/stylesheet.ts', 'dist/ctx_styles.test.cjs'],
]) {
  await build({ entryPoints: [entry], bundle: true, outfile, format: 'cjs', platform: 'node', minify: false });
  console.log(`compiled ${entry} to ${outfile}`);
}
