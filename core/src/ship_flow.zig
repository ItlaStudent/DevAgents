//! core/src/ship_flow.zig — Ship Flow C-05-B: prompt → revisión → PR → merge.
//!
//! Empaqueta una orden en un PR/MR mediante REST nativo de GitHub, GitLab o
//! Gitea. `gh` es una alternativa explícita. Número, URL y estado proceden
//! de la respuesta remota; los errores se conservan sin publicar secretos.
//!
//! Secuencia (matriz B1/B2/B5):
//!   1. `git rev-parse`      — el worktree debe ser repo git; si no, honesto.
//!   2. consulta de forja    — slug + rama base REALES del remoto.
//!   3. rama: la actual si no es la base; si no, `devagents/orden-<id>`.
//!   4. árbol sucio          — `git add -A` + commit (ship = empaquetar).
//!   5. `git push -u origin` — el head del PR existe en remoto o nada.
//!   6. adopción             — si la forja ya tiene uno ABIERTO para el head, se
//!      toma ese (número/URL reales), se ENMIENDA (PATCH título+cuerpo de
//! este ship,) y no se crea un duplicado.
//!   7. creación + consulta  — número y estado confirmados, jamás
//!      asumidos.
//!   8. fila `pull_requests` — INSERT o UPDATE si la orden ya tenía ese PR.

const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");
const providers = @import("providers");
const issues = @import("issues.zig");

const gh_mod = providers.github;
const gitea_mod = providers.gitea;
const forge_mod = providers.forge_rest;

pub const ShipResult = struct {
    pr_id: i64,
    number: i64,
    state: gh_mod.PullRequestState,
    url: []const u8,
    branch: []u8,
    /// true si el PR ya existía abierto para la rama y se adoptó (B2).
    adopted: bool,
    /// T4-GITEA: true cuando la rama se empujó pero NO hay credencial de API —
    /// el PR no existe y `url` es el /compare real para abrirlo a mano.
    /// Jamás se reporta un PR que no se creó.
    manual: bool = false,
    /// el ship reutilizó un PR ABIERTO para la rama y actualizó
    /// su título/cuerpo (PATCH/`gh pr edit`) con los de este ship, conservando
    /// el número — no fue solo reutilizar la URL.
    amended: bool = false,
    /// eco de la opción de borrador pedida para este ship.
    draft: bool = false,
    /// se pidió draft pero el PR final NO es borrador y la API de
    /// su forja no permite convertirlo (GitHub no acepta "draft" en PATCH de
    /// un PR ya abierto). Nunca se convierte en silencio: va aquí.
    draft_missing: bool = false,
    /// explicación legible del resultado a medias (ej.
    /// draft_missing). Texto estático, sin memoria propia — no se libera.
    note: ?[]const u8 = null,

    pub fn deinit(self: *ShipResult, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.branch);
    }
};

/// Opciones opcionales del ship, todas con valor por defecto que conserva el
/// comportamiento histórico.
pub const ShipOptions = struct {
    /// crear el PR como borrador. GitHub: "draft": true en el
    /// cuerpo del POST /pulls (su PATCH de PR ya abierto NO lo acepta).
    /// Gitea y GitLab: prefijo de título "WIP: " en la creación y en la
    /// enmienda — sus APIs no aceptan un campo draft; la forja marca el
    /// borrador por el prefijo del título (Gitea: pull_service.wipPrefixes;
    /// GitLab: título Draft:/WIP:).
    draft: bool = false,
};

pub const PrRow = struct {
    id: i64,
    order_id: i64,
    repo: []u8,
    number: i64,
    state: []u8,
    url: []u8,
    last_polled_at: i64,

    pub fn deinit(self: *PrRow, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
        allocator.free(self.state);
        allocator.free(self.url);
    }
};

/// Ejecuta argv con la salida capturada y exige exit 0; si no, copia el stderr
/// real a `gh.last_error` y devuelve `fail`. Es la única vía de git/gh dentro
/// del módulo: un fallo nunca se traga ni se convierte en éxito.
fn runOk(
    gh: *gh_mod.GitHubConnector,
    argv: []const []const u8,
    cwd: ?[]const u8,
    fail: anyerror,
    comptime what: []const u8,
) !gh_mod.CmdCapture {
    var cap = gh.capture(argv, cwd) catch |e| {
        gh.setLastError("", @errorName(e));
        return error.GhUnavailable;
    };
    if (cap.exit_code != 0) {
        gh.setLastError(cap.stderr, what);
        cap.deinit(gh.allocator);
        return fail;
    }
    return cap;
}

/// stdout recortado, en memoria propia del llamador.
fn capStdoutTrim(gh: *gh_mod.GitHubConnector, cap: *const gh_mod.CmdCapture) ![]u8 {
    return gh.allocator.dupe(u8, std.mem.trim(u8, cap.stdout, " \t\r\n"));
}

/// enmienda, vía `gh`: `gh pr edit <n> --repo <slug> --title
/// --body` actualiza un PR ABIERTO sin crear otro (la firma de
/// createPullRequest de providers/src/github.zig no se puede extender desde
/// este archivo: encargo con files-lock sobre github.zig).
fn ghPatchTitleBody(
    gh: *gh_mod.GitHubConnector,
    allocator: std.mem.Allocator,
    slug: []const u8,
    number: i64,
    title: []const u8,
    body: []const u8,
    worktree: []const u8,
) !void {
    const num_str = try std.fmt.allocPrint(allocator, "{d}", .{number});
    defer allocator.free(num_str);
    var cap = try runOk(gh, &[_][]const u8{
        "gh",     "pr", "edit",    num_str,
        "--repo", slug, "--title", title,
        "--body", body,
    }, worktree, error.GhEditFailed, "gh pr edit");
    cap.deinit(gh.allocator);
}

/// ¿el PR ABIERTO es borrador? `gh pr view <n> --repo <slug>
/// --json isDraft` es la señal honesta de la CLI. NUNCA error: si el CLI no
/// responde el borrador queda DESCONOCIDO (null) y el caller lo reporta con
/// constancia (draft_missing/note) — la enmienda ya se aplicó y no se tumba
/// la orden por un fallo de solo lectura (R2-5).
fn ghPrIsDraft(
    gh: *gh_mod.GitHubConnector,
    allocator: std.mem.Allocator,
    slug: []const u8,
    number: i64,
    worktree: []const u8,
) ?bool {
    const num_str = std.fmt.allocPrint(allocator, "{d}", .{number}) catch return null;
    defer allocator.free(num_str);
    var cap = runOk(gh, &[_][]const u8{
        "gh",     "pr", "view",   num_str,
        "--repo", slug, "--json", "isDraft",
    }, worktree, error.GhFailed, "gh pr view isDraft") catch return null;
    defer cap.deinit(gh.allocator);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, cap.stdout, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const d = parsed.value.object.get("isDraft") orelse return null;
    if (d != .bool) return null;
    return d.bool;
}

/// enmienda en la vía conector-directo de Gitea (no pasa por
/// forge_rest porque ese conector no expone PATCH en su propio camino): PATCH
/// /api/v1/repos/{slug}/pulls/{n} {"title","body"} con el transporte REST del
/// propio conector — el número se conserva.
fn giteaPatchTitleBody(
    conn_g: *gitea_mod.GiteaConnector,
    allocator: std.mem.Allocator,
    web_base: []const u8,
    slug: []const u8,
    number: i64,
    title: []const u8,
    body: []const u8,
) !void {
    if (number <= 0) return error.InvalidPullRequest;
    const suffix = try std.fmt.allocPrint(allocator, "/pulls/{d}", .{number});
    defer allocator.free(suffix);
    const url = try forgeEndpoint(allocator, .gitea, web_base, slug, suffix);
    defer allocator.free(url);
    const payload = try std.fmt.allocPrint(allocator, "{{\"title\":{f},\"body\":{f}}}", .{ std.json.fmt(title, .{}), std.json.fmt(body, .{}) });
    defer allocator.free(payload);
    var r = conn_g.rest("PATCH", url, payload) catch |e| {
        conn_g.setLastError("", @errorName(e));
        return error.GiteaUnavailable;
    };
    defer r.deinit(conn_g.allocator);
    // R2-3: Gitea documentó 200 PERO también devuelve 201 al PATCH de
    // /pulls/{n}; la enmienda solo depende de que se aplicó.
    if (r.status != 200 and r.status != 201) {
        conn_g.setHttpError(r.status, r.body);
        return error.GiteaPatchFailed;
    }
}

fn prTitle(allocator: std.mem.Allocator, order_id: i64, prompt: []const u8) ![]u8 {
    var line = std.mem.trim(u8, prompt, " \t\r\n");
    if (std.mem.indexOfScalar(u8, line, '\n')) |i| line = line[0..i];
    if (line.len > 60) line = line[0..60];
    return std.fmt.allocPrint(allocator, "DevAgents #{d}: {s}", .{ order_id, line });
}

fn prBody(allocator: std.mem.Allocator, conn: db.Connection, order_id: i64, prompt: []const u8, remote: gitea_mod.RemoteUrl) ![]u8 {
    const references = try issues.prReferences(allocator, conn, order_id, switch (remote.forge) {
        .github => .github,
        .gitlab => .gitlab,
        .gitea => .gitea,
    }, remote.slug, remote.web_base);
    defer allocator.free(references);
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}\n—\nCreado por DevAgents (orden #{d}).", .{ prompt, references, order_id });
}

const NOTE_DRAFT_MISSING = "El PR ABIERTO ya existía SIN borrador y la API de esta forja no permite convertir un PR ya abierto a borrador (GitHub no acepta 'draft' en el PATCH de un PR ya abierto); se actualizaron título y cuerpo por PATCH conservando el número, y el PR sigue no-borrador.";

/// R2-2: el GET del PR abierto falló: no se sabe si llevaba la marca de
/// borrador y el PATCH de título podría quitarla. Se dice, nunca en silencio.
const NOTE_WIP_UNCHECKED = "No se pudo leer el PR ABIERTO de esta forja para saber si era borrador; si llevaba prefijo WIP:/Draft: y este ship se pidió SIN borrador, la actualización de título podría quitársela — revisa el borrador remoto.";

/// R2-2: la marca de borrador por prefijo de título, acotada a los prefijos
/// REALES de Gitea (pull_service.wipPrefixes) y GitLab: sin el suelto "WIP" ni
/// "Draft" para no dar falso positivo con un título normal (p.ej. "Draftsman…").
fn draftPrefixOf(title: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "WIP:", "[WIP]", "Draft:", "[Draft]" };
    for (prefixes) |p| if (std.mem.startsWith(u8, title, p)) return p;
    return null;
}

/// título del ship; para Gitea/GitLab la marca de borrador es el
/// prefijo de título "WIP: " (sus APIs no aceptan un campo draft al crear el
/// PR). GitHub no lleva el prefijo: crea el borrador con "draft": true en el
/// cuerpo del POST (forgeCreateDraftPr) y en PATCH no hay forma de marca.
fn optionTitle(
    allocator: std.mem.Allocator,
    order_db_id: i64,
    prompt: []const u8,
    kind: gh_mod.Forge,
    draft: bool,
) ![]u8 {
    const base = try prTitle(allocator, order_db_id, prompt);
    errdefer allocator.free(base);
    if (!draft or kind == .github) return base;
    const prefixed = try std.fmt.allocPrint(allocator, "WIP: {s}", .{base});
    allocator.free(base);
    return prefixed;
}

/// endpoint de PR de una forja, replicando las reglas de
/// providers/forge_rest.zig.endpoint() (función privada): scheme https (http
/// solo loopback/localhost, como su validateCredentialUrl), sin credenciales
/// ni query en la URL base, path vacío y slug de 2 segmentos seguros (GitLab
/// usa 2 codificados, se admite más profundo por su forma de subgrupos). Se
/// duplica aquí porque la enmienda (PATCH título+cuerpo) y el borrador de
/// GitHub ("draft": true en el POST de creación) no caben en la firma de
/// createPullRequest ni en ensurePullRequestReferences.
fn forgeEndpoint(allocator: std.mem.Allocator, kind: gh_mod.Forge, web_base: []const u8, slug: []const u8, suffix: []const u8) ![]u8 {
    const uri = std.Uri.parse(web_base) catch return error.BadRemoteUrl;
    const is_https = std.mem.eql(u8, uri.scheme, "https");
    const is_http = std.mem.eql(u8, uri.scheme, "http");
    if (!is_https and !is_http) return error.BadRemoteUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or uri.host == null) return error.BadRemoteUrl;
    const path = uri.path.percent_encoded;
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.BadRemoteUrl;
    if (is_http) {
        // Mismo umbral que forge_rest vía validateCredentialUrl: loopback puro.
        const host = uri.host.?.percent_encoded;
        const loopback = std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.startsWith(u8, host, "127.") or std.ascii.eqlIgnoreCase(host, "[::1]") or std.mem.startsWith(u8, host, "[::ffff:127.");
        if (!loopback) return error.BadRemoteUrl;
    }
    var segments = std.mem.splitScalar(u8, slug, '/');
    var count: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.BadRemoteUrl;
        for (segment) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.BadRemoteUrl;
        count += 1;
    }
    if (count < 2 or (kind != .gitlab and count != 2)) return error.BadRemoteUrl;
    return switch (kind) {
        .gitea => std.fmt.allocPrint(allocator, "{s}/api/v1/repos/{s}{s}", .{ web_base, slug, suffix }),
        .github => if (std.mem.eql(u8, web_base, "https://github.com") or std.mem.eql(u8, web_base, "https://www.github.com"))
            std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}{s}", .{ slug, suffix })
        else
            std.fmt.allocPrint(allocator, "{s}/api/v3/repos/{s}{s}", .{ web_base, slug, suffix }),
        .gitlab => blk: {
            const project = try forge_mod.encodeComponent(allocator, slug);
            defer allocator.free(project);
            break :blk std.fmt.allocPrint(allocator, "{s}/api/v4/projects/{s}{s}", .{ web_base, project, suffix });
        },
    };
}

/// enmienda: PATCH (GitHub/Gitea) o PUT (GitLab) de un PR ABIERTO
/// con el título y cuerpo de ESTE ship, conservando el número — no crea otro
/// PR y no reutiliza en silencio: el resultado queda en ShipResult.amended.
fn forgePatchTitleBody(
    transport: *gitea_mod.GiteaConnector,
    kind: gh_mod.Forge,
    web_base: []const u8,
    slug: []const u8,
    number: i64,
    title: []const u8,
    body: []const u8,
) !void {
    if (number <= 0) return error.InvalidPullRequest;
    const a = transport.allocator;
    const suffix = try std.fmt.allocPrint(a, "/{s}/{d}", .{ if (kind == .gitlab) "merge_requests" else "pulls", number });
    defer a.free(suffix);
    const url = try forgeEndpoint(a, kind, web_base, slug, suffix);
    defer a.free(url);
    const field = if (kind == .gitlab) "description" else "body";
    const payload = try std.fmt.allocPrint(a, "{{\"title\":{f},\"{s}\":{f}}}", .{ std.json.fmt(title, .{}), field, std.json.fmt(body, .{}) });
    defer a.free(payload);
    var r = transport.rest(if (kind == .gitlab) "PUT" else "PATCH", url, payload) catch |e| {
        transport.setLastError(@errorName(e), "enmienda: transporte no disponible");
        return error.ForgeUnavailable;
    };
    defer r.deinit(a);
    // R2-3: 200 esperado; Gitea también reporta 201 al PATCH/PUT — mismo hecho
    // (aplicado). providers/src/forge_rest.zig:245 sigue exigiendo 200 igual
    // que aquí antes: NO se toca en este encargo (lock), anotado en el informe.
    if (r.status != 200 and r.status != 201) {
        transport.setHttpError(r.status, r.body);
        return error.ForgePatchFailed;
    }
}

/// ¿el PR ABIERTO de GitHub es borrador? Solo GitHub llamaba
/// aquí: su GET /pulls/{n} trae el campo booleano "draft" (el PATCH no puede
/// fijarlo). null = la forja no lo dice de forma fiable y el caller lo
/// trata como desconocido; para gitea/gitlab la señal (prefijo del título)
/// la da remotePrDraftMark.
fn remotePrIsDraft(
    transport: *gitea_mod.GiteaConnector,
    kind: gh_mod.Forge,
    web_base: []const u8,
    slug: []const u8,
    number: i64,
) !?bool {
    if (number <= 0) return error.InvalidPullRequest;
    const a = transport.allocator;
    const suffix = try std.fmt.allocPrint(a, "/{s}/{d}", .{ if (kind == .gitlab) "merge_requests" else "pulls", number });
    defer a.free(suffix);
    const url = try forgeEndpoint(a, kind, web_base, slug, suffix);
    defer a.free(url);
    var r = transport.rest("GET", url, null) catch |e| {
        transport.setLastError(@errorName(e), "borrador: transporte no disponible");
        return error.ForgeUnavailable;
    };
    defer r.deinit(a);
    if (r.status != 200) {
        transport.setHttpError(r.status, r.body);
        return error.ForgeFailed;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, a, r.body, .{}) catch return error.ForgeParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ForgeParseFailed;
    const o = parsed.value.object;
    const d = o.get("draft") orelse return null;
    if (d != .bool) return null;
    return d.bool;
}

/// R2-2: el PR ABIERTO lleva marca de borrador por título? GET /pulls/{n} y
/// prefijo acotado. null = el remoto NO lleva marca; error caído en el
/// caller con note — la marca ya no se quita en silencio.
fn remotePrDraftMark(
    transport: *gitea_mod.GiteaConnector,
    kind: gh_mod.Forge,
    web_base: []const u8,
    slug: []const u8,
    number: i64,
) !?[]const u8 {
    if (number <= 0) return error.InvalidPullRequest;
    const a = transport.allocator;
    const suffix = try std.fmt.allocPrint(a, "/{s}/{d}", .{ if (kind == .gitlab) "merge_requests" else "pulls", number });
    defer a.free(suffix);
    const url = try forgeEndpoint(a, kind, web_base, slug, suffix);
    defer a.free(url);
    var r = transport.rest("GET", url, null) catch |e| {
        transport.setLastError(@errorName(e), "prefijo: transporte no disponible");
        return error.ForgeUnavailable;
    };
    defer r.deinit(a);
    if (r.status != 200) {
        transport.setHttpError(r.status, r.body);
        return error.ForgeFailed;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, a, r.body, .{}) catch return error.ForgeParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ForgeParseFailed;
    const t = parsed.value.object.get("title") orelse return null;
    if (t != .string) return null;
    return draftPrefixOf(t.string);
}

/// creación con borrador SOLO para GitHub REST — el campo
/// "draft": true solo puede ir en el cuerpo del POST /pulls (el PATCH de PR
/// ya abierto no lo acepta y la firma de createPullRequest de forge_rest no
/// lo lleva), así que el POST se replica aquí con la misma validación de
/// endpoint y el mismo transporte.
fn forgeCreateDraftPr(
    transport: *gitea_mod.GiteaConnector,
    web_base: []const u8,
    slug: []const u8,
    title: []const u8,
    body: []const u8,
    head: []const u8,
    base: []const u8,
) !forge_mod.PullRequest {
    const a = transport.allocator;
    const url = try forgeEndpoint(a, .github, web_base, slug, "/pulls");
    defer a.free(url);
    const payload = try std.fmt.allocPrint(a, "{{\"title\":{f},\"body\":{f},\"head\":{f},\"base\":{f},\"draft\":true}}", .{ std.json.fmt(title, .{}), std.json.fmt(body, .{}), std.json.fmt(head, .{}), std.json.fmt(base, .{}) });
    defer a.free(payload);
    var r = transport.rest("POST", url, payload) catch |e| {
        transport.setLastError(@errorName(e), "borrador: transporte no disponible");
        return error.ForgeUnavailable;
    };
    defer r.deinit(a);
    if (r.status != 201) {
        transport.setHttpError(r.status, r.body);
        return error.ForgeValidationFailed;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, a, r.body, .{}) catch return error.ForgeParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ForgeParseFailed;
    const o = parsed.value.object;
    const n = o.get("number") orelse return error.ForgeParseFailed;
    const u = o.get("html_url") orelse return error.ForgeParseFailed;
    if (n != .integer or n.integer <= 0 or u != .string) return error.ForgeParseFailed;
    var state: gh_mod.PullRequestState = .open;
    if (o.get("state")) |sv| {
        if (sv == .string and std.mem.eql(u8, sv.string, "closed")) state = .failed;
    }
    const url_owned = try a.dupe(u8, u.string);
    errdefer a.free(url_owned);
    return .{ .number = n.integer, .state = state, .url = url_owned };
}

/// Sube la fila del PR a `pull_requests`. Si la orden ya tiene una fila para
/// ese número (re-ship), la ACTUALIZA en vez de duplicarla.
fn upsertPrRow(
    conn: db.Connection,
    order_id: i64,
    provider: []const u8,
    repo: []const u8,
    number: i64,
    state: gh_mod.PullRequestState,
    url: []const u8,
) !i64 {
    const sel = try conn.prepare("SELECT id FROM pull_requests WHERE order_id = ? AND number = ?");
    defer conn.finalize(sel);
    try db.bindInt(sel, 1, order_id);
    try db.bindInt(sel, 2, number);
    const now = health.nowSeconds(conn);
    if (db.c.sqlite3_step(sel) == db.c.SQLITE_ROW) {
        const id = db.c.sqlite3_column_int64(sel, 0);
        const upd = try conn.prepare("UPDATE pull_requests SET provider = ?, repo = ?, state = ?, url = ?, last_polled_at = ? WHERE id = ?");
        defer conn.finalize(upd);
        try db.bindText(upd, 1, provider);
        try db.bindText(upd, 2, repo);
        try db.bindText(upd, 3, state.toString());
        try db.bindText(upd, 4, url);
        try db.bindInt(upd, 5, now);
        try db.bindInt(upd, 6, id);
        if (db.c.sqlite3_step(upd) != db.c.SQLITE_DONE) return error.StepFailed;
        return id;
    }
    const ins = try conn.prepare("INSERT INTO pull_requests (order_id, provider, repo, number, state, url, last_polled_at) VALUES (?, ?, ?, ?, ?, ?, ?)");
    defer conn.finalize(ins);
    try db.bindInt(ins, 1, order_id);
    try db.bindText(ins, 2, provider);
    try db.bindText(ins, 3, repo);
    try db.bindInt(ins, 4, number);
    try db.bindText(ins, 5, state.toString());
    try db.bindText(ins, 6, url);
    try db.bindInt(ins, 7, now);
    if (db.c.sqlite3_step(ins) != db.c.SQLITE_DONE) return error.StepFailed;
    return db.c.sqlite3_last_insert_rowid(conn.db);
}

/// `git remote get-url origin` → RemoteUrl parseada (host/owner/repo/forge).
/// Sin remote o URL que no se entiende = error honesto, nunca un slug inventado.
fn detectRemote(gh: *gh_mod.GitHubConnector, allocator: std.mem.Allocator, worktree: []const u8) !gitea_mod.RemoteUrl {
    var cap = try runOk(gh, &[_][]const u8{ "git", "remote", "get-url", "origin" }, worktree, error.NoRemote, "git remote get-url origin");
    defer cap.deinit(gh.allocator);
    const url = std.mem.trim(u8, cap.stdout, " \t\r\n");
    if (url.len == 0) {
        gh.setLastError("", "el workspace no tiene remote 'origin'");
        return error.NoRemote;
    }
    return gitea_mod.parseRemoteUrlConfigured(allocator, url, gh.forge_hosts) catch {
        gh.setLastError("", "remote no reconocido (no https/ssh owner/repo)");
        return error.BadRemoteUrl;
    };
}

/// Rama base por git local (sin API): `git symbolic-ref refs/remotes/origin/HEAD`
/// → "origin/main" → "main"; fallback `git remote show origin` → "HEAD branch:".
/// null si ninguna lo sabe — la rama base jamás se inventa.
fn giteaBaseBranch(gh: *gh_mod.GitHubConnector, allocator: std.mem.Allocator, worktree: []const u8) !?[]u8 {
    {
        var cap = gh.capture(&[_][]const u8{ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, worktree) catch return null;
        defer cap.deinit(gh.allocator);
        if (cap.exit_code == 0) {
            const out = std.mem.trim(u8, cap.stdout, " \t\r\n");
            // "origin/main" → "main"
            if (std.mem.indexOfScalar(u8, out, '/')) |s| {
                if (s + 1 < out.len) return try allocator.dupe(u8, out[s + 1 ..]);
            }
        }
    }
    {
        var cap = gh.capture(&[_][]const u8{ "git", "remote", "show", "origin" }, worktree) catch return null;
        defer cap.deinit(gh.allocator);
        if (cap.exit_code == 0) {
            var it = std.mem.splitScalar(u8, cap.stdout, '\n');
            while (it.next()) |line| {
                const l = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, l, "HEAD branch:")) {
                    const b = std.mem.trim(u8, l["HEAD branch:".len..], " \t");
                    if (b.len > 0 and !std.mem.eql(u8, b, "(unknown)")) return try allocator.dupe(u8, b);
                }
            }
        }
    }
    return null;
}

/// scheme://host de una URL de PR ("https://git.4stra.dev/o/r/pulls/42" →
/// "https://git.4stra.dev"). null si no tiene esa forma — el caller falla
/// honesto en vez de recortar a ciegas.
pub fn webBaseFromPrUrl(url: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[i + 3 ..];
    const s = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (s == 0) return null;
    return url[0 .. i + 3 + s];
}

/// Resuelve la credencial de API para la forge Gitea, en orden honesto:
/// 1. DEVAGENTS_GITEA_TOKEN / GITEA_TOKEN del entorno → "token X".
/// 2. `git credential fill` sobre el host del remote → la MISMA credencial que
///    git usa para el push (credential manager), como "Basic base64(user:pass)".
///    GIT_TERMINAL_PROMPT=0 + GCM_INTERACTIVE=never: sin credencial guardada el
///    helper falla rápido en vez de colgar un diálogo.
/// null = no hay credencial usable — ship degrada a /compare, jamás finge auth.
pub fn resolveGiteaAuth(gh: *gh_mod.GitHubConnector, allocator: std.mem.Allocator, host: []const u8) !?[]u8 {
    return resolveForgeAuth(gh, allocator, .gitea, host);
}

fn envCredentialAllowed(forge: gh_mod.Forge, host: []const u8, pinned_host: ?[]const u8) bool {
    if (forge == .github and std.ascii.eqlIgnoreCase(host, "github.com")) return true;
    if (forge == .gitlab and std.ascii.eqlIgnoreCase(host, "gitlab.com")) return true;
    return pinned_host != null and std.ascii.eqlIgnoreCase(host, pinned_host.?);
}

pub fn resolveForgeAuth(gh: *gh_mod.GitHubConnector, allocator: std.mem.Allocator, forge: gh_mod.Forge, host: []const u8) !?[]u8 {
    if (host.len == 0) return error.BadRemoteUrl;
    for (host) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != ':') return error.BadRemoteUrl;
    if (gh.forge_auth_fn) |f| {
        if (try f(allocator, forge, host, gh.forge_auth_ctx)) |header| {
            if (std.mem.indexOfAny(u8, header, "\r\n") != null) {
                allocator.free(header);
                return error.InvalidCredential;
            }
            return header;
        }
    }
    const names: []const [*:0]const u8 = switch (forge) {
        .github => &.{ "DEVAGENTS_GITHUB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN" },
        .gitlab => &.{ "DEVAGENTS_GITLAB_TOKEN", "GITLAB_TOKEN" },
        .gitea => &.{ "DEVAGENTS_GITEA_TOKEN", "GITEA_TOKEN" },
    };
    const pin_name: [*:0]const u8 = switch (forge) {
        .github => "DEVAGENTS_GITHUB_HOST",
        .gitlab => "DEVAGENTS_GITLAB_HOST",
        .gitea => "DEVAGENTS_GITEA_HOST",
    };
    const pinned_host = try gitea_mod.envVar(allocator, pin_name);
    defer if (pinned_host) |p| allocator.free(p);
    for (names) |name| {
        if (!envCredentialAllowed(forge, host, pinned_host)) break;
        if (try gitea_mod.envVar(allocator, name)) |token| {
            defer allocator.free(token);
            if (std.mem.indexOfAny(u8, token, "\r\n") != null) return error.InvalidCredential;
            return try std.fmt.allocPrint(allocator, "{s} {s}", .{ if (forge == .gitea) "token" else "Bearer", token });
        }
    }

    const input = try std.fmt.allocPrint(allocator, "protocol=https\nhost={s}\n\n", .{host});
    defer allocator.free(input);
    var cap = gh.captureInput(&[_][]const u8{ "git", "credential", "fill" }, null, input, gh_mod.GIT_GUARD_ENV) catch return null;
    defer cap.deinit(gh.allocator);
    defer @memset(cap.stdout, 0);
    if (cap.exit_code != 0) return null;
    var user: ?[]const u8 = null;
    var pass: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, cap.stdout, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, l, "username=")) user = l["username=".len..];
        if (std.mem.startsWith(u8, l, "password=")) pass = l["password=".len..];
    }
    if (pass == null or pass.?.len == 0) return null;
    if (forge != .gitea) return try std.fmt.allocPrint(allocator, "Bearer {s}", .{pass.?});
    if (user == null or user.?.len == 0) return null;
    return try gitea_mod.basicAuthHeader(allocator, user.?, pass.?);
}

/// Empaqueta el trabajo de la orden en `worktree` y abre (o adopta) su PR.
/// `order_db_id` es el rowid real en `orders`; `prompt` alimenta título/cuerpo.
/// `gitea` es el conector REST para remotes que no son GitHub (T4) — null en
/// producción solo si el llamador ya sabe que el remote es GitHub.
pub fn shipOrder(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    gh: *gh_mod.GitHubConnector,
    gitea: ?*gitea_mod.GiteaConnector,
    order_db_id: i64,
    prompt: []const u8,
    worktree: []const u8,
) !ShipResult {
    return shipOrderWithOptions(allocator, conn, gh, gitea, order_db_id, prompt, worktree, .{});
}

/// versión de shipOrder con opciones (draft). El resto idéntico.
pub fn shipOrderWithOptions(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    gh: *gh_mod.GitHubConnector,
    gitea: ?*gitea_mod.GiteaConnector,
    order_db_id: i64,
    prompt: []const u8,
    worktree: []const u8,
    opts: ShipOptions,
) !ShipResult {
    // estado de la enmienda y del borrador para el resultado.
    var amended = false;
    var draft_missing = false;
    var note: ?[]const u8 = null;
    // 1. Debe ser un repo git. Sin esto no hay nada que empaquetar.
    {
        var cap = gh.capture(&[_][]const u8{ "git", "rev-parse", "--is-inside-work-tree" }, worktree) catch |e| {
            gh.setLastError("", @errorName(e));
            return error.GhUnavailable;
        };
        defer cap.deinit(gh.allocator);
        const t = std.mem.trim(u8, cap.stdout, " \t\r\n");
        if (cap.exit_code != 0 or !std.mem.eql(u8, t, "true")) {
            gh.setLastError(cap.stderr, "no es un repositorio git");
            return error.NotAGitRepo;
        }
    }

    // 2. Remote + forge por la URL real de `origin` (T4): github.com sigue por
    //    `gh` (auth del CLI); cualquier otro host va por la API REST de Gitea.
    var remote = try detectRemote(gh, allocator, worktree);
    defer remote.deinit(allocator);

    // slug + rama base: GitHub los confirma la API de `gh`; Gitea los saca del
    // remote y de git local (la API solo hace falta si se va a crear el PR).
    var slug: []const u8 = remote.slug;
    var base: ?[]const u8 = null;
    var gh_info: ?gh_mod.GitHubConnector.RepoInfo = null;
    defer if (gh_info) |*i| i.deinit(allocator);
    var gitea_base: ?[]u8 = null;
    defer if (gitea_base) |b| allocator.free(b);
    const use_rest = gh.rest_enabled and gitea != null;
    if (remote.forge == .github and !use_rest) {
        gh_info = try gh.detectRepo(worktree);
        slug = gh_info.?.slug;
        base = gh_info.?.base;
    } else {
        gitea_base = try giteaBaseBranch(gh, allocator, worktree);
        base = gitea_base;
    }

    // 3. Rama de trabajo: la actual si no es la base ni HEAD detachado; si no,
    //    `devagents/orden-<id>` recién creada sobre HEAD.
    var branch: []u8 = undefined;
    {
        var cap = try runOk(gh, &[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, worktree, error.GitFailed, "git rev-parse HEAD");
        defer cap.deinit(gh.allocator);
        const cur = std.mem.trim(u8, cap.stdout, " \t\r\n");
        // Solo se conserva la rama actual si es una rama de feature real: la
        // base, master/main por defecto o HEAD detachado fuerzan devagents/orden-<id>
        // (nunca se pushea la rama principal del repo a origin).
        const on_default = std.mem.eql(u8, cur, "main") or std.mem.eql(u8, cur, "master");
        if (cur.len > 0 and !std.mem.eql(u8, cur, "HEAD") and !std.mem.eql(u8, cur, base orelse "") and !on_default) {
            branch = try allocator.dupe(u8, cur);
        } else {
            // (a): la rama que ve el usuario dice DevAgents, no DevAgents.
            const name = try std.fmt.allocPrint(allocator, "devagents/orden-{d}", .{order_db_id});
            errdefer allocator.free(name);
            var chk = try runOk(gh, &[_][]const u8{ "git", "checkout", "-b", name }, worktree, error.GitFailed, "git checkout -b");
            chk.deinit(gh.allocator);
            branch = name;
        }
    }
    errdefer allocator.free(branch);

    // 4. Árbol sucio → commit. "Ship" significa empaquetar el trabajo: el diff
    //    que el usuario aprobó/revisó se sella en la rama antes de empujarla.
    {
        var cap = try runOk(gh, &[_][]const u8{ "git", "status", "--porcelain" }, worktree, error.GitFailed, "git status");
        defer cap.deinit(gh.allocator);
        if (std.mem.trim(u8, cap.stdout, " \t\r\n").len > 0) {
            var add = try runOk(gh, &[_][]const u8{ "git", "add", "-A" }, worktree, error.GitFailed, "git add -A");
            add.deinit(gh.allocator);
            const msg = try prTitle(gh.allocator, order_db_id, prompt);
            defer gh.allocator.free(msg);
            var com = try runOk(gh, &[_][]const u8{ "git", "commit", "-m", msg }, worktree, error.GitFailed, "git commit");
            com.deinit(gh.allocator);
        }
    }

    // 5. Push: la rama tiene que existir en remoto para que el PR la referencie.
    {
        var cap = try runOk(gh, &[_][]const u8{ "git", "push", "-u", "origin", branch }, worktree, error.GitPushFailed, "git push");
        cap.deinit(gh.allocator);
    }

    // 6/7. PR por forge. GitHub: adoptar-via-gh o crear-via-gh (número y estado
    //    confirmados con `gh pr view`). Gitea: si hay credencial de API, mismo
    //    contrato por REST; si NO la hay, el push ya es real y se devuelve el
    //    /compare para abrir el PR a mano — jamás un /pull/N inventado.
    var number: i64 = 0;
    var state: gh_mod.PullRequestState = .open;
    var url: ?[]const u8 = null;
    // Uno solo de errdefer cubre las rutas de error de TODOS los caminos
    // (REST, gh y conector directo): el llamador comparte el allocator con
    // gh/conector (c_api.zig), el free puntual ya no existe y no hay doble
    // liberación. En éxito la propiedad pasa a la ShipResult.
    errdefer if (url) |u| allocator.free(u);
    var adopted = false;
    var manual = false;
    var provider: []const u8 = "github";
    if (use_rest) {
        const transport = gitea.?;
        provider = @tagName(remote.forge);
        if (transport.auth_header == null) transport.auth_header = try resolveForgeAuth(gh, transport.allocator, remote.forge, remote.host);
        if (transport.auth_header == null) {
            if (remote.forge != .gitea) return error.ForgeUnauthorized;
            manual = true;
            url = try std.fmt.allocPrint(allocator, "{s}/{s}/compare", .{ remote.web_base, slug });
        } else {
            var forge = forge_mod.ForgeConnector{ .transport = transport, .kind = remote.forge, .web_base = remote.web_base, .slug = slug };
            var api_base: ?[]u8 = null;
            defer if (api_base) |b| transport.allocator.free(b);
            if (base == null) api_base = forge.repoDefaultBranch() catch |e| {
                gh.setLastError(transport.last_error.items, @errorName(e));
                return e;
            };
            if (try forge.listOpenPrForBranch(branch)) |listed| {
                number = listed.number;
                state = listed.state;
                url = try allocator.dupe(u8, listed.url);
                transport.allocator.free(listed.url);
                adopted = true;
                // enmienda: el re-ship con PR ABIERTO la actualiza
                // con título/cuerpo de ESTA orden por PATCH (github/gitea) o
                // PUT (gitlab), conservando el número y sin POST nuevo.
                var title: []u8 = try optionTitle(allocator, order_db_id, prompt, remote.forge, opts.draft);
                defer allocator.free(title);
                // R2-2: si el PR ABIERTO ya lleva prefijo WIP:/Draft: y ESTE
                // ship va SIN draft, la marca se conserva — borrarla en
                // silencio lo sacaría del borrador. GET fallido → nota.
                if (!opts.draft and remote.forge != .github) {
                    const remote_mark: ?[]const u8 = remotePrDraftMark(transport, remote.forge, remote.web_base, slug, number) catch blk: {
                        note = NOTE_WIP_UNCHECKED;
                        break :blk null;
                    };
                    if (remote_mark) |prefix| {
                        const conserved = try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, title });
                        allocator.free(title);
                        title = conserved;
                    }
                }
                const body = try prBody(allocator, conn, order_db_id, prompt, remote);
                defer allocator.free(body);
                if (opts.draft and remote.forge == .github) {
                    // GitHub no acepta "draft" en PATCH: si el PR ya abierto no
                    // era borrador, se dice en el resultado, nunca en silencio.
                    const already = try remotePrIsDraft(transport, remote.forge, remote.web_base, slug, number);
                    if (already == null or already.? == false) {
                        draft_missing = true;
                        note = NOTE_DRAFT_MISSING;
                    }
                }
                forgePatchTitleBody(transport, remote.forge, remote.web_base, slug, number, title, body) catch |e| {
                    gh.setLastError(transport.last_error.items, @errorName(e));
                    return e;
                };
                amended = true;
                const references = try issues.prReferences(allocator, conn, order_db_id, switch (remote.forge) {
                    .github => .github,
                    .gitlab => .gitlab,
                    .gitea => .gitea,
                }, remote.slug, remote.web_base);
                defer allocator.free(references);
                if (references.len > 0) try forge.ensurePullRequestReferences(number, references);
            } else {
                const title = try optionTitle(allocator, order_db_id, prompt, remote.forge, opts.draft);
                defer allocator.free(title);
                const body = try prBody(allocator, conn, order_db_id, prompt, remote);
                defer allocator.free(body);
                if (opts.draft and remote.forge == .github) {
                    var pr = forgeCreateDraftPr(transport, remote.web_base, slug, title, body, branch, base orelse api_base.?) catch |e| {
                        gh.setLastError(transport.last_error.items, @errorName(e));
                        return e;
                    };
                    defer pr.deinit(transport.allocator);
                    number = pr.number;
                    state = pr.state;
                    url = try allocator.dupe(u8, pr.url);
                } else {
                    var pr = forge.createPullRequest(title, body, branch, base orelse api_base.?) catch |e| {
                        gh.setLastError(transport.last_error.items, @errorName(e));
                        return e;
                    };
                    defer pr.deinit(transport.allocator);
                    number = pr.number;
                    state = pr.state;
                    url = try allocator.dupe(u8, pr.url);
                }
            }
        }
    } else if (remote.forge == .github) {
        if (try gh.listOpenPrForBranch(slug, branch, worktree)) |listed| {
            const l = listed;
            number = l.number;
            state = l.state;
            url = l.url;
            adopted = true;
            // enmienda vía gh: título/cuerpo de este ship por
            // `gh pr edit <n>`, conservando el número sin crear otro PR.
            // Título SIN prefijo: el borrador de GitHub no marca por título.
            const title = try prTitle(gh.allocator, order_db_id, prompt);
            defer gh.allocator.free(title);
            const body = try prBody(gh.allocator, conn, order_db_id, prompt, remote);
            defer gh.allocator.free(body);
            try ghPatchTitleBody(gh, gh.allocator, slug, number, title, body, worktree);
            amended = true;
            if (opts.draft) {
                const already = ghPrIsDraft(gh, gh.allocator, slug, number, worktree);
                if (already == null or already.? == false) {
                    draft_missing = true;
                    note = NOTE_DRAFT_MISSING;
                }
            }
        } else {
            if (opts.draft) {
                // El borrador por la CLI exige --draft en la firma de
                // createPullRequest de github.zig: fuera del lock de este
                // encargo (cableado pendiente). La vía REST es la de
                // forgeCreateDraftPr; el fallo es honesto, jamás un PR
                // normal disfrazado.
                gh.setLastError("", "borrador via gh CLI no disponible: la firma de createPullRequest de github.zig no expone --draft, cableado pendiente; para el borrador via REST se necesita rest_enabled y conector");
                return error.GhDraftUnsupported;
            }
            const title = try prTitle(gh.allocator, order_db_id, prompt);
            defer gh.allocator.free(title);
            const body = try prBody(gh.allocator, conn, order_db_id, prompt, remote);
            defer gh.allocator.free(body);
            const pr = try gh.createPullRequest(slug, title, body, branch, base.?, worktree);
            defer {
                gh.allocator.free(pr.provider);
                gh.allocator.free(pr.repo);
            }
            number = pr.number;
            state = pr.state;
            url = pr.url;
        }
    } else {
        provider = "gitea";
        const conn_g = gitea orelse {
            gh.setLastError("", "remote Gitea sin conector configurado");
            return error.GiteaUnavailable;
        };
        // Credencial: env token → git credential fill (la misma del push). Se
        // resuelve con el allocator DEL CONECTOR — deinit la libera él.
        if (conn_g.auth_header == null) {
            conn_g.auth_header = try resolveGiteaAuth(gh, conn_g.allocator, remote.host);
        }
        if (conn_g.auth_header == null) {
            // Degradado honesto: la rama YA está en origin (el push es real),
            // solo falta el PR. La URL /compare de Gitea es el punto real donde
            // el usuario lo abre a mano — sin base conocida, /compare a secas.
            const compare = if (base) |b|
                try std.fmt.allocPrint(allocator, "{s}/{s}/compare/{s}...{s}", .{ remote.web_base, slug, b, branch })
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}/compare", .{ remote.web_base, slug });
            manual = true;
            url = compare;
        } else {
            // Base: la de git local; si git no la sabe, la API del repo manda.
            var base_str: []const u8 = undefined;
            var base_owned: ?[]u8 = null;
            defer if (base_owned) |b| allocator.free(b);
            if (base) |b| {
                base_str = b;
            } else {
                base_owned = try conn_g.repoDefaultBranch(remote.web_base, slug);
                base_str = base_owned.?;
            }
            if (try conn_g.listOpenPrForBranch(remote.web_base, slug, branch)) |listed| {
                const l = listed;
                number = l.number;
                state = l.state;
                url = l.url;
                adopted = true;
                // enmienda en la vía conector-directo: PATCH
                // /api/v1/repos/{slug}/pulls/{n} con título/cuerpo de esta
                // orden (gitea.zig no expone update; se usa su transporte REST,
                // misma URL que sus propias llamadas). El prefijo WIP: del
                // título basta para que Gitea lo marque borrador.
                const title0 = try optionTitle(allocator, order_db_id, prompt, .gitea, opts.draft);
                var title: []u8 = title0;
                defer allocator.free(title);
                // R2-2: el PR ABIERTO que ya lleva prefijo WIP: conserva la
                // marca aunque ESTE ship vaya sin draft; GET fallido → nota.
                if (!opts.draft) {
                    const remote_mark: ?[]const u8 = remotePrDraftMark(conn_g, remote.forge, remote.web_base, slug, number) catch blk: {
                        note = NOTE_WIP_UNCHECKED;
                        break :blk null;
                    };
                    if (remote_mark) |prefix| {
                        const conserved = try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, title });
                        allocator.free(title);
                        title = conserved;
                    }
                }
                const body = try prBody(allocator, conn, order_db_id, prompt, remote);
                defer allocator.free(body);
                giteaPatchTitleBody(conn_g, allocator, remote.web_base, slug, number, title, body) catch |e| {
                    // La url del PR listado la libera el errdefer común de
                    // shipOrderWithOptions (R2-1): aquí no, doble gratis no.
                    return e;
                };
                amended = true;
            } else {
                const title = try optionTitle(allocator, order_db_id, prompt, .gitea, opts.draft);
                defer allocator.free(title);
                const body = try prBody(allocator, conn, order_db_id, prompt, remote);
                defer allocator.free(body);
                const pr = try conn_g.createPullRequest(remote.web_base, slug, title, body, branch, base_str);
                defer {
                    var p = pr;
                    p.deinit(allocator);
                }
                number = pr.number;
                state = pr.state;
                url = try allocator.dupe(u8, pr.url);
            }
        }
    }
    // La propiedad de `url` pasa al ShipResult (la libera su deinit).

    // 8. Fila en pull_requests — idempotente por (order_id, number). Solo si el
    //    PR EXISTE de verdad: un ship manual no escribe fila (number=0 sería un
    //    PR fantasma que el poller sondearía para siempre).
    var pr_id: i64 = 0;
    if (!manual) {
        pr_id = try upsertPrRow(conn, order_db_id, provider, slug, number, state, url.?);
    }

    return ShipResult{
        .pr_id = pr_id,
        .number = number,
        .state = state,
        .url = url.?,
        .branch = branch,
        .adopted = adopted,
        .manual = manual,
        .amended = amended,
        .draft = opts.draft,
        .draft_missing = draft_missing,
        .note = note,
    };
}

/// Merge real del PR: `gh pr merge --auto --merge` en GitHub, o
/// POST /pulls/{n}/merge en Gitea (T4 — la fila lleva `provider` desde que se
/// creó). Refresco autoritativo del estado con la vista de su propia forge; si
/// falla, la fila queda como estaba y el error real queda en last_error.
pub fn mergePr(
    conn: db.Connection,
    gh: *gh_mod.GitHubConnector,
    gitea: ?*gitea_mod.GiteaConnector,
    pr_id: i64,
) !gh_mod.PullRequestState {
    var repo_buf: [512]u8 = undefined;
    var repo_len: usize = 0;
    var prov_buf: [16]u8 = undefined;
    var prov_len: usize = 0;
    var url_buf: [512]u8 = undefined;
    var url_len: usize = 0;
    var number: i64 = 0;
    {
        const sel = try conn.prepare("SELECT repo, number, provider, url FROM pull_requests WHERE id = ?");
        defer conn.finalize(sel);
        try db.bindInt(sel, 1, pr_id);
        if (db.c.sqlite3_step(sel) != db.c.SQLITE_ROW) return error.NotFound;
        const r = std.mem.span(db.c.sqlite3_column_text(sel, 0));
        repo_len = @min(r.len, repo_buf.len - 1);
        @memcpy(repo_buf[0..repo_len], r[0..repo_len]);
        number = db.c.sqlite3_column_int64(sel, 1);
        const p = db.c.sqlite3_column_text(sel, 2);
        if (p != null) {
            const ps = std.mem.span(p);
            prov_len = @min(ps.len, prov_buf.len - 1);
            @memcpy(prov_buf[0..prov_len], ps[0..prov_len]);
        }
        const u = db.c.sqlite3_column_text(sel, 3);
        if (u != null) {
            const us = std.mem.span(u);
            url_len = @min(us.len, url_buf.len - 1);
            @memcpy(url_buf[0..url_len], us[0..url_len]);
        }
    }
    const repo = repo_buf[0..repo_len];
    const provider = prov_buf[0..prov_len];

    var new_state: gh_mod.PullRequestState = undefined;
    if (gh.rest_enabled and gitea != null) {
        const kind = std.meta.stringToEnum(gh_mod.Forge, provider) orelse return error.BadRemoteUrl;
        const transport = gitea.?;
        const web_base = webBaseFromPrUrl(url_buf[0..url_len]) orelse return error.BadRemoteUrl;
        const host = web_base[std.mem.indexOf(u8, web_base, "://").? + 3 ..];
        if (gitea_mod.detectForgeConfigured(host, gh.forge_hosts) != kind) return error.BadRemoteUrl;
        if (transport.auth_header == null) transport.auth_header = try resolveForgeAuth(gh, transport.allocator, kind, host);
        if (transport.auth_header == null) return error.ForgeUnauthorized;
        var forge = forge_mod.ForgeConnector{ .transport = transport, .kind = kind, .web_base = web_base, .slug = repo };
        try forge.mergePullRequest(number);
        new_state = try forge.pullRequestState(number);
    } else if (std.mem.eql(u8, provider, "gitea")) {
        const conn_g = gitea orelse {
            gh.setLastError("", "PR de Gitea sin conector configurado");
            return error.GiteaUnavailable;
        };
        // web_base = scheme://host de la URL del PR (autoridad ya verificada).
        const web_base = webBaseFromPrUrl(url_buf[0..url_len]) orelse {
            gh.setLastError(url_buf[0..url_len], "URL de PR sin scheme://host");
            return error.BadRemoteUrl;
        };
        if (conn_g.auth_header == null) {
            const host = web_base[std.mem.indexOf(u8, web_base, "://").? + 3 ..];
            conn_g.auth_header = try resolveGiteaAuth(gh, conn_g.allocator, host);
            if (conn_g.auth_header == null) {
                gh.setLastError("", "merge Gitea sin credencial de API");
                return error.GiteaUnavailable;
            }
        }
        try conn_g.mergePullRequest(web_base, repo, number);
        new_state = conn_g.pullRequestState(web_base, repo, number) catch |e| return e;
    } else {
        try gh.mergePullRequest(repo, number, null);
        new_state = gh.getPullRequestState(repo, number) catch |e| return e;
    }

    const upd = try conn.prepare("UPDATE pull_requests SET state = ?, last_polled_at = ? WHERE id = ?");
    defer conn.finalize(upd);
    try db.bindText(upd, 1, new_state.toString());
    try db.bindInt(upd, 2, health.nowSeconds(conn));
    try db.bindInt(upd, 3, pr_id);
    if (db.c.sqlite3_step(upd) != db.c.SQLITE_DONE) return error.StepFailed;
    return new_state;
}

/// PRs de una orden (order_id <= 0 → todas), más recientes primero.
pub fn listPrs(allocator: std.mem.Allocator, conn: db.Connection, order_id: i64) ![]PrRow {
    const sql = if (order_id > 0)
        "SELECT id, order_id, repo, number, state, url, last_polled_at FROM pull_requests WHERE order_id = ? ORDER BY id DESC"
    else
        "SELECT id, order_id, repo, number, state, url, last_polled_at FROM pull_requests ORDER BY id DESC";
    const stmt = try conn.prepare(sql);
    defer conn.finalize(stmt);
    if (order_id > 0) try db.bindInt(stmt, 1, order_id);

    var list = std.ArrayList(PrRow).empty;
    errdefer {
        for (list.items) |*r| r.deinit(allocator);
        list.deinit(allocator);
    }
    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        try list.append(allocator, .{
            .id = db.c.sqlite3_column_int64(stmt, 0),
            .order_id = db.c.sqlite3_column_int64(stmt, 1),
            .repo = try allocator.dupe(u8, std.mem.span(db.c.sqlite3_column_text(stmt, 2))),
            .number = db.c.sqlite3_column_int64(stmt, 3),
            .state = try allocator.dupe(u8, std.mem.span(db.c.sqlite3_column_text(stmt, 4))),
            .url = try allocator.dupe(u8, std.mem.span(db.c.sqlite3_column_text(stmt, 5))),
            .last_polled_at = db.c.sqlite3_column_int64(stmt, 6),
        });
    }
    return list.toOwnedSlice(allocator);
}

// ───────────────────────────── tests ─────────────────────────────

const ScriptEntry = struct {
    /// Subcadena que debe aparecer en el argv unido para casar la respuesta.
    match: []const u8,
    exit: u32 = 0,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    /// Marca la llamada como fallo de SPAWN (gh no existe) en vez de exit!=0.
    spawn_fail: bool = false,
};

/// Estado global del runner guionado. Los tests de un binario Zig corren en
/// serie; cada test fija `script` y vacía `script_calls` al empezar.
var script: []const ScriptEntry = &.{};
var script_calls: std.ArrayListUnmanaged([]u8) = .empty;
/// Paralelo a script_calls via fakeCaptureFull: el env recibido en cada
/// llamada ("K=V;K=V" o "" si no lleva). Permite EXIGIR la guardia.
var script_envs: std.ArrayListUnmanaged([]u8) = .empty;
/// Cuando es true, argv[0]=="git" se delega al runner Win32 real — prueba la
/// mitad git del flujo contra un repositorio de verdad.
var git_real: bool = false;

fn joinArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    for (argv, 0..) |a, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, a);
    }
    return buf.toOwnedSlice(allocator);
}

/// Registra una llamada en script_calls y script_envs manteniendolas SIEMPRE
/// paralelas (una entrada por lista por llamada, sea cual sea la seam).
/// TOMA la propiedad de ambos buffers: si el append falla los libera el,
/// para que el llamador no arme errdefers que los liberen dos veces cuando
/// una respuesta guionada devuelva error DESPUES del registro.
fn logCallEntry(joined: []u8, env_owned: []u8) !void {
    script_calls.append(std.testing.allocator, joined) catch |e| {
        std.testing.allocator.free(joined);
        std.testing.allocator.free(env_owned);
        return e;
    };
    script_envs.append(std.testing.allocator, env_owned) catch |e| {
        _ = script_calls.pop();
        std.testing.allocator.free(joined);
        std.testing.allocator.free(env_owned);
        return e;
    };
}

/// Respuesta guionada para una llamada ya registrada — el default ruidoso 127
/// asegura que el flujo nunca recibe un exit 0 que el test no previó.
fn scriptedOr127(allocator: std.mem.Allocator, joined: []const u8) anyerror!gh_mod.CmdCapture {
    for (script) |e| {
        if (std.mem.indexOf(u8, joined, e.match) != null) {
            if (e.spawn_fail) return error.SpawnFailed;
            return .{
                .exit_code = e.exit,
                .stdout = try allocator.dupe(u8, e.stdout),
                .stderr = try allocator.dupe(u8, e.stderr),
            };
        }
    }
    // Entrada no guionada: fallo ruidoso, nunca un 0 mudo — si el flujo pide
    // algo que el test no previó, el test lo ve.
    return .{
        .exit_code = 127,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, "comando no guionado"),
    };
}

fn fakeCapture(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!gh_mod.CmdCapture {
    const joined = try joinArgv(allocator, argv);
    const empty_env = std.testing.allocator.dupe(u8, "") catch {
        allocator.free(joined);
        return error.Oom;
    };
    try logCallEntry(joined, empty_env);
    if (git_real and argv.len > 0 and std.mem.eql(u8, argv[0], "git")) {
        // Mismo env que capture aplica en produccion — el git real
        // del test corre identico al del producto.
        return gh_mod.runCmdCaptureWin32Input(allocator, argv, cwd, null, gh_mod.GIT_GUARD_ENV);
    }
    return scriptedOr127(allocator, joined);
}

/// fake de la seam completa — registra argv en script_calls y el env en
/// script_envs (mismo orden). Con git_real delega a runCmdCaptureWin32Input
/// PASANDO el env: asi la guardia llega de verdad al proceso git real y el
/// test de integracion 401 no cuelga un dialogo de credenciales.
fn fakeCaptureFull(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    input: ?[]const u8,
    extra_env: ?[]const []const u8,
) anyerror!gh_mod.CmdCapture {
    const joined = try joinArgv(allocator, argv);
    var env_str = std.ArrayList(u8).empty;
    defer env_str.deinit(std.testing.allocator);
    if (extra_env) |ee| {
        for (ee, 0..) |kv, i| {
            if (i > 0) env_str.append(std.testing.allocator, ';') catch {
                allocator.free(joined);
                return error.Oom;
            };
            env_str.appendSlice(std.testing.allocator, kv) catch {
                allocator.free(joined);
                return error.Oom;
            };
        }
    }
    const env_owned = env_str.toOwnedSlice(std.testing.allocator) catch {
        allocator.free(joined);
        return error.Oom;
    };
    try logCallEntry(joined, env_owned);
    if (git_real and argv.len > 0 and std.mem.eql(u8, argv[0], "git")) {
        return gh_mod.runCmdCaptureWin32Input(allocator, argv, cwd, input, extra_env);
    }
    return scriptedOr127(allocator, joined);
}

fn resetScript(entries: []const ScriptEntry) void {
    for (script_calls.items) |c| std.testing.allocator.free(c);
    script_calls.deinit(std.testing.allocator);
    script_calls = .empty;
    for (script_envs.items) |e| std.testing.allocator.free(e);
    script_envs.deinit(std.testing.allocator);
    script_envs = .empty;
    script = entries;
    git_real = false;
    rest_queue.deinit(std.testing.allocator);
    rest_queue = .empty;
}

/// Respuestas REST guionadas por llamada — la misma idea que `script` pero
/// para la capa HTTP de Gitea (no pasa por capture_fn, es otro canal).
/// Cada llamada consume una entrada en orden; sin entrada = fallo ruidoso.
const RestEntry = struct {
    /// Substring que debe contener la URL para aplicar ("" = cualquiera).
    match: []const u8 = "",
    status: u16 = 200,
    body: []const u8 = "",
};

var rest_queue: std.ArrayListUnmanaged(RestEntry) = .empty;

fn scriptRest(entries: []const RestEntry) void {
    rest_queue.clearRetainingCapacity();
    rest_queue.appendSlice(std.testing.allocator, entries) catch {};
}

fn fakeRest(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    auth: ?[]const u8,
    body: ?[]const u8,
    ctx: ?*anyopaque,
) anyerror!gitea_mod.RestResponse {
    _ = ctx;
    _ = auth;
    // el cuerpo (payload) se registra tras la URL con " | " para
    // que los tests puedan exigir "draft":true, prefijos WIP: o el PATCH de
    // la enmienda — antes se descartaba.
    const joined = if (body) |b|
        try std.fmt.allocPrint(allocator, "{s} {s} | {s}", .{ method, url, b })
    else
        try std.fmt.allocPrint(allocator, "{s} {s}", .{ method, url });
    script_calls.append(std.testing.allocator, joined) catch {
        allocator.free(joined);
        return error.Oom;
    };
    for (rest_queue.items, 0..) |e, i| {
        if (e.match.len == 0 or std.mem.indexOf(u8, url, e.match) != null) {
            _ = rest_queue.orderedRemove(i);
            return .{ .status = e.status, .body = try allocator.dupe(u8, e.body) };
        }
    }
    return .{ .status = 500, .body = try allocator.dupe(u8, "REST no guionada") };
}

/// Vacia el log de llamadas entre fases de un test SIN soltar la capacidad
/// (esa la libera el resetScript del defer — antes lo tiraba y fugaba).
fn clearCalls() void {
    for (script_calls.items) |c| std.testing.allocator.free(c);
    script_calls.clearRetainingCapacity();
}

fn callsJoined(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    for (script_calls.items) |c| {
        try buf.appendSlice(allocator, c);
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

fn callsContain(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn testConn() !db.Connection {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    errdefer conn.close();
    const migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    return conn;
}

fn fakeGh() gh_mod.GitHubConnector {
    var gh = gh_mod.GitHubConnector.init(std.testing.allocator, null);
    gh.capture_fn = fakeCapture;
    gh.rest_enabled = false;
    return gh;
}

/// conector con la seam completa — los tests ven argv Y env.
fn fakeGhFull() gh_mod.GitHubConnector {
    var gh = gh_mod.GitHubConnector.init(std.testing.allocator, null);
    gh.capture_full_fn = fakeCaptureFull;
    gh.rest_enabled = false;
    return gh;
}

test "E5.26 ship common REST creates adopts and merges each forge without gh" {
    const a = std.testing.allocator;
    inline for (.{ gh_mod.Forge.github, gh_mod.Forge.gitlab, gh_mod.Forge.gitea }) |kind| {
        var entries = HAPPY_SCRIPT;
        entries[1].stdout = switch (kind) {
            .github => "https://github.com/acme/widgets.git",
            .gitlab => "https://gitlab.com/acme/widgets.git",
            .gitea => "https://git.4stra.dev/acme/widgets.git",
        };
        resetScript(&entries);
        defer resetScript(&.{});
        var conn = try testConn();
        defer conn.close();
        var gh = fakeGhFull();
        defer gh.deinit();
        gh.rest_enabled = true;
        var transport = fakeGitea();
        defer transport.deinit();
        transport.auth_header = try a.dupe(u8, "Bearer synthetic");
        const object = switch (kind) {
            .github => "{\"number\":42,\"html_url\":\"https://github.com/acme/widgets/pull/42\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}",
            .gitlab => "{\"iid\":42,\"web_url\":\"https://gitlab.com/acme/widgets/-/merge_requests/42\",\"state\":\"opened\",\"source_branch\":\"devagents/orden-7\"}",
            .gitea => "{\"number\":42,\"html_url\":\"https://git.4stra.dev/acme/widgets/pulls/42\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}",
        };
        scriptRest(&.{
            .{ .body = "{\"default_branch\":\"main\"}" },
            .{ .body = "[]" },
            .{ .status = 201, .body = object },
        });
        var created = try ship_flow_ship(a, conn, &gh, &transport);
        defer created.deinit(a);
        try std.testing.expectEqual(@as(i64, 42), created.number);
        try std.testing.expect(!created.adopted);
        const array = try std.fmt.allocPrint(a, "[{s}]", .{object});
        defer a.free(array);
        // la adopción ahora ENMIENDA (PUT/PATCH) con "{}";
        // R2-2: para no-GitHub la conservación de marca añade el GET del título
        // antes del PUT/PATCH (también se consume una entrada de guion).
        scriptRest(&.{ .{ .body = "{\"default_branch\":\"main\"}" }, .{ .body = array }, .{ .body = "{\"number\":42,\"state\":\"open\",\"title\":\"DevAgents #7: Implementa el login\"}" }, .{ .body = "{}" } });
        var adopted = try ship_flow_ship(a, conn, &gh, &transport);
        defer adopted.deinit(a);
        try std.testing.expect(adopted.adopted);
        try std.testing.expectEqual(created.pr_id, adopted.pr_id);
        try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
        scriptRest(&.{ .{ .body = "{\"merged\":true}" }, .{ .body = if (kind == .gitlab) "{\"state\":\"merged\"}" else "{\"state\":\"closed\",\"merged\":true}" } });
        try std.testing.expectEqual(gh_mod.PullRequestState.merged, try mergePr(conn, &gh, &transport, created.pr_id));
        const calls = try callsJoined(a);
        defer a.free(calls);
        try std.testing.expect(!callsContain(calls, "gh "));
        // R2-6: la enmienda se distingue del merge por MÉTODO y URL exactos.
        const amendment_call = switch (kind) {
            .github => "PATCH https://api.github.com/repos/acme/widgets/pulls/42",
            .gitlab => "PUT https://gitlab.com/api/v4/projects/acme%2Fwidgets/merge_requests/42",
            .gitea => "PATCH https://git.4stra.dev/api/v1/repos/acme/widgets/pulls/42",
        };
        try std.testing.expect(callsContain(calls, amendment_call));
        try std.testing.expect(callsContain(calls, if (kind == .gitlab) "\"description\":" else "\"body\":"));
    }
}

const AuthFixture = struct {
    calls: usize = 0,
    header: []const u8 = "Bearer fx-gh",
    fn auth(a: std.mem.Allocator, kind: gh_mod.Forge, host: []const u8, ctx: ?*anyopaque) !?[]u8 {
        const f: *AuthFixture = @ptrCast(@alignCast(ctx.?));
        f.calls += 1;
        try std.testing.expectEqual(gh_mod.Forge.github, kind);
        try std.testing.expectEqualStrings("github.example", host);
        return try a.dupe(u8, f.header);
    }
};

test "E5.26 forge auth injected key store host guard and git credential E-124" {
    const a = std.testing.allocator;
    resetScript(&.{.{ .match = "git credential fill", .stdout = "username=synthetic\npassword=fx-gh\n" }});
    defer resetScript(&.{});
    var gh = fakeGhFull();
    defer gh.deinit();
    var fixture = AuthFixture{};
    gh.forge_auth_fn = AuthFixture.auth;
    gh.forge_auth_ctx = &fixture;
    try std.testing.expectError(error.BadRemoteUrl, resolveForgeAuth(&gh, a, .github, "github.example\nprotocol=http"));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    const header = (try resolveForgeAuth(&gh, a, .github, "github.example")).?;
    defer a.free(header);
    try std.testing.expectEqualStrings("Bearer fx-gh", header);
    fixture.header = "Bearer fx-gh\r\ninjected: value";
    try std.testing.expectError(error.InvalidCredential, resolveForgeAuth(&gh, a, .github, "github.example"));
    gh.forge_auth_fn = null;
    const git_header = (try resolveForgeAuth(&gh, a, .github, "github.example")).?;
    defer a.free(git_header);
    try std.testing.expectEqualStrings("Bearer fx-gh", git_header);
    try std.testing.expectEqual(@as(usize, 1), script_calls.items.len);
    try std.testing.expect(std.mem.indexOf(u8, script_envs.items[0], "GIT_TERMINAL_PROMPT=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, script_envs.items[0], "GCM_INTERACTIVE=never") != null);
    try std.testing.expectEqual(@as(usize, 0), gh.last_error.items.len);
    try std.testing.expect(envCredentialAllowed(.github, "github.com", null));
    try std.testing.expect(envCredentialAllowed(.gitlab, "gitlab.com", null));
    try std.testing.expect(!envCredentialAllowed(.gitea, "arbitrary.example", null));
    try std.testing.expect(!envCredentialAllowed(.github, "enterprise.example", null));
    try std.testing.expect(!envCredentialAllowed(.gitlab, "enterprise.example", null));
    try std.testing.expect(envCredentialAllowed(.gitea, "gitea.example", "gitea.example"));
    try std.testing.expect(!envCredentialAllowed(.gitea, "other.example", "gitea.example"));
}

test "E5.26 merge rejects forge host mismatch before credential or REST" {
    const a = std.testing.allocator;
    resetScript(&.{});
    defer resetScript(&.{});
    var conn = try testConn();
    defer conn.close();
    const id = try upsertPrRow(conn, 7, "gitlab", "acme/widgets", 42, .open, "https://github.com/acme/widgets/pull/42");
    var gh = fakeGhFull();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{ .{ .body = "{\"state\":\"merged\"}" }, .{ .body = "{\"state\":\"merged\"}" } });
    try std.testing.expectError(error.BadRemoteUrl, mergePr(conn, &gh, &transport, id));
    try std.testing.expectEqual(@as(usize, 0), script_calls.items.len);
}

fn countPrRows(conn: db.Connection) !i64 {
    const stmt = try conn.prepare("SELECT COUNT(*) FROM pull_requests");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    return db.c.sqlite3_column_int64(stmt, 0);
}

const HAPPY_SCRIPT = [_]ScriptEntry{
    .{ .match = "git rev-parse --is-inside-work-tree", .stdout = "true\n" },
    .{ .match = "git remote get-url origin", .stdout = "https://github.com/acme/widgets.git\n" },
    .{ .match = "gh repo view", .stdout = "{\"nameWithOwner\":\"acme/widgets\",\"defaultBranchRef\":{\"name\":\"main\"}}" },
    .{ .match = "git rev-parse --abbrev-ref HEAD", .stdout = "main\n" },
    .{ .match = "git checkout -b", .stdout = "Switched to a new branch" },
    .{ .match = "git status --porcelain", .stdout = "" },
    .{ .match = "git add -A", .stdout = "" },
    .{ .match = "git commit", .stdout = "[devagents/orden-7 abc123] DevAgents #7" },
    .{ .match = "git push -u origin", .stdout = "" },
    .{ .match = "gh pr list", .stdout = "[]" },
    .{ .match = "gh pr create", .stdout = "https://github.com/acme/widgets/pull/42\n" },
    .{ .match = "gh pr view", .stdout = "{\"number\":42,\"state\":\"OPEN\",\"url\":\"https://github.com/acme/widgets/pull/42\",\"statusCheckRollup\":[]}" },
    // la enmienda del PR adoptado pasa por `gh pr edit`.
    .{ .match = "gh pr edit", .stdout = "Edited pull request acme/widgets#17" },
};

test "ship: happy path crea PR con datos REALES de gh y fila en pull_requests" {
    resetScript(&HAPPY_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 42), res.number);
    try std.testing.expectEqualStrings("https://github.com/acme/widgets/pull/42", res.url);
    try std.testing.expectEqual(gh_mod.PullRequestState.open, res.state);
    try std.testing.expectEqualStrings("devagents/orden-7", res.branch);
    try std.testing.expect(!res.adopted);
    try std.testing.expect(!res.manual);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));

    const calls = try callsJoined(allocator);
    defer allocator.free(calls);
    // Rama creada ANTES del push y push ANTES del create.
    const i_co = std.mem.indexOf(u8, calls, "git checkout -b devagents/orden-7").?;
    const i_push = std.mem.indexOf(u8, calls, "git push -u origin devagents/orden-7").?;
    const i_create = std.mem.indexOf(u8, calls, "gh pr create").?;
    try std.testing.expect(i_co < i_push and i_push < i_create);
}

fn fakeGitea() gitea_mod.GiteaConnector {
    var g = gitea_mod.GiteaConnector.init(std.testing.allocator);
    g.http_fn = fakeRest;
    return g;
}

fn ship_flow_ship(allocator: std.mem.Allocator, conn: db.Connection, gh: *gh_mod.GitHubConnector, gitea: *gitea_mod.GiteaConnector) !ShipResult {
    return shipOrder(allocator, conn, gh, gitea, 7, "Implementa el login", "C:/tmp/wt-fake");
}

test "ship: árbol sucio se commitea antes del push" {
    var entries = HAPPY_SCRIPT;
    entries[5].stdout = " M app.js\n?? nuevo.txt\n";
    resetScript(&entries);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    const calls = try callsJoined(allocator);
    defer allocator.free(calls);
    const i_add = std.mem.indexOf(u8, calls, "git add -A").?;
    const i_com = std.mem.indexOf(u8, calls, "git commit -m DevAgents #7").?;
    const i_push = std.mem.indexOf(u8, calls, "git push").?;
    try std.testing.expect(i_add < i_com and i_com < i_push);
}

test "ship: PR ya abierto para la rama se ADOPTA, no se duplica" {
    var entries = HAPPY_SCRIPT;
    entries[9].stdout = "[{\"number\":17,\"url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"OPEN\"}]";
    resetScript(&entries);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    try std.testing.expect(res.adopted);
    try std.testing.expectEqual(@as(i64, 17), res.number);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
    const calls = try callsJoined(allocator);
    defer allocator.free(calls);
    try std.testing.expect(!callsContain(calls, "gh pr create"));
}

test "ship: no es repo git — error honesto, sin fila ni push" {
    var entries = HAPPY_SCRIPT;
    entries[0].exit = 128;
    entries[0].stdout = "";
    entries[0].stderr = "fatal: not a git repository";
    resetScript(&entries);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    try std.testing.expectError(error.NotAGitRepo, ship_flow_ship(allocator, conn, &gh, &gitea));
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
    try std.testing.expect(std.mem.indexOf(u8, gh.last_error.items, "not a git repository") != null);
}

test "ship: gh ausente — SpawnFailed sube como GhUnavailable" {
    var entries = HAPPY_SCRIPT;
    entries[2].spawn_fail = true;
    resetScript(&entries);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    try std.testing.expectError(error.GhUnavailable, ship_flow_ship(allocator, conn, &gh, &gitea));
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
}

test "ship: gh pr create falla — stderr real en last_error, sin fila" {
    var entries = HAPPY_SCRIPT;
    entries[10].exit = 1;
    entries[10].stdout = "";
    entries[10].stderr = "GraphQL: No commits between main and devagents/orden-7";
    resetScript(&entries);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    try std.testing.expectError(error.GhCreateFailed, ship_flow_ship(allocator, conn, &gh, &gitea));
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
    try std.testing.expect(std.mem.indexOf(u8, gh.last_error.items, "No commits") != null);
}

test "ship: re-ship de la misma orden ACTUALIZA la fila, no duplica" {
    resetScript(&HAPPY_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();

    var gitea = fakeGitea();
    defer gitea.deinit();

    var r1 = try ship_flow_ship(allocator, conn, &gh, &gitea);
    r1.deinit(allocator);
    var r2 = try ship_flow_ship(allocator, conn, &gh, &gitea);
    r2.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
    try std.testing.expectEqual(r1.pr_id, r2.pr_id);
}

test "ship merge: gh pr merge + view refrescan la fila a merged" {
    resetScript(&HAPPY_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    // Segunda vuelta del guion: merge ok y view reporta MERGED.
    const merge_script = [_]ScriptEntry{
        .{ .match = "gh pr merge", .stdout = "Merged" },
        .{ .match = "gh pr view", .stdout = "{\"number\":42,\"state\":\"MERGED\",\"url\":\"https://github.com/acme/widgets/pull/42\",\"statusCheckRollup\":[]}" },
    };
    clearCalls();
    script = &merge_script;

    const st = try mergePr(conn, &gh, &gitea, res.pr_id);
    try std.testing.expectEqual(gh_mod.PullRequestState.merged, st);

    const stmt = try conn.prepare("SELECT state FROM pull_requests WHERE id = ?");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, res.pr_id);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("merged", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
}

test "ship merge: gh falla — fila intacta y error honesto" {
    resetScript(&HAPPY_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    const merge_script = [_]ScriptEntry{
        .{ .match = "gh pr merge", .exit = 1, .stderr = "Pull request is not mergeable" },
    };
    script = &merge_script;

    try std.testing.expectError(error.GhMergeFailed, mergePr(conn, &gh, &gitea, res.pr_id));
    try std.testing.expect(std.mem.indexOf(u8, gh.last_error.items, "not mergeable") != null);
    const stmt = try conn.prepare("SELECT state FROM pull_requests WHERE id = ?");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, res.pr_id);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("open", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
}

test "ship: git REAL en repo temporal — rama creada, commit sellado, push sin remote falla honesto" {
    // No se mockea git: temp repo de verdad, los pasos git corren con el
    // runner Win32 real y gh va guionado. Lo que se comprueba: la rama
    // devagents/orden-N existe tras checkout -b real, el commit se creo de
    // verdad, y el push contra un repo SIN remote da PushFailed con el
    // stderr real de git — nunca un exit 0 inventado.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    var cap = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "init", dir }, null) catch return error.SkipZigTest;
    cap.deinit(allocator);
    var c2 = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "config", "user.email", "b3@test" }, null) catch return error.SkipZigTest;
    c2.deinit(allocator);
    var c3 = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "config", "user.name", "b3" }, null) catch return error.SkipZigTest;
    c3.deinit(allocator);
    // La firma GPG es GLOBAL del usuario (commit.gpgsign=true + signingkey):
    // sin este aislamiento local el commit de prueba cuelga esperando el PIN
    // del gpg-agent y el repo queda sin HEAD (rev-parse falla con GitFailed
    // en lugar del GitPushFailed que el test espera del push sin remote).
    var c3b = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "config", "commit.gpgsign", "false" }, null) catch return error.SkipZigTest;
    c3b.deinit(allocator);
    // Commit inicial sin necesidad de archivo: --allow-empty es determinista
    // (no depende del cwd del proceso de test ni de un redirect de cmd).
    var c6 = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "commit", "--allow-empty", "-m", "init" }, null) catch return error.SkipZigTest;
    c6.deinit(allocator);
    // Remote inalcanzable pero parseable (T4 detecta la forge por su URL antes
    // del push): 127.0.0.1:1 da connection-refused inmediato y honesto.
    var c7 = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "remote", "add", "origin", "https://127.0.0.1:1/acme/widgets.git" }, null) catch return error.SkipZigTest;
    c7.deinit(allocator);

    const real_git_fake_gh = [_]ScriptEntry{
        .{ .match = "gh repo view", .stdout = "{\"nameWithOwner\":\"acme/widgets\",\"defaultBranchRef\":{\"name\":\"main\"}}" },
        .{ .match = "gh pr list", .stdout = "[]" },
        .{ .match = "gh pr create", .stdout = "https://github.com/acme/widgets/pull/9\n" },
        .{ .match = "gh pr view", .stdout = "{\"number\":9,\"state\":\"OPEN\",\"url\":\"https://github.com/acme/widgets/pull/9\",\"statusCheckRollup\":[]}" },
    };
    resetScript(&real_git_fake_gh);
    git_real = true;
    defer resetScript(&.{});

    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    // Remote inalcanzable: el push REAL debe fallar — el error es GitPushFailed
    // con stderr de git (connection refused), nunca exit 0.
    const res = shipOrder(allocator, conn, &gh, &gitea, 7, "cambio", dir);
    if (res) |*r| {
        var rr = r.*;
        rr.deinit(allocator);
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expectEqual(error.GitPushFailed, e);
        try std.testing.expect(gh.last_error.items.len > 0);
    }
    // Pero la rama SI se creó de verdad dentro del repo temporal.
    var br = try gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "branch", "--list", "devagents/orden-7" }, null);
    defer br.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, br.stdout, "devagents/orden-7") != null);
    // Y la fila NO se insertó: ship falló antes del PR — nada queda fingido.
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
}

// ────────────────────────── guardia anti-prompt ──────────────────────────

test "ship E-124: todo git del flujo sale con GIT_TERMINAL_PROMPT=0 y GCM_INTERACTIVE=never" {
    resetScript(&HAPPY_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGhFull();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    // La guardia va en el camino comun de capture(): TODA llamada git (push
    // incluido) la lleva. Control negativo de E5.02: quitar GIT_GUARD_ENV de
    // capture() pone esta prueba en rojo sin tocar una linea del test.
    try std.testing.expectEqual(script_calls.items.len, script_envs.items.len);
    var saw_push = false;
    for (script_calls.items, script_envs.items) |call, env| {
        if (!std.mem.startsWith(u8, call, "git ")) continue;
        try std.testing.expect(std.mem.indexOf(u8, env, "GIT_TERMINAL_PROMPT=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, env, "GCM_INTERACTIVE=never") != null);
        if (std.mem.indexOf(u8, call, "git push -u origin") != null) saw_push = true;
    }
    try std.testing.expect(saw_push);
}

test "ship E-124: fetch y clone salen por el mismo camino con la guardia" {
    const entries = [_]ScriptEntry{
        .{ .match = "git fetch", .stdout = "" },
        .{ .match = "git clone", .exit = 128, .stderr = "fatal: Authentication failed for 'https://x/y.git'" },
    };
    resetScript(&entries);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var gh = fakeGhFull();
    defer gh.deinit();

    var cap = try gh.capture(&.{ "git", "fetch", "origin" }, null);
    defer cap.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), cap.exit_code);

    // clone falla: error honesto y el stderr real queda en last_error (antes
    // iba por runCmdWin32 y ni se capturaba ni llevaba la guardia).
    try std.testing.expectError(error.GitCloneFailed, gh.cloneRepo("https://x/y.git", "C:/tmp/e124-clone"));
    try std.testing.expect(std.mem.indexOf(u8, gh.last_error.items, "Authentication failed") != null);

    try std.testing.expectEqual(@as(usize, 2), script_envs.items.len);
    for (script_envs.items) |env| {
        try std.testing.expect(std.mem.indexOf(u8, env, "GIT_TERMINAL_PROMPT=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, env, "GCM_INTERACTIVE=never") != null);
    }
}

/// Servidor HTTP minimo que responde 401 a todo — el remote del test de
/// integracion. Git hace GET /o/r.git/info/refs?service=... y recibe el
/// 401 real: sin credencial guardada debe fallar rapido, jamas abrir dialogo.
/// (Este Zig no tiene std.net: los sockets van por el runtime std.Io.)
const Http401Server = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *Http401Server) void {
        const io = self.io;
        while (!self.stop.load(.acquire)) {
            const conn = self.server.accept(io) catch return;
            defer conn.close(io);
            var buf: [2048]u8 = undefined;
            var data = [_][]u8{&buf};
            _ = io.vtable.netRead(io.userdata, conn.socket.handle, &data) catch 0;
            _ = self.hits.fetchAdd(1, .acq_rel);
            const resp = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"e124\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            var parts = [_][]const u8{resp};
            _ = io.vtable.netWrite(io.userdata, conn.socket.handle, "", &parts, 1) catch {};
        }
    }
};

test "ship E-124: push real contra HTTP local 401 falla en segundos con causa en last_error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);

    // Servidor 401 en loopback con puerto efimero — solo vive dentro del test.
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    const port = server.socket.address.getPort();
    const wake_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var srv = Http401Server{ .io = io, .server = &server };
    const th = try std.Thread.spawn(.{}, Http401Server.run, .{&srv});
    defer {
        srv.stop.store(true, .release);
        // accept() esta bloqueado: una conexion extra lo despierta para salir.
        if (wake_addr.connect(io, .{ .mode = .stream })) |s| {
            var sc = s;
            sc.close(io);
        } else |_| {}
        th.join();
        server.deinit(io);
    }

    // Repo real con remote http://127.0.0.1:port (forge gitea por el host):
    // el push pide credencial al recibir 401 y la guardia lo hace fallar ya.
    var cap = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "init", dir }, null) catch return error.SkipZigTest;
    cap.deinit(allocator);
    var c2 = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "config", "user.email", "e124@test" }, null) catch return error.SkipZigTest;
    c2.deinit(allocator);
    var c3 = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "config", "user.name", "e124" }, null) catch return error.SkipZigTest;
    c3.deinit(allocator);
    var c3b = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "config", "commit.gpgsign", "false" }, null) catch return error.SkipZigTest;
    c3b.deinit(allocator);
    var c6 = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "commit", "--allow-empty", "-m", "init" }, null) catch return error.SkipZigTest;
    c6.deinit(allocator);
    const remote_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/acme/widgets.git", .{port});
    defer allocator.free(remote_url);
    var c7 = gh_mod.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "remote", "add", "origin", remote_url }, null) catch return error.SkipZigTest;
    c7.deinit(allocator);

    resetScript(&.{});
    git_real = true;
    defer resetScript(&.{});

    var conn = try testConn();
    defer conn.close();
    var gh = fakeGhFull();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    const t0 = gh_mod.nowMs();
    const res = shipOrder(allocator, conn, &gh, &gitea, 7, "cambio", dir);
    const elapsed_ms = gh_mod.nowMs() - t0;

    if (res) |*r| {
        var rr = r.*;
        rr.deinit(allocator);
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expectEqual(error.GitPushFailed, e);
        // La causa real (auth/401) queda en last_error — no un timeout mudo.
        try std.testing.expect(gh.last_error.items.len > 0);
    }
    // "En segundos": sin la guardia, GCM podria abrir un dialogo y esto se
    // mediria en minutos o se colgaria. 20s es holgado para una maquina lenta.
    try std.testing.expect(elapsed_ms < 20_000);
    // El servidor SI respondio 401 a git — la peticion de red ocurrio de verdad.
    try std.testing.expect(srv.hits.load(.acquire) > 0);
    // Y el push salio con la guardia en el env real del proceso hijo.
    var saw_push = false;
    for (script_calls.items, script_envs.items) |call, env| {
        if (std.mem.indexOf(u8, call, "git push") == null) continue;
        saw_push = true;
        try std.testing.expect(std.mem.indexOf(u8, env, "GIT_TERMINAL_PROMPT=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, env, "GCM_INTERACTIVE=never") != null);
    }
    try std.testing.expect(saw_push);
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
}

test "ship listPrs: filtra por orden y devuelve las filas reales" {
    resetScript(&HAPPY_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);
    try conn.exec("INSERT INTO pull_requests (id, order_id, provider, repo, number, state, url, last_polled_at) VALUES (99, 55, 'github', 'acme/widgets', 5, 'open', 'https://x', 1)");

    const mine = try listPrs(allocator, conn, 7);
    defer {
        for (mine) |*r| r.deinit(allocator);
        allocator.free(mine);
    }
    try std.testing.expectEqual(@as(usize, 1), mine.len);
    try std.testing.expectEqual(@as(i64, 42), mine[0].number);

    const all = try listPrs(allocator, conn, 0);
    defer {
        for (all) |*r| r.deinit(allocator);
        allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
}

// ────────────────────────── T4-GITEA ──────────────────────────

const GITEA_SCRIPT = [_]ScriptEntry{
    .{ .match = "git rev-parse --is-inside-work-tree", .stdout = "true\n" },
    .{ .match = "git remote get-url origin", .stdout = "https://git.4stra.dev/Astra/DevAgents-Beats.git\n" },
    .{ .match = "git symbolic-ref", .stdout = "origin/main\n" },
    .{ .match = "git rev-parse --abbrev-ref HEAD", .stdout = "main\n" },
    .{ .match = "git checkout -b", .stdout = "Switched to a new branch" },
    .{ .match = "git status --porcelain", .stdout = "" },
    .{ .match = "git push -u origin", .stdout = "" },
    // La credencial HTTPS que git ya usa para el push — vale en la API.
    .{ .match = "git credential fill", .stdout = "protocol=https\nhost=git.4stra.dev\nusername=usuario\npassword=t0k-r34l\n" },
};

test "ship gitea: remote no-GitHub crea el PR por REST con datos REALES" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .status = 200, .body = "[]" },
        .{ .match = "/pulls", .status = 201, .body = "{\"number\":42,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/42\",\"state\":\"open\"}" },
    });

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 42), res.number);
    try std.testing.expectEqualStrings("https://git.4stra.dev/Astra/DevAgents-Beats/pulls/42", res.url);
    try std.testing.expectEqual(gh_mod.PullRequestState.open, res.state);
    try std.testing.expect(!res.adopted);
    try std.testing.expect(!res.manual);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));

    const calls = try callsJoined(allocator);
    defer allocator.free(calls);
    // Nada de `gh`: git local + REST. El push va antes del POST /pulls.
    try std.testing.expect(!callsContain(calls, "gh "));
    try std.testing.expect(callsContain(calls, "git credential fill"));
    const i_push = std.mem.indexOf(u8, calls, "git push -u origin devagents/orden-7").?;
    const i_post = std.mem.indexOf(u8, calls, "POST https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls").?;
    try std.testing.expect(i_push < i_post);

    // La fila queda marcada provider='gitea' — el poller la ruteará por REST.
    const stmt = try conn.prepare("SELECT provider FROM pull_requests WHERE id = ?");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, res.pr_id);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("gitea", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
}

test "ship gitea: PR abierto para la rama se ADOPTA por REST" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .status = 200, .body = "[{\"number\":17,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/17\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        // la adopción ahora ENMIENDA: PATCH /pulls/17. R2-2: el
        // GET del título (conservación de marca) va antes del PATCH.
        .{ .match = "/pulls/17", .status = 200, .body = "{\"number\":17,\"state\":\"open\",\"title\":\"DevAgents #17: algo anterior\"}" },
        .{ .match = "/pulls/17", .status = 200, .body = "{}" },
    });

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    try std.testing.expect(res.adopted);
    try std.testing.expect(res.amended);
    try std.testing.expectEqual(@as(i64, 17), res.number);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
    const calls = try callsJoined(allocator);
    defer allocator.free(calls);
    try std.testing.expect(!callsContain(calls, "POST"));
}

test "ship gitea: sin credencial de API degrada a /compare — push real, CERO PR inventado" {
    var entries = GITEA_SCRIPT;
    entries[7].exit = 1;
    entries[7].stdout = "";
    entries[7].stderr = "credential helper: no credentials stored";
    resetScript(&entries);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    // Sin env token ni credential fill → no hay auth: ninguna llamada REST.

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    // El push SÍ ocurrió (la rama está en origin) — lo único pendiente es el PR.
    try std.testing.expect(res.manual);
    try std.testing.expectEqual(@as(i64, 0), res.number);
    try std.testing.expectEqual(@as(i64, 0), res.pr_id);
    try std.testing.expectEqualStrings("https://git.4stra.dev/Astra/DevAgents-Beats/compare/main...devagents/orden-7", res.url);
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
    const calls = try callsJoined(allocator);
    defer allocator.free(calls);
    try std.testing.expect(callsContain(calls, "git push -u origin devagents/orden-7"));
    try std.testing.expect(!callsContain(calls, "GET https") and !callsContain(calls, "POST https"));
}

// doble del administrador de Git sobre captureInput, la misma
// función usada por da_git_store_credential para approve/fill. No invoca Git
// real ni la C-ABI: CoreState y su seam no son públicos fuera de c_api.zig.
const Mcp004CredentialFixture = struct {
    const secret = "synthetic-mcp004-password";
    const host = "mcp004.invalid";
    const approve_input = "protocol=https\nhost=mcp004.invalid\nusername=fixture\npassword=" ++ secret ++ "\n\n";
    const fill_input = "protocol=https\nhost=mcp004.invalid\n\n";
    var stored: bool = false;

    fn capture(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, input: ?[]const u8, env: ?[]const []const u8) !gh_mod.CmdCapture {
        var cap = try fakeCaptureFull(a, argv, cwd, input, env);
        errdefer cap.deinit(a);
        if (argv.len == 3 and std.mem.eql(u8, argv[1], "credential")) {
            try std.testing.expect(input != null);
            if (std.mem.eql(u8, argv[2], "approve")) {
                try std.testing.expectEqualStrings(approve_input, input.?);
                try std.testing.expectEqual(@as(u32, 0), cap.exit_code);
                stored = true;
            } else if (std.mem.eql(u8, argv[2], "fill")) {
                try std.testing.expectEqualStrings(fill_input, input.?);
                if (!stored) {
                    cap.exit_code = 1;
                    @memset(cap.stdout, 0);
                }
            }
        }
        return cap;
    }

    fn rest(a: std.mem.Allocator, method: []const u8, url: []const u8, auth: ?[]const u8, body: ?[]const u8, ctx: ?*anyopaque) !gitea_mod.RestResponse {
        try std.testing.expect(stored);
        const expected = try gitea_mod.basicAuthHeader(a, "fixture", secret);
        defer a.free(expected);
        try std.testing.expect(auth != null);
        try std.testing.expect(std.mem.eql(u8, expected, auth.?));
        return fakeRest(a, method, url, auth, body, ctx);
    }

    fn entries() [GITEA_SCRIPT.len + 1]ScriptEntry {
        var result = GITEA_SCRIPT ++ [_]ScriptEntry{.{ .match = "git credential approve" }};
        result[1].stdout = "https://mcp004.invalid/acme/widget.git\n";
        result[7].stdout = "username=fixture\npassword=" ++ secret ++ "\n";
        return result;
    }

    fn approveAndVerify(gh: *gh_mod.GitHubConnector) !void {
        var approved = try gh.captureInput(&.{ "git", "credential", "approve" }, null, approve_input, gh_mod.GIT_GUARD_ENV);
        defer approved.deinit(gh.allocator);
        try std.testing.expectEqual(@as(u32, 0), approved.exit_code);
        var filled = try gh.captureInput(&.{ "git", "credential", "fill" }, null, fill_input, gh_mod.GIT_GUARD_ENV);
        defer filled.deinit(gh.allocator);
        defer @memset(filled.stdout, 0);
        try std.testing.expectEqual(@as(u32, 0), filled.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, filled.stdout, "password=" ++ secret ++ "\n") != null);
    }

    fn noSecret(gh: *gh_mod.GitHubConnector, gitea: *gitea_mod.GiteaConnector, output: anytype) !void {
        const calls = try callsJoined(std.testing.allocator);
        defer std.testing.allocator.free(calls);
        const json = try std.json.Stringify.valueAlloc(std.testing.allocator, output, .{});
        defer std.testing.allocator.free(json);
        const encoded = try gitea_mod.basicAuthHeader(std.testing.allocator, "fixture", secret);
        defer std.testing.allocator.free(encoded);
        for ([_][]const u8{ calls, gh.last_error.items, gitea.last_error.items, json }) |text| {
            try std.testing.expect(std.mem.indexOf(u8, text, secret) == null);
            try std.testing.expect(std.mem.indexOf(u8, text, encoded["Basic ".len..]) == null);
        }
        for (script_envs.items) |env| {
            try std.testing.expect(std.mem.indexOf(u8, env, secret) == null);
            try std.testing.expect(std.mem.indexOf(u8, env, "GIT_TERMINAL_PROMPT=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, env, "GCM_INTERACTIVE=never") != null);
        }
    }
};

test "CK-MCP-004 ship push sin API entrega compare; approve fill y reintento crean y adoptan PR sin secreto" {
    inline for (.{ false, true }) |rest_enabled| {
        const a = std.testing.allocator;
        const entries = Mcp004CredentialFixture.entries();
        resetScript(&entries);
        defer resetScript(&.{});
        Mcp004CredentialFixture.stored = false;
        defer Mcp004CredentialFixture.stored = false;
        var conn = try testConn();
        defer conn.close();
        var gh = fakeGhFull();
        defer gh.deinit();
        gh.capture_full_fn = Mcp004CredentialFixture.capture;
        gh.rest_enabled = rest_enabled;
        var gitea = fakeGitea();
        defer gitea.deinit();
        gitea.http_fn = Mcp004CredentialFixture.rest;

        var manual = try ship_flow_ship(a, conn, &gh, &gitea);
        defer manual.deinit(a);
        try std.testing.expect(manual.manual);
        try std.testing.expectEqual(@as(i64, 0), manual.pr_id);
        try std.testing.expectEqual(@as(i64, 0), manual.number);
        try std.testing.expectEqualStrings(if (rest_enabled) "https://mcp004.invalid/acme/widget/compare" else "https://mcp004.invalid/acme/widget/compare/main...devagents/orden-7", manual.url);
        try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
        const before = try callsJoined(a);
        defer a.free(before);
        try std.testing.expect(callsContain(before, "git push -u origin devagents/orden-7"));
        try std.testing.expect(!callsContain(before, "git credential approve"));
        try std.testing.expect(!callsContain(before, "GET https") and !callsContain(before, "POST https"));
        try Mcp004CredentialFixture.noSecret(&gh, &gitea, manual);

        try Mcp004CredentialFixture.approveAndVerify(&gh);
        const object = "{\"number\":42,\"html_url\":\"https://mcp004.invalid/acme/widget/pulls/42\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}";
        scriptRest(&.{
            .{ .match = "/pulls?state=open", .body = "[]" },
            .{ .match = "/pulls", .status = 201, .body = object },
        });
        var created = try ship_flow_ship(a, conn, &gh, &gitea);
        defer created.deinit(a);
        try std.testing.expect(!created.manual and !created.adopted);
        try std.testing.expectEqual(@as(i64, 42), created.number);
        try std.testing.expectEqualStrings("https://mcp004.invalid/acme/widget/pulls/42", created.url);
        try std.testing.expectEqual(@as(usize, 0), rest_queue.items.len);
        try Mcp004CredentialFixture.noSecret(&gh, &gitea, created);

        clearCalls();
        // el re-ship adopta Y enmienda por PATCH (título/cuerpo de
        // esta orden), así que el guion lleva también la respuesta del PATCH;
        // R2-2: la conservación de marca necesita el GET del título antes.
        scriptRest(&.{
            .{ .match = "/pulls?state=open", .body = "[" ++ object ++ "]" },
            .{ .match = "/pulls/42", .body = "{\"number\":42,\"state\":\"open\",\"title\":\"DevAgents #7: Implementa el login\"}" },
            .{ .match = "/pulls/42", .body = "{}" },
        });
        var adopted = try ship_flow_ship(a, conn, &gh, &gitea);
        defer adopted.deinit(a);
        try std.testing.expect(adopted.adopted and !adopted.manual);
        try std.testing.expectEqual(created.pr_id, adopted.pr_id);
        try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
        try std.testing.expectEqual(@as(usize, 0), rest_queue.items.len);
        const after = try callsJoined(a);
        defer a.free(after);
        try std.testing.expect(!callsContain(after, "POST "));
        try Mcp004CredentialFixture.noSecret(&gh, &gitea, adopted);
    }
}

test "CK-MCP-004 host invalido rechazado antes de credencial o REST" {
    resetScript(&.{});
    defer resetScript(&.{});
    var gh = fakeGhFull();
    defer gh.deinit();
    for ([_][]const u8{ "", "bad host", "forge.invalid/path", "forge.invalid\npassword=injected", "https://forge.invalid" }) |host| {
        try std.testing.expectError(error.BadRemoteUrl, resolveGiteaAuth(&gh, std.testing.allocator, host));
    }
    try std.testing.expectEqual(@as(usize, 0), script_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), rest_queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), gh.last_error.items.len);
}

test "CK-MCP-004 API rechaza credencial renovada sin secreto en errores ni fila PR" {
    inline for (.{ false, true }) |rest_enabled| {
        const entries = Mcp004CredentialFixture.entries();
        resetScript(&entries);
        defer resetScript(&.{});
        Mcp004CredentialFixture.stored = false;
        defer Mcp004CredentialFixture.stored = false;
        var conn = try testConn();
        defer conn.close();
        var gh = fakeGhFull();
        defer gh.deinit();
        gh.capture_full_fn = Mcp004CredentialFixture.capture;
        gh.rest_enabled = rest_enabled;
        var gitea = fakeGitea();
        defer gitea.deinit();
        gitea.http_fn = Mcp004CredentialFixture.rest;
        try Mcp004CredentialFixture.approveAndVerify(&gh);
        scriptRest(&.{.{ .match = "/pulls?state=open", .status = 401, .body = "{\"token\":\"" ++ Mcp004CredentialFixture.secret ++ "\"}" }});
        const expected_error = if (rest_enabled) error.ForgeUnauthorized else error.GiteaFailed;
        try std.testing.expectError(expected_error, ship_flow_ship(std.testing.allocator, conn, &gh, &gitea));
        try std.testing.expect(std.mem.indexOf(u8, gitea.last_error.items, "401") != null);
        try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
        try std.testing.expectEqual(@as(usize, 0), rest_queue.items.len);
        try Mcp004CredentialFixture.noSecret(&gh, &gitea, @errorName(expected_error));
    }
}

test "ship gitea: API caída en create — error honesto con cuerpo real, sin fila" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .status = 200, .body = "[]" },
        .{ .match = "/pulls", .status = 422, .body = "{\"message\":\"base branch does not exist\"}" },
    });

    try std.testing.expectError(error.GiteaCreateFailed, ship_flow_ship(allocator, conn, &gh, &gitea));
    try std.testing.expect(std.mem.indexOf(u8, gitea.last_error.items, "base branch") != null);
    resetScript(&GITEA_SCRIPT);
    scriptRest(&.{.{ .match = "/pulls?state=open", .status = 422, .body = "{\"secret\":\"fx-s7\"}" }});
    try std.testing.expectError(error.GiteaFailed, ship_flow_ship(allocator, conn, &gh, &gitea));
    try std.testing.expect(std.mem.indexOf(u8, gitea.last_error.items, "fx-s7") == null);
    try std.testing.expect(std.mem.indexOf(u8, gitea.last_error.items, "422") != null);
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
}

test "ship gitea merge: fila provider=gitea va por REST, no por gh" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .status = 200, .body = "[]" },
        .{ .match = "/pulls", .status = 201, .body = "{\"number\":42,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/42\",\"state\":\"open\"}" },
    });

    var res = try ship_flow_ship(allocator, conn, &gh, &gitea);
    defer res.deinit(allocator);

    scriptRest(&.{
        .{ .match = "/merge", .status = 200, .body = "{}" },
        .{ .match = "/pulls/42", .status = 200, .body = "{\"state\":\"closed\",\"merged\":true}" },
    });
    clearCalls();
    const st = try mergePr(conn, &gh, &gitea, res.pr_id);
    try std.testing.expectEqual(gh_mod.PullRequestState.merged, st);
    const calls = try callsJoined(allocator);
    defer allocator.free(calls);
    try std.testing.expect(!callsContain(calls, "gh "));
    try std.testing.expect(callsContain(calls, "POST https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls/42/merge"));

    const stmt = try conn.prepare("SELECT state FROM pull_requests WHERE id = ?");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, res.pr_id);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("merged", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
}

// ────────────────────────── ──────────────────────────
// PR en borrador (draft), enmendado (re-ship hace PATCH conservando número) e
// informe de apilados. Draft: GitHub lo exige en el CUERPO del POST /pulls
// (docs.github.com "Create a pull request" — body parameter draft); Gitea no
// acepta draft en la API de crear PR: su marca es el prefijo de título "WIP: "
// (pull_service.wipPrefixes), igual que GitLab marca con prefijos de título.
// PATCH de PR ya abierto en GitHub NO acepta "draft" (docs "Update a pull
// request": solo title/body/state/base/maintainer_can_modify) — pedir draft
// sobre un PR abierto no-borrador se reporta en ShipResult.draft_missing/note.

fn ckComp022ScriptGithub() [8]ScriptEntry {
    var entries = GITEA_SCRIPT;
    entries[1].stdout = "https://github.com/acme/widgets.git\n";
    return entries;
}

test "CK-COMP-022: GitHub REST crea el PR BORRADOR con draft:true en el cuerpo del POST" {
    var entries = ckComp022ScriptGithub();
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[]" },
        .{ .match = "/pulls", .status = 201, .body = "{\"number\":42,\"html_url\":\"https://github.com/acme/widgets/pull/42\",\"state\":\"open\",\"draft\":true}" },
    });

    var res = try shipOrderWithOptions(a, conn, &gh, &transport, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    try std.testing.expectEqual(@as(i64, 42), res.number);
    try std.testing.expect(res.draft);
    try std.testing.expect(!res.adopted);
    try std.testing.expect(!res.draft_missing);
    const calls = try callsJoined(a);
    defer a.free(calls);
    // draft va en el CUERPO del POST de creación (campo nativo de GitHub).
    try std.testing.expect(callsContain(calls, "POST https://api.github.com/repos/acme/widgets/pulls"));
    try std.testing.expect(callsContain(calls, "\"draft\":true"));
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
}

test "CK-COMP-022: Gitea REST crea borrador con prefijo WIP: en el título (sin campo draft)" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[]" },
        .{ .match = "/pulls", .status = 201, .body = "{\"number\":42,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/42\",\"state\":\"open\"}" },
    });

    var res = try shipOrderWithOptions(a, conn, &gh, &transport, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    // Diferencia documentada: Gitea NO acepta "draft" en POST /pulls — la forja
    // marca borrador por el prefijo de título WIP: que ship añade.
    try std.testing.expectEqual(@as(i64, 42), res.number);
    try std.testing.expect(res.draft);
    const calls = try callsJoined(a);
    defer a.free(calls);
    try std.testing.expect(callsContain(calls, "POST https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls"));
    try std.testing.expect(callsContain(calls, "\"title\":\"WIP: DevAgents #7"));
    try std.testing.expect(!callsContain(calls, "\"draft\":"));
}

test "CK-COMP-022: sin draft el cuerpo del POST de GitHub es el de HOY (sin campo draft)" {
    var entries = ckComp022ScriptGithub();
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[]" },
        .{ .match = "/pulls", .status = 201, .body = "{\"number\":42,\"html_url\":\"https://github.com/acme/widgets/pull/42\",\"state\":\"open\"}" },
    });

    var res = try ship_flow_ship(a, conn, &gh, &transport);
    defer res.deinit(a);

    try std.testing.expectEqual(@as(i64, 42), res.number);
    try std.testing.expect(!res.draft);
    const calls = try callsJoined(a);
    defer a.free(calls);
    try std.testing.expect(callsContain(calls, "POST https://api.github.com/repos/acme/widgets/pulls"));
    // Mismas claves title/body/head/base, NINGÚN campo draft añadido.
    try std.testing.expect(callsContain(calls, "\"title\":\"DevAgents #7: Implementa el login\""));
    try std.testing.expect(callsContain(calls, "\"head\":\"devagents/orden-7\""));
    try std.testing.expect(callsContain(calls, "\"base\":\"main\""));
    try std.testing.expect(!callsContain(calls, "\"draft\""));
}

test "CK-COMP-022: re-ship con PR abierto hace PATCH con el número EXISTENTE y no crea otro POST" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        // R2-2: el GET del título del PR abierto (para conservar la marca de
        // borrador si la lleva) va ANTES del PATCH del PATCH mismo.
        .{ .match = "/pulls/17", .body = "{\"number\":17,\"state\":\"open\",\"title\":\"DevAgents #17: algo anterior\"}" },
        .{ .match = "/pulls/17", .body = "{}" },
    });

    var res = try ship_flow_ship(a, conn, &gh, &transport);
    defer res.deinit(a);

    try std.testing.expect(res.adopted);
    try std.testing.expect(res.amended);
    try std.testing.expectEqual(@as(i64, 17), res.number);
    try std.testing.expect(!res.draft_missing);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
    const calls = try callsJoined(a);
    defer a.free(calls);
    // PATCH del número existente con título y cuerpo de ESTA orden; cero POST.
    try std.testing.expect(callsContain(calls, "PATCH https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls/17"));
    try std.testing.expect(callsContain(calls, "\"title\":\"DevAgents #7: Implementa el login\""));
    try std.testing.expect(callsContain(calls, "Creado por DevAgents (orden #7)."));
    try std.testing.expect(!callsContain(calls, "POST "));
}

test "CK-COMP-022: Gitea re-ship enmendado con draft:true ya lleva prefijo WIP: y NO draft_missing" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .body = "{}" },
    });

    var res = try shipOrderWithOptions(a, conn, &gh, &transport, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    // El PATCH lleva el título con prefijo: Gitea convierte el PR a borrador.
    try std.testing.expect(res.amended);
    try std.testing.expect(!res.draft_missing);
    const calls = try callsJoined(a);
    defer a.free(calls);
    try std.testing.expect(callsContain(calls, "\"title\":\"WIP: DevAgents #7: Implementa el login\""));
}

test "CK-COMP-022: GitHub re-ship sobre PR abierto NO borrador — draft pedido se REPORTA" {
    var entries = ckComp022ScriptGithub();
    entries[1].stdout = "https://github.com/acme/widgets.git\n";
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .body = "{\"number\":17,\"state\":\"open\",\"draft\":false}" },
        .{ .match = "/pulls/17", .body = "{}" },
    });

    var res = try shipOrderWithOptions(a, conn, &gh, &transport, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    try std.testing.expect(res.adopted);
    try std.testing.expect(res.amended);
    try std.testing.expectEqual(@as(i64, 17), res.number);
    try std.testing.expect(res.draft_missing);
    try std.testing.expect(res.note != null);
    try std.testing.expect(std.mem.indexOf(u8, res.note.?, "no-borrador") != null);
    const calls = try callsJoined(a);
    defer a.free(calls);
    try std.testing.expect(callsContain(calls, "PATCH https://"));
    try std.testing.expect(!callsContain(calls, "POST "));
}

test "CK-COMP-022: GitHub re-ship sobre PR abierto YA borrador — nada que reportar" {
    var entries = ckComp022ScriptGithub();
    entries[1].stdout = "https://github.com/acme/widgets.git\n";
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .body = "{\"number\":17,\"state\":\"open\",\"draft\":true}" },
        .{ .match = "/pulls/17", .body = "{}" },
    });

    var res = try shipOrderWithOptions(a, conn, &gh, &transport, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    try std.testing.expect(res.adopted);
    try std.testing.expect(res.amended);
    try std.testing.expect(!res.draft_missing);
}

test "CK-COMP-022: gh adopta PR abierto y lo ENMIENDA via gh pr edit (titular sin prefijo WIP)" {
    var entries = HAPPY_SCRIPT;
    entries[9].stdout = "[{\"number\":17,\"url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"OPEN\"}]";
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try ship_flow_ship(a, conn, &gh, &gitea);
    defer res.deinit(a);

    try std.testing.expect(res.adopted);
    try std.testing.expect(res.amended);
    try std.testing.expectEqual(@as(i64, 17), res.number);
    try std.testing.expect(!res.draft_missing);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
    const calls = try callsJoined(a);
    defer a.free(calls);
    try std.testing.expect(!callsContain(calls, "gh pr create"));
    try std.testing.expect(callsContain(calls, "gh pr edit 17 --repo acme/widgets --title DevAgents #7: Implementa el login --body Implementa el login"));
}

test "CK-COMP-022: gh re-ship con draft pedido sobre PR NO borrador lo dice en el resultado" {
    var entries = HAPPY_SCRIPT;
    entries[9].stdout = "[{\"number\":17,\"url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"OPEN\"}]";
    // El `gh pr view isDraft` de la detección de borrador responde aquí.
    entries[11].stdout = "{\"isDraft\":false}";
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try shipOrderWithOptions(a, conn, &gh, &gitea, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    try std.testing.expect(res.adopted);
    try std.testing.expect(res.amended);
    try std.testing.expect(res.draft_missing);
    try std.testing.expect(res.note != null);
}

// R2-5: 'gh pr view' fallido no puede tumba la orden cuando la enmienda YA se
// aplicó: el estado de borrador queda DESCONOCIDO y se reporta con constancia
// (draft_missing + note), como el resto de señales a medias.
test "CK-COMP-022: gh pr view fallido durante la enmienda NO tumba la orden" {
    var entries = HAPPY_SCRIPT;
    entries[9].stdout = "[{\"number\":17,\"url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"OPEN\"}]";
    entries[11].exit = 1;
    entries[11].stderr = "gh: view sin red";
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try shipOrderWithOptions(a, conn, &gh, &gitea, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    try std.testing.expect(res.amended);
    try std.testing.expect(res.draft_missing);
    try std.testing.expect(res.note != null);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
}

test "CK-COMP-022: gh re-ship con draft pedido sobre PR YA borrador — reporte limpio" {
    var entries = HAPPY_SCRIPT;
    entries[9].stdout = "[{\"number\":17,\"url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"OPEN\"}]";
    entries[11].stdout = "{\"isDraft\":true}";
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    var res = try shipOrderWithOptions(a, conn, &gh, &gitea, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    try std.testing.expect(!res.draft_missing);
}

// R2-4: los prefijos de borrador están ACOTADOS: un título normal como
// "Draftsman…" o "WIP values…" NO es un PR en borrador (falso positivo hoy).
test "CK-COMP-022: prefijos de borrador sin falso positivo con titulos normales" {
    try std.testing.expect(draftPrefixOf("Draftsman: bosquejo de la UI") == null);
    try std.testing.expect(draftPrefixOf("WIP values en la tabla") == null);
    try std.testing.expect(draftPrefixOf("Draft printer de tickets") == null);
    // Los prefijos reales de la marca SÍ se detectan.
    try std.testing.expect(draftPrefixOf("WIP: la marca") != null);
    try std.testing.expect(draftPrefixOf("[WIP] la marca") != null);
    try std.testing.expect(draftPrefixOf("Draft: la marca") != null);
    try std.testing.expect(draftPrefixOf("[Draft] la marca") != null);
}

test "CK-COMP-022: gh create con draft pedido falla honesto (cableado pendiente de --draft en github.zig)" {
    resetScript(&HAPPY_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    try std.testing.expectError(error.GhDraftUnsupported, shipOrderWithOptions(a, conn, &gh, &gitea, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true }));
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
    try std.testing.expect(std.mem.indexOf(u8, gh.last_error.items, "cableado pendiente") != null);
}

// R2-1: las rutas de error de la enmienda no pueden fugar la URL del PR
// adoptado ni el resultado a medio armar. std.testing.allocator denuncia la
// fuga al cierre de cada test — ROJO con el código de hoy.
test "CK-COMP-022: GitHub REST con PATCH fallido (500) no fuga la URL del PR adoptado" {
    var entries = ckComp022ScriptGithub();
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .status = 500, .body = "{\"message\":\"fuga en ruta de error\"}" },
    });

    try std.testing.expectError(error.ForgePatchFailed, ship_flow_ship(a, conn, &gh, &transport));
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
}

test "CK-COMP-022: gh con pr edit fallido no fuga la URL del PR adoptado" {
    var entries = HAPPY_SCRIPT;
    entries[9].stdout = "[{\"number\":17,\"url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"OPEN\"}]";
    entries[12].exit = 1;
    entries[12].stderr = "gh: edit denegado";
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();

    try std.testing.expectError(error.GhEditFailed, ship_flow_ship(a, conn, &gh, &gitea));
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
}

test "CK-COMP-022: Gitea directo con PATCH fallido (500) no fuga la URL del PR adoptado" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .status = 500, .body = "{\"message\":\"fuga en ruta de error\"}" },
    });

    try std.testing.expectError(error.GiteaPatchFailed, ship_flow_ship(a, conn, &gh, &gitea));
    try std.testing.expectEqual(@as(i64, 0), try countPrRows(conn));
}

// R2-6: el conector Gitea DIRECTO con draft — método y cuerpo del POST.
test "CK-COMP-022: conector Gitea directo crea borrador por POST con prefijo WIP: en el título" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[]" },
        .{ .match = "/pulls", .status = 201, .body = "{\"number\":42,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/42\",\"state\":\"open\"}" },
    });

    var res = try shipOrderWithOptions(a, conn, &gh, &gitea, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    try std.testing.expectEqual(@as(i64, 42), res.number);
    try std.testing.expect(res.draft);
    try std.testing.expect(!res.adopted);
    const calls = try callsJoined(a);
    defer a.free(calls);
    try std.testing.expect(callsContain(calls, "POST https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls"));
    try std.testing.expect(callsContain(calls, "{\"title\":\"WIP: DevAgents #7: Implementa el login\""));
    try std.testing.expect(!callsContain(calls, "\"draft\":"));
}

// R2-6: GitHub REST SIN campo draft en su GET — desconocido para la forja,
// el ship lo reporta (draft_missing + note) y la enmienda igualmente se
// aplica conservando el número.
test "CK-COMP-022: GitHub REST sin campo draft en el GET reporta el remate a medias" {
    var entries = ckComp022ScriptGithub();
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://github.com/acme/widgets/pull/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .body = "{\"number\":17,\"state\":\"open\",\"id\":17}" },
        .{ .match = "/pulls/17", .body = "{}" },
    });

    var res = try shipOrderWithOptions(a, conn, &gh, &transport, 7, "Implementa el login", "C:/tmp/wt-fake", .{ .draft = true });
    defer res.deinit(a);

    try std.testing.expect(res.adopted);
    try std.testing.expect(res.amended);
    try std.testing.expect(res.draft_missing);
    try std.testing.expect(res.note != null);
    try std.testing.expectEqual(@as(i64, 17), res.number);
}

// R2-2: re-ship SIN draft sobre un PR que YA es borrador (prefijo WIP:/Draft:)
// no puede quitar la marca en silencio; GET del título ANTES del PATCH.
test "CK-COMP-022: Gitea re-ship SIN draft conserva el prefijo WIP: del PR abierto" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .body = "{\"number\":17,\"state\":\"open\",\"title\":\"WIP: DevAgents #17: algo anterior\"}" },
        .{ .match = "/pulls/17", .body = "{}" },
    });

    var res = try ship_flow_ship(a, conn, &gh, &transport);
    defer res.deinit(a);

    try std.testing.expect(res.amended);
    try std.testing.expect(!res.draft_missing);
    const calls = try callsJoined(a);
    defer a.free(calls);
    const i_get = std.mem.indexOf(u8, calls, "GET https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls/17");
    const i_patch = std.mem.indexOf(u8, calls, "PATCH https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls/17 |");
    try std.testing.expect(i_get != null);
    try std.testing.expect(i_patch != null);
    try std.testing.expect(i_get.? < i_patch.?);
    try std.testing.expect(callsContain(calls, "{\"title\":\"WIP: DevAgents #7: Implementa el login\""));
}

test "CK-COMP-022: Gitea directo re-ship SIN draft conserva el prefijo WIP: del PR abierto" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .body = "{\"number\":17,\"state\":\"open\",\"title\":\"WIP: DevAgents #17: algo anterior\"}" },
        .{ .match = "/pulls/17", .body = "{}" },
    });

    var res = try ship_flow_ship(a, conn, &gh, &gitea);
    defer res.deinit(a);

    try std.testing.expect(res.amended);
    try std.testing.expect(!res.draft_missing);
    const calls = try callsJoined(a);
    defer a.free(calls);
    const i_get = std.mem.indexOf(u8, calls, "GET https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls/17");
    const i_patch = std.mem.indexOf(u8, calls, "PATCH https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls/17 |");
    try std.testing.expect(i_get != null);
    try std.testing.expect(i_patch != null);
    try std.testing.expect(i_get.? < i_patch.?);
    try std.testing.expect(callsContain(calls, "{\"title\":\"WIP: DevAgents #7: Implementa el login\""));
}

test "CK-COMP-022: GitLab re-ship SIN draft conserva Draft: y el PUT lleva description" {
    var entries = GITEA_SCRIPT;
    entries[1].stdout = "https://gitlab.com/acme/widgets.git\n";
    resetScript(&entries);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/merge_requests?state=opened", .body = "[{\"iid\":42,\"web_url\":\"https://gitlab.com/acme/widgets/-/merge_requests/42\",\"state\":\"opened\",\"source_branch\":\"devagents/orden-7\"}]" },
        .{ .match = "/merge_requests/42", .body = "{\"iid\":42,\"state\":\"opened\",\"title\":\"Draft: DevAgents #42: algo anterior\"}" },
        .{ .match = "/merge_requests/42", .body = "{}" },
    });

    var res = try ship_flow_ship(a, conn, &gh, &transport);
    defer res.deinit(a);

    try std.testing.expect(res.amended);
    try std.testing.expect(!res.draft_missing);
    const calls = try callsJoined(a);
    defer a.free(calls);
    try std.testing.expect(callsContain(calls, "PUT https://gitlab.com/api/v4/projects/acme%2Fwidgets/merge_requests/42"));
    try std.testing.expect(callsContain(calls, "\"description\":\""));
    try std.testing.expect(callsContain(calls, "{\"title\":\"Draft: DevAgents #7: Implementa el login\""));
}

// R2-3: Gitea puede responder 201 al PATCH de /pulls/{n} — la enmienda solo
// depende de que el cambio SE aplicó, no del código exacto de la forja.
test "CK-COMP-022: Gitea REST acepta 201 en el PATCH de la enmienda" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    gh.rest_enabled = true;
    var transport = fakeGitea();
    defer transport.deinit();
    transport.auth_header = try a.dupe(u8, "Bearer synthetic");
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .body = "{\"number\":17,\"state\":\"open\",\"title\":\"DevAgents #17: algo anterior\"}" },
        .{ .match = "/pulls/17", .status = 201, .body = "{}" },
    });

    var res = try ship_flow_ship(a, conn, &gh, &transport);
    defer res.deinit(a);

    try std.testing.expect(res.amended);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
}

test "CK-COMP-022: Gitea directo acepta 201 en el PATCH de la enmienda" {
    resetScript(&GITEA_SCRIPT);
    defer resetScript(&.{});
    const a = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var gh = fakeGh();
    defer gh.deinit();
    var gitea = fakeGitea();
    defer gitea.deinit();
    scriptRest(&.{
        .{ .match = "/pulls?state=open", .body = "[{\"number\":17,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/17\",\"state\":\"open\",\"head\":{\"ref\":\"devagents/orden-7\"}}]" },
        .{ .match = "/pulls/17", .body = "{\"number\":17,\"state\":\"open\",\"title\":\"DevAgents #17: algo anterior\"}" },
        .{ .match = "/pulls/17", .status = 201, .body = "{}" },
    });

    var res = try ship_flow_ship(a, conn, &gh, &gitea);
    defer res.deinit(a);

    try std.testing.expect(res.amended);
    try std.testing.expectEqual(@as(i64, 1), try countPrRows(conn));
}
