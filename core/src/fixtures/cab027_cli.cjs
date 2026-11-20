// synthetic child, never loads CLI profiles or credentials.
const fs = require('fs');
const path = require('path');
let prompt = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { prompt += chunk; });
process.stdin.on('end', () => {
  const keys = ['CODEX_HOME', 'USERPROFILE', 'HOME', 'CLAUDE_CONFIG_DIR',
    'CLAUDE_CODE_DISABLE_AUTO_MEMORY', 'OPENCODE_CONFIG_DIR',
    'OPENCODE_DISABLE_CLAUDE_CODE_PROMPT', 'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS',
    'OPENCODE_DISABLE_EXTERNAL_SKILLS', 'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE'];
  const env = Object.fromEntries(keys.map(key => [key, process.env[key] ?? null]));
  let git = null;
  if (process.env.CAB027_GIT_EXE) {
    const result = require('child_process').spawnSync(process.env.CAB027_GIT_EXE,
      ['rev-parse', '--show-toplevel'], {encoding: 'utf8'});
    if (result.error) throw result.error;
    git = {status: result.status, root: result.stdout.trim()};
  }
  fs.writeFileSync('launch.json', JSON.stringify({argv: process.argv.slice(2), cwd: process.cwd(), env, prompt, git}));
  if (process.env.CAB027_ESCAPE === '1') {
    fs.writeFileSync(path.join(process.cwd(), '..', 'outside.txt'), 'escaped');
  }
  const parent = path.dirname(process.cwd());
  switch (process.env.CAB027_CHANGE) {
    case 'existing-tracked':
    case 'existing': fs.writeFileSync(path.join(parent, 'existing.txt'), 'concurrent edit with changed size'); break;
    case 'git': fs.writeFileSync(path.join(parent, '.git', 'cab027-new'), 'git internal'); break;
    case 'ignored':
      fs.mkdirSync(path.join(parent, 'ignored'));
      fs.writeFileSync(path.join(parent, 'ignored', 'new.txt'), 'ignored'); break;
    case 'multiple':
      fs.writeFileSync(path.join(parent, 'outside.txt'), 'first');
      fs.writeFileSync(path.join(parent, 'outside-two.txt'), 'second'); break;
    case 'staged': {
      fs.writeFileSync(path.join(parent, 'outside.txt'), 'staged');
      const result = require('child_process').spawnSync(process.env.CAB027_GIT_EXE,
        ['-C', parent, 'add', '--', 'outside.txt'], {encoding: 'utf8'});
      if (result.error || result.status !== 0) throw result.error || new Error(result.stderr);
      break;
    }
  }
  console.log(JSON.stringify({type: 'result', result: 'synthetic complete'}));
});
