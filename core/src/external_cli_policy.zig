const std = @import("std");
const confined = @import("confined_fs.zig");
const windows = std.os.windows;
const is_windows = @import("builtin").os.tag == .windows;
const GetEnvironmentVariableW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;
}.GetEnvironmentVariableW else @import("providers").posix_files.GetEnvironmentVariableW;
const CreateFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
}.CreateFileW else @import("providers").posix_files.CreateFileW;
extern "kernel32" fn GetFinalPathNameByHandleW(windows.HANDLE, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn GetFileInformationByHandleEx(windows.HANDLE, c_int, *anyopaque, u32) callconv(.winapi) c_int;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
extern fn da_cli_acl_safe(windows.HANDLE) c_int;
extern fn da_cli_acl_blocker(windows.HANDLE, ?[*]u8, u32) c_int;
extern fn da_cli_owner_safe(windows.HANDLE) c_int;
extern fn da_cli_owner_sddl([*:0]const u16) c_int;
extern fn da_cli_acl_inspect(windows.HANDLE, ?[*]u8, u32) c_int;
extern fn da_cli_binary_acl_inspect(windows.HANDLE, ?[*]u8, u32, ?[*]u8, u32) c_int;
extern fn da_cli_binary_acl_sddl([*:0]const u16, ?[*]u8, u32) c_int;
extern fn da_cli_acl_sddl([*:0]const u16, ?[*]u8, u32) c_int;
extern fn da_codex_sandbox_sids([*]u8, u32) c_int;
extern fn da_codex_profile_acl_safe(windows.HANDLE) c_int;
extern fn da_codex_profile_acl_sddl([*:0]const u16) c_int;
extern fn da_codex_profile_acl_fixture([*:0]const u16, u32) c_int;
extern fn da_cli_authenticode(windows.HANDLE, [*:0]const u16) i32;
extern fn da_cli_create_private_directory([*:0]const u16) u32;
extern fn da_appcontainer_app_name([*:0]const u8, [*]u8, u32) c_int;
extern fn da_appcontainer_moniker_is_devagents([*:0]const u16) c_int;

pub const GetEnvFn = *const fn (std.mem.Allocator, []const u8) anyerror!?[]u8;
pub const PresentFn = *const fn ([:0]const u8) bool;
/// Defense in depth: profile ACL trust is not authentication authority. Even a
/// modified auth.json cannot enable API billing: both login probes and exec
/// force ChatGPT, codexEnvironment removes EVERY provider billing variable from
/// the child, and config.toml may not select another provider (see
/// codexConfigOverridesProvider). `--ignore-user-config` is deliberately NOT
/// used: it would also drop the Windows sandbox mode and the model defaults
/// that live in config.toml, and its effect on the sandbox cannot be proven
/// without a live (billable-to-subscription) run.
pub const CODEX_LOGIN_CONFIG = "forced_login_method=\"chatgpt\"";
pub const CODEX_BILLING_ENV_VARS = [_][:0]const u8{ "OPENAI_API_KEY", "CODEX_API_KEY" };
pub const BILLING_ENV_VARS = [_][:0]const u8{
    "ANTHROPIC_API_KEY",  "OPENAI_API_KEY",      "GEMINI_API_KEY",          "GOOGLE_API_KEY",
    "OPENROUTER_API_KEY", "TOKENROUTER_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CODEX_API_KEY",
    "OPENCODE_API_KEY",
};

pub fn envPresent(name: [:0]const u8) bool {
    var wide: [128]u16 = undefined;
    if (name.len >= wide.len) return false;
    for (name, 0..) |c, i| wide[i] = c;
    wide[name.len] = 0;
    return GetEnvironmentVariableW(wide[0..name.len :0].ptr, null, 0) > 0;
}

pub fn billingForCli(cli: []const u8, present: PresentFn) bool {
    for (BILLING_ENV_VARS) |name| {
        if (appliesTo(cli, name) and present(name)) return true;
    }
    return false;
}

/// La copia pertenece al hijo; nunca se modifica el entorno del anfitrión.
/// Codex solo consume OPENAI/CODEX_API_KEY, pero un `env_key` de config.toml
/// podría nombrar cualquier otra variable de proveedor: el hijo no hereda
/// NINGUNA de BILLING_ENV_VARS.
pub fn codexEnvironment(a: std.mem.Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var child = try parent.clone(a);
    errdefer child.deinit();
    for (BILLING_ENV_VARS) |key| _ = child.swapRemove(key);
    // Tampoco el endpoint: OPENAI_BASE_URL redirigiría la facturación por API.
    _ = child.swapRemove("OPENAI_BASE_URL");
    const home = try codexHome(a, child.get("CODEX_HOME"), child.get("USERPROFILE"));
    defer a.free(home);
    try child.put("CODEX_HOME", home);
    return child;
}

fn codexHome(a: std.mem.Allocator, explicit: ?[]const u8, profile: ?[]const u8) ![]u8 {
    if (explicit) |home| {
        if (!localPath(home)) return error.InvalidEnvironment;
        return a.dupe(u8, home);
    }
    const base = profile orelse return error.InvalidEnvironment;
    if (!localPath(base)) return error.InvalidEnvironment;
    return std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".codex", .{base});
}

/// Variables que, sin ser una clave, desvían la CLI a facturación por API o a
/// otro proveedor (endpoint propio, token de pasarela, Bedrock/Vertex).
pub const ROUTING_ENV_VARS = [_][:0]const u8{
    "OPENAI_BASE_URL",         "ANTHROPIC_BASE_URL",     "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
};

/// 10-nov (USUARIO-NUEVO A1): el entorno del hijo de CUALQUIER CLI. Igual que
/// Codex: no hereda ninguna variable de facturación ni de desvío del
/// anfitrión. Un desarrollador suele tener ANTHROPIC_API_KEY o
/// TOKENROUTER_API_KEY como variable de usuario; con ellas Claude Code factura
/// por API y OpenCode las usa como credencial. Sin ellas, la CLI usa la sesión
/// con la que el usuario la inició (suscripción) y la clasificación de la
/// sesión sale de lo que la CLI responde con este mismo entorno.
pub fn cliEnvironment(a: std.mem.Allocator, parent: *const std.process.Environ.Map, cli: []const u8) !std.process.Environ.Map {
    if (std.mem.eql(u8, cli, "codex")) return codexEnvironment(a, parent);
    var child = try parent.clone(a);
    errdefer child.deinit();
    for (BILLING_ENV_VARS) |key| _ = child.swapRemove(key);
    for (ROUTING_ENV_VARS) |key| _ = child.swapRemove(key);
    return child;
}

/// Nombres (nunca valores) de las variables de facturación del anfitrión que
/// esa CLI leería y que DevAgents le quita. null si no hay ninguna.
pub fn ignoredBillingVars(a: std.mem.Allocator, cli: []const u8, present: PresentFn) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    for (BILLING_ENV_VARS) |name| {
        if (!appliesTo(cli, name) or !present(name)) continue;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, name);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(a);
}

fn appliesTo(cli: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, cli, "opencode") or
        (std.mem.eql(u8, cli, "codex") and (std.mem.eql(u8, name, "OPENAI_API_KEY") or std.mem.eql(u8, name, "CODEX_API_KEY"))) or
        (std.mem.eql(u8, cli, "claude-code") and (std.mem.eql(u8, name, "ANTHROPIC_API_KEY") or std.mem.eql(u8, name, "CLAUDE_CODE_OAUTH_TOKEN"))) or
        (std.mem.eql(u8, cli, "gemini-cli") and (std.mem.eql(u8, name, "GEMINI_API_KEY") or std.mem.eql(u8, name, "GOOGLE_API_KEY")));
}

const AclTestApi = struct {
    extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(.winapi) c_int;
    extern "advapi32" fn SetFileSecurityW([*:0]const u16, u32, *anyopaque) callconv(.winapi) c_int;
    extern "advapi32" fn OpenProcessToken(windows.HANDLE, u32, *windows.HANDLE) callconv(.winapi) c_int;
    extern "advapi32" fn GetTokenInformation(windows.HANDLE, c_int, ?*anyopaque, u32, *u32) callconv(.winapi) c_int;
    extern "advapi32" fn ConvertSidToStringSidA(*anyopaque, *[*:0]u8) callconv(.winapi) c_int;
    extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
};

/// Archivo desechable con el DACL dado (icacls no acepta una SID que no
/// resuelve: el descriptor se fija con la API, solo en este archivo).
fn aclFixtureFile(a: std.mem.Allocator, io: std.Io, dir: anytype, name: []const u8, dacl: [:0]const u16) ![:0]u8 {
    var file = try dir.createFile(io, name, .{});
    file.close(io);
    const path = try dir.realPathFileAlloc(io, name, a);
    errdefer a.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    var descriptor: ?*anyopaque = null;
    if (AclTestApi.ConvertStringSecurityDescriptorToSecurityDescriptorW(dacl, 1, &descriptor, null) == 0) return error.TestBadSddl;
    defer _ = AclTestApi.LocalFree(descriptor);
    // 4 = DACL_SECURITY_INFORMATION.
    if (AclTestApi.SetFileSecurityW(wide, 4, descriptor.?) == 0) return error.TestSetSecurityFailed;
    return path;
}

fn openForAcl(a: std.mem.Allocator, path: []const u8) !windows.HANDLE {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const handle = CreateFileW(wide, 0x00020000, 7, null, 3, 0x02200000, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.TestOpenFailed;
    return handle;
}

test "B1 ACL: un escritor huérfano no bloquea un ejecutable; sí una carpeta de trabajo" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // SID sintética sin cuenta, con el mismo patrón (Modify) que las del
    // perfil del propietario en %USERPROFILE%\.local\bin\claude.exe.
    const stranger = "S-1-5-21-1450992000-2083255000-1303809000-1697252000";
    const path = try aclFixtureFile(a, io, tmp.dir, "claude.exe", std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;0x1301bf;;;" ++ stranger ++ ")(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;OW)"));
    defer a.free(path);
    const handle = try openForAcl(a, path);
    defer _ = CloseHandle(handle);
    var orphans: [512]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 1), da_cli_binary_acl_inspect(handle, null, 0, &orphans, orphans.len));
    try std.testing.expectEqualStrings(stranger ++ "\n", std.mem.sliceTo(&orphans, 0));
    try checkBinaryAcl(handle);
    var raw: [768]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 1), da_cli_acl_blocker(handle, &raw, raw.len));
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&raw, 0));
    // La compuerta estricta (carpetas de trabajo gobernadas) no cambia.
    try std.testing.expectError(error.CliWritableByOthers, checkAcl(handle));
    // Varias ACE de la misma huérfana se anotan una vez.
    var twice: [512]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 1), da_cli_binary_acl_sddl(std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FW;;;" ++ stranger ++ ")(A;ID;0x1301bf;;;" ++ stranger ++ ")(A;;FA;;;SY)"), &twice, twice.len));
    try std.testing.expectEqualStrings(stranger ++ "\n", std.mem.sliceTo(&twice, 0));
}

test "B1 ACL: Todos, Usuarios y demás principales que pueden colocar código siguen bloqueando" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    // WD Todos, AU Usuarios autentificados, BU BUILTIN\Usuarios, BG Invitados,
    // AN Anónimo, IU INTERACTIVO, NS Servicio de red; una SID de sesión
    // (S-1-5-5-…) no resuelve pero no es una cuenta: tampoco es huérfana.
    for ([_][]const u8{ "WD", "AU", "BU", "BG", "AN", "IU", "NS", "S-1-5-5-0-123456" }) |sid| {
        const sddl = try std.fmt.allocPrint(a, "O:SYD:(A;;FA;;;SY)(A;;FW;;;{s})", .{sid});
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        var orphans: [512]u8 = @splat(0);
        try std.testing.expectEqual(@as(c_int, 0), da_cli_binary_acl_sddl(wide, &orphans, orphans.len));
        try std.testing.expectEqualStrings("", std.mem.sliceTo(&orphans, 0));
    }
    // B1c: DERECHOS DE PROPIETARIO (OW, S-1-3-4) solo da permisos al propietario, que
    // ya pasó su propia comprobación: no bloquea un ejecutable. La compuerta
    // estricta de las carpetas de trabajo no cambia.
    var none: [8]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 1), da_cli_binary_acl_sddl(std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FA;;;SY)(A;;FA;;;OW)"), &none, none.len));
    try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_sddl(std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FA;;;SY)(A;;FA;;;OW)"), null, 0));
    // Una huérfana junto a «Todos» no salva la instalación.
    try std.testing.expectEqual(@as(c_int, 0), da_cli_binary_acl_sddl(std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FW;;;S-1-5-21-123-456-789-1002)(A;;FW;;;WD)"), null, 0));
}

test "B1 ACL: otra cuenta que sí resuelve bloquea y se nombra" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // La cuenta Invitado (RID 501) del dominio del usuario actual existe en
    // todo Windows (aunque esté deshabilitada) y no es el usuario actual.
    var token: windows.HANDLE = undefined;
    try std.testing.expect(AclTestApi.OpenProcessToken(@ptrFromInt(std.math.maxInt(usize)), 8, &token) != 0);
    defer _ = CloseHandle(token);
    var info: [512]u8 align(8) = undefined;
    var size: u32 = 0;
    // 1 = TokenUser: TOKEN_USER { SID_AND_ATTRIBUTES { PSID, DWORD } }.
    try std.testing.expect(AclTestApi.GetTokenInformation(token, 1, &info, info.len, &size) != 0);
    const user_sid: *anyopaque = @as(*const *anyopaque, @ptrCast(&info)).*;
    var text: [*:0]u8 = undefined;
    try std.testing.expect(AclTestApi.ConvertSidToStringSidA(user_sid, &text) != 0);
    defer _ = AclTestApi.LocalFree(text);
    const user = std.mem.span(text);
    if (!std.mem.startsWith(u8, user, "S-1-5-21-")) return error.SkipZigTest;
    const guest = try std.fmt.allocPrint(a, "{s}-501", .{user[0..std.mem.lastIndexOfScalar(u8, user, '-').?]});
    defer a.free(guest);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dacl = try std.fmt.allocPrint(a, "D:P(A;;0x1301bf;;;{s})(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;OW)", .{guest});
    defer a.free(dacl);
    const dacl_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, dacl);
    defer a.free(dacl_wide);
    const path = try aclFixtureFile(a, io, tmp.dir, "claude.exe", dacl_wide);
    defer a.free(path);
    const handle = try openForAcl(a, path);
    defer _ = CloseHandle(handle);
    try std.testing.expectError(error.CliWritableByOthers, checkBinaryAcl(handle));
    var raw: [768]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_blocker(handle, &raw, raw.len));
    const blocker = std.mem.sliceTo(&raw, 0);
    // «SID|DOMINIO\nombre»: con nombre, porque resuelve.
    try std.testing.expect(std.mem.startsWith(u8, blocker, guest));
    try std.testing.expect(blocker.len > guest.len + 1 and blocker[guest.len] == '|');
    const who = try describeBlocker(a, blocker);
    defer a.free(who);
    try std.testing.expect(std.mem.indexOf(u8, who, "puede modificarla") != null);
    const unnamed = try describeBlocker(a, stranger_for_text ++ "|");
    defer a.free(unnamed);
    try std.testing.expect(std.mem.indexOf(u8, unnamed, "no corresponde a ninguna cuenta") != null);
    const named = try describeBlocker(a, "S-1-1-0|\\Todos");
    defer a.free(named);
    try std.testing.expectEqualStrings("\\Todos (S-1-1-0) puede modificarla", named);
}
const stranger_for_text = "S-1-5-21-1450992000-2083255000-1303809000-1697252000";

/// nombre de la aplicación propietaria de una SID de paquete (S-1-15-2-…
/// o S-1-15-3-… con siete RID), según el registro de AppContainer del
/// usuario. null = desconocida (SID huérfana: la app ya no está instalada).
pub fn appContainerAppName(a: std.mem.Allocator, sid: []const u8) !?[]u8 {
    if (!is_windows) return null;
    const z = try a.dupeZ(u8, sid);
    defer a.free(z);
    var buf: [512]u8 = @splat(0);
    if (da_appcontainer_app_name(z.ptr, &buf, buf.len) != 1) return null;
    return try a.dupe(u8, std.mem.sliceTo(&buf, 0));
}

/// las SID de AppContainer con escritura aceptadas llegan del C con el
/// prefijo «w:» dentro de la misma lista de señales; esto separa las dos.
pub fn isAppContainerWriterLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "w:");
}

/// B1: frase para Configuración › Agentes externos de un escritor huérfano
/// aceptado en la instalación elegida.
pub fn describeOrphans(a: std.mem.Allocator, orphans: []const u8) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var lines = std.mem.tokenizeScalar(u8, orphans, '\n');
    while (lines.next()) |sid| {
        try out.appendSlice(a, if (out.items.len == 0) "aceptado; escritor huérfano " else ", ");
        try out.appendSlice(a, sid);
    }
    if (out.items.len == 0) return null;
    try out.appendSlice(a, " (SID sin cuenta en este equipo: nadie puede iniciar sesión con ella)");
    return try out.toOwnedSlice(a);
}

test "B1 ACL: el texto del huérfano aceptado" {
    const a = std.testing.allocator;
    try std.testing.expect((try describeOrphans(a, "")) == null);
    const one = (try describeOrphans(a, "S-1-5-21-1-2-3-4\nS-1-5-21-5-6-7-8\n")).?;
    defer a.free(one);
    try std.testing.expectEqualStrings("aceptado; escritor huérfano S-1-5-21-1-2-3-4, S-1-5-21-5-6-7-8 (SID sin cuenta en este equipo: nadie puede iniciar sesión con ella)", one);
}

test "USUARIO-NUEVO A1: ninguna CLI hereda claves ni desvíos de facturación del anfitrión" {
    const a = std.testing.allocator;
    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    for (BILLING_ENV_VARS) |key| try parent.put(key, "synthetic");
    for (ROUTING_ENV_VARS) |key| try parent.put(key, "synthetic");
    try parent.put("PATH", "C:\\runtime");
    try parent.put("USERPROFILE", "C:\\profile");
    for ([_][]const u8{ "claude-code", "opencode", "gemini-cli", "codex" }) |cli| {
        var child = try cliEnvironment(a, &parent, cli);
        defer child.deinit();
        for (BILLING_ENV_VARS) |key| try std.testing.expect(!child.contains(key));
        if (!std.mem.eql(u8, cli, "codex")) for (ROUTING_ENV_VARS) |key| try std.testing.expect(!child.contains(key));
        try std.testing.expectEqualStrings("C:\\runtime", child.get("PATH").?);
    }
    // El anfitrión no se toca.
    for (BILLING_ENV_VARS) |key| try std.testing.expect(parent.contains(key));
    const Presence = struct {
        fn present(name: [:0]const u8) bool {
            return std.mem.eql(u8, name, "ANTHROPIC_API_KEY") or std.mem.eql(u8, name, "TOKENROUTER_API_KEY");
        }
    };
    const claude = (try ignoredBillingVars(a, "claude-code", Presence.present)).?;
    defer a.free(claude);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", claude);
    const opencode = (try ignoredBillingVars(a, "opencode", Presence.present)).?;
    defer a.free(opencode);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY, TOKENROUTER_API_KEY", opencode);
    try std.testing.expect((try ignoredBillingVars(a, "gemini-cli", Presence.present)) == null);
}

pub fn codexBilling(env: *const std.process.Environ.Map) bool {
    for (CODEX_BILLING_ENV_VARS) |key| if (env.get(key)) |value| if (value.len > 0) return true;
    return false;
}

pub fn codexHomeId(env: *const std.process.Environ.Map) ![64]u8 {
    const home = env.get("CODEX_HOME") orelse return error.InvalidEnvironment;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(home, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn codexAuthMode(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !@import("external_agent_catalog.zig").Session {
    const home = env.get("CODEX_HOME") orelse return error.InvalidEnvironment;
    var root = try confined.Root.initSecurity(a, home);
    defer root.deinit();
    for (root.handles.items) |handle| try checkOwner(handle);
    try checkCodexProfileAcl(root.dir().handle);
    try checkCodexConfig(a, io, &root);
    const file = root.open("auth.json") catch |e| switch (e) {
        error.FileNotFound => return .sin_sesion,
        else => return e,
    };
    defer file.close(io);
    try checkOwner(file.handle);
    try checkCodexProfileAcl(file.handle);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 1024 * 1024) return error.InvalidCodexAuth;
    const data = try a.alloc(u8, @intCast(stat.size));
    defer a.free(data);
    if (try file.readPositionalAll(io, data, 0) != data.len) return error.CodexAuthReadIncomplete;
    return @import("external_agent_catalog.zig").parseCodexAuthMode(a, data);
}

/// T2d-D6: sesión de Gemini CLI leyendo solo su configuración local, sin red
/// y sin conservar ningún valor. Orden de Gemini CLI: settings.json de sistema
/// (manda sobre el de usuario), el del usuario y, si ninguno elige método, el
/// entorno: variable del proceso y, si falta, el primer .env de la carpeta de
/// usuario (`.gemini\.env`, luego `.env`). Límite conocido: el settings.json y
/// el .env del propio proyecto, que Gemini también lee, no existen al detectar.
pub fn geminiSessionProbe(a: std.mem.Allocator, io: std.Io, getenv: GetEnvFn) !catalog_mod.GeminiSession {
    const home = (try getenv(a, "GEMINI_CLI_HOME")) orelse (try getenv(a, "USERPROFILE")) orelse
        return .{ .session = .desconocida, .reason = "no se encontró la carpeta de usuario para leer la configuración de Gemini CLI" };
    defer a.free(home);
    const system_path = (try getenv(a, "GEMINI_CLI_SYSTEM_SETTINGS_PATH")) orelse try a.dupe(u8, "C:\\ProgramData\\gemini-cli\\settings.json");
    defer a.free(system_path);
    const user_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".gemini" ++ std.fs.path.sep_str ++ "settings.json", .{home});
    defer a.free(user_path);
    var auth: catalog_mod.GeminiAuth = .none;
    for ([_][]const u8{ system_path, user_path }) |path| {
        const body = (readOptional(a, io, path) catch |e| {
            if (e == error.OutOfMemory) return e;
            return .{ .session = .desconocida, .reason = "no se pudo leer la configuración de Gemini CLI (settings.json)" };
        }) orelse continue;
        defer a.free(body);
        const selected = (try catalog_mod.parseGeminiSelectedType(a, body)) orelse
            return .{ .session = .desconocida, .reason = "la configuración de Gemini CLI (settings.json) no es un JSON válido" };
        if (selected != .none) {
            auth = selected;
            break;
        }
    }
    var dotenv: ?[]u8 = null;
    defer if (dotenv) |text| {
        std.crypto.secureZero(u8, text);
        a.free(text);
    };
    for ([_][]const u8{ ".gemini\\.env", ".env" }) |rel| {
        const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ home, rel });
        defer a.free(path);
        dotenv = readOptional(a, io, path) catch |e| if (e == error.OutOfMemory) return e else null;
        if (dotenv != null) break;
    }
    const env: catalog_mod.GeminiEnv = .{
        .gca = try geminiVar(a, getenv, dotenv, "GOOGLE_GENAI_USE_GCA", .true_value),
        .vertex = try geminiVar(a, getenv, dotenv, "GOOGLE_GENAI_USE_VERTEXAI", .true_value),
        .gateway = try geminiVar(a, getenv, dotenv, "GOOGLE_GEMINI_BASE_URL", .non_empty),
        .api_key = try geminiVar(a, getenv, dotenv, "GEMINI_API_KEY", .non_empty),
        .adc = try geminiVar(a, getenv, dotenv, "CLOUD_SHELL", .true_value) or try geminiVar(a, getenv, dotenv, "GEMINI_CLI_USE_COMPUTE_ADC", .true_value),
        .project = try geminiVar(a, getenv, dotenv, "GOOGLE_CLOUD_PROJECT", .non_empty) or try geminiVar(a, getenv, dotenv, "GOOGLE_CLOUD_PROJECT_ID", .non_empty),
    };
    if (auth == .none) auth = catalog_mod.geminiAuthFromEnv(env);
    return catalog_mod.geminiSession(auth, env.project);
}

const catalog_mod = @import("external_agent_catalog.zig");

fn readOptional(a: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

const VarCheck = enum { true_value, non_empty };

/// Solo devuelve si la variable cumple la condición; el valor (puede ser una
/// clave) se borra antes de liberarlo.
fn geminiVar(a: std.mem.Allocator, getenv: GetEnvFn, dotenv: ?[]const u8, name: []const u8, check: VarCheck) !bool {
    if (try getenv(a, name)) |value| {
        defer {
            std.crypto.secureZero(u8, value);
            a.free(value);
        }
        return holds(value, check);
    }
    const text = dotenv orelse return false;
    const value = catalog_mod.dotenvValue(text, name) orelse return false;
    return holds(value, check);
}

fn holds(value: []const u8, check: VarCheck) bool {
    return switch (check) {
        .true_value => std.mem.eql(u8, value, "true"),
        .non_empty => value.len > 0,
    };
}

const GeminiProbeEnv = struct {
    var pairs: []const [2][]const u8 = &.{};
    fn get(a: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
        for (pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return try a.dupe(u8, pair[1]);
        return null;
    }
    fn run(a: std.mem.Allocator, io: std.Io, with: []const [2][]const u8) !catalog_mod.GeminiSession {
        pairs = with;
        defer pairs = &.{};
        return geminiSessionProbe(a, io, get);
    }
};

test "T2d-D6: la sonda de Gemini lee settings.json de sistema y de usuario y el .env, sin red" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    try tmp.dir.createDirPath(io, "home\\.gemini");
    try tmp.dir.createDirPath(io, "sys");
    const home = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "home", .{base});
    defer a.free(home);
    const system = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "sys" ++ std.fs.path.sep_str ++ "settings.json", .{base});
    defer a.free(system);
    const Session = catalog_mod.Session;
    const env = [_][2][]const u8{ .{ "USERPROFILE", home }, .{ "GEMINI_CLI_SYSTEM_SETTINGS_PATH", system } };

    // Nada configurado: sin sesión.
    try std.testing.expectEqual(Session.sin_sesion, (try GeminiProbeEnv.run(a, io, &env)).session);
    // Usuario con clave de API (el caso del equipo del propietario): facturación por API.
    try tmp.dir.writeFile(io, .{ .sub_path = "home\\.gemini\\settings.json", .data = "{\n  // comentario\n  \"security\": {\"auth\": {\"selectedType\": \"gemini-api-key\"}}\n}" });
    try std.testing.expectEqual(Session.api_key, (try GeminiProbeEnv.run(a, io, &env)).session);
    // El de sistema manda sobre el de usuario.
    try tmp.dir.writeFile(io, .{ .sub_path = "sys\\settings.json", .data = "{\"security\":{\"auth\":{\"selectedType\":\"oauth-personal\"}}}" });
    const personal = try GeminiProbeEnv.run(a, io, &env);
    try std.testing.expectEqual(Session.sin_sesion, personal.session);
    try std.testing.expect(std.mem.indexOf(u8, personal.reason, "cuenta personal de Google") != null);
    // Cuenta de Google + proyecto en el .env de usuario: licencia de empresa.
    try tmp.dir.writeFile(io, .{ .sub_path = "home\\.gemini\\.env", .data = "GOOGLE_CLOUD_PROJECT=empresa-123\n" });
    try std.testing.expectEqual(Session.suscripcion, (try GeminiProbeEnv.run(a, io, &env)).session);
    // El proyecto también vale como variable del proceso.
    try tmp.dir.deleteFile(io, "home\\.gemini\\.env");
    const with_project = env ++ [_][2][]const u8{.{ "GOOGLE_CLOUD_PROJECT_ID", "empresa-123" }};
    try std.testing.expectEqual(Session.suscripcion, (try GeminiProbeEnv.run(a, io, &with_project)).session);
    // Sin método en ningún settings.json, manda el entorno.
    try tmp.dir.writeFile(io, .{ .sub_path = "sys\\settings.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home\\.gemini\\settings.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home\\.env", .data = "GEMINI_API_KEY=clave-sintetica\n" });
    try std.testing.expectEqual(Session.api_key, (try GeminiProbeEnv.run(a, io, &env)).session);
    const vertex = env ++ [_][2][]const u8{.{ "GOOGLE_GENAI_USE_VERTEXAI", "true" }};
    try std.testing.expectEqual(Session.api_key, (try GeminiProbeEnv.run(a, io, &vertex)).session);
    const gca = env ++ [_][2][]const u8{.{ "GOOGLE_GENAI_USE_GCA", "true" }};
    try std.testing.expectEqual(Session.sin_sesion, (try GeminiProbeEnv.run(a, io, &gca)).session);
    // Un settings.json roto no se adivina.
    try tmp.dir.writeFile(io, .{ .sub_path = "home\\.gemini\\settings.json", .data = "{roto" });
    try std.testing.expectEqual(Session.desconocida, (try GeminiProbeEnv.run(a, io, &env)).session);
    // Sin carpeta de usuario tampoco.
    try std.testing.expectEqual(Session.desconocida, (try GeminiProbeEnv.run(a, io, &.{})).session);
}

test "tanda 2: una carpeta del PATH que es un enlace se resuelve a su destino (node de nvm-windows)" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: carpeta del PATH enlazada con junction (nvm-windows)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const target = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "destino", .{base});
    defer a.free(target);
    try std.Io.Dir.cwd().createDirPath(io, target);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "enlace", .{base});
    defer a.free(link);
    @import("workspace.zig").createJunction(a, link, target) catch return error.SkipZigTest;
    const got = (try linkTarget(a, link)) orelse return error.TestUnexpectedResult;
    defer a.free(got);
    try std.testing.expect(std.ascii.endsWithIgnoreCase(got, "\\destino"));
    // Una carpeta normal no es un enlace: no hay destino distinto.
    try std.testing.expect((try linkTarget(a, target)) == null);
    // Lo que no existe tampoco.
    const missing = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "no-existe", .{base});
    defer a.free(missing);
    try std.testing.expect((try linkTarget(a, missing)) == null);
}

test "T2d-D3: el node de un shim tras un enlace fuera de las raíces se verifica en su destino" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const trusted = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "confiable", .{base});
    defer a.free(trusted);
    TestEnv.root = trusted;
    defer TestEnv.root = "";
    try tmp.dir.createDirPath(io, "confiable/nvm/v1");
    var created = try tmp.dir.createFile(io, "confiable/nvm/v1/node.exe", .{});
    created.close(io);
    const version_dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "nvm" ++ std.fs.path.sep_str ++ "v1", .{trusted});
    defer a.free(version_dir);
    // Como `C:\nvm4w\nodejs`: enlace FUERA de la raíz hacia la versión activa.
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "nvm4w", .{base});
    defer a.free(link);
    @import("workspace.zig").createJunction(a, link, version_dir) catch return error.SkipZigTest;
    defer tmp.dir.deleteDir(io, "nvm4w") catch |e| std.debug.print("T2d-D3 limpieza del enlace: {s}\n", .{@errorName(e)});
    const via_link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "node.exe", .{link});
    defer a.free(via_link);
    // Antes del arreglo el lanzador solo hacía esto, y Gemini CLI se descartaba.
    try std.testing.expectError(error.UntrustedCliRoot, verifyWithPolicy(a, via_link, TestEnv.get, TestEnv.syntheticAcl, TestEnv.syntheticAcl));
    var verified = try verifyFollowingLinkWithPolicy(a, via_link, TestEnv.get, TestEnv.syntheticAcl, TestEnv.syntheticAcl);
    defer verified.deinit();
    try std.testing.expect(std.ascii.endsWithIgnoreCase(verified.path, "\\confiable\\nvm\\v1\\node.exe"));
    // Un enlace DENTRO de la raíz no se sigue: sigue siendo un alias.
    const inner = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias", .{trusted});
    defer a.free(inner);
    @import("workspace.zig").createJunction(a, inner, version_dir) catch return error.SkipZigTest;
    defer tmp.dir.deleteDir(io, "confiable/alias") catch |e| std.debug.print("T2d-D3 limpieza del alias: {s}\n", .{@errorName(e)});
    const inner_node = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "node.exe", .{inner});
    defer a.free(inner_node);
    try std.testing.expectError(error.CliReparseOrAlias, verifyFollowingLinkWithPolicy(a, inner_node, TestEnv.get, TestEnv.syntheticAcl, TestEnv.syntheticAcl));
}

test "RELOJ child environment removes parent keys and preserves home PATH and unrelated billing guard" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("openai_api_key", "synthetic-openai");
    try parent.put("CODEX_API_KEY", "synthetic-codex");
    try parent.put("TOKENROUTER_API_KEY", "synthetic-router");
    try parent.put("CODEX_HOME", "C:\\profile\\codex");
    try parent.put("PATH", "C:\\runtime");
    var child = try codexEnvironment(a, &parent);
    defer child.deinit();
    try std.testing.expect(!child.contains("OPENAI_API_KEY"));
    try std.testing.expect(!child.contains("CODEX_API_KEY"));
    try std.testing.expect(parent.contains("OPENAI_API_KEY"));
    try std.testing.expect(parent.contains("CODEX_API_KEY"));
    // Ninguna variable de facturación de otro proveedor llega al hijo (un
    // env_key de config.toml podría nombrarla); el padre las conserva.
    try parent.put("ANTHROPIC_API_KEY", "synthetic-anthropic");
    try parent.put("OPENROUTER_API_KEY", "synthetic-openrouter");
    try parent.put("OPENAI_BASE_URL", "https://router.example/v1");
    var filtered = try codexEnvironment(a, &parent);
    defer filtered.deinit();
    for (BILLING_ENV_VARS) |key| try std.testing.expect(!filtered.contains(key));
    try std.testing.expect(!filtered.contains("OPENAI_BASE_URL"));
    try std.testing.expect(parent.contains("TOKENROUTER_API_KEY") and parent.contains("ANTHROPIC_API_KEY") and parent.contains("OPENROUTER_API_KEY") and parent.contains("OPENAI_BASE_URL"));
    try std.testing.expectEqualStrings(parent.get("CODEX_HOME").?, child.get("CODEX_HOME").?);
    try std.testing.expectEqual(try codexHomeId(&parent), try codexHomeId(&child));
    try std.testing.expectEqualStrings(parent.get("PATH").?, child.get("PATH").?);
    try std.testing.expect(!codexBilling(&child));
    try child.put("OPENAI_API_KEY", "synthetic");
    try std.testing.expect(codexBilling(&child));
    _ = child.swapRemove("OPENAI_API_KEY");
    try child.put("CODEX_API_KEY", "synthetic");
    try std.testing.expect(codexBilling(&child));
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, codexEnvironment(fail.allocator(), &parent));
    _ = parent.swapRemove("CODEX_HOME");
    try std.testing.expectError(error.InvalidEnvironment, codexEnvironment(a, &parent));
    try parent.put("USERPROFILE", "C:\\profile");
    var default = try codexEnvironment(a, &parent);
    defer default.deinit();
    try std.testing.expectEqualStrings("C:\\profile\\.codex", default.get("CODEX_HOME").?);
    try parent.put("CODEX_HOME", "relative");
    try std.testing.expectError(error.InvalidEnvironment, codexEnvironment(a, &parent));
}

test "RELOJ real child has no API keys with a synthetic parent and matching CODEX_HOME" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    var parent = try @import("platform.zig").environ().createMap(a);
    defer parent.deinit();
    try parent.put("OPENAI_API_KEY", "synthetic-openai");
    try parent.put("CODEX_API_KEY", "synthetic-codex");
    var child = try codexEnvironment(a, &parent);
    defer child.deinit();
    const node = try @import("executor.zig").resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    const script = "if(process.env.OPENAI_API_KEY||process.env.CODEX_API_KEY)process.exit(3);if(process.env.CODEX_HOME!==process.argv[1])process.exit(4);console.log('RELOJ_CHILD_KEYS_ABSENT=true;CODEX_HOME_MATCH=true');";
    var worker = @import("cli_worker.zig").ExternalCliWorker.init(a, threaded.io(), &.{ node, "-e", script, child.get("CODEX_HOME").? }, 30000);
    worker.environ_map = &child;
    worker.stdin_mode = .none;
    var outcome = try worker.runCollect(a, .{ .id = "reloj-env", .task_type = .auditar, .department = "auditoria", .description = "", .contract_fields = &.{}, .depends_on = &.{} });
    defer outcome.deinit(a);
    try std.testing.expect(!outcome.timed_out);
    try std.testing.expectEqual(@as(?u8, 0), outcome.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.output, "RELOJ_CHILD_KEYS_ABSENT=true;CODEX_HOME_MATCH=true") != null);
    try std.testing.expect(parent.contains("OPENAI_API_KEY") and parent.contains("CODEX_API_KEY"));
    std.debug.print("RELOJ_CHILD_KEYS_ABSENT=true;CODEX_HOME_MATCH=true;PARENT_UNCHANGED=true\n", .{});
}

test "RELOJ auth metadata changes block cached subscription before a CLI is sent" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const home = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "codex", .{base});
    defer a.free(home);
    try createPrivateDirectory(a, home);
    var dir = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer dir.close(io);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CODEX_HOME", home);
    try std.testing.expectEqual(@import("external_agent_catalog.zig").Session.sin_sesion, try codexAuthMode(a, io, &env));
    try dir.writeFile(io, .{ .sub_path = "auth.json", .data = "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":null}" });
    try std.testing.expectEqual(@import("external_agent_catalog.zig").Session.suscripcion, try codexAuthMode(a, io, &env));
    const db = @import("db.zig");
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);
    const home_id = try codexHomeId(&env);
    const detected = try std.json.Stringify.valueAlloc(a, .{.{
        .provider = "agent:codex",
        .cli = "codex",
        .session = "suscripcion",
        .codex_home_id = @as([]const u8, &home_id),
        .exe = "C:\\must-not-launch.exe",
        .version = "0.159.2",
        .models = .{.{ .slug = "gpt-6-luna" }},
    }}, .{});
    defer a.free(detected);
    const insert = try conn.prepare("INSERT INTO external_agent_cache(id,payload_json,detected_at) VALUES(1,?,1000)");
    defer conn.finalize(insert);
    try db.bindText(insert, 1, detected);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(insert));
    for ([_][]const u8{ "{\"auth_mode\":\"apikey\"}", "{\"auth_mode\":\"other\"}" }, [_]@import("external_agent_catalog.zig").Session{ .api_key, .desconocida }) |text, expected| {
        try dir.writeFile(io, .{ .sub_path = "auth.json", .data = text });
        try std.testing.expectEqual(expected, try @import("external_agents.zig").revalidateCodex(a, io, "C:\\missing-cli.exe", &env));
        if (expected == .api_key) {
            try std.testing.expectError(error.ApiBillingForbidden, @import("external_registry.zig").revalidateCodexPin(a, conn, detected, "gpt-6-luna", io, &env));
        } else {
            try std.testing.expectError(error.NotLoggedIn, @import("external_registry.zig").revalidateCodexPin(a, conn, detected, "gpt-6-luna", io, &env));
        }
    }
}

pub fn getEnv(a: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (!is_windows) {
        const z = try a.dupeZ(u8, name);
        defer a.free(z);
        const raw = std.c.getenv(z) orelse return null;
        return try a.dupe(u8, std.mem.span(raw));
    }
    const key = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
    defer a.free(key);
    const needed = GetEnvironmentVariableW(key, null, 0);
    if (needed == 0) return null;
    if (needed > 32768) return error.EnvironmentTooLong;
    const value = try a.alloc(u16, needed);
    defer a.free(value);
    const len = GetEnvironmentVariableW(key, value.ptr, needed);
    if (len == 0 or len >= needed) return error.EnvironmentChanged;
    return try std.unicode.utf16LeToUtf8Alloc(a, value[0..len]);
}

fn localPath(path: []const u8) bool {
    if (path.len < 3 or path.len > 32760 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) return false;
    // e5-harden punto 5: `;`, `,` y `=` son separadores de argumentos de cmd.exe.
    for (path[2..]) |c| if (c < 32 or std.mem.indexOfScalar(u8, ":\"&|<>^%!*?;,=", c) != null) return false;
    var parts = std.mem.splitAny(u8, path[3..], "/\\");
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
    }
    return true;
}

pub fn validBinaryPath(path: []const u8) bool {
    return localPath(path) and (std.ascii.endsWithIgnoreCase(path, ".exe") or std.ascii.endsWithIgnoreCase(path, ".cmd") or std.ascii.endsWithIgnoreCase(path, ".bat"));
}

fn inside(root: []const u8, path: []const u8) bool {
    const base = std.mem.trimEnd(u8, root, "\\");
    return path.len >= base.len and std.ascii.eqlIgnoreCase(path[0..base.len], base) and (path.len == base.len or path[base.len] == '\\');
}

const locations = .{
    .{ "APPDATA", "\\npm" },
    .{ "LOCALAPPDATA", "\\OpenAI\\Codex\\bin" },
    .{ "LOCALAPPDATA", "\\Programs\\Codex" },
    .{ "LOCALAPPDATA", "\\Programs\\Claude" },
    .{ "LOCALAPPDATA", "\\Programs\\OpenCode" },
    .{ "LOCALAPPDATA", "\\Programs\\Gemini" },
    .{ "LOCALAPPDATA", "\\Programs\\nodejs" },
    // 9-nov: instalador nativo oficial de Claude Code (`claude install`):
    // %USERPROFILE%\.local\bin\claude.exe. Sin esta raíz se elegía el shim de
    // npm (más viejo) aunque el nativo fuera el primero del PATH. Mismas
    // comprobaciones de propietario, ACL y reparse que el resto de raíces.
    .{ "USERPROFILE", "\\.local\\bin" },
    // B1 (10-nov): donde bun, pnpm, Volta, nvm y fnm dejan los ejecutables
    // globales. Carpetas del perfil del usuario, como `%APPDATA%\npm`: mismas
    // comprobaciones de propietario, ACL y reanálisis; ser raíz no acepta nada.
    .{ "USERPROFILE", "\\.bun" },
    .{ "LOCALAPPDATA", "\\pnpm" },
    .{ "LOCALAPPDATA", "\\Volta" },
    .{ "APPDATA", "\\nvm" },
    // Tanda 2 (12-nov): nvm-windows 1.2 («nvm4w») instala las versiones en
    // %LOCALAPPDATA%\nvm y pone en el PATH un enlace (NVM_SYMLINK) a la activa.
    .{ "LOCALAPPDATA", "\\nvm" },
    .{ "APPDATA", "\\fnm" },
    .{ "ProgramFiles", "" },
    .{ "ProgramFiles(x86)", "" },
};

fn trustedRoot(a: std.mem.Allocator, path: []const u8, getenv: GetEnvFn) !?[]u8 {
    inline for (locations) |location| {
        if (try getenv(a, location[0])) |base| {
            defer a.free(base);
            const root = try std.fmt.allocPrint(a, "{s}{s}", .{ base, location[1] });
            errdefer a.free(root);
            if (localPath(root) and inside(root, path)) return root;
            a.free(root);
        }
    }
    return null;
}

/// Destino final de una carpeta del PATH que es (o atraviesa) un enlace; null
/// si no existe, no se puede abrir o ya es su propio destino.
fn linkTarget(a: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (!is_windows) return error.ExternalCliUnavailableOnLinux;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    // FILE_READ_ATTRIBUTES, compartido, OPEN_EXISTING y BACKUP_SEMANTICS
    // (carpetas), SIGUIENDO el enlace: aquí se quiere el destino.
    const handle = CreateFileW(wide.ptr, 0x80, 7, null, 3, 0x02000000, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(handle);
    const target = finalName(a, handle) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    if (std.ascii.eqlIgnoreCase(target, path)) {
        a.free(target);
        return null;
    }
    return target;
}

fn finalName(a: std.mem.Allocator, handle: windows.HANDLE) ![]u8 {
    var wide: [32768]u16 = undefined;
    const n = GetFinalPathNameByHandleW(handle, &wide, wide.len, 0);
    if (n == 0 or n >= wide.len) return error.CliCanonicalizationFailed;
    const text = try std.unicode.utf16LeToUtf8Alloc(a, wide[0..n]);
    defer a.free(text);
    if (!std.mem.startsWith(u8, text, "\\\\?\\") or std.mem.startsWith(u8, text, "\\\\?\\UNC\\")) return error.InvalidExternalAgentPath;
    return a.dupe(u8, text[4..]);
}

/// T9 (decision del dueno, 13-nov): en POSIX la confianza de una CLI, de su
/// instalacion o de una carpeta gobernada es propietario (el usuario actual o
/// root) y permisos sin escritura de grupo ni de otros. No hay ACL ni firma.
fn posixTrust(handle: std.posix.fd_t) !void {
    const meta = @import("providers").posix_stat.get(handle, null) catch return error.CliPermissionsUnavailable;
    if (meta.uid != std.c.getuid() and meta.uid != 0) return error.CliUntrustedOwner;
    if (meta.mode & 0o022 != 0) return error.CliWritableByOthers;
}

pub fn checkAcl(handle: std.posix.fd_t) !void {
    if (!is_windows) return posixTrust(handle);
    switch (da_cli_acl_safe(handle)) {
        1 => {},
        0 => return error.CliWritableByOthers,
        2 => return error.CliUntrustedOwner,
        -3 => return error.CodexSandboxUnavailable,
        else => return error.CliPermissionsUnavailable,
    }
}

/// B1 (10-nov): compuerta de EJECUTABLES y de su instalación. Igual que
/// `checkAcl`, salvo que un escritor huérfano (SID de cuenta S-1-5-21-… que no
/// resuelve a ninguna cuenta: nadie puede iniciar sesión con ella) no bloquea;
/// se acepta y `verify` lo deja anotado en `acl_orphan_sids`. Las carpetas de
/// trabajo gobernadas (workspace.zig, workspace_acl.zig, la reparación de
/// c_api.zig) siguen con `checkAcl`, estricta: no son una instalación, y un
/// falso aceptado ahí deja a un escritor ajeno dentro del árbol que el agente
/// gobierna, mientras que un falso rechazo solo pide reparar los permisos.
pub fn checkBinaryAcl(handle: std.posix.fd_t) !void {
    if (!is_windows) return posixTrust(handle);
    switch (da_cli_binary_acl_inspect(handle, null, 0, null, 0)) {
        1 => {},
        0 => return error.CliWritableByOthers,
        2 => return error.CliUntrustedOwner,
        -3 => return error.CodexSandboxUnavailable,
        else => return error.CliPermissionsUnavailable,
    }
}

/// 10-nov (USUARIO-NUEVO A2): quién hace escribible una instalación rechazada,
/// «SID|DOMINIO\nombre» (nombre vacío si la SID no corresponde a ninguna
/// cuenta). null si la ACL es segura o no se pudo inspeccionar.
pub fn aclBlocker(a: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (!is_windows) return error.ExternalCliUnavailableOnLinux;
    // El binario y, si él está limpio, las carpetas que lo contienen (la
    // comprobación de instalación mira también los directorios).
    var current: []const u8 = path;
    var level: usize = 0;
    while (level < 4) : (level += 1) {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, current);
        defer a.free(wide);
        // Solo READ_CONTROL: se lee el descriptor, nunca el contenido.
        const handle = CreateFileW(wide, 0x00020000, 7, null, 3, 0x02200000, null);
        if (handle != windows.INVALID_HANDLE_VALUE) {
            defer _ = CloseHandle(handle);
            var buffer: [768]u8 = @splat(0);
            if (da_cli_acl_blocker(handle, &buffer, buffer.len) == 0) {
                const text = std.mem.sliceTo(&buffer, 0);
                if (text.len > 0) return try a.dupe(u8, text);
            }
        }
        current = std.fs.path.dirnameWindows(current) orelse return null;
    }
    return null;
}

/// Frase legible de un escritor ajeno («S-1-5-21-…, sin cuenta conocida»).
pub fn describeBlocker(a: std.mem.Allocator, blocker: []const u8) ![]u8 {
    const bar = std.mem.indexOfScalar(u8, blocker, '|') orelse blocker.len;
    const sid = blocker[0..bar];
    const name = if (bar < blocker.len) blocker[bar + 1 ..] else "";
    if (name.len > 0) return std.fmt.allocPrint(a, "{s} ({s}) puede modificarla", .{ name, sid });
    return std.fmt.allocPrint(a, "la SID {s}, que no corresponde a ninguna cuenta de este equipo ni al sandbox oficial de Codex, puede modificarla", .{sid});
}

/// Only CODEX_HOME and auth.json may trust the official local sandbox alias
/// and its direct local user members. Binary checkAcl and owner gates are
/// unchanged; unresolved membership fails closed.
fn checkCodexProfileAcl(handle: std.posix.fd_t) !void {
    if (!is_windows) return posixTrust(handle);
    switch (da_codex_profile_acl_safe(handle)) {
        1 => {},
        0 => return error.CliWritableByOthers,
        2 => return error.CliUntrustedOwner,
        -3 => return error.CodexSandboxUnavailable,
        else => return error.CliPermissionsUnavailable,
    }
}

/// config.toml no puede apuntar a otro proveedor: un `model_provider` distinto
/// de «openai», un `env_key` (clave por variable de entorno) o un `*base_url`
/// que no sea el de ChatGPT convierten la sesión en facturación por API.
/// Escaneo por línea, sin intérprete TOML completo, y a propósito estricto: se
/// buscan las claves como texto (también dentro de tablas en línea) y todo
/// `env_key` cuenta, sin mirar su valor.
pub fn codexConfigOverridesProvider(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = tomlStripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        // Una clave que esconde «env_key», «base_url» o «model_provider» con
        // escapes TOML (solo posibles entre comillas dobles) cuenta como
        // proveedor propio; las rutas de Windows no.
        if (basicKeyHidesProvider(tomlKeyPart(line))) return true;
        if (tomlKeyValue(line, "env_key") != null) return true;
        if (tomlKeyValue(line, "model_provider")) |value| {
            if (!std.mem.eql(u8, tomlString(value), "openai")) return true;
        }
        if (tomlKeyValue(line, "base_url")) |value| {
            if (!std.ascii.startsWithIgnoreCase(tomlString(value), "https://chatgpt.com/") and !std.ascii.eqlIgnoreCase(tomlString(value), "https://chatgpt.com")) return true;
        }
    }
    return false;
}

/// Longitud vigilada por la ventana deslizante: la clave sensible más larga es
/// «model_provider».
const provider_name_len = "model_provider".len;

/// Un escape TOML de una cadena básica («...»). `rest[0]` es el carácter que
/// sigue a la barra invertida; `consumed` cuenta los bytes posteriores a la
/// barra que forman el escape.
const Escape = struct {
    byte: u8,
    consumed: usize,
    valid: bool,
};

fn basicEscape(rest: []const u8) Escape {
    if (rest.len == 0) return .{ .byte = 0, .consumed = 0, .valid = false };
    const c = rest[0];
    const simple: ?u8 = switch (c) {
        '"' => '"',
        '\\' => '\\',
        'b' => 0x08,
        't' => '\t',
        'n' => '\n',
        'f' => 0x0c,
        'r' => '\r',
        else => null,
    };
    if (simple) |byte| return .{ .byte = byte, .consumed = 1, .valid = true };
    if (c != 'u' and c != 'U') return .{ .byte = 0, .consumed = 0, .valid = false };
    const digits: usize = if (c == 'u') 4 else 8;
    if (rest.len < 1 + digits) return .{ .byte = 0, .consumed = 0, .valid = false };
    var codepoint: u32 = 0;
    for (rest[1 .. 1 + digits]) |h| {
        const value = std.fmt.charToDigit(h, 16) catch return .{ .byte = 0, .consumed = 0, .valid = false };
        codepoint = codepoint * 16 + value;
    }
    if (codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF)) return .{ .byte = 0, .consumed = 0, .valid = false };
    // Los nombres buscados son ASCII; un codepoint no ASCII se marca con 0xff
    // para romper cualquier coincidencia sin decodificar UTF-8 completo.
    return .{ .byte = if (codepoint < 0x80) @intCast(codepoint) else 0xff, .consumed = 1 + digits, .valid = true };
}

/// Ventana deslizante del texto decodificado de una clave, con la marca de qué
/// bytes vinieron de un escape. Bloquea si la clave decodificada esconde
/// «env_key», «base_url» o «model_provider» a través de un escape.
const KeyProbe = struct {
    window: [provider_name_len]u8 = undefined,
    escaped: [provider_name_len]bool = undefined,
    len: usize = 0,

    fn push(self: *KeyProbe, byte: u8, from_escape: bool) void {
        if (self.len < self.window.len) {
            self.window[self.len] = byte;
            self.escaped[self.len] = from_escape;
            self.len += 1;
            return;
        }
        std.mem.copyForwards(u8, self.window[0 .. self.window.len - 1], self.window[1..]);
        std.mem.copyForwards(bool, self.escaped[0 .. self.escaped.len - 1], self.escaped[1..]);
        self.window[self.window.len - 1] = byte;
        self.escaped[self.escaped.len - 1] = from_escape;
    }

    fn hidesProvider(self: *const KeyProbe) bool {
        for ([_][]const u8{ "env_key", "base_url", "model_provider" }) |name| {
            var start: usize = 0;
            while (start + name.len <= self.len) : (start += 1) {
                if (!std.ascii.eqlIgnoreCase(self.window[start .. start + name.len], name)) continue;
                for (self.escaped[start .. start + name.len]) |escape| if (escape) return true;
            }
        }
        return false;
    }
};

/// Defensa contra ofuscación de la cabecera de una clave. Solo las cadenas
/// básicas («...») tienen escapes TOML; las literales ('...') y las rutas de
/// Windows (`[projects.'C:\Workspace']`, `[projects."C:\Workspace"]`) no
/// bloquean. Un escape válido que decodifique a `"`, o que revele una de las
/// claves sensibles, sí bloquea; `\\` decodifica a una barra y no oculta nada.
/// Un escape inválido bloquea (estricto: es TOML inválido y Codex no lo
/// aceptaría; el segundo auditor,).
fn basicKeyHidesProvider(keypart: []const u8) bool {
    var probe = KeyProbe{};
    var i: usize = 0;
    while (i < keypart.len) {
        if (keypart[i] != '"') {
            i += 1;
            continue;
        }
        i += 1;
        while (i < keypart.len and keypart[i] != '"') {
            if (keypart[i] == '\\') {
                const esc = basicEscape(keypart[i + 1 ..]);
                if (esc.valid) {
                    if (esc.byte == '"') return true;
                    probe.push(esc.byte, true);
                    i += 1 + esc.consumed;
                } else return true;
            } else {
                probe.push(keypart[i], false);
                i += 1;
            }
            if (probe.hidesProvider()) return true;
        }
        if (i < keypart.len) i += 1; // comilla de cierre
    }
    return false;
}

/// Quita un comentario `#` que no esté dentro de una cadena. En cadenas
/// básicas («...») el carácter que sigue a `\` no cierra la cadena; en las
/// literales ('...') no hay escapes.
fn tomlStripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\') {
                i += 1;
            } else if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') return std.mem.trim(u8, line[0..i], " \t");
    }
    return line;
}

/// Parte de la línea anterior al primer `=` fuera de cadenas (la línea entera
/// si no hay `=`, p. ej. el encabezado de una tabla).
fn tomlKeyPart(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\') {
                i += 1;
            } else if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '=') return line[0..i];
    }
    return line;
}

/// Valor (sin procesar) de la primera `clave = valor` cuyo nombre termina en
/// `key` y no continúa como otra clave más larga.
fn tomlKeyValue(line: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, key)) |i| : (from = i + key.len) {
        if (i > 0 and std.ascii.isAlphanumeric(line[i - 1])) continue;
        var j = i + key.len;
        if (j < line.len and (line[j] == '"' or line[j] == '\'')) j += 1;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        if (j < line.len and line[j] == '=') return std.mem.trim(u8, line[j + 1 ..], " \t");
    }
    return null;
}

/// Contenido de la primera cadena TOML del valor, o el token desnudo.
fn tomlString(value: []const u8) []const u8 {
    if (value.len == 0) return value;
    if (value[0] == '"' or value[0] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, value, 1, value[0]) orelse return value[1..];
        return value[1..end];
    }
    const end = std.mem.indexOfAny(u8, value, " \t,}") orelse value.len;
    return value[0..end];
}

/// config.toml del perfil: mismos propietario y ACL que auth.json, y sin
/// proveedor propio. Ausente = sin proveedores personalizados.
fn checkCodexConfig(a: std.mem.Allocator, io: std.Io, root: *confined.Root) !void {
    const file = root.open("config.toml") catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer file.close(io);
    try checkOwner(file.handle);
    try checkCodexProfileAcl(file.handle);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 1024 * 1024) return error.InvalidCodexConfig;
    const data = try a.alloc(u8, @intCast(stat.size));
    defer a.free(data);
    if (try file.readPositionalAll(io, data, 0) != data.len) return error.CodexAuthReadIncomplete;
    if (codexConfigOverridesProvider(data)) return error.CodexProviderOverride;
}

/// 10-nov (USUARIO-NUEVO A4): `model` y `model_reasoning_effort` de nivel
/// superior de config.toml (antes del primer encabezado `[tabla]`). Sin
/// intérprete TOML completo: el mismo escaneo acotado que el filtro de
/// proveedor. Los valores son datos: el llamador los valida como token.
pub const ConfiguredModel = struct { model: ?[]const u8 = null, effort: ?[]const u8 = null };

pub fn codexConfigModel(text: []const u8) ConfiguredModel {
    var out: ConfiguredModel = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = tomlStripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') break;
        const key_part = tomlKeyPart(line);
        if (key_part.len == line.len) continue;
        const key = std.mem.trim(u8, key_part, " \t\"'");
        const value = tomlString(std.mem.trim(u8, line[key_part.len + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "model")) out.model = value;
        if (std.mem.eql(u8, key, "model_reasoning_effort")) out.effort = value;
    }
    return out;
}

test "USUARIO-NUEVO A4: modelo de config.toml de nivel superior, sin leer tablas" {
    const text =
        \\# perfil del usuario
        \\model = "gpt-6.1-sol"
        \\model_reasoning_effort = 'medium' # comentario
        \\[profiles.otro]
        \\model = "no-este"
    ;
    const got = codexConfigModel(text);
    try std.testing.expectEqualStrings("gpt-6.1-sol", got.model.?);
    try std.testing.expectEqualStrings("medium", got.effort.?);
    const none = codexConfigModel("[tabla]\nmodel = \"x\"\n");
    try std.testing.expect(none.model == null and none.effort == null);
    try std.testing.expect(codexConfigModel("model_provider = \"openai\"\n").model == null);
}

/// Lee config.toml con las mismas comprobaciones de propietario y ACL que auth.json
/// y devuelve una copia de su modelo configurado. Ausente = sin modelo.
pub const OwnedConfiguredModel = struct { model: ?[]u8, effort: ?[]u8 };

pub fn codexConfiguredModel(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !OwnedConfiguredModel {
    const home = env.get("CODEX_HOME") orelse return error.InvalidEnvironment;
    var root = try confined.Root.initSecurity(a, home);
    defer root.deinit();
    const file = root.open("config.toml") catch |e| switch (e) {
        error.FileNotFound => return .{ .model = null, .effort = null },
        else => return e,
    };
    defer file.close(io);
    try checkOwner(file.handle);
    try checkCodexProfileAcl(file.handle);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 1024 * 1024) return error.InvalidCodexConfig;
    const data = try a.alloc(u8, @intCast(stat.size));
    defer a.free(data);
    if (try file.readPositionalAll(io, data, 0) != data.len) return error.CodexAuthReadIncomplete;
    const parsed = codexConfigModel(data);
    const model = if (parsed.model) |m| try a.dupe(u8, m) else null;
    errdefer if (model) |m| a.free(m);
    const effort = if (parsed.effort) |e| try a.dupe(u8, e) else null;
    return .{ .model = model, .effort = effort };
}

fn codexProfileReason(e: anyerror) []const u8 {
    return switch (e) {
        error.CodexProviderOverride => "la sesión queda bloqueada porque podría facturar por API",
        error.InvalidCodexConfig => "tipo o tamaño no válidos",
        error.CliWritableByOthers => "escritor ajeno al sandbox oficial de Codex",
        error.CliUntrustedOwner => "propietario no confiable",
        error.CodexSandboxUnavailable => "no se pudo resolver el grupo local CodexSandboxUsers o verificar sus miembros",
        error.CliPermissionsUnavailable => "no se pudo inspeccionar el descriptor de seguridad",
        error.AccessDenied => "acceso denegado al perfil",
        error.SandboxDenied => "ruta del perfil no confiable (reparse point o alias)",
        else => @errorName(e),
    };
}

pub fn codexProfileFailure(a: std.mem.Allocator, e: anyerror) ![]u8 {
    const category = switch (e) {
        error.CliWritableByOthers, error.CliUntrustedOwner, error.CliPermissionsUnavailable => "perfil de Codex con permisos no verificables",
        error.CodexSandboxUnavailable => "identidad del sandbox oficial de Codex no verificable",
        error.InvalidCodexAuth => "auth.json de Codex inválido (JSON o metadatos)",
        error.CodexProviderOverride => "config.toml de Codex define un proveedor propio (model_provider, env_key o base_url distintos de ChatGPT)",
        error.InvalidCodexConfig => "config.toml de Codex inválido",
        error.InvalidEnvironment, error.EnvironmentTooLong, error.EnvironmentChanged, error.InvalidUtf8 => "entorno de Codex inválido (CODEX_HOME o USERPROFILE)",
        error.SandboxDenied, error.HardLinkDenied, error.RootChanged => "ruta del perfil de Codex no confiable",
        error.OutOfMemory => "no se pudo verificar el perfil de Codex por falta de memoria",
        else => "no se pudo leer el perfil de Codex",
    };
    const reason = switch (e) {
        error.AccessDenied => @errorName(e),
        else => codexProfileReason(e),
    };
    return std.fmt.allocPrint(a, "{s}: {s}", .{ category, reason });
}

test "RELOJ Codex profile synthetic resolver accepts only local alias and direct local users" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    const a = std.testing.allocator;
    const group = "S-1-5-21-123-456-789-1001";
    const member = "S-1-5-21-123-456-789-1002";
    for ([_][]const u8{ group, member }) |sid| {
        const sddl = try std.fmt.allocPrint(a, "O:SYD:(A;;FA;;;{s})", .{sid});
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 1), da_codex_profile_acl_fixture(wide, 0));
        try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_sddl(wide, null, 0));
        // Same name/SID cannot bypass alias type and local-domain validation.
        for ([_]u32{ 1, 2, 3, 7 }) |scenario|
            try std.testing.expectEqual(@as(c_int, -3), da_codex_profile_acl_fixture(wide, scenario));
        try std.testing.expectEqual(@as(c_int, 0), da_codex_profile_acl_fixture(wide, 4));
    }
    const user_acl = std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FA;;;" ++ member ++ ")");
    // Direct membership does not make a domain user or nested group eligible.
    for ([_]u32{ 5, 6 }) |scenario|
        try std.testing.expectEqual(@as(c_int, 0), da_codex_profile_acl_fixture(user_acl, scenario));
    try std.testing.expectEqual(@as(c_int, -3), da_codex_profile_acl_fixture(user_acl, 8));
    for ([_][]const u8{ "WD", "BU", "AU", "S-1-5-21-123-456-789-1003" }) |sid| {
        const sddl = try std.fmt.allocPrint(a, "O:SYD:(A;;FW;;;{s})", .{sid});
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 0), da_codex_profile_acl_fixture(wide, 0));
    }
    for ([_][]const u8{ group, member, "S-1-5-21-123-456-789-1003" }) |sid| {
        const owned = try std.fmt.allocPrint(a, "O:{s}D:(A;;FA;;;SY)", .{sid});
        defer a.free(owned);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, owned);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 2), da_codex_profile_acl_fixture(wide, 0));
    }
    try std.testing.expectEqual(@as(c_int, 0), da_codex_profile_acl_fixture(std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:NO_ACCESS_CONTROL"), 0));
    try std.testing.expectEqual(@as(c_int, 0), da_codex_profile_acl_fixture(std.unicode.utf8ToUtf16LeStringLiteral("O:SY"), 0));
    try std.testing.expectEqual(@as(c_int, 1), da_codex_profile_acl_fixture(std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:"), 0));
    try std.testing.expectEqual(@as(c_int, -1), da_codex_profile_acl_fixture(std.unicode.utf8ToUtf16LeStringLiteral("invalid"), 0));
    try std.testing.expectError(error.CliPermissionsUnavailable, checkCodexProfileAcl(windows.INVALID_HANDLE_VALUE));
}

test "RELOJ Codex profile integration accepts resolved local sandbox writers" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    const a = std.testing.allocator;
    var identities: [8192]u8 = @splat(0);
    const resolved = da_codex_sandbox_sids(&identities, identities.len);
    if (resolved == 0) {
        std.debug.print("SKIP RELOJ Codex profile integration: local CodexSandboxUsers alias absent\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(c_int, 1), resolved);
    var sids = std.mem.tokenizeScalar(u8, std.mem.sliceTo(&identities, 0), '\n');
    const group = sids.next() orelse return error.MissingSandboxFixture;
    var writers = std.mem.tokenizeScalar(u8, std.mem.sliceTo(&identities, 0), '\n');
    var count: usize = 0;
    while (writers.next()) |sid| {
        // Modify + delete-child, including inherited ALLOW after explicit DENY.
        for ([_]bool{ false, true }) |inherited| {
            const sddl = if (inherited)
                try std.fmt.allocPrint(a, "O:SYD:(D;;WD;;;{s})(A;ID;0x1301ff;;;{s})", .{ sid, sid })
            else
                try std.fmt.allocPrint(a, "O:SYD:(A;;0x1301ff;;;{s})", .{sid});
            defer a.free(sddl);
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
            defer a.free(wide);
            try std.testing.expectEqual(@as(c_int, 1), da_codex_profile_acl_sddl(wide));
            // 10-nov (USUARIO-NUEVO A2, decisión del propietario): el binario y su
            // instalación aceptan también al sandbox oficial de Codex. Antes
            // este caso daba 0 y la instalación nativa de Claude Code, que
            // hereda esas ACE del perfil, se descartaba en silencio.
            try std.testing.expectEqual(@as(c_int, 1), da_cli_acl_sddl(wide, null, 0));
        }
        count += 1;
    }
    try std.testing.expect(count >= 1);
    const domain = group[0..std.mem.lastIndexOfScalar(u8, group, '-').?];
    const stranger = try std.fmt.allocPrint(a, "{s}-2147483646", .{domain});
    defer a.free(stranger);
    for ([_][]const u8{ "WD", "BU", "AU", stranger }) |sid| {
        const sddl = try std.fmt.allocPrint(a, "O:SYD:(A;;FW;;;{s})", .{sid});
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 0), da_codex_profile_acl_sddl(wide));
    }
    try std.testing.expectEqual(@as(c_int, -1), da_codex_profile_acl_sddl(std.unicode.utf8ToUtf16LeStringLiteral("invalid")));
    try std.testing.expectError(error.CliPermissionsUnavailable, checkCodexProfileAcl(windows.INVALID_HANDLE_VALUE));
    // Sandbox membership never authorizes owning the profile.
    const owned = try std.fmt.allocPrint(a, "O:{s}D:(A;;FA;;;SY)", .{group});
    defer a.free(owned);
    const owned_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, owned);
    defer a.free(owned_wide);
    try std.testing.expectEqual(@as(c_int, 2), da_codex_profile_acl_sddl(owned_wide));
}

test "RELOJ Codex profile ACL respects effective writes and deny allow order" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    // Unmapped synthetic SIDs: identity lookup must not turn a denied grant
    // into an effective writer. Match both CODEX_HOME and auth.json inheritance.
    const sid = "S-1-5-21-123-456-789-2147483646";
    const real_pattern = "O:SYD:(D;{s};0x30156;;;" ++ sid ++ ")(D;{s};0x30156;;;S-1-5-21-234-567-890-2147483646)(D;{s};0x30156;;;S-1-5-21-345-678-901-2147483646)(A;ID;0x1301ff;;;" ++ sid ++ ")(A;ID;0x1301ff;;;S-1-5-21-234-567-890-2147483646)(A;;FA;;;SY)(A;;FA;;;BA)";
    for ([_][]const u8{ "", "ID" }) |flags| {
        const sddl = try std.fmt.allocPrint(a, real_pattern, .{ flags, flags, flags });
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 1), da_codex_profile_acl_fixture(wide, 0));
        // 10-nov (A2): binarios e instalaciones usan el mismo análisis de
        // permisos efectivos que el perfil de Codex (un DENY propio anula).
        try std.testing.expectEqual(@as(c_int, 1), da_cli_acl_sddl(wide, null, 0));
    }
    const cases = .{
        .{ "(A;;FW;;;" ++ sid ++ ")", 0 },
        .{ "(D;;0xd0156;;;" ++ sid ++ ")(A;ID;GA;;;" ++ sid ++ ")", 1 },
        .{ "(D;;0xd0156;;;" ++ sid ++ ")(A;ID;GW;;;" ++ sid ++ ")", 1 },
        .{ "(A;;FW;;;" ++ sid ++ ")(D;ID;0xd0156;;;" ++ sid ++ ")", 0 },
        .{ "(D;IO;0xd0156;;;" ++ sid ++ ")(A;ID;FW;;;" ++ sid ++ ")", 0 },
        .{ "(D;;0xd0156;;;S-1-5-21-123-456-789-2147483645)(A;ID;FW;;;" ++ sid ++ ")", 0 },
        // Conditional/object DENY semantics cannot be assumed from a mask.
        .{ "(OD;;0xd0156;00000000-0000-0000-0000-000000000001;;" ++ sid ++ ")(A;;FW;;;" ++ sid ++ ")", -1 },
        .{ "(OD;;WD;00000000-0000-0000-0000-000000000001;;" ++ sid ++ ")(A;;FW;;;" ++ sid ++ ")", -1 },
        .{ "(XD;;0xd0156;;;" ++ sid ++ ";(@User.fixture == 1))(A;;FW;;;" ++ sid ++ ")", -1 },
        .{ "(XD;;WD;;;" ++ sid ++ ";(@User.fixture == 1))(A;;FW;;;" ++ sid ++ ")", -1 },
        .{ "(A;;FW;;;" ++ sid ++ ")(OD;;0xd0156;00000000-0000-0000-0000-000000000001;;" ++ sid ++ ")", 0 },
        .{ "(A;;FW;;;" ++ sid ++ ")(XD;;0xd0156;;;" ++ sid ++ ";(@User.fixture == 1))", 0 },
        .{ "(OD;IO;0xd0156;00000000-0000-0000-0000-000000000001;;" ++ sid ++ ")(A;;FW;;;" ++ sid ++ ")", 0 },
        .{ "(D;;WD;;;" ++ sid ++ ")(A;;FW;;;" ++ sid ++ ")", 0 },
    };
    inline for (cases) |case| {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, "O:SYD:" ++ case[0]);
        defer a.free(wide);
        // A parser failure must not masquerade as an unverifiable DENY.
        // 10-nov (A2): el binario sigue la misma política que el perfil.
        try std.testing.expectEqual(@as(c_int, case[1]), da_cli_acl_sddl(wide, null, 0));
        try std.testing.expectEqual(@as(c_int, case[1]), da_codex_profile_acl_fixture(wide, 0));
    }
    // Leaving any mutation bit uncovered still exposes a writer.
    for ([_]u32{ 0x2, 0x4, 0x10, 0x40, 0x100, 0x10000, 0x40000, 0x80000 }) |bit| {
        const sddl = try std.fmt.allocPrint(a, "O:SYD:(D;;0x{x};;;" ++ sid ++ ")(A;ID;FA;;;" ++ sid ++ ")", .{@as(u32, 0xd0156) & ~bit});
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 0), da_codex_profile_acl_fixture(wide, 0));
    }
}

test "RELOJ Codex config.toml scanner rejects other providers env_key and foreign base_url" {
    const cases = [_]struct { text: []const u8, blocked: bool }{
        .{ .text = "", .blocked = false },
        .{ .text = "model = \"gpt-6\"\n[windows]\nsandbox = \"elevated\"\n", .blocked = false },
        .{ .text = "model_provider = \"openai\"\n", .blocked = false },
        .{ .text = "model_provider = 'openai' # el oficial\n", .blocked = false },
        .{ .text = "model_provider = \"tokenrouter\"\n", .blocked = true },
        .{ .text = "[profiles.y]\nmodel_provider=\"azure\"\n", .blocked = true },
        .{ .text = "profiles.y.model_provider = \"azure\"\n", .blocked = true },
        .{ .text = "[model_providers.x]\nbase_url = \"https://api.x.com/v1\"\n", .blocked = true },
        .{ .text = "[model_providers.x]\nenv_key = \"X_KEY\"\n", .blocked = true },
        .{ .text = "[model_providers.x]\nbase_url = \"https://chatgpt.com/backend-api/codex\"\n", .blocked = false },
        .{ .text = "[model_providers.x]\nbase_url = 'https://chatgpt.com/backend-api/codex'  # ChatGPT\n", .blocked = false },
        .{ .text = "model_providers = { x = { env_key = \"K\" } }\n", .blocked = true },
        .{ .text = "openai_base_url = \"https://example.com/v1\"\n", .blocked = true },
        .{ .text = "model_providers.x.base_url=\"https://evil.example\"\r\n", .blocked = true },
        .{ .text = "# env_key = \"X\"\n# model_provider = \"x\"\n", .blocked = false },
        // Escapes que esconden la clave o cierran una cadena antes del `#`.
        .{ .text = "\"env\\u005fkey\" = \"X\"\n", .blocked = true },
        .{ .text = "[model_providers.\"x\\\"y\"]\n", .blocked = true },
        .{ .text = "n = \"a\\\" # b\", env_key = \"X\"\n", .blocked = true },
        .{ .text = "path = \"C:\\\\codex\" # env_key = \"X\"\n", .blocked = false },
        // Una clave más larga que solo contiene el nombre no es la clave.
        .{ .text = "model_providers = 1\n", .blocked = false },
        // una cabecera de proyecto con ruta de Windows (literal
        // entre comillas simples, sin escapes) no es un proveedor propio.
        .{ .text = "[projects.'C:\\Workspace\\Usuario']\n", .blocked = false },
        .{ .text = "[projects.'c:\\workspace\\usuario\\2026-04-24\\proyecto']\n", .blocked = false },
        .{ .text = "[projects.\"C:\\\\Workspace\\\\Usuario\"]\n", .blocked = false },
        .{ .text = "[plugins.\"a@b\"]\ntrust_level = \"trusted\"\n", .blocked = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.blocked, codexConfigOverridesProvider(case.text));
}

test "CK-CAB-002 codex config accepts a real profile and rejects decoded provider keys" {
    const cases = [_]struct { text: []const u8, blocked: bool }{
        // Cabecera de proyecto con ruta de Windows entre comillas simples.
        .{ .text = "[projects.'C:\\Workspace\\Usuario']\ntrust_level = \"trusted\"\n", .blocked = false },
        // La misma ruta entre comillas dobles con las barras escapadas (TOML
        // válido) no bloquea; sin escapar (`\U`, `\Z`) es un escape inválido y
        // bloquea, como cualquier escape no decodificable (el segundo auditor).
        .{ .text = "[projects.\"C:\\\\Workspace\\\\Usuario\"]\n", .blocked = false },
        .{ .text = "[projects.\"C:\\Workspace\\Usuario\"]\n", .blocked = true },
        .{ .text = "\"env\\q_key\" = \"X\"\n", .blocked = true },
        .{ .text = "\"env\\\\_key\" = \"X\"\n", .blocked = false },
        // Un escape válido dentro de una clave básica sí revela la clave real.
        .{ .text = "\"env\\u005fkey\" = \"X\"\n", .blocked = true },
        .{ .text = "\"base\\u005furl\" = \"X\"\n", .blocked = true },
        .{ .text = "\"ENV\\u005fKEY\" = \"X\"\n", .blocked = true },
        .{ .text = "[model_providers.\"x\\\"y\"]\n", .blocked = true },
        // Forma del config.toml real del propietario: model, [windows],
        // [plugins."a@b"] y varias [projects.'C:\…'] con trust_level.
        .{ .text = "model = \"gpt-5\"\n[windows]\nsandbox = \"elevated\"\n[plugins.\"a@b\"]\nenabled = true\n[projects.'C:\\Workspace\\Usuario']\ntrust_level = \"trusted\"\n[projects.'C:\\Workspace\\Usuario\\2026-04-24\\proyecto']\ntrust_level = \"trusted\"\n", .blocked = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.blocked, codexConfigOverridesProvider(case.text));
}

test "RELOJ Codex profile with a provider override in config.toml blocks the session with a visible cause" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const home = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "codex", .{base});
    defer a.free(home);
    try createPrivateDirectory(a, home);
    var dir = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer dir.close(io);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CODEX_HOME", home);
    const Session = @import("external_agent_catalog.zig").Session;
    try dir.writeFile(io, .{ .sub_path = "auth.json", .data = "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":null}" });
    try dir.writeFile(io, .{ .sub_path = "config.toml", .data = "model = \"gpt-6\"\n[windows]\nsandbox = \"elevated\"\n" });
    try std.testing.expectEqual(Session.suscripcion, try codexAuthMode(a, io, &env));
    try dir.writeFile(io, .{ .sub_path = "config.toml", .data = "[model_providers.tr]\nbase_url = \"https://router.example/v1\"\nenv_key = \"TOKENROUTER_API_KEY\"\n" });
    try std.testing.expectError(error.CodexProviderOverride, codexAuthMode(a, io, &env));
    // La revalidación previa al envío lo trata como facturación por API.
    try std.testing.expectEqual(Session.api_key, try @import("external_agents.zig").revalidateCodex(a, io, "C:\\missing-cli.exe", &env));
    const reason = try codexProfileFailure(a, error.CodexProviderOverride);
    defer a.free(reason);
    try std.testing.expectEqualStrings("config.toml de Codex define un proveedor propio (model_provider, env_key o base_url distintos de ChatGPT): la sesión queda bloqueada porque podría facturar por API", reason);
}

test "RELOJ Codex auth failure messages distinguish ACL identity JSON environment and reads" {
    const a = std.testing.allocator;
    const cases = .{
        .{ error.CliWritableByOthers, "permisos", "escritor" },
        .{ error.CliUntrustedOwner, "permisos", "propietario" },
        .{ error.CliPermissionsUnavailable, "permisos", "descriptor" },
        .{ error.CodexSandboxUnavailable, "identidad", "CodexSandboxUsers" },
        .{ error.InvalidCodexAuth, "JSON", "auth.json" },
        .{ error.InvalidEnvironment, "entorno", "CODEX_HOME" },
        .{ error.EnvironmentChanged, "entorno", "EnvironmentChanged" },
        .{ error.AccessDenied, "leer", "AccessDenied" },
        .{ error.InputOutput, "leer", "InputOutput" },
        .{ error.CodexAuthReadIncomplete, "leer", "CodexAuthReadIncomplete" },
    };
    inline for (cases) |case| {
        const message = try codexProfileFailure(a, case[0]);
        defer a.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, case[1]) != null);
        try std.testing.expect(std.mem.indexOf(u8, message, case[2]) != null);
    }
}

pub fn createPrivateDirectory(a: std.mem.Allocator, path: []const u8) !void {
    if (!is_windows) {
        // T9: carpeta nueva 0700 del usuario actual (no sigue un enlace final).
        if (!std.fs.path.isAbsolutePosix(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidExternalAgentPath;
        const z = try a.dupeZ(u8, path);
        defer a.free(z);
        if (std.c.mkdir(z, 0o700) != 0) {
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.posix.E.EXIST)) return error.PathAlreadyExists;
            if (e == @intFromEnum(std.posix.E.NOENT)) return error.FileNotFound;
            if (e == @intFromEnum(std.posix.E.ACCES) or e == @intFromEnum(std.posix.E.PERM)) return error.AccessDenied;
            return error.CliPermissionsUnavailable;
        }
        return;
    }
    if (!localPath(path)) return error.InvalidExternalAgentPath;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    return switch (da_cli_create_private_directory(wide)) {
        0 => {},
        183 => error.PathAlreadyExists,
        2, 3 => error.FileNotFound,
        5 => error.AccessDenied,
        8, 14 => error.OutOfMemory,
        else => error.CliPermissionsUnavailable,
    };
}

const AclFn = *const fn (std.posix.fd_t) anyerror!void;

fn checkOwner(handle: std.posix.fd_t) !void {
    if (!is_windows) {
        const meta = @import("providers").posix_stat.get(handle, null) catch return error.CliPermissionsUnavailable;
        if (meta.uid != std.c.getuid() and meta.uid != 0) return error.CliUntrustedOwner;
        return;
    }
    switch (da_cli_owner_safe(handle)) {
        1 => {},
        2 => return error.CliUntrustedOwner,
        else => return error.CliPermissionsUnavailable,
    }
}

test "E5.B13 HARD3. ACL descriptors accept read-only AppContainer and deny every writer" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (junctions, ACL o SID); omitida en Linux");
    const a = std.testing.allocator;
    for ([_][]const u8{ "S-1-15-2-1", "S-1-15-2-123-456", "S-1-15-3-123-456" }) |sid| {
        const sddl = try std.fmt.allocPrint(a, "O:SYD:(A;;FRFX;;;{s})", .{sid});
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        var signals: [8192]u8 = @splat(0);
        try std.testing.expectEqual(@as(c_int, 1), da_cli_acl_sddl(wide, &signals, signals.len));
        try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&signals, 0), sid) != null);
        for ([_][]const u8{ "FA", "FW", "WD", "WO", "DC", "0x00000002", "0x00000004", "0x00000010", "0x00000100", "0x00010000", "0x40000000", "0x10000000" }) |rights| {
            const writable = try std.fmt.allocPrint(a, "O:SYD:(A;;{s};;;{s})", .{ rights, sid });
            defer a.free(writable);
            const writable_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, writable);
            defer a.free(writable_wide);
            @memset(&signals, 0);
            try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_sddl(writable_wide, &signals, signals.len));
        }
    }
    for ([_][]const u8{ "S-1-1-0", "S-1-5-32-545", "S-1-5-11", "S-1-5-4", "S-1-5-32-546", "S-1-5-21-123-456-789-1002", "S-1-15-4-123" }) |sid| {
        for ([_][]const u8{ "FA", "FW", "WD", "WO" }) |rights| {
            const sddl = try std.fmt.allocPrint(a, "O:SYD:(A;;{s};;;{s})", .{ rights, sid });
            defer a.free(sddl);
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
            defer a.free(wide);
            try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_sddl(wide, null, 0));
        }
    }
}

test "E-369: una app empaquetada con escritura es señal; las SID compartidas y DevAgents se rechazan" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    // SID de UN paquete (siete RID): de paquete o su capacidad. Estos RID no
    // corresponden a ningún paquete del equipo (huérfana): se rechaza.
    for ([_][]const u8{ "S-1-15-3-11-22-33-44-55-66-77", "S-1-15-2-11-22-33-44-55-66-77" }) |sid| {
        for ([_][]const u8{ "FA", "FW", "WD", "0x00000002" }) |rights| {
            const sddl = try std.fmt.allocPrint(a, "O:SYD:(A;;{s};;;{s})(A;;FA;;;SY)", .{ rights, sid });
            defer a.free(sddl);
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
            defer a.free(wide);
            var signals: [8192]u8 = @splat(0);
            try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_sddl(wide, &signals, signals.len));
            try std.testing.expectEqualStrings("", std.mem.sliceTo(&signals, 0));
        }
        // De solo lectura sigue siendo una señal sin prefijo.
        const ro = try std.fmt.allocPrint(a, "O:SYD:(A;;FRFX;;;{s})", .{sid});
        defer a.free(ro);
        const ro_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, ro);
        defer a.free(ro_wide);
        var signals: [8192]u8 = @splat(0);
        try std.testing.expectEqual(@as(c_int, 1), da_cli_acl_sddl(ro_wide, &signals, signals.len));
        const expected = try std.fmt.allocPrint(a, "{s}\n", .{sid});
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, std.mem.sliceTo(&signals, 0));
        try std.testing.expectEqual(@as(?[]u8, null), try appContainerAppName(a, sid));
    }
    // Compartidas por muchos procesos encerrados: ALL APPLICATION PACKAGES,
    // ALL RESTRICTED APPLICATION PACKAGES, capacidades conocidas (internetClient)
    // y con nombre (S-1-15-3-1024-…). Con escritura, rechazo, y se nombra.
    for ([_][]const u8{ "S-1-15-2-1", "S-1-15-2-2", "S-1-15-3-1", "S-1-15-3-1024-1-2-3-4-5-6-7-8" }) |sid| {
        const sddl = try std.fmt.allocPrint(a, "O:SYD:(A;;FA;;;{s})", .{sid});
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        var signals: [8192]u8 = @splat(0);
        try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_sddl(wide, &signals, signals.len));
        try std.testing.expectEqualStrings("", std.mem.sliceTo(&signals, 0));
    }
    // El sandbox propio (perfiles «DevAgents.Sec5.*» del banco SEC5 y F1.8).
    try std.testing.expectEqual(@as(c_int, 1), da_appcontainer_moniker_is_devagents(std.unicode.utf8ToUtf16LeStringLiteral("DevAgents.Sec5.0011aabb")));
    try std.testing.expectEqual(@as(c_int, 1), da_appcontainer_moniker_is_devagents(std.unicode.utf8ToUtf16LeStringLiteral("devagents-futuro")));
    try std.testing.expectEqual(@as(c_int, 0), da_appcontainer_moniker_is_devagents(std.unicode.utf8ToUtf16LeStringLiteral("claude_pzs8sxrjxfjjc")));
    try std.testing.expectEqual(@as(c_int, 0), da_appcontainer_moniker_is_devagents(std.unicode.utf8ToUtf16LeStringLiteral("DevAgent")));
    try std.testing.expect(isAppContainerWriterLine("w:S-1-15-3-1"));
    try std.testing.expect(!isAppContainerWriterLine("S-1-15-3-1"));
}

test "E5.B13 ACL descriptor trusted principals read-only grants and failures" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    for ([_][]const u8{
        "O:SYD:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464)",
        "O:SYD:(A;;FRFX;;;WD)(A;;FRFX;;;BU)(A;;FRFX;;;AU)",
        "O:SYD:",
    }) |sddl| {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        var signals: [8192]u8 = @splat(0);
        try std.testing.expectEqual(@as(c_int, 1), da_cli_acl_sddl(wide, &signals, signals.len));
        try std.testing.expectEqualStrings("", std.mem.sliceTo(&signals, 0));
    }
    try std.testing.expectEqual(@as(c_int, -1), da_cli_acl_sddl(std.unicode.utf8ToUtf16LeStringLiteral("invalid"), null, 0));
    const app = std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FRFX;;;S-1-15-3-123-456)");
    var tiny: [2]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, -1), da_cli_acl_sddl(app, &tiny, 0));
    try std.testing.expectEqual(@as(c_int, -1), da_cli_acl_sddl(app, &tiny, tiny.len));
    try std.testing.expectEqual(@as(u8, 0), tiny[0]);
    try std.testing.expectEqual(@as(c_int, 1), da_cli_acl_sddl(app, null, 0));
    const mixed = std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FRFX;;;S-1-15-3-123-456)(A;;FA;;;WD)");
    var signals: [8192]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_sddl(mixed, &signals, signals.len));
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&signals, 0));
    try std.testing.expectEqual(@as(c_int, -1), da_cli_acl_inspect(windows.INVALID_HANDLE_VALUE, &signals, signals.len));
    try std.testing.expectEqual(@as(c_int, -1), da_cli_acl_safe(windows.INVALID_HANDLE_VALUE));
    for ([_][]const u8{ "WD", "BU", "AU", "IU", "BG" }) |sid| {
        const sddl = try std.fmt.allocPrint(a, "O:{s}D:(A;;FA;;;{s})", .{ sid, sid });
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 2), da_cli_acl_sddl(wide, null, 0));
        try std.testing.expectEqual(@as(c_int, 2), da_cli_owner_sddl(wide));
    }
    try std.testing.expectEqual(@as(c_int, 0), da_cli_acl_sddl(std.unicode.utf8ToUtf16LeStringLiteral("O:SY"), null, 0));
}
test "E5.B13 owner: foreign owner rejected even without write ACE" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    for ([_][]const u8{ "", "(A;;FRFX;;;WD)", "(A;;FA;;;S-1-5-21-123-456-789-1002)" }) |aces| {
        const sddl = try std.fmt.allocPrint(a, "O:S-1-5-21-123-456-789-1002D:{s}", .{aces});
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 2), da_cli_acl_sddl(wide, null, 0));
    }
}

test "E5.B13 owner: current token SYSTEM Administrators TrustedInstaller accepted" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const Api = struct {
        extern "advapi32" fn OpenProcessToken(windows.HANDLE, u32, *windows.HANDLE) callconv(.winapi) c_int;
        extern "advapi32" fn GetTokenInformation(windows.HANDLE, c_int, ?*anyopaque, u32, *u32) callconv(.winapi) c_int;
        extern "advapi32" fn ConvertSidToStringSidA(*anyopaque, *[*:0]u8) callconv(.winapi) c_int;
        extern "kernel32" fn LocalFree(*anyopaque) callconv(.winapi) ?*anyopaque;
    };
    const a = std.testing.allocator;
    var token: windows.HANDLE = undefined;
    try std.testing.expect(Api.OpenProcessToken(@ptrFromInt(std.math.maxInt(usize)), 8, &token) != 0);
    defer _ = CloseHandle(token);
    var needed: u32 = 0;
    _ = Api.GetTokenInformation(token, 1, null, 0, &needed);
    try std.testing.expect(needed > 0);
    const buffer = try a.alignedAlloc(u8, .of(usize), needed);
    defer a.free(buffer);
    try std.testing.expect(Api.GetTokenInformation(token, 1, buffer.ptr, needed, &needed) != 0);
    const sid = @as(*const *anyopaque, @ptrCast(buffer.ptr)).*;
    var current: [*:0]u8 = undefined;
    try std.testing.expect(Api.ConvertSidToStringSidA(sid, &current) != 0);
    defer _ = Api.LocalFree(current);
    for ([_][]const u8{ std.mem.span(current), "SY", "BA", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464" }) |owner| {
        const sddl = try std.fmt.allocPrint(a, "O:{s}D:(A;;FA;;;{s})", .{ owner, owner });
        defer a.free(sddl);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(wide);
        try std.testing.expectEqual(@as(c_int, 1), da_cli_acl_sddl(wide, null, 0));
        try std.testing.expectEqual(@as(c_int, 1), da_cli_owner_sddl(wide));
    }
}
fn checkInstallation(a: std.mem.Allocator, root: *const confined.Root, trusted: []const u8, acl_fn: AclFn, owner_fn: AclFn) !void {
    if (!is_windows) return error.ExternalCliUnavailableOnLinux;
    for (root.handles.items) |h| {
        const dir = try finalName(a, h);
        defer a.free(dir);
        try owner_fn(h);
        if (inside(trusted, dir)) try acl_fn(h);
    }
}

fn testForeignAncestor(aces: []const u8) !void {
    const Fixture = struct {
        var foreign: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
        var descriptor: [:0]const u16 = undefined;
        var owner_calls: usize = 0;
        var acl_calls: usize = 0;
        var writable: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
        fn owner(handle: windows.HANDLE) anyerror!void {
            owner_calls += 1;
            if (handle != foreign) return;
            switch (da_cli_owner_sddl(descriptor)) {
                2 => return error.CliUntrustedOwner,
                1 => {},
                else => return error.CliPermissionsUnavailable,
            }
        }
        fn acl(handle: windows.HANDLE) anyerror!void {
            acl_calls += 1;
            // A normal write ACE must still be rejected at/below trusted.
            const sddl = if (handle == writable) "O:SYD:(A;;FA;;;WD)" else "O:SYD:";
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, sddl);
            defer std.testing.allocator.free(wide);
            switch (da_cli_acl_sddl(wide, null, 0)) {
                1 => {},
                0 => return error.CliWritableByOthers,
                else => return error.CliPermissionsUnavailable,
            }
        }
    };
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "trusted/bin");
    const path = try tmp.dir.realPathFileAlloc(io, "trusted/bin", a);
    defer a.free(path);
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const trusted = std.fs.path.dirnameWindows(path).?;
    // Synthetic Root with retained real handles on the temporary chain only:
    // the sandbox forbids opening USERPROFILE, so Root.init is covered by the
    // installed smoke outside this fixture, not bypassed in production.
    var root: confined.Root = .{ .allocator = a, .canonical = try a.dupe(u8, path), .handles = .empty, .object = undefined };
    defer root.deinit();
    for ([_][]const u8{ base, trusted, path }) |dir| {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, dir);
        defer a.free(wide);
        const handle = CreateFileW(wide, 0x80000000, 3, null, 3, 0x02200000, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.CliOpenFailed;
        errdefer _ = CloseHandle(handle);
        try root.handles.append(a, handle);
    }
    root.object = try confined.identity(root.handles.items[root.handles.items.len - 1]);
    // Retained real handle immediately ABOVE the synthetic trusted root.
    // Only its descriptor is injected: no ACL on disk is changed.
    Fixture.foreign = root.handles.items[root.handles.items.len - 3];
    defer Fixture.foreign = windows.INVALID_HANDLE_VALUE;
    const ancestor = try finalName(a, Fixture.foreign);
    defer a.free(ancestor);
    try std.testing.expect(!inside(trusted, ancestor));
    const sddl = try std.fmt.allocPrint(a, "O:S-1-5-21-123-456-789-1002D:{s}", .{aces});
    defer a.free(sddl);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
    defer a.free(wide);
    Fixture.descriptor = wide;
    try std.testing.expectError(error.CliUntrustedOwner, checkInstallation(a, &root, trusted, TestEnv.syntheticAcl, Fixture.owner));
    std.debug.print("[E5.B13 ancestor] synthetic foreign owner above trusted root rejected; write_ACE={any}\n", .{aces.len != 0});
    // A permitted owner above trusted may have ordinary write grants. Every
    // retained directory receives the owner scan; only trusted and bin get ACL.
    Fixture.descriptor = std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FA;;;WD)");
    Fixture.owner_calls = 0;
    Fixture.acl_calls = 0;
    Fixture.writable = Fixture.foreign;
    try checkInstallation(a, &root, trusted, Fixture.acl, Fixture.owner);
    try std.testing.expectEqual(root.handles.items.len, Fixture.owner_calls);
    try std.testing.expectEqual(@as(usize, 2), Fixture.acl_calls);
    for (root.handles.items[1..]) |handle| {
        Fixture.writable = handle;
        try std.testing.expectError(error.CliWritableByOthers, checkInstallation(a, &root, trusted, Fixture.acl, Fixture.owner));
    }
    Fixture.writable = windows.INVALID_HANDLE_VALUE;
    std.debug.print("[E5.B13 ancestor] owner scan on all retained fixture handles; allowed owner/write above root accepted; writes at root and below denied\n", .{});
}

test "E5.B13 ancestor: foreign owner above trusted root without write ACE" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    try testForeignAncestor("");
}

test "E5.B13 ancestor: foreign owner above trusted root with write ACE" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    try testForeignAncestor("(A;;FA;;;S-1-5-21-123-456-789-1002)");
}

test "E5.B13 ancestor: owner scanner errors and real retained directory" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(c_int, -1), da_cli_owner_safe(windows.INVALID_HANDLE_VALUE));
    try std.testing.expectError(error.CliPermissionsUnavailable, checkOwner(windows.INVALID_HANDLE_VALUE));
    try std.testing.expectEqual(@as(c_int, -1), da_cli_owner_sddl(std.unicode.utf8ToUtf16LeStringLiteral("invalid")));
    try std.testing.expectEqual(@as(c_int, 2), da_cli_owner_sddl(std.unicode.utf8ToUtf16LeStringLiteral("D:")));
    try std.testing.expectEqual(@as(c_int, 1), da_cli_owner_sddl(std.unicode.utf8ToUtf16LeStringLiteral("O:SY")));
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try checkOwner(tmp.dir.handle);
    std.debug.print("[E5.B13 ancestor] real temporary directory owner accepted; invalid handle/descriptor and missing owner denied\n", .{});
}

pub const VerifiedBinary = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    root: confined.Root,
    file: std.posix.fd_t,
    authenticode_code: i32,
    acl_appcontainer_sids: ?[]u8 = null,
    /// B1: escritores huérfanos aceptados (una SID por línea).
    acl_orphan_sids: ?[]u8 = null,
    pub fn deinit(self: *VerifiedBinary) void {
        if (is_windows) _ = CloseHandle(self.file) else _ = std.c.close(self.file);
        self.root.deinit();
        self.allocator.free(self.path);
        if (self.acl_appcontainer_sids) |s| self.allocator.free(s);
        if (self.acl_orphan_sids) |s| self.allocator.free(s);
    }
};

pub fn verify(a: std.mem.Allocator, path: []const u8) !VerifiedBinary {
    return verifyWithPolicy(a, path, getEnv, checkBinaryAcl, checkOwner);
}

/// T2d-D3 (12-nov): el `node` que un shim de npm toma del PATH puede estar
/// tras un enlace fuera de las raíces (nvm-windows: `C:\nvm4w\nodejs` ->
/// `%LOCALAPPDATA%\nvm\vX`). `probeEnvironment` ya resolvía ese enlace para
/// el PATH del hijo, pero el lanzador del shim verificaba la ruta del enlace
/// y Gemini CLI se descartaba con `UntrustedCliRoot`. Mismo criterio aquí:
/// solo si la ruta está FUERA de toda raíz se sigue el enlace una vez, y el
/// destino pasa la verificación completa (raíz, reanálisis, propietario, ACL). Un
/// enlace DENTRO de una raíz sigue rechazado (`CliReparseOrAlias`).
pub fn verifyFollowingLink(a: std.mem.Allocator, path: []const u8) !VerifiedBinary {
    return verifyFollowingLinkWithPolicy(a, path, getEnv, checkBinaryAcl, checkOwner);
}

fn verifyFollowingLinkWithPolicy(a: std.mem.Allocator, path: []const u8, getenv: GetEnvFn, acl_fn: AclFn, owner_fn: AclFn) !VerifiedBinary {
    return verifyWithPolicy(a, path, getenv, acl_fn, owner_fn) catch |e| {
        if (e != error.UntrustedCliRoot) return e;
        const target = (try linkTarget(a, path)) orelse return e;
        defer a.free(target);
        return verifyWithPolicy(a, target, getenv, acl_fn, owner_fn);
    };
}

/// Un entrypoint JS es código ejecutable: mismo gate y handles retenidos que
/// un binario; no ampliar validBinaryPath (contrato de selección de CLIs).
pub fn verifyScript(a: std.mem.Allocator, path: []const u8) !VerifiedBinary {
    if (!localPath(path) or !std.ascii.endsWithIgnoreCase(path, ".js")) return error.InvalidExternalAgentPath;
    return verifyCodeWithPolicy(a, path, getEnv, checkBinaryAcl, checkOwner);
}

/// Leer el shim ya abierto evita comprobar una ruta y leer otra por TOCTOU.
pub fn readVerified(a: std.mem.Allocator, binary: *const VerifiedBinary) !?[]u8 {
    if (!is_windows) return error.ExternalCliUnavailableOnLinux;
    const Api = struct {
        extern "kernel32" fn ReadFile(windows.HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) c_int;
        extern "kernel32" fn SetFilePointerEx(windows.HANDLE, i64, ?*i64, u32) callconv(.winapi) c_int;
    };
    var buf: [16385]u8 = undefined;
    var n: u32 = 0;
    if (Api.SetFilePointerEx(binary.file, 0, null, 0) == 0) return error.CliOpenFailed;
    if (Api.ReadFile(binary.file, &buf, buf.len, &n, null) == 0) return error.CliOpenFailed;
    // Un batch grande no coincide con la plantilla npm; conserva el fallback
    // validado, sin interpretar una captura parcial como un shim reconocido.
    if (n > 16384) return null;
    return try a.dupe(u8, buf[0..n]);
}

fn checkFileAttributes(attributes: u32) !void {
    if (attributes & (0x400 | 0x10) != 0) return error.CliReparseOrAlias;
}

fn checkCanonical(trusted: []const u8, normalized: []const u8, canonical: []const u8) !void {
    if (!std.ascii.eqlIgnoreCase(canonical, normalized) or !inside(trusted, canonical)) return error.CliReparseOrAlias;
}

fn verifyWithEnv(a: std.mem.Allocator, path: []const u8, getenv: GetEnvFn) !VerifiedBinary {
    return verifyWithPolicy(a, path, getenv, checkBinaryAcl, checkOwner);
}

fn verifyWithPolicy(a: std.mem.Allocator, path: []const u8, getenv: GetEnvFn, acl_fn: AclFn, owner_fn: AclFn) !VerifiedBinary {
    if (!validBinaryPath(path)) return error.InvalidExternalAgentPath;
    return verifyCodeWithPolicy(a, path, getenv, acl_fn, owner_fn);
}

fn verifyCodeWithPolicy(a: std.mem.Allocator, path: []const u8, getenv: GetEnvFn, acl_fn: AclFn, owner_fn: AclFn) !VerifiedBinary {
    if (!is_windows) return error.ExternalCliUnavailableOnLinux;
    const normalized = try a.dupe(u8, path);
    defer a.free(normalized);
    for (normalized) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    const trusted = (try trustedRoot(a, normalized, getenv)) orelse return error.UntrustedCliRoot;
    defer a.free(trusted);
    const parent = std.fs.path.dirnameWindows(normalized) orelse return error.InvalidExternalAgentPath;
    var root = confined.Root.initSecurity(a, parent) catch |e| return switch (e) {
        error.SandboxDenied => error.CliReparseOrAlias,
        else => e,
    };
    errdefer root.deinit();
    try checkInstallation(a, &root, trusted, acl_fn, owner_fn);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, normalized);
    defer a.free(wide);
    // No WRITE/DELETE sharing: the validated file cannot be replaced or edited
    // until the probe/dispatch has completed. Ancestors are retained by Root.
    const file = CreateFileW(wide, 0x80020000, 1, null, 3, 0x00200000, null);
    if (file == windows.INVALID_HANDLE_VALUE) return error.CliOpenFailed;
    errdefer _ = CloseHandle(file);
    const Tag = extern struct { attributes: u32, tag: u32 };
    var tag: Tag = undefined;
    if (GetFileInformationByHandleEx(file, 9, &tag, @sizeOf(Tag)) == 0) return error.CliOpenFailed;
    try checkFileAttributes(tag.attributes);
    const canonical = try finalName(a, file);
    errdefer a.free(canonical);
    try checkCanonical(trusted, normalized, canonical);
    try acl_fn(file);
    var signals = std.ArrayList(u8).empty;
    defer signals.deinit(a);
    var orphans = std.ArrayList(u8).empty;
    defer orphans.deinit(a);
    // Synthetic ACL seams never produce real security signals.
    if (acl_fn == checkBinaryAcl) {
        for (root.handles.items) |h| {
            const dir = try finalName(a, h);
            defer a.free(dir);
            if (inside(trusted, dir)) try appendAclSignals(a, &signals, &orphans, h);
        }
        try appendAclSignals(a, &signals, &orphans, file);
    }
    const appcontainer = if (signals.items.len == 0) null else try signals.toOwnedSlice(a);
    errdefer if (appcontainer) |s| a.free(s);
    return .{ .allocator = a, .path = canonical, .root = root, .file = file, .authenticode_code = da_cli_authenticode(file, wide), .acl_appcontainer_sids = appcontainer, .acl_orphan_sids = if (orphans.items.len == 0) null else try orphans.toOwnedSlice(a) };
}

fn appendUniqueLines(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |sid| {
        var existing = std.mem.tokenizeScalar(u8, out.items, '\n');
        var found = false;
        while (existing.next()) |entry| {
            if (std.mem.eql(u8, entry, sid)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try out.appendSlice(a, sid);
            try out.append(a, '\n');
        }
    }
}

fn appendAclSignals(a: std.mem.Allocator, out: *std.ArrayList(u8), orphans: *std.ArrayList(u8), handle: windows.HANDLE) !void {
    var buffer: [8192]u8 = @splat(0);
    var orphan_buffer: [4096]u8 = @splat(0);
    switch (da_cli_binary_acl_inspect(handle, &buffer, buffer.len, &orphan_buffer, orphan_buffer.len)) {
        1 => {},
        0 => return error.CliWritableByOthers,
        2 => return error.CliUntrustedOwner,
        -3 => return error.CodexSandboxUnavailable,
        else => return error.CliPermissionsUnavailable,
    }
    try appendUniqueLines(a, orphans, std.mem.sliceTo(&orphan_buffer, 0));
    var lines = std.mem.tokenizeScalar(u8, std.mem.sliceTo(&buffer, 0), '\n');
    while (lines.next()) |sid| {
        var existing = std.mem.tokenizeScalar(u8, out.items, '\n');
        var found = false;
        while (existing.next()) |entry| {
            if (std.mem.eql(u8, entry, sid)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try out.appendSlice(a, sid);
            try out.append(a, '\n');
        }
    }
}

pub fn rejectionReason(e: anyerror) []const u8 {
    return switch (e) {
        // T9: el descubrimiento y la verificacion de CLIs externas (rutas de
        // instalacion, shims, firma) son de Windows; en Linux aun no existen.
        error.ExternalCliUnavailableOnLinux => "CLI externa no disponible en Linux en esta version: el descubrimiento y la verificacion de CLIs externas solo existen en Windows",
        error.UntrustedCliRoot => "CLI rechazada: fuera de las raíces de instalación confiables",
        error.InvalidExternalAgentPath => "CLI rechazada: ruta local absoluta requerida; UNC, ADS, dispositivos y .. prohibidos",
        error.CliReparseOrAlias, error.SandboxDenied => "CLI rechazada: reparse point o alias de ruta canónica",
        error.CliWritableByOthers => "CLI rechazada: binario o instalación escribible por otros usuarios",
        error.CodexSandboxUnavailable => "CLI rechazada: la instalación da permisos al sandbox de Codex y no se pudo verificar el grupo CodexSandboxUsers ni sus miembros",
        error.CliUntrustedOwner => "CLI rechazada: propietario del binario o directorio de instalación no confiable (usuario actual, SYSTEM, Administradores o TrustedInstaller requeridos)",
        error.CliPermissionsUnavailable => "CLI rechazada: no se pudieron comprobar los permisos de instalación",
        error.FileNotFound, error.CliOpenFailed => "CLI rechazada: archivo ausente, bloqueado o inaccesible",
        else => "CLI rechazada: no se pudo verificar el origen del binario",
    };
}

test "E5.B13 R2 retained ancestor handles permit real owner queries" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(threaded.io(), ".", a);
    defer a.free(path);
    var root = try confined.Root.initSecurity(a, path);
    defer root.deinit();
    for (root.handles.items) |handle| try checkOwner(handle);
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, confined.Root.initSecurity(fail.allocator(), path));
    try std.testing.expectError(error.SandboxDenied, confined.Root.initSecurity(a, "relative"));
    std.debug.print("[B13 R2] every retained ancestor owner queried with READ_CONTROL\n", .{});
}

pub fn probeEnvironment(a: std.mem.Allocator, getenv: GetEnvFn) ![:0]u16 {
    return probeEnvironmentImpl(a, getenv, false);
}

pub fn codexProbeEnvironment(a: std.mem.Allocator, getenv: GetEnvFn) ![:0]u16 {
    return probeEnvironmentImpl(a, getenv, true);
}

fn probeEnvironmentImpl(a: std.mem.Allocator, getenv: GetEnvFn, codex: bool) ![:0]u16 {
    if (!is_windows) return error.ExternalCliUnavailableOnLinux;
    var text = std.ArrayList(u8).empty;
    defer text.deinit(a);
    // An allowlist prevents *all* unknown secrets, tokens, billing variables,
    // runtime injection flags and CLI overrides from reaching discovery.
    for ([_][]const u8{ "APPDATA", "HOME", "HOMEDRIVE", "HOMEPATH", "LOCALAPPDATA", "SystemRoot", "TEMP", "TMP", "USERPROFILE" }) |key| {
        if (try getenv(a, key)) |value| {
            defer a.free(value);
            if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvironment;
            try text.appendSlice(a, key);
            try text.append(a, '=');
            try text.appendSlice(a, value);
            try text.append(a, 0);
        }
    }
    if (codex) {
        const explicit = try getenv(a, "CODEX_HOME");
        defer if (explicit) |s| a.free(s);
        const profile = try getenv(a, "USERPROFILE");
        defer if (profile) |s| a.free(s);
        const home = try codexHome(a, explicit, profile);
        defer a.free(home);
        try text.appendSlice(a, "CODEX_HOME=");
        try text.appendSlice(a, home);
        try text.append(a, 0);
    }
    try text.appendSlice(a, "PATH=");
    if (try getenv(a, "PATH")) |path| {
        defer a.free(path);
        var parts = std.mem.splitScalar(u8, path, ';');
        while (parts.next()) |part| {
            const raw = std.mem.trim(u8, part, " \"");
            if (!localPath(raw)) continue;
            // Tanda 2 (12-nov, Gemini CLI no aparecía): un shim de npm necesita
            // `node`, y nvm-windows lo deja tras un enlace (`C:\nvm4w\nodejs`)
            // fuera de las raíces. Se resuelve el enlace UNA vez y se usa el
            // destino solo si cae en una raíz confiable; las comprobaciones de
            // abajo (sin seguir reanálisis, propietario y ACL) se hacen sobre él, y
            // es el destino, no el enlace, lo que entra en el PATH del hijo.
            const linked = if (try trustedRoot(a, raw, getenv)) |direct| blk: {
                a.free(direct);
                break :blk null;
            } else try linkTarget(a, raw);
            defer if (linked) |t| a.free(t);
            const dir = linked orelse raw;
            if (try trustedRoot(a, dir, getenv)) |root| {
                defer a.free(root);
                // The same canonical and ACL checks cover interpreter lookup.
                var checked = confined.Root.initSecurity(a, dir) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    continue;
                };
                defer checked.deinit();
                checkInstallation(a, &checked, root, checkBinaryAcl, checkOwner) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    continue;
                };
                try text.appendSlice(a, checked.canonical);
                try text.append(a, ';');
            }
        }
    }
    if (try getenv(a, "SystemRoot")) |system| {
        defer a.free(system);
        if (!localPath(system)) return error.InvalidEnvironment;
        try text.appendSlice(a, system);
        try text.appendSlice(a, "\\System32");
    }
    try text.append(a, 0);
    var entries = std.ArrayList([]const u8).empty;
    defer entries.deinit(a);
    var split = std.mem.tokenizeScalar(u8, text.items, 0);
    while (split.next()) |entry| try entries.append(a, entry);
    const Sort = struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(lhs, rhs);
        }
    };
    std.mem.sort([]const u8, entries.items, {}, Sort.less);
    var ordered = std.ArrayList(u8).empty;
    defer ordered.deinit(a);
    for (entries.items) |entry| {
        try ordered.appendSlice(a, entry);
        try ordered.append(a, 0);
    }
    try ordered.append(a, 0);
    return std.unicode.utf8ToUtf16LeAllocZ(a, ordered.items);
}

const TestEnv = struct {
    var root: []const u8 = "";
    fn get(a: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
        if (std.mem.eql(u8, key, "ProgramFiles")) return try a.dupe(u8, root);
        if (std.mem.eql(u8, key, "PATH")) return try std.fmt.allocPrint(a, "C:\\untrusted-path;{s};\\\\server\\share;.;C:\\bad:stream", .{root});
        if (std.mem.eql(u8, key, "USERPROFILE")) return try a.dupe(u8, "C:\\synthetic-profile");
        if (std.mem.eql(u8, key, "SystemRoot")) return getEnv(a, key);
        // Attempting to read any billing value is itself a test failure.
        if (std.ascii.endsWithIgnoreCase(key, "_API_KEY") or std.ascii.endsWithIgnoreCase(key, "_TOKEN")) return error.SecretValueRead;
        return null;
    }
    // Sandbox temporary roots deliberately have shared Codex grants. This
    // explicit seam tests handles/Unicode/junctions without weakening real ACLs.
    fn syntheticAcl(handle: windows.HANDLE) anyerror!void {
        if (handle == windows.INVALID_HANDLE_VALUE) return error.CliOpenFailed;
    }
};

test "RELOJ discovery and execution resolve the same explicit and default CODEX_HOME" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const Fixture = struct {
        fn get(a: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
            if (std.mem.eql(u8, key, "CODEX_HOME")) return try a.dupe(u8, "C:\\explicit-profile\\codex");
            if (std.mem.eql(u8, key, "USERPROFILE")) return try a.dupe(u8, "C:\\default-profile");
            if (std.ascii.endsWithIgnoreCase(key, "_API_KEY")) return error.SecretValueRead;
            return null;
        }
        fn defaults(a: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
            if (std.mem.eql(u8, key, "CODEX_HOME")) return null;
            return get(a, key);
        }
    };
    const a = std.testing.allocator;
    for ([_]GetEnvFn{ Fixture.get, Fixture.defaults }) |getenv| {
        const block = try codexProbeEnvironment(a, getenv);
        defer a.free(block);
        var probe = std.process.Environ.Map.init(a);
        defer probe.deinit();
        try probe.putWindowsBlock(.{ .ptr = block.ptr });
        var child = try codexEnvironment(a, &probe);
        defer child.deinit();
        try std.testing.expectEqualStrings(probe.get("CODEX_HOME").?, child.get("CODEX_HOME").?);
        try std.testing.expect(!codexBilling(&probe) and !codexBilling(&child));
    }
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, codexProbeEnvironment(fail.allocator(), Fixture.get));
}

test "E5.B13 trust: canonical retained Unicode handle ACL and junction rejection" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: ACL, SID, Authenticode y rutas de Windows; la confianza POSIX (propietario y permisos) es otra");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    TestEnv.root = base;
    defer TestEnv.root = "";
    try std.testing.expectError(error.CliReparseOrAlias, checkFileAttributes(0x400));
    try std.testing.expectError(error.CliReparseOrAlias, checkFileAttributes(0x10));
    try checkFileAttributes(0x80);
    try std.testing.expectError(error.CliReparseOrAlias, checkCanonical("C:\\trusted", "C:\\trusted\\codex.exe", "C:\\outside\\codex.exe"));
    try std.testing.expectError(error.CliReparseOrAlias, checkCanonical("C:\\trusted", "C:\\trusted\\codex.exe", "C:\\trusted-other\\codex.exe"));
    try checkCanonical("C:\\trusted", "C:\\trusted\\codex.exe", "C:\\trusted\\codex.exe");
    try tmp.dir.createDirPath(io, "instalación");
    var created = try tmp.dir.createFile(io, "instalación/codex.exe", .{});
    created.close(io);
    const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "instalación" ++ std.fs.path.sep_str ++ "codex.exe", .{base});
    defer a.free(path);
    var verified = try verifyWithPolicy(a, path, TestEnv.get, TestEnv.syntheticAcl, TestEnv.syntheticAcl);
    try std.testing.expectEqualStrings(path, verified.path);
    try std.testing.expect(verified.authenticode_code != 0);
    // The same file cannot be replaced while probes/dispatch retain its handle.
    if (tmp.dir.rename("instalación/codex.exe", tmp.dir, "moved.exe", io)) |_| {
        verified.deinit();
        return error.TestUnexpectedResult;
    } else |e| try std.testing.expect(e == error.AccessDenied or e == error.FileBusy);
    verified.deinit();
    try std.testing.expectError(error.UntrustedCliRoot, verify(a, path));
    try std.testing.expectError(error.InvalidExternalAgentPath, verify(a, "\\\\server\\share\\codex.exe"));
    try std.testing.expectError(error.InvalidExternalAgentPath, verify(a, "C:\\x\\codex.exe:evil.exe"));
    try std.testing.expectError(error.InvalidExternalAgentPath, verify(a, "C:\\x\\..\\codex.exe"));
    const missing = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "missing.exe", .{base});
    defer a.free(missing);
    try std.testing.expectError(error.CliOpenFailed, verifyWithPolicy(a, missing, TestEnv.get, TestEnv.syntheticAcl, TestEnv.syntheticAcl));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, verifyWithEnv(failing.allocator(), path, TestEnv.get));
    const alias = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias", .{base});
    defer a.free(alias);
    const target = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "instalación", .{base});
    defer a.free(target);
    var cap = try @import("providers").github.runCmdCaptureWin32(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", alias, target }, null);
    defer cap.deinit(a);
    if (cap.exit_code != 0) std.debug.print("B13 mklink exit={d}\nstdout={s}\nstderr={s}\n", .{ cap.exit_code, cap.stdout, cap.stderr });
    try std.testing.expectEqual(@as(u32, 0), cap.exit_code);
    defer tmp.dir.deleteDir(io, "alias") catch |e| std.debug.print("B13 junction cleanup: {s}\n", .{@errorName(e)});
    const link_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias" ++ std.fs.path.sep_str ++ "codex.exe", .{base});
    defer a.free(link_path);
    try std.testing.expectError(error.CliReparseOrAlias, verifyWithPolicy(a, link_path, TestEnv.get, TestEnv.syntheticAcl, TestEnv.syntheticAcl));
    // A real, explicit grant makes this fixture independent of the caller's
    // inherited sandbox/owner ACL. Only this disposable file is modified.
    var grant = try @import("providers").github.runCmdCaptureWin32(a, &.{ "icacls.exe", path, "/grant", "*S-1-1-0:(F)" }, null);
    defer grant.deinit(a);
    if (grant.exit_code != 0) std.debug.print("B13 icacls exit={d}\nstdout={s}\nstderr={s}\n", .{ grant.exit_code, grant.stdout, grant.stderr });
    try std.testing.expectEqual(@as(u32, 0), grant.exit_code);
    try std.testing.expectError(error.CliWritableByOthers, verifyWithEnv(a, path, TestEnv.get));
    const installed = try @import("executor.zig").resolveAllowedExeExt(a, "clang-format", ".exe");
    defer a.free(installed);
    var real = try verify(a, installed);
    defer real.deinit();
    try std.testing.expectEqualStrings(installed, real.path);
    std.debug.print("[E5.B13 ACL/AuthentiCode real] exe={s} acl=safe authenticode_code={d}\n", .{ real.path, real.authenticode_code });
    std.debug.print("[E5.B13 trust] canonical Unicode handle retained; reparse/UNC/ADS/outside-root/other-user-write denied; Authenticode code recorded\n", .{});
}

test "E5.B13 R3 captured commands preserve Unicode argv and cwd with retained handle" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "instalación 空");
    var file = try tmp.dir.createFile(io, "instalación 空/codex.exe", .{});
    file.close(io);
    const cwd = try tmp.dir.realPathFileAlloc(io, "instalación 空", a);
    defer a.free(cwd);
    const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "codex.exe", .{cwd});
    defer a.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const handle = CreateFileW(wide, 0x80000000, 3, null, 3, 0x02200000, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.CliOpenFailed;
    defer _ = CloseHandle(handle);
    const gh = @import("providers").github;
    var grant = try gh.runCmdCaptureWin32(a, &.{ "icacls.exe", path, "/grant", "*S-1-1-0:(F)" }, cwd);
    defer grant.deinit(a);
    if (grant.exit_code != 0) std.debug.print("B13 R3 icacls exit={d}\nstdout={s}\nstderr={s}\n", .{ grant.exit_code, grant.stdout, grant.stderr });
    try std.testing.expectEqual(@as(u32, 0), grant.exit_code);
    var present = try gh.runCmdCaptureWin32(a, &.{ "cmd.exe", "/d", "/c", "if exist codex.exe (exit 0) else (exit 7)" }, cwd);
    defer present.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), present.exit_code);
    try std.testing.expectError(error.InvalidUtf8, gh.runCmdCaptureWin32(a, &.{ "icacls.exe", "\xff" }, null));
    try std.testing.expectError(error.InvalidUtf8, gh.runCmdCaptureWin32(a, &.{"icacls.exe"}, "\xff"));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.Oom, gh.runCmdCaptureWin32(failing.allocator(), &.{"icacls.exe"}, null));
    std.debug.print("[B13 R3] Unicode argv/cwd ACL grant exit=0 with retained handle; errors asserted\n", .{});
}

test "E5.B13 environment: minimal block and real child exclude all secrets" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    TestEnv.root = base;
    defer TestEnv.root = "";
    var grant = try @import("providers").github.runCmdCaptureWin32(a, &.{ "icacls.exe", base, "/grant", "*S-1-1-0:(F)" }, null);
    defer grant.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), grant.exit_code);
    const block = try probeEnvironment(a, TestEnv.get);
    defer a.free(block);
    try std.testing.expect(block.len >= 2 and block[block.len - 1] == 0 and block[block.len - 2] == 0);
    const text = try std.unicode.utf16LeToUtf8Alloc(a, block);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "C:\\untrusted-path") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "server\\share") == null);
    // The fixture has an explicit other-user write grant: exclude it even
    // when synthetically allowlisted, independent of the caller's sandbox.
    try std.testing.expect(std.mem.indexOf(u8, text, base) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "USERPROFILE=C:\\synthetic-profile") != null);
    for (BILLING_ENV_VARS) |key| try std.testing.expect(std.mem.indexOf(u8, text, key) == null);
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, probeEnvironment(fail.allocator(), TestEnv.get));
    const executor = @import("executor.zig");
    const node = try executor.resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    const script = "const keys=Object.keys(process.env);if(keys.some(k=>/_API_KEY$|_TOKEN$/i.test(k)))process.exit(3);if(process.env.USERPROFILE!=='C:\\\\synthetic-profile')process.exit(4);if(process.env.PATH.includes('untrusted-path'))process.exit(5);if(process.argv[1]!==('sonda-'+String.fromCodePoint(0xf1)))process.exit(6);console.log('PROBE_ENV_SECRETS=0;PROFILE_PRESERVED=true;PATH_SANITIZED=true;UNICODE_ARG_PRESERVED=true');";
    var result = try executor.runVerifierPinned(a, .{ .workspace_root = base, .timeout_ms = 30000, .environment = block }, node, &.{ "-e", script, "sonda-ñ" }, base);
    defer result.deinit(a);
    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PROBE_ENV_SECRETS=0") != null);
    try std.testing.expectError(error.InvalidPath, executor.runVerifierPinned(a, .{ .workspace_root = base, .environment = block }, node, &.{"\xff"}, base));
    std.debug.print("[E5.B13 environment] {s}", .{result.stdout});
}

test "E5.B13 billing: centralized variable names cover every CLI" {
    const Presence = struct {
        var key: [:0]const u8 = "CODEX_API_KEY";
        fn present(name: [:0]const u8) bool {
            return std.mem.eql(u8, name, key);
        }
    };
    for (BILLING_ENV_VARS) |key| {
        Presence.key = key;
        try std.testing.expect(billingForCli("opencode", Presence.present));
    }
    Presence.key = "CODEX_API_KEY";
    try std.testing.expect(billingForCli("codex", Presence.present));
    try std.testing.expect(!billingForCli("gemini-cli", Presence.present));
    try std.testing.expect(!billingForCli("unknown", Presence.present));
    Presence.key = "ANTHROPIC_API_KEY";
    try std.testing.expect(billingForCli("claude-code", Presence.present));
    Presence.key = "GOOGLE_API_KEY";
    try std.testing.expect(billingForCli("gemini-cli", Presence.present));
    try std.testing.expect(!envPresent("DEVAGENTS_B13_ABSENT_SECRET_NAME"));
    try std.testing.expect((try getEnv(std.testing.allocator, "DEVAGENTS_B13_ABSENT_SECRET_NAME")) == null);
    try std.testing.expect(rejectionReason(error.CliWritableByOthers).len > 0);
    try std.testing.expect(std.mem.indexOf(u8, rejectionReason(error.CliUntrustedOwner), "propietario") != null);
    try std.testing.expect(rejectionReason(error.CliPermissionsUnavailable).len > 0);
    try std.testing.expect(rejectionReason(error.CliOpenFailed).len > 0);
    try std.testing.expect(rejectionReason(error.UntrustedCliRoot).len > 0);
    try std.testing.expect(rejectionReason(error.InvalidExternalAgentPath).len > 0);
    try std.testing.expect(rejectionReason(error.CliReparseOrAlias).len > 0);
    try std.testing.expect(rejectionReason(error.OutOfMemory).len > 0);
}
