const assert = require('node:assert/strict');
const { test } = require('node:test');
const { XtermTerminal } = require('../dist/terminal_reconnect.test.cjs');
const boundedTest = (name, fn) => test(name, { timeout: 5000 }, fn);

global.CustomEvent = class { constructor(type, options) { this.type = type; this.detail = options?.detail; } };
global.document = { addEventListener() {}, dispatchEvent() {} };
global.window = {};

function setup(terminals = []) {
  const calls = [], reads = [], output = [];
  const core = {
    async ptySpawn() { calls.push('pty.spawn'); return { terminalId: 99, mode: 'conpty' }; },
    async ptyRead(id, offset) { reads.push([id, offset]); return { data: offset === 0 ? 'previa ñ\r\n' : 'nueva\r\n', offset: offset === 0 ? 11 : offset + 7 }; },
    async ptyKill(id) { calls.push(['pty.kill', id]); },
    async ptyWrite(id, data) { calls.push(['pty.write', id, data]); },
  };
  window.bridgeClient = { async send(kind, payload) { calls.push(kind); assert.deepEqual(payload, { list: true }); return { status: 'ok', payload: { terminals } }; } };
  const terminal = Object.create(XtermTerminal.prototype);
  Object.assign(terminal, { core, terminalId: 0, offset: 0, running: false, startedAt: 0,
    shellPath: 'cmd.exe', xterm: null, pollHandle: null, history: [], sessions: [],
    generation: 0, reading: false, starting: null, outputEl: {},
    container: { querySelector() { return null; } }, shellLabelEl: {},
    setStatus() {}, appendRaw(text) { output.push(text); }, appendErrorLine(text) { output.push(`ERROR ${text}`); },
    appendSystemLine() {}, startPolling() {}, stopPolling() {},
  });
  return { terminal, calls, reads, output };
}
const alive = (id = 7) => ({ terminalId: id, shellPath: 'cmd.exe', cols: 80, rows: 25, running: true, mode: 'conpty' });

boundedTest('reload lists first, reattaches existing session and resumes at the host byte offset', async () => {
  const { terminal, calls, reads, output } = setup([alive()]);
  await terminal.start();
  assert.deepEqual(calls, ['pty.read']);
  assert.equal(terminal.terminalId, 7);
  assert.deepEqual(reads, [[7, 0]]);
  await terminal.pollOnce();
  assert.deepEqual(reads, [[7, 0], [7, 11]]);
  assert.equal(output.join(''), 'previa ñ\r\nnueva\r\n');
});

boundedTest('no live session spawns once, including concurrent start calls', async () => {
  const { terminal, calls } = setup([{ ...alive(), running: false }]);
  await Promise.all([terminal.start(), terminal.start()]);
  assert.equal(calls[0], 'pty.read');
  assert.equal(calls.filter(call => call === 'pty.spawn').length, 1);
  assert.equal(terminal.terminalId, 99);
});

boundedTest('listing failure is visible and does not create a duplicate process', async () => {
  const { terminal, calls, output } = setup();
  window.bridgeClient.send = async () => { throw Error('host unavailable'); };
  await terminal.start();
  assert.equal(calls.length, 0);
  assert.equal(terminal.isRunning(), false);
  assert.match(output.join(''), /host unavailable/);
});

boundedTest('overlapping polls are serialized so output appears once', async () => {
  const { terminal, reads, output } = setup([alive()]);
  await terminal.start();
  assert.equal(reads.length, 1);
  let finish;
  terminal.core.ptyRead = (id, offset) => { reads.push([id, offset]); return new Promise(resolve => { finish = resolve; }); };
  const first = terminal.pollOnce();
  const second = terminal.pollOnce();
  assert.equal(reads.length, 2);
  finish({ data: 'tail', offset: 15 });
  await Promise.all([first, second]);
  assert.equal(output.join(''), 'previa ñ\r\ntail');
});

boundedTest('stop discards a late read response', async () => {
  const { terminal, output } = setup([alive()]);
  await terminal.start();
  let finish;
  terminal.core.ptyRead = () => new Promise(resolve => { finish = resolve; });
  const read = terminal.pollOnce();
  terminal.stop();
  finish({ data: 'late', offset: 15 });
  await read;
  assert.equal(output.join(''), 'previa ñ\r\n');
});

boundedTest('all live host sessions are available and switching replays the selected one without killing it', async () => {
  const { terminal, calls, reads } = setup([alive(8), alive(7)]);
  await terminal.start();
  assert.deepEqual(terminal.sessions.map(s => s.terminalId), [7, 8]);
  await terminal.connect('', false, 8);
  assert.deepEqual(reads, [[7, 0], [8, 0]]);
  assert.equal(terminal.terminalId, 8);
  assert.deepEqual(calls, ['pty.read', 'pty.read']);
});

boundedTest('explicit new terminal creates a process while preserving the existing session', async () => {
  const { terminal, calls } = setup([alive()]);
  await terminal.start();
  await terminal.start('', true);
  assert.deepEqual(calls, ['pty.read', 'pty.read', 'pty.spawn']);
  assert.deepEqual(terminal.sessions.map(s => s.terminalId), [7, 99]);
});

boundedTest('a failed reconnect never writes commands to the previous stopped id', async () => {
  const { terminal, calls } = setup([alive()]);
  await terminal.start();
  terminal.stop();
  window.bridgeClient.send = async () => { throw Error('host unavailable'); };
  assert.equal(await terminal.runCommand('echo should not run'), false);
  assert.equal(calls.some(call => Array.isArray(call) && call[0] === 'pty.write'), false);
});
