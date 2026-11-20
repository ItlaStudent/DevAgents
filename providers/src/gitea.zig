//! providers/src/gitea.zig — Conector Gitea: PRs por API REST, sin `gh`.
//!
//! El remoto del proyecto es Gitea (git.4stra.dev — /api/graphql responde 405,
//! no es GitHub) y `gh` no tiene credenciales ahí. Este conector implementa el
//! mismo contrato de verdad que github.zig pero sobre `POST/GET
//! /api/v1/repos/{owner}/{repo}/pulls`: número, URL y estado salen SIEMPRE del
//! JSON que devuelve la API — nunca se fabrican.
//!
//! Autenticación (la resuelve ship_flow): `Authorization: token <api_token>`
//! o `Authorization: Basic <base64(user:pass)>` — la segunda es la credencial
//! que git ya usa para el push (credential manager), válida en la API de Gitea.
//!
//! Costuras de test: `http_fn` guiona la capa REST como `capture_fn` guiona los
//! subprocesos en github.zig — producción usa http_client real.

const std = @import("std");
const http_client = @import("http/client.zig");
const gh_mod = @import("github.zig");

const http = std.http;
const external_error = @import("external_error.zig");

const GetEnvironmentVariableA = @import("platform.zig").env;

pub const Forge = gh_mod.Forge;

/// La forge se detecta por el HOST del remote — nada de sondeos ni suposiciones:
/// GitHub y GitLab públicos se reconocen directamente. Los hosts propios se
/// resuelven con detectForgeConfigured; el resto conserva el contrato Gitea.
pub fn detectForge(host: []const u8) Forge {
    if (std.ascii.eqlIgnoreCase(host, "github.com")) return .github;
    if (std.ascii.eqlIgnoreCase(host, "www.github.com")) return .github;
    if (std.ascii.eqlIgnoreCase(host, "gitlab.com")) return .gitlab;
    return .gitea;
}

pub fn parseRemoteUrlConfigured(allocator: std.mem.Allocator, url: []const u8, hosts: []const gh_mod.HostForgeConfig) !RemoteUrl {
    var remote = try parseRemoteUrl(allocator, url);
    remote.forge = detectForgeConfigured(remote.host, hosts);
    return remote;
}

pub fn detectForgeConfigured(host: []const u8, hosts: []const gh_mod.HostForgeConfig) Forge {
    for (hosts) |configured| {
        if (std.ascii.eqlIgnoreCase(host, configured.host)) return configured.forge;
    }
    return detectForge(host);
}

/// Resultado de parsear `git remote get-url origin`: host, owner/repo y la base
/// web para construir URLs de API y de /compare. Nada se inventa — si la URL no
/// se entiende, el parse falla y ship se detiene honesto.
pub const RemoteUrl = struct {
    host: []u8,
    owner: []u8,
    repo: []u8,
    /// "owner/repo" — la forma que la API espera en la ruta.
    slug: []u8,
    /// "https://host" — raíz web para /api/v1 y /compare.
    web_base: []u8,
    forge: Forge,

    pub fn deinit(self: *RemoteUrl, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.owner);
        allocator.free(self.repo);
        allocator.free(self.slug);
        allocator.free(self.web_base);
    }
};

/// Parsea las formas reales de un remote git:
///   https://host/owner/repo[.git][/]   http://host/owner/repo
///   git@host:owner/repo[.git]          ssh://git@host[:port]/owner/repo
/// Cualquier otra cosa (local, file://, sin owner/repo) es error — mejor que
/// adivinar un slug que no existe.
pub fn parseRemoteUrl(allocator: std.mem.Allocator, url: []const u8) !RemoteUrl {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len == 0) return error.BadRemoteUrl;

    var host_part: []const u8 = "";
    var path_part: []const u8 = "";
    var scheme_https = true;

    if (std.mem.indexOf(u8, trimmed, "://")) |i| {
        const scheme = trimmed[0..i];
        scheme_https = !std.ascii.eqlIgnoreCase(scheme, "http");
        if (!std.ascii.eqlIgnoreCase(scheme, "https") and
            !std.ascii.eqlIgnoreCase(scheme, "http") and
            !std.ascii.eqlIgnoreCase(scheme, "ssh") and
            !std.ascii.eqlIgnoreCase(scheme, "git")) return error.BadRemoteUrl;
        const rest = trimmed[i + 3 ..];
        // ssh://[user@]host[:port]/owner/repo — quitar user@ y :port.
        var authority = rest;
        if (std.mem.indexOfScalar(u8, authority, '/')) |s| {
            path_part = authority[s + 1 ..];
            authority = authority[0..s];
        } else return error.BadRemoteUrl;
        if (std.mem.indexOfScalar(u8, authority, '@')) |at| {
            if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) return error.BadRemoteUrl;
            authority = authority[at + 1 ..];
        }
        if (std.ascii.eqlIgnoreCase(scheme, "ssh") or std.ascii.eqlIgnoreCase(scheme, "git")) {
            if (std.mem.indexOfScalar(u8, authority, ':')) |c| authority = authority[0..c];
        }
        host_part = authority;
    } else if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
        // Forma scp: git@host:owner/repo — exige '@' antes de ':' para no
        // confundirse con rutas "C:\" locales.
        const before = trimmed[0..colon];
        const at = std.mem.indexOfScalar(u8, before, '@') orelse return error.BadRemoteUrl;
        host_part = before[at + 1 ..];
        path_part = trimmed[colon + 1 ..];
    } else return error.BadRemoteUrl;

    var path = path_part;
    if (std.mem.endsWith(u8, path, "/")) path = path[0 .. path.len - 1];
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.BadRemoteUrl;
    const owner = path[0..slash];
    const repo = path[slash + 1 ..];
    if (host_part.len == 0 or owner.len == 0 or repo.len == 0) return error.BadRemoteUrl;
    for (host_part) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != ':') return error.BadRemoteUrl;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.BadRemoteUrl;
        for (segment) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return error.BadRemoteUrl;
    }

    const host = try allocator.dupe(u8, host_part);
    errdefer allocator.free(host);
    const owner_d = try allocator.dupe(u8, owner);
    errdefer allocator.free(owner_d);
    const repo_d = try allocator.dupe(u8, repo);
    errdefer allocator.free(repo_d);
    const slug = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, repo });
    errdefer allocator.free(slug);
    const web_base = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ if (scheme_https) "https" else "http", host_part });
    errdefer allocator.free(web_base);

    return .{
        .host = host,
        .owner = owner_d,
        .repo = repo_d,
        .slug = slug,
        .web_base = web_base,
        .forge = detectForge(host_part),
    };
}

/// Respuesta REST cruda: status + cuerpo. El cuerpo es del llamador.
pub const RestResponse = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *RestResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

/// Firma del canal REST inyectable. Producción: null → http_client real.
/// `auth` es el header Authorization YA construido ("token X" | "Basic Y").
pub const RestFn = *const fn (
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    auth: ?[]const u8,
    body: ?[]const u8,
    ctx: ?*anyopaque,
) anyerror!RestResponse;

/// "Basic base64(user:pass)" — la forma que acepta la API de Gitea con la
/// credencial HTTPS que git ya tiene guardada para el push.
pub fn basicAuthHeader(allocator: std.mem.Allocator, user: []const u8, pass: []const u8) ![]u8 {
    const pair = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, pass });
    defer allocator.free(pair);
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, "Basic ".len + enc.calcSize(pair.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = enc.encode(out["Basic ".len..], pair);
    return out;
}

/// "token <t>" — API token de Gitea (env DEVAGENTS_GITEA_TOKEN / GITEA_TOKEN).
pub fn tokenAuthHeader(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len == 0 or std.mem.indexOfAny(u8, token, "\r\n") != null) return error.InvalidCredential;
    return std.fmt.allocPrint(allocator, "token {s}", .{token});
}

/// Lee una variable de entorno acotada; null si no existe o está vacía.
pub fn envVar(allocator: std.mem.Allocator, name: [*:0]const u8) !?[]u8 {
    var buf: [4096:0]u8 = undefined;
    const n = GetEnvironmentVariableA(name, &buf, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return null;
    const v = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (v.len == 0) return null;
    return try allocator.dupe(u8, v);
}

pub const GiteaConnector = struct {
    allocator: std.mem.Allocator,
    /// Cliente real (producción). Si es null y tampoco hay http_fn, rest()
    /// crea uno propio perezoso — el connector sigue siendo barato de armar.
    http: ?*http_client.HttpClient = null,
    own_http: ?http_client.HttpClient = null,
    /// Costura de tests: guiona las respuestas REST sin red.
    http_fn: ?RestFn = null,
    http_ctx: ?*anyopaque = null,
    /// Header Authorization resuelto por el llamador (env/credential fill).
    /// null = sin credencial — las llamadas que la exijan fallarán honesto.
    auth_header: ?[]const u8 = null,
    /// Último diagnóstico (status + extracto externo saneado, hasta 200 bytes). Solo error.
    last_error: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) GiteaConnector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GiteaConnector) void {
        if (self.auth_header) |h| self.allocator.free(@constCast(h));
        self.last_error.deinit(self.allocator);
        if (self.own_http) |*h| {
            h.deinit();
            self.own_http = null;
        }
    }

    pub fn setLastError(self: *GiteaConnector, detail: []const u8, fallback: []const u8) void {
        self.last_error.clearRetainingCapacity();
        const msg = if (std.mem.trim(u8, detail, " \t\r\n").len > 0) detail else fallback;
        var buffer: [200]u8 = undefined;
        const secret = if (self.auth_header) |h| if (std.mem.indexOfScalar(u8, h, ' ')) |i| h[i + 1 ..] else h else null;
        self.last_error.appendSlice(self.allocator, external_error.excerpt(&buffer, msg, secret)) catch |e| {
            std.log.err("forge diagnostic unavailable: {s}", .{@errorName(e)});
        };
    }

    pub fn setHttpError(self: *GiteaConnector, status: u16, body: []const u8) void {
        var excerpt_buffer: [200]u8 = undefined;
        const secret = if (self.auth_header) |h| if (std.mem.indexOfScalar(u8, h, ' ')) |i| h[i + 1 ..] else h else null;
        const clean = external_error.excerpt(&excerpt_buffer, body, secret);
        var buffer: [240]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "HTTP {d} {s}", .{ status, clean }) catch |e| {
            self.setLastError("", @errorName(e));
            return;
        };
        self.last_error.clearRetainingCapacity();
        self.last_error.appendSlice(self.allocator, message[0..@min(message.len, 200)]) catch |e| {
            std.log.err("forge diagnostic unavailable: {s}", .{@errorName(e)});
        };
    }

    fn httpClient(self: *GiteaConnector) !*http_client.HttpClient {
        if (self.http) |h| return h;
        if (self.own_http == null) self.own_http = try http_client.HttpClient.init(self.allocator);
        return &self.own_http.?;
    }

    /// Punto único de salida REST: tests lo guionan con http_fn; producción va
    /// por http_client con el header Authorization resuelto.
    pub fn rest(self: *GiteaConnector, method: []const u8, url: []const u8, body: ?[]const u8) !RestResponse {
        if (self.http_fn) |f| return f(self.allocator, method, url, self.auth_header, body, self.http_ctx);
        const client = try self.httpClient();
        var hdrs: [4]http.Header = undefined;
        var n: usize = 0;
        hdrs[n] = .{ .name = "user-agent", .value = "DevAgents" };
        n += 1;
        if (self.auth_header) |a| {
            hdrs[n] = .{ .name = "authorization", .value = a };
            n += 1;
        }
        if (std.mem.eql(u8, method, "GET")) {
            const r = try self.getWithStatus(client, url, hdrs[0..n]);
            return r;
        }
        hdrs[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;
        const verb: http.Method = if (std.mem.eql(u8, method, "POST")) .POST else if (std.mem.eql(u8, method, "PUT")) .PUT else if (std.mem.eql(u8, method, "PATCH")) .PATCH else return error.InvalidMethod;
        const uri = try std.Uri.parse(url);
        var req = try client.request(verb, uri, .{ .extra_headers = hdrs[0..n], .redirect_behavior = .not_allowed });
        defer req.deinit();
        const json = body orelse "{}";
        req.transfer_encoding = .{ .content_length = json.len };
        var writer = try req.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(json);
        try writer.end();
        try req.connection.?.flush();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        return .{ .status = @intFromEnum(response.head.status), .body = try client.readBody(&response) };
    }

    /// GET con status — igual que postJsonWithHeaders pero sin cuerpo; la API
    /// de Gitea distingue 200 (hay datos) de 401/404 (auth/endpoint), y tratar
    /// ambos como "sin PRs" sería mentir.
    fn getWithStatus(self: *GiteaConnector, client: *http_client.HttpClient, url: []const u8, headers: []const http.Header) !RestResponse {
        _ = self;
        const uri = try std.Uri.parse(url);
        var req = try client.request(.GET, uri, .{ .extra_headers = headers, .redirect_behavior = .not_allowed });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        const status = response.head.status;
        const body = try client.readBody(&response);
        return .{ .status = @intFromEnum(status), .body = body };
    }

    fn apiUrl(self: *GiteaConnector, comptime fmt: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(self.allocator, fmt, args);
    }

    /// GET /api/v1/repos/{slug} → default_branch REAL del repo. Error si la API
    /// no responde 200 o el JSON no trae el campo — nunca "main" inventado.
    pub fn repoDefaultBranch(self: *GiteaConnector, web_base: []const u8, slug: []const u8) ![]u8 {
        const url = try self.apiUrl("{s}/api/v1/repos/{s}", .{ web_base, slug });
        defer self.allocator.free(url);
        var r = self.rest("GET", url, null) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GiteaUnavailable;
        };
        defer r.deinit(self.allocator);
        if (r.status != 200) {
            self.setHttpError(r.status, r.body);
            return error.GiteaFailed;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, r.body, .{}) catch {
            self.setHttpError(r.status, r.body);
            return error.GiteaParseFailed;
        };
        defer parsed.deinit();
        const v = parsed.value.object.get("default_branch") orelse return error.GiteaParseFailed;
        if (v != .string or v.string.len == 0) return error.GiteaParseFailed;
        return try self.allocator.dupe(u8, v.string);
    }

    /// GET /api/v1/repos/{slug}/pulls?state=open&limit=50 → el PR ABIERTO cuyo
    /// head.ref sea la rama, o null. La adopción B2 igual que en github.zig:
    /// un PR ya abierto se toma, no se duplica.
    pub const ListedPr = struct {
        number: i64,
        url: []u8,
        state: gh_mod.PullRequestState,

        pub fn deinit(self: *ListedPr, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
        }
    };

    pub fn listOpenPrForBranch(self: *GiteaConnector, web_base: []const u8, slug: []const u8, head_branch: []const u8) !?ListedPr {
        const url = try self.apiUrl("{s}/api/v1/repos/{s}/pulls?state=open&limit=50", .{ web_base, slug });
        defer self.allocator.free(url);
        var r = self.rest("GET", url, null) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GiteaUnavailable;
        };
        defer r.deinit(self.allocator);
        if (r.status != 200) {
            self.setHttpError(r.status, r.body);
            return error.GiteaFailed;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, r.body, .{}) catch {
            self.setHttpError(r.status, r.body);
            return error.GiteaParseFailed;
        };
        defer parsed.deinit();
        if (parsed.value != .array) return error.GiteaParseFailed;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const head = item.object.get("head") orelse continue;
            if (head != .object) continue;
            const ref_v = head.object.get("ref") orelse continue;
            if (ref_v != .string or !std.mem.eql(u8, ref_v.string, head_branch)) continue;
            const num_v = item.object.get("number") orelse return error.GiteaParseFailed;
            if (num_v != .integer) return error.GiteaParseFailed;
            const url_v = item.object.get("html_url") orelse return error.GiteaParseFailed;
            if (url_v != .string) return error.GiteaParseFailed;
            return .{
                .number = num_v.integer,
                .url = try self.allocator.dupe(u8, url_v.string),
                .state = .open,
            };
        }
        return null;
    }

    /// POST /api/v1/repos/{slug}/pulls {title, body, head, base} → el PR creado
    /// con número/URL/estado REALES del JSON de respuesta. Cualquier no-201 es
    /// error con extracto saneado de la API en last_error — nunca un PR fabricado.
    pub const CreatedPr = struct {
        number: i64,
        url: []u8,
        state: gh_mod.PullRequestState,

        pub fn deinit(self: *CreatedPr, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
        }
    };

    pub fn createPullRequest(
        self: *GiteaConnector,
        web_base: []const u8,
        slug: []const u8,
        title: []const u8,
        body_text: []const u8,
        head_branch: []const u8,
        base_branch: []const u8,
    ) !CreatedPr {
        const url = try self.apiUrl("{s}/api/v1/repos/{s}/pulls", .{ web_base, slug });
        defer self.allocator.free(url);
        const body = try std.fmt.allocPrint(self.allocator,
            \\{{"title":{f},"body":{f},"head":{f},"base":{f}}}
        , .{ std.json.fmt(title, .{}), std.json.fmt(body_text, .{}), std.json.fmt(head_branch, .{}), std.json.fmt(base_branch, .{}) });
        defer self.allocator.free(body);
        var r = self.rest("POST", url, body) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GiteaUnavailable;
        };
        defer r.deinit(self.allocator);
        if (r.status != 201) {
            self.setHttpError(r.status, r.body);
            return error.GiteaCreateFailed;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, r.body, .{}) catch {
            self.setHttpError(r.status, r.body);
            return error.GiteaParseFailed;
        };
        defer parsed.deinit();
        const o = parsed.value.object;
        const num_v = o.get("number") orelse return error.GiteaParseFailed;
        if (num_v != .integer) return error.GiteaParseFailed;
        const url_v = o.get("html_url") orelse return error.GiteaParseFailed;
        if (url_v != .string) return error.GiteaParseFailed;
        var state: gh_mod.PullRequestState = .open;
        if (o.get("state")) |sv| {
            if (sv == .string and std.mem.eql(u8, sv.string, "closed")) state = .failed;
        }
        return .{
            .number = num_v.integer,
            .url = try self.allocator.dupe(u8, url_v.string),
            .state = state,
        };
    }

    /// GET /api/v1/repos/{slug}/pulls/{n} → estado REAL: merged flag + state.
    /// Error si la API no responde 200 — jamás un .open fingido.
    pub fn pullRequestState(self: *GiteaConnector, web_base: []const u8, slug: []const u8, number: i64) !gh_mod.PullRequestState {
        const url = try self.apiUrl("{s}/api/v1/repos/{s}/pulls/{d}", .{ web_base, slug, number });
        defer self.allocator.free(url);
        var r = self.rest("GET", url, null) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GiteaUnavailable;
        };
        defer r.deinit(self.allocator);
        if (r.status != 200) {
            self.setHttpError(r.status, r.body);
            return error.GiteaFailed;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, r.body, .{}) catch {
            self.setHttpError(r.status, r.body);
            return error.GiteaParseFailed;
        };
        defer parsed.deinit();
        const o = parsed.value.object;
        if (o.get("merged")) |mv| {
            if (mv == .bool and mv.bool) return .merged;
        }
        if (o.get("state")) |sv| {
            if (sv == .string) {
                if (std.mem.eql(u8, sv.string, "open")) return .open;
                if (std.mem.eql(u8, sv.string, "closed")) return .failed;
            }
        }
        return error.GiteaParseFailed;
    }

    /// POST /api/v1/repos/{slug}/pulls/{n}/merge {"Do":"merge"} → merge real.
    /// no-200/204 = error con extracto saneado de la API en last_error.
    pub fn mergePullRequest(self: *GiteaConnector, web_base: []const u8, slug: []const u8, number: i64) !void {
        const url = try self.apiUrl("{s}/api/v1/repos/{s}/pulls/{d}/merge", .{ web_base, slug, number });
        defer self.allocator.free(url);
        var r = self.rest("POST", url, "{\"Do\":\"merge\"}") catch |e| {
            self.setLastError("", @errorName(e));
            return error.GiteaUnavailable;
        };
        defer r.deinit(self.allocator);
        if (r.status != 200 and r.status != 204) {
            self.setHttpError(r.status, r.body);
            return error.GiteaMergeFailed;
        }
    }
};

// ───────────────────────────── tests ─────────────────────────────

test "gitea: parseRemoteUrl acepta https, ssh:// y forma scp, y detecta la forge" {
    const a = std.testing.allocator;

    var r1 = try parseRemoteUrl(a, "https://git.4stra.dev/Astra/DevAgents-Beats.git");
    defer r1.deinit(a);
    try std.testing.expectEqualStrings("git.4stra.dev", r1.host);
    try std.testing.expectEqualStrings("Astra/DevAgents-Beats", r1.slug);
    try std.testing.expectEqualStrings("https://git.4stra.dev", r1.web_base);
    try std.testing.expectEqual(Forge.gitea, r1.forge);

    var r2 = try parseRemoteUrl(a, "git@github.com:acme/widgets.git");
    defer r2.deinit(a);
    try std.testing.expectEqualStrings("github.com", r2.host);
    try std.testing.expectEqualStrings("acme/widgets", r2.slug);
    try std.testing.expectEqual(Forge.github, r2.forge);

    var r3 = try parseRemoteUrl(a, "ssh://git@git.4stra.dev:2222/Team/tool.git");
    defer r3.deinit(a);
    try std.testing.expectEqualStrings("git.4stra.dev", r3.host);
    try std.testing.expectEqualStrings("Team/tool", r3.slug);
    try std.testing.expectEqual(Forge.gitea, r3.forge);

    var r4 = try parseRemoteUrl(a, "https://git.4stra.dev/Astra/DevAgents-Beats/");
    defer r4.deinit(a);
    try std.testing.expectEqualStrings("Astra/DevAgents-Beats", r4.slug);

    // Basura honesta: sin owner/repo, local, file:// → error, nunca un slug.
    try std.testing.expectError(error.BadRemoteUrl, parseRemoteUrl(a, ""));
    try std.testing.expectError(error.BadRemoteUrl, parseRemoteUrl(a, "C:\\repo\\local"));
    try std.testing.expectError(error.BadRemoteUrl, parseRemoteUrl(a, "file:///tmp/x.git"));
    try std.testing.expectError(error.BadRemoteUrl, parseRemoteUrl(a, "https://git.4stra.dev/solo-repo.git"));
}

test "gitea: basicAuthHeader codifica user:pass real" {
    const a = std.testing.allocator;
    const h = try basicAuthHeader(a, "usuario", "secreto123");
    defer a.free(h);
    try std.testing.expectEqualStrings("Basic dXN1YXJpbzpzZWNyZXRvMTIz", h);
}

test "gitea E5.26 external error never exposes short credentials" {
    const a = std.testing.allocator;
    var g = GiteaConnector.init(a);
    defer g.deinit();
    g.http_fn = fakeRest;
    defer {
        rest_calls.deinit(a);
        rest_calls = .empty;
    }
    resetRest(422, "{\"message\":\"base branch missing\",\"token\":\"fx-s7\"}");
    try std.testing.expectError(error.GiteaFailed, g.pullRequestState("http://127.0.0.1", "o/r", 1));
    try std.testing.expect(std.mem.indexOf(u8, g.last_error.items, "fx-s7") == null);
    try std.testing.expect(std.mem.indexOf(u8, g.last_error.items, "422") != null);
    try std.testing.expect(std.mem.indexOf(u8, g.last_error.items, "texto externo") != null);
    try std.testing.expect(g.last_error.items.len <= 200);
    resetRest(200, "broken JSON password=fx-p9");
    try std.testing.expectError(error.GiteaParseFailed, g.pullRequestState("http://127.0.0.1", "o/r", 1));
    try std.testing.expect(std.mem.indexOf(u8, g.last_error.items, "fx-p9") == null);
}

test "providers E5.26 detect remote built-in and configured hosts guards credentials and paths" {
    const a = std.testing.allocator;
    var lab = try parseRemoteUrl(a, "git@gitlab.com:group/subgroup/repo.git");
    defer lab.deinit(a);
    try std.testing.expectEqual(Forge.gitlab, lab.forge);
    try std.testing.expectEqualStrings("group/subgroup/repo", lab.slug);
    var own = try parseRemoteUrlConfigured(a, "https://git.company.example:8443/group/repo.git", &.{.{ .host = "git.company.example:8443", .forge = .gitlab }});
    defer own.deinit(a);
    try std.testing.expectEqual(Forge.gitlab, own.forge);
    try std.testing.expectEqualStrings("https://git.company.example:8443", own.web_base);
    try std.testing.expectEqual(Forge.github, detectForgeConfigured("github.com", &.{}));
    try std.testing.expectEqual(Forge.github, detectForgeConfigured("enterprise.example", &.{.{ .host = "enterprise.example", .forge = .github }}));
    try std.testing.expectError(error.BadRemoteUrl, parseRemoteUrl(a, "https://user:secret@github.com/team/repo"));
    try std.testing.expectError(error.BadRemoteUrl, parseRemoteUrl(a, "https://github.com/team/../repo"));
    try std.testing.expectError(error.BadRemoteUrl, parseRemoteUrl(a, "https://github.com/team/repo?access_token=secret"));
    try std.testing.expectError(error.InvalidCredential, tokenAuthHeader(a, "token\r\ninjected: value"));
}

var rest_script: []const u8 = "";
var rest_status: u16 = 200;
var rest_calls: std.ArrayListUnmanaged(u8) = .empty;

fn fakeRest(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    auth: ?[]const u8,
    body: ?[]const u8,
    ctx: ?*anyopaque,
) anyerror!RestResponse {
    _ = ctx;
    const line = try std.fmt.allocPrint(allocator, "{s} {s} auth={s} body={s}\n", .{ method, url, auth orelse "-", body orelse "-" });
    defer allocator.free(line);
    try rest_calls.appendSlice(std.testing.allocator, line);
    return .{ .status = rest_status, .body = try allocator.dupe(u8, rest_script) };
}

fn resetRest(status: u16, body: []const u8) void {
    for (rest_calls.items) |*c| c.* = 0;
    rest_calls.clearRetainingCapacity();
    rest_status = status;
    rest_script = body;
}

test "gitea: createPullRequest devuelve número/URL REALES del 201 y falla honesto si no" {
    const a = std.testing.allocator;
    var g = GiteaConnector.init(a);
    defer g.deinit();
    g.http_fn = fakeRest;
    g.auth_header = try a.dupe(u8, "token t0k");
    defer {
        rest_calls.deinit(a);
        rest_calls = .empty;
    }

    resetRest(201, "{\"number\":42,\"html_url\":\"https://git.4stra.dev/Astra/DevAgents-Beats/pulls/42\",\"state\":\"open\"}");
    var pr = try g.createPullRequest("https://git.4stra.dev", "Astra/DevAgents-Beats", "t", "b", "beats/orden-7", "main");
    defer pr.deinit(a);
    try std.testing.expectEqual(@as(i64, 42), pr.number);
    try std.testing.expectEqualStrings("https://git.4stra.dev/Astra/DevAgents-Beats/pulls/42", pr.url);
    try std.testing.expectEqual(gh_mod.PullRequestState.open, pr.state);
    try std.testing.expect(std.mem.indexOf(u8, rest_calls.items, "POST https://git.4stra.dev/api/v1/repos/Astra/DevAgents-Beats/pulls") != null);
    try std.testing.expect(std.mem.indexOf(u8, rest_calls.items, "\"head\":\"beats/orden-7\"") != null);

    // Un 422 de la API (rama ya con PR, base inexistente) = error con el cuerpo
    // real en last_error — nunca un PR fabricado.
    resetRest(422, "{\"message\":\"pull request already exists for these targets\"}");
    try std.testing.expectError(error.GiteaCreateFailed, g.createPullRequest("https://git.4stra.dev", "Astra/DevAgents-Beats", "t", "b", "x", "main"));
    try std.testing.expect(std.mem.indexOf(u8, g.last_error.items, "already exists") != null);
}

test "gitea: listOpenPrForBranch adopta solo si head.ref coincide" {
    const a = std.testing.allocator;
    var g = GiteaConnector.init(a);
    defer g.deinit();
    g.http_fn = fakeRest;
    g.auth_header = try a.dupe(u8, "token t0k");
    defer {
        rest_calls.deinit(a);
        rest_calls = .empty;
    }

    resetRest(200, "[{\"number\":9,\"html_url\":\"https://git.4stra.dev/o/r/pulls/9\",\"head\":{\"ref\":\"otra\"}},{\"number\":10,\"html_url\":\"https://git.4stra.dev/o/r/pulls/10\",\"head\":{\"ref\":\"beats/orden-7\"}}]");
    var listed = (try g.listOpenPrForBranch("https://git.4stra.dev", "o/r", "beats/orden-7")).?;
    defer listed.deinit(a);
    try std.testing.expectEqual(@as(i64, 10), listed.number);

    resetRest(200, "[]");
    try std.testing.expect((try g.listOpenPrForBranch("https://git.4stra.dev", "o/r", "beats/orden-7")) == null);
}

test "gitea: pullRequestState lee merged/state real; merge devuelve error honesto" {
    const a = std.testing.allocator;
    var g = GiteaConnector.init(a);
    defer g.deinit();
    g.http_fn = fakeRest;
    g.auth_header = try a.dupe(u8, "token t0k");
    defer {
        rest_calls.deinit(a);
        rest_calls = .empty;
    }

    resetRest(200, "{\"state\":\"open\",\"merged\":false}");
    try std.testing.expectEqual(gh_mod.PullRequestState.open, try g.pullRequestState("https://git.4stra.dev", "o/r", 10));
    resetRest(200, "{\"state\":\"closed\",\"merged\":true}");
    try std.testing.expectEqual(gh_mod.PullRequestState.merged, try g.pullRequestState("https://git.4stra.dev", "o/r", 10));
    resetRest(404, "{\"message\":\"Not Found\"}");
    try std.testing.expectError(error.GiteaFailed, g.pullRequestState("https://git.4stra.dev", "o/r", 10));

    resetRest(405, "{\"message\":\"Merge not allowed\"}");
    try std.testing.expectError(error.GiteaMergeFailed, g.mergePullRequest("https://git.4stra.dev", "o/r", 10));
}
