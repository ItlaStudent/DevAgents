//! core/src/embedder_ctx.zig — Embedder cloud compartido (E5.15).
//!
//! Contexto + `embed_fn` (HTTP por lotes con presupuesto y reintento 429) que
//! usan tanto el C ABI (`c_api.resolveEmbedder` envuelve `resolve` leyendo
//! CoreState) como herramientas sin CoreState (p.ej. tools/bench_retrieval).
//! La resolución vive sobre (catalog_db, catalog_path) — nada de estado del
//! proceso aquí: quien llama es el propietario de la sesión.
//!
//! Estilo del proveedor: openai/nvidia_nim/cohere → /embeddings
//! OpenAI-compatible; google_gemini → batchEmbedContents. `is_free` es la
//! clasificación del catálogo por (provider, model): gobierna la puerta de
//! spend_budget que se comprueba ANTES de cada intento HTTP, reintentos
//! incluidos.

const std = @import("std");
const db = @import("db.zig");
const credentials = @import("credentials.zig");
const providers = @import("providers");
const retry_planner = @import("retry_planner.zig");
const spend_budget = @import("spend_budget.zig");
const model_router = @import("model_router.zig");

pub const EmbedderCtx = struct {
    base_url: []const u8,
    api_key: ?[]const u8,
    model: []const u8,
    provider: []const u8,
    style: providers.embeddings.Style,
    is_free: bool,
    catalog_db: db.Connection,
    /// Reintentos 429 programados en esta sesión del ctx (telemetría).
    retries: u32 = 0,
};

/// Un intento real contra el proveedor: puerta de presupuesto + HTTP. Es el
/// `call_fn` que retry_planner repite ante 429 — el presupuesto se reevalúa
/// en cada reintento porque cada reintento es una llamada HTTP nueva.
const EmbedCall = struct {
    ctx: *EmbedderCtx,
    allocator: std.mem.Allocator,
    texts: []const []const u8,
    out: ?[][]f32 = null,

    fn call(raw: ?*anyopaque) anyerror!void {
        const self: *EmbedCall = @ptrCast(@alignCast(raw.?));
        const c = self.ctx;
        var http = providers.http_client.HttpClient.init(self.allocator) catch return error.HttpInit;
        defer http.deinit();
        switch (try spend_budget.reservar(c.catalog_db, c.is_free)) {
            .gratuito, .autorizado => {},
            .denegado => return error.BudgetDenied,
        }
        const vecs = providers.embeddings.embedTexts(
            self.allocator,
            &http,
            c.style,
            c.base_url,
            c.api_key,
            c.model,
            self.texts,
            1200,
        );
        // La reserva ya contabilizó el intento aunque falle su respuesta.
        self.out = try vecs;
    }
};

fn embedRetryTick(raw: ?*anyopaque, _: u32, _: u64) void {
    const ctx: *EmbedderCtx = @ptrCast(@alignCast(raw.?));
    ctx.retries += 1;
}

/// La `embed_fn` que repo_search/repo_embed invocan: un lote por llamada,
/// presupuesto por intento y reintento acotado solo ante 429 (la política y
/// el jitter los trae retry_planner — aquí no se duplica backoff).
pub fn cloudEmbed(ctx_raw: ?*anyopaque, allocator: std.mem.Allocator, texts: []const []const u8) anyerror![][]f32 {
    const ctx: *EmbedderCtx = @ptrCast(@alignCast(ctx_raw orelse return error.NoEmbedderCtx));
    var call = EmbedCall{ .ctx = ctx, .allocator = allocator, .texts = texts };
    const rhooks = retry_planner.Hooks{
        .retry_ctx = ctx,
        .on_retry_fn = embedRetryTick,
    };
    try retry_planner.run(retry_planner.default_policy, rhooks, &call, EmbedCall.call);
    return call.out orelse error.BadResponse;
}

/// Resuelve el embedder si settings.embeddings_config lo habilita y hay
/// proveedor con estilo soportado + clave activa. Devuelve null y rellena el
/// ctx, o la nota honesta del motivo (la entrega repo_search como
/// semantic_status). Los motivos son literales estables: la cabina/MCP los
/// enseñan tal cual ("semantic: unavailable (reason)").
pub fn resolve(
    catalog_db: db.Connection,
    catalog_path: []const u8,
    aa: std.mem.Allocator,
    out_ctx: **EmbedderCtx,
) ?[]const u8 {
    var enabled = false;
    var prov: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    if (catalog_db.prepare("SELECT value FROM settings WHERE key='embeddings_config'")) |s| {
        defer catalog_db.finalize(s);
        if (db.c.sqlite3_step(s) == db.c.SQLITE_ROW) {
            const ptr = db.c.sqlite3_column_text(s, 0);
            if (ptr != null) {
                var pj = std.json.parseFromSlice(std.json.Value, aa, ptr[0..std.mem.len(ptr)], .{}) catch null;
                defer if (pj) |*p| p.deinit();
                if (pj != null and pj.?.value == .object) {
                    const o = pj.?.value.object;
                    if (o.get("enabled")) |ev| {
                        if (ev == .bool and ev.bool) enabled = true;
                    }
                    // dupe en aa: el arbol parseado muere con pj.deinit() y los
                    // strings se usan despues (bindText/api call).
                    if (o.get("provider")) |pv| {
                        if (pv == .string and pv.string.len > 0) prov = aa.dupe(u8, pv.string) catch null;
                    }
                    if (o.get("model")) |mv| {
                        if (mv == .string and mv.string.len > 0) model = aa.dupe(u8, mv.string) catch null;
                    }
                }
            }
        }
    } else |_| {}
    if (!enabled) return "disabled";
    const provider_name = prov orelse return "not_configured";
    const model_name = model orelse return "not_configured";

    var base_url: ?[]const u8 = null;
    var api_style: ?[]const u8 = null;
    const ps = catalog_db.prepare("SELECT base_url, api_style FROM providers WHERE name = ?") catch return "provider_missing";
    defer catalog_db.finalize(ps);
    db.bindText(ps, 1, provider_name) catch return "provider_missing";
    if (db.c.sqlite3_step(ps) == db.c.SQLITE_ROW) {
        const bptr = db.c.sqlite3_column_text(ps, 0);
        const sptr = db.c.sqlite3_column_text(ps, 1);
        if (bptr != null) base_url = aa.dupe(u8, bptr[0..std.mem.len(bptr)]) catch null;
        if (sptr != null) api_style = aa.dupe(u8, sptr[0..std.mem.len(sptr)]) catch null;
    }
    if (base_url == null) return "provider_missing";
    const style = providers.embeddings.styleForApi(api_style orelse "") orelse return "unsupported_style";

    var cm = credentials.CredentialManager.init(aa, catalog_path) catch return "credentials_unavailable";
    defer cm.deinit();
    const key = (cm.getKey(provider_name) catch null) orelse return "no_key";

    const ctx = aa.create(EmbedderCtx) catch return "oom";
    ctx.* = .{
        .base_url = base_url.?,
        .api_key = key,
        .model = model_name,
        .provider = provider_name,
        .style = style,
        .is_free = model_router.catalogModelIsFree(catalog_db, provider_name, model_name),
        .catalog_db = catalog_db,
    };
    out_ctx.* = ctx;
    return null;
}
