const path = require('node:path');
const { spawnSync } = require('node:child_process');
for (const name of ['image_attachments', 'compositor_attachments']) {
  const result = spawnSync(process.execPath, [path.resolve(__dirname, `../shell/webui/tests/${name}.test.cjs`)], { stdio: 'inherit' });
  if (result.error) { console.error(result.error); process.exit(1); }
  if (result.status !== 0) process.exit(result.status ?? 1);
}
