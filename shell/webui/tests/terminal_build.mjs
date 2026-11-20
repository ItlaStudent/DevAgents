import * as esbuild from 'esbuild';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
for (const [entry, name] of [['terminal/xterm_terminal', 'terminal_reconnect'], ['editor/monaco_editor', 'editor_label'], ['design/stylesheet', 'terminal_styles']]) {
  const input = process.argv.includes('--baseline')
    ? { stdin: { contents: execFileSync('git', ['show', `HEAD:shell/webui/src/${entry}.ts`], { encoding: 'utf8' }),
      resolveDir: path.resolve('src', path.dirname(entry)), sourcefile: `${path.basename(entry)}.ts`, loader: 'ts' } }
    : { entryPoints: [`src/${entry}.ts`] };
  await esbuild.build({ ...input, bundle: true,
    outfile: `dist/${name}.test.cjs`, format: 'cjs', platform: 'node' });
}
console.log('compiled terminal reconnect and editor accessibility tests');
