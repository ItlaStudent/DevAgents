import { BridgeClient } from './client';
import { unknownQuota, type CliQuota } from '../components/cli_quota';

/**
 * Acceso tipado a la superficie agentica del puente (kinds `core.*`).
 *
 * El WebView no decide nada: cada metodo es una intencion que viaja al host
 * C++ y de ahi al motor via C-ABI. Aqui solo se normalizan tipos y errores
 * para que los paneles no repitan el desempaquetado de `{status, payload}`.
 */

export type SpaceKind = 'order' | 'main-checkout';
export interface WebhookItem { id: number; url: string; event: string; format: 'json' | 'ntfy'; active: boolean; has_secret: boolean; allow_private: boolean; }
export interface RemoteState { running: boolean; url: string; pid: number; }
/** T7: `da_project_rules_get_json`. */
/** T7: `da_cli_accounts_json`. */
export interface CliAccount { id: string; label: string; dir: string; loginCommand: string; }
export interface CliAccountsState { clis: Array<{ cli: string; display: string; envVar: string; selected: string | null; accounts: CliAccount[] }>; unsupported: Array<{ cli: string; display: string; why: string }>; /** QA-B 6: aviso de la última baja (carpeta que quedó en disco). */ notice?: string | null; }
export interface ProjectRules { projectRoot: string; custom: boolean; rules: string; defaultRules: string; projectDocs: string[]; precedence: string; maxBytes: number; }

/** ENJAMBRE: un miembro del conjunto cerrado de modelos — tal y como lo
 *  emite `da_swarm_get_models_json` (snake_case directo del motor). */
export interface SwarmMember {
  provider: string;
  model: string;
}

export interface ModelSelection {
  provider: string;
  model: string;
  text_gen: boolean;
  is_free: boolean;
  show_in_selectors: boolean;
  allow_automatic: boolean;
}

/**
 * E5.08 — GOBIERNO ENCIMA: un agente externo detectado en runtime, tal y
 * como lo emite `da_external_agents_json`. `provider` es `agent:<cli>` —
 * el mismo formato que aceptan los pines y el enjambre del motor.
 * Solo llegan CLIs realmente instalados (versión legible); nunca se finge
 * disponibilidad.
 */
export interface ExternalAgent {
  provider: string;
  cli: string;
  display: string;
  exe: string;
  version: string | null;
  acp: boolean;
  manufacturer: string;
  session: 'suscripcion' | 'api_key' | 'sin_sesion' | 'desconocida';
  session_reason?: string | null;
  enumeration_status: string;
  detected_at_ms: number;
  selection_reason: string;
  acl_appcontainer_sids?: string[];
  /** una app empaquetada (una sola) que puede modificar la instalación; aceptada como señal. */
  acl_appcontainer_writers?: Array<{ sid: string; app: string | null }>;
  /** B1: escritores huérfanos (SID sin cuenta) aceptados en la instalación en uso. */
  acl_orphan_sids?: string[];
  acl_orphan_note?: string | null;
  authenticode?: string;
  authenticode_code?: number | null;
  models: Array<{slug: string; display_name: string; manufacturer: string; reasoning_efforts: string[]; reasoning_effort?: string; free?: boolean; label?: string; text_gen?: boolean; origin?: 'cli' | 'alias' | 'config' | 'default'}>;
  /** Etiqueta de cabina emitida por el motor: «X (tu suscripción)». */
  label: string;
  /** USUARIO-NUEVO (10-nov): variables de facturación del anfitrión que no se le pasan. */
  ignored_env?: string | null;
  /** Lo que respondió la CLI cuando no pudo listar sus modelos. */
  enumeration_reason?: string | null;
  /** Otras instalaciones encontradas y por qué no se eligieron. */
  rejected?: Array<{ path: string; version: string | null; reason: string }>;
}

/** E5.08: límites vigentes de agentes externos (`da_external_limits_json`).
 *  0 en un eje = sin tope en ese eje. `inherit_personal_context` (A3, 10-nov):
 *  null = el ajuste guardado no se pudo leer. */
export interface ExternalLimits {
  task_timeout_ms: number;
  task_max_turns: number;
  order_timeout_ms: number;
  order_max_turns: number;
  inherit_personal_context?: boolean | null;
}

/** E5.24: la sonda escribe visión medida; un salto conserva not_probed. */
export interface VisionProbeResult {
  provider: string;
  model: string;
  status: string;
  cap_vision_status: 'yes' | 'no' | 'not_probed';
  reason?: string;
}

/**
 * Un space tal y como lo emite `da_spaces_list_json` (c_api.zig).
 *
 * Los nombres son los que escribe el motor, no los de la tabla SQL: la tabla
 * usa `worktree_path`/`created_at` y el JSON publica `worktreePath`/`createdAt`.
 * Copiar los de la tabla es lo que rompió `ProviderModel` sin que TypeScript
 * dijera nada, así que aquí van declarados como llegan y NO opcionales: si el
 * motor deja de emitir uno, el error sale en compilación y no en pantalla.
 */
export interface SpaceItem {
  id: number;
  projectId: string;
  kind: SpaceKind;
  name: string;
  worktreePath: string;
  branch: string;
  createdAt: number;
  archivedAt: number | null;
  isNonGitDegraded: boolean;
}

/**
 * E5.05: estado de `.devagents/worktree.json` del proyecto tal y como lo
 * emite `da_worktree_config_json`. `exists` distingue "hay archivo" de
 * "no hay": sin archivo llegan las `suggestions` por lockfiles; con archivo
 * inválido, `valid` es false y `detail` trae la causa exacta del parser.
 */
export interface WorktreeConfigStatus {
  exists: boolean;
  valid: boolean;
  detail: string;
  copy: string[];
  setup_windows: string | null;
  setup_posix: string | null;
  timeout_s: number;
  suggestions: { lockfile: string; command: string }[];
}

/**
 * Una fila de `pull_requests` tal y como la emite `da_prs_json` — nombres
 * snake_case porque así los escribe el motor, no se renombran en el puente.
 */
export interface PrItem {
  id: number;
  order_id: number;
  repo: string;
  number: number;
  state: string;
  url: string;
  last_polled_at: number;
}

/** E5.18: una candidata best-of-N con sus métricas y su worktree. */
export interface BestOfNCandidate {
  id: number;
  member_idx: number;
  provider: string;
  model: string;
  child_order_id: number | null;
  space_id: number | null;
  worktree: string | null;
  files: string[];
  deleted_files: string[];
  status: string;
  gates_pass: number;
  gates_fail: number;
  tests_pass: number;
  tests_fail: number;
  audit_verdict: string;
  cost_tokens: number | null;
  elapsed_ms: number;
  rank: number | null;
  chosen: boolean;
}

/** Payload de `da_best_of_n_candidates_json`. */
export interface BestOfNCard {
  order_id: number;
  parent_worktree: string | null;
  candidates: BestOfNCandidate[];
}

/** El `pr` que devuelve `da_order_ship_json` tras `gh pr create/view` real. */
export interface PrShipResult {
  id: number;
  number: number;
  url: string;
  state: string;
  adopted: boolean;
  /** T4: true si la rama se empujo pero no hay credencial de API — `url` es
      el /compare real para abrir el PR a mano; el PR NO existe aun. */
  manual?: boolean;
  branch: string;
}

/** Una capacidad declarada en el `plugin.json`. */
export interface PluginCapability {
  kind: 'provider' | 'tool' | 'skill' | 'mcp';
  name: string;
  description: string;
}

/**
 * UI-ACTION: fila de `da_ui_actions_poll` — un evento `ui_action` (la petición)
 * o `ui_action_result` (el ack que la cabina escribe de vuelta). El payload es
 * `{action, args?, task_id?}` para peticiones y `{action_id, ok, detail?}` para
 * resultados. `order_id=0` marca acciones globales (MCP/externas).
 */
export interface UiActionRow {
  id: number;
  ts: number;
  kind: 'ui_action' | 'ui_action_result';
  payload: {
    action?: string;
    args?: {
      theme?: string;
      view?: string;
      session_id?: string;
      text?: string;
      // E5.21 — open_window: vista aislada + parámetro según la vista.
      vista?: string;
      path?: string;
      order_id?: number;
      orderId?: number;
    };
    task_id?: string;
    action_id?: number;
    ok?: boolean;
    detail?: string;
  } | null;
  order_id: number;
}

/**
 * Un plugin instalado, tal y como lo emite `da_plugins_list_json`.
 *
 * Los campos del manifiesto son opcionales A PROPÓSITO, y es la única vez que
 * eso está justificado en esta API: una carpeta con un `plugin.json` ilegible
 * se publica igualmente como entrada con `error`, porque ocultarla dejaría al
 * usuario sin saber por qué su plugin no aparece. Cuando `trusted` es false,
 * `error` dice el motivo.
 */
export interface PluginItem {
  folder: string;
  name: string;
  trusted: boolean;
  version?: string;
  abiVersion?: number;
  dllName?: string;
  capabilities?: PluginCapability[];
  error?: string;
}

export interface EngineStatusPayload {
  running: boolean;
  pid: number;
  version: string;
  governanceMode: string;
  activeModel: string;
  activeProvider: string;
  keyLabel: string;
  keyCount: number;
  providerCount: number;
  engineReady: boolean;
  initError: string;
  workspaceRoot?: string;
}

/**
 * Un modelo tal y como lo emite `da_providers_list_json` (c_api.zig).
 *
 * OJO con los nombres: la tabla SQL usa `model_name`, pero el JSON que sale
 * del motor lo publica como `name`, y el contexto como `context_window`. La
 * versión anterior de esta interfaz copiaba los nombres de la tabla, y como
 * todos los campos son opcionales TypeScript no dijo nada: el catálogo pintaba
 * 61 filas vacías y el desplegable de modelo de planificación, 61 opciones en
 * blanco. Si tocas esto, contrástalo con el JSON real, no con el esquema.
 *
 * `is_favorite` es curaduría automática del router, de solo lectura.
 */
export interface ProviderModel {
  name?: string;
  context_window?: number | null;
  is_free?: boolean;
  available?: boolean;
  is_favorite?: boolean;
  /**
   * S4: ¿sirve para generar TEXTO? Lo decide el motor (`isNonTextGenModel`), no
   * esta capa: duplicar aquí la lista de patrones («imagen-», «veo-», «rerank»,
   * «embed»…) garantizaría que las dos se separaran con el tiempo.
   *
   * Ausente en motores antiguos, así que quien lo consuma debe tratar
   * `undefined` como «sí» y no esconder modelos por falta de dato.
   */
  text_gen?: boolean;
}

export interface ProviderInfo {
  name: string;
  base_url: string;
  api_style: string;
  is_free_tier: boolean;
  enabled: boolean;
  /**
   * MODELO-LOCAL: el proveedor corre en la máquina del usuario (Ollama) y no
   * tiene clave API. El motor le aplica la política conservadora — modelo
   * exacto sin respaldos e inferencias en secuencia por defecto — y la UI lo
   * etiqueta para que el usuario sepa qué esperar.
   *
   * Ausente en motores antiguos: `undefined` se lee como «remoto».
   */
  local?: boolean;
  keys: Array<{ label?: string; status?: string }>;
  models: ProviderModel[];
}

export interface KeyInfo {
  provider: string;
  label: string;
  status?: string;
  /** E1.13 multi-cuenta: orden de preferencia de la clave dentro del proveedor. */
  priority?: number;
  /** E1.13: tope de cuota configurado (0 = sin tope). */
  quota_limit?: number;
  /** E1.13: cuota consumida en la ventana vigente. */
  quota_used?: number;
  /** E1.13: llamadas servidas por esta clave. */
  requests_count?: number;
  /** E1.14: true si es la clave que sirvió la llamada más reciente del proveedor. */
  in_use?: boolean;
}

/** E1.18/F4: estado del presupuesto de pago (llamadas, no dólares). */
export interface BudgetState {
  authorized: number;
  spent: number;
  remaining: number;
}

/** E1.16/F4: uso del plan en la ventana móvil de 7 días. */
export interface UsageWeek {
  since_ms: number;
  calls: number;
  prompt: number;
  completion: number;
  total: number;
  by_model: Array<{ provider: string; model: string; total: number }>;
  /** Claves que NO están 'active' (enfriando/agotada/error) = aviso de rate-limit. */
  limited_keys: Array<{
    provider: string;
    label: string;
    status: string;
    quota_limit: number;
    quota_used: number;
  }>;
}

export interface FsEntry {
  name: string;
  path: string;
  isDir: boolean;
}

export interface SearchMatch {
  filePath: string;
  lineNumber: number;
  lineContent: string;
}

/** E5.14 — resultado de `da_repo_search` (BM25 lexico, no semantico). */
export interface RepoSearchMatch {
  path: string;
  line: number;
  snippet: string;
  score: number;
  /**
   * E5.15: procedencia del match — "bm25" (solo lexico), "vector" (solo
   * semantico: el coseno lo trajo con BM25=0) o "bm25+vector".
   */
  source?: string;
}
/** E5.15: estado del indice vectorial persistente reportado por la busqueda. */
export interface RepoEmbedIndexInfo {
  state: string;
  chunks_indexed: number;
  files_indexed: number;
  model: string;
  updated_at: number;
}
export interface RepoSearchResult {
  query_mode: string;
  truncated: boolean;
  elapsed_ms: number;
  files_seen: number;
  files_scanned: number;
  chunks_total: number;
  /**
   * E5.15: presente solo si se pidio mode semantic/hybrid. "ok" = el embedder
   * cloud respondio y la fusion RRF corrio; cualquier otro valor es la razon
   * honesta del fallback a BM25 (disabled, no_key, provider_missing, error
   * del embedder).
   */
  semantic_status?: string;
  /** E5.15: estado del indice vectorial cargado para la consulta hibrida. */
  index?: RepoEmbedIndexInfo;
  matches: RepoSearchMatch[];
}
/** E5.15 — resultado de `da_repo_embed_index` (pasada de indexado real). */
export interface RepoEmbedIndexResult {
  indexed: boolean;
  reason?: string;
  model?: string;
  files_scanned?: number;
  chunks_total?: number;
  embedded?: number;
  reused?: number;
  removed?: number;
  batches?: number;
  dim?: number;
  elapsed_ms?: number;
  retries_429?: number;
  error?: string;
  truncated?: boolean;
}

export interface OrderEvent {
  id: number;
  ts: number;
  source: string;
  kind: string;
  /**
   * Lo que emite el motor: `da_order_events_json` entrega el payload ya
   * ANIDADO como objeto, junto a `severity` y `title`. La interfaz declaraba
   * en su lugar un `payload_json` de tipo cadena que no existe, y como era
   * opcional TypeScript no dijo nada: `JSON.parse(String(undefined ?? '{}'))`
   * devolvía `{}` en todos los consumidores. De ahí que el streaming en vivo,
   * el razonamiento plegado y los paneles de Cambios y Modelos trabajando
   * salieran siempre vacíos pese a que el motor sí manda los datos.
   */
  payload?: Record<string, unknown>;
  severity?: string;
  title?: string;
  /** Forma antigua. Se conserva por si alguna ruta la sigue produciendo. */
  payload_json?: string;
}

/**
 * Payload de un evento sea cual sea la forma en que llegó.
 *
 * Un único sitio donde resolverlo: los cuatro consumidores lo hacían por su
 * cuenta y los cuatro se equivocaban igual.
 */
export function eventPayload(ev: OrderEvent): Record<string, unknown> {
  if (ev.payload && typeof ev.payload === 'object') return ev.payload;
  if (typeof ev.payload_json === 'string' && ev.payload_json) {
    try {
      const parsed = JSON.parse(ev.payload_json);
      if (parsed && typeof parsed === 'object') return parsed as Record<string, unknown>;
    } catch {
      // Payload ilegible: mejor vacío que reventar la vista entera.
    }
  }
  return {};
}

export interface SessionInfo {
  id?: number;
  order_id?: number;
  /** Hilo al que pertenece la orden (orders.conversation_id, V20). Las órdenes
   *  del mismo hilo se colapsan en una fila en la barra lateral. */
  conversation_id?: string | null;
  title?: string;
  status?: string;
  /** Estado legible ('done', 'failed'.). `status` llega como número del motor. */
  status_text?: string;
  created_at?: number;
  archived_at?: number | null;
  /** Remate D1: subtareas que la vuelta delegó (`delegate_tasks`) y cuántas
   *  se integraron. Ausentes si no delegó. */
  delegated?: number;
  integrated?: number;
}

export type GovernanceMode = 'free' | 'paid' | 'hybrid' | 'local';

/** El motor persiste el nombre canónico ("free_tier_first", "local_only");
 *  la UI trabaja con el nombre corto. Un solo sitio para la traducción. */
function normalizeGovernanceMode(mode: string): GovernanceMode {
  switch (mode) {
    case 'free':
    case 'free_tier_first':
      return 'free';
    case 'paid':
    case 'paid_tier_first':
      return 'paid';
    case 'local':
    case 'local_only':
    case 'solo_local':
      return 'local';
    default:
      return 'hybrid';
  }
}

export interface IssueRequest {
  source: 'github' | 'gitea' | 'gitlab' | 'linear' | 'jira';
  base_url: string;
  project: string;
  issue_id?: string;
  fixture?: boolean;
}

export interface IssueItem {
  source: IssueRequest['source'];
  base_url: string;
  project: string;
  id: string;
  title: string;
  body: string;
  url: string;
}

export class CoreApi {
  constructor(private bridge: BridgeClient) {}
  version(identity: string): Promise<{host: string; engine: string}> {
    return this.call('core.status', {identity});
  }

  listWebhooks(): Promise<WebhookItem[]> { return this.call('core.webhooks.list'); }
  addWebhook(config: { url: string; event: string; format: 'json' | 'ntfy'; secret?: string; allow_private?: boolean }): Promise<{ok: boolean; id: number}> {
    return this.call('core.webhooks.add', config);
  }
  testWebhook(id: number): Promise<{ok: boolean; queued: boolean}> { return this.call('core.webhooks.test', {id}); }
  deleteWebhook(id: number): Promise<{ok: boolean}> { return this.call('core.webhooks.delete', {id}); }
  remoteStatus(): Promise<RemoteState> { return this.call('core.remote.status'); }
  remoteStart(port: number, origin: string): Promise<{url: string; token: string}> { return this.call('core.remote.start', {port, origin}); }
  remoteStop(): Promise<RemoteState> { return this.call('core.remote.stop'); }
  issuesList(request: IssueRequest): Promise<{ issues: IssueItem[]; limit: number; scope: string }> {
    return this.call('core.issues.list', request);
  }
  issueRead(request: IssueRequest): Promise<IssueItem> {
    return this.call('core.issues.read', request);
  }
  issuePrompt(request: IssueRequest): Promise<{ prompt: string; issue: IssueItem }> {
    return this.call('core.issues.prompt', request);
  }
  issueComment(request: IssueRequest, text: string): Promise<{ posted: boolean }> {
    return this.call('core.issues.comment', { ...request, text, explicit: true });
  }

  /** Desempaqueta la respuesta del puente; propaga el error del motor tal cual. */
  private async call<T>(kind: string, payload: unknown = {}): Promise<T> {
    const res = await this.bridge.send<unknown, { status?: string; payload?: T; error?: string }>(
      kind,
      payload
    );
    if (res && typeof res === 'object' && 'error' in res && res.error) {
      throw new Error(String(res.error));
    }
    return (res?.payload ?? null) as T;
  }

  /**
   * S7: abre una ruta local absoluta (o una URL http/https) con la aplicación
   * predeterminada del sistema. El host valida el destino y rechaza cualquier
   * otra cosa, así que no hay verbo de shell arbitrario que pueda colarse.
   */
  openPath(target: string): Promise<unknown> {
    return this.call('shell.open', { target });
  }

  // --- Estado y gobernanza ------------------------------------------------
  status(): Promise<EngineStatusPayload> {
    return this.call<EngineStatusPayload>('core.status');
  }
  async getGovernance(): Promise<{ mode: GovernanceMode }> {
    const res = await this.call<{ mode: string }>('core.governance.get');
    return { mode: normalizeGovernanceMode(res.mode) };
  }
  setGovernance(mode: GovernanceMode): Promise<{ mode: GovernanceMode }> {
    return this.call('core.governance.set', { mode });
  }
  /** E1.18/F4: presupuesto de pago (autorizadas/consumidas/restantes). */
  getBudget(): Promise<BudgetState> {
    return this.call<BudgetState>('core.budget.get');
  }
  setBudgetAuthorized(authorized: number): Promise<{ applied: boolean }> {
    return this.call('core.budget.set', { authorized });
  }
  /** E1.16/F4: medidor del plan — ventana movil de 7 dias + claves limitadas. */
  getUsageWeek(): Promise<UsageWeek> {
    return this.call<UsageWeek>('core.usage.week');
  }

  // --- Proveedores, claves y modelos --------------------------------------
  listProviders(): Promise<ProviderInfo[]> {
    return this.call<ProviderInfo[]>('core.providers.list').then((r) => r || []);
  }

  modelSelection(): Promise<ModelSelection[]> {
    return this.call<ModelSelection[]>('core.models.selection.v1').then(rows => {
      if (!Array.isArray(rows)) throw new Error('Metadatos de selección de modelos inválidos');
      return rows;
    });
  }

  setModelPreferences(provider: string, model: string, show_in_selectors: boolean, allow_automatic: boolean): ReturnType<CoreApi['orderPreflight']> {
    return this.call('core.models.preferences.set.v1', { provider, model, show_in_selectors, allow_automatic });
  }
  /**
 * r2: consumo medido de una orden (da_usage_summary_json). Para el
   * «Contexto» real interesa `last_prompt` (tokens de prompt de la ULTIMA
   * llamada con uso medido) y su `last_provider`/`last_model`; los `total_*`
   * suman todas las llamadas y no sirven para el porcentaje de la ventana.
   */
  usageSummary(orderId: number): Promise<{
    order_id: number;
    total_prompt: number;
    total_completion: number;
    total_tokens: number;
    last_prompt?: number;
    last_provider?: string;
    last_model?: string;
  }> {
    return this.call('core.usage', { orderId });
  }
  addProvider(name: string, apiStyle: string, baseUrl: string): Promise<{ added: boolean }> {
    return this.call('core.provider.add', { name, apiStyle, baseUrl });
  }
  listKeys(): Promise<KeyInfo[]> {
    return this.call<KeyInfo[]>('core.keys.list').then((r) => r || []);
  }
  /** Multi-cuenta: cada clave del mismo proveedor necesita una etiqueta distinta. */
  addKey(provider: string, label: string, key: string): Promise<{ added: boolean }> {
    return this.call('core.keys.add', { provider, label, key });
  }
  /**
   * Borra UNA clave, identificada por su etiqueta.
   *
   * `label` es obligatorio a propósito: en el motor una etiqueta vacía es un
   * comodín que vacía el proveedor entero, y con el valor por defecto que tenía
   * antes bastaba un `dataset.label` ausente para borrarlas todas.
   */
  removeKey(provider: string, label: string): Promise<{ removed: boolean }> {
    if (!label) return Promise.reject(new Error('removeKey exige una etiqueta.'));
    return this.call('core.keys.remove', { provider, label });
  }
  /** Vacía un proveedor entero. Hay que quererlo: pídelo por su nombre. */
  removeAllKeysOfProvider(provider: string): Promise<{ removed: boolean }> {
    return this.call('core.keys.remove', { provider, label: '', allowAll: true });
  }
  /**
   * E1.13 multi-cuenta: edita prioridad/cuota/estado de una clave.
   * Un campo omitido queda intacto; solo se escribe lo que se pasa.
   */
  setKeyMeta(
    provider: string,
    label: string,
    meta: { priority?: number; quotaLimit?: number; status?: string },
  ): Promise<{ updated: boolean }> {
    if (!label) return Promise.reject(new Error('setKeyMeta exige una etiqueta.'));
    return this.call('core.keys.setMeta', { provider, label, ...meta });
  }
  /** Tabla de texto tal como la produce el catalogo, no JSON. */
  modelsTable(): Promise<string> {
    return this.call<string>('core.models.list');
  }
  discoverModels(): Promise<{ count: number }> {
    return this.call('core.models.discover');
  }
  registerModel(provider: string, model: string, context = 0, isFree = true) {
    return this.call('core.model.register', { provider, model, context, isFree });
  }
  catalogInfo(): Promise<{
    catalog_path_abs: string;
    model_count: number;
    provider_count: number;
    key_count: number;
  }> {
    return this.call('core.catalog.info');
  }
  /** (b): primer arranque guardado en el motor. */
  onboardingState(): Promise<{ done: boolean; has_usage: boolean }> {
    return this.call('core.onboarding.state');
  }
  onboardingDone(): Promise<unknown> {
    return this.call('core.onboarding.done');
  }
  routerCandidates(taskType = 'planificar'): Promise<unknown[]> {
    return this.call<unknown[]>('core.router.candidates', { taskType }).then((r) => r || []);
  }

  // --- Modelo de planificacion --------------------------------------------
  getPlanModel(): Promise<{ provider: string; model: string }> {
    return this.call('core.plan.getModel');
  }
  /** Cadenas vacias devuelven el control al router automatico. */
  setPlanModel(provider: string, model: string): Promise<{ applied: boolean }> {
    return this.call('core.plan.setModel', { provider, model });
  }

  /** ROLES-MODELO: pin del ejecutor (constructoras + correcciones).
   *  Vacío = sigue al modelo de la orden. */
  getExecModel(): Promise<{ provider: string; model: string }> {
    return this.call('core.exec.getModel');
  }
  setExecModel(provider: string, model: string): Promise<{ applied: boolean }> {
    return this.call('core.exec.setModel', { provider, model });
  }

  /** ROLES-MODELO: pin del auditor (solo tareas .auditar).
   *  Vacío = automático de otro fabricante. */
  getAuditModel(): Promise<{ provider: string; model: string }> {
    return this.call('core.audit.getModel');
  }
  setAuditModel(provider: string, model: string): Promise<{ applied: boolean }> {
    return this.call('core.audit.setModel', { provider, model });
  }

  getRoleModels(): Promise<Array<{ role: string; provider: string; model: string }>> {
    return this.call('core.roles.getModels');
  }
  setRoleModel(role: string, provider: string, model: string): Promise<{ applied: boolean }> {
    return this.call('core.roles.setModel', { role, provider, model });
  }
  getSwarmEnabled(): Promise<{ enabled: boolean }> {
    return this.call('core.swarm.getEnabled');
  }
  getComposerReview(): Promise<{ mode: string; label: string; pending_verdict: boolean }> {
    return this.call('core.composer.review');
  }
  setSwarmEnabled(enabled: boolean): Promise<{ applied: boolean }> {
    return this.call('core.swarm.setEnabled', { enabled });
  }

  /** ENJAMBRE: conjunto cerrado de modelos para las tareas productoras.
   *  `[]` = Automático (el router decide por tarea). El motor valida la forma,
   *  normaliza y aplica la gobernanza por tarea (coste, no-generadores). */
  getSwarmModels(): Promise<SwarmMember[]> {
    return this.call<SwarmMember[]>('core.swarm.getModels').then((r) => (Array.isArray(r) ? r : []));
  }
  setSwarmModels(members: SwarmMember[]): Promise<{ applied: boolean }> {
    // Convención del puente: los arrays anidados viajan como cadena en `json`.
    return this.call('core.swarm.setModels', { json: JSON.stringify(members) });
  }

  /** E5.08: registro de agentes externos detectados (versión + ACP).
   *  Un motor viejo sin el handler devuelve [] — la cabina solo muestra
   *  catálogo, que es justo lo que ese motor sabe despachar. */
  orderPreflight(): Promise<{ budget?: BudgetState; paid_roles?: boolean[]; allowed: boolean; issues: Array<{role: string; provider: string; model: string; cause: string; reason: string; action: string; severity?: 'block' | 'warn'; authorized?: number | null; spent?: number | null; remaining?: number | null}>; message: string; subscription_notice: string }> {
    return this.call('core.order.preflight');
  }

  getExternalAgents(): Promise<ExternalAgent[]> {
    return this.call<ExternalAgent[]>('core.external.agents').then((r) => (Array.isArray(r) ? r : []));
  }

  /** Tanda 4 (F0.5): comprobación antes de la primera orden (`da_doctor_json`). */
  doctor(): Promise<{ version: number; ready: boolean; checks: Array<{ id: string; status: 'ok' | 'aviso' | 'falla'; title: string; detail: string; fix: string }> }> {
    return this.call('core.doctor');
  }

  /** Tanda 5 (F0.4): actualizador. Todas devuelven el estado (`da_update_state_json`). */
  updateState(): Promise<unknown> {
    return this.call('core.update.state');
  }

  /** `force` ignora las 24 h («Buscar ahora»). Desactivado, el motor no sale a la red. */
  updateCheck(force: boolean): Promise<unknown> {
    return this.call('core.update.check', { force });
  }

  updateDownload(): Promise<unknown> {
    return this.call('core.update.download');
  }

  updateSetEnabled(enabled: boolean): Promise<unknown> {
    return this.call('core.update.setEnabled', { enabled });
  }

  /** T12 M3: `unverified` = consentimiento expreso de instalar sin firma verificable. */
  updateApplyOnExit(apply: boolean, unverified = false): Promise<unknown> {
    return this.call('core.update.applyOnExit', { apply, unverified });
  }

  /** T7 (e): reglas del proyecto abierto, guardadas en el motor. */
  getProjectRules(): Promise<ProjectRules> {
    return this.call<ProjectRules>('core.project.rules.get');
  }

  /** Guarda reglas propias para el proyecto abierto; devuelve el estado nuevo. */
  setProjectRules(rules: string): Promise<ProjectRules> {
    return this.call<ProjectRules>('core.project.rules.set', { rules });
  }

  /** T7 (f): cuentas por CLI, cada una en su carpeta. */
  getCliAccounts(): Promise<CliAccountsState> {
    return this.call<CliAccountsState>('core.cliAccounts.list');
  }

  addCliAccount(cli: string, label: string): Promise<CliAccountsState> {
    return this.call<CliAccountsState>('core.cliAccounts.add', { cli, label });
  }

  removeCliAccount(id: string): Promise<CliAccountsState> {
    return this.call<CliAccountsState>('core.cliAccounts.remove', { id });
  }

  /** `id` vacío = login del sistema (carpeta por defecto de la CLI). */
  selectCliAccount(cli: string, id: string): Promise<CliAccountsState> {
    return this.call<CliAccountsState>('core.cliAccounts.select', { cli, id });
  }

  /** Vuelve a las reglas de código limpio de DevAgents. */
  resetProjectRules(): Promise<ProjectRules> {
    return this.call<ProjectRules>('core.project.rules.set', { reset: true });
  }

  /** uses the existing host route; quota is native read-only data. */
  async getCliQuotas(): Promise<CliQuota[]> {
    const agents = await this.call<Array<ExternalAgent & { quota?: CliQuota }>>('core.external.agents');
    if (!Array.isArray(agents)) throw new Error('Respuesta de cuotas inválida');
    return (['codex', 'claude-code'] as const).map(cli => {
      const quota = agents.find(a => a.provider === `agent:${cli}`)?.quota;
      return quota?.cli === cli ? quota : unknownQuota(cli);
    });
  }

  refreshExternalAgents(): Promise<ExternalAgent[]> {
    return this.call('core.external.refresh');
  }
  restoreWorkspacePermissions(orderId: number): Promise<{restored: boolean; root: string; message: string}> {
    return this.call('core.workspace.restorePermissions', { orderId, explicit: true });
  }
  getExternalPaths(): Promise<Record<string,string>> {
    return this.call('core.external.paths.get');
  }
  setExternalPaths(paths: Record<string,string>): Promise<{applied:boolean}> {
    return this.call('core.external.paths.set',{json:JSON.stringify(paths)});
  }
  setExternalModelOptions(provider:string, model:string, reasoning_effort:string): Promise<{applied:boolean}> {
    return this.call('core.external.options.set',{json:JSON.stringify({provider,model,reasoning_effort})});
  }

  getExternalLimits(): Promise<ExternalLimits> {
    return this.call('core.external.limits.get');
  }

  /** Parcial: las claves ausentes conservan el valor vigente del motor. */
  setExternalLimits(limits: Partial<ExternalLimits>): Promise<{ applied: boolean }> {
    return this.call('core.external.limits.set', { json: JSON.stringify(limits) });
  }

  /** Modo determinista: el modelo fijado hace la orden entera, sin respaldos.
   *  Sin modelo fijado el motor lo ignora, por eso la UI solo lo ofrece cuando
   *  hay uno elegido. */
  setDeterministic(enabled: boolean): Promise<{ enabled: boolean }> {
    return this.call('core.plan.setDeterministic', { enabled });
  }

  getDeterministic(): Promise<{ enabled: boolean }> {
    return this.call('core.plan.getDeterministic', {});
  }

  /** modo Directo. Un solo modelo responde y trabaja con las
   *  herramientas gobernadas, sin plan, colmena ni auditoría (como una CLI). */
  /** USUARIO-NUEVO B (10-nov): `delegate` = modo «DevAgents» (Directo que
   *  puede delegar subtareas en paralelo, cada una en su worktree). */
  setDirect(enabled: boolean, delegate = false): Promise<{ enabled: boolean; delegate?: boolean }> {
    return this.call('core.plan.setDirect', { enabled, delegate: enabled && delegate });
  }

  getDirect(): Promise<{ enabled: boolean; delegate?: boolean }> {
    return this.call('core.plan.getDirect', {});
  }

  /** D2(a): tope del loop agéntico observe→re-planifica. 1 = un paso (estable);
   *  >=2 deja al motor re-planificar tras cada ola, dentro del presupuesto
   *  común. El motor lo acota a [1,12]. */
  setAgenticIterations(iterations: number): Promise<{ applied: boolean }> {
    return this.call('core.agentic.setIterations', { iterations });
  }

  getAgenticIterations(): Promise<{ iterations: number }> {
    return this.call('core.agentic.getIterations', {});
  }

  // --- Ciclo de una orden --------------------------------------------------
  submitOrder(
    text: string,
    project = 'default',
    conversationId = '',
    opts?: { waitForPlanApproval?: boolean; bestOfN?: number; bestOfNMembers?: string; issueRequest?: IssueRequest; attachments?: Array<{ name: string; data_base64: string }> }
  ): Promise<{ orderId: number }> {
    return this.call(opts?.issueRequest ? 'core.order.fromIssue' : 'core.order.submit', {
      text,
      project,
      conversationId,
      waitForPlanApproval: opts?.waitForPlanApproval ?? false,
      bestOfN: opts?.bestOfN ?? 0,
      bestOfNMembers: opts?.bestOfNMembers ?? '',
      attachments: opts?.attachments ?? [],
      issueRequest: opts?.issueRequest ? JSON.stringify(opts.issueRequest) : '',
    });
  }

  /** E5.18: tarjeta comparativa — candidatas con métricas, rank y worktree. */
  bestOfNCandidates(orderId: number): Promise<BestOfNCard> {
    return this.call<BestOfNCard>('core.order.bestOfNCandidates', { orderId });
  }

  /** E5.18: fusión aprobada — aplica la candidata elegida sobre el worktree
   * de la orden y archiva las perdedoras. */
  bestOfNChoose(orderId: number, candidateId: number): Promise<{ applied: boolean }> {
    return this.call('core.order.bestOfNChoose', { orderId, candidateId });
  }
  answerOrder(orderId: number, answers: unknown): Promise<{ accepted: boolean }> {
    return this.call('core.order.answer', { orderId, answersJson: JSON.stringify(answers) });
  }
  pollPlan(): Promise<{ done: boolean; ok: boolean }> {
    return this.call('core.order.pollPlan');
  }
  getPlan(orderId: number): Promise<unknown> {
    return this.call('core.order.plan', { orderId });
  }
  approveOrder(orderId: number): Promise<{ approved: boolean }> {
    return this.call('core.order.approve', { orderId });
  }
  /** Replanifica la misma orden; nunca aprueba ni despacha. */
  replanOrder(orderId: number, changes: string): Promise<{ planning: boolean }> {
    return this.call('core.order.replan', { orderId, changes });
  }

  dispatchOrder(orderId: number): Promise<{ dispatching: boolean }> {
    return this.call('core.order.dispatch', { orderId });
  }
  /** CHECKPOINT-T2: reanuda una orden 'interrupted' desde su checkpoint por
   * tarea — no rehace las completadas y re-ejecuta enteras las que quedaron a
   * medias. El progreso se sigue con pollDispatch/orderStatus/orderEvents
   * igual que un dispatch normal. */
  resumeOrder(orderId: number): Promise<{ resuming: boolean }> {
    return this.call('core.order.resume', { orderId });
  }
  /**
   * SEMANTIC-GATE-T3: fija el observable declarado de la orden (array JSON de
   * aserciones — ver semantic_gate.zig). El 'done' exige que se cumpla; si
   * no, la orden termina failed con cause=semantic_gate_failed y la
   * diferencia concreta.
   */
  setOrderExpected(orderId: number, expectedJson: string): Promise<{ set: boolean }> {
    return this.call('core.order.setExpected', { orderId, expected: expectedJson });
  }
  /** SEMANTIC-GATE-T3: observable declarado de la orden (array de aserciones o null). */
  orderExpected(orderId: number): Promise<unknown[] | null> {
    return this.call<unknown[]>('core.order.expected', { orderId }).then((r) => r ?? null);
  }
  pollDispatch(orderId: number): Promise<{ done: boolean; ok: boolean }> {
    return this.call('core.order.pollDispatch', { orderId });
  }
  cancelOrder(orderId: number): Promise<{ cancelled: boolean }> {
    return this.call('core.order.cancel', { orderId });
  }
  /** PLAN-CANCEL: cancela la planificación en curso (orderId 0 = la actual). */
  cancelPlan(orderId: number): Promise<{ cancelled: boolean }> {
    return this.call('core.plan.cancel', { orderId });
  }
  orderEvents(orderId: number, sinceId = 0): Promise<OrderEvent[]> {
    return this.call<OrderEvent[]>('core.order.events', { orderId, sinceId }).then((r) => r || []);
  }
  orderStatus(orderId: number): Promise<{ status: number }> {
    return this.call('core.order.status', { orderId });
  }

  // --- UI-ACTION: acciones cosméticas pedidas por agentes/órdenes -----------
  /** Sondeo incremental de `ui_action`/`ui_action_result` (id > sinceId). */
  uiActions(sinceId = 0): Promise<UiActionRow[]> {
    return this.call<UiActionRow[]>('core.ui.actions', { sinceId }).then((r) => r || []);
  }
  /** Reporta al motor el resultado de aplicar una acción (cierra el loop). */
  uiActionAck(actionId: number, ok: boolean, detail = ''): Promise<unknown> {
    return this.call('core.ui.ack', { actionId, ok, detail });
  }

  // --- Sesiones ------------------------------------------------------------
  listSessions(mode: 'active' | 'archived' | 'all' = 'active'): Promise<SessionInfo[]> {
    return this.call<SessionInfo[]>('core.sessions.list', { mode }).then((r) => r || []);
  }
  archiveSession(orderId: number, archived: boolean): Promise<{ archived: boolean }> {
    return this.call('core.session.archive', { orderId, archived: archived ? 1 : 0 });
  }
  previewArchiveBefore(before: number): Promise<{ count: number }> {
    return this.call('core.session.archiveBefore.preview', { before });
  }
  archiveBefore(before: number, expectedCount: number): Promise<{ count: number }> {
    return this.call('core.session.archiveBefore', { before, expectedCount, confirmed: true });
  }
  sessionMessages(orderId: number): Promise<unknown[]> {
    return this.call<unknown[]>('core.session.messages', { orderId }).then((r) => r || []);
  }
  conversationMessages(orderId: number): Promise<unknown[]> {
    return this.call<unknown[]>('core.session.messages.v2', { orderId }).then((r) => r || []);
  }
  renameSession(orderId: number, title: string) {
    return this.call('core.session.rename', { orderId, title });
  }
  /** S8: borra la sesión y todo lo que cuelga de ella. No se puede deshacer. */
  deleteSession(orderId: number): Promise<{ deleted: boolean }> {
    return this.call('core.session.delete', { orderId });
  }

  // --- Auditoria y salud ---------------------------------------------------
  ledger(): Promise<unknown[]> {
    return this.call<unknown[]>('core.ledger').then((r) => r || []);
  }
  auditChecklist(): Promise<unknown[]> {
    return this.call<unknown[]>('core.auditChecklist').then((r) => r || []);
  }
  escalations(): Promise<unknown[]> {
    return this.call<unknown[]>('core.escalations').then((r) => r || []);
  }
  health(): Promise<unknown[]> {
    return this.call<unknown[]>('core.health').then((r) => r || []);
  }
  healthDetail(): Promise<unknown[]> {
    return this.call<unknown[]>('core.health.detail').then((r) => r || []);
  }
  probeHealth(maxModels = 8): Promise<unknown[]> {
    return this.call<unknown[]>('core.health.probe', { maxModels }).then((r) => r || []);
  }
  /** Acción explícita; la elegibilidad gratuita se comprueba en el motor. */
  visionProbe(provider: string, model: string): Promise<VisionProbeResult> {
    return this.call<VisionProbeResult>('core.vision.probe', { provider, model });
  }
  specialists(): Promise<{ specialists: unknown[] }> {
    return this.call('core.specialists');
  }
  pendingApprovals(): Promise<unknown[]> {
    return this.call<unknown[]>('core.approvals.pending').then((r) => r || []);
  }
  resolveApproval(approvalId: number, approved: boolean) {
    return this.call('core.approvals.resolve', { approvalId, approved });
  }
  /** scope: 0 = solo esta vez, 1 = toda la sesión, 2 = siempre. */
  resolveApprovalScoped(approvalId: number, approved: boolean, scope: 0 | 1 | 2) {
    return this.call('core.approvals.resolveScoped', { approvalId, approved, scope });
  }

  // --- Aprendizaje del router ---------------------------------------------
  /** Puntuación por modelo y tipo de tarea: la tierlist que el motor ya calcula. */
  modelScores(): Promise<unknown[]> {
    return this.call<unknown[]>('core.model.scores').then((r) => r || []);
  }
  evolution(): Promise<unknown> {
    return this.call('core.evolution');
  }

  // --- Permisos del agente -------------------------------------------------
  /**
   * Controla qué puede hacer el agente sin preguntar.
   * - `normal`: pide aprobación para cada acción con efectos
   * - `accept_edits`: acepta ediciones de archivo, pregunta por comandos
   * - `bypass`: no pregunta (usar con cuidado)
   * - `autonomous`: modo desatendido
   * `allow`/`deny` son prefijos de comando.
   */
  setPermissions(
    mode: 'normal' | 'accept_edits' | 'bypass' | 'autonomous',
    allow: string[] = [],
    deny: string[] = []
  ) {
    return this.call('core.permissions.set', {
      configJson: JSON.stringify({ mode, allow, deny }),
    });
  }

  /**
 * olvida que Auto y Omitir permisos ya se habilitaron en este
   * equipo; la próxima vez que se elijan, DevAgents vuelve a preguntar en su
   * ventana propia. Solo endurece: el host no pide confirmación.
   */
  forgetElevatedPermissions(): Promise<{ forgotten: boolean }> {
    return this.call<{ forgotten: boolean }>('core.permissions.forgetElevated');
  }

  /** Permisos vigentes del motor (lectura, sin autorización del host). */
  getPermissions(): Promise<{ mode: 'normal' | 'accept_edits' | 'bypass' | 'autonomous'; allow: string[]; deny: string[] }> {
    return this.call<{ mode: 'normal' | 'accept_edits' | 'bypass' | 'autonomous'; allow: string[]; deny: string[] }>('core.permissions.get');
  }

  // --- Búsqueda web ---------------------------------------------------------
  webSearch(query: string, maxResults = 5): Promise<unknown> {
    return this.call('core.websearch', { query, maxResults });
  }

  /**
   * Captura la pantalla primaria y devuelve la ruta ABSOLUTA del archivo.
   *
   * El formato es BMP de 24 bits sin comprimir, no PNG: el motor escribe las
   * cabeceras a mano para no arrastrar zlib. Sirve para adjuntar el estado de
   * la pantalla a un informe de problema; capturar no es leer, así que el
   * agente todavía no puede mirarla (eso depende de multimodal).
   */
  captureScreenshot(): Promise<{
    ok: boolean;
    path?: string;
    width?: number;
    height?: number;
    error?: string;
  }> {
    return this.call('core.screenshot');
  }

  /**
   * Abre el selector de carpeta del sistema y devuelve la ruta elegida.
   *
   * `cancelled` distingue "el usuario cerró el diálogo" de un fallo real: sin
   * ese campo, cancelar acabaría enseñando un mensaje de error cada vez que
   * alguien cambia de idea. Antes no había diálogo ninguno — las rutas se
   * escribían a mano, y `SpacesPanel` llegaba a llamar a `window.prompt()`,
   * que WebView2 desactiva por defecto: no aparecía nada y devolvía null.
   */
  pickFolder(title = ''): Promise<{ cancelled: boolean; path?: string }> {
    return this.call('dialog.pickFolder', { title });
  }
  /** Solo el selector de workspace autoriza escritura bajo la raíz elegida. */
  pickWorkspace(): Promise<{ cancelled: boolean; path?: string }> {
    return this.call('dialog.pickWorkspace', {});
  }

  // --- Spaces: un git worktree por orden -------------------------------------
  //
  // `core/src/spaces.zig` crea la rama, el worktree y la fila desde F5. Hasta
  // ahora no había ni export ni handler, así que la vista "Spaces" listaba
  // montajes haciéndose pasar por spaces.

  spaces(projectId = 'default'): Promise<SpaceItem[]> {
    return this.call<SpaceItem[]>('core.spaces.list', { projectId }).then((r) => r || []);
  }
  createSpace(name: string, projectId = 'default', kind: SpaceKind = 'order'): Promise<SpaceItem> {
    return this.call('core.space.create', { projectId, name, kind });
  }
  archiveSpace(spaceId: number): Promise<{ archived: boolean }> {
    return this.call('core.space.archive', { spaceId });
  }
  pruneSpaces(projectId = 'default'): Promise<{ pruned: number }> {
    return this.call('core.spaces.prune', { projectId });
  }
  /** E5.05: estado de `.devagents/worktree.json`; solo inspección del motor. */
  worktreeConfig(projectId = 'default'): Promise<WorktreeConfigStatus> {
    return this.call<WorktreeConfigStatus>('core.worktree.config', { projectId });
  }

  // --- Ship Flow B3: plan -> revisión -> PR -> merge -------------------------
  //
  // Nada de esto fabrica estado: `ship` devuelve lo que el motor parseó de la
  // salida REAL de `gh pr create/view` (o el error real de gh/git), `merge`
  // devuelve el estado RELEIDO tras `gh pr merge` y `prs` son las filas
  // reales de la tabla pull_requests alimentadas por el poller en segundo
  // plano.

  /** Empaqueta una orden `done` en un PR real. El `error` llega del motor. */
  shipOrder(orderId: number): Promise<{ ok: boolean; pr?: PrShipResult; error?: string; detail?: string }> {
    return this.call('core.order.ship', { orderId });
  }
  /**
   * Guarda la credencial HTTPS de una forge en el administrador de git
   * (`credential approve` + relectura `fill`). `stored` confirma el
   * round-trip real del store — no que la credencial sea válida para la API
   * (eso lo decide el próximo ship con un 401 honesto).
   */
  storeGitCredential(host: string, username: string, password: string): Promise<{ stored: boolean; host: string }> {
    return this.call('core.git.storeCredential', { host, username, password });
  }
  /** Merge real via `gh pr merge` + relectura autoritativa del estado. */
  mergePr(prId: number): Promise<{ merged: boolean; state: string }> {
    return this.call('core.pr.merge', { prId });
  }
  /** PRs persistidos; `orderId` 0 lista todos. */
  prs(orderId = 0): Promise<PrItem[]> {
    return this.call<PrItem[]>('core.prs.list', { orderId }).then((r) => r || []);
  }
  /** Clonado GitHub sin checkout previo (git clone real). */
  cloneRepo(url: string, targetDir: string): Promise<{ cloned: boolean }> {
    return this.call('core.repo.clone', { url, targetDir });
  }
  /** La carpeta REAL donde la orden escribe (su worktree de space o la raíz). */
  orderWorktree(orderId: number): Promise<{ path: string; space_id: number | null }> {
    return this.call('core.order.worktree', { orderId });
  }

  /**
   * Una llamada al modelo, sin planificador y sin orden.
   *
   * Ctrl+Enter en el editor iba por `submitOrder`, es decir por el
   * PLANIFICADOR — y el planificador no genera código: clasifica la intención y
   * devuelve un plan con una descripción en prosa. Esa era la causa real de que
   * propusiera prosa; no se arreglaba afinando el prompt.
   *
   * No escribe archivos ni ejecuta nada. Lo que devuelve pasa por el visor de
   * cambios, donde se acepta o se rechaza bloque a bloque.
   */
  completeText(
    prompt: string,
    system = ''
  ): Promise<{ ok: boolean; text?: string; provider?: string; model?: string; error?: string }> {
    return this.call('core.complete', { prompt, system });
  }

  /**
   * Crea una carpeta dentro de `parent`. `name` es un NOMBRE, no una ruta: el
   * host rechaza separadores y `..`, así que no se puede escribir fuera de
   * donde se hizo clic derecho. No sobrescribe: si ya existe, devuelve error.
   */
  mkdir(parent: string, name: string): Promise<{ path: string }> {
    return this.call('fs.mkdir', { parent, name });
  }
  /** Igual que `mkdir` pero para un archivo. `content` vacío = archivo en blanco. */
  createFile(parent: string, name: string, content = ''): Promise<{ path: string }> {
    return this.call('fs.createFile', { parent, name, content });
  }

  // --- Plugins ---------------------------------------------------------------
  //
  // `plugin_loader.zig` verifica la ABI, ancla el SHA-256 del DLL en catalog.db
  // y carga la biblioteca de verdad. Era código muerto: no existía una sola
  // función `da_plugin_*` con la que alcanzarlo.

  plugins(): Promise<PluginItem[]> {
    return this.call<PluginItem[]>('core.plugins.list').then((r) => r || []);
  }
  pluginsDir(): Promise<{ path: string }> {
    return this.call('core.plugins.dir');
  }
  /** `folder` es el nombre de la subcarpeta, nunca una ruta. */
  trustPlugin(folder: string): Promise<{ trusted: boolean }> {
    return this.call('core.plugin.trust', { folder });
  }
  untrustPlugin(name: string): Promise<{ untrusted: boolean }> {
    return this.call('core.plugin.untrust', { name });
  }

  // --- Revisión de cambios por hunk ----------------------------------------
  acceptHunk(
    path: string,
    hunkId: number,
    originalContent: string,
    newContent: string,
    range?: { startLine: number; originalLineCount: number; newLineCount: number },
    baseFileContent = ''
  ) {
    return this.call('hunk.accept', {
      path,
      hunkId,
      originalContent,
      newContent,
      ...range,
      baseFileContent,
    });
  }
  rejectHunk(
    path: string,
    hunkId: number,
    originalContent: string,
    newContent: string,
    range?: { startLine: number; originalLineCount: number; newLineCount: number },
    baseFileContent = ''
  ) {
    return this.call('hunk.reject', {
      path,
      hunkId,
      originalContent,
      newContent,
      ...range,
      baseFileContent,
    });
  }

  // --- Terminal ConPTY ------------------------------------------------------
  /** `mode`: vía real — 'conpty' o 'pipes' (respaldo por tuberías). */
  ptySpawn(shellPath = 'cmd.exe', workingDir = ''): Promise<{ terminalId: number; mode?: 'conpty' | 'pipes' }> {
    return this.call('pty.spawn', { shellPath, workingDir });
  }
  ptyWrite(terminalId: number, data: string) {
    return this.call('pty.write', { terminalId, data });
  }
  /** Tamaño del panel para la pseudoconsola; por tuberías devuelve resized:false. */
  ptyResize(terminalId: number, cols: number, rows: number): Promise<{ resized: boolean }> {
    return this.call('pty.resize', { terminalId, cols, rows });
  }
  /** Devuelve solo lo nuevo desde `sinceOffset`, y el offset al que avanzar. */
  ptyRead(terminalId: number, sinceOffset = 0): Promise<{ data: string; offset: number }> {
    return this.call('pty.read', { terminalId, sinceOffset });
  }
  ptyKill(terminalId: number) {
    return this.call('pty.kill', { terminalId });
  }

  /** F7/E2.14: la pantalla no se apaga con una orden viva. El host devuelve el estado previo. */
  keepAwake(enable: boolean): Promise<{ active: boolean; prev: number }> {
    return this.call('system.keep_awake', { enable });
  }

  // --- Workspace y MCP -----------------------------------------------------
  controlProcess(action: 'stop' | 'logs', processId: string, generation: number, cursor?: string) {
    return this.call<{ state: string; exit_code?: number; log?: { text: string; next_cursor: string; more: boolean; skipped: number } }>(
      'core.process.control', { action, process_id: processId, lease_generation: generation, cursor }
    );
  }

  setWorkspace(path: string) {
    return this.call('core.workspace.set', { path });
  }
  /** argv del servidor MCP, p. ej. ['npx', '-y', '@modelcontextprotocol/server-x']. */
  mcpConnect(argv: string[], cwd = '', timeoutMs = 15000): Promise<{ connected: boolean }> {
    return this.call('core.mcp.connect', { argvJson: JSON.stringify(argv), cwd, timeoutMs });
  }
  mcpDisconnect(): Promise<{ connected: boolean }> {
    return this.call('core.mcp.disconnect');
  }
  mcpStatus(): Promise<{ connected: boolean }> {
    return this.call('core.mcp.status');
  }
  mcpTools(): Promise<unknown[]> {
    return this.call<unknown[]>('core.mcp.tools').then((r) => r || []);
  }
  mcpCall(name: string, args: unknown = {}): Promise<string> {
    return this.call('core.mcp.call', { name, argsJson: JSON.stringify(args) });
  }
  /** MCP-AUTH: token del servidor MCP propio para configurar IDEs externas. */
  mcpAuthToken(): Promise<{ token: string }> {
    return this.call('core.mcp.authToken');
  }

  /**
   * Reemplaza el plan de una orden por uno editado.
   *
   * Recibe el plan COMPLETO en JSON, no texto libre: es lo único que el motor
   * sabe leer (`planFromJson`). Y solo funciona con la orden en estado
   * `planned`, es decir, después de planificar y antes de despachar.
   */
  setOrderPlan(orderId: number, planJson: string): Promise<{ applied: boolean }> {
    return this.call('core.order.plan.set', { orderId, planJson });
  }

  // --- Favoritos y montajes -------------------------------------------------
  /**
   * Marca o desmarca un modelo como favorito TUYO.
   *
   * El router ordena por este mismo campo, así que no es decorativo: sube al
   * modelo en la selección automática. Un `Descubrir modelos` posterior puede
   * pisar la elección, porque el descubrimiento reescribe la fila entera.
   */
  setModelFavorite(provider: string, model: string, favorite: boolean) {
    return this.call('core.model.setFavorite', { provider, model, favorite });
  }
  /**
   * Carpetas enlazadas: lo que el agente puede leer fuera del workspace.
   *
   * Los tipos de retorno de las dos siguientes NO son decorativos: el puente
   * responde `{"mounted":true}` y `{"unmounted":true}`, no `added`/`removed`.
 * Declararlos mal es exactamente el fallo (la interfaz leía un campo que
   * el motor no emite y TypeScript callaba por ser opcional).
   */
  mounts(): Promise<Array<Record<string, unknown>>> {
    return this.call<Array<Record<string, unknown>>>('core.mounts.list').then((r) => r || []);
  }
  addMountPath(path: string): Promise<{ mounted: boolean }> {
    return this.call('core.mount.add', { path });
  }
  removeMountPath(path: string): Promise<{ unmounted: boolean }> {
    return this.call('core.mount.remove', { path });
  }

  // --- Skills y memoria -----------------------------------------------------
  /**
   * Skills descubiertas en las carpetas enlazadas. El motor las busca por
   * `SKILL.md`/`skill.md` dentro de cada montaje activo, así que sin montajes
   * devuelve una lista vacía y no es un error.
   */
  skills(): Promise<Array<Record<string, unknown>>> {
    // `da_skills_discover_json` NO devuelve un array: devuelve
    // `{"resources":[…],"warnings":[…]}`. Al pasarlo tal cual, el panel hacía
    // `.map` sobre un objeto y reventaba fuera del try, dejando la sección
    // congelada en su bloque de carga. Se normaliza aquí, en el único sitio
    // que conoce la forma real de la respuesta.
    return this.call<unknown>('core.skills').then((r) => {
      if (Array.isArray(r)) return r as Array<Record<string, unknown>>;
      const res = (r as { resources?: unknown })?.resources;
      return Array.isArray(res) ? (res as Array<Record<string, unknown>>) : [];
    });
  }
  /** Contexto que la memoria (Engram o el respaldo local) guarda del proyecto. */
  memoryContext(project = 'default'): Promise<Record<string, unknown>> {
    return this.call('core.memory', { project });
  }

  /**
   * Nivel de esfuerzo de razonamiento. Cadena vacía devuelve el control al
   * proveedor. Los modelos que no lo entienden lo ignoran sin fallar.
   */
  setReasoningEffort(effort: '' | 'low' | 'medium' | 'high'): Promise<{ applied: boolean }> {
    return this.call('core.reasoningEffort.set', { effort });
  }

  // --- Hooks de ciclo de vida -----------------------------------------------
  /**
   * Comandos que se ejecutan alrededor de cada acción del agente.
   *
   * Es un REEMPLAZO completo: lo que no se envíe queda vacío. Un `pre*` que
   * termine con código distinto de cero BLOQUEA la acción; los `post*` son
   * informativos. Marcadores disponibles: `{path}`, `{exe}`, `{cwd}`.
   */
  setHooks(cfg: {
    enabled: boolean;
    preCommand?: string;
    postCommand?: string;
    preEdit?: string;
    postEdit?: string;
    timeoutMs?: number;
  }): Promise<{ applied: boolean }> {
    return this.call('core.hooks.set', { configJson: JSON.stringify(cfg) });
  }

  // --- Puntos de control ----------------------------------------------------
  /**
   * Guarda una foto del árbol de trabajo antes de que el agente lo toque.
   *
   * B1 (10-nov): la foto es un índice git propio con TODO lo no ignorado,
   * seguido y sin seguimiento (`untrackedCount` cuenta los sin seguimiento que
   * entran). Restaurarla deja el proyecto como estaba: restaura lo modificado y
   * lo borrado y borra lo que la ejecución creó; lo ignorado no se toca.
   */
  createCheckpoint(root = ''): Promise<{ sha: string; root: string; untrackedCount: number }> {
    return this.call('checkpoint.create', { root });
  }
  restoreCheckpoint(
    sha: string,
    root = '',
  ): Promise<{ restored: number; deleted: number; removedDirs: number; notDeleted: string[]; indexRestored?: boolean; indexNote?: string }> {
    return this.call('checkpoint.restore', { sha, root });
  }

  // --- Sistema de archivos -------------------------------------------------
  listDir(path = ''): Promise<{ root: string; entries: FsEntry[] }> {
    return this.call('fs.list', { path });
  }
  /**
 * rama git de la raíz autorizada. La resuelve el host con
   * RunGitCapture/IsGitRepo (solo lectura); nunca se pregunta al motor ni se
   * confunde con la rama de un Space. Sin raíz se responde la de la carpeta
   * de trabajo actual.
   */
  gitBranch(root = ''): Promise<{ root: string; isRepo: boolean; branch: string }> {
    return this.call('core.git.branch', { root });
  }
  /**
 * E4: estado del árbol de trabajo de la raíz autorizada, de SOLO
   * LECTURA. `files` trae el numstat (`git diff --numstat`) más los archivos
   * sin seguimiento; `added`/`removed` son los totales. `truncated` avisa de
   * que la lista se cortó en el host. La tarjeta «Cambios» lo pinta; nunca se
   * pregunta al motor ni se toca el índice desde aquí.
   */
  gitStatus(root = ''): Promise<{
    root: string;
    isRepo: boolean;
    branch: string;
    added: number;
    removed: number;
    truncated: boolean;
    files: Array<{ path: string; added: number; removed: number; untracked: boolean }>;
  }> {
    return this.call('core.git.status', { root });
  }
  /**
 * E5: commit LOCAL con la lista exacta de archivos y el mensaje
   * que el usuario aprobó en el modal. El host exige consentimiento nativo,
   * confina cada ruta a la raíz autorizada y nunca hace push, `--amend` ni
   * salta hooks. Devuelve el hash del commit recién creado.
   */
  /** QA primerizo (11-nov): `git init` en la raíz autorizada; el host pide consentimiento nativo. */
  gitInit(root = ''): Promise<{ root: string; isRepo: boolean }> {
    return this.call('core.git.init', { root });
  }
  gitCommit(request: {
    root?: string;
    message: string;
    files: string[];
  }): Promise<{ root: string; hash: string; files: string[] }> {
    return this.call('core.git.commit', request);
  }
  /**
 * artefactos de una orden (da_list_artifacts_json del motor,
   * order_id=0 lista todas). Es la red de recuperación de la tarjeta
   * Resultados; los eventos file_written siguen siendo la fuente principal.
   */
  listArtifacts(
    orderId: number
  ): Promise<Array<{ order_id: number; file_path: string; file_name: string; size: number }>> {
    return this.call('core.artifacts.list', { orderId });
  }
  search(
    query: string,
    rootDir: string,
    opts: { caseSensitive?: boolean; isRegex?: boolean } = {}
  ): Promise<SearchMatch[]> {
    return this.call<{ matches: SearchMatch[] }>('search.query', {
      query,
      rootDir,
      caseSensitive: !!opts.caseSensitive,
      isRegex: !!opts.isRegex,
    }).then((r) => r?.matches || []);
  }
  /**
   * E5.14/E5.15: ranking BM25 del motor sobre git ls-files. `mode` puede ser
   * 'semantic'/'hybrid' para el rerank por embeddings — solo se aplica si la
   * capa semantica esta configurada; si no, la respuesta llega con
   * query_mode="bm25" y semantic_status=<razon>.
   */
  repoSearch(
    query: string,
    rootDir: string,
    maxResults = 20,
    mode: 'ranking' | 'bm25' | 'semantic' | 'hybrid' = 'ranking'
  ): Promise<RepoSearchResult> {
    return this.call<RepoSearchResult>('search.query', {
      query,
      rootDir,
      mode,
      maxResults,
    });
  }
  /** E5.15: construye/actualiza el índice vectorial persistente del repo
   *  (incremental por hash de trozo; cuenta y reintento 429 viajan en la
   *  respuesta — nunca devuelve un índice fingido). */
  repoEmbedIndex(rootDir = ''): Promise<RepoEmbedIndexResult> {
    return this.call<RepoEmbedIndexResult>('search.embedIndex', { rootDir });
  }
  /** E5.15: estado del índice vectorial del repo (state/chunks/files/model). */
  repoEmbedStatus(rootDir = '', model = ''): Promise<RepoEmbedIndexInfo> {
    return this.call<RepoEmbedIndexInfo>('search.embedStatus', { rootDir, model });
  }
  openDoc(path: string): Promise<{ path: string; content: string; readOnly?: boolean }> {
    return this.call('doc.open', { path });
  }
  saveDoc(path: string, content: string, force = false, saveToken?: string) {
    return this.call('doc.save', { path, content, force, ...(saveToken ? { saveToken } : {}) });
  }
  saveAs(): Promise<{ cancelled: boolean; path?: string; saveToken?: string }> {
    return this.call('dialog.saveAs', {});
  }
}
