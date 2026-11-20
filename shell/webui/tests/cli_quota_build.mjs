import * as esbuild from 'esbuild';
for (const [entry, name] of [
  ['src/components/cli_quota.ts', 'cli_quota'],
  ['src/bridge/core_api.ts', 'cli_quota_api'],
  ['src/design/stylesheet.ts', 'cli_quota_styles'],
]) {
  await esbuild.build({ entryPoints: [entry], bundle: true, outfile: `dist/${name}.test.cjs`, format: 'cjs', platform: 'browser' });
  console.log(`CK-COMP-007 compiled ${entry}`);
}
