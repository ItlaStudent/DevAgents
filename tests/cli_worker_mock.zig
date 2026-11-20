const std = @import("std");

/// Mock ejecutable para ExternalCliWorker (T-F5-04): lee una tarea JSON de stdin
/// y escribe artefactos predecibles a stdout, luego sale. Sin red, determinista.
///
/// Protocolo original (sin flags): espera una línea JSON
/// `{"id":"...","desc":"...","type":"..."}` por stdin, responde con
/// `[{"field":"src/main.c","content":"<desc>"}]` por stdout, y sale.
///
/// E5.07 (ampliado): `--headless <escenario>` para los adaptadores sin
/// interfaz. El prompt llega por argv (último posicional) o stdin; el mock no
/// lo necesita — actúa según el escenario:
///   edit    escribe mock_edit.txt en el cwd (prueba cwd=worktree + diff),
///           emite líneas stream-json y un result final
///   stream  emite líneas stream-json (assistant + tool + result)
///   stderr  escribe una línea en stderr además de stdout
///   hang    emite una línea "mock-hang" y se queda en bucle (timeout → kill)
const is_windows = @import("builtin").os.tag == .windows;
const GetCurrentDirectoryA = if (is_windows) struct {
    extern "kernel32" fn GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: [*]u8) u32;
}.GetCurrentDirectoryA else posixCwd;
fn posixCwd(size: u32, buf: [*]u8) u32 {
    if (std.c.getcwd(buf, size) == null) return 0;
    return @intCast(std.mem.len(@as([*:0]u8, @ptrCast(buf))));
}
const winSleep = struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) void;
}.Sleep;
fn Sleep(ms: u32) void {
    if (is_windows) return winSleep(ms);
    var duration: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    while (std.c.nanosleep(&duration, &duration) != 0) {
        if (std.c._errno().* != @intFromEnum(std.posix.E.INTR)) @panic("fixture nanosleep failed");
    }
}

const HeadlessScenario = enum { edit, stream, stderr_out, hang, clock, lock, acl_clock, acl_error, acl_hang, acl_cancel, tree_success, tree_error, tree_hang, tree_cancel, tree_leaf, tree_breakaway, echo_stdin, session, quota_account, permissions };

const Acl = extern struct { revision: u8, reserved: u8, size: u16, ace_count: u16, reserved2: u16 };
const AceHeader = extern struct { kind: u8, flags: u8, size: u16 };
const AclSizeInfo = extern struct { ace_count: u32, bytes_in_use: u32, bytes_free: u32 };
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn GetSecurityInfo(std.os.windows.HANDLE, c_int, u32, ?*?*anyopaque, ?*?*anyopaque, *?*Acl, ?*?*Acl, *?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn GetSecurityDescriptorControl(*anyopaque, *u16, *u32) callconv(.winapi) c_int;
extern "advapi32" fn GetAclInformation(*Acl, *AclSizeInfo, u32, c_int) callconv(.winapi) c_int;
extern "advapi32" fn GetAce(*Acl, u32, *?*anyopaque) callconv(.winapi) c_int;
extern "advapi32" fn InitializeAcl(*Acl, u32, u32) callconv(.winapi) c_int;
extern "advapi32" fn AddAce(*Acl, u32, u32, *anyopaque, u32) callconv(.winapi) c_int;
extern "advapi32" fn AddAccessAllowedAceEx(*Acl, u32, u32, u32, *anyopaque) callconv(.winapi) c_int;
extern "advapi32" fn ConvertStringSidToSidW([*:0]const u16, *?*anyopaque) callconv(.winapi) c_int;
extern "advapi32" fn GetLengthSid(*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn SetSecurityInfo(std.os.windows.HANDLE, c_int, u32, ?*anyopaque, ?*anyopaque, ?*Acl, ?*Acl) callconv(.winapi) u32;

fn mockAclCheck(stage: []const u8, code: u32) !void {
    if (code == 0) return;
    std.debug.print("mock ACL: etapa={s}; win32={d}\n", .{ stage, code });
    return error.AclGrantFailed;
}

fn addWorkspaceAce(a: std.mem.Allocator) !void {
    // T9: en POSIX lo que deja un CLI que abre la carpeta es escritura de otros.
    if (!is_windows) {
        const meta = std.c.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (meta < 0) return error.AclMockFailed;
        defer _ = std.c.close(meta);
        if (std.c.fchmod(meta, 0o702) != 0) return error.AclMockFailed;
        return;
    }
    // Synthetic binary SID: this fixture must not depend on SAM/account lookup.
    // Clone the live DACL, preserving every existing ACE and root protection.
    const handle = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("."), 0x60080, 3, null, 3, 0x02200000, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) try mockAclCheck("open", GetLastError());
    defer _ = CloseHandle(handle);
    var descriptor: ?*anyopaque = null;
    var existing: ?*Acl = null;
    try mockAclCheck("capture", GetSecurityInfo(handle, 1, 4, null, null, &existing, null, &descriptor));
    defer _ = LocalFree(descriptor);
    const original = existing orelse return error.AclGrantFailed;
    const security = descriptor orelse return error.AclGrantFailed;
    var control: u16 = 0;
    var revision: u32 = 0;
    if (GetSecurityDescriptorControl(security, &control, &revision) == 0) try mockAclCheck("control", GetLastError());
    var sid: ?*anyopaque = null;
    if (ConvertStringSidToSidW(std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-123-456-789-4080735840"), &sid) == 0) try mockAclCheck("sid", GetLastError());
    defer _ = LocalFree(sid);
    const principal = sid orelse return error.AclGrantFailed;
    var info: AclSizeInfo = undefined;
    if (GetAclInformation(original, &info, @sizeOf(AclSizeInfo), 2) == 0) try mockAclCheck("acl-size", GetLastError());
    const size = std.math.add(u32, info.bytes_in_use, 8 + GetLengthSid(principal)) catch return error.AclGrantFailed;
    if (size > std.math.maxInt(u16)) return error.AclGrantFailed;
    const buffer = try a.alignedAlloc(u8, .of(u32), size);
    defer a.free(buffer);
    const augmented: *Acl = @ptrCast(buffer.ptr);
    if (InitializeAcl(augmented, size, original.revision) == 0) try mockAclCheck("acl-init", GetLastError());
    var added = false;
    var i: u32 = 0;
    while (i < info.ace_count) : (i += 1) {
        var pointer: ?*anyopaque = null;
        if (GetAce(original, i, &pointer) == 0) try mockAclCheck("ace-read", GetLastError());
        const entry = pointer orelse return error.AclGrantFailed;
        const header: *const AceHeader = @ptrCast(@alignCast(entry));
        // New explicit grant precedes inherited entries; all original entries
        // retain their relative order, masks, flags and binary SID bytes.
        if (!added and header.flags & 0x10 != 0) {
            if (AddAccessAllowedAceEx(augmented, original.revision, 3, 0x1301bf, principal) == 0) try mockAclCheck("grant", GetLastError());
            added = true;
        }
        if (AddAce(augmented, original.revision, std.math.maxInt(u32), entry, header.size) == 0) try mockAclCheck("ace-copy", GetLastError());
    }
    if (!added and AddAccessAllowedAceEx(augmented, original.revision, 3, 0x1301bf, principal) == 0) try mockAclCheck("grant", GetLastError());
    const protection: u32 = if (control & 0x1000 != 0) 0x80000000 else 0x20000000;
    try mockAclCheck("apply", SetSecurityInfo(handle, 1, 4 | protection, null, null, augmented, null));
}

extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn CloseHandle(std.os.windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn GetModuleFileNameW(?std.os.windows.HANDLE, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetProcessId(std.os.windows.HANDLE) callconv(.winapi) u32;

const StartupInfoW = extern struct {
    cb: u32,
    reserved: ?[*:0]u16,
    desktop: ?[*:0]u16,
    title: ?[*:0]u16,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_chars: u32,
    y_chars: u32,
    fill_attribute: u32,
    flags: u32,
    show_window: u16,
    reserved2: u16,
    reserved3: ?*u8,
    std_input: ?std.os.windows.HANDLE,
    std_output: ?std.os.windows.HANDLE,
    std_error: ?std.os.windows.HANDLE,
};
const ProcessInformation = extern struct { process: ?std.os.windows.HANDLE, thread: ?std.os.windows.HANDLE, process_id: u32, thread_id: u32 };
extern "kernel32" fn CreateProcessW(?[*:0]const u16, ?[*:0]u16, ?*anyopaque, ?*anyopaque, c_int, u32, ?*anyopaque, ?[*:0]const u16, *StartupInfoW, *ProcessInformation) callconv(.winapi) c_int;

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var headless: ?HeadlessScenario = null;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip(); // argv[0]
    var recorded_args = std.ArrayList([]const u8).empty;
    defer recorded_args.deinit(allocator);
    var saw_headless = false;
    while (args_iter.next()) |arg| {
        try recorded_args.append(allocator, arg);
        if (std.mem.eql(u8, arg, "--headless")) {
            saw_headless = true;
        } else if (saw_headless and headless == null) {
            // T7: el adaptador añade al encargo las [REGLAS DEL PROYECTO] tras
            // un salto de línea; el escenario es la primera línea del prompt.
            const word = std.mem.sliceTo(arg, '\n');
            if (std.mem.eql(u8, word, "edit")) headless = .edit;
            if (std.mem.eql(u8, word, "stream")) headless = .stream;
            if (std.mem.eql(u8, word, "stderr")) headless = .stderr_out;
            if (std.mem.eql(u8, word, "hang")) headless = .hang;
            if (std.mem.eql(u8, word, "clock")) headless = .clock;
            if (std.mem.eql(u8, word, "lock")) headless = .lock;
            if (std.mem.eql(u8, word, "acl-clock")) headless = .acl_clock;
            if (std.mem.eql(u8, word, "acl-error")) headless = .acl_error;
            if (std.mem.eql(u8, word, "acl-hang")) headless = .acl_hang;
            if (std.mem.eql(u8, word, "acl-cancel")) headless = .acl_cancel;
            if (std.mem.eql(u8, word, "tree-success")) headless = .tree_success;
            if (std.mem.eql(u8, word, "tree-error")) headless = .tree_error;
            if (std.mem.eql(u8, word, "tree-hang")) headless = .tree_hang;
            if (std.mem.eql(u8, word, "tree-cancel")) headless = .tree_cancel;
            if (std.mem.eql(u8, word, "tree-leaf")) headless = .tree_leaf;
            if (std.mem.eql(u8, word, "tree-breakaway")) headless = .tree_breakaway;
            if (std.mem.eql(u8, word, "echo-stdin")) headless = .echo_stdin;
            if (std.mem.eql(u8, word, "session")) headless = .session;
            if (std.mem.eql(u8, word, "quota-account")) headless = .quota_account;
            if (std.mem.eql(u8, word, "permissions")) headless = .permissions;
        }
    }

    // Fixture detached: sin consola ni stdin/stdout, registra el argv real.
    for (recorded_args.items, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--record-argv")) {
            if (index + 1 == recorded_args.items.len) return error.MissingRecordPath;
            const payload = try std.json.Stringify.valueAlloc(allocator, recorded_args.items, .{});
            defer allocator.free(payload);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = recorded_args.items[index + 1], .data = payload });
            return;
        }
    }

    const out = std.Io.File.stdout();
    var out_buf: [16384]u8 = undefined;
    var writer = out.writerStreaming(io, &out_buf);

    // QA-B H7: lanzado como Claude Code de verdad (`-p --output-format
    // stream-json`, el prompt por stdin), responde como su modo sin interfaz:
    // un plan JSON válido, o una salida que no es un plan si el encargo dice
    // PLAN_INVALIDO. Así la prueba de punta a punta planifica sin ninguna CLI
    // real ni clave.
    if (headless == null and recorded_args.items.len >= 3 and std.mem.eql(u8, recorded_args.items[0], "-p") and
        std.mem.eql(u8, recorded_args.items[2], "stream-json"))
    {
        const input = std.Io.File.stdin();
        var in_buf: [8192]u8 = undefined;
        var reader = input.readerStreaming(io, &in_buf);
        var captured: std.Io.Writer.Allocating = .init(allocator);
        defer captured.deinit();
        _ = try reader.interface.streamRemaining(&captured.writer);
        const invalid = std.mem.indexOf(u8, captured.written(), "PLAN_INVALIDO") != null;
        const plan = if (invalid)
            "Aquí tienes el plan: primero escribo el archivo y luego lo pruebo."
        else
            "```json\n{\"understanding\":\"Crear hola.py que imprime hola (plan de la CLI simulada)\",\"tasks\":[{\"id\":\"t1\",\"task_type\":\"programar\",\"department\":\"programacion\",\"description\":\"Escribe hola.py que imprime hola\",\"contract_fields\":[],\"depends_on\":[]}]}\n```";
        try writer.interface.writeAll("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"plan-mock\"}\n");
        var js: std.json.Stringify = .{ .writer = &writer.interface, .options = .{} };
        try js.write(.{ .type = "result", .subtype = "success", .result = plan });
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        return;
    }

    if (headless) |scenario| {
        switch (scenario) {
            // T12 A2: registra el argv y la configuración en línea de
            // OpenCode con que se lanzó (permisos de solo lectura al planificar).
            .permissions => {
                const environ = if (@import("builtin").os.tag == .windows) std.process.Environ{ .block = .global } else std.process.Environ{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } };
                const opencode = std.process.Environ.getAlloc(environ, allocator, "OPENCODE_CONFIG_CONTENT") catch |e| switch (e) {
                    error.EnvironmentVariableMissing => try allocator.dupe(u8, ""),
                    else => return e,
                };
                defer allocator.free(opencode);
                const request = try std.json.Stringify.valueAlloc(allocator, .{ .argv = recorded_args.items, .opencode_config = opencode }, .{});
                defer allocator.free(request);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "permissions-request.json", .data = request });
                try writer.interface.writeAll("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"mock permisos\"}\n");
            },
            .session => {
                const input = std.Io.File.stdin();
                var buf: [4096]u8 = undefined;
                var reader = input.readerStreaming(io, &buf);
                var captured: std.Io.Writer.Allocating = .init(allocator);
                defer captured.deinit();
                _ = try reader.interface.streamRemaining(&captured.writer);
                var cli_id: []const u8 = "";
                var resume_id: ?[]const u8 = null;
                for (recorded_args.items, 0..) |arg, index| {
                    if (index + 1 >= recorded_args.items.len) continue;
                    if (std.mem.eql(u8, arg, "--mock-cli")) cli_id = recorded_args.items[index + 1];
                    if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "--session") or std.mem.eql(u8, arg, "resume")) resume_id = recorded_args.items[index + 1];
                }
                const request = try std.json.Stringify.valueAlloc(allocator, .{ .argv = recorded_args.items, .prompt = captured.written() }, .{});
                defer allocator.free(request);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = if (resume_id != null) "resume-request.json" else "fresh-request.json", .data = request });
                if (resume_id) |id| {
                    if (std.mem.eql(u8, id, "expired")) {
                        try writer.interface.writeAll("{\"type\":\"error\",\"sessionID\":\"expired\",\"error\":{\"message\":\"Session not found: expired\"}}\n");
                        try writer.interface.flush();
                        std.process.exit(2);
                    }
                    if (std.mem.eql(u8, id, "quota")) {
                        try writer.interface.writeAll("quota exceeded\n");
                        try writer.interface.flush();
                        std.process.exit(3);
                    }
                }
                const id = resume_id orelse "saved-123";
                if (std.mem.eql(u8, cli_id, "claude-code")) {
                    try writer.interface.print("{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"{s}\"}}\n", .{id});
                } else if (std.mem.eql(u8, cli_id, "codex")) {
                    try writer.interface.print("{{\"type\":\"thread.started\",\"thread_id\":\"{s}\"}}\n", .{id});
                } else if (std.mem.eql(u8, cli_id, "opencode")) {
                    try writer.interface.print("{{\"type\":\"step_start\",\"sessionID\":\"{s}\",\"part\":{{\"type\":\"step-start\"}}}}\n", .{id});
                } else return error.UnknownMockCli;
                try writer.interface.flush();
                if (std.mem.eql(u8, id, "interrupted")) while (true) Sleep(1000);
                if (std.mem.eql(u8, cli_id, "codex")) {
                    try writer.interface.writeAll("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"mock complete\"}}\n");
                } else try writer.interface.writeAll("{\"type\":\"result\",\"result\":\"mock complete\"}\n");
            },
            .tree_leaf => {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "descendant.ready", .data = "active" });
                while (true) Sleep(3600000);
            },
            .tree_breakaway => if (!is_windows) {
                // T9: no hay Job Objects en Linux; el escenario no aplica.
                try writer.interface.print("BREAKAWAY=unsupported_on_linux\n", .{});
                try writer.interface.flush();
            } else {
                // El Job de la sesión no concede BREAKAWAY: salir de él debe fallar.
                const exe = try selfExe(allocator);
                defer allocator.free(exe);
                const command = try std.fmt.allocPrint(allocator, "\"{s}\" --headless tree-leaf", .{exe});
                defer allocator.free(command);
                const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command);
                defer allocator.free(wide);
                var startup = std.mem.zeroes(StartupInfoW);
                startup.cb = @sizeOf(StartupInfoW);
                var info: ProcessInformation = undefined;
                // CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW
                if (CreateProcessW(null, wide.ptr, null, null, 0, 0x01000000 | 0x08000000, null, null, &startup, &info) == 0) {
                    try writer.interface.print("BREAKAWAY=denied;code={d}\n", .{GetLastError()});
                } else {
                    try writer.interface.print("BREAKAWAY=allowed;pid={d}\n", .{info.process_id});
                    _ = CloseHandle(info.process.?);
                    _ = CloseHandle(info.thread.?);
                }
                try writer.interface.flush();
            },
            .tree_success, .tree_error, .tree_hang, .tree_cancel => {
                const exe = try selfExe(allocator);
                defer allocator.free(exe);
                const descendant = try std.process.spawn(io, .{
                    .argv = &.{ exe, "--headless", "tree-leaf" },
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                    .create_no_window = true,
                });
                const pid: u32 = if (is_windows) GetProcessId(descendant.id.?) else @intCast(descendant.id.?);
                if (pid == 0) return error.DescendantIdUnavailable;
                var attempts: usize = 0;
                while (attempts < 500) : (attempts += 1) {
                    if (std.Io.Dir.cwd().openFile(io, "descendant.ready", .{})) |ready| {
                        ready.close(io);
                        break;
                    } else |err| {
                        if (err != error.FileNotFound) return err;
                        Sleep(10);
                    }
                }
                if (attempts == 500) return error.DescendantNotReady;
                // Leave the descendant active with no inherited protocol pipes.
                // Closing the parent's handles does not terminate that process.
                if (is_windows) {
                    _ = CloseHandle(descendant.id.?);
                    _ = CloseHandle(descendant.thread_handle);
                }
                try writer.interface.print("DESCENDANT_PID={d}\n", .{pid});
                try writer.interface.flush();
                if (scenario == .tree_error) std.process.exit(7);
                if (scenario == .tree_hang or scenario == .tree_cancel) while (true) Sleep(3600000);
            },
            .acl_clock, .acl_error, .acl_hang, .acl_cancel => {
                try addWorkspaceAce(allocator);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "acl-child.txt", .data = "created under inherited sandbox ACE" });
                try writer.interface.writeAll("{\"type\":\"assistant\",\"message\":{\"content\":\"ACE added\"}}\n");
                try writer.interface.flush();
                if (scenario == .acl_error) std.process.exit(7);
                if (scenario == .acl_cancel) {
                    try writer.interface.writeAll("{\"type\":\"assistant\",\"message\":{\"content\":\"cancel now\"}}\n");
                    try writer.interface.flush();
                }
                if (scenario == .acl_hang or scenario == .acl_cancel) while (true) Sleep(3600000);
            },
            .echo_stdin => {
                const input = std.Io.File.stdin();
                var buf: [4096]u8 = undefined;
                var reader = input.readerStreaming(io, &buf);
                var captured: std.Io.Writer.Allocating = .init(allocator);
                defer captured.deinit();
                _ = try reader.interface.streamRemaining(&captured.writer);
                var js: std.json.Stringify = .{ .writer = &writer.interface, .options = .{} };
                try js.write(captured.written());
                try writer.interface.writeByte('\n');
            },
            .clock => {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "reloj.py", .data = "print('reloj-simulado')\n" });
                try writer.interface.writeAll("mock Codex: reloj.py escrito en cwd\n");
            },
            .lock => if (!is_windows) {
                // T9: sin bloqueo obligatorio en POSIX: flock exclusivo (consultivo).
                const fd = std.c.open("user.db", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
                if (fd < 0) return error.LockFailed;
                if (std.c.flock(fd, std.c.LOCK.EX) != 0) return error.LockFailed;
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "lock.ready", .data = "exclusive" });
                while (true) Sleep(3600000);
            } else {
                const handle = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("user.db"), 0x80000000, 0, null, 3, 0x80, null);
                if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.LockFailed;
                defer _ = CloseHandle(handle);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "lock.ready", .data = "exclusive" });
                while (true) Sleep(3600000);
            },
            // T7: cuenta con cuota agotada si su carpeta
            // (CODEX_HOME) termina en «agotada»; si no, completa la tarea.
            .quota_account => {
                const home = std.process.Environ.getAlloc(if (@import("builtin").os.tag == .windows) .{ .block = .global } else .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } }, allocator, "CODEX_HOME") catch "";
                if (std.mem.endsWith(u8, home, "agotada")) {
                    try writer.interface.writeAll("ERROR: You've hit your usage limit. Try again later.\n");
                    try writer.interface.flush();
                    std.process.exit(3);
                }
                try writer.interface.print("{{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"hecho con {s}\"}}\n", .{std.fs.path.basename(home)});
            },
            .edit => {
                // Prueba de cwd: el archivo debe caer en el worktree del hijo.
                var cwd_buf: [4096]u8 = undefined;
                const n: usize = if (@import("builtin").os.tag == .windows) GetCurrentDirectoryA(@intCast(cwd_buf.len), &cwd_buf) else if (std.c.getcwd(&cwd_buf, cwd_buf.len) != null) std.mem.len(@as([*:0]u8, @ptrCast(&cwd_buf))) else 0;
                const cwd = if (n > 0 and n < cwd_buf.len) cwd_buf[0..n] else "?";
                try std.Io.Dir.cwd().writeFile(io, .{
                    .sub_path = "mock_edit.txt",
                    .data = "editado por cli-worker-mock\n",
                });
                try writer.interface.print("CWD={s}\n", .{cwd});
                try writer.interface.writeAll("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"mock: edito mock_edit.txt\"}]}}\n");
                try writer.interface.writeAll("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"mock: cree mock_edit.txt\"}\n");
            },
            .stream => {
                try writer.interface.writeAll("{\"type\":\"system\",\"subtype\":\"init\"}\n");
                try writer.interface.writeAll("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"mock stream\"}]}}\n");
                try writer.interface.writeAll("{\"type\":\"tool_use\",\"name\":\"Edit\"}\n");
                try writer.interface.writeAll("{\"type\":\"result\",\"result\":\"mock stream listo\"}\n");
            },
            .stderr_out => {
                const errf = std.Io.File.stderr();
                var err_buf: [1024]u8 = undefined;
                var ew = errf.writerStreaming(io, &err_buf);
                try ew.interface.writeAll("stderr-del-mock\n");
                try ew.interface.flush();
                try writer.interface.writeAll("{\"type\":\"result\",\"result\":\"mock con stderr\"}\n");
            },
            .hang => {
                try writer.interface.writeAll("mock-hang: empiezo y me cuelgo\n");
                try writer.interface.flush();
                while (true) Sleep(3600000);
            },
        }
        try writer.interface.flush();
        return;
    }

    const in = std.Io.File.stdin();
    var in_buf: [16384]u8 = undefined;
    var reader = in.readerStreaming(io, &in_buf);

    const maybe = reader.interface.takeDelimiter('\n') catch return;
    const line = maybe orelse return;
    var trimmed = line;
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |e| {
        writer.interface.writeAll("ERROR: invalid JSON\n") catch return;
        writer.interface.flush() catch return;
        return e;
    };
    defer parsed.deinit();

    const content = if (parsed.value == .object)
        parsed.value.object.get("desc") orelse std.json.Value{ .string = "mock-output" }
    else
        std.json.Value{ .string = "mock-output" };

    var out_str: std.Io.Writer.Allocating = .init(allocator);
    defer out_str.deinit();
    var js: std.json.Stringify = .{ .writer = &out_str.writer, .options = .{} };
    try js.beginArray();
    try js.beginObject();
    try js.objectField("field");
    try js.write("src/main.c");
    try js.objectField("content");
    try js.write(content.string);
    try js.endObject();
    try js.endArray();

    writer.interface.writeAll(out_str.written()) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.interface.flush() catch return;
}

/// T9: ruta del propio ejecutable (GetModuleFileNameW o /proc/self/exe).
fn selfExe(allocator: std.mem.Allocator) ![]u8 {
    if (!is_windows) {
        var buf: [4096]u8 = undefined;
        const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
        if (n <= 0 or n >= buf.len) return error.ModulePathUnavailable;
        return allocator.dupe(u8, buf[0..@intCast(n)]);
    }
    var module: [32768]u16 = undefined;
    const n = GetModuleFileNameW(null, &module, module.len);
    if (n == 0 or n >= module.len) return error.ModulePathUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(allocator, module[0..n]);
}
