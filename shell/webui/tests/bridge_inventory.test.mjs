// Independent allowlist: adding a bridge capability requires documenting it.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import test from 'node:test';
const root = fileURLToPath(new URL('../../../', import.meta.url));
export const reviewedHandlers = `app.exedir
browser.app.register
browser.approval.resolve
browser.back
browser.blocked.retry
browser.control
browser.cover
browser.forward
browser.navigate
browser.panel.toggle
browser.reload
browser.state
browser.stop
browser.tab.close
browser.tab.new
browser.tab.select
cdp.dump
checkpoint.create
checkpoint.restore
core.agentic.getIterations
core.agentic.setIterations
core.approvals.pending
core.approvals.resolve
core.approvals.resolveScoped
core.artifacts.list
core.audit.getModel
core.audit.setModel
core.auditChecklist
core.budget.get
core.budget.set
core.catalog.info
core.cliAccounts.add
core.cliAccounts.list
core.cliAccounts.remove
core.cliAccounts.select
core.models.selection.v1
core.models.preferences.set.v1
core.complete
core.composer.review
core.doctor
core.escalations
core.evolution
core.exec.getModel
core.exec.setModel
core.external.agents
core.external.limits.get
core.external.limits.set
core.external.options.set
core.external.paths.get
core.external.paths.set
core.external.refresh
core.git.storeCredential
core.git.branch
core.git.commit
core.git.init
core.git.status
core.governance.get
core.governance.set
core.health
core.health.detail
core.health.probe
core.hooks.set
core.inventory
core.inventory.refresh
core.issues.comment
core.issues.list
core.issues.prompt
core.issues.read
core.keys.add
core.keys.list
core.keys.remove
core.keys.setMeta
core.ledger
core.mcp.authToken
core.mcp.call
core.mcp.connect
core.mcp.disconnect
core.mcp.status
core.mcp.tools
core.memory
core.model.register
core.model.scores
core.model.setFavorite
core.models.discover
core.models.list
core.mount.add
core.mount.remove
core.mounts.list
core.onboarding.done
core.onboarding.state
core.order.answer
core.order.approve
core.order.attachments
core.order.bestOfNCandidates
core.order.bestOfNChoose
core.order.cancel
core.order.dispatch
core.order.events
core.order.expected
core.order.fromIssue
core.order.plan
core.order.plan.set
core.order.pollDispatch
core.order.pollPlan
core.order.preflight
core.order.replan
core.order.resume
core.order.setExpected
core.order.ship
core.order.status
core.order.submit
core.order.worktree
core.permissions.forgetElevated
core.permissions.get
core.permissions.set
core.plan.cancel
core.plan.getDeterministic
core.plan.getDirect
core.plan.getModel
core.plan.setDeterministic
core.plan.setDirect
core.plan.setModel
core.plugin.trust
core.plugin.untrust
core.plugins.dir
core.plugins.list
core.pr.merge
core.project.rules.get
core.project.rules.set
core.provider.add
core.providers.list
core.prs.list
core.reasoningEffort.set
core.remote.start
core.remote.status
core.remote.stop
core.repo.clone
core.roles.getModels
core.roles.setModel
core.router.candidates
core.screenshot
core.session.archive
core.session.archiveBefore
core.session.archiveBefore.preview
core.session.delete
core.session.messages
core.session.messages.v2
core.session.rename
core.sessions.list
core.skills
core.space.archive
core.space.create
core.spaces.list
core.spaces.prune
core.specialists
core.status
core.swarm.getEnabled
core.swarm.getModels
core.swarm.setEnabled
core.swarm.setModels
core.ui.ack
core.ui.actions
core.update.applyOnExit
core.update.check
core.update.download
core.update.setEnabled
core.update.state
core.usage
core.usage.week
core.vision.probe
core.webhooks.add
core.webhooks.delete
core.webhooks.list
core.webhooks.test
core.websearch
core.workspace.restorePermissions
core.process.control
core.workspace.set
core.worktree.config
dialog.pickFolder
dialog.pickWorkspace
dialog.saveAs
doc.open
doc.save
fs.createFile
fs.list
fs.mkdir
fs.unwatch
fs.watch
hunk.accept
hunk.reject
init
lsp.request
notifications.status
opendesign.launch
ping
pty.kill
pty.read
pty.resize
pty.spawn
pty.write
search.embedIndex
search.embedStatus
search.query
search.replace
shell.open
system.keep_awake
window.close
window.command
window.list
window.open`.trim().split(/\s+/).sort();
const stripComments = source => source.replace(/"(?:\\.|[^"\\])*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g,
  token => token.startsWith('/') ? ' '.repeat(token.length) : token);
// Enumerate literal calls, getters, and initializer-list registrations. Unknown
// expressions fail closed instead of silently missing a newly dynamic handler.
export function registrations(source) {
  const clean = stripComments(source).replace(/\\\r?\n/g, ' ');
  const names = [];
  const calls = [...clean.matchAll(/\b(RegisterHandler|BEATS_GETTER)\s*\(\s*([^,]+),/g)];
  for (const call of calls) {
    const arg = call[2].trim();
    if (arg === 'const std::string &kind') continue;
    const linePrefix = clean.slice(clean.lastIndexOf('\n', call.index) + 1, call.index);
    if (arg === 'KIND' && (/#\s*define\s+BEATS_GETTER\s*\(/.test(linePrefix) ||
        (call[1] === 'BEATS_GETTER' && /#\s*define\s*$/.test(linePrefix)))) continue;
    const literal = arg.match(/^"([^"\\]+)"$/);
    if (literal) { names.push(literal[1]); continue; }
    const loop = [...clean.slice(0, call.index).matchAll(/for\s*\([^()]+?:\s*\{([^}]+)\}\)\s*\{/g)].at(-1);
    const prefix = loop && clean.slice(loop.index + loop[0].length, call.index).trim();
    assert(loop && (!prefix || /^(?:[A-Za-z_]\w*\.)?[A-Za-z_]\w*->$/.test(prefix)),
      `unclassified registration expression: ${arg}`);
    const values = [...loop[1].matchAll(/"([^"\\]+)"/g)].map(m => m[1]);
    assert(values.length);
    const dynamic = arg.match(/^"([^"\\]+)"\s*\+\s*action$/);
    assert(dynamic || arg === 'kind', `unclassified registration: ${arg}`);
    names.push(...values.map(v => dynamic ? dynamic[1] + v : v));
  }
  return names;
}
function actualRegistrations() {
  return readdirSync(path.join(root, 'shell/host'), { recursive: true })
    .filter(f => /\.(cpp|hpp|cc|cxx|h|hxx|ipp|inc)$/.test(f) && !path.basename(f).startsWith('test_'))
    .flatMap(f => registrations(readFileSync(path.join(root, 'shell/host', f), 'utf8'))).sort();
}
function assertReviewedHandlers(actual) {
  assert.equal(new Set(actual).size, actual.length, 'duplicate handler registration');
  assert.deepEqual([...actual].sort(), reviewedHandlers, 'handler added/removed without inventory review');
}

test('every registered host handler has an independent reviewed table entry', () => {
  assertReviewedHandlers(actualRegistrations());
  const doc = readFileSync(path.join(root, 'docs/WEBVIEW-SEGURIDAD.md'), 'utf8');
  const documented = [...doc.matchAll(/^\| `([^`]+)` \|/gm)].map(m => m[1]).sort();
  assert.deepEqual(documented, reviewedHandlers, 'security table must describe every handler exactly once');
});
test('unlisted literal and dynamic registrations fail the inventory gate', () => {
  assert.throws(() => assertReviewedHandlers([...actualRegistrations(),
    ...registrations('RegisterHandler("fs.unreviewed", []{});')]),
    /handler added\/removed without inventory review/);
  assert.deepEqual(registrations('RegisterHandler("fs.unreviewed", []{});'), ['fs.unreviewed']);
  assert.throws(() => registrations('RegisterHandler(unreviewedExpression, []{});'), /unclassified/);
  assert.throws(() => registrations('#define UNREVIEWED(KIND) RegisterHandler(KIND, []{});'), /unclassified/);
});

// Dispatch gate: nothing may act on a message kind before (or beside)
// Bridge::HandleMessage's registry. Every comparison of a message kind with a
// literal ("msg.kind == ...", "msgKind == ...", "ExtractKind(...) == ...", or a
// variable assigned from ExtractKind) must be on this justified allowlist.
// A literal that is not here, e.g. a fixed-path "cdp.dump" write in main.cpp,
// fails the build of the inventory.
export const kindComparisonAllowlist = {
  'bridge.cpp|pty.spawn': 'HandleMessage guard: shell must come from the host registry before the registered handler runs',
  'bridge.cpp|lsp.request': 'HandleMessage guard: LSP must come from the host registry before the registered handler runs',
  'bridge.cpp|core.workspace.set': 'HandleMessage guard: exact granted root before the registered handler runs',
  'bridge.cpp|core.mount.add': 'HandleMessage guard: granted read root before the registered handler runs',
  'bridge.cpp|core.repo.clone': 'HandleMessage guard: write root + HTTPS URL before the registered handler runs',
  'bridge.cpp|core.permissions.set': 'CK-PUB-018 consent decision: compares with the live engine config and forwards a host-built canonical configJson to the registered handler',
  'bridge.cpp|core.mcp.connect': 'CK-PUB-018 consent decision: same argv+cwd approved once per host session; the registered handler still runs',
  'bridge.cpp|checkpoint.create': 'routing only (IsCheckpointKind, B1e): main.cpp sends the raw message to its own ordered lane, whose worker calls Bridge::HandleMessage; the registered handler still runs and no side effect happens before it',
  'bridge.cpp|checkpoint.restore': 'routing only (IsCheckpointKind, B1e): same lane as checkpoint.create; the registered handler still runs and no side effect happens before it',
  'bridge.cpp|search.query': 'HandleMessage guard: exact granted rootDir in every mode',
  'bridge.cpp|search.embedIndex': 'HandleMessage guard: exact granted rootDir in every mode',
  'bridge.cpp|search.embedStatus': 'HandleMessage guard: exact granted rootDir in every mode',
  'main.cpp|dialog.pickWorkspace': 'inside the registered handler itself: distinguishes write grant from read grant',
  'main.cpp|core.governance.set': 'routing only: broadcasts engine.changed after the registered handler ran, no side effect on the request',
  'main.cpp|core.budget.set': 'routing only: broadcasts engine.changed after the registered handler ran, no side effect on the request',
  'main.cpp|core.theme.set': 'routing only: broadcast trigger, there is no handler and the request is not acted upon',
  'main.cpp|core.update.state': 'routing only (T5): after the registered core.update.* handler ran in the slow/discovery lane, every kind but the read-only state broadcasts update.changed; no side effect on the request',
};
export function kindComparisons(source) {
  const clean = stripComments(source);
  const aliases = new Set(['msgKind', 'kind']);
  for (const m of clean.matchAll(/\b([A-Za-z_]\w*)\s*=\s*(?:beats::)?(?:Bridge::)?ExtractKind\s*\(/g)) aliases.add(m[1]);
  const names = [...aliases].join('|');
  const pattern = new RegExp(String.raw`(?:\b(?:${names})|\bmsg\.kind|ExtractKind\s*\([^)]*\))\s*(?:==|!=)\s*"([^"\\]+)"|"([^"\\]+)"\s*(?:==|!=)\s*(?:\b(?:${names})\b|\bmsg\.kind\b)`, 'g');
  return [...clean.matchAll(pattern)].map(m => m[1] ?? m[2]);
}
function actualKindComparisons() {
  return readdirSync(path.join(root, 'shell/host'), { recursive: true })
    .filter(f => /\.(cpp|hpp|cc|cxx|h|hxx|ipp|inc)$/.test(f) && !path.basename(f).startsWith('test_'))
    .flatMap(f => kindComparisons(readFileSync(path.join(root, 'shell/host', f), 'utf8'))
      .map(literal => `${path.basename(f)}|${literal}`));
}
function assertKindComparisons(actual) {
  const unlisted = [...new Set(actual)].filter(key => !(key in kindComparisonAllowlist));
  assert.deepEqual(unlisted, [], 'message kind compared outside the registry without a justified allowlist entry');
  for (const key of Object.keys(kindComparisonAllowlist))
    assert(actual.includes(key), `stale allowlist entry: ${key}`);
}
test('no code dispatches on a message kind outside the reviewed handler registry', () => {
  assertKindComparisons(actualKindComparisons());
  // Regression: the former fixed-path write before dispatch (main.cpp) is gone.
  assert(!actualKindComparisons().includes('main.cpp|cdp.dump'));
});
test('kind comparison gate detects every spelling of a pre-dispatch intercept', () => {
  for (const source of [
    'if (msgKind == "cdp.dump") { fopen("C:\\\\tmp\\\\x"); }',
    'if (beats::Bridge::ExtractKind(rawJson) == "fs.evil") {}',
    'const auto k = Bridge::ExtractKind(r); if (k == "fs.evil") {}',
    'if ("fs.evil" == msg.kind) {}',
    'if (msg.kind != "fs.evil") {}',
  ]) assert.deepEqual(kindComparisons(source).length, 1, source);
  assert.throws(() => assertKindComparisons([...actualKindComparisons(), 'main.cpp|cdp.dump']),
    /without a justified allowlist entry/);
  assert.deepEqual(kindComparisons('// msgKind == "x"\nconst s = "msgKind == \\"y\\"";'), []);
});
