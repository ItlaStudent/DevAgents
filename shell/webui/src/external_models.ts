import type { ExternalAgent } from './bridge/core_api';

export function externalModelRows(agents: ExternalAgent[]) {
  return agents.flatMap(a => (Array.isArray(a.models) ? a.models : []).filter(m => m.text_gen !== false).map(m => ({
    provider: a.provider,
    model: m.slug,
    label: m.label ?? `${a.display} · ${m.display_name} (${m.free === true ? 'gratis' : a.session === 'suscripcion' ? 'tu suscripción' : a.session === 'api_key' ? (a.session_reason ? `facturación API: bloqueado — ${a.session_reason}` : 'facturación API: bloqueado') : a.session === 'sin_sesion' ? (a.session_reason ? `sin sesión — ${a.session_reason}` : 'sin sesión') : a.session_reason || 'sesión desconocida'})`,
    group: a.display,
    manufacturer: m.manufacturer,
    exe: a.exe,
    version: a.version ?? 'desconocida',
    session: a.session,
    enumeration: a.enumeration_status,
    reason: a.selection_reason,
    aclSignals: a.acl_appcontainer_sids ?? [],
    aclWriters: (a.acl_appcontainer_writers ?? []).map(w => `${w.app ?? 'app desinstalada'} (${w.sid})`),
    signature: a.authenticode ?? "not_checked",
    efforts: m.reasoning_efforts,
    effort: m.reasoning_effort ?? '',
    available: m.free === true || a.session === 'suscripcion',
    billingFree: m.free === true,
    fav: false, free: m.free === true || (a.provider !== 'agent:opencode' && a.session === 'suscripcion'), enabledProvider: true,
    ctx: 0, local: false, agent: true,
  })));
}
