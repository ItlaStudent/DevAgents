//!. Child context policy; never reads authentication or memory files.
const std = @import("std");
const db = @import("db.zig");
const confined = @import("confined_fs.zig");
const policy = @import("external_cli_policy.zig");

pub const SETTING = "external_agent_inherit_personal_context";

/// 10-nov (USUARIO-NUEVO A3): frase llana para cada motivo por el que un
/// agente externo no arranca. Ningún nombre de error de Zig llega crudo a la
/// conversación; un error sin frase propia se dice como «no pudo arrancar» y
/// el nombre va entre paréntesis como dato técnico, al final.
pub fn plainStartFailure(a: std.mem.Allocator, display: []const u8, e: anyerror) ![]u8 {
    return switch (e) {
        error.PersonalContextIsolationUnavailable => std.fmt.allocPrint(a, "{s} no arrancó porque tienes instrucciones personales (AGENTS.md en tu carpeta de {s}) y DevAgents, por defecto, no se las pasa a los agentes externos. Pulsa «Heredar mis instrucciones» para usar tu configuración tal como funciona en tu terminal, o «Ahora no» para dejarlo así; puedes cambiarlo cuando quieras en Configuración › Agentes externos.", .{ display, display }),
        error.CustomOpenCodeContextUnavailable => std.fmt.allocPrint(a, "{s} no arrancó: tu carpeta de configuración propia (OPENCODE_CONFIG_DIR) declara habilidades o MCP que se perderían al aislar tus instrucciones personales. Pulsa «Heredar mis instrucciones» para usar tu configuración completa, o muévelas al perfil estándar de OpenCode.", .{display}),
        error.OpenCodeProfileInspectionFailed => std.fmt.allocPrint(a, "{s} no arrancó: no se pudo leer tu carpeta de configuración (OPENCODE_CONFIG_DIR) para comprobar qué hereda. Revisa que exista, que su opencode.json sea válido y que no sea enorme, o pulsa «Heredar mis instrucciones».", .{display}),
        error.ContextDirectoryContaminated => std.fmt.allocPrint(a, "{s} no arrancó: la carpeta aislada que DevAgents le prepara contiene un AGENTS.md que no puso DevAgents. Bórralo de esa carpeta o pulsa «Heredar mis instrucciones».", .{display}),
        error.InvalidOpenCodeConfigContent => std.fmt.allocPrint(a, "{s} no arrancó: tu variable OPENCODE_CONFIG_CONTENT no es un JSON válido, así que DevAgents no puede añadirle la regla que le impide ejecutar comandos sin permiso. Corrígela o elige el permiso Auto.", .{display}),
        error.OpenCodePlanningConfigUnavailable => std.fmt.allocPrint(a, "{s} no planificó: no se pudo inspeccionar su configuración global JSON/JSONC para desactivar todos los servidores MCP. Revisa los archivos de configuración antes de reintentar.", .{display}),
        error.ApiBillingForbidden => std.fmt.allocPrint(a, "{s} cobraría por API (su sesión usa una clave de API) y DevAgents solo lo usa con tu suscripción. Inicia sesión con tu cuenta en {s} o elige otro modelo.", .{ display, display }),
        error.NotLoggedIn => std.fmt.allocPrint(a, "{s} no tiene la sesión iniciada. Ábrelo una vez en tu terminal, inicia sesión y vuelve a intentarlo.", .{display}),
        error.ExeNotResolved, error.FileNotFound => std.fmt.allocPrint(a, "No se encontró el ejecutable de {s}. Pulsa «Volver a detectar» en Configuración › Agentes externos.", .{display}),
        error.CliWritableByOthers, error.CliUntrustedOwner, error.CliPermissionsUnavailable, error.UntrustedCliRoot, error.CliReparseOrAlias, error.CodexSandboxUnavailable => std.fmt.allocPrint(a, "DevAgents no lanzó {s}: {s}. En Configuración › Agentes externos verás qué instalación se usó y por qué se descartaron las otras.", .{ display, policy.rejectionReason(e) }),
        error.TestRealCliForbidden => std.fmt.allocPrint(a, "La suite prohíbe lanzar {s}: el ejecutable está fuera de la carpeta de dobles de prueba.", .{display}),
        error.Timeout => std.fmt.allocPrint(a, "{s} superó el tiempo máximo.", .{display}),
        // T2d-D5 (12-nov): estos llegan DESPUÉS de que el agente trabajó; decir
        // «no pudo arrancar» hacía creer que no había tocado nada.
        error.WorkspacePermissionsRestoreFailed => std.fmt.allocPrint(a, "{s} terminó, pero DevAgents no pudo devolver los permisos de la carpeta del proyecto a como estaban antes de lanzarlo, así que la orden queda como fallida. Lo que escribió sigue en tu proyecto: revísalo en «Cambios».", .{display}),
        error.ProcessTreeStillActive => std.fmt.allocPrint(a, "{s} terminó, pero dejó procesos en marcha más de 15 s y DevAgents no restauró a ciegas los permisos de la carpeta del proyecto. Lo que escribió sigue en tu proyecto: revísalo en «Cambios».", .{display}),
        else => std.fmt.allocPrint(a, "{s} no pudo arrancar (detalle técnico: {s}).", .{ display, @errorName(e) }),
    };
}

test "USUARIO-NUEVO A3: ningún motivo de arranque llega como nombre de error" {
    const a = std.testing.allocator;
    for ([_]anyerror{ error.PersonalContextIsolationUnavailable, error.CustomOpenCodeContextUnavailable, error.OpenCodeProfileInspectionFailed, error.ContextDirectoryContaminated, error.InvalidOpenCodeConfigContent, error.ApiBillingForbidden, error.NotLoggedIn, error.ExeNotResolved, error.CliWritableByOthers, error.WorkspacePermissionsRestoreFailed, error.ProcessTreeStillActive }) |e| {
        const text = try plainStartFailure(a, "Codex", e);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, @errorName(e)) == null);
    }
    const isolation = try plainStartFailure(a, "Codex", error.PersonalContextIsolationUnavailable);
    defer a.free(isolation);
    try std.testing.expect(std.mem.indexOf(u8, isolation, "«Heredar mis instrucciones»") != null);
    try std.testing.expect(std.mem.indexOf(u8, isolation, "«Ahora no»") != null);
    // T2d-D5: un fallo tras el trabajo no se dice como «no pudo arrancar».
    const restore = try plainStartFailure(a, "Codex", error.WorkspacePermissionsRestoreFailed);
    defer a.free(restore);
    try std.testing.expect(std.mem.indexOf(u8, restore, "no pudo arrancar") == null);
    try std.testing.expect(std.mem.indexOf(u8, restore, "«Cambios»") != null);
}

pub fn load(conn: db.Connection) !bool {
    const q = try conn.prepare("SELECT value FROM settings WHERE key='external_agent_inherit_personal_context'");
    defer conn.finalize(q);
    const rc = db.c.sqlite3_step(q);
    if (rc == db.c.SQLITE_DONE) return false;
    if (rc != db.c.SQLITE_ROW) return error.ContextSettingReadFailed;
    const ptr = db.c.sqlite3_column_text(q, 0) orelse return error.InvalidContextSetting;
    const value = std.mem.span(ptr);
    if (std.mem.eql(u8, value, "false")) return false;
    if (std.mem.eql(u8, value, "true")) return true;
    return error.InvalidContextSetting;
}

/// Keep the authenticated home, MCP configuration and skill directories. Git
/// routing variables from the orchestrator must never select a different tree.
pub fn environment(a: std.mem.Allocator, io: std.Io, parent: *const std.process.Environ.Map, cli: []const u8, root: []const u8, inherit: bool) !std.process.Environ.Map {
    // 10-nov (USUARIO-NUEVO A1): ninguna CLI hereda claves ni desvíos de
    // facturación del anfitrión (antes, solo Codex).
    var child = try policy.cliEnvironment(a, parent, cli);
    errdefer child.deinit();
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT" }) |key| _ = child.swapRemove(key);
    // Git explicitly ignores a ceiling equal to cwd. The parent is the
    // directory it must not enter (verified with the nested real-git probe).
    try child.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root) orelse root);
    if (!inherit and std.mem.eql(u8, cli, "claude-code"))
        try child.put("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1");
    if (!inherit and std.mem.eql(u8, cli, "opencode")) {
        // Only a profile with capabilities would lose skills/MCP when replaced.
        // Inspect configuration and skill names, never credentials or memory.
        if (parent.get("OPENCODE_CONFIG_DIR")) |custom| {
            const custom_path = try std.fs.path.resolve(a, &.{ root, custom });
            defer a.free(custom_path);
            const capabilities = openCodeCapabilities(a, io, custom_path) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return error.OpenCodeProfileInspectionFailed,
            };
            if (capabilities) return error.CustomOpenCodeContextUnavailable;
        }
        // Verified separately from DISABLE_CLAUDE_CODE_SKILLS in 1.18.25.
        try child.put("OPENCODE_DISABLE_CLAUDE_CODE_PROMPT", "1");
        const dir = try openCodeContextDir(a, root);
        defer a.free(dir);
        try child.put("OPENCODE_CONFIG_DIR", dir);
    }
    return child;
}

/// QA primerizo (11-nov): OpenCode instala sus dependencias (`node_modules`,
/// ~60 MB) en su carpeta de configuración. Vivía en `<proyecto>\.devagents\`
/// y quedaba dentro de la carpeta del cliente aunque la orden fallara. Ahora es
/// UNA carpeta compartida dentro de los datos de DevAgents (no se reinstala en
/// cada orden); solo si no se puede resolver la carpeta de datos se usa la
/// antigua, para no lanzar con el perfil personal.
pub fn openCodeContextDir(a: std.mem.Allocator, root: []const u8) ![]u8 {
    // Las pruebas nunca escriben en la carpeta de datos real del usuario.
    if (@import("builtin").is_test) return openCodeContextDirFrom(a, null, root);
    const paths = @import("paths.zig");
    const resolved = paths.resolveDataDir(a, null) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return openCodeContextDirFrom(a, null, root),
    };
    defer a.free(resolved.dir);
    return openCodeContextDirFrom(a, resolved.dir, root);
}

/// `resolveWindows`: un override con «/» no debe romper la comparación canónica de confined_fs.
pub fn openCodeContextDirFrom(a: std.mem.Allocator, data_dir: ?[]const u8, root: []const u8) ![]u8 {
    if (data_dir) |dir| return std.fs.path.resolve(a, &.{ dir, "external-context-opencode" });
    return std.fs.path.join(a, &.{ root, ".devagents", "external-context-opencode" });
}

test "QA primerizo: la configuración aislada de OpenCode no vive en el proyecto del cliente" {
    const a = std.testing.allocator;
    const dir = try openCodeContextDirFrom(a, (if (@import("builtin").os.tag == .windows) "C:/datos/DevAgents-Angel" else "/datos/DevAgents-Angel"), (if (@import("builtin").os.tag == .windows) "C:\\proyecto-cliente" else "/proyecto-cliente"));
    defer a.free(dir);
    try std.testing.expectEqualStrings((if (@import("builtin").os.tag == .windows) "C:\\datos\\DevAgents-Angel\\external-context-opencode" else "/datos/DevAgents-Angel/external-context-opencode"), dir);
    const fallback = try openCodeContextDirFrom(a, null, (if (@import("builtin").os.tag == .windows) "C:\\proyecto-cliente" else "/proyecto-cliente"));
    defer a.free(fallback);
    try std.testing.expect(std.mem.endsWith(u8, fallback, ".devagents" ++ std.fs.path.sep_str ++ "external-context-opencode"));
}

/// QA primerizo (10-nov): niega la terminal a OpenCode mediante su
/// configuración en línea. Con `--auto`, OpenCode aprueba todo salvo lo
/// denegado explícitamente; `permission.bash = "deny"` lo deja editando pero
/// sin ejecutar comandos (verificado en vivo con 1.19.4: con la regla, «NO
/// PUDE» y ningún archivo creado por el comando; sin ella, lo ejecuta). Si el
/// usuario ya trae `OPENCODE_CONFIG_CONTENT`, se conserva y solo se fija la
/// regla; si no es JSON de objeto, se rechaza antes que lanzar sin la regla.
pub fn denyOpenCodeShell(a: std.mem.Allocator, child: *std.process.Environ.Map) !void {
    return denyOpenCodePermissions(a, child, &.{"bash"}, false);
}

/// T12 A2: OpenCode no tiene modo de solo lectura. Para planificar se le
/// niegan por permisos la terminal, la edición (cubre escribir y parchear) y
/// la web; con `--auto` lo denegado nunca se aprueba. Misma fusión que
/// `denyOpenCodeShell` con la configuración en línea del usuario.
pub const OPENCODE_READ_ONLY_DENIED = [_][]const u8{ "bash", "edit", "webfetch" };

pub fn denyOpenCodeWrites(a: std.mem.Allocator, child: *std.process.Environ.Map) !void {
    return denyOpenCodePermissions(a, child, &OPENCODE_READ_ONLY_DENIED, true);
}

fn denyOpenCodePermissions(a: std.mem.Allocator, child: *std.process.Environ.Map, denied: []const []const u8, disable_mcp: bool) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var root: std.json.Value = .{ .object = .empty };
    if (child.get("OPENCODE_CONFIG_CONTENT")) |existing| {
        if (std.mem.trim(u8, existing, " \t\r\n").len > 0) {
            root = std.json.parseFromSliceLeaky(std.json.Value, aa, existing, .{}) catch return error.InvalidOpenCodeConfigContent;
            if (root != .object) return error.InvalidOpenCodeConfigContent;
        }
    }
    var perm: std.json.Value = .{ .object = .empty };
    if (root.object.get("permission")) |p| {
        if (p == .object) perm = p;
    }
    for (denied) |key| {
        _ = perm.object.orderedRemove(key);
        try perm.object.put(aa, key, .{ .string = "deny" });
    }
    try root.object.put(aa, "permission", perm);
    if (disable_mcp) {
        // T12B M-3: al planificar no basta con los permisos globales: ningún
        // servidor MCP puede colarse (sus herramientas no son de solo lectura)
        // y un permiso por agente no debe reabrir lo denegado.
        var mcp: std.json.Value = .{ .object = .empty };
        if (root.object.get("mcp")) |existing| try disableMcpNames(aa, &mcp, existing);
        var threaded = std.Io.Threaded.init(aa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const config_home = nonempty(child.get("XDG_CONFIG_HOME")) orelse blk: {
            const home = if (@import("builtin").os.tag == .windows)
                nonempty(child.get("USERPROFILE")) orelse nonempty(child.get("HOME"))
            else
                nonempty(child.get("HOME")) orelse nonempty(child.get("USERPROFILE"));
            break :blk try std.fs.path.join(aa, &.{ home orelse return error.OpenCodePlanningConfigUnavailable, ".config" });
        };
        try disableMcpDirectory(aa, io, &mcp, try std.fs.path.join(aa, &.{ config_home, "opencode" }));
        if (child.get("OPENCODE_CONFIG")) |path| try disableMcpFile(aa, io, &mcp, path);
        if (child.get("OPENCODE_CONFIG_DIR")) |path| try disableMcpDirectory(aa, io, &mcp, path);
        try root.object.put(aa, "mcp", mcp);
        try child.put("OPENCODE_DISABLE_PROJECT_CONFIG", "1");
        if (root.object.getPtr("agent")) |agents| {
            if (agents.* == .object) {
                var it = agents.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    var agent_perm: std.json.Value = .{ .object = .empty };
                    if (entry.value_ptr.object.get("permission")) |p| {
                        if (p == .object) agent_perm = p;
                    }
                    for (denied) |key| {
                        _ = agent_perm.object.orderedRemove(key);
                        try agent_perm.object.put(aa, key, .{ .string = "deny" });
                    }
                    try entry.value_ptr.object.put(aa, "permission", agent_perm);
                }
            }
        }
    }
    const text = try std.json.Stringify.valueAlloc(a, root, .{});
    defer a.free(text);
    try child.put("OPENCODE_CONFIG_CONTENT", text);
}

fn nonempty(value: ?[]const u8) ?[]const u8 {
    return if (value) |v| (if (v.len > 0) v else null) else null;
}

fn disableMcpNames(a: std.mem.Allocator, target: *std.json.Value, source: std.json.Value) !void {
    if (source != .object) return error.InvalidOpenCodeConfigContent;
    var names = source.object.iterator();
    while (names.next()) |entry| {
        var disabled: std.json.Value = .{ .object = .empty };
        try disabled.object.put(a, "enabled", .{ .bool = false });
        try target.object.put(a, entry.key_ptr.*, disabled);
    }
}

fn disableMcpDirectory(a: std.mem.Allocator, io: std.Io, target: *std.json.Value, dir: []const u8) !void {
    for ([_][]const u8{ "opencode.json", "opencode.jsonc" }) |name|
        try disableMcpFile(a, io, target, try std.fs.path.join(a, &.{ dir, name }));
}

fn disableMcpFile(a: std.mem.Allocator, io: std.Io, target: *std.json.Value, path: []const u8) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(OPENCODE_CONFIG_MAX_BYTES)) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return error.OpenCodePlanningConfigUnavailable,
    };
    normalizeJsonc(text) catch return error.OpenCodePlanningConfigUnavailable;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.InvalidOpenCodeConfigContent;
    if (parsed != .object) return error.InvalidOpenCodeConfigContent;
    if (parsed.object.get("mcp")) |mcp| try disableMcpNames(a, target, mcp);
}

test "QA primerizo: OpenCode sin terminal conserva la configuración en línea del usuario" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try denyOpenCodeShell(a, &env);
    try std.testing.expectEqualStrings("{\"permission\":{\"bash\":\"deny\"}}", env.get("OPENCODE_CONFIG_CONTENT").?);
    try env.put("OPENCODE_CONFIG_CONTENT", "{\"mcp\":{\"x\":{\"type\":\"local\"}},\"permission\":{\"edit\":\"allow\",\"bash\":\"allow\"}}");
    try denyOpenCodeShell(a, &env);
    const merged = env.get("OPENCODE_CONFIG_CONTENT").?;
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"bash\":\"deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"edit\":\"allow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"mcp\"") != null);
    try env.put("OPENCODE_CONFIG_CONTENT", "no es json");
    try std.testing.expectError(error.InvalidOpenCodeConfigContent, denyOpenCodeShell(a, &env));
}

test "T12 A2: al planificar OpenCode recibe edición, terminal y web denegadas aunque el usuario las permita" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(home);
    try std.testing.expectError(error.OpenCodePlanningConfigUnavailable, denyOpenCodeWrites(a, &env));
    try env.put("XDG_CONFIG_HOME", home);
    try denyOpenCodeWrites(a, &env);
    try std.testing.expectEqualStrings("{\"permission\":{\"bash\":\"deny\",\"edit\":\"deny\",\"webfetch\":\"deny\"},\"mcp\":{}}", env.get("OPENCODE_CONFIG_CONTENT").?);
    try env.put("OPENCODE_CONFIG_CONTENT", "{\"mcp\":{\"x\":{\"type\":\"local\"}},\"permission\":{\"edit\":\"allow\",\"bash\":\"allow\",\"webfetch\":\"allow\",\"read\":\"allow\"},\"agent\":{\"build\":{\"permission\":{\"edit\":\"allow\",\"read\":\"allow\"}}}}");
    try denyOpenCodeWrites(a, &env);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, env.get("OPENCODE_CONFIG_CONTENT").?, .{});
    defer parsed.deinit();
    const perm = parsed.value.object.get("permission").?.object;
    for (OPENCODE_READ_ONLY_DENIED) |key| try std.testing.expectEqualStrings("deny", perm.get(key).?.string);
    try std.testing.expectEqualStrings("allow", perm.get("read").?.string);
    // T12B M-3: sin servidores MCP y sin que un permiso por agente reabra lo denegado.
    try std.testing.expect(!parsed.value.object.get("mcp").?.object.get("x").?.object.get("enabled").?.bool);
    const agent_perm = parsed.value.object.get("agent").?.object.get("build").?.object.get("permission").?.object;
    for (OPENCODE_READ_ONLY_DENIED) |key| try std.testing.expectEqualStrings("deny", agent_perm.get(key).?.string);
    try std.testing.expectEqualStrings("allow", agent_perm.get("read").?.string);
}

const OPENCODE_CONFIG_MAX_BYTES = 256 * 1024;

test "VG1 M-3: global JSONC and explicit OpenCode configs disable every MCP name" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "opencode", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "opencode/opencode.json", .data = "{\"mcp\":{\"global\":{}}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "opencode/opencode.jsonc", .data = "{/* comment */\"mcp\":{\"jsonc\":{},},// line\n}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "explicit.json", .data = "{\"mcp\":{\"explicit\":{}}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "opencode.json", .data = "{\"mcp\":{\"custom\":{}}}" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const explicit = try std.fs.path.join(a, &.{ dir, "explicit.json" });
    defer a.free(explicit);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", dir);
    try env.put("OPENCODE_CONFIG", explicit);
    try env.put("OPENCODE_CONFIG_DIR", dir);
    try env.put("OPENCODE_CONFIG_CONTENT", "{\"mcp\":{\"inline\":{}}}");
    try denyOpenCodeWrites(a, &env);
    try std.testing.expectEqualStrings("1", env.get("OPENCODE_DISABLE_PROJECT_CONFIG").?);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, env.get("OPENCODE_CONFIG_CONTENT").?, .{});
    defer parsed.deinit();
    const mcp = parsed.value.object.get("mcp").?.object;
    for ([_][]const u8{ "global", "jsonc", "explicit", "custom", "inline" }) |name|
        try std.testing.expect(!mcp.get(name).?.object.get("enabled").?.bool);
    try tmp.dir.writeFile(io, .{ .sub_path = "explicit.json", .data = "{/* unterminated" });
    try std.testing.expectError(error.OpenCodePlanningConfigUnavailable, denyOpenCodeWrites(a, &env));
}
const OPENCODE_SKILL_MAX_ENTRIES = 1024;
const OPENCODE_SKILL_MAX_DEPTH = 16;

/// Installed 1.18.25 loads only these two files from OPENCODE_CONFIG_DIR.
/// Do not resolve {env:...}/{file:...}, follow URLs, or open auth/skill contents.
fn openCodeCapabilities(a: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    var root = confined.Root.init(a, path) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer root.deinit();
    for ([_][]const u8{ "opencode.json", "opencode.jsonc" }) |name| {
        const text = root.readFileAlloc(a, name, OPENCODE_CONFIG_MAX_BYTES) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        defer a.free(text);
        try normalizeJsonc(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidOpenCodeProfile;
        if (parsed.value.object.get("mcp")) |mcp| {
            if (mcp != .object) return error.InvalidOpenCodeProfile;
            if (mcp.object.count() > 0) return true;
        }
        if (parsed.value.object.get("skills")) |skills| {
            if (skills != .object) return error.InvalidOpenCodeProfile;
            for ([_][]const u8{ "paths", "urls" }) |key| if (skills.object.get(key)) |value| {
                if (value != .array) return error.InvalidOpenCodeProfile;
                if (value.array.items.len > 0) return true;
            };
        }
    }
    var remaining: usize = OPENCODE_SKILL_MAX_ENTRIES;
    for ([_][]const u8{ "skill", "skills" }) |name|
        if (try openCodeSkillNames(a, io, &root, name, 0, &remaining)) return true;
    return false;
}

fn openCodeSkillNames(a: std.mem.Allocator, io: std.Io, root: *const confined.Root, relative: []const u8, depth: usize, remaining: *usize) anyerror!bool {
    if (depth > OPENCODE_SKILL_MAX_DEPTH) return error.OpenCodeSkillScanLimit;
    const file = root.open(relative) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .directory) return false;
    var iterator = (std.Io.Dir{ .handle = file.handle }).iterate();
    while (try iterator.next(io)) |entry| {
        if (remaining.* == 0) return error.OpenCodeSkillScanLimit;
        remaining.* -= 1;
        if (entry.kind != .directory and std.mem.eql(u8, entry.name, "SKILL.md")) return true;
        if (entry.kind == .directory or entry.kind == .sym_link) {
            const child = try std.fs.path.join(a, &.{ relative, entry.name });
            defer a.free(child);
            if (try openCodeSkillNames(a, io, root, child, depth + 1, remaining)) return true;
        }
    }
    return false;
}

/// Erase JSONC comments and trailing commas in place, preserving strings and
/// rejecting unterminated comments; std.json validates the remaining syntax.
fn normalizeJsonc(text: []u8) !void {
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) @memset(text[0..3], ' ');
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
        } else if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n' and text[i] != '\r') : (i += 1) text[i] = ' ';
            continue;
        } else if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
            text[i] = ' ';
            text[i + 1] = ' ';
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) : (i += 1) text[i] = ' ';
            if (i + 1 >= text.len) return error.InvalidOpenCodeProfile;
            text[i] = ' ';
            text[i + 1] = ' ';
            i += 2;
            continue;
        }
        i += 1;
    }
    i = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
        } else if (text[i] == ',') {
            var next = i + 1;
            while (next < text.len and std.ascii.isWhitespace(text[next])) : (next += 1) {}
            if (next < text.len and (text[next] == '}' or text[next] == ']')) text[i] = ' ';
        }
    }
}

pub fn appendCodexArgs(a: std.mem.Allocator, argv: *std.ArrayList([]const u8), inherit: bool) !void {
    if (!inherit) try argv.appendSlice(a, &.{ "-c", "project_doc_max_bytes=0", "-c", "memories.use_memories=false", "-c", "memories.generate_memories=false", "-c", "developer_instructions=\"\"" });
}

/// --settings and its schema are in the installed Claude 2.1.283 help/bundle.
/// Exclusion affects User/Project/Local memory, never skills or MCP settings.
pub fn claudeSettings(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const base = env.get("USERPROFILE") orelse env.get("HOME") orelse return error.InvalidEnvironment;
    const default_dir = try std.fs.path.join(a, &.{ base, ".claude" });
    defer a.free(default_dir);
    const dir = env.get("CLAUDE_CONFIG_DIR") orelse default_dir;
    const md = try std.fs.path.join(a, &.{ dir, "CLAUDE.md" });
    defer a.free(md);
    const rules = try std.fs.path.join(a, &.{ dir, "rules", "**" });
    defer a.free(rules);
    return std.json.Stringify.valueAlloc(a, .{ .autoMemoryEnabled = false, .claudeMdExcludes = .{ md, rules } }, .{});
}

/// Codex 0.144.4 loads codex-home/src/instructions independently of project
/// docs. No selective switch exists in installed help. Do not silently launch
/// with forbidden globals or move its authenticated CODEX_HOME with existing SID/ACL checks.
pub fn checkCodexGlobals(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    const home = env.get("CODEX_HOME") orelse return error.InvalidEnvironment;
    for ([_][]const u8{ "AGENTS.override.md", "AGENTS.md" }) |name| {
        const path = try std.fs.path.join(a, &.{ home, name });
        defer a.free(path);
        _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        return error.PersonalContextIsolationUnavailable;
    }
}

pub fn hasGit(a: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const git = try std.fs.path.join(a, &.{ path, ".git" });
    defer a.free(git);
    _ = std.Io.Dir.cwd().statFile(io, git, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    return true;
}

fn repository(a: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    var path = root;
    while (true) {
        if (try hasGit(a, io, path)) return path;
        path = std.fs.path.dirname(path) orelse return root;
    }
}

/// Codex's doc budget cannot exclude only its global AGENTS. Disable discovery
/// and replay the project chain explicitly. OpenCode disables Claude prompts
/// independently of Claude skills, so replay that project's las reglas del repositorio as well.
pub fn projectPrompt(a: std.mem.Allocator, io: std.Io, root: []const u8, prompt: []const u8) ![]u8 {
    const top = try repository(a, io, root);
    var chain = std.ArrayList([]const u8).empty;
    defer chain.deinit(a);
    var current = root;
    while (true) {
        try chain.append(a, current);
        if (std.ascii.eqlIgnoreCase(current, top)) break;
        current = std.fs.path.dirname(current) orelse return error.InvalidProjectRoot;
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, prompt);
    var count = chain.items.len;
    while (count > 0) {
        count -= 1;
        var safe = try confined.Root.init(a, chain.items[count]);
        defer safe.deinit();
        var override_loaded = false;
        for ([_][]const u8{ "AGENTS.override.md", "AGENTS.md", "CLAUDE.md" }) |name| {
            if (override_loaded and std.mem.eql(u8, name, "AGENTS.md")) continue;
            const file = safe.open(name) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.size > 128 * 1024 or out.items.len + stat.size > 512 * 1024) return error.ProjectInstructionsTooLarge;
            const text = try a.alloc(u8, @intCast(stat.size));
            defer a.free(text);
            if (try file.readPositionalAll(io, text, 0) != text.len) return error.ProjectInstructionsChanged;
            try out.appendSlice(a, "\n\nProject instructions from ");
            try out.appendSlice(a, chain.items[count]);
            try out.appendSlice(a, "/");
            try out.appendSlice(a, name);
            try out.appendSlice(a, ":\n");
            try out.appendSlice(a, text);
            if (std.mem.eql(u8, name, "AGENTS.override.md")) override_loaded = true;
        }
    }
    return out.toOwnedSlice(a);
}

const Paths = std.StringHashMap(void);
fn freePaths(a: std.mem.Allocator, paths: *Paths) void {
    var it = paths.keyIterator();
    while (it.next()) |key| a.free(key.*);
    paths.deinit();
}

/// Advisory only (owns OS confinement). Compare file names, never
/// contents/timestamps. Git supplies tracked/untracked names and ignore rules;
/// metadata only distinguishes existing files from missing index entries.
pub const OutsideGuard = struct {
    a: std.mem.Allocator,
    parent: ?confined.Root = null,
    has_repository: bool = false,
    excluded: []const u8 = "",
    before: Paths,
    new_paths: std.ArrayList([]u8) = .empty,
    snapshot_error: ?anyerror = null,

    pub fn init(a: std.mem.Allocator, io: std.Io, root: []const u8) !OutsideGuard {
        const top = try repository(a, io, root);
        var guard: OutsideGuard = .{ .a = a, .before = Paths.init(a) };
        errdefer guard.deinit();
        guard.has_repository = try hasGit(a, io, top);
        if (guard.has_repository and !std.ascii.eqlIgnoreCase(top, root)) {
            guard.parent = try confined.Root.init(a, top);
            guard.excluded = root[top.len + 1 ..];
            // Include even ignored existing names in the baseline: changing
            // ignore rules during the task must not turn old files into new.
            guard.before = guard.snapshot(io, false) catch |e| blk: {
                guard.snapshot_error = e;
                break :blk Paths.init(a);
            };
        }
        return guard;
    }

    pub fn deinit(self: *OutsideGuard) void {
        freePaths(self.a, &self.before);
        for (self.new_paths.items) |path| self.a.free(path);
        self.new_paths.deinit(self.a);
        if (self.parent) |*parent| parent.deinit();
    }

    fn insideOrder(self: *OutsideGuard, path: []const u8) bool {
        if (path.len < self.excluded.len) return false;
        for (path[0..self.excluded.len], self.excluded) |left, right| {
            const l = if (left == '\\') '/' else std.ascii.toLower(left);
            const r = if (right == '\\') '/' else std.ascii.toLower(right);
            if (l != r) return false;
        }
        return path.len == self.excluded.len or path[self.excluded.len] == '/' or path[self.excluded.len] == '\\';
    }

    fn snapshot(self: *OutsideGuard, io: std.Io, respect_ignore: bool) !Paths {
        var result = Paths.init(self.a);
        errdefer freePaths(self.a, &result);
        const root = if (self.parent) |*value| value else return result;
        try root.validateIdentity(root);
        const git = try @import("executor.zig").resolveAllowedExeExt(self.a, "git", ".exe");
        defer self.a.free(git);
        var env = try @import("platform.zig").environ().createMap(self.a);
        defer env.deinit();
        for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT" }) |key| _ = env.swapRemove(key);
        try env.put("GIT_OPTIONAL_LOCKS", "0");
        const args = [_][]const u8{ git, "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "ls-files", "-z", "--cached", "--others", "--exclude-standard" };
        const capture = try std.process.run(self.a, io, .{
            .argv = args[0 .. args.len - @intFromBool(!respect_ignore)],
            .cwd = .{ .path = root.canonical },
            .environ_map = &env,
            .stdout_limit = .limited(32 * 1024 * 1024),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
        defer self.a.free(capture.stdout);
        defer self.a.free(capture.stderr);
        if (capture.term != .exited or capture.term.exited != 0) return error.OutsideGitSnapshotFailed;
        try root.validateIdentity(root);
        var names = std.mem.tokenizeScalar(u8, capture.stdout, 0);
        while (names.next()) |path| {
            if (self.insideOrder(path)) continue;
            // Never include .git, even if a malicious index lists it.
            var components = std.mem.tokenizeAny(u8, path, "/\\");
            var internal = false;
            while (components.next()) |part| if (std.ascii.eqlIgnoreCase(part, ".git")) {
                internal = true;
                break;
            };
            if (internal) continue;
            if (result.count() >= 100000) return error.OutsideSnapshotTooLarge;
            const file = root.openMetadata(path) catch |e| switch (e) {
                error.FileNotFound, error.SandboxDenied => continue,
                else => return e,
            };
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.kind != .file) continue;
            if (result.contains(path)) continue;
            const key = try self.a.dupe(u8, path);
            errdefer self.a.free(key);
            try result.put(key, {});
        }
        return result;
    }

    pub fn check(self: *OutsideGuard, io: std.Io) !void {
        if (self.snapshot_error) |e| return e;
        if (self.parent == null) return;
        var after = try self.snapshot(io, true);
        defer freePaths(self.a, &after);
        var names = after.keyIterator();
        while (names.next()) |path| {
            if (self.before.contains(path.*)) continue;
            const full = try std.fs.path.join(self.a, &.{ self.parent.?.canonical, path.* });
            errdefer self.a.free(full);
            try self.new_paths.append(self.a, full);
        }
    }
};

test "CK-CAB-027 Codex globals cannot silently bypass default policy" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CODEX_HOME", root);
    try checkCodexGlobals(a, io, &env);
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "PERSONAL CONTEXT MUST NOT BE READ" });
    try std.testing.expectError(error.PersonalContextIsolationUnavailable, checkCodexGlobals(a, io, &env));
    try std.testing.expectEqualStrings(root, env.get("CODEX_HOME").?);
}

test "CK-CAB-027 capability environment is preserved and custom OpenCode profiles never silently lose skills or MCP" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "opencode.json", .data = "{\"skills\":{\"paths\":[\"synthetic\"]}}" });
    const custom = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(custom);
    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("USERPROFILE", "C:\\synthetic-home");
    try parent.put("CODEX_HOME", "C:\\synthetic-home\\.codex-sid");
    try parent.put("OPENCODE_CONFIG", "C:\\synthetic-home\\capabilities.json");
    try parent.put("OPENCODE_CONFIG_CONTENT", "{\"mcp\":{\"sentinel\":{\"type\":\"local\",\"command\":[\"synthetic\"]}},\"skills\":{\"paths\":[\"C:/synthetic-skills\"]}}");
    for ([_][]const u8{ "claude-code", "codex", "opencode" }) |cli| {
        var child = try environment(a, io, &parent, cli, "C:\\order", false);
        defer child.deinit();
        for ([_][]const u8{ "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "CODEX_HOME", "USERPROFILE" }) |key|
            try std.testing.expectEqualStrings(parent.get(key).?, child.get(key).?);
    }
    try parent.put("OPENCODE_CONFIG_DIR", custom);
    try std.testing.expectError(error.CustomOpenCodeContextUnavailable, environment(a, io, &parent, "opencode", "C:\\order", false));
    var inherited = try environment(a, io, &parent, "opencode", "C:\\order", true);
    defer inherited.deinit();
    try std.testing.expectEqualStrings(custom, inherited.get("OPENCODE_CONFIG_DIR").?);
}

test "CK-CAB-027 r3 custom OpenCode config inspection distinguishes capabilities from empty profiles" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Case = struct { name: []const u8, data: []const u8, blocks: bool };
    for ([_]Case{
        .{ .name = "opencode.json", .data = "{}", .blocks = false },
        .{ .name = "opencode.json", .data = "{\"skills\":{\"paths\":[],\"urls\":[]},\"mcp\":{}}", .blocks = false },
        .{ .name = "opencode.jsonc", .data = "{/* \"mcp\":{\"fake\":{}} */\n\"model\":\"https://synthetic/mcp\", // comment\n\"skills\":{\"paths\":[],},}", .blocks = false },
        .{ .name = "opencode.json", .data = "{\"mcp\":{\"synthetic\":{\"type\":\"local\",\"command\":[\"synthetic\"]}}}", .blocks = true },
        .{ .name = "opencode.jsonc", .data = "{//comment\n\"skills\":{\"paths\":[\"synthetic\"],},}", .blocks = true },
        .{ .name = "opencode.json", .data = "{\"skills\":{\"urls\":[\"https://synthetic.invalid/skills\"]}}", .blocks = true },
        .{ .name = "skills/synthetic/SKILL.md", .data = "synthetic skill; content must not be read", .blocks = true },
        .{ .name = "skill/synthetic/SKILL.md", .data = "synthetic legacy skill directory", .blocks = true },
        .{ .name = "skills/synthetic/notes.txt", .data = "no skill definition", .blocks = false },
        .{ .name = "opencode.jsonc", .data = "\xef\xbb\xbf{\"model\":\"escaped\\\" // literal /* text */\",}", .blocks = false },
        .{ .name = "opencode.jsonc", .data = "{// CR comment\r\"model\":\"synthetic\"}", .blocks = false },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (std.fs.path.dirname(case.name)) |dir| try tmp.dir.createDirPath(io, dir);
        try tmp.dir.writeFile(io, .{ .sub_path = case.name, .data = case.data });
        const custom = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(custom);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("OPENCODE_CONFIG_DIR", custom);
        if (case.blocks) {
            try std.testing.expectError(error.CustomOpenCodeContextUnavailable, environment(a, io, &env, "opencode", "C:\\order", false));
        } else {
            var child = try environment(a, io, &env, "opencode", "C:\\order", false);
            defer child.deinit();
            try std.testing.expectEqualStrings("1", child.get("OPENCODE_DISABLE_CLAUDE_CODE_PROMPT").?);
            try std.testing.expectEqualStrings(custom, env.get("OPENCODE_CONFIG_DIR").?);
        }
    }
}

test "CK-CAB-027 r3 custom OpenCode inspection errors are explicit and opt-in bypasses inspection" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("OPENCODE_CONFIG_DIR", root);
    for ([_][]const u8{ "{/* unterminated", "{\"mcp\":[]}", "{\"skills\":{\"paths\":true}}", "[]", "{\"model\":\"{file:auth.json}\"}" }) |data| {
        try tmp.dir.writeFile(io, .{ .sub_path = "opencode.json", .data = data });
        if (std.mem.indexOf(u8, data, "{file:")) |_| {
            // No auth.json exists: success proves references are not resolved.
            var child = try environment(a, io, &env, "opencode", root, false);
            child.deinit();
        } else {
            try std.testing.expectError(error.OpenCodeProfileInspectionFailed, environment(a, io, &env, "opencode", root, false));
        }
        var inherited = try environment(a, io, &env, "opencode", root, true);
        defer inherited.deinit();
        try std.testing.expectEqualStrings(root, inherited.get("OPENCODE_CONFIG_DIR").?);
    }
    const too_large = try a.alloc(u8, OPENCODE_CONFIG_MAX_BYTES + 1);
    defer a.free(too_large);
    @memset(too_large, ' ');
    try tmp.dir.writeFile(io, .{ .sub_path = "opencode.json", .data = too_large });
    try std.testing.expectError(error.OpenCodeProfileInspectionFailed, environment(a, io, &env, "opencode", root, false));
    try env.put("OPENCODE_CONFIG_DIR", "missing-profile");
    var missing = try environment(a, io, &env, "opencode", root, false);
    defer missing.deinit();
    try std.testing.expectEqualStrings("1", missing.get("OPENCODE_DISABLE_CLAUDE_CODE_PROMPT").?);
}

/// parte A. Pure handoff-context selection when switching models.
/// No I/O, no provider calls; never truncates mandatory or optional text.
/// Global reserve for the request envelope, independent of message count.
const HANDOFF_FORMAT_MARGIN_TOKENS: u32 = 64;

/// Per-message reserve for serialization separators/structure (8 tokens),
/// in addition to the role and text counted with the injected tokenizer.
/// Provider integration must respect this allowance or increase it.
const HANDOFF_MESSAGE_FORMAT_TOKENS: u32 = 8;

pub const ContextRecord = struct {
    role: []const u8,
    text: []const u8,
    id: []const u8,
    order: ?u64 = null,
    created_at: u64 = 0,
};

/// Minimal token-counting interface. count_fn receives an optional context
/// pointer so call sites can bind state without heap allocation.
pub const TokenCounter = struct {
    ctx: ?*const anyopaque = null,
    count_fn: *const fn (?*const anyopaque, []const u8) usize,

    pub fn count(self: TokenCounter, text: []const u8) usize {
        return self.count_fn(self.ctx, text);
    }
};

/// Approximation: ceil(bytes/2), reserving roughly 50% more than bytes/3.
/// This safety allowance is not a guaranteed upper bound for every tokenizer;
/// inject the provider's actual tokenizer when available.
pub fn defaultTokenCounter() TokenCounter {
    return .{ .count_fn = countDefaultTokens };
}

fn countDefaultTokens(_: ?*const anyopaque, text: []const u8) usize {
    return text.len / 2 + text.len % 2;
}

fn handoffMessageTokens(counter: TokenCounter, role: []const u8, text: []const u8) u64 {
    return @as(u64, counter.count(text)) + counter.count(role) + HANDOFF_MESSAGE_FORMAT_TOKENS;
}

pub const HandoffContext = struct {
    messages: []ContextRecord,
    omitted_ids: [][]const u8,
    /// Mandatory and selected messages, including roles and per-message format.
    /// Excludes the global envelope reserve, fixed prompt and reserved output.
    tokens_used: usize,
    a: std.mem.Allocator,

    pub fn deinit(self: *HandoffContext) void {
        for (self.messages) |*message| {
            self.a.free(message.role);
            self.a.free(message.text);
            self.a.free(message.id);
        }
        self.a.free(self.messages);
        for (self.omitted_ids) |id| self.a.free(id);
        self.a.free(self.omitted_ids);
    }
};

/// Select transcript turns for a model change inside a token budget.
/// original_order and latest_request are mandatory and never truncated; if
/// they alone exceed the budget, fail with HandoffTooLarge before any use.
/// Optional turns are taken from the most recent backwards while they fit
/// whole (never truncated); ones that do not fit are recorded in omitted_ids.
/// The result preserves chronological order. context_window == 0 (unknown)
/// fails explicitly with UnknownContextWindow.
/// Each included message reserves role tokens and 8 format tokens, separately
/// from the global 64-token envelope reserve. Both mandatory texts are budgeted
/// as distinct user messages; the eventual serializer must honor that contract.
pub fn buildHandoffContext(
    allocator: std.mem.Allocator,
    original_order: []const u8,
    latest_request: []const u8,
    transcript: []const ContextRecord,
    context_window: u32,
    reserved_output_tokens: u32,
    fixed_prompt_tokens: u32,
    counter: TokenCounter,
) !HandoffContext {
    if (context_window == 0) return error.UnknownContextWindow;
    const overhead: u64 = @as(u64, reserved_output_tokens) + fixed_prompt_tokens + HANDOFF_FORMAT_MARGIN_TOKENS;
    const budget: u64 = if (@as(u64, context_window) > overhead) @as(u64, context_window) - overhead else 0;
    const mandatory = handoffMessageTokens(counter, "user", original_order) + handoffMessageTokens(counter, "user", latest_request);
    if (mandatory > budget) return error.HandoffTooLarge;

    // The last transcript turn may already be the latest request resent;
    // skip it instead of duplicating (it still counts as mandatory).
    const duplicate_last = transcript.len > 0 and std.mem.eql(u8, transcript[transcript.len - 1].text, latest_request);

    var selected = std.ArrayList(usize).empty;
    defer selected.deinit(allocator);
    var omitted = std.ArrayList([]const u8).empty;
    defer {
        for (omitted.items) |id| allocator.free(id);
        omitted.deinit(allocator);
    }

    var used: u64 = mandatory;
    var index: usize = transcript.len;
    while (index > 0) {
        index -= 1;
        if (duplicate_last and index == transcript.len - 1) continue;
        const tokens = handoffMessageTokens(counter, transcript[index].role, transcript[index].text);
        if (used + tokens <= budget) {
            try selected.append(allocator, index);
            used += tokens;
        } else {
            const id = try allocator.dupe(u8, transcript[index].id);
            errdefer allocator.free(id);
            try omitted.append(allocator, id);
        }
    }

    var messages = try allocator.alloc(ContextRecord, selected.items.len);
    var filled: usize = 0;
    errdefer {
        for (messages[0..filled]) |*message| {
            allocator.free(message.role);
            allocator.free(message.text);
            allocator.free(message.id);
        }
        allocator.free(messages);
    }
    while (filled < selected.items.len) : (filled += 1) {
        const record = transcript[selected.items[selected.items.len - 1 - filled]];
        const role = try allocator.dupe(u8, record.role);
        errdefer allocator.free(role);
        const text = try allocator.dupe(u8, record.text);
        errdefer allocator.free(text);
        const id = try allocator.dupe(u8, record.id);
        messages[filled] = .{ .role = role, .text = text, .id = id, .order = record.order, .created_at = record.created_at };
    }

    var left: usize = 0;
    var right: usize = omitted.items.len;
    while (left < right) {
        right -= 1;
        if (left >= right) break;
        const swap = omitted.items[left];
        omitted.items[left] = omitted.items[right];
        omitted.items[right] = swap;
        left += 1;
    }
    const omitted_ids = try omitted.toOwnedSlice(allocator);
    errdefer {
        for (omitted_ids) |id| allocator.free(id);
        allocator.free(omitted_ids);
    }

    return .{ .messages = messages, .omitted_ids = omitted_ids, .tokens_used = @intCast(used), .a = allocator };
}

/// B. Only order text and complete conversational messages are
/// read; events are diagnostics, not a lossless transcript of provider turns.
pub const OrderTranscript = struct {
    original: []u8,
    records: []ContextRecord,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OrderTranscript) void {
        self.allocator.free(self.original);
        for (self.records) |r| {
            self.allocator.free(r.role);
            self.allocator.free(r.text);
            self.allocator.free(r.id);
        }
        self.allocator.free(self.records);
    }
};

pub fn loadOrderTranscript(a: std.mem.Allocator, runtime: ?db.Connection, order_id: i64, stateless_original: []const u8) !OrderTranscript {
    var records: std.ArrayList(ContextRecord) = .empty;
    errdefer {
        for (records.items) |r| {
            a.free(r.role);
            a.free(r.text);
            a.free(r.id);
        }
        records.deinit(a);
    }
    if (order_id == 0) return .{ .original = try a.dupe(u8, stateless_original), .records = try records.toOwnedSlice(a), .allocator = a };
    if (order_id < 0) return error.HandoffSourceUnavailable;
    const conn = runtime orelse return error.HandoffSourceUnavailable;
    const order = try conn.prepare("SELECT user_prompt FROM orders WHERE id=?");
    defer conn.finalize(order);
    try db.bindInt(order, 1, order_id);
    if (db.c.sqlite3_step(order) != db.c.SQLITE_ROW) return error.HandoffSourceUnavailable;
    const original = try a.dupe(u8, std.mem.span(db.c.sqlite3_column_text(order, 0) orelse return error.HandoffSourceUnavailable));
    errdefer a.free(original);
    const messages = try conn.prepare("SELECT id,role,content,created_at FROM messages WHERE order_id=? ORDER BY created_at,id");
    defer conn.finalize(messages);
    try db.bindInt(messages, 1, order_id);
    while (true) {
        const rc = db.c.sqlite3_step(messages);
        if (rc == db.c.SQLITE_DONE) break;
        if (rc != db.c.SQLITE_ROW) return error.HandoffSourceUnavailable;
        const role = try a.dupe(u8, std.mem.span(db.c.sqlite3_column_text(messages, 1) orelse return error.HandoffSourceUnavailable));
        errdefer a.free(role);
        const text = try a.dupe(u8, std.mem.span(db.c.sqlite3_column_text(messages, 2) orelse return error.HandoffSourceUnavailable));
        errdefer a.free(text);
        const id = try std.fmt.allocPrint(a, "message:{d}", .{db.c.sqlite3_column_int64(messages, 0)});
        errdefer a.free(id);
        try records.append(a, .{ .role = role, .text = text, .id = id, .order = @intCast(order_id), .created_at = @intCast(@max(0, db.c.sqlite3_column_int64(messages, 3))) });
    }
    return .{ .original = original, .records = try records.toOwnedSlice(a), .allocator = a };
}

pub fn modelContextWindow(catalog: db.Connection, provider: []const u8, model: []const u8) !u32 {
    const q = try catalog.prepare("SELECT m.context_window FROM models m JOIN providers p ON p.id=m.provider_id WHERE p.name=? AND m.model_name=?");
    defer catalog.finalize(q);
    try db.bindText(q, 1, provider);
    try db.bindText(q, 2, model);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_ROW) return error.UnknownContextWindow;
    const window = db.c.sqlite3_column_int64(q, 0);
    if (window <= 0 or window > std.math.maxInt(u32)) return error.UnknownContextWindow;
    return @intCast(window);
}

pub const HANDOFF_OUTPUT_TOKENS: u32 = 4096;

/// Serialize as text inside the existing user-message transport. Each record
/// adds only '\n[', ']\n', '\n' (5 bytes), below part A's 8-token reserve with
/// the default counter. Roles and complete texts are charged separately.
/// Reserve all possible omitted references before selection, so references
/// never consume unbudgeted space. The final serialized request is checked too.
pub fn buildHandoffPrompt(a: std.mem.Allocator, original: []const u8, latest: []const u8, transcript: []const ContextRecord, window: u32, fixed_tokens: u32, counter: TokenCounter) ![]u8 {
    var references: u64 = counter.count("omitted:\n");
    for (transcript) |r| references += counter.count(r.id) + counter.count("\n");
    const fixed: u64 = @as(u64, fixed_tokens) + references;
    if (fixed > std.math.maxInt(u32)) return error.HandoffTooLarge;
    var context = try buildHandoffContext(a, original, latest, transcript, window, HANDOFF_OUTPUT_TOKENS, @intCast(fixed), counter);
    defer context.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    if (context.omitted_ids.len > 0) {
        try out.writer.writeAll("omitted:\n");
        for (context.omitted_ids) |id| try out.writer.print("{s}\n", .{id});
    }
    try out.writer.print("\n[user]\n{s}\n", .{original});
    for (context.messages) |r| try out.writer.print("\n[{s}]\n{s}\n", .{ r.role, r.text });
    try out.writer.print("\n[user]\n{s}\n", .{latest});
    // Also enforces custom counters that charge separators more than the
    // default approximation; reject rather than silently exceed the window.
    try checkHandoffPrompt(out.written(), window, fixed_tokens, counter);
    return out.toOwnedSlice();
}

pub fn checkHandoffPrompt(prompt: []const u8, window: u32, fixed_tokens: u32, counter: TokenCounter) !void {
    if (window == 0) return error.UnknownContextWindow;
    const total = @as(u64, counter.count(prompt)) + fixed_tokens + HANDOFF_OUTPUT_TOKENS + HANDOFF_FORMAT_MARGIN_TOKENS;
    if (total > window) return error.HandoffTooLarge;
}

fn countBytesForHandoffTests(_: ?*const anyopaque, text: []const u8) usize {
    return text.len;
}

fn byteCounterForHandoffTests() TokenCounter {
    return .{ .count_fn = countBytesForHandoffTests };
}

test "CK-COMP-009 long transcript selects recent turns inside budget in chronological order" {
    const a = std.testing.allocator;
    const records = [_]ContextRecord{
        .{ .role = "user", .text = "0123456789", .id = "m1", .created_at = 1 },
        .{ .role = "assistant", .text = "0123456789", .id = "m2", .created_at = 2 },
        .{ .role = "user", .text = "0123456789", .id = "m3", .created_at = 3 },
        .{ .role = "assistant", .text = "0123456789", .id = "m4", .created_at = 4 },
        .{ .role = "user", .text = "0123456789", .id = "m5", .created_at = 5 },
        .{ .role = "assistant", .text = "0123456789", .id = "m6", .created_at = 6 },
        .{ .role = "user", .text = "0123456789", .id = "m7", .created_at = 7 },
        .{ .role = "assistant", .text = "0123456789", .id = "m8", .created_at = 8 },
        .{ .role = "user", .text = "0123456789", .id = "m9", .created_at = 9 },
        .{ .role = "assistant", .text = "0123456789", .id = "m10", .created_at = 10 },
    };
    var context = try buildHandoffContext(a, "original", "latest", &records, 340, 20, 20, byteCounterForHandoffTests());
    defer context.deinit();
    const expected = [_][]const u8{ "m3", "m4", "m5", "m6", "m7", "m8", "m9", "m10" };
    try std.testing.expectEqual(expected.len, context.messages.len);
    for (context.messages, expected) |message, id| try std.testing.expectEqualStrings(id, message.id);
    try std.testing.expectEqual(@as(usize, 2), context.omitted_ids.len);
    try std.testing.expectEqualStrings("m1", context.omitted_ids[0]);
    try std.testing.expectEqualStrings("m2", context.omitted_ids[1]);
    try std.testing.expectEqual(@as(usize, 234), context.tokens_used);
}

test "CK-COMP-009 mandatory context that cannot fit fails explicitly" {
    const a = std.testing.allocator;
    var original: [60]u8 = undefined;
    @memset(original[0..], 'o');
    var latest: [60]u8 = undefined;
    @memset(latest[0..], 'l');
    const records = [_]ContextRecord{.{ .role = "user", .text = "small", .id = "m1" }};
    try std.testing.expectError(error.HandoffTooLarge, buildHandoffContext(a, original[0..], latest[0..], &records, 200, 20, 20, byteCounterForHandoffTests()));
}

test "CK-COMP-009 unknown context window fails explicitly" {
    const a = std.testing.allocator;
    const records = [_]ContextRecord{.{ .role = "user", .text = "turn", .id = "m1" }};
    try std.testing.expectError(error.UnknownContextWindow, buildHandoffContext(a, "original", "latest", &records, 0, 0, 0, byteCounterForHandoffTests()));
}

test "CK-COMP-009 record that does not fit is omitted whole and never truncated" {
    const a = std.testing.allocator;
    var large_b: [120]u8 = undefined;
    @memset(large_b[0..], 'B');
    var large_d: [80]u8 = undefined;
    @memset(large_d[0..], 'D');
    const records = [_]ContextRecord{
        .{ .role = "user", .text = "AAAAAAAAAA", .id = "m1", .created_at = 1 },
        .{ .role = "assistant", .text = large_b[0..], .id = "m2", .created_at = 2 },
        .{ .role = "user", .text = "CCCCCCCCCC", .id = "m3", .created_at = 3 },
        .{ .role = "assistant", .text = large_d[0..], .id = "m4", .created_at = 4 },
    };
    var context = try buildHandoffContext(a, "orig", "new", &records, 265, 10, 10, byteCounterForHandoffTests());
    defer context.deinit();
    const expected = [_][]const u8{ "m1", "m3", "m4" };
    try std.testing.expectEqual(expected.len, context.messages.len);
    for (context.messages, expected) |message, id| try std.testing.expectEqualStrings(id, message.id);
    try std.testing.expectEqualStrings("AAAAAAAAAA", context.messages[0].text);
    try std.testing.expectEqualStrings("CCCCCCCCCC", context.messages[1].text);
    try std.testing.expectEqualStrings(large_d[0..], context.messages[2].text);
    try std.testing.expectEqual(@as(usize, 1), context.omitted_ids.len);
    try std.testing.expectEqualStrings("m2", context.omitted_ids[0]);
    try std.testing.expectEqual(@as(usize, 172), context.tokens_used);
}

test "CK-COMP-009 latest request matching the last transcript record is not duplicated" {
    const a = std.testing.allocator;
    const records = [_]ContextRecord{
        .{ .role = "user", .text = "older", .id = "m1", .created_at = 1 },
        .{ .role = "user", .text = "same prompt", .id = "m2", .created_at = 2 },
    };
    var context = try buildHandoffContext(a, "orig", "same prompt", &records, 200, 0, 0, byteCounterForHandoffTests());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 1), context.messages.len);
    try std.testing.expectEqualStrings("m1", context.messages[0].id);
    try std.testing.expect(!std.mem.eql(u8, "same prompt", context.messages[0].text));
    try std.testing.expectEqual(@as(usize, 0), context.omitted_ids.len);
    try std.testing.expectEqual(@as(usize, 56), context.tokens_used);
}

test "CK-COMP-009 default token counter approximates ceil bytes over two with explicit safety" {
    const counter = defaultTokenCounter();
    try std.testing.expectEqual(@as(usize, 0), counter.count(""));
    try std.testing.expectEqual(@as(usize, 1), counter.count("a"));
    try std.testing.expectEqual(@as(usize, 1), counter.count("ab"));
    try std.testing.expectEqual(@as(usize, 2), counter.count("abc"));
    try std.testing.expectEqual(@as(usize, 2), counter.count("abcd"));
    try std.testing.expectEqual(@as(usize, 3), counter.count("abcde"));
    try std.testing.expectEqual(@as(usize, 3), counter.count("abcdef"));
    try std.testing.expectEqual(@as(usize, 4), counter.count("abcdefg"));
}

test "CK-COMP-009 many short messages reserve roles and separators per included record" {
    var records: [32]ContextRecord = undefined;
    for (&records, 0..) |*record, index|
        record.* = .{ .role = "assistant", .text = "x", .id = "short", .created_at = @intCast(index) };

    // Byte counter: mandatory user turns cost 2*(1+4+8)=26.
    // Each optional assistant turn costs 1+9+8=18; nine fit exactly.
    var context = try buildHandoffContext(std.testing.allocator, "o", "l", &records, 252, 0, 0, byteCounterForHandoffTests());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 9), context.messages.len);
    try std.testing.expectEqual(@as(usize, 23), context.omitted_ids.len);
    try std.testing.expectEqual(@as(usize, 188), context.tokens_used);
    for (context.messages, 23..) |message, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index)), message.created_at);
        try std.testing.expectEqualStrings("x", message.text);
    }
    for (context.omitted_ids) |id| try std.testing.expectEqualStrings("short", id);

    var smaller = try buildHandoffContext(std.testing.allocator, "o", "l", &records, 251, 0, 0, byteCounterForHandoffTests());
    defer smaller.deinit();
    try std.testing.expectEqual(@as(usize, 8), smaller.messages.len);
    try std.testing.expectEqual(@as(usize, 24), smaller.omitted_ids.len);
    try std.testing.expectEqual(@as(usize, 170), smaller.tokens_used);
}

test "CK-COMP-009 mandatory message framing must fit even when text alone fits" {
    try std.testing.expectError(error.HandoffTooLarge, buildHandoffContext(
        std.testing.allocator,
        "1234567",
        "123456",
        &.{},
        100,
        0,
        0,
        byteCounterForHandoffTests(),
    ));
}

test "CK-COMP-009 long role is counted in addition to fixed separators" {
    const records = [_]ContextRecord{
        .{ .role = "user", .text = "x", .id = "small-role" },
        .{ .role = "r" ** 80, .text = "x", .id = "long-role" },
    };
    var context = try buildHandoffContext(std.testing.allocator, "o", "l", &records, 128, 0, 0, byteCounterForHandoffTests());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 1), context.messages.len);
    try std.testing.expectEqualStrings("small-role", context.messages[0].id);
    try std.testing.expectEqual(@as(usize, 1), context.omitted_ids.len);
    try std.testing.expectEqualStrings("long-role", context.omitted_ids[0]);
    try std.testing.expectEqual(@as(usize, 39), context.tokens_used);
}

test "CK-COMP-009 handoff context releases selected and omitted allocations" {
    const a = std.testing.allocator;
    var records: [32]ContextRecord = undefined;
    var index: usize = 0;
    while (index < records.len) : (index += 1)
        records[index] = .{ .role = "assistant", .text = "0123456789", .id = "mem", .created_at = @intCast(index) };
    var context = try buildHandoffContext(a, "orig", "new", &records, 200, 0, 0, byteCounterForHandoffTests());
    context.deinit();
    var empty = try buildHandoffContext(a, "orig", "new", &[_]ContextRecord{}, 200, 0, 0, byteCounterForHandoffTests());
    empty.deinit();
    try std.testing.expectError(error.HandoffTooLarge, buildHandoffContext(a, "0123456789", "0123456789", &records, 100, 40, 0, byteCounterForHandoffTests()));
}

test "CK-CAB-027 persistent default opt-in survives reopening and invalid setting fails" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "catalog.db" });
    defer a.free(path);
    {
        var conn = try db.Connection.open(a, path);
        defer conn.close();
        try db.Migrator.init(a).migrate(conn, &db.catalog_schema);
        try std.testing.expect(!(try load(conn)));
        try conn.exec("UPDATE settings SET value='true' WHERE key='external_agent_inherit_personal_context'");
        try std.testing.expect(try load(conn));
    }
    {
        var conn = try db.Connection.open(a, path);
        defer conn.close();
        try std.testing.expect(try load(conn));
        try conn.exec("UPDATE settings SET value='invalid' WHERE key='external_agent_inherit_personal_context'");
        try std.testing.expectError(error.InvalidContextSetting, load(conn));
    }
}
