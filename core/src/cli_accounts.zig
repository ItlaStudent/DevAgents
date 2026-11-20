//! T7 (f,) · Varias cuentas por CLI, aisladas y con
//! rotación (decisión del propietario del 13-nov).
//!
//! Cada cuenta vive en su propia carpeta dentro de la carpeta de datos de
//! DevAgents (`<datos>\cli-accounts\<cli>\<id>`) y la CLI la usa porque se le
//! pasa la variable que, según su documentación oficial, aísla su
//! configuración y sus credenciales:
//!
//! - Codex: `CODEX_HOME` (https://learn.chatgpt.com/docs/auth/ci-cd-auth usa
//!   `${CODEX_HOME:-$HOME/.codex}/auth.json`). La carpeta nace con
//!   `cli_auth_credentials_store = "file"` en su config.toml para que el
//!   inicio de sesión quede en SU auth.json y no en el llavero del sistema,
//!   compartido entre carpetas.
//! - Claude Code: `CLAUDE_CONFIG_DIR` (https://code.claude.com/docs/en/claude-directory:
//!   «every ~/.claude path on this page lives under that directory instead»,
//!   también `.claude.json`; las credenciales son `.credentials.json` ahí).
//! - Gemini CLI y OpenCode NO se ofrecen: `GEMINI_CLI_HOME` mueve la carpeta
//!   de configuración, pero su documentación no garantiza que el inicio de
//!   sesión con Google no vaya al llavero del sistema (compartido); OpenCode
//!   no documenta ninguna variable que mueva su carpeta de datos (auth.json /
//!   opencode.db), solo «custom XDG paths» sin nombrarlas.
//!
//! El inicio de sesión lo hace el usuario en la terminal integrada con un
//! comando que fija la variable solo para ese proceso: DevAgents nunca ve ni
//! guarda credenciales, y la carpeta por defecto de la CLI (el «login del
//! sistema») no se toca ni se copia: sin cuenta elegida la CLI corre como
//! siempre.
//!
//! Rotación: si la corrida con una cuenta termina por cuota o límite de uso,
//! se repite con la siguiente cuenta de esa CLI y se avisa («la cuenta X agotó
//! su cuota; sigue con Y»).

const std = @import("std");
const db = @import("db.zig");
const planner = @import("planner.zig");
const sandbox = @import("sandbox.zig");
const external_agents = @import("external_agents.zig");

pub const CliSpec = struct {
    cli: []const u8,
    display: []const u8,
    env_var: []const u8,
    login: []const u8,
};

pub const SUPPORTED = [_]CliSpec{
    .{ .cli = "codex", .display = "Codex", .env_var = "CODEX_HOME", .login = "codex login" },
    .{ .cli = "claude-code", .display = "Claude Code", .env_var = "CLAUDE_CONFIG_DIR", .login = "claude auth login" },
};

/// CLIs detectadas que no se ofrecen, con el motivo para la cabina.
pub const UNSUPPORTED = [_]struct { cli: []const u8, display: []const u8, why: []const u8 }{
    .{ .cli = "gemini-cli", .display = "Gemini CLI", .why = "GEMINI_CLI_HOME mueve su configuración, pero su documentación no garantiza que el inicio de sesión con Google no quede en el llavero del sistema, compartido entre cuentas." },
    .{ .cli = "opencode", .display = "OpenCode", .why = "Su documentación no nombra ninguna variable que mueva la carpeta donde guarda las credenciales (auth.json / opencode.db)." },
};

const SETTINGS_KEY = "cli_accounts";
const SELECTED_PREFIX = "cli_account_selected:";
pub const ACCOUNTS_DIR = "cli-accounts";
pub const MAX_ACCOUNTS_PER_CLI: usize = 8;
pub const MAX_LABEL_BYTES: usize = 40;

pub const Error = error{ UnsupportedCli, InvalidLabel, TooManyAccounts, UnknownAccount, InvalidDataDir, CorruptRegistry, AccountFolderBusy } || db.DbError || std.mem.Allocator.Error;

/// Aviso de la última baja que no pudo borrar la carpeta (la cuenta sí se
/// quitó). Lo enseña la cabina con el estado y lo limpia la siguiente alta,
/// baja o selección.
const NOTICE_KEY = "cli_accounts_notice";

pub fn specFor(cli: []const u8) ?CliSpec {
    for (SUPPORTED) |spec| if (std.mem.eql(u8, spec.cli, cli)) return spec;
    return null;
}

pub const Account = struct {
    id: []const u8,
    cli: []const u8,
    label: []const u8,
    dir: []const u8,
};

pub const Registry = struct {
    parsed: ?std.json.Parsed([]Account) = null,

    pub fn items(self: *const Registry) []const Account {
        return if (self.parsed) |p| p.value else &.{};
    }

    pub fn deinit(self: *Registry) void {
        if (self.parsed) |*p| p.deinit();
        self.parsed = null;
    }

    pub fn find(self: *const Registry, id: []const u8) ?Account {
        for (self.items()) |acc| if (std.mem.eql(u8, acc.id, id)) return acc;
        return null;
    }

    /// Cuentas de una CLI en el orden en que se dieron de alta.
    pub fn forCli(self: *const Registry, a: std.mem.Allocator, cli: []const u8) ![]Account {
        var out: std.ArrayList(Account) = .empty;
        errdefer out.deinit(a);
        for (self.items()) |acc| if (std.mem.eql(u8, acc.cli, cli)) try out.append(a, acc);
        return out.toOwnedSlice(a);
    }
};

fn readSetting(a: std.mem.Allocator, conn: db.Connection, key: []const u8) Error!?[]u8 {
    const stmt = try conn.prepare("SELECT value FROM settings WHERE key = ?");
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, key);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
    const ptr = db.c.sqlite3_column_text(stmt, 0) orelse return null;
    const len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 0));
    return try a.dupe(u8, ptr[0..len]);
}

fn writeSetting(conn: db.Connection, key: []const u8, value: ?[]const u8) Error!void {
    if (value == null) {
        const del = try conn.prepare("DELETE FROM settings WHERE key = ?");
        defer conn.finalize(del);
        try db.bindText(del, 1, key);
        if (db.c.sqlite3_step(del) != db.c.SQLITE_DONE) return error.StepFailed;
        return;
    }
    const stmt = try conn.prepare(
        \\INSERT INTO settings (key, value) VALUES (?, ?)
        \\ON CONFLICT(key) DO UPDATE SET value=excluded.value
    );
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, key);
    try db.bindText(stmt, 2, value.?);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub fn load(a: std.mem.Allocator, conn: db.Connection) Error!Registry {
    const raw = (try readSetting(a, conn, SETTINGS_KEY)) orelse return .{};
    defer a.free(raw);
    const parsed = std.json.parseFromSlice([]Account, a, raw, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptRegistry,
    };
    return .{ .parsed = parsed };
}

fn store(a: std.mem.Allocator, conn: db.Connection, accounts: []const Account) Error!void {
    const json = try std.json.Stringify.valueAlloc(a, accounts, .{});
    defer a.free(json);
    try writeSetting(conn, SETTINGS_KEY, json);
}

/// T12 B3: además de lo que cmd.exe interpreta, `$` y el acento grave, que
/// PowerShell expande (`$(...)`, `$env:X` y el acento grave como escape) si la
/// terminal integrada es PowerShell y recibe la línea antes que cmd.
fn shellSensitive(c: u8) bool {
    return c < 0x20 or c == '"' or c == '%' or c == '&' or c == '|' or c == '<' or c == '>' or c == '^' or c == '$' or c == '`';
}

fn validLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > MAX_LABEL_BYTES) return false;
    if (!std.unicode.utf8ValidateSlice(label)) return false;
    for (label) |c| if (shellSensitive(c) or c == '\\') return false;
    return true;
}

/// Carpeta de datos apta para el comando de la terminal: absoluta y sin los
/// caracteres que cmd.exe interpreta dentro de `set VAR=valor&&…` ni los que
/// expande PowerShell (`$`, acento grave; ver `shellSensitive`).
fn validDataDir(dir: []const u8) bool {
    if (dir.len < 3 or dir.len > 1024 or !std.fs.path.isAbsolute(dir)) return false;
    for (dir) |c| if (shellSensitive(c) or c == '!') return false;
    return true;
}

/// Da de alta una cuenta: id `<cli>-<n>`, carpeta propia bajo `data_dir` y,
/// para Codex, credenciales en archivo dentro de esa carpeta.
pub fn add(a: std.mem.Allocator, io: std.Io, conn: db.Connection, data_dir: []const u8, cli: []const u8, label: []const u8) Error!Account {
    const spec = specFor(cli) orelse return error.UnsupportedCli;
    const clean = std.mem.trim(u8, label, " \t\r\n");
    if (!validLabel(clean)) return error.InvalidLabel;
    if (!validDataDir(data_dir)) return error.InvalidDataDir;
    var reg = try load(a, conn);
    defer reg.deinit();
    const existing = try reg.forCli(a, cli);
    defer a.free(existing);
    if (existing.len >= MAX_ACCOUNTS_PER_CLI) return error.TooManyAccounts;
    var n: usize = existing.len + 1;
    var id_buf: [64]u8 = undefined;
    const id = free_id: {
        while (n <= MAX_ACCOUNTS_PER_CLI * 2) : (n += 1) {
            const candidate = std.fmt.bufPrint(&id_buf, "{s}-{d}", .{ cli, n }) catch return error.InvalidLabel;
            if (reg.find(candidate) == null) break :free_id candidate;
        }
        return error.TooManyAccounts;
    };
    const dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ std.mem.trimEnd(u8, data_dir, "\\/"), ACCOUNTS_DIR, spec.cli, id });
    errdefer a.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.InvalidDataDir;
    if (std.mem.eql(u8, spec.cli, "codex")) {
        const config = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "config.toml", .{dir});
        defer a.free(config);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config, .data = "# DevAgents: credenciales de esta cuenta en su propio auth.json, no en el llavero del sistema.\ncli_auth_credentials_store = \"file\"\n" }) catch return error.InvalidDataDir;
    }
    var next: std.ArrayList(Account) = .empty;
    defer next.deinit(a);
    try next.appendSlice(a, reg.items());
    const account = Account{ .id = try a.dupe(u8, id), .cli = spec.cli, .label = try a.dupe(u8, clean), .dir = dir };
    try next.append(a, account);
    try store(a, conn, next.items);
    try writeSetting(conn, NOTICE_KEY, null);
    return account;
}

pub fn freeAccount(a: std.mem.Allocator, account: Account) void {
    a.free(account.id);
    a.free(account.label);
    a.free(account.dir);
}

/// ¿Algún componente de la ruta es `..` (o `.`)? Una carpeta de cuenta así
/// podría salir de `<datos>\cli-accounts` aunque empiece por ella. Windows
/// ignora los espacios y puntos finales de cada componente.
/// T12 B3: la carpeta registrada de una cuenta es exactamente
/// `<base><cli>\<id>` (lo único que crea `add`), con `<cli>` admitida e
/// `<id>` sin separadores ni puntos. Un registro manipulado que apunte a la
/// carpeta de cuentas entera o a la de una CLI no pasa.
fn isOwnAccountDir(a: std.mem.Allocator, base: []const u8, victim: Account) !bool {
    if (specFor(victim.cli) == null) return false;
    if (victim.id.len == 0 or std.mem.indexOfAny(u8, victim.id, "\\/:") != null or hasDotComponent(victim.id)) return false;
    const expected = try std.fmt.allocPrint(a, "{s}{s}" ++ std.fs.path.sep_str ++ "{s}", .{ base, victim.cli, victim.id });
    defer a.free(expected);
    const dir = std.mem.trimEnd(u8, victim.dir, "\\/");
    if (dir.len != expected.len) return false;
    for (dir, expected) |left, right| {
        const l = if (left == '/') '\\' else std.ascii.toLower(left);
        const r = if (right == '/') '\\' else std.ascii.toLower(right);
        if (l != r) return false;
    }
    return true;
}

fn hasDotComponent(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "\\/");
    while (it.next()) |part| {
        if (std.mem.trimEnd(u8, part, " .").len == 0) return true;
    }
    return false;
}

/// Qué pasó con la carpeta al quitar una cuenta.
pub const RemoveOutcome = enum { deleted, missing, kept_outside, left_behind };

/// Quita la cuenta del registro y su carpeta (solo si cuelga de la carpeta de
/// cuentas de DevAgents, sin componentes `..`: nunca una carpeta por defecto
/// de la CLI ni otra ajena).
///
/// QA-B (14-nov): sin cuentas a medias. La carpeta primero se renombra a una
/// lápida junto a ella (operación atómica): si no se puede (la CLI la tiene
/// abierta) no se toca nada y se devuelve `AccountFolderBusy`. Con la lápida
/// hecha se quita del registro y se borra; si el borrado falla, la cuenta ya
/// no existe y el aviso (`NOTICE_KEY`) dice qué carpeta quedó en disco.
pub fn remove(a: std.mem.Allocator, io: std.Io, conn: db.Connection, data_dir: []const u8, id: []const u8) Error!RemoveOutcome {
    var reg = try load(a, conn);
    defer reg.deinit();
    const victim = reg.find(id) orelse return error.UnknownAccount;
    var next: std.ArrayList(Account) = .empty;
    defer next.deinit(a);
    for (reg.items()) |acc| if (!std.mem.eql(u8, acc.id, id)) try next.append(a, acc);
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "", .{ std.mem.trimEnd(u8, data_dir, "\\/"), ACCOUNTS_DIR });
    defer a.free(base);
    try writeSetting(conn, NOTICE_KEY, null);

    var outcome: RemoveOutcome = .kept_outside;
    var tombstone: ?[]u8 = null;
    defer if (tombstone) |t| a.free(t);
    if ((if (@import("builtin").os.tag == .windows) std.ascii.startsWithIgnoreCase(victim.dir, base) else std.mem.startsWith(u8, victim.dir, base)) and !hasDotComponent(victim.dir) and try isOwnAccountDir(a, base, victim)) {
        const grave = try std.fmt.allocPrint(a, "{s}.quitando", .{std.mem.trimEnd(u8, victim.dir, "\\/")});
        if (std.Io.Dir.cwd().rename(victim.dir, std.Io.Dir.cwd(), grave, io)) |_| {
            tombstone = grave;
        } else |e| {
            a.free(grave);
            if (e != error.FileNotFound) {
                std.log.warn("cuenta {s}: carpeta en uso, no se quita ({s})", .{ id, @errorName(e) });
                return error.AccountFolderBusy;
            }
            outcome = .missing;
        }
    } else {
        const msg = try std.fmt.allocPrint(a, "La cuenta «{s}» se quitó, pero su carpeta {s} no se borró: está fuera de la carpeta de cuentas de DevAgents.", .{ victim.label, victim.dir });
        defer a.free(msg);
        try writeSetting(conn, NOTICE_KEY, msg);
    }

    const key = try std.fmt.allocPrint(a, "{s}{s}", .{ SELECTED_PREFIX, victim.cli });
    defer a.free(key);
    const chosen = try readSetting(a, conn, key);
    defer if (chosen) |c| a.free(c);
    if (chosen) |c| if (std.mem.eql(u8, c, id)) try writeSetting(conn, key, null);
    store(a, conn, next.items) catch |e| {
        // El registro no cambió: la carpeta vuelve a su sitio y la cuenta
        // sigue entera.
        if (tombstone) |t| std.Io.Dir.cwd().rename(t, std.Io.Dir.cwd(), victim.dir, io) catch |re|
            std.log.err("cuenta {s}: no se pudo devolver la carpeta {s} a su sitio ({s})", .{ id, t, @errorName(re) });
        return e;
    };

    if (tombstone) |t| {
        if (std.Io.Dir.cwd().deleteTree(io, t)) |_| {
            outcome = .deleted;
        } else |e| {
            outcome = .left_behind;
            const msg = try std.fmt.allocPrint(a, "La cuenta «{s}» se quitó, pero su carpeta no se pudo borrar ({s}): bórrala a mano, queda en {s}", .{ victim.label, @errorName(e), t });
            defer a.free(msg);
            try writeSetting(conn, NOTICE_KEY, msg);
        }
    }
    return outcome;
}

/// Aviso pendiente de la última baja (ver `NOTICE_KEY`), o null.
pub fn pendingNotice(a: std.mem.Allocator, conn: db.Connection) Error!?[]u8 {
    return readSetting(a, conn, NOTICE_KEY);
}

/// Cuenta con la que empiezan las órdenes de esa CLI; null = el login del
/// sistema (carpeta por defecto de la CLI, sin rotación).
pub fn select(a: std.mem.Allocator, conn: db.Connection, cli: []const u8, id: ?[]const u8) Error!void {
    if (specFor(cli) == null) return error.UnsupportedCli;
    if (id) |value| {
        var reg = try load(a, conn);
        defer reg.deinit();
        const acc = reg.find(value) orelse return error.UnknownAccount;
        if (!std.mem.eql(u8, acc.cli, cli)) return error.UnknownAccount;
    }
    const key = try std.fmt.allocPrint(a, "{s}{s}", .{ SELECTED_PREFIX, cli });
    defer a.free(key);
    try writeSetting(conn, key, id);
    try writeSetting(conn, NOTICE_KEY, null);
}

pub fn selected(a: std.mem.Allocator, conn: db.Connection, cli: []const u8) Error!?[]u8 {
    const key = try std.fmt.allocPrint(a, "{s}{s}", .{ SELECTED_PREFIX, cli });
    defer a.free(key);
    return readSetting(a, conn, key);
}

/// Comando para la terminal integrada: fija la variable SOLO en un cmd hijo
/// y lanza el inicio de sesión de la CLI. El usuario escribe sus credenciales
/// en la CLI; DevAgents no las ve.
pub fn loginCommand(a: std.mem.Allocator, account: Account) Error![]u8 {
    const spec = specFor(account.cli) orelse return error.UnsupportedCli;
    if (!validDataDir(account.dir)) return error.InvalidDataDir;
    if (@import("builtin").os.tag != .windows) {
        // Single-quote the value, including literal apostrophes in an account path.
        const quoted = try std.mem.replaceOwned(u8, a, account.dir, "'", "'\\''");
        defer a.free(quoted);
        return std.fmt.allocPrint(a, "{s}='{s}' {s}", .{ spec.env_var, quoted, spec.login });
    }
    return std.fmt.allocPrint(a, "cmd /d /s /c \"set {s}={s}&& {s}\"", .{ spec.env_var, account.dir, spec.login });
}

/// ¿La corrida terminó por cuota o límite de uso de la cuenta? Textos de
/// Codex («You've hit your usage limit»), Claude Code («usage limit reached»),
/// HTTP 429 y los genéricos de cuota.
pub fn isQuotaExhausted(outcome: *const external_agents.RunOutcome) bool {
    if (outcome.success or outcome.cancelled or outcome.timed_out) return false;
    for ([_][]const u8{ outcome.detail, outcome.declaration }) |text| {
        for ([_][]const u8{ "usage limit", "rate limit", "rate_limit", "quota exceeded", "quota exhausted", "insufficient_quota", "429", "limit reached", "resource_exhausted", "cuota agotada" }) |needle| {
            if (std.ascii.indexOfIgnoreCase(text, needle) != null) return true;
        }
    }
    return false;
}

/// Aviso de rotación: lo recibe el llamador para su evento y el hilo.
pub const RotationNotice = struct {
    cli: []const u8,
    from_id: []const u8,
    from_label: []const u8,
    to_id: []const u8,
    to_label: []const u8,
};
pub const NotifyFn = *const fn (ctx: ?*anyopaque, notice: RotationNotice) void;

pub fn noticeText(a: std.mem.Allocator, notice: RotationNotice) ![]u8 {
    const display = if (specFor(notice.cli)) |s| s.display else notice.cli;
    return std.fmt.allocPrint(a, "La cuenta «{s}» de {s} agotó su cuota; sigue con «{s}».", .{ notice.from_label, display, notice.to_label });
}

/// Corre la CLI con la cuenta `start_id` (o la primera) y, si agota cuota,
/// con la siguiente, hasta probarlas todas. Sin cuentas, corre como siempre.
/// `base_env` es el entorno del hijo ya filtrado (`cliEnvironment`); a cada
/// intento se le añade solo la variable de la cuenta.
pub fn runRotating(
    run: external_agents.RunFn,
    run_ctx: ?*anyopaque,
    a: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    req: external_agents.RunRequest,
    sb: sandbox.Sandbox,
    base_env: ?*const std.process.Environ.Map,
    accounts: []const Account,
    start_id: ?[]const u8,
    notify: ?NotifyFn,
    notify_ctx: ?*anyopaque,
) anyerror!external_agents.RunOutcome {
    if (accounts.len == 0) return run(run_ctx, a, io, task, req, sb);
    const spec = specFor(accounts[0].cli) orelse return error.UnsupportedCli;
    var index: usize = 0;
    if (start_id) |id| {
        for (accounts, 0..) |acc, i| if (std.mem.eql(u8, acc.id, id)) {
            index = i;
        };
    }
    var tried: usize = 0;
    while (true) : (tried += 1) {
        const account = accounts[index];
        var env = if (base_env) |e| try e.clone(a) else std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put(spec.env_var, account.dir);
        var attempt = req;
        attempt.environ_map = &env;
        var outcome = try run(run_ctx, a, io, task, attempt, sb);
        if (!isQuotaExhausted(&outcome) or tried + 1 >= accounts.len) return outcome;
        const next = (index + 1) % accounts.len;
        if (notify) |n| n(notify_ctx, .{ .cli = account.cli, .from_id = account.id, .from_label = account.label, .to_id = accounts[next].id, .to_label = accounts[next].label });
        outcome.deinit(a);
        index = next;
    }
}

/// QA-B 2c: la corrida de una CLI con la cuenta elegida para ella y rotación
/// por cuota, igual en Directo, en la planificación sin clave (H7) y en el
/// despacho de tareas de Orquestado y Colmena. Sin cuenta elegida (o sin
/// catálogo) corre con el login del sistema, como siempre. Si el registro o
/// la selección no se pueden leer se avisa en el log y se usa el login del
/// sistema (mismo criterio que tenía Directo).
pub fn runWithSelected(
    run: external_agents.RunFn,
    run_ctx: ?*anyopaque,
    a: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    req: external_agents.RunRequest,
    sb: sandbox.Sandbox,
    conn: ?db.Connection,
    base_env: ?*const std.process.Environ.Map,
    notify: ?NotifyFn,
    notify_ctx: ?*anyopaque,
) anyerror!external_agents.RunOutcome {
    const rules = try @import("project_rules.zig").loadContext(a, conn, req.worktree);
    defer rules.deinit(a);
    const prompt = if (req.resume_session != null) try a.dupe(u8, req.prompt) else try rules.withCliBlock(a, req.prompt);
    defer a.free(prompt);
    var ruled = req;
    ruled.prompt = prompt;
    const cli = req.meta.cli_id;
    var reg: Registry = .{};
    defer reg.deinit();
    var start: ?[]u8 = null;
    defer if (start) |s| a.free(s);
    if (conn) |c| if (specFor(cli) != null) {
        start = selected(a, c, cli) catch |e| blk: {
            std.log.warn("cuentas de {s}: selección ilegible ({s}); se usa el login del sistema", .{ cli, @errorName(e) });
            break :blk null;
        };
        if (start != null) reg = load(a, c) catch |e| blk: {
            std.log.warn("cuentas de {s}: registro ilegible ({s}); se usa el login del sistema", .{ cli, @errorName(e) });
            break :blk .{};
        };
    };
    const accounts = try reg.forCli(a, cli);
    defer a.free(accounts);
    if (start == null or accounts.len == 0) return run(run_ctx, a, io, task, ruled, sb);
    var own_env: ?std.process.Environ.Map = null;
    defer if (own_env) |*env| env.deinit();
    if (base_env == null) own_env = try @import("platform.zig").environ().createMap(a);
    return runRotating(run, run_ctx, a, io, task, ruled, sb, base_env orelse &own_env.?, accounts, start, notify, notify_ctx);
}

/// JSON para la cabina: CLIs que admiten cuentas, sus cuentas, la elegida y
/// las CLIs que no se ofrecen con el motivo.
pub fn describeJson(a: std.mem.Allocator, conn: db.Connection) ![]u8 {
    var reg = try load(a, conn);
    defer reg.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("clis");
    try js.beginArray();
    for (SUPPORTED) |spec| {
        const chosen = try selected(a, conn, spec.cli);
        defer if (chosen) |c| a.free(c);
        try js.beginObject();
        try js.objectField("cli");
        try js.write(spec.cli);
        try js.objectField("display");
        try js.write(spec.display);
        try js.objectField("envVar");
        try js.write(spec.env_var);
        try js.objectField("selected");
        try js.write(chosen);
        try js.objectField("accounts");
        try js.beginArray();
        for (reg.items()) |acc| {
            if (!std.mem.eql(u8, acc.cli, spec.cli)) continue;
            try js.beginObject();
            try js.objectField("id");
            try js.write(acc.id);
            try js.objectField("label");
            try js.write(acc.label);
            try js.objectField("dir");
            try js.write(acc.dir);
            try js.objectField("loginCommand");
            const cmd = try loginCommand(a, acc);
            defer a.free(cmd);
            try js.write(cmd);
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("unsupported");
    try js.beginArray();
    for (UNSUPPORTED) |u| {
        try js.beginObject();
        try js.objectField("cli");
        try js.write(u.cli);
        try js.objectField("display");
        try js.write(u.display);
        try js.objectField("why");
        try js.write(u.why);
        try js.endObject();
    }
    try js.endArray();
    const pending = try pendingNotice(a, conn);
    defer if (pending) |n| a.free(n);
    try js.objectField("notice");
    try js.write(pending);
    try js.endObject();
    return a.dupe(u8, out.written());
}

// ── Pruebas ─────────────────────────────────────────────────────────────

fn testConn(a: std.mem.Allocator) !db.Connection {
    var conn = try db.Connection.open(a, ":memory:");
    errdefer conn.close();
    try conn.exec("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    return conn;
}

test "T7 cuentas: alta en carpeta propia de DevAgents, Codex con credenciales en archivo" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(data);
    var conn = try testConn(a);
    defer conn.close();
    const first = try add(a, io, conn, data, "codex", "Trabajo");
    defer freeAccount(a, first);
    const second = try add(a, io, conn, data, "codex", "Personal");
    defer freeAccount(a, second);
    try std.testing.expectEqualStrings("codex-1", first.id);
    try std.testing.expectEqualStrings("codex-2", second.id);
    try std.testing.expect(std.mem.startsWith(u8, first.dir, data));
    try std.testing.expect(std.mem.indexOf(u8, first.dir, std.fs.path.sep_str ++ "cli-accounts" ++ std.fs.path.sep_str ++ "codex" ++ std.fs.path.sep_str ++ "codex-1") != null);
    const cfg = try tmp.dir.readFileAlloc(io, "cli-accounts" ++ std.fs.path.sep_str ++ "codex" ++ std.fs.path.sep_str ++ "codex-1" ++ std.fs.path.sep_str ++ "config.toml", a, .limited(4096));
    defer a.free(cfg);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "cli_auth_credentials_store = \"file\"") != null);
    // Nunca la carpeta por defecto de la CLI.
    try std.testing.expect(std.mem.indexOf(u8, first.dir, ".codex") == null);
    const cmd = try loginCommand(a, first);
    defer a.free(cmd);
    const expected = try std.fmt.allocPrint(a, if (@import("builtin").os.tag == .windows) "cmd /d /s /c \"set CODEX_HOME={s}&& codex login\"" else "CODEX_HOME='{s}' codex login", .{first.dir});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, cmd);
    try std.testing.expectError(error.UnsupportedCli, add(a, io, conn, data, "gemini-cli", "x"));
    try std.testing.expectError(error.UnsupportedCli, add(a, io, conn, data, "opencode", "x"));
    try std.testing.expectError(error.InvalidLabel, add(a, io, conn, data, "claude-code", "a&b"));
    const claude = try add(a, io, conn, data, "claude-code", "Equipo");
    defer freeAccount(a, claude);
    const claude_cmd = try loginCommand(a, claude);
    defer a.free(claude_cmd);
    try std.testing.expect(std.mem.indexOf(u8, claude_cmd, if (@import("builtin").os.tag == .windows) "set CLAUDE_CONFIG_DIR=" else "CLAUDE_CONFIG_DIR=") != null);
    try std.testing.expect(std.mem.endsWith(u8, claude_cmd, if (@import("builtin").os.tag == .windows) "&& claude auth login\"" else "' claude auth login"));
    if (@import("builtin").os.tag != .windows) {
        const quoted_cmd = try loginCommand(a, .{ .id = "codex-1", .cli = "codex", .label = "x", .dir = "/tmp/account's folder" });
        defer a.free(quoted_cmd);
        try std.testing.expectEqualStrings("CODEX_HOME='/tmp/account'\\''s folder' codex login", quoted_cmd);
    }
    try select(a, conn, "codex", "codex-2");
    const chosen = (try selected(a, conn, "codex")).?;
    defer a.free(chosen);
    try std.testing.expectEqualStrings("codex-2", chosen);
    try std.testing.expectError(error.UnknownAccount, select(a, conn, "codex", "claude-code-1"));
    try std.testing.expectEqual(RemoveOutcome.deleted, try remove(a, io, conn, data, "codex-2"));
    try std.testing.expect((try selected(a, conn, "codex")) == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "cli-accounts" ++ std.fs.path.sep_str ++ "codex" ++ std.fs.path.sep_str ++ "codex-2", .{}));
    const described = try describeJson(a, conn);
    defer a.free(described);
    try std.testing.expect(std.mem.indexOf(u8, described, "\"Trabajo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, described, "\"Personal\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, described, "\"gemini-cli\"") != null);
}

const QuotaFake = struct {
    seen: [4][]const u8 = undefined,
    calls: usize = 0,
    notices: usize = 0,
    last_notice: [256]u8 = undefined,
    last_len: usize = 0,

    fn run(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: planner.PlannedTask, req: external_agents.RunRequest, _: sandbox.Sandbox) anyerror!external_agents.RunOutcome {
        const self: *QuotaFake = @ptrCast(@alignCast(ctx.?));
        const home = req.environ_map.?.get("CODEX_HOME").?;
        self.seen[self.calls] = if (std.mem.endsWith(u8, home, "codex-1")) "codex-1" else if (std.mem.endsWith(u8, home, "codex-2")) "codex-2" else "otra";
        self.calls += 1;
        const exhausted = std.mem.endsWith(u8, home, "codex-1");
        return .{
            .success = !exhausted,
            .agent_version = try a.dupe(u8, ""),
            .argv_censored = try a.dupe(u8, ""),
            .declaration = try a.dupe(u8, if (exhausted) "" else "hecho"),
            .detail = try a.dupe(u8, if (exhausted) "ERROR: You've hit your usage limit. Try again later." else ""),
            .artifacts = &.{},
        };
    }

    fn notify(ctx: ?*anyopaque, notice: RotationNotice) void {
        const self: *QuotaFake = @ptrCast(@alignCast(ctx.?));
        self.notices += 1;
        const text = std.fmt.bufPrint(&self.last_notice, "{s}->{s}", .{ notice.from_label, notice.to_label }) catch return;
        self.last_len = text.len;
    }
};

test "T7 cuentas: cuota agotada rota a la siguiente cuenta y avisa" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var sb = try sandbox.Sandbox.init(a, "C:\\t7");
    defer sb.deinit();
    const accounts = [_]Account{
        .{ .id = "codex-1", .cli = "codex", .label = "Trabajo", .dir = "E:\\datos\\cli-accounts\\codex\\codex-1" },
        .{ .id = "codex-2", .cli = "codex", .label = "Personal", .dir = "E:\\datos\\cli-accounts\\codex\\codex-2" },
    };
    var base = std.process.Environ.Map.init(a);
    defer base.deinit();
    try base.put("PATH", "C:\\Windows");
    const task = planner.PlannedTask{ .id = "t", .task_type = .programar, .department = "programacion", .description = "x", .contract_fields = &.{}, .depends_on = &.{} };
    const req = external_agents.RunRequest{ .meta = external_agents.metaForProvider("agent:codex").?, .worktree = "C:\\t7", .prompt = "x", .timeout_ms = 1000, .max_turns = 1 };
    var fake = QuotaFake{};
    var outcome = try runRotating(QuotaFake.run, &fake, a, threaded.io(), task, req, sb, &base, &accounts, "codex-1", QuotaFake.notify, &fake);
    defer outcome.deinit(a);
    try std.testing.expect(outcome.success);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqualStrings("codex-1", fake.seen[0]);
    try std.testing.expectEqualStrings("codex-2", fake.seen[1]);
    try std.testing.expectEqual(@as(usize, 1), fake.notices);
    try std.testing.expectEqualStrings("Trabajo->Personal", fake.last_notice[0..fake.last_len]);
    // El entorno base no se modifica (el login del sistema queda intacto).
    try std.testing.expect(base.get("CODEX_HOME") == null);
    // Empezando por la que no tiene cuota no se rota.
    var fake2 = QuotaFake{};
    var direct = try runRotating(QuotaFake.run, &fake2, a, threaded.io(), task, req, sb, &base, &accounts, "codex-2", QuotaFake.notify, &fake2);
    defer direct.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fake2.calls);
    try std.testing.expectEqual(@as(usize, 0), fake2.notices);
    const text = try noticeText(a, .{ .cli = "codex", .from_id = "codex-1", .from_label = "Trabajo", .to_id = "codex-2", .to_label = "Personal" });
    defer a.free(text);
    try std.testing.expectEqualStrings("La cuenta «Trabajo» de Codex agotó su cuota; sigue con «Personal».", text);
}

extern "kernel32" fn SetFileAttributesW(name: [*:0]const u16, attrs: u32) callconv(.winapi) i32;
const CreateFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) std.os.windows.HANDLE;
}.CreateFileW else @import("providers").posix_files.CreateFileW;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(h: std.os.windows.HANDLE) callconv(.winapi) i32;
}.CloseHandle else @import("providers").posix_files.CloseHandle;

test "QA-B 6: quitar una cuenta no la deja a medias y dice si su carpeta quedó en disco" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(data);
    var conn = try testConn(a);
    defer conn.close();

    // 1) Carpeta en uso (un archivo abierto sin compartir): no se quita nada.
    const acc = try add(a, io, conn, data, "codex", "Ocupada");
    defer freeAccount(a, acc);
    const held_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "abierto.txt", .{acc.dir});
    defer a.free(held_path);
    const held_w = try std.unicode.utf8ToUtf16LeAllocZ(a, held_path);
    defer a.free(held_w);
    const held = CreateFileW(held_w, 0x40000000, 0, null, 2, 0x80, null);
    try std.testing.expect(held != std.os.windows.INVALID_HANDLE_VALUE);
    const busy = remove(a, io, conn, data, acc.id);
    _ = CloseHandle(held);
    try std.testing.expectError(error.AccountFolderBusy, busy);
    {
        var reg = try load(a, conn);
        defer reg.deinit();
        try std.testing.expect(reg.find(acc.id) != null);
    }
    try tmp.dir.access(io, "cli-accounts\\codex\\codex-1\\config.toml", .{});

    // 2) Carpeta que no se deja borrar entera (archivo de solo lectura): la
    //    cuenta se quita del todo y el aviso dice dónde quedó la carpeta.
    const ro_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "solo-lectura.txt", .{acc.dir});
    defer a.free(ro_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ro_path, .data = "x" });
    const ro_w = try std.unicode.utf8ToUtf16LeAllocZ(a, ro_path);
    defer a.free(ro_w);
    try std.testing.expect(SetFileAttributesW(ro_w, 0x1) != 0);
    const outcome = try remove(a, io, conn, data, acc.id);
    const grave = try std.fmt.allocPrint(a, "{s}.quitando", .{acc.dir});
    defer a.free(grave);
    if (outcome == .left_behind) {
        const text = (try pendingNotice(a, conn)).?;
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, grave) != null);
        const described = try describeJson(a, conn);
        defer a.free(described);
        try std.testing.expect(std.mem.indexOf(u8, described, "\"notice\":\"La cuenta") != null);
        const left = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "solo-lectura.txt", .{grave});
        defer a.free(left);
        const left_w = try std.unicode.utf8ToUtf16LeAllocZ(a, left);
        defer a.free(left_w);
        _ = SetFileAttributesW(left_w, 0x80);
    } else {
        // Este volumen borra archivos de solo lectura: al menos la baja fue
        // completa y sin aviso.
        try std.testing.expectEqual(RemoveOutcome.deleted, outcome);
        try std.testing.expect((try pendingNotice(a, conn)) == null);
    }
    std.debug.print("QA-B 6: carpeta con archivo de solo lectura -> {s}\n", .{@tagName(outcome)});
    {
        var reg = try load(a, conn);
        defer reg.deinit();
        try std.testing.expect(reg.find(acc.id) == null);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "cli-accounts\\codex\\codex-1", .{}));

    // 3) Una carpeta registrada con `..` que sale de cli-accounts no se toca.
    try tmp.dir.createDirPath(io, "fuera");
    try tmp.dir.writeFile(io, .{ .sub_path = "fuera\\tesoro.txt", .data = "no borrar" });
    const hostile_dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "cli-accounts" ++ std.fs.path.sep_str ++ ".." ++ std.fs.path.sep_str ++ "fuera", .{data});
    defer a.free(hostile_dir);
    const hostile = [_]Account{.{ .id = "codex-9", .cli = "codex", .label = "Trampa", .dir = hostile_dir }};
    try store(a, conn, &hostile);
    try std.testing.expectEqual(RemoveOutcome.kept_outside, try remove(a, io, conn, data, "codex-9"));
    try tmp.dir.access(io, "fuera\\tesoro.txt", .{});
    const text = (try pendingNotice(a, conn)).?;
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "fuera de la carpeta de cuentas") != null);
    try std.testing.expect(hasDotComponent("C:\\d\\cli-accounts\\..\\x"));
    try std.testing.expect(hasDotComponent("C:\\d\\cli-accounts\\.. \\x"));
    try std.testing.expect(!hasDotComponent("C:\\d\\cli-accounts\\codex\\codex-1"));
}

test "T12 B3: quitar una cuenta nunca borra la carpeta de cuentas ni la de una CLI aunque el registro lo diga" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T12 B3: las carpetas de cuentas usan rutas de Windows (validDataDir); omitida en Linux");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(data);
    var conn = try testConn(a);
    defer conn.close();
    const keep = try add(a, io, conn, data, "codex", "Sigue");
    defer freeAccount(a, keep);
    const base_dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "cli-accounts", .{data});
    defer a.free(base_dir);
    const base_slash = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "cli-accounts" ++ std.fs.path.sep_str ++ "", .{data});
    defer a.free(base_slash);
    const cli_dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "cli-accounts" ++ std.fs.path.sep_str ++ "codex", .{data});
    defer a.free(cli_dir);
    const other_id = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "cli-accounts" ++ std.fs.path.sep_str ++ "codex" ++ std.fs.path.sep_str ++ "codex-1", .{data});
    defer a.free(other_id);
    for ([_]Account{
        .{ .id = "codex-7", .cli = "codex", .label = "Base", .dir = base_dir },
        .{ .id = "codex-7", .cli = "codex", .label = "Base", .dir = base_slash },
        .{ .id = "codex-7", .cli = "codex", .label = "CLI", .dir = cli_dir },
        // Carpeta de OTRA cuenta registrada bajo este id.
        .{ .id = "codex-7", .cli = "codex", .label = "Ajena", .dir = other_id },
        // CLI no admitida.
        .{ .id = "x-1", .cli = "otra", .label = "Rara", .dir = cli_dir },
    }) |hostile| {
        const accounts = [_]Account{ keep, hostile };
        try store(a, conn, &accounts);
        try std.testing.expectEqual(RemoveOutcome.kept_outside, try remove(a, io, conn, data, hostile.id));
        try tmp.dir.access(io, "cli-accounts\\codex\\codex-1\\config.toml", .{});
    }
    // La forma exacta sí se borra.
    const accounts = [_]Account{keep};
    try store(a, conn, &accounts);
    try std.testing.expectEqual(RemoveOutcome.deleted, try remove(a, io, conn, data, keep.id));
}

test "T12 B3: carpetas y etiquetas con $ o acento grave se rechazan (PowerShell los expande)" {
    try std.testing.expect(validDataDir(if (@import("builtin").os.tag == .windows) "C:\\datos\\DevAgents" else "/datos/DevAgents"));
    try std.testing.expect(!validDataDir("C:\\datos\\$(calc)"));
    try std.testing.expect(!validDataDir("C:\\datos\\$env:USERPROFILE"));
    try std.testing.expect(!validDataDir("C:\\datos\\a`b"));
    try std.testing.expect(validLabel("Trabajo 2"));
    try std.testing.expect(!validLabel("pago$"));
    try std.testing.expect(!validLabel("a`b"));
    const acc = Account{ .id = "codex-1", .cli = "codex", .label = "x", .dir = "C:\\datos\\$(calc)\\cli-accounts\\codex\\codex-1" };
    try std.testing.expectError(error.InvalidDataDir, loginCommand(std.testing.allocator, acc));
}
