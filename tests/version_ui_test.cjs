const assert = require('node:assert/strict');
const {checkVersion, versionMismatch, buildIdentity, showVersionError} = require('../shell/webui/dist/version.test.cjs');
(async () => {
  let calls = 0;
  const report = message => { calls++; assert.match(message, /esperaba host-old; encontro 0\.1\.0\+0123456789ab/); };
  assert.equal(await checkVersion({version: async () => ({host: 'host-old', engine: 'host-old'})}, report), false);
  assert.equal(calls, 1);
  let warning = '';
  assert.equal(await checkVersion({version: async () => ({host: buildIdentity, engine: 'dll-old'})}, m => warning=m), false);
  assert.match(warning, /motor DLL/); assert.ok(warning.includes(buildIdentity)); assert.ok(warning.includes('dll-old'));
  assert.equal(await checkVersion({version: async identity => { assert.equal(identity, buildIdentity); return {host: identity, engine: identity}; }}, () => {throw Error('unexpected warning');}), true);
  assert.equal(await checkVersion({version: async () => ({version:'old-host'})}, m => warning=m), false);
  assert.match(warning, /host no declara el protocolo/);
  assert.equal(await checkVersion({version: async () => {throw Error('host timeout');}}, m => warning=m), false);
  assert.match(warning, /host timeout/);
  assert.match(versionMismatch('WebUI', 'new', ''), /sin version/);
  // r2: matching strings with missing/malformed Git hashes must still warn.
  for (const identity of ['0.1.0/abi1.bus1.ui1', '0.1.0+/abi1.bus1.ui1',
    '0.1.0+abc/abi1.bus1.ui1', '0.1.0+not-a-hash/abi1.bus1.ui1', '0.1.0+0123456789ab', '']) {
    for (const piece of ['motor DLL', 'WebUI']) {
      for (const [expected, found] of [[identity, identity], [buildIdentity, identity], [identity, buildIdentity]]) {
        const message = versionMismatch(piece, expected, found);
        assert.match(message, /build sin identidad de git/);
        assert.ok(message.includes(piece));
        assert.ok(message.includes(`host esperaba ${expected}`));
        assert.ok(message.includes(found || 'ausente (sin version)'));
        assert.match(message, /Actualiza/);
      }
    }
  }
  assert.equal(versionMismatch('WebUI', buildIdentity, buildIdentity), '');
  assert.equal(await checkVersion({version: async () => ({host: buildIdentity, engine: '0.1.0/abi1.bus1.ui1'})}, m => warning=m), false);
  assert.match(warning, /motor DLL.*build sin identidad de git/);
  assert.equal(await checkVersion({version: async () => ({host: '0.1.0/abi1.bus1.ui1', engine: '0.1.0/abi1.bus1.ui1'})}, m => warning=m), false);
  assert.match(warning, /WebUI.*build sin identidad de git/);
  console.log('CK-COMP-004 r2 WebUI: 36 invalid comparisons rejected with Git warning; valid match accepted; startup rejects hashless host and DLL');
  let element;
  global.document = {createElement: () => ({setAttribute(k,v) {this[k]=v;}, style:{}})};
  const target = {replaceChildren(e) {element=e;}};
  showVersionError('<img src=x onerror=alert(1)>', target);
  assert.equal(element.role, 'alert'); assert.match(element.textContent, /<img/); assert.equal(element.innerHTML, undefined);
  console.log('CK-COMP-004 WebUI: 7/7 PASS (host/WebUI, host/DLL, match, old host, timeout, missing version, safe visible warning)');
})().catch(e => {console.error(e); process.exitCode=1;});
