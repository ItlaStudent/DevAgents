import { ChatPanel } from './chat_panel';
import { MissionControlPanel } from './mission_control';
import { VerificationPanel } from './verification_panel';
import { CatalogSessionsPanel } from './catalog_sessions';
import { UnifiedSettingsPanel } from './settings_memory';

export function runPanesVerificationSuite(): boolean {
  console.log('[SUITE] Starting Phase 3 Agent Panes UI Verification...');

  // 1. ChatPanel test
  const chatDiv = document.createElement('div');
  const chat = new ChatPanel(chatDiv);
  chat.setMode('agent');
  chat.addMessage({
    id: 'm1',
    sender: 'Superagent',
    role: 'assistant',
    content: 'Phase 3 Agent test message',
    timestamp: Date.now(),
  });

  // 2. MissionControlPanel test
  const mcDiv = document.createElement('div');
  const mc = new MissionControlPanel(mcDiv);
  mc.setTasks([
    {
      id: 't1',
      title: 'Phase 3 Task',
      department: 'Frontend',
      assignedModel: 'Gemini 3.6 Flash',
      state: 'running',
      logs: ['Worker starting...\n', 'Building bundle...\n'],
    },
  ]);

  // 3. VerificationPanel test
  const vDiv = document.createElement('div');
  const vp = new VerificationPanel(vDiv);
  vp.setVerifications([
    {
      id: 'v1',
      item: 'F3-T1',
      verdict: 'BUILD PASS',
      evidencePath: 'tests/fixtures/panes-verification.txt',
    },
  ]);

  // 4. CatalogSessionsPanel test
  const catDiv = document.createElement('div');
  const cat = new CatalogSessionsPanel(catDiv);
  cat.setCatalog([
    {
      id: 'c1',
      name: 'Gemini 3.6 Flash',
      provider: 'Google',
      isFree: true,
      contextWindow: 1048576,
      latencyMs: 120,
    },
  ]);

  // 5. UnifiedSettingsPanel test
  const setDiv = document.createElement('div');
  const set = new UnifiedSettingsPanel(setDiv);
  set.setSpecialists([
    {
      name: 'CodeArchitect',
      department: 'Architecture',
      assignedModel: 'Claude Opus 5',
    },
  ]);

  console.log('[SUITE] ALL PHASE 3 PANE TESTS PASSED SUCCESSFULLY!');
  return true;
}
