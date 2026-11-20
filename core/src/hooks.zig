//! Hooks de ciclo de vida: ejecutable + argv, nunca una línea de shell.
//! pre_command/post_command rodean executor.runGoverned; pre_edit/post_edit
//! rodean workspace.persistTask. Un pre_* no cero bloquea; post_* informa.
//! {path}, {exe}, {cwd} ocupan UN argumento completo. Las cadenas antiguas
//! se convierten a argv al aplicar la configuración, antes de sustituir datos.

const std = @import("std");
const windows = std.os.windows;
const argv = @import("windows_argv.zig");
const batch = @import("windows_cmd.zig");
const command_policy = @import("command_policy.zig");
const command_environment = @import("command_environment.zig");

extern "kernel32" fn CreateProcessW(?[*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, c_int, u32, ?*anyopaque, ?[*:0]const u16, *windows.STARTUPINFOW, *ProcessInformation) callconv(.winapi) c_int;
extern "kernel32" fn SearchPathW(?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, u32, [*]u16, ?*?[*:0]u16) callconv(.winapi) u32;
const GetEnvironmentVariableW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;
}.GetEnvironmentVariableW else @import("providers").posix_files.GetEnvironmentVariableW;
const GetFullPathNameW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFullPathNameW([*:0]const u16, u32, [*]u16, ?*?[*:0]u16) callconv(.winapi) u32;
}.GetFullPathNameW else @import("providers").posix_files.GetFullPathNameW;
const GetFileAttributesW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;
}.GetFileAttributesW else @import("providers").posix_files.GetFileAttributesW;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(windows.HANDLE, *u32) callconv(.winapi) c_int;
extern "kernel32" fn TerminateProcess(windows.HANDLE, u32) callconv(.winapi) c_int;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;

const ProcessInformation = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

pub const Kind = enum { pre_command, post_command, pre_edit, post_edit };
const MAX_CMD = 1024;
const MAX_ARGS = 64;

/// Almacenamiento fijo: no retiene el allocator del JSON ni trunca comandos.
const Hook = struct {
    bytes: [MAX_CMD]u8 = std.mem.zeroes([MAX_CMD]u8),
    spans: [MAX_ARGS + 1]struct { start: usize = 0, len: usize = 0 } = @splat(.{}),
    used: usize = 0,
    count: usize = 0,
    substitutes: bool = false,

    fn push(self: *Hook, value: []const u8) !void {
        if (self.count == self.spans.len or value.len > self.bytes.len - self.used) return error.HookTooLong;
        if (std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidHooksConfig;
        self.spans[self.count] = .{ .start = self.used, .len = value.len };
        @memcpy(self.bytes[self.used..][0..value.len], value);
        self.used += value.len;
        self.count += 1;
    }

    fn arg(self: *const Hook, index: usize) []const u8 {
        const span = self.spans[index];
        return self.bytes[span.start..][0..span.len];
    }
};

/// Estado estático porque los enganches son funciones libres del motor.
const Config = struct {
    entries: [4]Hook = @splat(.{}),
    timeout_ms: u32 = 15_000,
    enabled: bool = false,
};
var config: Config = .{};

fn slot(kind: Kind) *const Hook {
    return &config.entries[@intFromEnum(kind)];
}

pub fn reset() void {
    config = .{};
}

pub fn isEnabled() bool {
    return config.enabled;
}

const markers = [_][]const u8{ "{path}", "{exe}", "{cwd}" };

fn isMarker(value: []const u8) bool {
    for (markers) |marker| if (std.mem.eql(u8, value, marker)) return true;
    return false;
}

fn containsMarker(value: []const u8) bool {
    for (markers) |marker| if (std.mem.indexOf(u8, value, marker) != null) return true;
    return false;
}

fn parseHook(allocator: std.mem.Allocator, value: std.json.Value) !Hook {
    var hook: Hook = .{};
    switch (value) {
        .string => |legacy| {
            const parsed = try argv.parseLegacy(allocator, legacy);
            defer argv.freeParsed(allocator, parsed);
            for (parsed) |arg| try hook.push(arg);
        },
        .object => |obj| {
            const exe = obj.get("exe") orelse return error.InvalidHooksConfig;
            const args = obj.get("argv") orelse return error.InvalidHooksConfig;
            if (exe != .string or exe.string.len == 0 or args != .array) return error.InvalidHooksConfig;
            try hook.push(exe.string);
            for (args.array.items) |arg| {
                if (arg != .string) return error.InvalidHooksConfig;
                try hook.push(arg.string);
            }
        },
        else => return error.InvalidHooksConfig,
    }
    if (hook.count == 0) return hook;
    if (hook.arg(0).len == 0 or containsMarker(hook.arg(0)) or std.mem.indexOfAny(u8, hook.arg(0), "\r\n\"") != null) return error.InvalidHookExecutable;
    var args: [MAX_ARGS][]const u8 = undefined;
    var substitutes = false;
    for (1..hook.count) |i| {
        const arg = hook.arg(i);
        // Un marcador dentro de código o de otro token volvería a convertir
        // el dato externo en sintaxis. Exigimos argumentos independientes.
        if (containsMarker(arg) and !isMarker(arg)) return error.HookPlaceholderMustBeArgument;
        substitutes = substitutes or isMarker(arg);
        args[i - 1] = arg;
    }
    // Quoting de Windows sólo protege argv; NO protege cmd /c o -Command.
    // Los shells estáticos heredados se mantienen, sin interpolar datos allí.
    if (substitutes) try checkSubstitutionPolicy(hook.arg(0), args[0 .. hook.count - 1], .{ .allocator = allocator, .template_only = true });
    hook.substitutes = substitutes;
    return hook;
}

fn checkSubstitutionPolicy(exe: []const u8, args: []const []const u8, context: command_policy.Context) error{ HookPlaceholderInInlineCode, HookPlaceholderInIndirectLauncher }!void {
    switch (command_policy.decide(exe, args, &.{}, context)) {
        .exempt, .script_template => {},
        .inline_code => return error.HookPlaceholderInInlineCode,
        .command => return error.HookPlaceholderInIndirectLauncher,
    }
}

/// Reemplazo completo y atómico. Nuevo contrato:
/// {"enabled":true,"preEdit":{"exe":"zig","argv":["fmt","{path}"]}}.
/// Las cadenas heredadas se parsean una vez con reglas argv de Windows.
pub fn applyJson(allocator: std.mem.Allocator, json_text: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return error.InvalidHooksConfig;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHooksConfig;
    const obj = parsed.value.object;
    var next: Config = .{};
    if (obj.get("enabled")) |v| {
        if (v != .bool) return error.InvalidHooksConfig;
        next.enabled = v.bool;
    }
    if (obj.get("timeoutMs")) |v| {
        if (v != .integer or v.integer <= 0 or v.integer >= 600_000) return error.InvalidHooksConfig;
        next.timeout_ms = @intCast(v.integer);
    }
    const names = [_][]const u8{ "preCommand", "postCommand", "preEdit", "postEdit" };
    for (names, 0..) |name, i| {
        if (obj.get(name)) |value| next.entries[i] = try parseHook(allocator, value);
    }
    config = next;
}

fn expandArgs(hook: *const Hook, path: []const u8, exe: []const u8, cwd: []const u8, out: *[MAX_ARGS][]const u8) []const []const u8 {
    for (1..hook.count) |i| {
        const arg = hook.arg(i);
        out[i - 1] = if (std.mem.eql(u8, arg, "{path}")) path else if (std.mem.eql(u8, arg, "{exe}")) exe else if (std.mem.eql(u8, arg, "{cwd}")) cwd else arg;
    }
    return out[0 .. hook.count - 1];
}

fn environment(allocator: std.mem.Allocator, name: [*:0]const u16) ![:0]u16 {
    const n = GetEnvironmentVariableW(name, null, 0);
    if (n == 0 or n > 32768) return error.HookExecutableNotResolved;
    const value = try allocator.allocSentinel(u16, n, 0);
    errdefer allocator.free(value);
    const read = GetEnvironmentVariableW(name, value.ptr, n);
    if (read == 0 or read >= n) return error.HookExecutableNotResolved;
    value[read] = 0;
    return value;
}

fn absolute(path: []const u16) bool {
    return (path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) or (path.len >= 2 and path[0] == '\\' and path[1] == '\\');
}

fn resolveExecutable(allocator: std.mem.Allocator, exe: []const u8, cwd: []const u8) ![:0]u16 {
    const name = try std.unicode.utf8ToUtf16LeAllocZ(allocator, exe);
    defer allocator.free(name);
    var resolved: [32768]u16 = undefined;
    var n: u32 = 0;
    if (absolute(name) or std.mem.indexOfAny(u8, exe, "\\/") != null) {
        const joined = if (!absolute(name) and cwd.len > 0) try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ cwd, exe }) else try allocator.dupe(u8, exe);
        defer allocator.free(joined);
        const candidate = try std.unicode.utf8ToUtf16LeAllocZ(allocator, joined);
        defer allocator.free(candidate);
        n = GetFullPathNameW(candidate.ptr, resolved.len, &resolved, null);
    } else {
        // PATH explícito: no permite el directorio de trabajo añadido por el SO.
        const path = try environment(allocator, std.unicode.utf8ToUtf16LeStringLiteral("PATH"));
        defer allocator.free(path);
        const extensions = [_][*:0]const u16{ std.unicode.utf8ToUtf16LeStringLiteral(".exe"), std.unicode.utf8ToUtf16LeStringLiteral(".cmd"), std.unicode.utf8ToUtf16LeStringLiteral(".bat") };
        for (extensions) |ext| {
            n = SearchPathW(path.ptr, name.ptr, ext, resolved.len, &resolved, null);
            if (n != 0) break;
        }
    }
    if (n == 0 or n >= resolved.len or !absolute(resolved[0..n])) return error.HookExecutableNotResolved;
    resolved[n] = 0;
    const attrs = GetFileAttributesW(@ptrCast(&resolved));
    if (attrs == 0xFFFFFFFF or attrs & 0x10 != 0) return error.HookExecutableNotResolved;
    return allocator.dupeZ(u16, resolved[0..n]);
}

fn pinnedCmd(allocator: std.mem.Allocator) ![:0]u16 {
    const cmd = try batch.systemCmdExe(allocator);
    defer allocator.free(cmd);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd);
}

fn launch(allocator: std.mem.Allocator, hook: *const Hook, path: []const u8, exe: []const u8, cwd: []const u8) !u32 {
    if (@import("builtin").os.tag != .windows) return posixLaunch(allocator, hook, path, exe, cwd);
    const resolved = try resolveExecutable(allocator, hook.arg(0), cwd);
    defer allocator.free(resolved);
    const resolved_utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, resolved);
    defer allocator.free(resolved_utf8);
    var args_buf: [MAX_ARGS][]const u8 = undefined;
    const args = expandArgs(hook, path, exe, cwd, &args_buf);
    // Un valor que empieza por -c o /c puede activar el intérprete aunque el
    // template fuera seguro. Repetimos el gate sobre los argumentos efectivos.
    const policy_context: command_policy.Context = .{ .allocator = allocator, .workspace_root = cwd, .cwd = cwd };
    if (hook.substitutes) {
        try checkSubstitutionPolicy(resolved_utf8, args, policy_context);
    } else if (command_policy.decide(resolved_utf8, args, &.{}, policy_context) != .exempt) {
        // Sin canal de aprobación por llamada, un hook falla cerrado.
        return error.HookCommandRequiresApproval;
    }
    const launch_args = try command_policy.launchArgs(allocator, resolved_utf8, args, policy_context);
    defer allocator.free(launch_args);
    const env_block = try command_environment.build(allocator, null);
    defer allocator.free(env_block);
    var application = resolved;
    var cmd_exe: ?[:0]u16 = null;
    defer if (cmd_exe) |c| allocator.free(c);
    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(allocator);
    if (std.ascii.endsWithIgnoreCase(resolved_utf8, ".cmd") or std.ascii.endsWithIgnoreCase(resolved_utf8, ".bat")) {
        cmd_exe = try pinnedCmd(allocator);
        application = cmd_exe.?;
        const cmd_utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, application);
        defer allocator.free(cmd_utf8);
        const escaped = try batch.buildCommandLine(allocator, cmd_utf8, resolved_utf8, launch_args);
        defer allocator.free(escaped);
        try cmd.appendSlice(allocator, escaped);
    } else {
        try argv.appendArg(&cmd, allocator, resolved_utf8);
        for (launch_args) |arg| {
            try cmd.append(allocator, ' ');
            try argv.appendArg(&cmd, allocator, arg);
        }
    }
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd.items);
    defer allocator.free(cmd_w);
    if (cmd_w.len >= 32767) return error.HookTooLong;
    if (std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidHooksConfig;
    const cwd_w: ?[:0]u16 = if (cwd.len > 0) try std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd) else null;
    defer if (cwd_w) |c| allocator.free(c);
    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: ProcessInformation = undefined;
    if (CreateProcessW(application.ptr, cmd_w.ptr, null, null, 0, 0x08000400, @ptrCast(env_block.ptr), if (cwd_w) |c| c.ptr else null, &si, &pi) == 0) return error.HookSpawnFailed;
    defer _ = CloseHandle(pi.hProcess);
    defer _ = CloseHandle(pi.hThread);
    if (WaitForSingleObject(pi.hProcess, config.timeout_ms) != 0) {
        // Un hook vencido no debe seguir trabajando tras bloquear la acción.
        if (TerminateProcess(pi.hProcess, 1) == 0) return error.HookTerminateFailed;
        if (WaitForSingleObject(pi.hProcess, 5000) != 0) return error.HookTimeout;
        return error.HookTimeout;
    }
    var code: u32 = 1;
    if (GetExitCodeProcess(pi.hProcess, &code) == 0) return error.HookExitCodeFailed;
    return code;
}

/// null si está ausente/desactivado. Fallos de configuración/lanzamiento dan
/// código 1 y diagnóstico explícito: un pre_* nunca deja pasar al fallar.
pub fn run(allocator: std.mem.Allocator, kind: Kind, path: []const u8, exe: []const u8, cwd: []const u8) ?u32 {
    if (!config.enabled) return null;
    const hook = slot(kind);
    if (hook.count == 0) return null;
    return launch(allocator, hook, path, exe, cwd) catch |err| {
        std.log.err("hook {s}: {s}", .{ @tagName(kind), @errorName(err) });
        return 1;
    };
}

pub fn blocks(allocator: std.mem.Allocator, kind: Kind, path: []const u8, exe: []const u8, cwd: []const u8) bool {
    const code = run(allocator, kind, path, exe, cwd) orelse return false;
    return code != 0;
}

pub const GateError = command_environment.Error || error{
    OutOfMemory,
    InvalidHooksConfig,
    HookExecutableNotResolved,
    HookPlaceholderInInlineCode,
    HookPlaceholderInIndirectLauncher,
    UnsafeBatchArgument,
    HookTooLong,
    HookSpawnFailed,
    HookTerminateFailed,
    HookTimeout,
    HookExitCodeFailed,
    HookExitedNonZero,
    HookInvalidArgument,
};

/// Los callers de pre_* reciben la causa tipada, sin reducirla a un veto genérico.
pub fn check(allocator: std.mem.Allocator, kind: Kind, path: []const u8, exe: []const u8, cwd: []const u8) GateError!void {
    if (!config.enabled) return;
    const hook = slot(kind);
    if (hook.count == 0) return;
    const code = launch(allocator, hook, path, exe, cwd) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EnvironmentReadFailed => error.EnvironmentReadFailed,
            error.InvalidEnvironment => error.InvalidEnvironment,
            error.InvalidHooksConfig => error.InvalidHooksConfig,
            error.HookExecutableNotResolved => error.HookExecutableNotResolved,
            error.HookPlaceholderInInlineCode => error.HookPlaceholderInInlineCode,
            error.HookPlaceholderInIndirectLauncher => error.HookPlaceholderInIndirectLauncher,
            error.UnsafeBatchArgument => error.UnsafeBatchArgument,
            error.HookTooLong => error.HookTooLong,
            error.HookSpawnFailed => error.HookSpawnFailed,
            error.HookTerminateFailed => error.HookTerminateFailed,
            error.HookTimeout => error.HookTimeout,
            error.HookExitCodeFailed => error.HookExitCodeFailed,
            else => error.HookInvalidArgument,
        };
    };
    if (code != 0) {
        std.log.info("hook {s}: exit={d}", .{ @tagName(kind), code });
        return error.HookExitedNonZero;
    }
}

test "SEC2 hooks sin configuracion no hacen nada" {
    reset();
    try std.testing.expect(!isEnabled());
    try std.testing.expect(run(std.testing.allocator, .pre_edit, "x", "", "") == null);
    try std.testing.expect(!blocks(std.testing.allocator, .pre_edit, "x", "", ""));
}

test "SEC2 hooks applyJson reemplaza legacy por ejecutable y argv" {
    defer reset();
    try applyJson(std.testing.allocator,
        \\{"enabled":true,"preEdit":"zig fmt \"{path}\"","postEdit":"dos"}
    );
    try std.testing.expect(isEnabled());
    try std.testing.expectEqualStrings("zig", slot(.pre_edit).arg(0));
    try std.testing.expectEqualStrings("fmt", slot(.pre_edit).arg(1));
    try std.testing.expectEqualStrings("{path}", slot(.pre_edit).arg(2));
    try std.testing.expectEqualStrings("dos", slot(.post_edit).arg(0));
    try applyJson(std.testing.allocator,
        \\{"enabled":true,"preEdit":{"exe":"tres","argv":[]}}
    );
    try std.testing.expectEqualStrings("tres", slot(.pre_edit).arg(0));
    try std.testing.expectEqual(@as(usize, 0), slot(.post_edit).count);
}

test "SEC2 hooks sustituciones preservan cada argumento hostil intacto" {
    defer reset();
    try applyJson(std.testing.allocator,
        \\{"enabled":true,"preEdit":{"exe":"formatter","argv":["{path}","{exe}","{cwd}",""]}}
    );
    const hostile = "C:\\中文 & | ^ % ! < > ( ) \"\r\narchivo.zig";
    var expanded: [MAX_ARGS][]const u8 = undefined;
    const args = expandArgs(slot(.pre_edit), hostile, hostile, hostile, &expanded);
    try std.testing.expectEqual(@as(usize, 4), args.len);
    for (args[0..3]) |arg| try std.testing.expectEqualStrings(hostile, arg);
    try std.testing.expectEqualStrings("", args[3]);
}

test "SEC2 hooks rechazan marcador dentro de codigo y conservan configuracion anterior" {
    defer reset();
    const allocator = std.testing.allocator;
    try applyJson(allocator,
        \\{"enabled":true,"preEdit":"zig fmt {path}"}
    );
    try std.testing.expectError(error.HookPlaceholderMustBeArgument, applyJson(allocator,
        \\{"enabled":true,"preEdit":"formatter --file={path}"}
    ));
    try std.testing.expectError(error.InvalidHookExecutable, applyJson(allocator,
        \\{"enabled":true,"preEdit":"{exe} {path}"}
    ));
    try std.testing.expectError(error.HookPlaceholderInInlineCode, applyJson(allocator,
        \\{"enabled":true,"preEdit":"cmd.exe /c {path}"}
    ));
    try std.testing.expectError(error.HookPlaceholderInInlineCode, applyJson(allocator,
        \\{"enabled":true,"preEdit":{"exe":"powershell","argv":["-Command","{path}"]}}
    ));
    try std.testing.expectEqualStrings("zig", slot(.pre_edit).arg(0));
    try std.testing.expectEqual(@as(usize, 3), slot(.pre_edit).count);
}

test "SEC2 hooks rechazan NUL tipos incorrectos y exceso sin truncar" {
    defer reset();
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidHooksConfig, applyJson(allocator,
        \\{"preEdit":{"exe":"tool","argv":["x\u0000y"]}}
    ));
    try std.testing.expectError(error.InvalidHooksConfig, applyJson(allocator,
        \\{"preEdit":{"exe":"tool","argv":[1]}}
    ));
    try std.testing.expectError(error.UnterminatedQuote, applyJson(allocator,
        \\{"preEdit":"tool \"sin cierre"}
    ));
    const too_long = try std.json.Stringify.valueAlloc(allocator, .{ .preEdit = "a" ** (MAX_CMD + 1) }, .{});
    defer allocator.free(too_long);
    try std.testing.expectError(error.HookTooLong, applyJson(allocator, too_long));
}

test "SEC2 hooks un dato no puede ocupar la posicion del script" {
    defer reset();
    try std.testing.expectError(error.HookPlaceholderInIndirectLauncher, applyJson(std.testing.allocator,
        \\{"enabled":true,"preEdit":{"exe":"python","argv":["{path}","print('injected')"]}}
    ));
}

test "SEC2 hooks un pre-hook no cero bloquea y cero deja pasar" {
    defer reset();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exit.py", .data = "import sys; sys.exit(int(sys.argv[1]))" });
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cwd);
    try applyJson(a, if (@import("builtin").os.tag == .windows)
        \\{"enabled":true,"preEdit":{"exe":"python","argv":["exit.py","3"]}}
    else
        \\{"enabled":true,"preEdit":{"exe":"python3","argv":["exit.py","3"]}}
    );
    try std.testing.expect(blocks(a, .pre_edit, "a.zig", "", cwd));
    try std.testing.expectEqual(@as(?u32, 3), run(a, .pre_edit, "a.zig", "", cwd));
    try applyJson(a, if (@import("builtin").os.tag == .windows)
        \\{"enabled":true,"preEdit":{"exe":"python","argv":["exit.py","0"]}}
    else
        \\{"enabled":true,"preEdit":{"exe":"python3","argv":["exit.py","0"]}}
    );
    try std.testing.expect(!blocks(a, .pre_edit, "a.zig", "", cwd));
}

test "SEC2 hooks static interpreter forms requiring approval fail closed" {
    defer reset();
    try applyJson(std.testing.allocator, if (@import("builtin").os.tag == .windows)
        \\{"enabled":true,"preEdit":"cmd /c exit 0"}
    else
        \\{"enabled":true,"preEdit":{"exe":"sh","argv":["-c","exit 0"]}}
    );
    try std.testing.expectError(error.HookCommandRequiresApproval, launch(std.testing.allocator, slot(.pre_edit), "", "", ""));
    try applyJson(std.testing.allocator, if (@import("builtin").os.tag == .windows)
        \\{"enabled":true,"preEdit":{"exe":"python","argv":["-m","pip","install","."]}}
    else
        \\{"enabled":true,"preEdit":{"exe":"python3","argv":["-m","pip","install","."]}}
    );
    try std.testing.expectError(error.HookCommandRequiresApproval, launch(std.testing.allocator, slot(.pre_edit), "", "", ""));
}

test "SEC2 hooks un comando inexistente falla cerrado" {
    defer reset();
    try applyJson(std.testing.allocator,
        \\{"enabled":true,"preEdit":"este-binario-no-existe-jamas"}
    );
    // launch propaga el diagnóstico; run lo convierte en código de bloqueo.
    try std.testing.expectError(error.HookExecutableNotResolved, launch(std.testing.allocator, slot(.pre_edit), "a.zig", "", ""));
}

test "SEC2 hooks desactivados no bloquean" {
    defer reset();
    try applyJson(std.testing.allocator,
        \\{"enabled":false,"preEdit":"cmd /c exit 1"}
    );
    try std.testing.expect(!blocks(std.testing.allocator, .pre_edit, "x", "", ""));
}

test "SEC2 hooks indirect launchers reject substitutions through central policy" {
    defer reset();
    for ([_][]const u8{ "wsl", "cscript", "wscript", "mshta", "rundll32", "regsvr32", "bash", "sh", "forfiles", "npm", "npx" }) |exe| {
        const json = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .enabled = true, .preEdit = .{ .exe = exe, .argv = .{"{path}"} } }, .{});
        defer std.testing.allocator.free(json);
        try std.testing.expectError(error.HookPlaceholderInIndirectLauncher, applyJson(std.testing.allocator, json));
    }
}

test "SEC2 hooks CreateProcessW entrega argv hostil sin segundo comando" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CreateProcessW y las reglas de comillas de la linea de comandos de Windows");
    defer reset();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "cwd & % ! ^ (中文)");
    var dir = try tmp.dir.openDir(io, "cwd & % ! ^ (中文)", .{});
    defer dir.close(io);
    const cwd = try tmp.dir.realPathFileAlloc(io, "cwd & % ! ^ (中文)", allocator);
    defer allocator.free(cwd);
    const hostile = "C:\\中文 & | ^ %VAR% ! < > ( ) \"\r\narchivo.zig & echo injected > SECOND_COMMAND";
    const expected = try std.json.Stringify.valueAlloc(allocator, &[_][]const u8{ hostile, hostile, cwd, "" }, .{});
    defer allocator.free(expected);
    try dir.writeFile(io, .{ .sub_path = "expected.json", .data = expected });
    try dir.writeFile(io, .{ .sub_path = "argv_fixture.py", .data =
        \\import json, pathlib, sys
        \\actual = sys.argv[1:]
        \\pathlib.Path("actual.json").write_text(json.dumps(actual), encoding="utf-8")
        \\expected = json.loads(pathlib.Path("expected.json").read_text(encoding="utf-8"))
        \\sys.exit(0 if actual == expected else 3)
        \\
    });
    try applyJson(allocator,
        \\{"enabled":true,"preEdit":{"exe":"python","argv":["argv_fixture.py","{path}","{exe}","{cwd}",""]}}
    );
    try std.testing.expectEqual(@as(?u32, 0), run(allocator, .pre_edit, hostile, hostile, cwd));
    const actual = try dir.readFileAlloc(io, "actual.json", allocator, .limited(4096));
    defer allocator.free(actual);
    const decoded = try std.json.parseFromSlice([][]const u8, allocator, actual, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 4), decoded.value.len);
    try std.testing.expectEqualStrings(hostile, decoded.value[0]);
    try std.testing.expectEqualStrings(hostile, decoded.value[1]);
    try std.testing.expectEqualStrings(cwd, decoded.value[2]);
    try std.testing.expectEqualStrings("", decoded.value[3]);
    try std.testing.expectError(error.FileNotFound, dir.access(io, "SECOND_COMMAND", .{}));
}

// ── T9: hooks en POSIX ──────────────────────────────────────────────────
// Misma politica (argv, sustituciones, command_policy) y mismo entorno
// filtrado; el binario se fija por ruta absoluta y corre en su propio grupo
// de procesos con el mismo plazo (posix_process.runEnv lo mata al vencer).

fn posixResolve(allocator: std.mem.Allocator, exe: []const u8, cwd: []const u8) error{ OutOfMemory, HookExecutableNotResolved }![]u8 {
    if (exe.len == 0 or std.mem.indexOfScalar(u8, exe, 0) != null) return error.HookExecutableNotResolved;
    const candidate = if (std.mem.indexOfScalar(u8, exe, '/') != null) blk: {
        if (std.fs.path.isAbsolutePosix(exe)) break :blk try allocator.dupe(u8, exe);
        if (cwd.len == 0) return error.HookExecutableNotResolved;
        break :blk try std.fs.path.resolvePosix(allocator, &.{ cwd, exe });
    } else blk: {
        const raw = std.c.getenv("PATH") orelse return error.HookExecutableNotResolved;
        var dirs = std.mem.splitScalar(u8, std.mem.span(raw), ':');
        while (dirs.next()) |dir| {
            if (!std.fs.path.isAbsolutePosix(dir)) continue;
            const joined = try std.fs.path.join(allocator, &.{ dir, exe });
            if (posixExecutable(allocator, joined)) break :blk joined;
            allocator.free(joined);
        }
        return error.HookExecutableNotResolved;
    };
    errdefer allocator.free(candidate);
    if (!posixExecutable(allocator, candidate)) return error.HookExecutableNotResolved;
    return candidate;
}

fn posixExecutable(allocator: std.mem.Allocator, path: []const u8) bool {
    const z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(z);
    const meta = @import("providers").posix_stat.get(std.c.AT.FDCWD, z) catch return false;
    const kind = meta.mode & std.c.S.IFMT;
    if (kind == std.c.S.IFDIR) return false;
    return std.c.access(z, std.c.X_OK) == 0;
}

fn posixLaunch(allocator: std.mem.Allocator, hook: *const Hook, path: []const u8, exe: []const u8, cwd: []const u8) (GateError || error{HookCommandRequiresApproval})!u32 {
    const resolved = try posixResolve(allocator, hook.arg(0), cwd);
    defer allocator.free(resolved);
    var args_buf: [MAX_ARGS][]const u8 = undefined;
    const args = expandArgs(hook, path, exe, cwd, &args_buf);
    const policy_context: command_policy.Context = .{ .allocator = allocator, .workspace_root = cwd, .cwd = cwd };
    if (hook.substitutes) {
        try checkSubstitutionPolicy(resolved, args, policy_context);
    } else if (command_policy.decide(resolved, args, &.{}, policy_context) != .exempt) {
        return error.HookCommandRequiresApproval;
    }
    const launch_args = command_policy.launchArgs(allocator, resolved, args, policy_context) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.HookInvalidArgument;
    defer allocator.free(launch_args);
    if (std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidHooksConfig;
    var env = try command_environment.posixMap(allocator, null);
    defer env.deinit();
    const child_argv = try allocator.alloc([]const u8, launch_args.len + 1);
    defer allocator.free(child_argv);
    child_argv[0] = resolved;
    @memcpy(child_argv[1..], launch_args);
    const result = @import("providers").posix_process.runEnv(allocator, child_argv, if (cwd.len > 0) cwd else null, null, &env, config.timeout_ms, 64 * 1024) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.HookSpawnFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.timed_out) return error.HookTimeout;
    return result.exit_code;
}
