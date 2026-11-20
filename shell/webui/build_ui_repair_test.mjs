import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import * as esbuild from 'esbuild';

const root = dirname(fileURLToPath(import.meta.url));

await Promise.all([
  esbuild.build({
    entryPoints: [join(root, 'src', 'file_runtime.ts')],
    bundle: true,
    outfile: join(root, 'dist', 'file_runtime.repair.test.cjs'),
    format: 'cjs',
    platform: 'node',
    minify: false,
  }),
  esbuild.build({
    entryPoints: [join(root, 'src', 'session_groups.ts')],
    bundle: true,
    outfile: join(root, 'dist', 'session_groups.repair.test.cjs'),
    format: 'cjs',
    platform: 'node',
    minify: false,
  }),
  esbuild.build({
    entryPoints: [join(root, 'src', 'panes', 'catalog_sessions.ts')],
    bundle: true,
    outfile: join(root, 'dist', 'catalog_sessions.repair.test.cjs'),
    format: 'cjs',
    platform: 'node',
    minify: false,
  }),
  esbuild.build({
    entryPoints: [join(root, 'src', 'panes', 'mission_control.ts')],
    bundle: true,
    outfile: join(root, 'dist', 'mission_control.repair.test.cjs'),
    format: 'cjs',
    platform: 'node',
    minify: false,
  }),
  esbuild.build({
    entryPoints: [join(root, 'src', 'panes', 'chat_panel.ts')],
    bundle: true,
    outfile: join(root, 'dist', 'chat_panel.repair.test.cjs'),
    format: 'cjs',
    platform: 'node',
    minify: false,
  }),
]);

console.log('compiled UI repair modules');
