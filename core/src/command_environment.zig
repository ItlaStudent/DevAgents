//! Entorno explícito común a captura, detached, verificadores y hooks.
const std = @import("std");
const is_windows = @import("builtin").os.tag == .windows;

// T9: fuera de Windows el bloque se construye desde `environ` (UTF-8 a UTF-16)
// para que el MISMO filtro de abajo decida; `toEnvp` lo devuelve como envp.
const GetEnvironmentStringsW = if (is_windows) struct {
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
}.GetEnvironmentStringsW else posixEnvironmentStrings;
const FreeEnvironmentStringsW = if (is_windows) struct {
    extern "kernel32" fn FreeEnvironmentStringsW([*]u16) callconv(.winapi) c_int;
}.FreeEnvironmentStringsW else posixFreeEnvironmentStrings;
const CompareStringOrdinal = if (is_windows) struct {
    extern "kernel32" fn CompareStringOrdinal([*]const u16, c_int, [*]const u16, c_int, c_int) callconv(.winapi) c_int;
}.CompareStringOrdinal else posixCompareOrdinal;

pub const Error = error{ OutOfMemory, EnvironmentReadFailed, InvalidEnvironment };
const Rule = struct { name: []const u8, prefix: bool = false, contains: ?[]const u8 = null };
// Única lista: nombres Windows comparados sin distinguir mayúsculas.
// NODE_EXTRA_CA_CERTS se conserva: confianza TLS, no carga de código.
const startup_rules = [_]Rule{
    .{ .name = "NODE_OPTIONS" },
    .{ .name = "NODE_PATH" },
    .{ .name = "PYTHONSTARTUP" },
    .{ .name = "PYTHONPATH" },
    .{ .name = "PYTHONHOME" },
    .{ .name = "PYTHONINSPECT" },
    .{ .name = "PYTHONUSERBASE" },
    .{ .name = "PERL5OPT" },
    .{ .name = "PERL5LIB" },
    .{ .name = "PERLLIB" },
    .{ .name = "RUBYOPT" },
    .{ .name = "RUBYLIB" },
    .{ .name = "JAVA_TOOL_OPTIONS" },
    .{ .name = "_JAVA_OPTIONS" },
    .{ .name = "JDK_JAVA_OPTIONS" },
    .{ .name = "DOTNET_STARTUP_HOOKS" },
    .{ .name = "COR_ENABLE_PROFILING" },
    .{ .name = "COR_PROFILER", .prefix = true },
    .{ .name = "CORECLR_ENABLE_PROFILING" },
    .{ .name = "CORECLR_", .prefix = true, .contains = "PROFILER" },
    .{ .name = "LD_PRELOAD" },
    // H12: shells que re-expanden entorno al arrancar y cargan código/config.
    // SHELLOPTS+BASHOPTS+PS4 fuerzan xtrace/funciones en bash incluso
    // restringido; PYTHONBREAKPOINT lanza un callable al toparse.
    .{ .name = "SHELLOPTS" },
    .{ .name = "PS4" },
    .{ .name = "BASHOPTS" },
    .{ .name = "PYTHONBREAKPOINT" },
    // H12: solo la lista que carga código o configuración (no el prefijo
    // entero): GIT_* inofensivas (GIT_AUTHOR_*, GIT_DIR, GIT_INDEX_FILE…)
    // siguen llegando a los flujos legítimos de git.
    .{ .name = "GIT_CONFIG", .prefix = true },
    .{ .name = "GIT_EXEC_PATH" },
    .{ .name = "GIT_SSH", .prefix = true },
    .{ .name = "GIT_ASKPASS" },
    .{ .name = "GIT_EDITOR" },
    .{ .name = "GIT_SEQUENCE_EDITOR" },
    .{ .name = "GIT_PAGER" },
    .{ .name = "GIT_EXTERNAL_DIFF" },
    .{ .name = "GIT_TEMPLATE_DIR" },
    .{ .name = "GIT_PROXY_COMMAND" },
    .{ .name = "PSModulePath" },
    .{ .name = "BASH_ENV" },
    .{ .name = "ENV" },
    .{ .name = "ZDOTDIR" },
    .{ .name = "PHPRC" },
    .{ .name = "PHP_INI_SCAN_DIR" },
};

fn starts(name: []const u16, ascii: []const u8) bool {
    if (name.len < ascii.len) return false;
    for (name[0..ascii.len], ascii) |wide, byte| {
        if (wide > 127 or std.ascii.toLower(@intCast(wide)) != std.ascii.toLower(byte)) return false;
    }
    return true;
}

fn removed(name: []const u16) bool {
    if (name.len == 23 and starts(name, "DEVAGENTS_COMMAND_CHILD")) return true;
    for (startup_rules) |rule| {
        if (!starts(name, rule.name) or (!rule.prefix and name.len != rule.name.len)) continue;
        if (rule.contains) |needle| {
            for (0..name.len) |i| if (starts(name[i..], needle)) return true;
        } else return true;
    }
    return false;
}

fn less(_: void, a: []const u16, b: []const u16) bool {
    return CompareStringOrdinal(a.ptr, @intCast(a.len), b.ptr, @intCast(b.len), 1) == 1;
}

/// Bloque doble-NUL UTF-16 owned. Incluso un entorno explícito del caller
/// pasa por el filtro; jamás se usa null para heredar al crear el proceso.
pub fn build(a: std.mem.Allocator, supplied: ?[:0]const u16) Error![:0]u16 {
    const inherited = if (supplied == null) GetEnvironmentStringsW() orelse return error.EnvironmentReadFailed else null;
    defer if (inherited) |p| {
        _ = FreeEnvironmentStringsW(p);
    };
    const source: []const u16 = if (supplied) |s| s[0 .. s.len + 1] else blk: {
        const p = inherited.?;
        var len: usize = 0;
        while (p[len] != 0 or p[len + 1] != 0) : (len += 1) {}
        break :blk p[0 .. len + 2];
    };
    var entries = std.ArrayList([]const u16).empty;
    defer entries.deinit(a);
    var pos: usize = 0;
    while (pos < source.len and source[pos] != 0) {
        const end = std.mem.indexOfScalarPos(u16, source, pos, 0) orelse return error.InvalidEnvironment;
        const entry = source[pos..end];
        // Conserva entradas especiales de unidad (=C:=...), sin tratarlas
        // como una variable de nombre vacío.
        const eq = std.mem.indexOfScalarPos(u16, entry, @intFromBool(entry[0] == '='), '=') orelse return error.InvalidEnvironment;
        if (eq == 0) return error.InvalidEnvironment;
        const name = entry[0..eq];
        if (!removed(name) and !(name.len == 16 and starts(name, "PYTHONUNBUFFERED"))) try entries.append(a, entry);
        pos = end + 1;
    }
    if (pos >= source.len) return error.InvalidEnvironment;
    for (source[pos..]) |c| if (c != 0) return error.InvalidEnvironment;
    try entries.append(a, std.unicode.utf8ToUtf16LeStringLiteral("PYTHONUNBUFFERED=1"));
    try entries.append(a, std.unicode.utf8ToUtf16LeStringLiteral("DEVAGENTS_COMMAND_CHILD=1"));
    std.mem.sort([]const u16, entries.items, {}, less);
    var block = std.ArrayList(u16).empty;
    errdefer block.deinit(a);
    for (entries.items) |entry| {
        try block.appendSlice(a, entry);
        try block.append(a, 0);
    }
    return try block.toOwnedSliceSentinel(a, 0);
}

test "SEC2 startup environment explicit block filters case wildcards and preserves data" {
    const a = std.testing.allocator;
    const input = std.unicode.utf8ToUtf16LeStringLiteral("=C:=C:\\work\x00nOdE_oPtIoNs=--require bad\x00COR_PROFILER_PATH_32=bad\x00CORECLR_TEST_PROFILER_PATH=bad\x00CORECLR_ENABLE_PROFILING=1\x00pErLlIb=bad\x00PSModulePath=bad\x00NODE_EXTRA_CA_CERTS=C:\\ca.pem\x00PATH=C:\\safe\x00TEST_UNICODE=中文\x00PYTHONUNBUFFERED=0\x00\x00");
    const block = try build(a, input);
    defer a.free(block);
    const text = try std.unicode.utf16LeToUtf8Alloc(a, block);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "bad") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "=C:=C:\\work") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "NODE_EXTRA_CA_CERTS=C:\\ca.pem") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "TEST_UNICODE=中文") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PYTHONUNBUFFERED=1") != null);
    try std.testing.expect(block[block.len - 1] == 0 and block[block.len] == 0);
    for (startup_rules) |rule| {
        const name = try std.unicode.utf8ToUtf16LeAllocZ(a, rule.name);
        defer a.free(name);
        if (rule.contains == null) try std.testing.expect(removed(name));
    }
    try std.testing.expectError(error.InvalidEnvironment, build(a, std.unicode.utf8ToUtf16LeStringLiteral("BROKEN\x00\x00")));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, build(failing.allocator(), input));
}

test "CK-SEG-012 H12 startup environment filters shell tracing and git code-loading variables" {
    @setEvalBranchQuota(20000);
    const a = std.testing.allocator;
    const input = std.unicode.utf8ToUtf16LeStringLiteral(
        "SHELLOPTS=xtrace\x00PS4=$'\x00BASHOPTS=extdebug\x00PYTHONBREAKPOINT=os.system\x00" ++
            "GIT_EXEC_PATH=C:\\evil\x00git_SSH=C:\\evil\x00GIT_SSH_COMMAND=C:\\evil ssh\x00" ++
            "GIT_ASKPASS=C:\\evil.exe\x00GIT_EDITOR=C:\\evil.exe\x00GIT_SEQUENCE_EDITOR=C:\\evil.exe\x00GIT_PAGER=C:\\evil.exe\x00" ++
            "GIT_EXTERNAL_DIFF=C:\\evil.exe\x00GIT_TEMPLATE_DIR=C:\\evil\x00GIT_PROXY_COMMAND=C:\\evil.exe\x00" ++
            "GIT_CONFIG_GLOBAL=C:\\evil\x00GIT_CONFIG_COUNT=1\x00GIT_CONFIG_KEY_0=core.fsmonitor\x00" ++
            "GIT_CONFIG_VALUE_0=C:\\evil\x00GIT_AUTHOR_NAME=legit\x00PATH=C:\\safe\x00\x00",
    );
    const block = try build(a, input);
    defer a.free(block);
    const text = try std.unicode.utf16LeToUtf8Alloc(a, block);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "evil") == null);
    for ([_][]const u8{ "SHELLOPTS", "PS4=", "BASHOPTS", "PYTHONBREAKPOINT", "GIT_CONFIG", "GIT_SSH", "GIT_EXEC_PATH", "GIT_SEQUENCE_EDITOR" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, text, name) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "GIT_AUTHOR_NAME=legit") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PATH=C:\\safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PYTHONUNBUFFERED=1") != null);
}

test "CK-SEG-020 every command environment forces the child approval guard" {
    const a = std.testing.allocator;
    for ([_]?[:0]const u16{ null, std.unicode.utf8ToUtf16LeStringLiteral("devagents_command_child=0\x00PATH=C:\\safe\x00\x00") }) |input| {
        const block = try build(a, input);
        defer a.free(block);
        const text = try std.unicode.utf16LeToUtf8Alloc(a, block);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "DEVAGENTS_COMMAND_CHILD=1") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "devagents_command_child=0") == null);
    }
}

fn posixEnvironmentStrings() ?[*]u16 {
    const a = std.heap.page_allocator;
    var block = std.ArrayList(u16).empty;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const text = std.mem.span(entry);
        // Una entrada que no es UTF-8 no se puede filtrar con certeza: se omite.
        const wide = std.unicode.utf8ToUtf16LeAlloc(a, text) catch continue;
        defer a.free(wide);
        if (wide.len == 0) continue;
        block.appendSlice(a, wide) catch return null;
        block.append(a, 0) catch return null;
    }
    if (block.items.len == 0) block.append(a, 0) catch return null;
    block.append(a, 0) catch return null;
    const owned = block.toOwnedSlice(a) catch return null;
    return owned.ptr;
}

fn posixFreeEnvironmentStrings(block: [*]u16) c_int {
    var len: usize = 0;
    while (block[len] != 0 or block[len + 1] != 0) : (len += 1) {}
    std.heap.page_allocator.free(block[0 .. len + 2]);
    return 1;
}

/// CompareStringOrdinal con bIgnoreCase: comparacion por unidades UTF-16 con
/// mayusculas ASCII; 1 = menor, 2 = igual, 3 = mayor.
fn posixCompareOrdinal(x: [*]const u16, xl: c_int, y: [*]const u16, yl: c_int, _: c_int) c_int {
    const lx: usize = @intCast(xl);
    const ly: usize = @intCast(yl);
    for (0..@min(lx, ly)) |i| {
        const cx = if (x[i] < 128) std.ascii.toUpper(@intCast(x[i])) else x[i];
        const cy = if (y[i] < 128) std.ascii.toUpper(@intCast(y[i])) else y[i];
        if (cx != cy) return if (cx < cy) 1 else 3;
    }
    return if (lx == ly) 2 else if (lx < ly) 1 else 3;
}

/// T9: bloque filtrado -> envp terminado en null (memoria del arena `a`).
pub fn toEnvp(a: std.mem.Allocator, block: [:0]const u16) Error![:null]?[*:0]const u8 {
    var list = std.ArrayList(?[*:0]const u8).empty;
    var pos: usize = 0;
    while (pos < block.len and block[pos] != 0) {
        const end = std.mem.indexOfScalarPos(u16, block, pos, 0) orelse block.len;
        const entry = std.unicode.utf16LeToUtf8AllocZ(a, block[pos..end]) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidEnvironment;
        try list.append(a, entry.ptr);
        pos = end + 1;
    }
    return list.toOwnedSliceSentinel(a, null);
}

test "T9 POSIX command environment reads environ and drops startup hooks" {
    if (is_windows) return @import("platform.zig").skip("T9: entorno POSIX; Windows lo cubren las pruebas SEC2/CK-SEG");
    const a = std.testing.allocator;
    const setenv = struct {
        extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
        extern "c" fn unsetenv([*:0]const u8) c_int;
    };
    _ = setenv.setenv("LD_PRELOAD", "/tmp/t9-evil.so", 1);
    defer _ = setenv.unsetenv("LD_PRELOAD");
    const block = try build(a, null);
    defer a.free(block);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const envp = try toEnvp(arena.allocator(), block);
    var child_flag = false;
    for (envp) |entry| {
        const text = std.mem.span(entry.?);
        try std.testing.expect(!std.mem.startsWith(u8, text, "LD_PRELOAD="));
        if (std.mem.eql(u8, text, "DEVAGENTS_COMMAND_CHILD=1")) child_flag = true;
    }
    try std.testing.expect(child_flag);
}

/// T9: el entorno filtrado como mapa, para std.process.spawn en POSIX.
pub fn posixMap(a: std.mem.Allocator, supplied: ?[:0]const u16) Error!std.process.Environ.Map {
    const block = try build(a, supplied);
    defer a.free(block);
    var map = std.process.Environ.Map.init(a);
    errdefer map.deinit();
    var pos: usize = 0;
    while (pos < block.len and block[pos] != 0) {
        const end = std.mem.indexOfScalarPos(u16, block, pos, 0) orelse block.len;
        const entry = std.unicode.utf16LeToUtf8Alloc(a, block[pos..end]) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidEnvironment;
        defer a.free(entry);
        const eq = std.mem.indexOfScalarPos(u8, entry, 1, '=') orelse return error.InvalidEnvironment;
        try map.put(entry[0..eq], entry[eq + 1 ..]);
        pos = end + 1;
    }
    return map;
}
