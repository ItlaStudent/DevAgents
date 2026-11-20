const assert = require('node:assert/strict');
const {checkVersion, buildIdentity} = require('../dist/version.test.cjs');

const instructions = text => text.split('Actualiza').length - 1;

(async () => {
  let warning = '';
  assert.equal(await checkVersion(
    {version: async () => ({host: '0.1.0+abcdef012345/abi1.bus1.ui1', engine: '0.1.0+abcdef012345/abi1.bus1.ui1'})},
    message => { warning = message; }), false);
  assert.match(warning, /Version incompatible de WebUI/);
  assert.equal(instructions(warning), 1, `un aviso, una instruccion: ${warning}`);
  assert.match(warning, /Actualiza WebUI y el host desde el mismo paquete DevAgents\.$/);
  assert.doesNotMatch(warning, /\.\./);

  warning = '';
  assert.equal(await checkVersion(
    {version: async () => ({host: buildIdentity, engine: '0.1.0+abcdef012345/abi1.bus1.ui1'})},
    message => { warning = message; }), false);
  assert.match(warning, /Version incompatible de motor DLL/);
  assert.equal(instructions(warning), 1, `un aviso, una instruccion: ${warning}`);
  assert.match(warning, /Actualiza motor DLL y el host desde el mismo paquete DevAgents\.$/);
  assert.doesNotMatch(warning, /\.\./);

  warning = '';
  assert.equal(await checkVersion(
    {version: async () => { throw new Error('host timeout'); }},
    message => { warning = message; }), false);
  assert.equal(instructions(warning), 1, `error sin instruccion recibe la generica: ${warning}`);
  assert.match(warning, /Actualiza el host, motor y WebUI desde el mismo paquete\.$/);

  console.log('CK-COMP-004 r3 WebUI: un aviso, una instruccion (WebUI, motor DLL y errores sin instruccion)');
})().catch(error => { console.error(error); process.exitCode = 1; });
