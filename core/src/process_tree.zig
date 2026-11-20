const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(windows.HANDLE, c_int, *const anyopaque, u32) callconv(.winapi) c_int;
extern "kernel32" fn QueryInformationJobObject(windows.HANDLE, c_int, *anyopaque, u32, ?*u32) callconv(.winapi) c_int;
extern "kernel32" fn AssignProcessToJobObject(windows.HANDLE, windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn TerminateJobObject(windows.HANDLE, u32) callconv(.winapi) c_int;
extern "kernel32" fn ResumeThread(windows.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
const Sleep = @import("platform.zig").sleep;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn IsProcessInJob(windows.HANDLE, windows.HANDLE, *c_int) callconv(.winapi) c_int;

// Same Win32 job layout and KILL_ON_JOB_CLOSE policy as executor.zig.
const BasicLimits = extern struct {
    process_time: i64 = 0,
    job_time: i64 = 0,
    flags: u32 = 0x2000,
    minimum_working_set: usize = 0,
    maximum_working_set: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};
const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io_counters: [6]u64 = @splat(0),
    process_memory_limit: usize = 0,
    job_memory_limit: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};
const Accounting = extern struct {
    total_user_time: i64 = 0,
    total_kernel_time: i64 = 0,
    period_user_time: i64 = 0,
    period_kernel_time: i64 = 0,
    page_faults: u32 = 0,
    total_processes: u32 = 0,
    active_processes: u32 = 0,
    terminated_processes: u32 = 0,
};
const ProcessIdsHeader = extern struct { assigned: u32, count: u32 };

/// Per-session job, never inherited and without BREAKAWAY permissions. Spawn
/// suspended, attach and resume: no descendant can escape during assignment.
pub const ProcessTree = struct {
    /// Tope de espera para que el trabajo quede sin procesos activos. Pasado
    /// el tope se abandona la espera con un aviso visible: nunca se bloquea.
    pub const terminate_timeout_ms: u32 = 15_000;
    /// Cuenta de árboles que no terminaron a tiempo en todo el proceso. Quien no
    /// puede leer `stuck` (transporte ACP ya liberado) compara esta cuenta
    /// antes y después; un falso positivo solo cancela una restauración.
    pub var stuck_total: std.atomic.Value(u32) = .init(0);

    handle: ?windows.HANDLE = null,
    /// T9: fuera de Windows el arbol es el grupo de procesos del hijo (el hijo
    /// se lanza con `.pgid = 0`, ver `spawn_pgid`); 0 = sin hijo asociado.
    pgid: i32 = 0,
    /// Quedaron procesos activos tras `terminate_timeout_ms`: no hay garantía
    /// de que ya no escriban, y quien restaure permisos debe fallar visible.
    stuck: bool = false,
    notice: ?struct { ctx: *anyopaque, callFn: *const fn (*anyopaque, []const u8) void } = null,

    /// Valor para `std.process.SpawnOptions.pgid`: en POSIX el hijo abre su
    /// propio grupo de procesos, que es lo que `deinit` termina entero.
    pub const spawn_pgid: ?std.posix.pid_t = if (builtin.os.tag == .windows) null else 0;

    pub fn init() error{SpawnFailed}!ProcessTree {
        if (builtin.os.tag != .windows) return .{};
        const handle = CreateJobObjectW(null, null) orelse return error.SpawnFailed;
        errdefer _ = CloseHandle(handle);
        const limits: ExtendedLimits = .{};
        if (SetInformationJobObject(handle, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return error.SpawnFailed;
        return .{ .handle = handle };
    }

    pub fn attachAndResume(self: *ProcessTree, child: *std.process.Child) error{SpawnFailed}!void {
        if (builtin.os.tag != .windows) {
            // spawn_pgid = 0: el pid del hijo es el identificador de su grupo.
            self.pgid = @intCast(child.id orelse return error.SpawnFailed);
            return;
        }
        if (AssignProcessToJobObject(self.handle.?, child.id.?) == 0) return error.SpawnFailed;
        if (ResumeThread(child.thread_handle) == 0xffffffff) return error.SpawnFailed;
    }

    pub fn parentExited(_: *const ProcessTree, child: *const std.process.Child) bool {
        if (builtin.os.tag != .windows) return posixExited(@intCast(child.id orelse return true));
        return WaitForSingleObject(child.id.?, 0) == 0;
    }

    fn cleanupNotice(self: *ProcessTree, operation: []const u8, code: u32) void {
        self.notify("limpieza del árbol de procesos: {s}; win32={d}", operation, code);
    }

    fn notify(self: *ProcessTree, comptime format: []const u8, operation: []const u8, code: u32) void {
        var buffer: [384]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, format, .{ operation, code }) catch "limpieza del árbol de procesos: no se pudieron sincronizar todos los procesos";
        std.debug.print("{s}\n", .{message});
        if (self.notice) |sink| sink.callFn(sink.ctx, message);
    }

    /// Solo aquí (árbol atascado) los permisos del espacio dejan de restaurarse.
    fn markStuck(self: *ProcessTree, operation: []const u8, code: u32) void {
        self.stuck = true;
        _ = stuck_total.fetchAdd(1, .acq_rel);
        self.notify("limpieza del árbol de procesos: {s}; win32={d}; los permisos del espacio no se restauran mientras queden procesos activos", operation, code);
    }

    /// ActiveProcesses=0 prevents further execution, but can precede process
    /// handle signaling. Retain accessible handles before terminating the job
    /// and wait for their final signal before workspace restoration.
    pub fn deinit(self: *ProcessTree) void {
        if (builtin.os.tag != .windows) return self.posixDeinit();
        const handle = self.handle orelse return;
        const allocator = std.heap.page_allocator;
        const header_words = @sizeOf(ProcessIdsHeader) / @sizeOf(usize);
        var processes: std.ArrayList(usize) = .empty;
        defer processes.deinit(allocator);
        var process_count: usize = 0;
        var words: usize = header_words + 64;
        while (true) {
            processes.resize(allocator, words) catch {
                self.cleanupNotice("no se pudo reservar memoria para la lista de procesos", 8);
                break;
            };
            const header: *ProcessIdsHeader = @ptrCast(processes.items.ptr);
            header.* = .{ .assigned = 0, .count = 0 };
            const queried = QueryInformationJobObject(handle, 3, processes.items.ptr, @intCast(processes.items.len * @sizeOf(usize)), null) != 0;
            const code = if (queried) 0 else GetLastError();
            if ((!queried and code == 234) or (queried and header.count < header.assigned)) {
                words = @max(words * 2, header_words + header.assigned);
                continue;
            }
            if (!queried) {
                self.cleanupNotice("no se pudo enumerar los procesos del trabajo", code);
                break;
            }
            process_count = header.count;
            break;
        }
        const retained = if (process_count == 0) processes.items[0..0] else processes.items[header_words..][0..process_count];
        for (retained) |*pid_or_handle| {
            const pid: u32 = @intCast(pid_or_handle.*);
            pid_or_handle.* = 0;
            const process = OpenProcess(0x100000 | 0x1000, 0, pid) orelse {
                const code = GetLastError();
                // Invalid PID already exited. A sandbox user's DACL may deny
                // SYNCHRONIZE; report it and rely on the job's active count.
                if (code != 87) self.cleanupNotice("no se pudo retener el proceso; se usa la cuenta del trabajo", code);
                continue;
            };
            var in_job: c_int = 0;
            if (IsProcessInJob(process, handle, &in_job) == 0) {
                self.cleanupNotice("no se pudo verificar que el proceso pertenece al trabajo", GetLastError());
                _ = CloseHandle(process);
                continue;
            }
            // Avoid waiting for an unrelated process if Windows reused a PID.
            if (in_job == 0) {
                _ = CloseHandle(process);
                continue;
            }
            pid_or_handle.* = @intFromPtr(process);
        }
        var reported = false;
        var waited_ms: u32 = 0;
        while (true) {
            const terminated = TerminateJobObject(handle, 1) != 0;
            const termination_error = if (terminated) 0 else GetLastError();
            var accounting: Accounting = .{};
            const queried = QueryInformationJobObject(handle, 1, &accounting, @sizeOf(Accounting), null) != 0;
            if (queried and accounting.active_processes == 0) break;
            if ((!terminated or !queried) and !reported) {
                self.cleanupNotice("no se pudo confirmar la terminación del trabajo", if (!queried) GetLastError() else termination_error);
                reported = true;
            }
            // La puerta sigue cerrada ante un fallo nativo, pero con tope:
            // pasado `terminate_timeout_ms` se marca `stuck` y se avisa.
            if (waited_ms >= terminate_timeout_ms) {
                self.markStuck("quedan procesos activos tras 15 s de espera", if (!queried) GetLastError() else termination_error);
                break;
            }
            Sleep(10);
            waited_ms += 10;
        }
        for (retained) |process| {
            if (process == 0) continue;
            const process_handle: windows.HANDLE = @ptrFromInt(process);
            // Con el trabajo atascado no se espera: cada espera tendría su tope.
            const signal = WaitForSingleObject(process_handle, if (self.stuck) 0 else terminate_timeout_ms);
            if (signal != 0 and !self.stuck) self.markStuck("un proceso no emitió su señal final en 15 s", GetLastError());
            _ = CloseHandle(process_handle);
        }
        _ = CloseHandle(handle);
        self.handle = null;
    }

    /// T9: SIGKILL a todo el grupo y espera, con el mismo tope, a que no quede
    /// ningun miembro vivo (los zombis ya no ejecutan; el padre los recoge).
    /// Si el grupo no se puede comprobar se marca `stuck`: nunca un exito falso.
    fn posixDeinit(self: *ProcessTree) void {
        const pgid = self.pgid;
        if (pgid <= 0) return;
        self.pgid = 0;
        if (builtin.os.tag != .linux) {
            _ = std.c.kill(-pgid, .KILL);
            self.markStuck("sin /proc no se puede confirmar el fin del grupo de procesos", 0);
            return;
        }
        var waited_ms: u32 = 0;
        while (true) {
            if (std.c.kill(-pgid, .KILL) != 0 and std.c._errno().* == @intFromEnum(std.posix.E.SRCH)) return;
            const live = posixLiveMembers(pgid) catch |e| {
                self.markStuck(@errorName(e), 0);
                return;
            };
            if (live == 0) return;
            if (waited_ms >= terminate_timeout_ms) {
                self.markStuck("quedan procesos activos del grupo tras 15 s de espera", live);
                return;
            }
            Sleep(10);
            waited_ms += 10;
        }
    }
};

/// Miembros del grupo que no son zombis, leyendo /proc/<pid>/stat (estado y
/// pgrp, campos 3 y 5; el nombre va entre parentesis y puede contener espacios).
fn posixLiveMembers(pgid: i32) !u32 {
    const dir = std.c.opendir("/proc") orelse return error.ProcUnavailable;
    defer _ = std.c.closedir(dir);
    var live: u32 = 0;
    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        const pid = std.fmt.parseInt(i32, name, 10) catch continue;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch continue;
        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) continue;
        defer _ = std.c.close(fd);
        var buf: [512]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) continue;
        const text = buf[0..@intCast(n)];
        const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
        const state = fields.next() orelse continue;
        _ = fields.next(); // ppid
        const group = std.fmt.parseInt(i32, fields.next() orelse continue, 10) catch continue;
        if (group == pgid and !std.mem.eql(u8, state, "Z") and !std.mem.eql(u8, state, "X")) live += 1;
    }
    return live;
}

fn posixExited(pid: i32) bool {
    if (builtin.os.tag != .linux) return std.c.kill(pid, @enumFromInt(0)) != 0;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return true;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return true;
    defer _ = std.c.close(fd);
    var buf: [512]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return true;
    const text = buf[0..@intCast(n)];
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return true;
    const rest = std.mem.trimStart(u8, text[close + 1 ..], " ");
    return rest.len == 0 or rest[0] == 'Z' or rest[0] == 'X';
}

extern "kernel32" fn OpenProcess(u32, c_int, u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn TerminateProcess(windows.HANDLE, u32) callconv(.winapi) c_int;

/// Test fixtures emit a PID only after their detached descendant is active.
/// Clean up a leaked fixture when the assertion fails, without touching data.
pub fn expectTestProcessStopped(pid: u32) !void {
    if (!builtin.is_test) @compileError("test helper is unavailable in production");
    if (builtin.os.tag != .windows) {
        if (!posixExited(@intCast(pid))) {
            _ = std.c.kill(@intCast(pid), .KILL);
            return error.TestUnexpectedResult;
        }
        return;
    }
    const handle = OpenProcess(0x100000 | 1, 0, pid) orelse {
        try std.testing.expectEqual(@as(u32, 87), GetLastError());
        return;
    };
    defer _ = CloseHandle(handle);
    const state = WaitForSingleObject(handle, 0);
    if (state == 258) {
        try std.testing.expect(TerminateProcess(handle, 1) != 0);
        try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(handle, 5000));
    }
    try std.testing.expectEqual(@as(u32, 0), state);
}
