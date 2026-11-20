//! Tanda 4 (F0.5,): `doctor`, la comprobación previa a la primera
//! orden. Dice, sin gastar ninguna orden ni red externa, si este equipo puede
//! lanzar una: carpeta de datos escribible, espacio en disco, runtime de
//! WebView2, git, y al menos una ruta de modelo utilizable (una CLI con sesión
//! de suscripción, una clave de API guardada u Ollama en local). Cada fallo
//! dice cómo arreglarse. Lo usan `devagents-core.exe doctor` y la cabina
//! (`da_doctor_json` → `core.doctor`).
//!
//! Las sondas se inyectan (`Probes`) para que las pruebas no dependan de lo que
//! haya instalado en la máquina; `realProbes()` son las de producción.
const std = @import("std");
const executor = @import("executor.zig");

pub const Status = enum {
    ok,
    aviso,
    falla,

    pub fn text(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .aviso => "aviso",
            .falla => "falla",
        };
    }
};

pub const Check = struct {
    id: []const u8,
    status: Status,
    title: []const u8,
    detail: []u8,
    fix: []const u8 = "",
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    checks: []Check,
    /// true cuando nada falla y hay al menos una ruta de modelo utilizable.
    ready: bool,

    pub fn deinit(self: *Report) void {
        for (self.checks) |c| self.allocator.free(c.detail);
        self.allocator.free(self.checks);
    }
};

pub const Probes = struct {
    /// Bytes libres para el usuario en el volumen de `path`; null = no se pudo saber.
    disk_free: *const fn (path: []const u8) ?u64,
    /// Versión del runtime de WebView2 (owned) o null si no está instalado.
    webview2_version: *const fn (a: std.mem.Allocator) ?[]u8,
    /// Ruta absoluta de git.exe (owned) o null si no está en el PATH.
    git_path: *const fn (a: std.mem.Allocator) ?[]u8,
    /// ¿Responde algo en 127.0.0.1:11434 (Ollama)? Solo loopback.
    ollama_up: *const fn () bool,
    /// ¿Se puede crear y borrar un archivo en `dir`?
    dir_writable: *const fn (a: std.mem.Allocator, dir: []const u8) bool,
};

pub const Input = struct {
    data_dir: ?[]const u8,
    /// Motivo si la carpeta de datos no se pudo resolver (override inválido…).
    data_dir_error: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    /// Catálogo de agentes externos tal como lo emite `detectedJson` (el
    /// mismo que reciben la cabina y la caché). null = no se pudo detectar.
    agents_json: ?[]const u8,
    /// Claves de API activas guardadas en el catálogo.
    saved_keys: usize = 0,
    /// CLIs conocidas que NO están en `agents_json` y por qué (todas sus
    /// instalaciones descartadas, o detectada ahora con la lista desfasada).
    missing: []const MissingCli = &.{},
    probes: Probes,
};

pub const RejectedInstall = struct { path: []const u8, reason: []const u8 };

pub const MissingCli = struct {
    cli: []const u8,
    /// true = una detección nueva sí la encuentra; la lista estaba desfasada.
    detected: bool = false,
    rejected: []const RejectedInstall = &.{},
};

/// Umbrales de espacio: por debajo de 1 GiB una orden con worktree puede
/// quedarse a medias; por debajo de 5 GiB se avisa.
pub const disk_fail_bytes: u64 = 1024 * 1024 * 1024;
pub const disk_warn_bytes: u64 = 5 * 1024 * 1024 * 1024;

pub fn run(a: std.mem.Allocator, input: Input) !Report {
    var checks: std.ArrayList(Check) = .empty;
    errdefer {
        for (checks.items) |c| a.free(c.detail);
        checks.deinit(a);
    }

    // 1. Carpeta de datos.
    if (input.data_dir) |dir| {
        if (input.probes.dir_writable(a, dir)) {
            try add(a, &checks, "data_dir", .ok, "Carpeta de datos", "{s}", .{dir}, "");
        } else {
            try add(a, &checks, "data_dir", .falla, "Carpeta de datos", "no se puede escribir en {s}", .{dir}, "Comprueba los permisos de esa carpeta o define DEVAGENTS_DATA_DIR con una carpeta tuya que exista.");
        }
    } else {
        try add(a, &checks, "data_dir", .falla, "Carpeta de datos", "no se pudo resolver ({s})", .{input.data_dir_error orelse "motivo desconocido"}, "Si definiste DEVAGENTS_DATA_DIR o BEATS_DATA_DIR, debe ser una ruta absoluta a una carpeta que exista.");
    }

    // 2. Espacio en disco (carpeta de datos y proyecto, si están en volúmenes distintos lo dice cada uno).
    var disk_targets: [2]?[]const u8 = .{ input.data_dir, input.workspace };
    if (input.workspace != null and input.data_dir != null and sameVolume(input.workspace.?, input.data_dir.?)) disk_targets[1] = null;
    for (disk_targets, 0..) |maybe, i| {
        const target = maybe orelse continue;
        const id = if (i == 0) "disk_data" else "disk_workspace";
        const title = if (i == 0) "Espacio libre (datos)" else "Espacio libre (proyecto)";
        if (input.probes.disk_free(target)) |free| {
            const gib = @as(f64, @floatFromInt(free)) / (1024.0 * 1024.0 * 1024.0);
            if (free < disk_fail_bytes) {
                try add(a, &checks, id, .falla, title, "{d:.1} GiB libres en {s}", .{ gib, volumeOf(target) }, "Libera espacio: una orden crea un espacio de trabajo con copia del proyecto y puede necesitar más de 1 GiB.");
            } else if (free < disk_warn_bytes) {
                try add(a, &checks, id, .aviso, title, "{d:.1} GiB libres en {s}", .{ gib, volumeOf(target) }, "Con menos de 5 GiB un proyecto grande puede quedarse sin sitio a mitad de una orden.");
            } else {
                try add(a, &checks, id, .ok, title, "{d:.1} GiB libres en {s}", .{ gib, volumeOf(target) }, "");
            }
        } else {
            try add(a, &checks, id, .aviso, title, "no se pudo medir en {s}", .{target}, "");
        }
    }

    // 3. WebView2 (la cabina no abre sin él). T9: en Linux no hay cabina en
    // esta version; se dice como aviso, no como fallo de un runtime ausente.
    if (@import("builtin").os.tag != .windows) {
        try add(a, &checks, "webview2", .aviso, "Cabina", "no disponible en Linux en esta version (motor, CLI y MCP si)", .{}, "");
    } else if (input.probes.webview2_version(a)) |version| {
        defer a.free(version);
        try add(a, &checks, "webview2", .ok, "Runtime de WebView2", "versión {s}", .{version}, "");
    } else {
        try add(a, &checks, "webview2", .falla, "Runtime de WebView2", "no está instalado", .{}, "Instala el «Evergreen Runtime» de WebView2 desde https://developer.microsoft.com/microsoft-edge/webview2/ (Windows 11 ya lo trae).");
    }

    // 4. git (espacios de trabajo, revertir, entregar).
    if (input.probes.git_path(a)) |path| {
        defer a.free(path);
        try add(a, &checks, "git", .ok, "git", "{s}", .{path}, "");
    } else {
        try add(a, &checks, "git", .aviso, "git", "no está en el PATH", .{}, "Sin git las órdenes trabajan en una carpeta aparte sin historial y no se puede revertir ni abrir PR. Instálalo desde https://git-scm.com/download/win.");
    }

    // 5. Una fila por CLI de terceros detectada, y las instalaciones descartadas.
    var routes: usize = 0;
    var detected: usize = 0;
    if (input.agents_json) |json| {
        var parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        if (parsed != null and parsed.?.value == .array) {
            for (parsed.?.value.array.items) |agent| {
                if (agent != .object) continue;
                detected += 1;
                const cli = str(agent, "cli");
                const display = if (str(agent, "display").len > 0) str(agent, "display") else cli;
                const version = if (str(agent, "version").len > 0) str(agent, "version") else "?";
                const session = str(agent, "session");
                const reason = str(agent, "session_reason");
                const sep: []const u8 = if (reason.len > 0) " — " else "";
                // El id debe vivir más que `parsed`: se usa el del catálogo
                // fijo, con un id propio por clase de fila (la cabina los usa
                // como clave y no deben repetirse).
                const known = knownCli(cli);
                const id = known.id;
                if (std.mem.eql(u8, session, "suscripcion")) {
                    routes += 1;
                    try add(a, &checks, id, .ok, stableTitle(cli), "{s} · {s} · sesión de suscripción · {s}", .{ display, version, str(agent, "exe") }, "");
                } else if (std.mem.eql(u8, session, "api_key")) {
                    try add(a, &checks, id, .aviso, stableTitle(cli), "{s} · {s} · {s}", .{ display, version, if (reason.len > 0) reason else "sesión con clave de API: factura por uso, no entra en «Solo gratis»" }, "Para usar tu suscripción, inicia sesión en la propia CLI con tu cuenta en vez de una clave.");
                } else if (std.mem.eql(u8, session, "sin_sesion")) {
                    try add(a, &checks, id, .aviso, stableTitle(cli), "{s} · {s} · sin sesión{s}{s}", .{ display, version, sep, reason }, "Abre la CLI una vez en una terminal e inicia sesión; DevAgents usará esa sesión.");
                } else {
                    try add(a, &checks, id, .aviso, stableTitle(cli), "{s} · {s} · sesión no reconocida{s}{s}", .{ display, version, sep, reason }, "");
                }
                // OpenCode sirve modelos gratuitos sin sesión de suscripción.
                if (!std.mem.eql(u8, session, "suscripcion")) {
                    if (agent.object.get("models")) |models| if (models == .array) for (models.array.items) |m| {
                        if (m != .object) continue;
                        const free = m.object.get("free") orelse continue;
                        if (free == .bool and free.bool) {
                            routes += 1;
                            try add(a, &checks, known.id_free, .ok, stableTitle(cli), "{s}: tiene modelos gratuitos sin sesión", .{display}, "");
                            break;
                        }
                    };
                }
                if (agent.object.get("rejected")) |rejected| if (rejected == .array) for (rejected.array.items) |r| {
                    if (r != .object) continue;
                    try add(a, &checks, known.id_rejected, .aviso, stableTitle(cli), "instalación descartada {s}: {s}", .{ str(r, "path"), str(r, "reason") }, "");
                };
                // una sola app empaquetada puede escribir en la
                // instalación elegida. Se acepta, pero el usuario debe saberlo.
                if (agent.object.get("acl_appcontainer_writers")) |writers| if (writers == .array) for (writers.array.items) |w| {
                    if (w != .object) continue;
                    const sid = str(w, "sid");
                    const app = str(w, "app");
                    if (app.len > 0) {
                        try add(a, &checks, known.id_acl, .aviso, stableTitle(cli), "la app «{s}» ({s}) puede modificar la instalación de {s}", .{ app, sid, display }, acl_writer_fix);
                    } else {
                        try add(a, &checks, known.id_acl, .aviso, stableTitle(cli), "una app ya desinstalada ({s}) conserva permiso de escritura sobre la instalación de {s}", .{ sid, display }, acl_writer_fix);
                    }
                };
            }
        } else {
            try add(a, &checks, "agents", .aviso, "CLI de terceros", "el catálogo de agentes no es legible", .{}, "");
        }
    } else {
        try add(a, &checks, "agents", .aviso, "CLI de terceros", "no se pudo detectar", .{}, "");
    }
    // Tanda 4: una CLI con TODAS sus instalaciones descartadas no está en el
    // catálogo; sin esto, el informe la callaba.
    for (input.missing) |m| {
        const known = knownCli(m.cli);
        if (m.detected) {
            try add(a, &checks, known.id, .aviso, known.title, "se encuentra ahora, pero la lista de agentes es anterior", .{}, "Pulsa «Detectar agentes» en Configuración › Agentes externos para que aparezca.");
            continue;
        }
        for (m.rejected) |r| {
            try add(a, &checks, known.id_rejected, .aviso, known.title, "ninguna instalación utilizable; descartada {s}: {s}", .{ r.path, r.reason }, "Corrige lo que dice el motivo o instala la CLI de nuevo con el instalador oficial; luego pulsa «Detectar agentes».");
        }
    }
    if (detected == 0 and input.agents_json != null) {
        try add(a, &checks, "agents", .aviso, "CLI de terceros", "ninguna detectada (Claude Code, Codex, Gemini CLI, OpenCode)", .{}, "No son obligatorias: con una clave de API u Ollama también se puede trabajar.");
    }

    // 6. Claves de API y Ollama.
    routes += input.saved_keys;
    if (input.saved_keys > 0) try add(a, &checks, "api_keys", .ok, "Claves de API", "{d} guardada(s), cifradas con DPAPI", .{input.saved_keys}, "");
    const ollama = input.probes.ollama_up();
    if (ollama) {
        routes += 1;
        try add(a, &checks, "ollama", .ok, "Ollama", "responde en 127.0.0.1:11434", .{}, "");
    }

    // 7. ¿Hay con qué lanzar la primera orden?
    if (routes == 0) {
        try add(a, &checks, "routes", .falla, "Modelos disponibles", "ninguna ruta utilizable", .{}, "Necesitas al menos una: inicia sesión en Claude Code, Codex u OpenCode; añade una clave de API en Ajustes (hay proveedores con capa gratuita); o instala Ollama.");
    } else {
        try add(a, &checks, "routes", .ok, "Modelos disponibles", "{d} ruta(s) utilizable(s)", .{routes}, "");
    }

    var ready = true;
    for (checks.items) |c| {
        if (c.status == .falla) ready = false;
    }
    return .{ .allocator = a, .checks = try checks.toOwnedSlice(a), .ready = ready };
}

fn add(a: std.mem.Allocator, list: *std.ArrayList(Check), id: []const u8, status: Status, title: []const u8, comptime fmt: []const u8, args: anytype, fix: []const u8) !void {
    const detail = try std.fmt.allocPrint(a, fmt, args);
    errdefer a.free(detail);
    try list.append(a, .{ .id = id, .status = status, .title = title, .detail = detail, .fix = fix });
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const field = v.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}

/// `Check.id` y `Check.title` no son owned: para una CLI se toman de esta
/// tabla fija, no del JSON (que se libera al terminar `run`).
const KnownCli = struct {
    cli: []const u8,
    title: []const u8,
    id: []const u8,
    id_free: []const u8,
    id_rejected: []const u8,
    id_acl: []const u8,
};

fn knownEntry(comptime cli: []const u8, comptime title: []const u8) KnownCli {
    return .{ .cli = cli, .title = title, .id = cli, .id_free = cli ++ "-gratis", .id_rejected = cli ++ "-descartada", .id_acl = cli ++ "-acl" };
}

pub const known_clis = [_]KnownCli{
    knownEntry("claude-code", "Claude Code"),
    knownEntry("codex", "Codex"),
    knownEntry("gemini-cli", "Gemini CLI"),
    knownEntry("opencode", "OpenCode"),
};

const unknown_cli = knownEntry("agent", "CLI de terceros");

fn knownCli(cli: []const u8) KnownCli {
    for (known_clis) |k| if (std.mem.eql(u8, k.cli, cli)) return k;
    return unknown_cli;
}

fn stableTitle(cli: []const u8) []const u8 {
    return knownCli(cli).title;
}

const acl_writer_fix = "DevAgents la acepta porque es una sola aplicación y no otro usuario, pero esa app podría cambiar el programa que DevAgents ejecuta. Si no lo quieres, busca la carpeta con la entrada explícita (sin «(I)») con `icacls <carpeta>` subiendo desde la de la CLI, guarda antes una copia con `icacls <carpeta> /save copia.txt` y quítala con `icacls <carpeta> /remove *<SID>`. La app puede volver a ponerla.";

fn volumeOf(path: []const u8) []const u8 {
    if (path.len >= 2 and path[1] == ':') return path[0..2];
    return path;
}

fn sameVolume(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(volumeOf(x), volumeOf(y));
}

pub fn toJson(a: std.mem.Allocator, report: Report) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("version");
    try js.write(@as(u8, 1));
    try js.objectField("ready");
    try js.write(report.ready);
    try js.objectField("checks");
    try js.beginArray();
    for (report.checks) |c| {
        try js.beginObject();
        try js.objectField("id");
        try js.write(c.id);
        try js.objectField("status");
        try js.write(c.status.text());
        try js.objectField("title");
        try js.write(c.title);
        try js.objectField("detail");
        try js.write(c.detail);
        try js.objectField("fix");
        try js.write(c.fix);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return out.toOwnedSlice();
}

pub fn renderText(a: std.mem.Allocator, report: Report) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("DevAgents doctor — comprobación antes de la primera orden\n\n");
    for (report.checks) |c| {
        const mark = switch (c.status) {
            .ok => "[ok]   ",
            .aviso => "[aviso]",
            .falla => "[FALLA]",
        };
        try w.print("{s} {s}: {s}\n", .{ mark, c.title, c.detail });
        if (c.fix.len > 0 and c.status != .ok) try w.print("        → {s}\n", .{c.fix});
    }
    try w.print("\n{s}\n", .{if (report.ready) "Listo para lanzar la primera orden." else "Falta algo antes de la primera orden: mira las líneas [FALLA]."});
    return out.toOwnedSlice();
}

/// `devagents-core.exe doctor`: el mismo informe que la cabina, desde la CLI.
/// La carpeta de datos es la única del producto (paths.resolveDataDir); el
/// catálogo de agentes sale de la caché si está vigente y, si no, se detecta
/// (lanza cada CLI con --version, sin gastar cupo) y se guarda en la caché,
/// como «Detectar agentes» en la cabina. El proyecto es la carpeta actual.
pub fn runLocal(a: std.mem.Allocator) !Report {
    const paths = @import("paths.zig");
    const db = @import("db.zig");
    const registry = @import("external_registry.zig");
    const health = @import("health.zig");
    var data_dir: ?[]u8 = null;
    var data_dir_error: ?[]const u8 = null;
    if (paths.resolveDataDir(a, null)) |resolved| {
        data_dir = resolved.dir;
    } else |e| data_dir_error = @errorName(e);
    defer if (data_dir) |d| a.free(d);

    var agents_json: ?[]u8 = null;
    defer if (agents_json) |j| a.free(j);
    var saved_keys: usize = 0;
    if (data_dir != null) {
        if (paths.catalogDb(a)) |cat_path| {
            defer a.free(cat_path);
            if (db.Connection.open(a, cat_path)) |conn_value| {
                var conn = conn_value;
                defer conn.close();
                db.Migrator.init(a).migrate(conn, &db.catalog_schema) catch {};
                agents_json = (registry.cached(a, conn, health.nowSeconds(conn)) catch null) orelse (registry.refresh(a, conn, null, null) catch null);
                if (conn.prepare("SELECT COUNT(*) FROM api_keys WHERE status='active'")) |stmt| {
                    defer conn.finalize(stmt);
                    if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) saved_keys = @intCast(@max(0, db.c.sqlite3_column_int64(stmt, 0)));
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    // CLIs conocidas que el catálogo no trae: se vuelve a detectar SOLO esa
    // CLI para decir por qué (mismas rutas y misma verificación).
    const agents = @import("external_agents.zig");
    var reports: [known_clis.len]agents.MissingReport = @splat(.{});
    var missing_buf: [known_clis.len]MissingCli = undefined;
    var installs: std.ArrayList(RejectedInstall) = .empty;
    defer {
        installs.deinit(a);
        for (&reports) |*r| r.deinit(a);
    }
    var missing_len: usize = 0;
    if (agents_json) |json| {
        // Primero se reservan todas las filas: `installs` no debe moverse
        // después de tomar porciones de él.
        var total: usize = 0;
        for (known_clis, 0..) |k, i| {
            if (std.mem.indexOf(u8, json, k.cli) != null and catalogHas(a, json, k.cli)) continue;
            reports[i] = agents.explainMissing(a, k.cli) catch .{};
            total += reports[i].rejected.len;
        }
        try installs.ensureTotalCapacity(a, total);
        for (known_clis, 0..) |k, i| {
            const r = reports[i];
            if (!r.detected and r.rejected.len == 0) continue;
            const start = installs.items.len;
            for (r.rejected) |x| installs.appendAssumeCapacity(.{ .path = x.path, .reason = x.reason });
            missing_buf[missing_len] = .{ .cli = k.cli, .detected = r.detected, .rejected = installs.items[start..] };
            missing_len += 1;
        }
    }

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), ".", a) catch null;
    defer if (cwd) |c| a.free(c);
    return run(a, .{
        .data_dir = data_dir,
        .data_dir_error = data_dir_error,
        .workspace = cwd,
        .agents_json = agents_json,
        .saved_keys = saved_keys,
        .missing = missing_buf[0..missing_len],
        .probes = realProbes(),
    });
}

/// ¿Trae el catálogo una fila con `"cli": cli`?
fn catalogHas(a: std.mem.Allocator, json: []const u8, cli: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .array) return true;
    for (parsed.value.array.items) |agent| {
        if (std.mem.eql(u8, str(agent, "cli"), cli)) return true;
    }
    return false;
}

// ── Sondas de producción ───────────────────────────────────────────────────

const GetCurrentProcessId = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
}.GetCurrentProcessId else @import("providers").posix_files.GetCurrentProcessId;
const GetTickCount64 = @import("platform.zig").ticks;
const GetDiskFreeSpaceExW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetDiskFreeSpaceExW(dir: [*:0]const u16, free_to_caller: ?*u64, total: ?*u64, total_free: ?*u64) callconv(.winapi) i32;
}.GetDiskFreeSpaceExW else @import("providers").posix_files.GetDiskFreeSpaceExW;
extern "advapi32" fn RegGetValueW(hkey: usize, sub_key: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

const HKEY_CURRENT_USER: usize = 0x80000001;
const HKEY_LOCAL_MACHINE: usize = 0x80000002;
const RRF_RT_REG_SZ: u32 = 0x2;

fn realDiskFree(path: []const u8) ?u64 {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(fba.allocator(), path) catch return null;
    var free: u64 = 0;
    if (GetDiskFreeSpaceExW(wide.ptr, &free, null, null) == 0) return null;
    return free;
}

/// Método documentado por Microsoft para detectar el runtime Evergreen: el
/// valor `pv` de la clave del cliente EdgeUpdate {F3017226-…}, en HKLM (32 y
/// 64 bits) o HKCU, distinto de vacío y de 0.0.0.0.
fn realWebView2Version(a: std.mem.Allocator) ?[]u8 {
    if (@import("builtin").os.tag != .windows) return null;
    const guid = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
    const sources = [_]struct { root: usize, key: [:0]const u16 }{
        .{ .root = HKEY_LOCAL_MACHINE, .key = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\" ++ guid) },
        .{ .root = HKEY_LOCAL_MACHINE, .key = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\" ++ guid) },
        .{ .root = HKEY_CURRENT_USER, .key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\EdgeUpdate\\Clients\\" ++ guid) },
    };
    for (sources) |source| {
        var data: [128]u16 = undefined;
        var bytes: u32 = @sizeOf(@TypeOf(data));
        if (RegGetValueW(source.root, source.key.ptr, std.unicode.utf8ToUtf16LeStringLiteral("pv").ptr, RRF_RT_REG_SZ, null, &data, &bytes) != 0) continue;
        const units = bytes / 2;
        if (units == 0) continue;
        const text = std.mem.sliceTo(data[0..units], 0);
        const version = std.unicode.utf16LeToUtf8Alloc(a, text) catch continue;
        if (version.len == 0 or std.mem.eql(u8, version, "0.0.0.0")) {
            a.free(version);
            continue;
        }
        return version;
    }
    return null;
}

fn realGitPath(a: std.mem.Allocator) ?[]u8 {
    const resolved = executor.resolveAllowedExeExt(a, "git", ".exe") catch return null;
    defer a.free(resolved);
    return a.dupe(u8, resolved) catch null;
}

fn realOllamaUp() bool {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 11434) catch return false;
    // Sin plazo: el Zig 0.16.0 de Windows aún no lo implementa (`@panic` en
    // netConnectIpWindows). En loopback un puerto cerrado responde enseguida.
    var stream = address.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

fn realDirWritable(a: std.mem.Allocator, dir: []const u8) bool {
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer d.close(io);
    var name_buf: [64]u8 = undefined;
    // Nombre único por proceso e instante; se borra enseguida.
    const name = std.fmt.bufPrint(&name_buf, ".doctor-{d}-{d}.tmp", .{ GetCurrentProcessId(), GetTickCount64() }) catch return false;
    d.writeFile(io, .{ .sub_path = name, .data = "doctor" }) catch return false;
    d.deleteFile(io, name) catch return false;
    return true;
}

pub fn realProbes() Probes {
    return .{ .disk_free = realDiskFree, .webview2_version = realWebView2Version, .git_path = realGitPath, .ollama_up = realOllamaUp, .dir_writable = realDirWritable };
}

// ── Pruebas ─────────────────────────────────────────────────────────────────

const Fake = struct {
    var free: ?u64 = 50 * 1024 * 1024 * 1024;
    var webview: bool = true;
    var git: bool = true;
    var ollama: bool = false;
    var writable: bool = true;
    fn disk(_: []const u8) ?u64 {
        return free;
    }
    fn wv(a: std.mem.Allocator) ?[]u8 {
        return if (webview) a.dupe(u8, "142.0.3595.53") catch null else null;
    }
    fn gitp(a: std.mem.Allocator) ?[]u8 {
        return if (git) a.dupe(u8, "C:\\Program Files\\Git\\cmd\\git.exe") catch null else null;
    }
    fn oll() bool {
        return ollama;
    }
    fn wr(_: std.mem.Allocator, _: []const u8) bool {
        return writable;
    }
    fn probes() Probes {
        return .{ .disk_free = disk, .webview2_version = wv, .git_path = gitp, .ollama_up = oll, .dir_writable = wr };
    }
    fn reset() void {
        free = 50 * 1024 * 1024 * 1024;
        webview = true;
        git = true;
        ollama = false;
        writable = true;
    }
};

fn findCheck(report: Report, id: []const u8) ?Check {
    for (report.checks) |c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

test "T4 doctor: sin ninguna ruta de modelo no está listo y dice cómo arreglarlo" {
    const a = std.testing.allocator;
    Fake.reset();
    var report = try run(a, .{ .data_dir = "C:\\datos", .agents_json = "[]", .probes = Fake.probes() });
    defer report.deinit();
    try std.testing.expect(!report.ready);
    const routes = findCheck(report, "routes").?;
    try std.testing.expectEqual(Status.falla, routes.status);
    try std.testing.expect(std.mem.indexOf(u8, routes.fix, "clave de API") != null);
}

test "T4 doctor: una CLI con suscripción basta y el informe sale en JSON y en texto" {
    const a = std.testing.allocator;
    Fake.reset();
    const agents =
        \\[{"provider":"agent:claude-code","cli":"claude-code","display":"Claude Code","exe":"C:\\x\\claude.exe","version":"2.1.322","session":"suscripcion","models":[],"rejected":[{"path":"C:\\viejo\\claude.exe","version":"1.0.0","reason":"versión más antigua que la elegida"}]},
        \\ {"provider":"agent:gemini-cli","cli":"gemini-cli","display":"Gemini CLI","exe":"C:\\x\\gemini.cmd","version":"0.53.1","session":"api_key","session_reason":"método «gemini-api-key»: clave de API, factura por uso","models":[]}]
    ;
    var report = try run(a, .{ .data_dir = "C:\\datos", .workspace = "C:\\proyecto", .agents_json = agents, .probes = Fake.probes() });
    defer report.deinit();
    try std.testing.expect(report.ready);
    try std.testing.expectEqual(Status.ok, findCheck(report, "claude-code").?.status);
    try std.testing.expectEqual(Status.aviso, findCheck(report, "gemini-cli").?.status);
    var rejected_seen = false;
    for (report.checks) |c| {
        if (std.mem.indexOf(u8, c.detail, "instalación descartada C:\\viejo\\claude.exe") != null) rejected_seen = true;
    }
    try std.testing.expect(rejected_seen);
    // Mismo volumen: una sola fila de espacio.
    try std.testing.expect(findCheck(report, "disk_workspace") == null);
    const json = try toJson(a, report);
    defer a.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ready").?.bool);
    const text = try renderText(a, report);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Listo para lanzar la primera orden") != null);
}

test "T4 doctor: disco, WebView2, carpeta de datos y git" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el doctor comprueba WebView2 y la cabina Windows; en Linux lo cubre la orden doctor real (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    Fake.reset();
    Fake.free = 512 * 1024 * 1024;
    Fake.webview = false;
    Fake.git = false;
    Fake.writable = false;
    Fake.ollama = true;
    var report = try run(a, .{ .data_dir = "C:\\datos", .workspace = "E:\\proyecto", .agents_json = null, .saved_keys = 1, .probes = Fake.probes() });
    defer report.deinit();
    try std.testing.expect(!report.ready);
    try std.testing.expectEqual(Status.falla, findCheck(report, "disk_data").?.status);
    try std.testing.expect(findCheck(report, "disk_workspace") != null);
    try std.testing.expectEqual(Status.falla, findCheck(report, "webview2").?.status);
    try std.testing.expectEqual(Status.falla, findCheck(report, "data_dir").?.status);
    try std.testing.expectEqual(Status.aviso, findCheck(report, "git").?.status);
    try std.testing.expectEqual(Status.ok, findCheck(report, "ollama").?.status);
    try std.testing.expectEqual(Status.ok, findCheck(report, "routes").?.status);
    Fake.reset();
    Fake.free = 3 * 1024 * 1024 * 1024;
    var warn = try run(a, .{ .data_dir = null, .data_dir_error = "DataDirOverrideInvalid", .agents_json = "[{\"cli\":\"opencode\",\"session\":\"sin_sesion\",\"models\":[{\"slug\":\"x\",\"free\":true}]}]", .saved_keys = 0, .probes = Fake.probes() });
    defer warn.deinit();
    try std.testing.expect(std.mem.indexOf(u8, findCheck(warn, "data_dir").?.detail, "DataDirOverrideInvalid") != null);
    try std.testing.expect(findCheck(warn, "disk_data") == null);
    // OpenCode sin sesión pero con un modelo gratuito es una ruta utilizable.
    try std.testing.expectEqual(Status.ok, findCheck(warn, "routes").?.status);
}

test "T4 doctor: sondas reales no fallan en este equipo" {
    const a = std.testing.allocator;
    const probes = realProbes();
    _ = probes.ollama_up();
    if (probes.webview2_version(a)) |v| a.free(v);
    if (probes.git_path(a)) |p| a.free(p);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const dir = try tmp.dir.realPathFileAlloc(threaded.io(), ".", a);
    defer a.free(dir);
    try std.testing.expect(probes.dir_writable(a, dir));
    try std.testing.expect(probes.disk_free(dir) != null);
}

test "T4 doctor: ids únicos, app empaquetada con escritura y CLI con todo descartado" {
    const a = std.testing.allocator;
    Fake.reset();
    const agents =
        \\[{"provider":"agent:opencode","cli":"opencode","display":"OpenCode","exe":"C:\\npm\\opencode.cmd","version":"1.2.3","session":"sin_sesion","models":[{"slug":"x","free":true}],
        \\  "rejected":[{"path":"C:\\viejo\\opencode.cmd","version":"0.1.0","reason":"versión más antigua que la elegida"}],
        \\  "acl_appcontainer_writers":[{"sid":"S-1-15-3-1-2-3-4-5-6-7","app":"Claude"},{"sid":"S-1-15-3-9-9-9-9-9-9-9","app":null}]}]
    ;
    const codex_rejected = [_]RejectedInstall{.{ .path = "C:\\npm\\codex.cmd", .reason = "CLI rechazada: binario o instalación escribible por otros usuarios" }};
    const missing = [_]MissingCli{
        .{ .cli = "codex", .rejected = &codex_rejected },
        .{ .cli = "gemini-cli", .detected = true },
    };
    var report = try run(a, .{ .data_dir = "C:\\datos", .agents_json = agents, .missing = &missing, .probes = Fake.probes() });
    defer report.deinit();
    // Cada clase de fila tiene su id: principal, gratis, descartada, acl.
    try std.testing.expectEqual(Status.aviso, findCheck(report, "opencode").?.status);
    try std.testing.expectEqual(Status.ok, findCheck(report, "opencode-gratis").?.status);
    try std.testing.expect(std.mem.indexOf(u8, findCheck(report, "opencode-descartada").?.detail, "C:\\viejo\\opencode.cmd") != null);
    const acl = findCheck(report, "opencode-acl").?;
    try std.testing.expectEqual(Status.aviso, acl.status);
    try std.testing.expect(std.mem.indexOf(u8, acl.detail, "la app «Claude» (S-1-15-3-1-2-3-4-5-6-7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, acl.fix, "icacls") != null);
    var orphan_writer = false;
    for (report.checks) |c| {
        if (std.mem.indexOf(u8, c.detail, "app ya desinstalada (S-1-15-3-9-9-9-9-9-9-9)") != null) orphan_writer = true;
    }
    try std.testing.expect(orphan_writer);
    // Codex no está en el catálogo: el informe dice por qué.
    const codex = findCheck(report, "codex-descartada").?;
    try std.testing.expect(std.mem.indexOf(u8, codex.detail, "ninguna instalación utilizable; descartada C:\\npm\\codex.cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, findCheck(report, "gemini-cli").?.detail, "lista de agentes es anterior") != null);
    // Ningún id de CLI aparece en dos clases distintas de fila.
    for (known_clis) |k| {
        const ids = [_][]const u8{ k.id, k.id_free, k.id_rejected, k.id_acl };
        for (ids, 0..) |x, i| for (ids[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x, y));
    }
    // OpenCode gratis es ruta: el informe está listo pese a los avisos.
    try std.testing.expect(report.ready);
}
