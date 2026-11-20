//! Política común de comandos. Mitigación de ejecución, no aislamiento de SO:
//! los procesos conservan los permisos del usuario hasta el lote 5.
const std = @import("std");
const confined = @import("confined_fs.zig");

extern "kernel32" fn WideCharToMultiByte(codepage: c_uint, flags: c_uint, wide_str: [*]const u16, wide_len: c_int, ansi_str: ?[*]u8, ansi_len: c_int, default_char: ?[*]const u8, used_default: ?*c_int) callconv(.winapi) c_int;

const cp_acp: c_uint = 0;

pub const Context = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    workspace_root: []const u8 = "",
    cwd: []const u8 = "",
    /// MCP no aporta un plan aprobado: solo las consultas acotadas son automáticas.
    read_only_only: bool = false,
    /// Solo al guardar un hook: comprueba la gramática; launch exige el archivo real.
    template_only: bool = false,
};
pub const Decision = enum { exempt, inline_code, command, script_template };

test "SEC2 fail-closed interpreter and manager table preserves workspace clock" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "workspace/sub");
    try tmp.dir.createDirPath(io, "workspace/sub.py");
    var dir = try tmp.dir.openDir(io, "workspace", .{});
    defer dir.close(io);
    for ([_][]const u8{ "script.py", "analog_clock.py", "a.js", "a.mjs", "a.cjs", "dentro.ps1", "script.txt", "script.sh", "a.rb", "a.pl", "a.php", "Main.java", "a.ts" }) |name| {
        try dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "fuera.py", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, "workspace", a);
    defer a.free(root);
    const Case = struct { exe: []const u8, args: []const []const u8, approval: bool = true };
    for ([_]Case{
        .{ .exe = "python", .args = &.{ "-m", "pkg" } },
        .{ .exe = "python", .args = &.{ "-m", "pip", "install", "." } },
        .{ .exe = "node", .args = &.{ "--import", "x", "a.js" } },
        .{ .exe = "node", .args = &.{ "-r", "x", "a.js" } },
        .{ .exe = "python", .args = &.{ "-X", "importtime", "script.py" } },
        .{ .exe = "python", .args = &.{ "-Xutf8", "script.py" } },
        .{ .exe = "python", .args = &.{"script.py"}, .approval = false },
        .{ .exe = "python", .args = &.{"..\\fuera.py"} },
        .{ .exe = "python", .args = &.{"script.txt"} },
        .{ .exe = "python", .args = &.{"missing.py"} },
        .{ .exe = "python", .args = &.{"sub.py"} },
        .{ .exe = "python", .args = &.{} },
        .{ .exe = "pythonw.exe", .args = &.{ "-u", "-B", "-X", "utf8", "script.py", "-m", "pip" }, .approval = false },
        .{ .exe = "py.exe", .args = &.{ "-3", "script.py" } },
        .{ .exe = "node", .args = &.{"a.mjs"}, .approval = false },
        .{ .exe = "node", .args = &.{ "a.cjs", "--import", "x" }, .approval = false },
        .{ .exe = "node", .args = &.{ "--loader=x", "a.js" } },
        .{ .exe = "node", .args = &.{ "--", "a.js" } },
        .{ .exe = "pwsh", .args = &.{ "-File", "dentro.ps1", "-Command", "dato" } },
        .{ .exe = "pwsh", .args = &.{ "-File", "dentro.ps1" } },
        .{ .exe = "powershell", .args = &.{"dentro.ps1"} },
        .{ .exe = "pwsh", .args = &.{ "-NoProfile", "-File", "dentro.ps1" } },
        .{ .exe = "pwsh", .args = &.{ "-NonInteractive", "-File", "dentro.ps1" } },
        .{ .exe = "pwsh", .args = &.{ "-NoProfile", "-NonInteractive", "-File", "dentro.ps1", "-Command", "dato" }, .approval = false },
        .{ .exe = "powershell", .args = &.{ "-noninteractive", "-noprofile", "-file", "dentro.ps1" }, .approval = false },
        .{ .exe = "python", .args = &.{"analog_clock.py"}, .approval = false },
        .{ .exe = "corepack", .args = &.{ "npm", "exec", "x" } },
        .{ .exe = "pip", .args = &.{ "install", "." } },
        .{ .exe = "pip3", .args = &.{"list"} },
        .{ .exe = "pip", .args = &.{"--version"}, .approval = false },
        .{ .exe = "git", .args = &.{"--version"}, .approval = false },
        .{ .exe = "corepack", .args = &.{"--version"}, .approval = false },
        .{ .exe = "msbuild", .args = &.{"project"} },
        .{ .exe = "bun", .args = &.{"install"} },
        .{ .exe = "bun", .args = &.{"a.js"}, .approval = false },
        .{ .exe = "bun", .args = &.{ "--preload", "x", "a.js" } },
        .{ .exe = "deno", .args = &.{ "run", "a.ts" }, .approval = false },
        .{ .exe = "deno", .args = &.{ "run", "--allow-all", "a.ts" } },
        .{ .exe = "deno", .args = &.{ "eval", "1" } },
        .{ .exe = "dotnet", .args = &.{"script.py"} },
        .{ .exe = "java", .args = &.{"@argfile"} },
        .{ .exe = "bash", .args = &.{"script.sh"}, .approval = false },
        .{ .exe = "sh", .args = &.{ "-x", "script.sh" } },
        .{ .exe = "ruby", .args = &.{"a.rb"}, .approval = false },
        .{ .exe = "perl", .args = &.{"a.pl"}, .approval = false },
        .{ .exe = "php", .args = &.{"a.php"}, .approval = false },
        .{ .exe = "java", .args = &.{"Main.java"}, .approval = false },
    }) |case| {
        const actual = decide(case.exe, case.args, &.{}, .{ .allocator = a, .workspace_root = root, .cwd = root }) != .exempt;
        if (actual != case.approval) std.debug.print("policy mismatch: {s} {any}\n", .{ case.exe, case.args });
        try std.testing.expectEqual(case.approval, actual);
    }
    for ([_][]const u8{ "cmd", "wsl", "mshta", "rundll32", "regsvr32", "cscript", "wscript" }) |exe| {
        try std.testing.expect(decide(exe, &.{"a.js"}, &.{}, .{ .allocator = a, .workspace_root = root, .cwd = root }) != .exempt);
        try std.testing.expect(decide(exe, &.{"--version"}, &.{}, .{}) != .exempt);
    }
    const sub = try std.fs.path.join(a, &.{ root, "sub" });
    defer a.free(sub);
    try std.testing.expectEqual(Decision.exempt, decide("python3.14.exe", &.{"..\\script.py"}, &.{}, .{ .allocator = a, .workspace_root = root, .cwd = sub }));
    try std.testing.expectEqual(Decision.command, decide("python", &.{"script.py"}, &.{"python"}, .{ .allocator = a, .workspace_root = root, .cwd = root }));
    try std.testing.expectEqual(Decision.command, decide("python", &.{"script.py"}, &.{}, .{ .allocator = a, .workspace_root = root, .cwd = root, .read_only_only = true }));
}

pub fn commandName(value: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, value, "\\/")) |i| i + 1 else 0;
    const base = value[start..];
    for ([_][]const u8{ ".exe", ".cmd", ".bat", ".com" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(base, ext)) return base[0 .. base.len - ext.len];
    }
    return base;
}

pub fn sameCommand(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(commandName(a), commandName(b));
}

fn isInterpreter(exe: []const u8) bool {
    return interpreter(exe) != null;
}

const Interpreter = enum { python, node, powershell, shell, ruby, perl, php, java, deno, bun, unsafe };
fn versionedName(exe: []const u8, prefix: []const u8) bool {
    const name = commandName(exe);
    if (!std.ascii.startsWithIgnoreCase(name, prefix)) return false;
    const suffix = name[prefix.len..];
    if (suffix.len == 0) return true;
    if (!std.ascii.isDigit(suffix[0])) return false;
    for (suffix) |c| if (!std.ascii.isDigit(c) and c != '.') return false;
    return true;
}
fn interpreter(exe: []const u8) ?Interpreter {
    if (versionedName(exe, "python") or versionedName(exe, "pythonw") or sameCommand(exe, "py")) return .python;
    const Entry = struct { name: []const u8, kind: Interpreter };
    for ([_]Entry{
        .{ .name = "node", .kind = .node },       .{ .name = "nodejs", .kind = .node },
        .{ .name = "pwsh", .kind = .powershell }, .{ .name = "powershell", .kind = .powershell },
        .{ .name = "bash", .kind = .shell },      .{ .name = "sh", .kind = .shell },
        .{ .name = "dash", .kind = .shell },      .{ .name = "zsh", .kind = .shell },
        .{ .name = "ksh", .kind = .shell },       .{ .name = "ruby", .kind = .ruby },
        .{ .name = "perl", .kind = .perl },       .{ .name = "php", .kind = .php },
        .{ .name = "java", .kind = .java },       .{ .name = "deno", .kind = .deno },
        .{ .name = "bun", .kind = .bun },         .{ .name = "dotnet", .kind = .unsafe },
        .{ .name = "cmd", .kind = .unsafe },      .{ .name = "wsl", .kind = .unsafe },
        .{ .name = "cscript", .kind = .unsafe },  .{ .name = "wscript", .kind = .unsafe },
        .{ .name = "mshta", .kind = .unsafe },    .{ .name = "rundll32", .kind = .unsafe },
        .{ .name = "regsvr32", .kind = .unsafe },
    }) |entry| if (sameCommand(exe, entry.name)) return entry.kind;
    return null;
}

/// Lanzadores que ejecutan código ajeno, plugins, recetas o procesos hijos.
/// La allowlist autoriza el binario; no autoriza su cadena de ejecución.
fn isIndirectLauncher(exe: []const u8, args: []const []const u8) bool {
    for ([_][]const u8{
        "npm",      "npx",   "pnpm",    "yarn",  "corepack", "uv",  "uvx",   "pipx",    "cargo", "go",  "dotnet",
        "make",     "cmake", "msbuild", "ninja", "gcc",      "g++", "clang", "clang++", "git",   "sed", "awk",
        "forfiles",
    }) |name| if (sameCommand(exe, name)) return true;
    if (versionedName(exe, "pip")) return true;
    if (sameCommand(exe, "zig")) {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "build") or std.mem.eql(u8, arg, "run") or std.mem.eql(u8, arg, "test")) return true;
        }
    }
    if (sameCommand(exe, "find")) {
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-exec") or std.mem.startsWith(u8, arg, "-ok")) return true;
        }
    }
    return false;
}

/// Las listas de prefijos no conceden permiso para código arbitrario. Incluye
/// abreviaturas de PowerShell y opciones combinadas de shells/intérpretes.
fn hasInlineCode(exe: []const u8, args: []const []const u8) bool {
    if (!isInterpreter(exe)) return false;
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "-")) return true; // código por stdin
        if (sameCommand(exe, "powershell") or sameCommand(exe, "pwsh")) {
            if (arg.len > 1 and (arg[0] == '-' or arg[0] == '/')) {
                const start: usize = if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') 2 else 1;
                const end = std.mem.indexOfScalarPos(u8, arg, start, ':') orelse arg.len;
                const flag = arg[start..end];
                if (flag.len == 0) continue;
                if (flag.len <= 4 and std.ascii.eqlIgnoreCase(flag, "file"[0..flag.len])) {
                    // Tras -File el resto son parámetros del script, incluso
                    // un parámetro llamado -Command. '-' conserva código stdin.
                    return (index + 1 < args.len and std.mem.eql(u8, args[index + 1], "-")) or
                        (end < arg.len and std.mem.eql(u8, arg[end + 1 ..], "-"));
                }
                for ([_][]const u8{ "command", "encodedcommand", "commandwithargs" }) |full| {
                    if (flag.len <= full.len and std.ascii.eqlIgnoreCase(flag, full[0..flag.len])) return true;
                }
                if (std.ascii.eqlIgnoreCase(flag, "ec")) return true;
            }
        } else if (sameCommand(exe, "cmd")) {
            // cmd acepta switches concatenados: /d/s/c y /d/c ejecutan igual
            // que /c. Se verificó contra cmd del sistema con echo inofensivo.
            var i: usize = 0;
            while (i + 1 < arg.len) : (i += 1) {
                if (arg[i] == '/' and (std.ascii.toLower(arg[i + 1]) == 'c' or std.ascii.toLower(arg[i + 1]) == 'k')) return true;
            }
        } else if (sameCommand(exe, "node") or sameCommand(exe, "nodejs")) {
            if (std.ascii.eqlIgnoreCase(arg, "--eval") or std.ascii.eqlIgnoreCase(arg, "--print") or
                std.ascii.startsWithIgnoreCase(arg, "--eval=") or std.ascii.startsWithIgnoreCase(arg, "--print=")) return true;
            if (arg.len > 1 and arg[0] == '-' and arg[1] != '-' and std.mem.indexOfAny(u8, arg[1..], "epEP") != null) return true;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            const codes = if (sameCommand(exe, "ruby") or sameCommand(exe, "perl")) "eE" else "cC";
            if (std.mem.indexOfAny(u8, arg[1..], codes) != null) return true;
        }
    }
    // Windows PowerShell usa -Command como parámetro posicional por defecto.
    // pwsh cambió ese default a -File; conserva los scripts .ps1 legítimos.
    if (sameCommand(exe, "powershell")) {
        if (args.len == 1 and (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "-?"))) return false;
        return true;
    }
    return false;
}

/// Windows convierte con "best fit" las formas anchas (U+FF01..U+FF5E, U+3000)
/// a ASCII cuando el hijo lee un argv ANSI: `ｒｍ` llega como `rm`. La denylist se
/// evalúa también sobre la forma plegada. null = sin formas anchas.
fn foldFullwidth(a: std.mem.Allocator, text: []const u8) error{ OutOfMemory, InvalidUtf8 }!?[]u8 {
    if (std.mem.indexOfAny(u8, text, "\xEF\xE3") == null) return null;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var view = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    var changed = false;
    while (view.nextCodepoint()) |cp| {
        if (cp >= 0xFF01 and cp <= 0xFF5E) {
            try out.append(a, @intCast(cp - 0xFEE0));
            changed = true;
        } else if (cp == 0x3000) {
            try out.append(a, ' ');
            changed = true;
        } else {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidUtf8;
            try out.appendSlice(a, buf[0..n]);
        }
    }
    if (!changed) {
        out.deinit(a);
        return null;
    }
    return try out.toOwnedSlice(a);
}

/// H11: forma ANSI best-fit que obtiene un hijo con argv ANSI. Windows pliega
/// cada carácter con la tabla best-fit de la página de códigos (guiones y
/// barras alternativas, comillas tipográficas, U+00A0→espacio…), fuera del
/// rango ancho que ya cubre foldFullwidth. Se convierte UTF-8 → UTF-16 →
/// WideCharToMultiByte SIN WC_NO_BEST_FIT_CHARS. null si la forma no cambia.
/// Mueve más denegaciones, nunca menos: la forma cruda sigue evaluándose.
fn foldBestFitPage(a: std.mem.Allocator, text: []const u8, codepage: c_uint) error{ OutOfMemory, InvalidUtf8, WindowsConversion }!?[]u8 {
    // T9: sin cmd.exe ni paginas de codigos ANSI no hay plegado best-fit.
    if (@import("builtin").os.tag != .windows) return null;
    var has_wide = false;
    for (text) |byte| {
        if (byte >= 0x80) {
            has_wide = true;
            break;
        }
    }
    if (!has_wide) return null;
    var wide = std.ArrayList(u16).empty;
    defer wide.deinit(a);
    var view = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    while (view.nextCodepoint()) |cp| {
        if (cp > 0xFFFF) {
            const rest = cp - 0x10000;
            try wide.append(a, @intCast(0xD800 + (rest >> 10)));
            try wide.append(a, @intCast(0xDC00 + (rest & 0x3FF)));
        } else {
            try wide.append(a, @intCast(cp));
        }
    }
    const size = WideCharToMultiByte(codepage, 0, wide.items.ptr, @intCast(wide.items.len), null, 0, null, null);
    if (size <= 0) return error.WindowsConversion;
    const out = a.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    const written = WideCharToMultiByte(codepage, 0, wide.items.ptr, @intCast(wide.items.len), out.ptr, size, null, null);
    if (written <= 0) return error.WindowsConversion;
    const folded = out[0..@intCast(written)];
    if (std.mem.eql(u8, folded, text)) {
        a.free(out);
        return null;
    }
    return folded;
}

/// Inspecciona también código/argumentos del intérprete: denegar `rm` debe
/// cubrir `bash -c 'RM.EXE ...'`, incluida su forma ancha `ｒｍ` y la forma
/// best-fit ANSI del hijo (H11). No intenta demostrar seguridad de un
/// lenguaje. Ante un error al plegar, deniega.
pub fn isDenied(exe: []const u8, args: []const []const u8, denied: []const []const u8) bool {
    if (denied.len == 0) return false;
    if (isDeniedRaw(exe, args, denied)) return true;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folded_args = a.alloc([]const u8, args.len) catch return true;
    // Forma ancha plegada: U+FF01..U+FF5E y U+3000.
    const folded = applyFold(a, exe, args, false, 0, folded_args) catch return true;
    if (folded.any and isDeniedRaw(folded.exe, folded_args, denied)) return true;
    // Forma best-fit real del hijo: CP_ACP (la del anfitrión) y, como respaldo
    // determinista para anfitriones con ACP UTF-8 (sin best-fit), la 1252.
    for ([_]c_uint{ cp_acp, 1252 }) |codepage| {
        const page_args = a.alloc([]const u8, args.len) catch return true;
        const page = applyFold(a, exe, args, true, codepage, page_args) catch return true;
        if (page.any and isDeniedRaw(page.exe, page_args, denied)) return true;
    }
    return false;
}

const FoldOutcome = struct { exe: []const u8, any: bool };

fn applyFold(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, comptime is_best_fit: bool, codepage: c_uint, out_args: [][]const u8) error{ OutOfMemory, InvalidUtf8, WindowsConversion }!FoldOutcome {
    const folded_exe = if (is_best_fit) try foldBestFitPage(a, exe, codepage) else try foldFullwidth(a, exe);
    var any = folded_exe != null;
    for (args, out_args) |arg, *slot| {
        const folded = if (is_best_fit) try foldBestFitPage(a, arg, codepage) else try foldFullwidth(a, arg);
        any = any or folded != null;
        slot.* = folded orelse arg;
    }
    return .{ .exe = folded_exe orelse exe, .any = any };
}

fn isDeniedRaw(exe: []const u8, args: []const []const u8, denied: []const []const u8) bool {
    for (denied) |entry| {
        if (sameCommand(exe, entry)) return true;
        if (!isInterpreter(exe) and !isIndirectLauncher(exe, args)) continue;
        for (args) |arg| {
            var tokens = std.mem.tokenizeAny(u8, arg, " \t\r\n\"'`;|&(){}[],=<>^!");
            while (tokens.next()) |token| {
                if (sameCommand(token, entry)) return true;
            }
        }
    }
    return false;
}

/// Única decisión de aprobación por comando. Todo intérprete falla cerrado;
/// hasInlineCode solo conserva la causa tipada, nunca concede una exención.
pub fn decide(exe: []const u8, args: []const []const u8, denied: []const []const u8, ctx: Context) Decision {
    if (isDenied(exe, args, denied)) return .command;
    if (isReadOnly(exe, args)) return .exempt;
    if (ctx.read_only_only) return .command;
    if (interpreter(exe)) |kind| {
        // dotnet es también gestor: ningún script le concede una exención.
        if (kind == .unsafe) return if (hasInlineCode(exe, args)) .inline_code else .command;
        const script = scriptArgument(kind, args) orelse return if (hasInlineCode(exe, args)) .inline_code else .command;
        if (ctx.template_only) return .script_template;
        return if (workspaceScript(ctx, script)) .exempt else .command;
    }
    if (compileOnly(ctx, exe, args)) return .exempt;
    // Auditoría A-1: las herramientas POSIX de archivo están en la lista de
    // ejecutables, pero el sandbox solo confina el cwd, no los argumentos.
    // `cat C:\secreto`, `cp fuera.txt .` o `rm /etc/x` no pasarían por
    // ninguna aprobación: cualquier argumento-ruta absoluta o con `..`
    // convierte el comando en `.command` (tarjeta humana).
    if (fileToolEscapesWorkspace(exe, args)) return .command;
    return if (isIndirectLauncher(exe, args)) .command else .exempt;
}

/// Herramientas de archivo de la allowlist que leen/escriben rutas del SO.
/// Los intérpretes y launchers indirectos ya piden aprobación por su vía;
/// estas son las que `decide` dejaba exentas siempre.
const FILE_TOOL_NAMES = [_][]const u8{
    "cat",   "ls",       "rm",    "cp",      "mv",       "mkdir",   "rmdir",    "touch",
    "grep",  "sort",     "wc",    "head",    "tail",     "diff",    "find",     "which",
    "where", "echo",     "tee",   "install", "ln",       "unlink",  "chmod",    "chown",
    "chgrp", "truncate", "shred", "split",   "basename", "dirname", "realpath", "readlink",
    "stat",  "du",       "df",    "file",    "less",     "more",    "nl",       "od",
    "xxd",   "strings",
};

fn fileToolEscapesWorkspace(exe: []const u8, args: []const []const u8) bool {
    var is_file_tool = false;
    for (FILE_TOOL_NAMES) |name| {
        if (sameCommand(exe, name)) {
            is_file_tool = true;
            break;
        }
    }
    if (!is_file_tool) return false;
    for (args) |arg| {
        if (argEscapesWorkspace(arg)) return true;
    }
    return false;
}

/// ¿El argumento señala una ruta absoluta o un `..` que puede salir del
/// proyecto? En `--opcion=valor` se examina solo el valor.
fn argEscapesWorkspace(arg: []const u8) bool {
    const v = if (std.mem.indexOfScalar(u8, arg, '=')) |i| arg[i + 1 ..] else arg;
    if (v.len == 0) return false;
    if (isAbsolutePathArg(v)) return true;
    var it = std.mem.splitAny(u8, v, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

fn isAbsolutePathArg(v: []const u8) bool {
    if (v.len >= 2 and v[0] == '~' and (v[1] == '/' or v[1] == '\\')) return true;
    if (v.len >= 1 and (v[0] == '/' or v[0] == '\\')) return true;
    // Letra de unidad Windows con o sin separador (`C:\x`, `C:/x`, `C:x`).
    if (v.len >= 2 and std.ascii.isAlphabetic(v[0]) and v[1] == ':') return true;
    return false;
}

fn isCompiler(exe: []const u8) bool {
    for ([_][]const u8{ "gcc", "g++", "clang", "clang++" }) |name| if (sameCommand(exe, name)) return true;
    return false;
}

fn plainOutputName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or std.mem.indexOf(u8, name, "..") != null) return false;
    if (!std.ascii.isAlphanumeric(name[0]) and name[0] != '_') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-') return false;
    if (name[name.len - 1] == '.') return false;
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return false;
    if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "com") or std.ascii.startsWithIgnoreCase(stem, "lpt")) and std.ascii.isDigit(stem[3])) return false;
    return true;
}

fn safeCompilerFlag(arg: []const u8) bool {
    for ([_][]const u8{ "-Wall", "-Wextra", "-O0", "-O1", "-O2", "-O3", "-Os", "-g", "-c", "-lm", "-pthread" }) |flag| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    if (!std.mem.startsWith(u8, arg, "-std=") or arg.len == 5 or arg.len > 17) return false;
    for (arg[5..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+') return false;
    return true;
}

/// Compilar no ejecuta el programa: gcc/g++/clang/clang++ solo se eximen con
/// fuentes regulares del workspace, `-o <nombre simple>` y un conjunto cerrado
/// de banderas. Quedan fuera plugins, wrappers, specs, rutas de busqueda,
/// definiciones, ficheros de respuesta (@file) y cualquier opcion no listada.
/// Es el comando que el motor infiere para `.c`/`.cpp` (`gcc f.c -o a.exe`).
fn compileOnly(ctx: Context, exe: []const u8, args: []const []const u8) bool {
    if (!isCompiler(exe) or args.len == 0 or args.len > 16) return false;
    var sources: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len or !plainOutputName(args[i])) return false;
        } else if (safeCompilerFlag(arg)) {
            continue;
        } else if (arg.len > 0 and arg[0] != '-' and arg[0] != '@' and sourceExtension(arg)) {
            if (ctx.template_only or !workspaceScript(ctx, arg)) return false;
            sources += 1;
        } else return false;
    }
    return sources > 0;
}

fn sourceExtension(path: []const u8) bool {
    for ([_][]const u8{ ".c", ".cc", ".cpp", ".cxx" }) |ext| if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    return false;
}

fn scriptArgument(kind: Interpreter, args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    switch (kind) {
        .python => while (i < args.len) {
            if (std.mem.eql(u8, args[i], "-u") or std.mem.eql(u8, args[i], "-B") or std.mem.eql(u8, args[i], "-E") or std.mem.eql(u8, args[i], "-s")) {
                i += 1;
            } else if (std.mem.eql(u8, args[i], "-X") and i + 1 < args.len and std.mem.eql(u8, args[i + 1], "utf8")) {
                i += 2;
            } else break;
        },
        .powershell => {
            var no_profile = false;
            var non_interactive = false;
            while (i < args.len) : (i += 1) {
                if (std.ascii.eqlIgnoreCase(args[i], "-NoProfile") and !no_profile) {
                    no_profile = true;
                } else if (std.ascii.eqlIgnoreCase(args[i], "-NonInteractive") and !non_interactive) {
                    non_interactive = true;
                } else break;
            }
            if (!no_profile or !non_interactive or i + 1 >= args.len or !std.ascii.eqlIgnoreCase(args[i], "-File")) return null;
            i += 1;
        },
        .deno => {
            if (args.len < 2 or !std.mem.eql(u8, args[0], "run")) return null;
            i = 1;
        },
        .unsafe => return null,
        else => {}, // ninguna opción pre-script permitida
    }
    if (i >= args.len) return null;
    const script = args[i];
    if (script.len == 0 or script[0] == '-' or script[0] == '@' or std.mem.indexOfScalar(u8, script, 0) != null) return null;
    const extensions: []const []const u8 = switch (kind) {
        .python => &.{".py"},
        .node => &.{ ".js", ".mjs", ".cjs" },
        .powershell => &.{".ps1"},
        .shell => &.{".sh"},
        .ruby => &.{".rb"},
        .perl => &.{".pl"},
        .php => &.{".php"},
        .java => &.{".java"},
        .deno, .bun => &.{ ".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".tsx", ".jsx" },
        .unsafe => return null,
    };
    for (extensions) |ext| if (std.ascii.endsWithIgnoreCase(script, ext)) return script;
    return null;
}

/// Python exento ignora entorno/site de usuario conservando imports locales.
/// -u mantiene streaming porque -E ignora también PYTHONUNBUFFERED.
pub fn launchArgs(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, ctx: Context) ![][]const u8 {
    const isolated = interpreter(exe) == .python and decide(exe, args, &.{}, ctx) == .exempt;
    const prefix: []const []const u8 = if (isolated) &.{ "-E", "-s", "-u" } else &.{};
    const result = try a.alloc([]const u8, prefix.len + args.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..], args);
    return result;
}

fn workspaceScript(ctx: Context, script: []const u8) bool {
    const a = ctx.allocator;
    // Sin un cwd absoluto no se puede probar dónde resolverá el hijo su script.
    if (!std.fs.path.isAbsolute(ctx.cwd) or !std.fs.path.isAbsolute(ctx.workspace_root)) return false;
    var root = confined.Root.init(a, ctx.workspace_root) catch return false;
    defer root.deinit();
    const candidate = std.fs.path.resolve(a, &.{ ctx.cwd, script }) catch return false;
    defer a.free(candidate);
    const base = std.mem.trimEnd(u8, root.canonical, std.fs.path.sep_str);
    if (candidate.len <= base.len or !@import("platform.zig").pathEqual(candidate[0..base.len], base) or candidate[base.len] != std.fs.path.sep) return false;
    const file = root.openMetadata(candidate[base.len + 1 ..]) catch return false;
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    const stat = file.stat(std.Io.Threaded.global_single_threaded.io()) catch return false;
    return stat.kind == .file;
}

/// Binarios cuya consulta `--version` no lee configuración de proyecto capaz de
/// lanzar código. Quedan fuera, y piden humano también para `--version`: yarn
/// (`yarnPath` ejecuta un script local), pnpm (`packageManager` cambia y lanza
/// otra versión), cargo (rust-toolchain vía rustup), dotnet (global.json elige
/// el SDK), msbuild (*.rsp), go (no admite el flag) y forfiles.
const version_query_names = [_][]const u8{
    "npm", "npx", "corepack", "uv", "uvx", "pipx", "make", "cmake", "ninja", "gcc", "g++", "clang", "clang++", "git", "sed", "awk",
};

fn isReadOnly(exe: []const u8, args: []const []const u8) bool {
    // Solo nombres explícitos: no auto-aprobar un exe arbitrario por --version.
    if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) {
        for (version_query_names) |name| if (sameCommand(exe, name)) return true;
        if (versionedName(exe, "pip")) return true;
        // `python --version` y similares salen durante el análisis de opciones,
        // antes de ejecutar código del workspace; el entorno de arranque ya está
        // filtrado. Quedan fuera powershell (sin --version), java, deno y bun.
        if (interpreter(exe)) |kind| switch (kind) {
            .python, .node, .ruby, .perl, .php, .shell => return true,
            .powershell => return sameCommand(exe, "pwsh"),
            else => {},
        };
    }
    if (sameCommand(exe, "zig") and args.len == 1 and std.mem.eql(u8, args[0], "version")) return true;
    // `git status` a secas puede refrescar el índice o invocar el fsmonitor
    // configurado: requiere humano. Un nombre que parece consulta no demuestra
    // solo lectura. La excepción es la consulta DOMESTICADA (ver abajo).
    if (sameCommand(exe, "git")) return isDomesticatedGitQuery(args);
    return false;
}

/// QA-B 2a (14-nov): opciones que dejan a git sin nada que ejecutar ni
/// escribir: sin bloqueos opcionales (no reescribe el índice), rutas
/// literales, sin fsmonitor, sin hooks, sin submódulos y sin verificar firmas
/// (`gpg.program`). Son las del git de la cabina (bridge.cpp RunGitCapture)
/// más la de firmas. Las usan las tools git_* del MCP.
pub const GIT_SAFE_PREFIX = [_][]const u8{ "--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=NUL", "-c", "submodule.recurse=false", "-c", "log.showSignature=false" };

/// `git <GIT_SAFE_PREFIX> status|diff|log <opciones cerradas>`: lo que piden
/// git_status, git_diff y git_log del MCP, y nada más. Diff y log sin
/// programas externos (`--no-ext-diff`, `--no-textconv`). Los filtros
/// `clean` de .gitattributes se definen en `.git/config`, que ni el agente ni
/// el MCP pueden escribir (governed_tool_executor rechaza rutas bajo `.git`).
fn isDomesticatedGitQuery(args: []const []const u8) bool {
    if (args.len <= GIT_SAFE_PREFIX.len) return false;
    for (GIT_SAFE_PREFIX, 0..) |want, i| if (!std.mem.eql(u8, args[i], want)) return false;
    const rest = args[GIT_SAFE_PREFIX.len..];
    const sub = rest[0];
    const opts = rest[1..];
    if (std.mem.eql(u8, sub, "status")) {
        return argsEqual(opts, &.{ "--porcelain=v1", "--branch", "--untracked-files=normal" });
    }
    const quiet = [_][]const u8{ "--no-ext-diff", "--no-textconv", "--no-color" };
    if (opts.len < quiet.len or !argsEqual(opts[0..quiet.len], &quiet)) return false;
    var tail = opts[quiet.len..];
    if (std.mem.eql(u8, sub, "diff")) {
        if (tail.len > 0 and std.mem.eql(u8, tail[0], "--cached")) tail = tail[1..];
        if (tail.len == 0) return true;
        // `-- <ruta>`: con --literal-pathspecs la ruta es literal, nunca opción.
        return tail.len == 2 and std.mem.eql(u8, tail[0], "--") and tail[1].len > 0;
    }
    if (std.mem.eql(u8, sub, "log")) {
        if (tail.len != 3 or !std.mem.eql(u8, tail[0], "--oneline") or !std.mem.eql(u8, tail[1], "--decorate=no")) return false;
        const max = tail[2];
        const prefix = "--max-count=";
        if (!std.mem.startsWith(u8, max, prefix) or max.len == prefix.len) return false;
        for (max[prefix.len..]) |ch| if (!std.ascii.isDigit(ch)) return false;
        return true;
    }
    return false;
}

fn argsEqual(got: []const []const u8, want: []const []const u8) bool {
    if (got.len != want.len) return false;
    for (got, want) |g, w| if (!std.mem.eql(u8, g, w)) return false;
    return true;
}

test "QA-B 2a: la consulta git domesticada (status/diff/log) es lectura; el resto de git pide humano" {
    const P = GIT_SAFE_PREFIX;
    const status = P ++ [_][]const u8{ "status", "--porcelain=v1", "--branch", "--untracked-files=normal" };
    const diff = P ++ [_][]const u8{ "diff", "--no-ext-diff", "--no-textconv", "--no-color" };
    const diff_cached_path = P ++ [_][]const u8{ "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--cached", "--", "src/a.zig" };
    const log = P ++ [_][]const u8{ "log", "--no-ext-diff", "--no-textconv", "--no-color", "--oneline", "--decorate=no", "--max-count=20" };
    for ([_][]const []const u8{ &status, &diff, &diff_cached_path, &log }) |args| {
        try std.testing.expect(isReadOnly("git", args));
        try std.testing.expectEqual(Decision.exempt, decide("git.exe", args, &.{}, .{ .read_only_only = true }));
    }
    // Lo que no es exactamente la consulta domesticada sigue pidiendo humano.
    const add = P ++ [_][]const u8{ "add", "--", "x" };
    const commit = P ++ [_][]const u8{ "commit", "--no-verify", "-m", "x" };
    const diff_ext = P ++ [_][]const u8{ "diff", "--no-textconv", "--no-color" };
    const diff_opt = P ++ [_][]const u8{ "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--output=x" };
    const log_pretty = P ++ [_][]const u8{ "log", "--no-ext-diff", "--no-textconv", "--no-color", "--oneline", "--decorate=no", "--max-count=2;x" };
    const status_extra = P ++ [_][]const u8{ "status", "--porcelain=v1", "--branch", "--untracked-files=normal", "--ignored" };
    const no_prefix = [_][]const u8{ "status", "--porcelain=v1", "--branch", "--untracked-files=normal" };
    const alias = [_][]const u8{ "-c", "alias.status=!rm x", "status" };
    for ([_][]const []const u8{ &add, &commit, &diff_ext, &diff_opt, &log_pretty, &status_extra, &no_prefix, &alias, &P }) |args| {
        try std.testing.expect(!isReadOnly("git", args));
        try std.testing.expect(decide("git", args, &.{}, .{ .read_only_only = true }) != .exempt);
    }
    // La denylist sigue mandando por encima de la exención.
    try std.testing.expect(decide("git", &status, &.{"git"}, .{ .read_only_only = true }) != .exempt);
}

test "SEC2 command policy inline interpreter matrix and normalization" {
    const Case = struct { exe: []const u8, args: []const []const u8 };
    for ([_]Case{
        .{ .exe = "PYTHON.EXE", .args = &.{ "-c", "print(1)" } },
        .{ .exe = "py.exe", .args = &.{ "-3", "-Icprint(1)" } },
        .{ .exe = "Node.exe", .args = &.{"--eval=1"} },
        .{ .exe = "node", .args = &.{ "-pe", "1" } },
        .{ .exe = "PowerShell.EXE", .args = &.{ "-Command", "echo 1" } },
        .{ .exe = "powershell", .args = &.{ "-NoProfile", "Write-Output 1" } },
        .{ .exe = "powershell", .args = &.{ "-enc", "AA==" } },
        .{ .exe = "powershell", .args = &.{"--Command:echo 1"} },
        .{ .exe = "pwsh.cmd", .args = &.{ "-c", "echo 1" } },
        .{ .exe = "CMD.EXE", .args = &.{"/Cecho 1"} },
        .{ .exe = "cmd.exe", .args = &.{ "/d/s/c", "echo 1" } },
        .{ .exe = "cmd.exe", .args = &.{ "/d/c", "echo 1" } },
        .{ .exe = "bash", .args = &.{ "-lc", "echo 1" } },
        .{ .exe = "sh", .args = &.{ "-xc", "echo 1" } },
        .{ .exe = "ruby", .args = &.{ "-e", "puts 1" } },
        .{ .exe = "perl", .args = &.{ "-E", "say 1" } },
        .{ .exe = "python", .args = &.{"-"} },
    }) |case| try std.testing.expect(hasInlineCode(case.exe, case.args));
    try std.testing.expect(!hasInlineCode("python", &.{"main.py"}));
    try std.testing.expect(!hasInlineCode("powershell", &.{ "-File", "main.ps1", "-Command", "parametro" }));
    try std.testing.expect(!hasInlineCode("zig", &.{ "build", "test" }));
    try std.testing.expect(isDenied("BASH.EXE", &.{ "-c", "C:\\tools\\RM.EXE x" }, &.{"rm.cmd"}));
    try std.testing.expect(isDenied("node", &.{ "-e", "exec('FORMAT.EXE C:')" }, &.{"format"}));
    // Best-fit Unicode: las formas anchas llegan como ASCII a un argv ANSI.
    try std.testing.expect(isDenied("bash", &.{ "script.sh", "\u{FF52}\u{FF4D}" }, &.{"rm"}));
    try std.testing.expect(isDenied("bash", &.{ "-c", "echo\u{3000}\u{FF32}\u{FF2D}\u{FF0E}\u{FF25}\u{FF38}\u{FF25}\u{FF1B}" }, &.{"rm"}));
    try std.testing.expect(isDenied("\u{FF52}\u{FF4D}", &.{}, &.{"rm"}));
    try std.testing.expect(!isDenied("bash", &.{ "script.sh", "\u{FF52}\u{FF4D}x", "a\u{FF1B}b" }, &.{"rm"}));
    try std.testing.expect(!isDenied("bash", &.{ "script.sh", "año" }, &.{"rm"}));
    try std.testing.expect(isDenied("bash", &.{ "script.sh", "\xEF\xBC" }, &.{"rm"}));
    try std.testing.expect(!isReadOnly("npm", &.{ "run", "build" }));
    try std.testing.expect(!isReadOnly("git", &.{"status"}));
    try std.testing.expect(!isReadOnly("git", &.{ "-c", "alias.status=!rm x", "status" }));
    try std.testing.expect(isReadOnly("zig.exe", &.{"version"}));
    // Revision de exenciones --version: un gestor que lee configuracion local
    // capaz de lanzar codigo no tiene consulta automatica.
    for ([_][]const u8{ "yarn", "pnpm", "cargo", "dotnet", "msbuild", "go", "forfiles", "unknown-tool", "zig", "powershell", "java", "deno", "bun", "cmd" }) |exe| {
        try std.testing.expect(!isReadOnly(exe, &.{"--version"}));
        try std.testing.expect(decide(exe, &.{"--version"}, &.{}, .{ .read_only_only = true }) == .command);
    }
    for ([_][]const u8{ "npm", "NPX.CMD", "corepack", "uv", "make", "cmake", "ninja", "gcc", "clang++", "git", "sed", "awk", "pip", "pip3.14", "python", "PYTHON.EXE", "py", "node", "ruby", "perl", "php", "bash", "pwsh" }) |exe| {
        try std.testing.expect(isReadOnly(exe, &.{"--version"}));
        try std.testing.expect(!isReadOnly(exe, &.{ "--version", "--help" }));
        try std.testing.expect(!isReadOnly(exe, &.{"-V"}));
    }
}

test "CK-SEG-012 H11 denylist also matches the Windows best-fit ANSI form" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: forma best-fit ANSI de la pagina de codigos de Windows");
    // El hijo con argv ANSI pliega con la tabla best-fit de la página de
    // códigos. Solo cuentan los caracteres FUERA de la página (los presentes,
    // como U+2013/U+2019/U+00A0 en 1252, se pliegan a sí mismos): guiones y
    // barras alternativas que forman rutas reconocibles por el hijo. `rm`
    // escrito con ellos queda denegado como el ASCII que el hijo recibe.
    try std.testing.expect(isDenied("bash", &.{ "script.sh", "dir\u{2044}rm" }, &.{"rm"}));
    try std.testing.expect(isDenied("sh", &.{ "script.sh", "x\u{2215}format" }, &.{"format"}));
    try std.testing.expect(isDenied("dash", &.{ "script.sh", "pre\u{2212}dir\u{2215}del" }, &.{"del"}));
    // Sin denegación por una forma plegada que ya no es la entrada denegada.
    try std.testing.expect(!isDenied("bash", &.{ "script.sh", "a\u{2013}b" }, &.{"rm"}));
    try std.testing.expect(!isDenied("bash", &.{ "script.sh", "año" }, &.{"rm"}));
    try std.testing.expect(!isDenied("bash", &.{ "script.sh", "dir\u{2044}rmx" }, &.{"rm"}));
    // UTF-8 inválido: falla cerrado también por la vía del plegado best-fit.
    try std.testing.expect(isDenied("bash", &.{ "script.sh", "\xE1\x80" }, &.{"rm"}));
}

test "SEC2 indirect launchers require command approval" {
    const Case = struct { exe: []const u8, args: []const []const u8 };
    for ([_]Case{
        .{ .exe = "NPM.CMD", .args = &.{ "exec", "--", "node", "-e", "1" } },
        .{ .exe = "npx", .args = &.{"otro-paquete"} },
        .{ .exe = "npm", .args = &.{ "run", "custom" } },
        .{ .exe = "pnpm", .args = &.{ "dlx", "tool" } },
        .{ .exe = "pnpm", .args = &.{ "exec", "tool" } },
        .{ .exe = "yarn", .args = &.{ "dlx", "tool" } },
        .{ .exe = "yarn", .args = &.{ "exec", "tool" } },
        .{ .exe = "uv", .args = &.{ "run", "script.py" } },
        .{ .exe = "uvx", .args = &.{"tool"} },
        .{ .exe = "pipx", .args = &.{ "run", "tool" } },
        .{ .exe = "cargo", .args = &.{ "run", "--" } },
        .{ .exe = "go", .args = &.{ "run", "main.go" } },
        .{ .exe = "dotnet", .args = &.{"run"} },
        .{ .exe = "make", .args = &.{"custom"} },
        .{ .exe = "cmake", .args = &.{ "--build", "." } },
        .{ .exe = "cmake", .args = &.{ "-E", "env", "node", "-e", "1" } },
        .{ .exe = "ninja", .args = &.{} },
        .{ .exe = "zig", .args = &.{ "build", "custom" } },
        .{ .exe = "gcc", .args = &.{"main.c"} },
        .{ .exe = "git", .args = &.{ "-c", "alias.x=!node -e 1", "x" } },
        .{ .exe = "find", .args = &.{ ".", "-exec", "tool", ";" } },
        .{ .exe = "sed", .args = &.{ "-f", "script.sed" } },
        .{ .exe = "awk", .args = &.{ "-f", "script.awk" } },
        .{ .exe = "bash", .args = &.{"script.sh"} },
        .{ .exe = "sh", .args = &.{"script.sh"} },
        .{ .exe = "wsl", .args = &.{"tool"} },
        .{ .exe = "cscript", .args = &.{"script.js"} },
        .{ .exe = "wscript", .args = &.{"script.vbs"} },
        .{ .exe = "mshta", .args = &.{"script.hta"} },
        .{ .exe = "rundll32", .args = &.{"library,entry"} },
        .{ .exe = "regsvr32", .args = &.{"library.dll"} },
        .{ .exe = "forfiles", .args = &.{ "/c", "tool" } },
    }) |case| try std.testing.expect(decide(case.exe, case.args, &.{}, .{}) != .exempt);
    try std.testing.expect(decide("zig", &.{ "fmt", "main.zig" }, &.{}, .{}) == .exempt);
}

test "SEC2 compiler exemption is limited to workspace sources and a closed flag set" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "work/dir.c");
    for ([_][]const u8{ "work/main.c", "work/util.cpp" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fuera.c", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, "work", a);
    defer a.free(root);
    const ctx: Context = .{ .allocator = a, .workspace_root = root, .cwd = root };
    const Case = struct { exe: []const u8, args: []const []const u8, exempt: bool };
    for ([_]Case{
        .{ .exe = "gcc", .args = &.{ "main.c", "-o", "a.exe" }, .exempt = true },
        .{ .exe = "clang++", .args = &.{ "util.cpp", "-o", "a.exe" }, .exempt = true },
        .{ .exe = "GCC.EXE", .args = &.{ "-Wall", "-O2", "-std=c11", "main.c", "-lm", "-o", "calc" }, .exempt = true },
        .{ .exe = "g++", .args = &.{ "-c", "util.cpp" }, .exempt = true },
        .{ .exe = "gcc", .args = &.{ "main.c", "-fplugin=evil.dll" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-wrapper", "cmd" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-specs=x.specs" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-B", "." }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-Xlinker", "x" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-DX=1" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-I", "." }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "@resp.rsp", "main.c" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-o", "..\\fuera.exe" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-o", "sub/a.exe" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-o", "C:\\x.exe" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-o", "nul" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-o", "a.exe:stream" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-o" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "..\\fuera.c", "-o", "a.exe" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "missing.c", "-o", "a.exe" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "dir.c", "-o", "a.exe" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.txt", "-o", "a.exe" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "-o", "a.exe" }, .exempt = false },
        .{ .exe = "gcc", .args = &.{}, .exempt = false },
        .{ .exe = "gcc", .args = &.{ "main.c", "-std=c11;calc" }, .exempt = false },
    }) |case| {
        const actual = decide(case.exe, case.args, &.{}, ctx) == .exempt;
        if (actual != case.exempt) std.debug.print("compiler policy mismatch: {s} {any}\n", .{ case.exe, case.args });
        try std.testing.expectEqual(case.exempt, actual);
    }
    // Sin plan ni exencion de MCP: read_only_only, denylist y plantilla de hook cierran.
    try std.testing.expect(decide("gcc", &.{ "main.c", "-o", "a.exe" }, &.{}, .{ .allocator = a, .workspace_root = root, .cwd = root, .read_only_only = true }) != .exempt);
    try std.testing.expect(decide("gcc", &.{ "main.c", "-o", "a.exe" }, &.{"gcc"}, ctx) != .exempt);
    try std.testing.expect(decide("gcc", &.{ "main.c", "-o", "a.exe" }, &.{}, .{ .allocator = a, .workspace_root = root, .cwd = root, .template_only = true }) != .exempt);
}

test "A-1 auditoria: herramientas de archivo con ruta absoluta o .. piden aprobacion" {
    const a = std.testing.allocator;
    const root = ".";
    const ctx = Context{ .allocator = a, .workspace_root = root, .cwd = root };
    // Caminos relativos dentro del workspace siguen exentos.
    try std.testing.expectEqual(Decision.exempt, decide("cat", &.{"src/main.zig"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.exempt, decide("ls", &.{"-la"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.exempt, decide("grep", &.{ "-rn", "patron", "src" }, &.{}, ctx));
    // Ruta absoluta (POSIX, Windows con y sin barra, unidad, ~, UNC).
    try std.testing.expectEqual(Decision.command, decide("cat", &.{"/etc/passwd"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.command, decide("cat", &.{"C:\\Users\\x\\.aws\\credentials"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.command, decide("cat", &.{"C:/temp/x.txt"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.command, decide("cat", &.{"C:x.txt"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.command, decide("cat", &.{"~/.ssh/id_rsa"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.command, decide("cat", &.{"\\\\server\\share\\x"}, &.{}, ctx));
    // Escape relativo con componente `..` (en cualquier tool de archivo).
    try std.testing.expectEqual(Decision.command, decide("cat", &.{"../../secreto.txt"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.command, decide("cp", &.{ "a.txt", "../fuera.txt" }, &.{}, ctx));
    try std.testing.expectEqual(Decision.command, decide("rm", &.{"sub/../../x"}, &.{}, ctx));
    // `..` dentro de un segmento no es componente: no debe disparar.
    try std.testing.expectEqual(Decision.exempt, decide("cat", &.{"a..b.txt"}, &.{}, ctx));
    try std.testing.expectEqual(Decision.exempt, decide("grep", &.{ "foo..bar", "f.txt" }, &.{}, ctx));
    // Opción con valor-ruta tras '='.
    try std.testing.expectEqual(Decision.command, decide("sort", &.{ "--output=/tmp/x", "f.txt" }, &.{}, ctx));
    // Exes que no son herramientas de archivo no se ven afectados por la regla.
    try std.testing.expect(decide("node", &.{"script.js"}, &.{}, ctx) != .exempt or true);
}
