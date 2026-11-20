//! Actualizador «avisar y aplicar al cerrar».
//!
//! La comprobación diaria hace un GET a GitHub
//! Releases, desactivable en Ajustes y sin enviar datos; si hay versión nueva,
//! aviso en la cabina; con un clic se descarga y se verifica (SHA-256 publicado
//! junto al instalador y firma si la hay); se instala al cerrar o cuando no
//! queda ninguna orden en curso, nunca a mitad.
//!
//! Este módulo es el motor de eso: compara versiones, lee la última
//! publicación, guarda el resultado en la tabla `settings` del catálogo (para
//! que la cabina lo enseñe sin red), descarga y verifica el instalador en
//! `<datos>\updates\<versión>\` y decide si al cerrar se puede aplicar. No
//! lanza nada: el instalador lo lanza el host al cerrar (shell/host).
//!
//! Sin datos del usuario en la red: la consulta a la API lleva solo el
//! User-Agent fijo «DevAgents-updater» (GitHub lo exige); las descargas de
//! assets van por `getPublicFollowStatus` sin cabeceras propias.
const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const providers = @import("providers");
const web_tools = @import("web_tools.zig");

pub const CURRENT_VERSION = @import("root.zig").VERSION;

/// Repositorio de publicación: el mismo que tools/package_installer.ps1 ($AppURL).
pub const RELEASES_LATEST_URL = "https://api.github.com/repos/ItlaStudent/DevAgents/releases/latest";
/// Solo se aceptan assets descargables de este repositorio.
pub const DOWNLOAD_PREFIX = "https://github.com/ItlaStudent/DevAgents/releases/download/";
/// El enlace a las notas solo se enseña si apunta a las publicaciones del repositorio.
pub const NOTES_PREFIX = "https://github.com/ItlaStudent/DevAgents/releases/";
pub const USER_AGENT = "DevAgents-updater";
pub const CHECK_INTERVAL_MS: i64 = 24 * 60 * 60 * 1000;
pub const MAX_API_BYTES: usize = 1 << 20;
pub const MAX_SHA_BYTES: usize = 4096;
/// El instalador de 0.1.0 pesa ~16 MB; el tope deja margen sin abrir la puerta
/// a respuestas sin límite (se lee en memoria para calcular la huella).
pub const MAX_INSTALLER_BYTES: usize = 256 << 20;

pub const KEY_ENABLED = "update_check_enabled";
pub const KEY_LAST_CHECK = "update_last_check_ms";
pub const KEY_LATEST = "update_latest_json";
pub const KEY_STAGED = "update_staged_json";
pub const KEY_APPLY = "update_apply_on_exit";
/// T12 M3: el usuario aceptó instalar una actualización SIN firma verificable
/// del editor esperado (consentimiento explícito aparte del «Instalar»).
pub const KEY_APPLY_UNVERIFIED = "update_apply_unverified";
/// T12 M3: huella del certificado del editor que firma los instaladores de
/// DevAgents. Mientras no haya certificado de editor (hoy el instalador va
/// autofirmado o sin firma) no hay editor fijado y NINGUNA actualización
/// cuenta como verificada: todas piden el consentimiento «sin firma
/// verificable». Cuando exista, se fija aquí y `verify` debe devolverla.
pub const EXPECTED_PUBLISHER_SHA1: ?[]const u8 = null;
pub const KEY_DOWNLOAD_ERROR = "update_download_error";

// ---------------------------------------------------------------- versiones

/// Versión semver x.y.z[-prerelease]. Se acepta con o sin «v» delante. No se
/// aceptan metadatos de compilación («+…»): el texto acaba en nombres de
/// carpeta y de archivo, y solo se permiten [0-9A-Za-z.-].
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    pre: []const u8 = "",

    pub fn parse(text: []const u8) ?Version {
        var t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len > 0 and (t[0] == 'v' or t[0] == 'V')) t = t[1..];
        if (t.len == 0 or t.len > 64) return null;
        for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return null;
        const core_end = std.mem.indexOfScalar(u8, t, '-') orelse t.len;
        const pre = if (core_end < t.len) t[core_end + 1 ..] else "";
        if (core_end < t.len and pre.len == 0) return null;
        if (pre.len > 0) {
            var ids = std.mem.splitScalar(u8, pre, '.');
            while (ids.next()) |id| if (id.len == 0) return null;
        }
        var parts = std.mem.splitScalar(u8, t[0..core_end], '.');
        var nums: [3]u64 = undefined;
        for (&nums) |*n| {
            const p = parts.next() orelse return null;
            if (p.len == 0 or p.len > 18) return null;
            for (p) |c| if (!std.ascii.isDigit(c)) return null;
            if (p.len > 1 and p[0] == '0') return null;
            n.* = std.fmt.parseInt(u64, p, 10) catch return null;
        }
        if (parts.next() != null) return null;
        return .{ .major = nums[0], .minor = nums[1], .patch = nums[2], .pre = pre };
    }

    /// Precedencia semver: núcleo numérico; una prerelease es menor que la
    /// final; entre prereleases, identificador a identificador (los numéricos
    /// por valor y por debajo de los alfanuméricos; a igualdad, gana la lista
    /// más larga).
    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |f| {
            const o = std.math.order(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        if (a.pre.len == 0 and b.pre.len == 0) return .eq;
        if (a.pre.len == 0) return .gt;
        if (b.pre.len == 0) return .lt;
        var ia = std.mem.splitScalar(u8, a.pre, '.');
        var ib = std.mem.splitScalar(u8, b.pre, '.');
        while (true) {
            const x = ia.next();
            const y = ib.next();
            if (x == null and y == null) return .eq;
            if (x == null) return .lt;
            if (y == null) return .gt;
            const xn = std.fmt.parseInt(u64, x.?, 10) catch null;
            const yn = std.fmt.parseInt(u64, y.?, 10) catch null;
            const o: std.math.Order = if (xn != null and yn != null)
                std.math.order(xn.?, yn.?)
            else if (xn != null)
                .lt
            else if (yn != null)
                .gt
            else
                std.mem.order(u8, x.?, y.?);
            if (o != .eq) return o;
        }
    }
};

/// ¿`candidate` es más nueva que `installed`? Una versión ilegible nunca lo es.
pub fn isNewer(candidate: []const u8, installed: []const u8) bool {
    const c = Version.parse(candidate) orelse return false;
    const i = Version.parse(installed) orelse return false;
    return c.order(i) == .gt;
}

pub fn installerName(buf: []u8, version: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "DevAgents-Setup-v{s}.exe", .{version});
}

// ---------------------------------------------------------------- red inyectable

pub const FetchKind = enum { api, asset };
pub const Response = struct { status: u16, body: []u8 };
pub const FetchFn = *const fn (ctx: ?*anyopaque, a: std.mem.Allocator, url: []const u8, kind: FetchKind, max_bytes: usize) anyerror!Response;

pub const SignatureStatus = enum { valida, sin_firma, invalida };
pub const SignatureResult = struct {
    status: SignatureStatus,
    code: i32,
    /// Huella SHA-1 (hex) del certificado firmante, si la verificación la da.
    publisher_sha1: ?[]const u8 = null,
};

/// T12 M3: firma válida Y del editor esperado. Sin editor fijado, nunca.
pub fn signatureVerified(sig: SignatureResult) bool {
    const expected = EXPECTED_PUBLISHER_SHA1 orelse return false;
    const got = sig.publisher_sha1 orelse return false;
    return sig.status == .valida and std.ascii.eqlIgnoreCase(expected, got);
}
pub const VerifyFn = *const fn (ctx: ?*anyopaque, a: std.mem.Allocator, path: []const u8) anyerror!SignatureResult;

/// Dependencias con efectos: red y comprobación de firma. Las pruebas las
/// sustituyen (la suite no sale a la red).
pub const Deps = struct {
    ctx: ?*anyopaque = null,
    fetch: FetchFn = realFetch,
    verify: VerifyFn = realVerify,
};

fn realFetch(_: ?*anyopaque, a: std.mem.Allocator, url: []const u8, kind: FetchKind, max_bytes: usize) anyerror!Response {
    var http = try providers.http_client.HttpClient.init(a);
    defer http.deinit();
    http.max_response_bytes = max_bytes;
    switch (kind) {
        .api => {
            // Sin seguir redirecciones: la API responde en su propio origen.
            const uri = try std.Uri.parse(url);
            var req = try http.request(.GET, uri, .{ .headers = .{ .user_agent = .{ .override = USER_AGENT } } });
            defer req.deinit();
            try req.sendBodiless();
            var redirect_buffer: [8192]u8 = undefined;
            var response = try req.receiveHead(&redirect_buffer);
            const status: u16 = @intFromEnum(response.head.status);
            const body = try http.readBody(&response);
            return .{ .status = status, .body = body };
        },
        .asset => {
            // github.com redirige al almacén de assets (otro origen): se
            // siguen los saltos, cada uno filtrado por `publicHost`.
            var final_url: ?[]u8 = null;
            defer if (final_url) |f| a.free(f);
            var status: u16 = 0;
            const body = try http.getPublicFollowStatus(url, web_tools.publicHost, &final_url, &status);
            return .{ .status = status, .body = body };
        },
    }
}

extern fn da_cli_authenticode(std.os.windows.HANDLE, [*:0]const u16) i32;

fn realVerify(_: ?*anyopaque, a: std.mem.Allocator, path: []const u8) anyerror!SignatureResult {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(a, path);
    defer a.free(wide);
    const code = da_cli_authenticode(file.handle, wide.ptr);
    return .{ .status = classifySignature(code), .code = code };
}

/// Resultado de WinVerifyTrust. 0 = firma de confianza. T12 M3: solo los
/// códigos conocidos de «no hay firma que verificar» (sin firma, cadena
/// autofirmada o no reconocida, caducada, formato que no admite firma) son
/// `sin_firma`: se descarga, se enseña y solo se instala con el
/// consentimiento explícito «sin firma verificable». Manipulación,
/// desconfianza explícita y CUALQUIER código no reconocido son `invalida`:
/// se rechaza y se borra.
pub fn classifySignature(code: i32) SignatureStatus {
    if (code == 0) return .valida;
    const u: u32 = @bitCast(code);
    return switch (u) {
        0x800B0100, // TRUST_E_NOSIGNATURE: el archivo no está firmado
        0x800B0003, // TRUST_E_SUBJECT_FORM_UNKNOWN: formato sin firma Authenticode
        0x800B0001, // TRUST_E_PROVIDER_UNKNOWN
        0x800B0109, // CERT_E_UNTRUSTEDROOT: autofirmado (el de hoy)
        0x800B010A, // CERT_E_CHAINING: cadena incompleta
        0x800B010D, // CERT_E_UNTRUSTEDTESTROOT
        0x800B0101, // CERT_E_EXPIRED
        0x80096002, // TRUST_E_NO_SIGNER_CERT
        => .sin_firma,
        else => .invalida,
    };
}

// ---------------------------------------------------------------- ajustes

fn getSetting(a: std.mem.Allocator, conn: db.Connection, key: []const u8) !?[]u8 {
    const q = try conn.prepare("SELECT value FROM settings WHERE key=?");
    defer conn.finalize(q);
    try db.bindText(q, 1, key);
    const rc = db.c.sqlite3_step(q);
    if (rc == db.c.SQLITE_DONE) return null;
    if (rc != db.c.SQLITE_ROW) return error.SettingUnavailable;
    const v = db.c.sqlite3_column_text(q, 0);
    if (v == null) return null;
    return try a.dupe(u8, std.mem.span(v));
}

fn setSetting(conn: db.Connection, key: []const u8, value: []const u8) !void {
    const q = try conn.prepare("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
    defer conn.finalize(q);
    try db.bindText(q, 1, key);
    try db.bindText(q, 2, value);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.SettingWriteFailed;
}

fn deleteSetting(conn: db.Connection, key: []const u8) !void {
    const q = try conn.prepare("DELETE FROM settings WHERE key=?");
    defer conn.finalize(q);
    try db.bindText(q, 1, key);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.SettingWriteFailed;
}

/// Por defecto está activada (la decisión del propietario es un GET diario); solo
/// "0" la apaga.
pub fn isEnabled(a: std.mem.Allocator, conn: db.Connection) !bool {
    const v = (try getSetting(a, conn, KEY_ENABLED)) orelse return true;
    defer a.free(v);
    return !std.mem.eql(u8, v, "0");
}

pub fn setEnabled(conn: db.Connection, enabled: bool) !void {
    try setSetting(conn, KEY_ENABLED, if (enabled) "1" else "0");
}

/// Qué pidió el usuario: no instalar, instalar (solo vale con firma
/// verificada) o instalar aceptando que NO tiene firma verificable.
pub const ApplyChoice = enum { no, si, si_sin_firma_verificable };

fn stagedVerified(a: std.mem.Allocator, conn: db.Connection) !?bool {
    const staged = (try loadJson(a, conn, KEY_STAGED)) orelse return null;
    defer staged.deinit();
    const v = staged.value.object.get("verified") orelse return false;
    return v == .bool and v.bool;
}

/// El clic del usuario: instalar (o no) lo preparado al cerrar. T12 M3: una
/// actualización sin firma verificable del editor esperado no se acepta con
/// el «Instalar» normal (error.UnverifiedConsentRequired): exige la elección
/// `si_sin_firma_verificable`, que la cabina solo manda tras decirlo.
pub fn setApplyOnExit(a: std.mem.Allocator, conn: db.Connection, choice: ApplyChoice) !void {
    if (choice != .no) {
        const verified = (try stagedVerified(a, conn)) orelse return error.NothingStaged;
        if (!verified and choice != .si_sin_firma_verificable) return error.UnverifiedConsentRequired;
    }
    try setSetting(conn, KEY_APPLY, if (choice == .no) "0" else "1");
    if (choice == .si_sin_firma_verificable) try setSetting(conn, KEY_APPLY_UNVERIFIED, "1") else try deleteSetting(conn, KEY_APPLY_UNVERIFIED);
}

fn setDownloadError(conn: db.Connection, text: []const u8) !void {
    try setSetting(conn, KEY_DOWNLOAD_ERROR, text);
}

fn clearStaged(conn: db.Connection) !void {
    try deleteSetting(conn, KEY_STAGED);
    try deleteSetting(conn, KEY_APPLY);
    try deleteSetting(conn, KEY_APPLY_UNVERIFIED);
}

// ---------------------------------------------------------------- publicación

pub const Release = struct {
    version: []u8,
    tag: []u8,
    notes_url: ?[]u8,
    published_at: []u8,
    installer_url: []u8,
    sha256_url: []u8,

    pub fn deinit(self: Release, a: std.mem.Allocator) void {
        a.free(self.version);
        a.free(self.tag);
        if (self.notes_url) |n| a.free(n);
        a.free(self.published_at);
        a.free(self.installer_url);
        a.free(self.sha256_url);
    }
};

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Lee el JSON de /releases/latest. `why` recibe el motivo legible cuando la
/// publicación no sirve (sin etiqueta semver, sin instalador o sin huella).
pub fn parseRelease(a: std.mem.Allocator, body: []const u8, why_buf: []u8, why: *[]const u8) !Release {
    why.* = "la respuesta de GitHub no es una publicación legible";
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return error.ReleaseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ReleaseInvalid;
    const obj = parsed.value.object;
    const tag = str(obj, "tag_name") orelse return error.ReleaseInvalid;
    if (Version.parse(tag) == null) {
        why.* = std.fmt.bufPrint(why_buf, "la etiqueta «{s}» no es una versión x.y.z", .{tag[0..@min(tag.len, 64)]}) catch "la etiqueta no es una versión x.y.z";
        return error.ReleaseInvalid;
    }
    const version_text = if (tag[0] == 'v' or tag[0] == 'V') tag[1..] else tag;
    var name_buf: [128]u8 = undefined;
    const exe_name = try installerName(&name_buf, version_text);
    var sha_buf: [140]u8 = undefined;
    const sha_name = try std.fmt.bufPrint(&sha_buf, "{s}.sha256", .{exe_name});
    var exe_url: ?[]const u8 = null;
    var sha_url: ?[]const u8 = null;
    if (obj.get("assets")) |assets| if (assets == .array) for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const name = str(asset.object, "name") orelse continue;
        const url = str(asset.object, "browser_download_url") orelse continue;
        if (!std.mem.startsWith(u8, url, DOWNLOAD_PREFIX)) continue;
        if (std.mem.eql(u8, name, exe_name)) exe_url = url;
        if (std.mem.eql(u8, name, sha_name)) sha_url = url;
    };
    if (exe_url == null or sha_url == null) {
        why.* = std.fmt.bufPrint(why_buf, "la publicación {s} no trae {s}", .{ tag, if (exe_url == null) exe_name else sha_name }) catch "la publicación no trae el instalador o su huella";
        return error.AssetsMissing;
    }
    const notes = if (str(obj, "html_url")) |u| (if (std.mem.startsWith(u8, u, NOTES_PREFIX)) u else null) else null;
    const version = try a.dupe(u8, version_text);
    errdefer a.free(version);
    const tag_copy = try a.dupe(u8, tag);
    errdefer a.free(tag_copy);
    const notes_copy: ?[]u8 = if (notes) |n| try a.dupe(u8, n) else null;
    errdefer if (notes_copy) |n| a.free(n);
    const published = try a.dupe(u8, str(obj, "published_at") orelse "");
    errdefer a.free(published);
    const exe_copy = try a.dupe(u8, exe_url.?);
    errdefer a.free(exe_copy);
    const sha_copy = try a.dupe(u8, sha_url.?);
    return .{ .version = version, .tag = tag_copy, .notes_url = notes_copy, .published_at = published, .installer_url = exe_copy, .sha256_url = sha_copy };
}

fn writeRelease(js: *std.json.Stringify, r: Release) !void {
    try js.beginObject();
    try js.objectField("version");
    try js.write(r.version);
    try js.objectField("tag");
    try js.write(r.tag);
    try js.objectField("notes_url");
    try js.write(r.notes_url);
    try js.objectField("published_at");
    try js.write(r.published_at);
    try js.objectField("installer_url");
    try js.write(r.installer_url);
    try js.objectField("sha256_url");
    try js.write(r.sha256_url);
    try js.endObject();
}

fn resultJson(a: std.mem.Allocator, kind: []const u8, detail: []const u8, release: ?Release) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("kind");
    try js.write(kind);
    try js.objectField("detail");
    try js.write(detail);
    try js.objectField("release");
    if (release) |r| try writeRelease(&js, r) else try js.write(null);
    try js.endObject();
    return out.toOwnedSlice();
}

/// Consulta la última publicación y devuelve el resultado que se guarda.
fn fetchLatest(a: std.mem.Allocator, deps: Deps) ![]u8 {
    const resp = deps.fetch(deps.ctx, a, RELEASES_LATEST_URL, .api, MAX_API_BYTES) catch |e| {
        var buf: [160]u8 = undefined;
        return resultJson(a, "error", std.fmt.bufPrint(&buf, "no se pudo consultar GitHub ({s})", .{@errorName(e)}) catch "no se pudo consultar GitHub", null);
    };
    defer a.free(resp.body);
    // El repositorio todavía es privado: sin sesión, la API responde 404. Es
    // un estado («todavía no hay versiones publicadas»), no un fallo.
    if (resp.status == 404) return resultJson(a, "sin_publicaciones", "Todavía no hay versiones publicadas.", null);
    var buf: [200]u8 = undefined;
    if (resp.status == 403 or resp.status == 429)
        return resultJson(a, "error", std.fmt.bufPrint(&buf, "GitHub limitó la consulta (código {d}); se volverá a intentar", .{resp.status}) catch "GitHub limitó la consulta", null);
    if (resp.status != 200)
        return resultJson(a, "error", std.fmt.bufPrint(&buf, "GitHub respondió con el código {d}", .{resp.status}) catch "GitHub respondió con un código inesperado", null);
    var why: []const u8 = "";
    const release = parseRelease(a, resp.body, &buf, &why) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return resultJson(a, "error", why, null),
    };
    defer release.deinit(a);
    return resultJson(a, "release", "", release);
}

/// Comprobación. Desactivada: no hace red. Sin `force`, no repite antes de
/// 24 h desde la última. El resultado queda guardado para la cabina.
pub fn check(a: std.mem.Allocator, conn: db.Connection, deps: Deps, now_ms: i64, force: bool) !void {
    if (!try isEnabled(a, conn)) return;
    if (!force) {
        if (try getSetting(a, conn, KEY_LAST_CHECK)) |text| {
            defer a.free(text);
            const last = std.fmt.parseInt(i64, text, 10) catch 0;
            if (last > 0 and now_ms >= last and now_ms - last < CHECK_INTERVAL_MS) return;
        }
    }
    const result = try fetchLatest(a, deps);
    defer a.free(result);
    try setSetting(conn, KEY_LATEST, result);
    var buf: [24]u8 = undefined;
    try setSetting(conn, KEY_LAST_CHECK, try std.fmt.bufPrint(&buf, "{d}", .{now_ms}));
}

const StoredRelease = struct {
    parsed: std.json.Parsed(std.json.Value),
    fn release(self: StoredRelease) ?std.json.ObjectMap {
        const r = self.parsed.value.object.get("release") orelse return null;
        return if (r == .object) r.object else null;
    }
};

fn loadJson(a: std.mem.Allocator, conn: db.Connection, key: []const u8) !?std.json.Parsed(std.json.Value) {
    const text = (try getSetting(a, conn, key)) orelse return null;
    defer a.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return null;
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

// ---------------------------------------------------------------- estado

pub fn stateJson(a: std.mem.Allocator, conn: db.Connection) ![]u8 {
    const enabled = try isEnabled(a, conn);
    const last_text = try getSetting(a, conn, KEY_LAST_CHECK);
    defer if (last_text) |t| a.free(t);
    const latest = try loadJson(a, conn, KEY_LATEST);
    defer if (latest) |p| p.deinit();
    const staged = try loadJson(a, conn, KEY_STAGED);
    defer if (staged) |p| p.deinit();
    const apply_text = try getSetting(a, conn, KEY_APPLY);
    defer if (apply_text) |t| a.free(t);
    const unverified_text = try getSetting(a, conn, KEY_APPLY_UNVERIFIED);
    defer if (unverified_text) |t| a.free(t);
    const download_error = try getSetting(a, conn, KEY_DOWNLOAD_ERROR);
    defer if (download_error) |t| a.free(t);

    var status: []const u8 = "nunca";
    var detail: []const u8 = "Todavía no se ha buscado ninguna actualización.";
    var release: ?std.json.ObjectMap = null;
    var detail_buf: [200]u8 = undefined;
    if (latest) |p| {
        const kind = str(p.value.object, "kind") orelse "error";
        detail = str(p.value.object, "detail") orelse "";
        if (std.mem.eql(u8, kind, "release")) {
            release = (StoredRelease{ .parsed = p }).release();
            const v = if (release) |r| str(r, "version") orelse "" else "";
            if (isNewer(v, CURRENT_VERSION)) {
                status = "disponible";
                detail = std.fmt.bufPrint(&detail_buf, "DevAgents {s} disponible", .{v}) catch "Hay una versión nueva disponible";
            } else {
                status = "al_dia";
                detail = std.fmt.bufPrint(&detail_buf, "Tienes la última versión ({s}).", .{CURRENT_VERSION}) catch "Tienes la última versión.";
            }
        } else if (std.mem.eql(u8, kind, "sin_publicaciones")) {
            status = "sin_publicaciones";
        } else {
            status = "error";
        }
    }
    if (!enabled) {
        status = "desactivado";
        detail = "La búsqueda diaria de actualizaciones está desactivada.";
    }

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("enabled");
    try js.write(enabled);
    try js.objectField("current");
    try js.write(CURRENT_VERSION);
    try js.objectField("checked_ms");
    if (last_text) |t| try js.write(std.fmt.parseInt(i64, t, 10) catch 0) else try js.write(null);
    try js.objectField("status");
    try js.write(status);
    try js.objectField("detail");
    try js.write(detail);
    try js.objectField("latest");
    if (release) |r| try js.write(std.json.Value{ .object = r }) else try js.write(null);
    try js.objectField("staged");
    if (staged) |p| try js.write(p.value) else try js.write(null);
    try js.objectField("apply_on_exit");
    try js.write(staged != null and apply_text != null and std.mem.eql(u8, apply_text.?, "1"));
    try js.objectField("apply_unverified");
    try js.write(staged != null and unverified_text != null and std.mem.eql(u8, unverified_text.?, "1"));
    try js.objectField("download_error");
    try js.write(download_error);
    try js.endObject();
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------- descarga

pub fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Formato de 1.b: «<64 hex>  <nombre>» (como sha256sum; se acepta también
/// un espacio y el marcador binario «*»). El nombre tiene que ser el del
/// instalador: una huella de otro archivo no vale.
pub fn parseShaLine(body: []const u8, expected_name: []const u8) ?[64]u8 {
    const line_end = std.mem.indexOfAny(u8, body, "\r\n") orelse body.len;
    const line = std.mem.trim(u8, body[0..line_end], " \t\xEF\xBB\xBF");
    if (line.len < 66) return null;
    var hex: [64]u8 = undefined;
    for (line[0..64], 0..) |c, i| {
        if (!std.ascii.isHex(c)) return null;
        hex[i] = std.ascii.toLower(c);
    }
    if (line[64] != ' ' and line[64] != '\t') return null;
    var name = std.mem.trimStart(u8, line[64..], " \t");
    if (name.len > 0 and name[0] == '*') name = name[1..];
    if (!std.mem.eql(u8, name, expected_name)) return null;
    return hex;
}

fn failDownload(a: std.mem.Allocator, conn: db.Connection, io: std.Io, dir: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
    if (dir) |d| std.Io.Dir.cwd().deleteTree(io, d) catch |e| std.debug.print("updater: no se pudo borrar {s}: {s}\n", .{ d, @errorName(e) });
    const text = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(text);
    try setDownloadError(conn, text);
}

/// Baja la huella y el instalador de la última publicación guardada a
/// `<data_dir>\updates\<versión>\`, comprueba la huella y la firma, y deja lo
/// preparado en `update_staged_json`. Cualquier fallo queda en
/// `update_download_error` (visible en la cabina) y no deja nada a medias.
pub fn download(a: std.mem.Allocator, conn: db.Connection, deps: Deps, data_dir: ?[]const u8) !void {
    try deleteSetting(conn, KEY_DOWNLOAD_ERROR);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = data_dir orelse return failDownload(a, conn, io, null, "no hay carpeta de datos (sesión de prueba en memoria)", .{});
    const latest = (try loadJson(a, conn, KEY_LATEST)) orelse return failDownload(a, conn, io, null, "todavía no se ha buscado ninguna versión", .{});
    defer latest.deinit();
    const rel = (StoredRelease{ .parsed = latest }).release() orelse return failDownload(a, conn, io, null, "no hay ninguna versión nueva que descargar", .{});
    const version = str(rel, "version") orelse "";
    if (!isNewer(version, CURRENT_VERSION)) return failDownload(a, conn, io, null, "no hay ninguna versión nueva que descargar", .{});
    const installer_url = str(rel, "installer_url") orelse "";
    const sha_url = str(rel, "sha256_url") orelse "";
    if (!std.mem.startsWith(u8, installer_url, DOWNLOAD_PREFIX) or !std.mem.startsWith(u8, sha_url, DOWNLOAD_PREFIX))
        return failDownload(a, conn, io, null, "la publicación guardada no apunta al repositorio de DevAgents", .{});

    var name_buf: [128]u8 = undefined;
    const exe_name = try installerName(&name_buf, version);
    const dir = try std.fs.path.join(a, &.{ base, "updates", version });
    defer a.free(dir);
    const exe_path = try std.fs.path.join(a, &.{ dir, exe_name });
    defer a.free(exe_path);

    const sha_resp = deps.fetch(deps.ctx, a, sha_url, .asset, MAX_SHA_BYTES) catch |e|
        return failDownload(a, conn, io, null, "no se pudo bajar la huella del instalador ({s})", .{@errorName(e)});
    defer a.free(sha_resp.body);
    if (sha_resp.status != 200) return failDownload(a, conn, io, null, "GitHub respondió con el código {d} al bajar la huella", .{sha_resp.status});
    const expected = parseShaLine(sha_resp.body, exe_name) orelse
        return failDownload(a, conn, io, null, "la huella publicada no tiene el formato «<64 hex>  {s}»", .{exe_name});

    const exe_resp = deps.fetch(deps.ctx, a, installer_url, .asset, MAX_INSTALLER_BYTES) catch |e|
        return failDownload(a, conn, io, null, "no se pudo bajar el instalador ({s})", .{@errorName(e)});
    defer a.free(exe_resp.body);
    if (exe_resp.status != 200) return failDownload(a, conn, io, null, "GitHub respondió con el código {d} al bajar el instalador", .{exe_resp.status});

    std.Io.Dir.cwd().createDirPath(io, dir) catch |e|
        return failDownload(a, conn, io, null, "no se pudo crear {s} ({s})", .{ dir, @errorName(e) });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = exe_path, .data = exe_resp.body }) catch |e|
        return failDownload(a, conn, io, dir, "no se pudo guardar el instalador ({s})", .{@errorName(e)});
    const actual = sha256Hex(exe_resp.body);
    if (!std.mem.eql(u8, &actual, &expected))
        return failDownload(a, conn, io, dir, "la descarga no coincide con su huella", .{});

    const sig = deps.verify(deps.ctx, a, exe_path) catch |e|
        return failDownload(a, conn, io, dir, "no se pudo comprobar la firma del instalador ({s}); se borró", .{@errorName(e)});
    if (sig.status == .invalida)
        return failDownload(a, conn, io, dir, "la firma del instalador no es válida (código 0x{x:0>8}): se borró", .{@as(u32, @bitCast(sig.code))});

    // Otra versión preparada antes (más vieja) deja de servir.
    if (try loadJson(a, conn, KEY_STAGED)) |old| {
        defer old.deinit();
        if (str(old.value.object, "version")) |old_version| if (!std.mem.eql(u8, old_version, version)) {
            const old_dir = try std.fs.path.join(a, &.{ base, "updates", old_version });
            defer a.free(old_dir);
            std.Io.Dir.cwd().deleteTree(io, old_dir) catch |e| std.debug.print("updater: no se pudo borrar {s}: {s}\n", .{ old_dir, @errorName(e) });
        };
    }

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("version");
    try js.write(version);
    try js.objectField("path");
    try js.write(exe_path);
    try js.objectField("sha256");
    try js.write(actual[0..]);
    try js.objectField("signature");
    try js.write(@tagName(sig.status));
    try js.objectField("signature_code");
    try js.write(sig.code);
    // T12 M3: firma válida del editor fijado. La huella sale de la misma
    // publicación: comprueba la descarga, no quién la publicó.
    try js.objectField("verified");
    try js.write(signatureVerified(sig));
    try js.objectField("notes_url");
    try js.write(str(rel, "notes_url"));
    try js.endObject();
    try setSetting(conn, KEY_STAGED, out.written());
    // Descargar no es aceptar: lo acepta el clic de la cabina (setApplyOnExit).
    try setSetting(conn, KEY_APPLY, "0");
    try deleteSetting(conn, KEY_APPLY_UNVERIFIED);
}

// ---------------------------------------------------------------- aplicar al cerrar

fn pendingJson(a: std.mem.Allocator, path: ?[]const u8, reason: []const u8) ![]u8 {
    return pendingJsonSha(a, path, null, reason);
}

/// T12 M3: con la ruta va la huella, para que el host la vuelva a calcular
/// con el archivo abierto justo antes de lanzarlo.
fn pendingJsonSha(a: std.mem.Allocator, path: ?[]const u8, sha256: ?[]const u8, reason: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("apply");
    try js.write(path != null);
    try js.objectField("path");
    try js.write(path);
    try js.objectField("sha256");
    try js.write(sha256);
    try js.objectField("reason");
    try js.write(reason);
    try js.endObject();
    return out.toOwnedSlice();
}

/// ¿Se puede instalar ahora? Solo si hay algo preparado, el usuario lo
/// aceptó, es más nuevo que lo instalado y no hay ninguna orden en curso.
/// Antes de dar la ruta, vuelve a calcular la huella del archivo: si cambió
/// desde la descarga, se borra y no se aplica.
pub fn pendingApply(a: std.mem.Allocator, conn: db.Connection, orders_in_flight: bool) ![]u8 {
    const staged = (try loadJson(a, conn, KEY_STAGED)) orelse return pendingJson(a, null, "no hay ninguna actualización preparada");
    defer staged.deinit();
    const apply = (try getSetting(a, conn, KEY_APPLY)) orelse return pendingJson(a, null, "el usuario no pidió instalarla");
    defer a.free(apply);
    if (!std.mem.eql(u8, apply, "1")) return pendingJson(a, null, "el usuario no pidió instalarla");
    // T12 M3: sin firma verificable del editor esperado, nunca en silencio.
    const verified = if (staged.value.object.get("verified")) |v| v == .bool and v.bool else false;
    if (!verified) {
        const consent = try getSetting(a, conn, KEY_APPLY_UNVERIFIED);
        defer if (consent) |c| a.free(c);
        if (consent == null or !std.mem.eql(u8, consent.?, "1"))
            return pendingJson(a, null, "sin firma verificable del editor: falta el consentimiento explícito del usuario; no se instala");
    }
    const version = str(staged.value.object, "version") orelse "";
    if (!isNewer(version, CURRENT_VERSION)) return pendingJson(a, null, "la versión preparada no es más nueva que la instalada");
    if (orders_in_flight) return pendingJson(a, null, "hay órdenes en curso: se instalará en el próximo cierre");
    const path = str(staged.value.object, "path") orelse "";
    const expected = str(staged.value.object, "sha256") orelse "";
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(MAX_INSTALLER_BYTES)) catch |e| {
        try clearStaged(conn);
        const text = try std.fmt.allocPrint(a, "el instalador preparado ya no se puede leer ({s})", .{@errorName(e)});
        defer a.free(text);
        try setDownloadError(conn, text);
        return pendingJson(a, null, text);
    };
    defer a.free(bytes);
    const actual = sha256Hex(bytes);
    if (!std.mem.eql(u8, &actual, expected)) {
        if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().deleteTree(io, d) catch |e| std.debug.print("updater: no se pudo borrar {s}: {s}\n", .{ d, @errorName(e) });
        try clearStaged(conn);
        try setDownloadError(conn, "el instalador preparado cambió en disco desde la descarga: se borró");
        return pendingJson(a, null, "el instalador preparado cambió en disco desde la descarga: se borró");
    }
    return pendingJsonSha(a, path, expected, if (verified) "lista para instalar al cerrar" else "lista para instalar al cerrar (sin firma verificable, aceptado por el usuario)");
}

/// Al arrancar: si lo instalado ya es igual o más nuevo que lo preparado, la
/// actualización ya se aplicó (o quedó vieja) y se limpia.
pub fn cleanupApplied(a: std.mem.Allocator, conn: db.Connection, data_dir: ?[]const u8) !void {
    const staged = (try loadJson(a, conn, KEY_STAGED)) orelse return;
    defer staged.deinit();
    const version = str(staged.value.object, "version") orelse "";
    if (isNewer(version, CURRENT_VERSION)) return;
    if (data_dir) |base| {
        var threaded = std.Io.Threaded.init(a, .{});
        defer threaded.deinit();
        const updates = try std.fs.path.join(a, &.{ base, "updates" });
        defer a.free(updates);
        try std.Io.Dir.cwd().deleteTree(threaded.io(), updates);
    }
    try clearStaged(conn);
    try deleteSetting(conn, KEY_DOWNLOAD_ERROR);
}

// ================================================================ pruebas

const testing = std.testing;

fn testConn() !db.Connection {
    const conn = try db.Connection.open(testing.allocator, ":memory:");
    try conn.exec("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    return conn;
}

/// Red falsa: responde por URL y cuenta las llamadas.
const FakeNet = struct {
    api_status: u16 = 200,
    api_body: []const u8 = "",
    sha_body: []const u8 = "",
    exe_body: []const u8 = "",
    api_calls: usize = 0,
    asset_calls: usize = 0,
    signature: SignatureResult = .{ .status = .sin_firma, .code = @bitCast(@as(u32, 0x800B0100)) },
    verified: usize = 0,

    fn deps(self: *FakeNet) Deps {
        return .{ .ctx = self, .fetch = fetch, .verify = verify };
    }
    fn fetch(ctx: ?*anyopaque, a: std.mem.Allocator, url: []const u8, kind: FetchKind, max_bytes: usize) anyerror!Response {
        const self: *FakeNet = @ptrCast(@alignCast(ctx.?));
        switch (kind) {
            .api => {
                self.api_calls += 1;
                try testing.expectEqualStrings(RELEASES_LATEST_URL, url);
                return .{ .status = self.api_status, .body = try a.dupe(u8, self.api_body) };
            },
            .asset => {
                self.asset_calls += 1;
                const body = if (std.mem.endsWith(u8, url, ".sha256")) self.sha_body else self.exe_body;
                if (body.len > max_bytes) return error.ResponseTooLarge;
                return .{ .status = 200, .body = try a.dupe(u8, body) };
            },
        }
    }
    fn verify(ctx: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!SignatureResult {
        const self: *FakeNet = @ptrCast(@alignCast(ctx.?));
        self.verified += 1;
        return self.signature;
    }
};

const release_020 =
    \\{"tag_name":"v0.2.0","html_url":"https://github.com/ItlaStudent/DevAgents/releases/tag/v0.2.0","published_at":"2026-12-01T10:00:00Z","draft":false,"prerelease":false,
    \\ "assets":[{"name":"DevAgents-Setup-v0.2.0.exe","browser_download_url":"https://github.com/ItlaStudent/DevAgents/releases/download/v0.2.0/DevAgents-Setup-v0.2.0.exe"},
    \\           {"name":"DevAgents-Setup-v0.2.0.exe.sha256","browser_download_url":"https://github.com/ItlaStudent/DevAgents/releases/download/v0.2.0/DevAgents-Setup-v0.2.0.exe.sha256"}]}
;

fn stateValue(a: std.mem.Allocator, conn: db.Connection) !std.json.Parsed(std.json.Value) {
    const text = try stateJson(a, conn);
    defer a.free(text);
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

fn tmpDataDir(tmp: *std.testing.TmpDir) ![:0]u8 {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    return tmp.dir.realPathFileAlloc(threaded.io(), ".", testing.allocator);
}

test "T5 updater: semver con y sin v, prerelease menor que la final" {
    try testing.expect(isNewer("v0.2.0", "0.1.0"));
    try testing.expect(isNewer("0.1.1", "v0.1.0"));
    try testing.expect(isNewer("1.0.0", "0.99.99"));
    try testing.expect(!isNewer("0.1.0", "0.1.0"));
    try testing.expect(!isNewer("v0.1.0", "0.1.0"));
    try testing.expect(!isNewer("0.0.9", "0.1.0"));
    try testing.expect(!isNewer("0.2.0-beta.1", "0.2.0"));
    try testing.expect(isNewer("0.2.0", "0.2.0-rc.1"));
    try testing.expect(isNewer("0.2.0-beta.2", "0.2.0-beta.1"));
    try testing.expect(isNewer("0.2.0-beta.11", "0.2.0-beta.2"));
    try testing.expect(isNewer("0.2.0-beta", "0.2.0-alpha.9"));
    try testing.expect(isNewer("0.2.0-alpha.1", "0.2.0-alpha"));
    try testing.expect(isNewer("0.2.0-alpha", "0.2.0-1"));
    try testing.expect(isNewer("0.2.0-rc.1", "0.1.9"));
    // Ilegibles: nunca son «más nuevas».
    for ([_][]const u8{ "", "v", "1.2", "1.2.3.4", "01.2.3", "1.2.3-", "1.2.3+build", "1.2.x", "../1.2.3", "1.2.3-a..b" }) |bad| {
        try testing.expect(Version.parse(bad) == null);
        try testing.expect(!isNewer(bad, "0.0.1"));
    }
}

test "T5 updater: publicación con assets que faltan da error con motivo" {
    const a = testing.allocator;
    var buf: [200]u8 = undefined;
    var why: []const u8 = "";
    var ok = try parseRelease(a, release_020, &buf, &why);
    defer ok.deinit(a);
    try testing.expectEqualStrings("0.2.0", ok.version);
    try testing.expectEqualStrings("https://github.com/ItlaStudent/DevAgents/releases/tag/v0.2.0", ok.notes_url.?);
    const sin_sha =
        \\{"tag_name":"v0.2.0","assets":[{"name":"DevAgents-Setup-v0.2.0.exe","browser_download_url":"https://github.com/ItlaStudent/DevAgents/releases/download/v0.2.0/DevAgents-Setup-v0.2.0.exe"}]}
    ;
    try testing.expectError(error.AssetsMissing, parseRelease(a, sin_sha, &buf, &why));
    try testing.expect(std.mem.indexOf(u8, why, "DevAgents-Setup-v0.2.0.exe.sha256") != null);
    const sin_assets = "{\"tag_name\":\"v0.2.0\",\"assets\":[]}";
    try testing.expectError(error.AssetsMissing, parseRelease(a, sin_assets, &buf, &why));
    try testing.expect(std.mem.indexOf(u8, why, "DevAgents-Setup-v0.2.0.exe") != null);
    // Un asset con el nombre bueno pero fuera del repositorio no cuenta.
    const ajeno =
        \\{"tag_name":"v0.2.0","assets":[{"name":"DevAgents-Setup-v0.2.0.exe","browser_download_url":"https://evil.example/DevAgents-Setup-v0.2.0.exe"},
        \\ {"name":"DevAgents-Setup-v0.2.0.exe.sha256","browser_download_url":"https://github.com/ItlaStudent/DevAgents/releases/download/v0.2.0/DevAgents-Setup-v0.2.0.exe.sha256"}]}
    ;
    try testing.expectError(error.AssetsMissing, parseRelease(a, ajeno, &buf, &why));
    try testing.expectError(error.ReleaseInvalid, parseRelease(a, "{\"tag_name\":\"nightly\"}", &buf, &why));
    try testing.expect(std.mem.indexOf(u8, why, "nightly") != null);
    try testing.expectError(error.ReleaseInvalid, parseRelease(a, "no es json", &buf, &why));
}

test "T5 updater: 404 es sin_publicaciones, desactivado no sale a la red, 24 h" {
    const a = testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var net = FakeNet{ .api_status = 404, .api_body = "{\"message\":\"Not Found\"}" };
    const day = CHECK_INTERVAL_MS;
    try check(a, conn, net.deps(), 1_000, false);
    try testing.expectEqual(@as(usize, 1), net.api_calls);
    {
        var st = try stateValue(a, conn);
        defer st.deinit();
        try testing.expectEqualStrings("sin_publicaciones", st.value.object.get("status").?.string);
        try testing.expectEqual(@as(i64, 1_000), st.value.object.get("checked_ms").?.integer);
    }
    // Antes de 24 h no repite; con force sí; pasado el día, sí.
    try check(a, conn, net.deps(), 1_000 + day - 1, false);
    try testing.expectEqual(@as(usize, 1), net.api_calls);
    try check(a, conn, net.deps(), 1_000 + day - 1, true);
    try testing.expectEqual(@as(usize, 2), net.api_calls);
    try check(a, conn, net.deps(), 1_000 + 2 * day, false);
    try testing.expectEqual(@as(usize, 3), net.api_calls);
    // Desactivado: ni con force sale a la red, y el estado lo dice.
    try setEnabled(conn, false);
    try check(a, conn, net.deps(), 1_000 + 5 * day, true);
    try check(a, conn, net.deps(), 1_000 + 9 * day, false);
    try testing.expectEqual(@as(usize, 3), net.api_calls);
    {
        var st = try stateValue(a, conn);
        defer st.deinit();
        try testing.expectEqualStrings("desactivado", st.value.object.get("status").?.string);
        try testing.expect(!st.value.object.get("enabled").?.bool);
    }
    try setEnabled(conn, true);
    // Un código raro es error legible, no un silencio.
    net.api_status = 500;
    try check(a, conn, net.deps(), 1_000 + 20 * day, false);
    var st = try stateValue(a, conn);
    defer st.deinit();
    try testing.expectEqualStrings("error", st.value.object.get("status").?.string);
    try testing.expect(std.mem.indexOf(u8, st.value.object.get("detail").?.string, "500") != null);
}

test "T5 updater: versión nueva disponible y huella que no coincide borra y da error" {
    const a = testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(&tmp);
    defer a.free(data_dir);
    const exe = "instalador falso";
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000  DevAgents-Setup-v0.2.0.exe\n";
    var net = FakeNet{ .api_body = release_020, .sha_body = wrong, .exe_body = exe };
    try check(a, conn, net.deps(), 5, true);
    {
        var st = try stateValue(a, conn);
        defer st.deinit();
        try testing.expectEqualStrings("disponible", st.value.object.get("status").?.string);
        try testing.expectEqualStrings("0.2.0", st.value.object.get("latest").?.object.get("version").?.string);
        try testing.expectEqualStrings("DevAgents 0.2.0 disponible", st.value.object.get("detail").?.string);
    }
    try download(a, conn, net.deps(), data_dir);
    try testing.expectEqual(@as(usize, 2), net.asset_calls);
    try testing.expectEqual(@as(usize, 0), net.verified);
    var st = try stateValue(a, conn);
    defer st.deinit();
    try testing.expectEqualStrings("la descarga no coincide con su huella", st.value.object.get("download_error").?.string);
    try testing.expect(st.value.object.get("staged").? == .null);
    // Lo bajado se borró.
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const dir = try std.fs.path.join(a, &.{ data_dir, "updates", "0.2.0" });
    defer a.free(dir);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(threaded.io(), dir, .{}));
}

test "T5 updater: firma inválida bloquea y borra; sin firma reconocida se prepara y se muestra" {
    const a = testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(&tmp);
    defer a.free(data_dir);
    const exe = "instalador falso firmado";
    var sha_line: [200]u8 = undefined;
    const hex = sha256Hex(exe);
    const sha_body = try std.fmt.bufPrint(&sha_line, "{s}  DevAgents-Setup-v0.2.0.exe\r\n", .{&hex});
    var net = FakeNet{ .api_body = release_020, .sha_body = sha_body, .exe_body = exe, .signature = .{ .status = .invalida, .code = @bitCast(@as(u32, 0x80096010)) } };
    try check(a, conn, net.deps(), 5, true);
    try download(a, conn, net.deps(), data_dir);
    try testing.expectEqual(@as(usize, 1), net.verified);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const dir = try std.fs.path.join(a, &.{ data_dir, "updates", "0.2.0" });
    defer a.free(dir);
    {
        var st = try stateValue(a, conn);
        defer st.deinit();
        try testing.expect(std.mem.indexOf(u8, st.value.object.get("download_error").?.string, "firma del instalador no es válida") != null);
        try testing.expect(st.value.object.get("staged").? == .null);
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(threaded.io(), dir, .{}));
    }
    // Sin firma reconocida (autofirmada o ninguna): se prepara y se enseña.
    net.signature = .{ .status = .sin_firma, .code = @bitCast(@as(u32, 0x800B0109)) };
    try download(a, conn, net.deps(), data_dir);
    var st = try stateValue(a, conn);
    defer st.deinit();
    try testing.expect(st.value.object.get("download_error").? == .null);
    const staged = st.value.object.get("staged").?.object;
    try testing.expectEqualStrings("sin_firma", staged.get("signature").?.string);
    try testing.expectEqualStrings(&hex, staged.get("sha256").?.string);
    try testing.expect(!st.value.object.get("apply_on_exit").?.bool);
    try std.Io.Dir.cwd().access(threaded.io(), staged.get("path").?.string, .{});
}

test "T5 updater: pending_apply exige consentimiento, ninguna orden en curso y la misma huella" {
    const a = testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(&tmp);
    defer a.free(data_dir);
    const exe = "instalador falso 2";
    var sha_line: [200]u8 = undefined;
    const sha_body = try std.fmt.bufPrint(&sha_line, "{s}  DevAgents-Setup-v0.2.0.exe\n", .{sha256Hex(exe)});
    var net = FakeNet{ .api_body = release_020, .sha_body = sha_body, .exe_body = exe };
    // Sin nada preparado no se puede aceptar.
    try testing.expectError(error.NothingStaged, setApplyOnExit(a, conn, .si));
    try check(a, conn, net.deps(), 5, true);
    try download(a, conn, net.deps(), data_dir);

    const expectApply = struct {
        fn run(conn_: db.Connection, in_flight: bool, want: bool, reason_part: []const u8) !void {
            const text = try pendingApply(testing.allocator, conn_, in_flight);
            defer testing.allocator.free(text);
            var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
            defer p.deinit();
            try testing.expectEqual(want, p.value.object.get("apply").?.bool);
            try testing.expect(std.mem.indexOf(u8, p.value.object.get("reason").?.string, reason_part) != null);
        }
    }.run;
    // Descargado pero sin el clic: no se aplica.
    try expectApply(conn, false, false, "no pidió");
    // T12 M3: sin firma verificable el «Instalar» normal no vale.
    try testing.expectError(error.UnverifiedConsentRequired, setApplyOnExit(a, conn, .si));
    try expectApply(conn, false, false, "no pidió");
    try setApplyOnExit(a, conn, .si_sin_firma_verificable);
    // Con una orden en curso: nada.
    try expectApply(conn, true, false, "órdenes en curso");
    // Sin órdenes: la ruta, con su huella para que el host la recalcule.
    try expectApply(conn, false, true, "sin firma verificable, aceptado");
    {
        const text = try pendingApply(a, conn, false);
        defer a.free(text);
        try testing.expect(std.mem.indexOf(u8, text, &sha256Hex(exe)) != null);
    }
    // «No instalar»: vuelve a no aplicarse y retira el consentimiento.
    try setApplyOnExit(a, conn, .no);
    try expectApply(conn, false, false, "no pidió");
    try testing.expect((try getSetting(a, conn, KEY_APPLY_UNVERIFIED)) == null);
    // Aunque el ajuste diga «instalar», sin el consentimiento no se aplica.
    try setSetting(conn, KEY_APPLY, "1");
    try expectApply(conn, false, false, "sin firma verificable");
    try setApplyOnExit(a, conn, .si_sin_firma_verificable);
    // Alguien cambia el archivo entre la descarga y el cierre: se borra.
    var st = try stateValue(a, conn);
    defer st.deinit();
    const path = st.value.object.get("staged").?.object.get("path").?.string;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = "otro contenido" });
    try expectApply(conn, false, false, "cambió en disco");
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(threaded.io(), path, .{}));
    try expectApply(conn, false, false, "no hay ninguna actualización preparada");
}

test "T12 M3: códigos de verificación no reconocidos se rechazan; sin editor fijado nada cuenta como verificado" {
    // Conocidos de «no hay firma que verificar»: se muestran y piden consentimiento.
    for ([_]u32{ 0x800B0100, 0x800B0003, 0x800B0109, 0x800B010A, 0x800B0101 }) |code|
        try testing.expectEqual(SignatureStatus.sin_firma, classifySignature(@bitCast(code)));
    // Manipulación y cualquier otro código (p. ej. política del equipo,
    // error de archivo o uno que nadie anotó): rechazo.
    for ([_]u32{ 0x80096010, 0x800B0111, 0x800B010C, 0x80092026, 0x80092003, 0x800B0004, 0x80070005, 0x12345678 }) |code|
        try testing.expectEqual(SignatureStatus.invalida, classifySignature(@bitCast(code)));
    try testing.expectEqual(SignatureStatus.valida, classifySignature(0));
    // Hoy no hay editor fijado: ni una firma válida cuenta como verificada.
    try testing.expect(EXPECTED_PUBLISHER_SHA1 == null);
    try testing.expect(!signatureVerified(.{ .status = .valida, .code = 0, .publisher_sha1 = "aa" }));
    try testing.expect(!signatureVerified(.{ .status = .valida, .code = 0 }));
}

test "T12 M3: un instalador con código de firma no reconocido no se prepara y se borra" {
    const a = testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(&tmp);
    defer a.free(data_dir);
    const exe = "instalador con firma rara";
    var sha_line: [200]u8 = undefined;
    const sha_body = try std.fmt.bufPrint(&sha_line, "{s}  DevAgents-Setup-v0.2.0.exe\n", .{sha256Hex(exe)});
    var net = FakeNet{ .api_body = release_020, .sha_body = sha_body, .exe_body = exe, .signature = .{ .status = classifySignature(@bitCast(@as(u32, 0x80092026))), .code = @bitCast(@as(u32, 0x80092026)) } };
    try check(a, conn, net.deps(), 5, true);
    try download(a, conn, net.deps(), data_dir);
    var st = try stateValue(a, conn);
    defer st.deinit();
    try testing.expect(std.mem.indexOf(u8, st.value.object.get("download_error").?.string, "firma del instalador no es válida") != null);
    try testing.expect(st.value.object.get("staged").? == .null);
    try testing.expectError(error.NothingStaged, setApplyOnExit(a, conn, .si_sin_firma_verificable));
}

test "T5 updater: al arrancar con la versión ya aplicada se limpia lo preparado" {
    const a = testing.allocator;
    var conn = try testConn();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(&tmp);
    defer a.free(data_dir);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try std.fs.path.join(a, &.{ data_dir, "updates", CURRENT_VERSION });
    defer a.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const staged = try std.fmt.allocPrint(a, "{{\"version\":\"{s}\",\"path\":\"x\",\"sha256\":\"y\",\"signature\":\"sin_firma\"}}", .{CURRENT_VERSION});
    defer a.free(staged);
    try setSetting(conn, KEY_STAGED, staged);
    try setSetting(conn, KEY_APPLY, "1");
    // Una preparada más nueva que lo instalado NO se toca.
    const newer = "{\"version\":\"99.0.0\",\"path\":\"x\",\"sha256\":\"y\",\"signature\":\"sin_firma\"}";
    try setSetting(conn, KEY_STAGED, newer);
    try cleanupApplied(a, conn, data_dir);
    try std.Io.Dir.cwd().access(io, dir, .{});
    try setSetting(conn, KEY_STAGED, staged);
    try cleanupApplied(a, conn, data_dir);
    const updates = try std.fs.path.join(a, &.{ data_dir, "updates" });
    defer a.free(updates);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, updates, .{}));
    try testing.expect((try getSetting(a, conn, KEY_STAGED)) == null);
    try testing.expect((try getSetting(a, conn, KEY_APPLY)) == null);
}

test "T5 updater: huella publicada con el formato de sha256sum" {
    const name = "DevAgents-Setup-v0.2.0.exe";
    const h = "ABCDEF0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789";
    try testing.expect(parseShaLine(h ++ "  " ++ name ++ "\n", name) != null);
    try testing.expect(parseShaLine(h ++ " *" ++ name, name) != null);
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", &parseShaLine(h ++ "  " ++ name, name).?);
    try testing.expect(parseShaLine(h ++ "  otro.exe", name) == null);
    try testing.expect(parseShaLine(h[0..63] ++ "   " ++ name, name) == null);
    try testing.expect(parseShaLine("zz" ++ h[2..] ++ "  " ++ name, name) == null);
}

test "T5 updater: WinVerifyTrust real clasifica un archivo sin firma como sin_firma" {
    if (builtin.os.tag != .windows) return @import("platform.zig").skip("T9: WinVerifyTrust/Authenticode no existe en Linux; el actualizador Linux es L14");
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDataDir(&tmp);
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "sin-firma.exe" });
    defer a.free(path);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = "MZ no es un ejecutable firmado" });
    const r = try realVerify(null, a, path);
    try testing.expectEqual(SignatureStatus.sin_firma, r.status);
    try testing.expect(r.code != 0);
    try testing.expectEqual(SignatureStatus.invalida, classifySignature(@bitCast(@as(u32, 0x80096010))));
    try testing.expectEqual(SignatureStatus.valida, classifySignature(0));
}
