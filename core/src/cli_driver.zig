const std = @import("std");
const db = @import("db.zig");
const planner = @import("planner.zig");
const superagent = @import("superagent.zig");
const live_planner = @import("llm_planner.zig");
const live_worker = @import("live_worker.zig");
const sandbox = @import("sandbox.zig");
const workspace = @import("workspace.zig");
const model_router = @import("model_router.zig");
const contracts = @import("contracts.zig");
const executor = @import("executor.zig");
const tool_discovery = @import("tool_discovery.zig");
const paths = @import("paths.zig");
const health = @import("health.zig");
const engram_memory = @import("engram_memory.zig");
const session_store = @import("session_store.zig");
const spaces = @import("spaces.zig");
const cli = @import("cli.zig");

// Win32 directo (no std.fs.cwd) para evitar access violation en host Qt/MSVC.
const windows = std.os.windows;
const FindFirstFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) windows.HANDLE;
}.FindFirstFileA else @import("providers").posix_files.FindFirstFileA;
const FindNextFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindNextFileA(hFindFile: windows.HANDLE, lpFindFileData: *WIN32_FIND_DATAA) c_int;
}.FindNextFileA else @import("providers").posix_files.FindNextFileA;
const FindClose = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindClose(hFindFile: windows.HANDLE) c_int;
}.FindClose else @import("providers").posix_files.FindClose;
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?windows.HANDLE,
    ) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: [*]u8, n: u32, read: *u32, ov: ?*anyopaque) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, n: u32, read: *u32, ov: ?*anyopaque) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const GetFileSizeEx = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileSizeEx(hFile: windows.HANDLE, lpFileSize: *i64) c_int;
}.GetFileSizeEx else @import("providers").posix_files.GetFileSizeEx;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const GetStdHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetStdHandle(nStdHandle: u32) windows.HANDLE;
}.GetStdHandle else @import("providers").posix_files.GetStdHandle;
const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) c_int;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;

const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));

const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u8,
    cAlternateFileName: [14]u8,
};

const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

// Buffer estático para capturar stdout en tests sin depender de std.io.
var g_test_buffer: [4096]u8 = undefined;
var g_test_len: usize = 0;
var g_test_active: bool = false;

// observa el Superagent de la ruta real antes de usar proveedores.
// La costura y sus entradas solo existen en el binario de pruebas.
pub const ExternalCatalogRouteTest = if (@import("builtin").is_test) struct {
    pub var observer: ?*const fn (*superagent.Superagent) anyerror!void = null;
    pub const order = CliDriver.cmdOrder;
    pub const approve = CliDriver.cmdApprove;
} else struct {};

/// Driver CLI-JSON universal (BACKLOG-IDE-REMOTE Fase 1).
/// Superficie agnóstica de IDE: cualquier agente/IDE externo puede pilotar
/// DevAgents ejecutando comandos y leyendo JSON de stdout.
pub const CliDriver = struct {
    pub fn run(allocator: std.mem.Allocator, args: [][]const u8) !void {
        if (args.len < 1) {
            try writeError("Usage: devagents driver <subcommand> [...]");
            return error.InvalidUsage;
        }

        const default_db = try paths.runtimeDb(allocator);
        defer allocator.free(default_db);
        const default_ledger = try paths.ledgerDb(allocator);
        defer allocator.free(default_ledger);

        var db_path: []const u8 = default_db;
        var ledger_path: []const u8 = default_ledger;
        var ws_root: []const u8 = workspace.WORKSPACE_ROOT;
        var origin: executor.Origin = .untrusted;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
                db_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--ledger") and i + 1 < args.len) {
                ledger_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--workspace") and i + 1 < args.len) {
                ws_root = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--origin") and i + 1 < args.len) {
                origin = parseOrigin(args[i + 1]);
                i += 1;
            } else {
                // Fin de flags; el resto es subcomando + argumentos.
                const sub_args = args[i..];
                if (sub_args.len == 0) {
                    try writeError("Missing subcommand");
                    return error.InvalidUsage;
                }
                return dispatch(allocator, sub_args, db_path, ledger_path, ws_root, origin);
            }
        }
        try writeError("Missing subcommand");
        return error.InvalidUsage;
    }

    fn parseOrigin(s: []const u8) executor.Origin {
        if (std.mem.eql(u8, s, "local")) return .local;
        return .untrusted;
    }

    fn dispatch(allocator: std.mem.Allocator, args: [][]const u8, db_path: []const u8, ledger_path: []const u8, ws_root: []const u8, origin: executor.Origin) !void {
        const cmd = args[0];
        if (std.mem.eql(u8, cmd, "status")) {
            const order_id = if (args.len > 1) try parseOrderId(args[1]) else null;
            return cmdStatus(allocator, db_path, order_id);
        } else if (std.mem.eql(u8, cmd, "plan")) {
            const order_id = if (args.len > 1) try parseOrderId(args[1]) else null;
            return cmdPlan(allocator, db_path, order_id);
        } else if (std.mem.eql(u8, cmd, "console")) {
            var since: i64 = 0;
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--since") and i + 1 < args.len) {
                    since = try std.fmt.parseInt(i64, args[i + 1], 10);
                    i += 1;
                }
            }
            return cmdConsole(allocator, db_path, since);
        } else if (std.mem.eql(u8, cmd, "artifacts")) {
            var order_id: ?i64 = null;
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--order") and i + 1 < args.len) {
                    order_id = try std.fmt.parseInt(i64, args[i + 1], 10);
                    i += 1;
                }
            }
            return cmdArtifacts(allocator, ws_root, order_id);
        } else if (std.mem.eql(u8, cmd, "cat")) {
            if (args.len < 2) {
                try writeError("Usage: devagents driver cat <relpath>");
                return error.InvalidUsage;
            }
            return cmdCat(allocator, ws_root, args[1]);
        } else if (std.mem.eql(u8, cmd, "health")) {
            // la superficie de maquina de la salud vive AQUI, que es donde
            // vive `--json` para todo lo demas. Antes `devagents health --json`
            // caia en el driver y respondia «Unknown driver subcommand», y el
            // JSON de verdad salia por stderr desde cli.zig — o sea, dos medias
            // superficies y ninguna usable.
            const modo_lista = args.len >= 2 and std.mem.eql(u8, args[1], "list");
            return cmdHealthJson(allocator, db_path, modo_lista);
        } else if (std.mem.eql(u8, cmd, "doctor")) {
            // Tanda 4: `devagents doctor --json`, el mismo JSON que `core.doctor`.
            var report = try @import("doctor.zig").runLocal(allocator);
            defer report.deinit();
            const j = try @import("doctor.zig").toJson(allocator, report);
            defer allocator.free(j);
            return writeStdout(j);
        } else if (std.mem.eql(u8, cmd, "approvals")) {
            return cmdApprovals(allocator, db_path);
        } else if (std.mem.eql(u8, cmd, "approve")) {
            if (args.len < 3) {
                try writeError("Usage: devagents driver approve <id> --yes|--no");
                return error.InvalidUsage;
            }
            const id = try std.fmt.parseInt(i64, args[1], 10);
            const approved = blk: {
                if (std.mem.eql(u8, args[2], "--yes")) break :blk true;
                if (std.mem.eql(u8, args[2], "--no")) break :blk false;
                try writeError("Expected --yes or --no");
                return error.InvalidUsage;
            };
            const cat = try paths.catalogDb(allocator);
            defer allocator.free(cat);
            return cmdApprove(allocator, db_path, cat, id, approved);
        } else if (std.mem.eql(u8, cmd, "order")) {
            if (args.len < 2) {
                try writeError("Usage: devagents driver order \"<texto>\"");
                return error.InvalidUsage;
            }
            return cmdOrder(allocator, db_path, args[1], origin);
        } else if (std.mem.eql(u8, cmd, "answer")) {
            if (args.len < 3) {
                try writeError("Usage: devagents driver answer <order_id> <json>");
                return error.InvalidUsage;
            }
            const order_id = try std.fmt.parseInt(i64, args[1], 10);
            return cmdAnswer(allocator, db_path, order_id, args[2]);
        } else if (std.mem.eql(u8, cmd, "log")) {
            var tail: usize = 50;
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--tail") and i + 1 < args.len) {
                    tail = try std.fmt.parseInt(usize, args[i + 1], 10);
                    i += 1;
                }
            }
            return cmdLog(allocator, ledger_path, tail);
        } else {
            try writeError("Unknown driver subcommand");
            return error.UnknownCommand;
        }
    }

    fn parseOrderId(s: []const u8) !i64 {
        return std.fmt.parseInt(i64, s, 10) catch {
            try writeError("Invalid order_id");
            return error.InvalidOrderId;
        };
    }

    fn openRuntime(allocator: std.mem.Allocator, db_path: []const u8) !db.Connection {
        var conn = try db.Connection.open(allocator, db_path);
        errdefer conn.close();
        const migrator = db.Migrator.init(allocator);
        try migrator.migrate(conn, &db.runtime_schema);
        return conn;
    }

    fn nowSeconds(conn: db.Connection) i64 {
        const stmt = conn.prepare("SELECT strftime('%s','now')") catch return 0;
        defer conn.finalize(stmt);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return 0;
        return db.c.sqlite3_column_int64(stmt, 0);
    }

    fn cmdStatus(allocator: std.mem.Allocator, db_path: []const u8, order_id: ?i64) !void {
        var runtime = try openRuntime(allocator, db_path);
        defer runtime.close();

        const sql = if (order_id) |_|
            "SELECT id, status, project_id, created_at FROM orders WHERE id = ?"
        else
            "SELECT id, status, project_id, created_at FROM orders ORDER BY id DESC LIMIT 1";
        const stmt = try runtime.prepare(sql);
        defer runtime.finalize(stmt);
        if (order_id) |id| try db.bindInt(stmt, 1, id);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) {
            try writeError("Order not found");
            return error.OrderNotFound;
        }
        const id = db.c.sqlite3_column_int64(stmt, 0);
        const status_ptr = db.c.sqlite3_column_text(stmt, 1);
        const status = status_ptr[0..std.mem.len(status_ptr)];
        const project_ptr = db.c.sqlite3_column_text(stmt, 2);
        const project = project_ptr[0..std.mem.len(project_ptr)];
        const created = db.c.sqlite3_column_int64(stmt, 3);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("order_id");
        try js.write(id);
        try js.objectField("status");
        try js.write(status);
        try js.objectField("project_id");
        try js.write(project);
        try js.objectField("created_at");
        try js.write(created);
        try js.endObject();
        try writeStdout(out.written());
    }

    fn cmdPlan(allocator: std.mem.Allocator, db_path: []const u8, order_id: ?i64) !void {
        var runtime = try openRuntime(allocator, db_path);
        defer runtime.close();

        const order_sql = if (order_id) |_|
            "SELECT id, status FROM orders WHERE id = ?"
        else
            "SELECT id, status FROM orders ORDER BY id DESC LIMIT 1";
        const order_stmt = try runtime.prepare(order_sql);
        defer runtime.finalize(order_stmt);
        if (order_id) |id| try db.bindInt(order_stmt, 1, id);
        if (db.c.sqlite3_step(order_stmt) != db.c.SQLITE_ROW) {
            try writeError("Order not found");
            return error.OrderNotFound;
        }
        const id = db.c.sqlite3_column_int64(order_stmt, 0);
        const status_ptr = db.c.sqlite3_column_text(order_stmt, 1);
        const status = status_ptr[0..std.mem.len(status_ptr)];

        const is_clarifying = std.mem.eql(u8, status, "clarifying");
        const plan_sql = if (is_clarifying)
            "SELECT clarifications_json FROM plans WHERE order_id = ? ORDER BY id DESC LIMIT 1"
        else
            "SELECT understanding FROM plans WHERE order_id = ? ORDER BY id DESC LIMIT 1";
        const plan_stmt = try runtime.prepare(plan_sql);
        defer runtime.finalize(plan_stmt);
        try db.bindInt(plan_stmt, 1, id);
        if (db.c.sqlite3_step(plan_stmt) != db.c.SQLITE_ROW) {
            if (is_clarifying) {
                // Sin plan aún: devolver questions vacío (el plan no se persiste en clarifying).
                try writeStdout("[]");
                return;
            }
            try writeError("Plan not found");
            return error.PlanNotFound;
        }
        const json_ptr = db.c.sqlite3_column_text(plan_stmt, 0);
        const json = json_ptr[0..std.mem.len(json_ptr)];

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("order_id");
        try js.write(id);
        try js.objectField("status");
        try js.write(status);
        if (is_clarifying) {
            // clarifications_json ya es JSON válido → embeber crudo manteniendo el
            // estado de la máquina (beginWriteRaw/endWriteRaw hacen valueStart/valueDone).
            try js.objectField("questions");
            try js.beginWriteRaw();
            try js.writer.writeAll(json);
            js.endWriteRaw();
        } else {
            // understanding es texto plano → emitir como string JSON (escapado).
            try js.objectField("plan");
            try js.write(json);
        }
        try js.endObject();
        try writeStdout(out.written());
    }

    fn cmdConsole(allocator: std.mem.Allocator, db_path: []const u8, since: i64) !void {
        var runtime = try openRuntime(allocator, db_path);
        defer runtime.close();

        const stmt = try runtime.prepare("SELECT id, source, payload_json FROM events WHERE kind = 'worker_output' AND id > ? ORDER BY id");
        defer runtime.finalize(stmt);
        try db.bindInt(stmt, 1, since);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginArray();
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const ev_id = db.c.sqlite3_column_int64(stmt, 0);
            const src_ptr = db.c.sqlite3_column_text(stmt, 1);
            const src = src_ptr[0..std.mem.len(src_ptr)];
            const payload_ptr = db.c.sqlite3_column_text(stmt, 2);
            const payload = payload_ptr[0..std.mem.len(payload_ptr)];
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch continue;
            defer parsed.deinit();
            const stream = if (parsed.value.object.get("stream")) |v| (if (v == .string) v.string else "") else "";
            const text = if (parsed.value.object.get("text")) |v| (if (v == .string) v.string else "") else "";
            const seq = if (parsed.value.object.get("seq")) |v| (if (v == .integer) v.integer else ev_id) else ev_id;

            try js.beginObject();
            try js.objectField("worker_id");
            try js.write(src);
            try js.objectField("stream");
            try js.write(stream);
            try js.objectField("text");
            try js.write(text);
            try js.objectField("seq");
            try js.write(seq);
            try js.endObject();
        }
        try js.endArray();
        try writeStdout(out.written());
    }

    fn cmdArtifacts(allocator: std.mem.Allocator, ws_root: []const u8, order_id: ?i64) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginArray();
        if (order_id) |id| {
            const dir = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_root, id });
            defer allocator.free(dir);
            listArtifactsDir(allocator, dir, id, &js) catch {};
        } else {
            listArtifactsDir(allocator, ws_root, null, &js) catch {};
        }
        try js.endArray();
        try writeStdout(out.written());
    }

    fn listArtifactsDir(allocator: std.mem.Allocator, dir: []const u8, order_id: ?i64, js: *std.json.Stringify) !void {
        const pattern = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "*", .{dir});
        defer allocator.free(pattern);
        const pattern_z = try allocator.dupeZ(u8, pattern);
        defer allocator.free(pattern_z);

        var data: WIN32_FIND_DATAA = undefined;
        const h = FindFirstFileA(pattern_z, &data);
        if (h == INVALID_HANDLE_VALUE) return;
        defer _ = FindClose(h);

        while (true) {
            var name_len: usize = 0;
            while (name_len < data.cFileName.len and data.cFileName[name_len] != 0) : (name_len += 1) {}
            const name_slice = data.cFileName[0..name_len];
            // Ignorar . y ..
            if (!std.mem.eql(u8, name_slice, ".") and !std.mem.eql(u8, name_slice, "..")) {
                // Ignorar directorios
                if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0) {
                    const size: i64 = (@as(i64, data.nFileSizeHigh) << 32) | @as(i64, data.nFileSizeLow);
                    try js.beginObject();
                    if (order_id) |oid| {
                        try js.objectField("order_id");
                        try js.write(oid);
                    }
                    try js.objectField("file");
                    try js.write(name_slice);
                    try js.objectField("bytes");
                    try js.write(size);
                    try js.endObject();
                }
            }
            if (FindNextFileA(h, &data) == 0) break;
        }
    }

    fn cmdCat(allocator: std.mem.Allocator, ws_root: []const u8, relpath: []const u8) !void {
        var sb = try sandbox.Sandbox.init(allocator, ws_root);
        defer sb.deinit();
        if (!sb.isAllowed(relpath)) {
            try writeError("Path outside workspace");
            return error.PathOutsideSandbox;
        }
        const full = try std.fs.path.resolve(allocator, &.{ ws_root, relpath });
        defer allocator.free(full);
        const full_z = try allocator.dupeZ(u8, full);
        defer allocator.free(full_z);

        const h = CreateFileA(full_z, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (h == INVALID_HANDLE_VALUE) {
            try writeError("FileNotFound");
            return error.FileNotFound;
        }
        defer _ = CloseHandle(h);

        var size: i64 = 0;
        if (GetFileSizeEx(h, &size) == 0) {
            try writeError("ReadError");
            return error.ReadError;
        }
        const cap: usize = @min(@as(usize, @intCast(size)), 1024 * 1024);
        const data = try allocator.alloc(u8, cap);
        defer allocator.free(data);
        var total_read: usize = 0;
        while (total_read < cap) {
            var chunk: u32 = 0;
            const to_read: u32 = @intCast(@min(cap - total_read, std.math.maxInt(u32)));
            if (ReadFile(h, data.ptr + total_read, to_read, &chunk, null) == 0) {
                try writeError("ReadError");
                return error.ReadError;
            }
            if (chunk == 0) break;
            total_read += chunk;
        }
        try writeStdout(data[0..total_read]);
    }

    /// salud en JSON por stdout, para quien la vaya a redirigir.
    fn cmdHealthJson(allocator: std.mem.Allocator, db_path: []const u8, modo_lista: bool) !void {
        var runtime = try openRuntime(allocator, db_path);
        defer runtime.close();
        const j = if (modo_lista)
            try health.listJson(allocator, runtime)
        else
            try health.summaryJson(allocator, runtime);
        defer allocator.free(j);
        try writeStdout(j);
    }

    fn cmdApprovals(allocator: std.mem.Allocator, db_path: []const u8) !void {
        var runtime = try openRuntime(allocator, db_path);
        defer runtime.close();

        const stmt = try runtime.prepare("SELECT id, task_id, description FROM approvals WHERE resolved = 0 ORDER BY id");
        defer runtime.finalize(stmt);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginArray();
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const id = db.c.sqlite3_column_int64(stmt, 0);
            const task_ptr = db.c.sqlite3_column_text(stmt, 1);
            const task = task_ptr[0..std.mem.len(task_ptr)];
            const desc_ptr = db.c.sqlite3_column_text(stmt, 2);
            const desc = desc_ptr[0..std.mem.len(desc_ptr)];
            try js.beginObject();
            try js.objectField("id");
            try js.write(id);
            try js.objectField("task_id");
            try js.write(task);
            try js.objectField("description");
            try js.write(desc);
            try js.endObject();
        }
        try js.endArray();
        try writeStdout(out.written());
    }

    fn cmdApprove(allocator: std.mem.Allocator, db_path: []const u8, catalog_path: []const u8, id: i64, approved: bool) !void {
        // This gate belongs before opening the DB: command descendants may
        // inspect approvals, but cannot act as the operator who resolves them.
        const env = struct {
            extern "kernel32" fn GetEnvironmentVariableA([*:0]const u8, [*]u8, u32) callconv(.winapi) u32;
            extern "kernel32" fn GetLastError() callconv(.winapi) u32;
            extern "kernel32" fn SetLastError(u32) callconv(.winapi) void;
        };
        var marker: [1]u8 = undefined;
        // T9: en POSIX basta con que la variable exista (getenv no falla de
        // otra forma); presente con cualquier valor = hijo de un comando.
        const is_child = if (@import("builtin").os.tag != .windows) std.c.getenv("DEVAGENTS_COMMAND_CHILD") != null else blk: {
            env.SetLastError(0);
            const marker_size = env.GetEnvironmentVariableA("DEVAGENTS_COMMAND_CHILD", &marker, marker.len);
            break :blk marker_size != 0 or env.GetLastError() != 203; // ERROR_ENVVAR_NOT_FOUND
        };
        if (is_child) {
            try writeError("driver approve: approval resolution denied to command child processes");
            return error.CommandChildApprovalDenied;
        }
        var runtime = try openRuntime(allocator, db_path);
        defer runtime.close();

        // (auditoría el segundo auditor, punto 2): solo resolver si seguía pendiente
        // (`resolved = 0`). Un segundo `approve` sobre una fila ya cerrada no
        // vuelve a despachar la orden.
        const upd = try runtime.prepare("UPDATE approvals SET approved = ?, resolved = 1 WHERE id = ? AND resolved = 0");
        defer runtime.finalize(upd);
        try db.bindInt(upd, 1, if (approved) 1 else 0);
        try db.bindInt(upd, 2, id);
        if (db.c.sqlite3_step(upd) != db.c.SQLITE_DONE) {
            try writeError("Failed to resolve approval");
            return error.ExecFailed;
        }
        if (db.c.sqlite3_changes(runtime.db) == 0) {
            // Distinguir "no existe" (error, como antes) de "ya resuelta" (no
            // re-despachar): la fila pudo cerrarla closeStaleApprovals.
            const chk = try runtime.prepare("SELECT 1 FROM approvals WHERE id = ?");
            defer runtime.finalize(chk);
            try db.bindInt(chk, 1, id);
            if (db.c.sqlite3_step(chk) != db.c.SQLITE_ROW) {
                try writeError("Approval not found");
                return error.ApprovalNotFound;
            }
            var out_ar: std.Io.Writer.Allocating = .init(allocator);
            defer out_ar.deinit();
            var js_ar: std.json.Stringify = .{ .writer = &out_ar.writer, .options = .{} };
            try js_ar.beginObject();
            try js_ar.objectField("approval_id");
            try js_ar.write(id);
            try js_ar.objectField("resolved");
            try js_ar.write(true);
            try js_ar.objectField("approved");
            try js_ar.write(approved);
            try js_ar.objectField("dispatched");
            try js_ar.write(false);
            try js_ar.objectField("note");
            try js_ar.write("already resolved");
            try js_ar.endObject();
            try writeStdout(out_ar.written());
            return;
        }

        var order_id: ?i64 = null;
        if (approved) {
            const sel = try runtime.prepare("SELECT task_id FROM approvals WHERE id = ?");
            defer runtime.finalize(sel);
            try db.bindInt(sel, 1, id);
            if (db.c.sqlite3_step(sel) == db.c.SQLITE_ROW) {
                const task_ptr = db.c.sqlite3_column_text(sel, 0);
                const task_id = task_ptr[0..std.mem.len(task_ptr)];
                if (std.mem.startsWith(u8, task_id, "order-")) {
                    order_id = std.fmt.parseInt(i64, task_id["order-".len..], 10) catch null;
                }
            }
        }

        const reported_order_id = order_id;
        if (order_id) |oid| {
            // (auditoría el segundo auditor, punto 2): una orden ya terminal no se
            // vuelve a despachar aunque la aprobación se resuelva ahora.
            if (orderIsTerminal(runtime, oid)) order_id = null;
        }

        var dispatched = false;
        var report: ?[]const u8 = null;
        errdefer if (report) |r| allocator.free(r);

        if (order_id) |oid| {
            var outcome = reconstructOutcomeFromDb(allocator, runtime, oid) catch |e| {
                try writeError(@errorName(e));
                var out_err: std.Io.Writer.Allocating = .init(allocator);
                defer out_err.deinit();
                var js_err: std.json.Stringify = .{ .writer = &out_err.writer, .options = .{} };
                try js_err.beginObject();
                try js_err.objectField("approval_id");
                try js_err.write(id);
                try js_err.objectField("resolved");
                try js_err.write(true);
                try js_err.objectField("approved");
                try js_err.write(true);
                try js_err.objectField("order_id");
                try js_err.write(oid);
                try js_err.objectField("dispatched");
                try js_err.write(false);
                try js_err.objectField("error");
                try js_err.write(@errorName(e));
                try js_err.endObject();
                try writeStdout(out_err.written());
                return;
            };
            defer outcome.deinit();

            const now = nowSeconds(runtime);
            var catalog: ?db.Connection = db.Connection.open(allocator, catalog_path) catch null;
            defer if (catalog) |*c| c.close();
            var router_storage: model_router.Router = undefined;
            var router_ptr: ?*model_router.Router = null;
            if (catalog) |cat| {
                if (catalogHasModels(cat)) {
                    router_storage = model_router.Router.init(allocator, cat, null, now);
                    router_storage.setHealthConn(runtime);
                    router_ptr = &router_storage;
                }
            }

            var mem_bundle = engram_memory.initFromEnv(allocator, runtime);
            defer mem_bundle.deinit();

            var sa = superagent.Superagent.init(allocator, runtime, router_ptr, mem_bundle.backend(), now);
            const external_catalog = cli.Cli.loadAndWireExternalCatalog(&sa, catalog, false);
            defer if (external_catalog) |json| allocator.free(json);
            if (@import("builtin").is_test) {
                if (ExternalCatalogRouteTest.observer) |observe| return observe(&sa);
            }
            var live_opt = live_worker.LiveLlm.init(allocator, catalog_path);
            if (live_opt) |*l| l.setHealthConn(runtime);
            defer if (live_opt) |*l| l.deinit();

            var dr = (if (live_opt) |*l|
                sa.approveAndDispatch(&outcome, live_worker.LiveLlm.llmFn, l, catalog_path)
            else
                sa.approveAndDispatch(&outcome, null, null, null)) catch |e| {
                try writeError(@errorName(e));
                var out_err: std.Io.Writer.Allocating = .init(allocator);
                defer out_err.deinit();
                var js_err: std.json.Stringify = .{ .writer = &out_err.writer, .options = .{} };
                try js_err.beginObject();
                try js_err.objectField("approval_id");
                try js_err.write(id);
                try js_err.objectField("resolved");
                try js_err.write(true);
                try js_err.objectField("approved");
                try js_err.write(true);
                try js_err.objectField("order_id");
                try js_err.write(oid);
                try js_err.objectField("dispatched");
                try js_err.write(false);
                try js_err.objectField("error");
                try js_err.write(@errorName(e));
                try js_err.endObject();
                try writeStdout(out_err.written());
                return;
            };
            defer dr.deinit(allocator);

            var seq: i64 = now;
            for (dr.outputs) |so| {
                seq += 1;
                insertWorkerOutputEvent(allocator, runtime, so.worker_id, so.stream, so.text, seq, so.task_id) catch {};
            }
            seq += 1;
            insertWorkerOutputEvent(allocator, runtime, "superagente", "reporte", dr.report, seq, "") catch {};

            dispatched = true;
            report = try allocator.dupe(u8, dr.report);
        }

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("approval_id");
        try js.write(id);
        try js.objectField("resolved");
        try js.write(true);
        try js.objectField("approved");
        try js.write(approved);
        if (reported_order_id) |oid| {
            try js.objectField("order_id");
            try js.write(oid);
        }
        try js.objectField("dispatched");
        try js.write(dispatched);
        if (report) |r| {
            try js.objectField("report");
            try js.write(r);
            allocator.free(r);
            report = null;
        }
        try js.endObject();
        try writeStdout(out.written());
    }

    /// true si la orden ya está en un estado terminal (no se debe
    /// re-despachar). Ante duda de lectura, false (no bloquear un despacho).
    fn orderIsTerminal(runtime: db.Connection, order_id: i64) bool {
        const stmt = runtime.prepare("SELECT status FROM orders WHERE id = ?") catch return false;
        defer runtime.finalize(stmt);
        db.bindInt(stmt, 1, order_id) catch return false;
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return false;
        const p = db.c.sqlite3_column_text(stmt, 0);
        if (p == null) return false;
        const status = p[0..std.mem.len(p)];
        return std.mem.eql(u8, status, "done") or std.mem.eql(u8, status, "failed") or
            std.mem.eql(u8, status, "rejected") or std.mem.eql(u8, status, "cancelled") or
            std.mem.eql(u8, status, "interrupted") or std.mem.eql(u8, status, "audit_unavailable");
    }

    fn insertWorkerOutputEvent(allocator: std.mem.Allocator, runtime: db.Connection, worker_id: []const u8, stream: []const u8, text: []const u8, seq: i64, task_id: []const u8) !void {
        var payload_out: std.Io.Writer.Allocating = .init(allocator);
        defer payload_out.deinit();
        var pjs: std.json.Stringify = .{ .writer = &payload_out.writer, .options = .{} };
        try pjs.beginObject();
        try pjs.objectField("stream");
        try pjs.write(stream);
        try pjs.objectField("text");
        try pjs.write(text);
        try pjs.objectField("seq");
        try pjs.write(seq);
        if (task_id.len > 0) {
            try pjs.objectField("task_id");
            try pjs.write(task_id);
        }
        try pjs.endObject();
        const payload = payload_out.written();
        const stmt = try runtime.prepare("INSERT INTO events (ts, source, kind, payload_json) VALUES (?, ?, 'worker_output', ?)");
        defer runtime.finalize(stmt);
        try db.bindInt(stmt, 1, seq);
        try db.bindText(stmt, 2, worker_id);
        try db.bindText(stmt, 3, payload);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    fn parseContractFields(allocator: std.mem.Allocator, json_str: []const u8) ![]planner.ContractField {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidJson;
        const arr = parsed.value.array.items;
        var fields = try allocator.alloc(planner.ContractField, arr.len);
        var initialized: usize = 0;
        errdefer {
            for (fields[0..initialized]) |f| {
                allocator.free(f.name);
                if (f.value) |value| allocator.free(value);
            }
            allocator.free(fields);
        }
        for (arr, 0..) |item, i| {
            if (item != .object) return error.InvalidJson;
            const obj = item.object;
            const name_v = obj.get("name") orelse return error.InvalidJson;
            const type_v = obj.get("type") orelse return error.InvalidJson;
            const req_v = obj.get("required") orelse return error.InvalidJson;
            if (name_v != .string or type_v != .string) return error.InvalidJson;
            const ft = std.meta.stringToEnum(contracts.FieldType, type_v.string) orelse return error.InvalidJson;
            const required = if (req_v == .bool) req_v.bool else false;
            const name = allocator.dupe(u8, name_v.string) catch |err| return err;
            const value: ?[]const u8 = if (obj.get("value")) |value_v| switch (value_v) {
                .string => allocator.dupe(u8, value_v.string) catch |err| {
                    allocator.free(name);
                    return err;
                },
                .null => null,
                else => {
                    allocator.free(name);
                    return error.InvalidJson;
                },
            } else null;
            fields[i] = .{
                .name = name,
                .field_type = ft,
                .required = required,
                .value = value,
            };
            initialized += 1;
        }
        return fields;
    }

    fn parseStringArray(allocator: std.mem.Allocator, json_str: []const u8) ![][]const u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidJson;
        const arr = parsed.value.array.items;
        var items = try allocator.alloc([]const u8, arr.len);
        errdefer {
            for (items) |s| allocator.free(s);
            allocator.free(items);
        }
        for (arr, 0..) |item, i| {
            if (item != .string) return error.InvalidJson;
            items[i] = try allocator.dupe(u8, item.string);
        }
        return items;
    }

    fn reconstructOutcomeFromDb(allocator: std.mem.Allocator, runtime: db.Connection, order_id: i64) !superagent.OrderOutcome {
        const plan_stmt = try runtime.prepare("SELECT id, understanding FROM plans WHERE order_id = ? ORDER BY id DESC LIMIT 1");
        defer runtime.finalize(plan_stmt);
        try db.bindInt(plan_stmt, 1, order_id);
        if (db.c.sqlite3_step(plan_stmt) != db.c.SQLITE_ROW) {
            return error.PlanNotFound;
        }
        const plan_id = db.c.sqlite3_column_int64(plan_stmt, 0);
        const understanding_ptr = db.c.sqlite3_column_text(plan_stmt, 1);
        const understanding = understanding_ptr[0..std.mem.len(understanding_ptr)];

        var tasks = std.ArrayList(planner.PlannedTask).empty;
        errdefer {
            for (tasks.items) |t| {
                allocator.free(t.id);
                allocator.free(t.department);
                allocator.free(t.description);
                for (t.contract_fields) |f| {
                    allocator.free(f.name);
                    if (f.value) |value| allocator.free(value);
                }
                allocator.free(t.contract_fields);
                for (t.depends_on) |d| allocator.free(d);
                allocator.free(t.depends_on);
            }
            tasks.deinit(allocator);
        }

        const task_sql =
            \\SELECT t.task_type, t.department, t.description,
            \\       c.name AS logical_id,
            \\       c.interface_spec AS fields_json,
            \\       c.consumers_json AS depends_json
            \\FROM tasks t JOIN contracts c ON t.contract_id = c.id
            \\WHERE t.plan_id = ? ORDER BY t.id
        ;
        const task_stmt = try runtime.prepare(task_sql);
        defer runtime.finalize(task_stmt);
        try db.bindInt(task_stmt, 1, plan_id);
        while (db.c.sqlite3_step(task_stmt) == db.c.SQLITE_ROW) {
            const tt_ptr = db.c.sqlite3_column_text(task_stmt, 0);
            const tt_str = tt_ptr[0..std.mem.len(tt_ptr)];
            const task_type = std.meta.stringToEnum(model_router.TaskType, tt_str) orelse return error.InvalidTaskType;
            const dept_ptr = db.c.sqlite3_column_text(task_stmt, 1);
            const department = dept_ptr[0..std.mem.len(dept_ptr)];
            const desc_ptr = db.c.sqlite3_column_text(task_stmt, 2);
            const description = desc_ptr[0..std.mem.len(desc_ptr)];
            const id_ptr = db.c.sqlite3_column_text(task_stmt, 3);
            const logical_id = id_ptr[0..std.mem.len(id_ptr)];
            const fields_ptr = db.c.sqlite3_column_text(task_stmt, 4);
            const fields_json = fields_ptr[0..std.mem.len(fields_ptr)];
            const deps_ptr = db.c.sqlite3_column_text(task_stmt, 5);
            const deps_json = deps_ptr[0..std.mem.len(deps_ptr)];

            const contract_fields = try parseContractFields(allocator, fields_json);
            errdefer {
                for (contract_fields) |f| {
                    allocator.free(f.name);
                    if (f.value) |value| allocator.free(value);
                }
                allocator.free(contract_fields);
            }
            const depends_on = try parseStringArray(allocator, deps_json);
            errdefer {
                for (depends_on) |d| allocator.free(d);
                allocator.free(depends_on);
            }

            try tasks.append(allocator, .{
                .id = try allocator.dupe(u8, logical_id),
                .task_type = task_type,
                .department = try allocator.dupe(u8, department),
                .description = try allocator.dupe(u8, description),
                .contract_fields = contract_fields,
                .depends_on = depends_on,
            });
        }

        var plan = planner.Plan{
            .allocator = allocator,
            .understanding = try allocator.dupe(u8, understanding),
            .questions = try allocator.alloc(planner.ClarificationQuestion, 0),
            .tasks = try tasks.toOwnedSlice(allocator),
        };
        errdefer plan.deinit();

        return superagent.OrderOutcome{
            .allocator = allocator,
            .order_id = order_id,
            .plan_id = plan_id,
            .status = .planned,
            .plan = plan,
            .assignments = try allocator.alloc(superagent.ModelAssignment, 0),
            .discovery_needed = try allocator.alloc([]const u8, 0),
            .discovery_missing = try allocator.alloc([]const u8, 0),
            .discovery_needed_resources = try allocator.alloc(tool_discovery.Resource, 0),
        };
    }

    fn cmdOrder(allocator: std.mem.Allocator, db_path: []const u8, text: []const u8, origin: executor.Origin) !void {
        // NOTA (FIX C / BUG-IDE-02): cmdOrder solo PLANIFICA (processOrder).
        // Los artefactos se persisten durante el DESPACHO (approveAndDispatch), que
        // ocurre tras aprobación (cmdApprove). Además, persistTask solo escribe
        // cuando llm_fn != null (modo live); en mock/tests sin red no hay artefactos.
        var runtime = try openRuntime(allocator, db_path);
        defer runtime.close();

        const now = nowSeconds(runtime);

        // Ruta canónica, no el literal "catalog.db": relativo al cwd abría una
        // base distinta de la de la cabina y el CLI se quedaba sin claves ni
        // modelos según desde dónde se lanzara.
        const catalog_path = try paths.catalogDb(allocator);
        defer allocator.free(catalog_path);

        var catalog: ?db.Connection = db.Connection.open(allocator, catalog_path) catch null;
        defer if (catalog) |*c| c.close();
        var router_storage: model_router.Router = undefined;
        var router_ptr: ?*model_router.Router = null;
        // Ver el comentario de la misma fuga en c_api.zig: el cache de
        // healthFactor solo se liberaba en los tests.
        defer if (router_ptr) |r| r.deinitHealthCache();
        if (catalog) |cat| {
            if (catalogHasModels(cat)) {
                router_storage = model_router.Router.init(allocator, cat, null, now);
                router_ptr = &router_storage;
            }
        }

        var lp = live_planner.LlmPlanner.init(allocator, catalog_path);
        const pb = lp.backend();
        defer pb.deinit();

        var mem_bundle = engram_memory.initFromEnv(allocator, runtime);
        defer mem_bundle.deinit();

        var sa = superagent.Superagent.init(allocator, runtime, router_ptr, mem_bundle.backend(), now);
        const external_catalog = cli.Cli.loadAndWireExternalCatalog(&sa, catalog, false);
        defer if (external_catalog) |json| allocator.free(json);
        sa.order_origin = origin;
        if (@import("builtin").is_test) {
            if (ExternalCatalogRouteTest.observer) |observe| return observe(&sa);
        }

        var outcome = sa.processOrder("driver", text, &.{}, pb, null, null) catch |e| {
            try writeError(@errorName(e));
            return e;
        };
        defer outcome.deinit();

        // Si la orden es untrusted y tiene plan con tareas, generar aprobación pendiente
        // en la tabla approvals (fuente única de verdad visible por GUI y driver).
        if (origin == .untrusted and outcome.status == .planned and outcome.plan.tasks.len > 0) {
            const desc = try std.fmt.allocPrint(allocator, "Ejecutar plan de orden #{d} (origen untrusted)", .{outcome.order_id});
            defer allocator.free(desc);
            insertPendingApproval(runtime, outcome.order_id, desc) catch {};
        }

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("order_id");
        try js.write(outcome.order_id);
        try js.objectField("status");
        try js.write(outcome.status.toText());
        try js.objectField("origin");
        try js.write(@tagName(origin));
        if (outcome.plan.needsClarification()) {
            try js.objectField("questions");
            try writeQuestions(&js, outcome.plan.questions);
        } else {
            try js.objectField("plan");
            try writePlan(&js, &outcome.plan);
        }
        try js.endObject();
        try writeStdout(out.written());
    }

    fn insertPendingApproval(runtime: db.Connection, order_id: i64, description: []const u8) !void {
        const stmt = try runtime.prepare("INSERT INTO approvals (task_id, description, approved, resolved, created_at) VALUES (?, ?, 0, 0, ?)");
        defer runtime.finalize(stmt);
        const task_id = try std.fmt.allocPrint(runtime.allocator, "order-{d}", .{order_id});
        defer runtime.allocator.free(task_id);
        try db.bindText(stmt, 1, task_id);
        try db.bindText(stmt, 2, description);
        // Cursor #2: created_at debe ser un timestamp, no el order_id (antes se enlazaba
        // order_id por error). El order_id ya queda preservado en task_id ("order-N").
        try db.bindInt(stmt, 3, nowSeconds(runtime));
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    fn cmdAnswer(allocator: std.mem.Allocator, db_path: []const u8, order_id: i64, answers_json: []const u8) !void {
        var runtime = try openRuntime(allocator, db_path);
        defer runtime.close();

        const now = nowSeconds(runtime);

        const order_stmt = try runtime.prepare("SELECT user_prompt, status FROM orders WHERE id = ?");
        defer runtime.finalize(order_stmt);
        try db.bindInt(order_stmt, 1, order_id);
        if (db.c.sqlite3_step(order_stmt) != db.c.SQLITE_ROW) {
            try writeError("Order not found");
            return error.OrderNotFound;
        }
        const text_ptr = db.c.sqlite3_column_text(order_stmt, 0);
        const text = text_ptr[0..std.mem.len(text_ptr)];
        const status_ptr = db.c.sqlite3_column_text(order_stmt, 1);
        const status = status_ptr[0..std.mem.len(status_ptr)];
        if (!std.mem.eql(u8, status, "clarifying")) {
            try writeError("Order is not in clarifying state");
            return error.InvalidState;
        }

        const answers = parseClarificationAnswers(allocator, answers_json) catch {
            try writeError("Invalid answers JSON");
            return error.InvalidJson;
        };
        defer {
            for (answers) |a| {
                allocator.free(a.question_id);
                allocator.free(a.answer);
            }
            allocator.free(answers);
        }

        const catalog_path2 = try paths.catalogDb(allocator);
        defer allocator.free(catalog_path2);
        var lp = live_planner.LlmPlanner.init(allocator, catalog_path2);
        const pb = lp.backend();
        defer pb.deinit();

        var mem_bundle = engram_memory.initFromEnv(allocator, runtime);
        defer mem_bundle.deinit();

        var sa = superagent.Superagent.init(allocator, runtime, null, mem_bundle.backend(), now);
        sa.order_origin = .untrusted;

        var outcome = sa.processOrder("driver", text, answers, pb, null, null) catch |e| {
            try writeError(@errorName(e));
            return e;
        };
        defer outcome.deinit();

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("order_id");
        try js.write(outcome.order_id);
        try js.objectField("status");
        try js.write(outcome.status.toText());
        if (outcome.plan.needsClarification()) {
            try js.objectField("questions");
            try writeQuestions(&js, outcome.plan.questions);
        } else {
            try js.objectField("plan");
            try writePlan(&js, &outcome.plan);
        }
        try js.endObject();
        try writeStdout(out.written());
    }

    fn cmdLog(allocator: std.mem.Allocator, ledger_path: []const u8, tail: usize) !void {
        var ledger = db.Connection.open(allocator, ledger_path) catch {
            try writeError("Cannot open ledger.db");
            return error.OpenFailed;
        };
        defer ledger.close();

        const stmt = try ledger.prepare("SELECT ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, notes FROM audit_ledger ORDER BY id DESC LIMIT ?");
        defer ledger.finalize(stmt);
        try db.bindInt(stmt, 1, @intCast(tail));

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginArray();
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const ts = db.c.sqlite3_column_int64(stmt, 0);
            const sk_ptr = db.c.sqlite3_column_text(stmt, 1);
            const sk = sk_ptr[0..std.mem.len(sk_ptr)];
            const sid = db.c.sqlite3_column_int64(stmt, 2);
            const action_ptr = db.c.sqlite3_column_text(stmt, 3);
            const action = action_ptr[0..std.mem.len(action_ptr)];
            const verdict_ptr = db.c.sqlite3_column_text(stmt, 4);
            const verdict = verdict_ptr[0..std.mem.len(verdict_ptr)];
            const model_ptr = db.c.sqlite3_column_text(stmt, 5);
            const model = model_ptr[0..std.mem.len(model_ptr)];
            const provider_ptr = db.c.sqlite3_column_text(stmt, 6);
            const provider = provider_ptr[0..std.mem.len(provider_ptr)];
            const ev_ptr = db.c.sqlite3_column_text(stmt, 7);
            const ev = ev_ptr[0..std.mem.len(ev_ptr)];
            const notes_ptr = db.c.sqlite3_column_text(stmt, 8);
            const notes = if (notes_ptr) |p| p[0..std.mem.len(p)] else "";

            try js.beginObject();
            try js.objectField("ts");
            try js.write(ts);
            try js.objectField("subject_kind");
            try js.write(sk);
            try js.objectField("subject_id");
            try js.write(sid);
            try js.objectField("action");
            try js.write(action);
            try js.objectField("verdict");
            try js.write(verdict);
            try js.objectField("model_id");
            try js.write(model);
            try js.objectField("provider");
            try js.write(provider);
            try js.objectField("evidence_ref");
            try js.write(ev);
            try js.objectField("notes");
            try js.write(notes);
            try js.endObject();
        }
        try js.endArray();
        try writeStdout(out.written());
    }

    fn catalogHasModels(cat: db.Connection) bool {
        const stmt = cat.prepare("SELECT COUNT(*) FROM models WHERE available = 1") catch return false;
        defer cat.finalize(stmt);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return false;
        return db.c.sqlite3_column_int(stmt, 0) > 0;
    }

    fn writeQuestions(js: *std.json.Stringify, questions: []const planner.ClarificationQuestion) !void {
        try js.beginArray();
        for (questions) |q| {
            try js.beginObject();
            try js.objectField("id");
            try js.write(q.id);
            try js.objectField("text");
            try js.write(q.text);
            try js.objectField("options");
            try js.beginArray();
            for (q.options) |o| try js.write(o);
            try js.endArray();
            try js.endObject();
        }
        try js.endArray();
    }

    fn writePlan(js: *std.json.Stringify, plan: *const planner.Plan) !void {
        try js.beginObject();
        try js.objectField("understanding");
        try js.write(plan.understanding);
        try js.objectField("tasks");
        try js.beginArray();
        for (plan.tasks) |t| {
            try js.beginObject();
            try js.objectField("id");
            try js.write(t.id);
            try js.objectField("task_type");
            try js.write(t.task_type.toText());
            try js.objectField("department");
            try js.write(t.department);
            try js.objectField("description");
            try js.write(t.description);
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }

    fn parseClarificationAnswers(allocator: std.mem.Allocator, json_str: []const u8) ![]planner.ClarificationAnswer {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidJson;
        var list = std.ArrayList(planner.ClarificationAnswer).empty;
        errdefer {
            for (list.items) |a| {
                allocator.free(a.question_id);
                allocator.free(a.answer);
            }
            list.deinit(allocator);
        }
        for (parsed.value.array.items) |item| {
            if (item != .object) return error.InvalidJson;
            const obj = item.object;
            const qid = (obj.get("question_id") orelse return error.InvalidJson);
            const ans = (obj.get("answer") orelse return error.InvalidJson);
            if (qid != .string or ans != .string) return error.InvalidJson;
            try list.append(allocator, .{
                .question_id = try allocator.dupe(u8, qid.string),
                .answer = try allocator.dupe(u8, ans.string),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    fn writeError(msg: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch {};
        js.objectField("error") catch {};
        js.write(msg) catch {};
        js.endObject() catch {};
        try writeStdOutRaw(out.written());
    }

    fn writeStdout(data: []const u8) !void {
        try writeStdOutRaw(data);
    }

    fn writeStdOutRaw(data: []const u8) !void {
        if (g_test_active) {
            const to_copy = @min(data.len, g_test_buffer.len - g_test_len);
            @memcpy(g_test_buffer[g_test_len .. g_test_len + to_copy], data[0..to_copy]);
            g_test_len += to_copy;
            if (g_test_len < g_test_buffer.len) {
                g_test_buffer[g_test_len] = '\n';
                g_test_len += 1;
            }
            return;
        }
        const h = GetStdHandle(STD_OUTPUT_HANDLE);
        if (h == INVALID_HANDLE_VALUE) return error.WriteError;
        var written: u32 = 0;
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk: u32 = @intCast(@min(data.len - offset, std.math.maxInt(u32)));
            if (WriteFile(h, data.ptr + offset, chunk, &written, null) == 0) return error.WriteError;
            offset += written;
        }
        const nl = "\n";
        _ = WriteFile(h, nl.ptr, 1, &written, null);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "driver contract parser preserves value strings and null" {
    const allocator = std.testing.allocator;
    const fields = try CliDriver.parseContractFields(
        allocator,
        "[{\"name\":\"command\",\"type\":\"string\",\"required\":true,\"value\":\"echo hi\"},{\"name\":\"note\",\"type\":\"string\",\"required\":false,\"value\":null}]",
    );
    defer {
        for (fields) |field| {
            allocator.free(field.name);
            if (field.value) |value| allocator.free(value);
        }
        allocator.free(fields);
    }
    try std.testing.expectEqualStrings("command", fields[0].name);
    try std.testing.expectEqualStrings("echo hi", fields[0].value.?);
    try std.testing.expect(fields[1].value == null);
}

test "driver contract parser cleans initialized fields after malformed later item" {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer {
        const status = debug_allocator.deinit();
        std.testing.expect(status == .ok) catch @panic("contract parser leaked partial fields");
    }
    try std.testing.expectError(error.InvalidJson, CliDriver.parseContractFields(
        debug_allocator.allocator(),
        "[{\"name\":\"command\",\"type\":\"string\",\"required\":true,\"value\":\"echo hi\"},{\"name\":\"broken\",\"type\":7,\"required\":true}]",
    ));
}

test "driver order produces JSON and marks origin untrusted" {
    const allocator = std.testing.allocator;
    var runtime = try db.Connection.open(allocator, ":memory:");
    defer runtime.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(runtime, &db.runtime_schema);

    var mp = planner.MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    var sa = superagent.Superagent.init(allocator, runtime, null, superagent.NoopMemory.backend(), 1);
    sa.order_origin = .untrusted;
    var outcome = try sa.processOrder("driver", "construye una calculadora CLI en C con tests", &.{}, pb, null, null);
    defer outcome.deinit();

    try std.testing.expectEqual(superagent.OrderStatus.planned, outcome.status);
    try std.testing.expectEqual(executor.Origin.untrusted, sa.order_origin);
}

test "driver cat rejects path outside workspace" {
    var sb = try sandbox.Sandbox.init(std.testing.allocator, "devagents-workspace");
    defer sb.deinit();
    try std.testing.expect(!sb.isAllowed("..\\secret.txt"));
    try std.testing.expect(!sb.isAllowed("C:\\Windows\\evil.dll"));
}

test "driver approval persists across connections on file db" {
    const allocator = std.testing.allocator;
    const db_path = "test-driver-persist.db";
    _ = DeleteFileA("test-driver-persist.db");
    defer _ = DeleteFileA("test-driver-persist.db");

    // g_test_active DEBE permanecer activo durante TODAS las llamadas a cmd* del
    // driver: bajo `zig build test`, el stdout del proceso de test es el canal IPC
    // del test-runner de Zig; un WriteFile de bytes crudos (writeStdOutRaw con
    // g_test_active=false) corrompe ese protocolo y CUELGA el build. Capturamos a
    // buffer en su lugar; el parseo lee el buffer y no escribe a stdout.
    g_test_active = true;
    defer g_test_active = false;

    // Conexión 1: crear aprobación y cerrar.
    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const migrator = db.Migrator.init(allocator);
        try migrator.migrate(runtime, &db.runtime_schema);
        try CliDriver.insertPendingApproval(runtime, 42, "Test approval");
    }

    // Conexión 2: leer pendientes vía cmdApprovals (abre su propia conexión).
    g_test_len = 0;
    try CliDriver.cmdApprovals(allocator, db_path);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, g_test_buffer[0..g_test_len], .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expect(parsed.value.array.items.len == 1);
        const first = parsed.value.array.items[0];
        try std.testing.expect(first == .object);
        try std.testing.expectEqualStrings("order-42", first.object.get("task_id").?.string);
        try std.testing.expectEqualStrings("Test approval", first.object.get("description").?.string);
    }

    // Conexión 3: resolver vía cmdApprove (abre su propia conexión).
    // catalog ":memory:" → aislado: jamás toca el catalog.db real del proyecto.
    g_test_len = 0;
    try CliDriver.cmdApprove(allocator, db_path, ":memory:", 1, true);

    // Conexión 4: verificar que ya no está pendiente.
    g_test_len = 0;
    try CliDriver.cmdApprovals(allocator, db_path);
    try std.testing.expectEqualStrings("[]", std.mem.trim(u8, g_test_buffer[0..g_test_len], " \n\r"));
}

test "CK-SEG-020 driver approve child denied without resolving and legitimate operator succeeds" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    const env = struct {
        extern "kernel32" fn SetEnvironmentVariableA([*:0]const u8, ?[*:0]const u8) callconv(.winapi) c_int;
        extern "kernel32" fn GetEnvironmentVariableA([*:0]const u8, [*]u8, u32) callconv(.winapi) u32;
    };
    var saved: [4096:0]u8 = undefined;
    const count = env.GetEnvironmentVariableA("DEVAGENTS_COMMAND_CHILD", &saved, saved.len);
    try std.testing.expect(count < saved.len);
    saved[count] = 0;
    defer _ = env.SetEnvironmentVariableA("DEVAGENTS_COMMAND_CHILD", if (count == 0) null else saved[0..count :0]);
    const path = "test-seg020-approval.db";
    _ = DeleteFileA(path);
    defer _ = DeleteFileA(path);
    var runtime = try db.Connection.open(a, path);
    defer runtime.close();
    try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);
    try CliDriver.insertPendingApproval(runtime, 42, "isolated approval");
    g_test_active = true;
    defer g_test_active = false;
    for ([_][*:0]const u8{ "1", "0" }) |value| {
        try std.testing.expect(env.SetEnvironmentVariableA("DEVAGENTS_COMMAND_CHILD", value) != 0);
        try std.testing.expectError(error.CommandChildApprovalDenied, CliDriver.cmdApprove(a, path, ":memory:", 1, true));
        const row = try runtime.prepare("SELECT resolved FROM approvals WHERE id=1");
        defer runtime.finalize(row);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(row));
        try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(row, 0));
    }
    try std.testing.expect(env.SetEnvironmentVariableA("DEVAGENTS_COMMAND_CHILD", null) != 0);
    try CliDriver.cmdApprove(a, path, ":memory:", 1, false);
    const row = try runtime.prepare("SELECT resolved, approved FROM approvals WHERE id=1");
    defer runtime.finalize(row);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(row));
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(row, 0));
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(row, 1));
}

test "driver JSON output has expected fields" {
    const allocator = std.testing.allocator;
    const db_path = "test-driver-json.db";
    _ = DeleteFileA("test-driver-json.db");

    var order_id: i64 = 0;
    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const migrator = db.Migrator.init(allocator);
        try migrator.migrate(runtime, &db.runtime_schema);

        var mp = planner.MockPlanner.init(allocator);
        const pb = mp.backend();
        defer pb.deinit();

        var sa = superagent.Superagent.init(allocator, runtime, null, superagent.NoopMemory.backend(), 1);
        var outcome = try sa.processOrder("driver", "construye una calculadora CLI en C con tests", &.{}, pb, null, null);
        defer outcome.deinit();
        order_id = outcome.order_id;

        // Insertar un evento worker_output para que cmdConsole tenga datos.
        // events.ts es NOT NULL → debe incluirse o el INSERT falla en silencio.
        const ev_stmt = try runtime.prepare("INSERT INTO events (ts, kind, source, payload_json) VALUES (1000, 'worker_output', 'test', '{\"stream\":\"stdout\",\"text\":\"hello\"}')");
        defer runtime.finalize(ev_stmt);
        if (db.c.sqlite3_step(ev_stmt) != db.c.SQLITE_DONE) return error.EventInsertFailed;
    }

    // Probar comandos del driver (cada uno abre su propia conexión al mismo archivo)
    g_test_active = true;

    // status JSON
    g_test_len = 0;
    try CliDriver.cmdStatus(allocator, db_path, order_id);
    g_test_active = false;
    {
        const json_str = g_test_buffer[0..g_test_len];
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        try std.testing.expect(parsed.value.object.get("order_id") != null);
        try std.testing.expect(parsed.value.object.get("status") != null);
        try std.testing.expect(parsed.value.object.get("project_id") != null);
        try std.testing.expect(parsed.value.object.get("created_at") != null);
    }

    // plan JSON
    g_test_active = true;
    g_test_len = 0;
    try CliDriver.cmdPlan(allocator, db_path, order_id);
    g_test_active = false;
    {
        const json_str = g_test_buffer[0..g_test_len];
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        try std.testing.expect(parsed.value.object.get("order_id") != null);
        try std.testing.expect(parsed.value.object.get("status") != null);
    }

    // approvals JSON (vacío)
    g_test_active = true;
    g_test_len = 0;
    try CliDriver.cmdApprovals(allocator, db_path);
    g_test_active = false;
    {
        const json_str = g_test_buffer[0..g_test_len];
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
    }

    // console JSON
    g_test_active = true;
    g_test_len = 0;
    try CliDriver.cmdConsole(allocator, db_path, 0);
    g_test_active = false;
    {
        const json_str = g_test_buffer[0..g_test_len];
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expect(parsed.value.array.items.len == 1);
    }

    _ = DeleteFileA("test-driver-json.db");
}

test "driver untrusted order creates pending approval" {
    const allocator = std.testing.allocator;
    const db_path = "test-driver-untrusted.db";
    _ = DeleteFileA("test-driver-untrusted.db");

    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const migrator = db.Migrator.init(allocator);
        try migrator.migrate(runtime, &db.runtime_schema);

        var mp = planner.MockPlanner.init(allocator);
        const pb = mp.backend();
        defer pb.deinit();

        var sa = superagent.Superagent.init(allocator, runtime, null, superagent.NoopMemory.backend(), 1);
        sa.order_origin = .untrusted;
        var outcome = try sa.processOrder("driver", "construye una calculadora CLI en C con tests", &.{}, pb, null, null);
        defer outcome.deinit();

        try std.testing.expectEqual(superagent.OrderStatus.planned, outcome.status);
        try std.testing.expect(outcome.plan.tasks.len > 0);

        try CliDriver.insertPendingApproval(runtime, outcome.order_id, "Test pending");
    }

    // Verificar persistencia en nueva conexión
    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const stmt = try runtime.prepare("SELECT count(*) FROM approvals WHERE resolved = 0");
        defer runtime.finalize(stmt);
        _ = db.c.sqlite3_step(stmt);
        const count = db.c.sqlite3_column_int64(stmt, 0);
        try std.testing.expectEqual(@as(i64, 1), count);
    }

    _ = DeleteFileA("test-driver-untrusted.db");
}

test "driver insertPendingApproval graba created_at como timestamp, no el order_id (Cursor #2)" {
    const allocator = std.testing.allocator;
    var runtime = try db.Connection.open(allocator, ":memory:");
    defer runtime.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(runtime, &db.runtime_schema);

    try CliDriver.insertPendingApproval(runtime, 7, "x");
    const stmt = try runtime.prepare("SELECT created_at FROM approvals WHERE task_id = 'order-7'");
    defer runtime.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    const created_at = db.c.sqlite3_column_int64(stmt, 0);
    // Debe ser epoch reciente (> 2020-01-01 = 1577836800), jamás el order_id (7).
    try std.testing.expect(created_at > 1577836800);
}

test "driver cat blocks escaped paths and absolute paths" {
    // Evitar que writeError/writeStdout usen Win32 durante tests
    g_test_active = true;
    g_test_len = 0;
    try std.testing.expectError(error.PathOutsideSandbox, CliDriver.cmdCat(std.testing.allocator, "devagents-workspace", "..\\secret.txt"));
    g_test_len = 0;
    try std.testing.expectError(error.PathOutsideSandbox, CliDriver.cmdCat(std.testing.allocator, "devagents-workspace", "C:\\Windows\\system32\\notepad.exe"));
    g_test_len = 0;
    try std.testing.expectError(error.PathOutsideSandbox, CliDriver.cmdCat(std.testing.allocator, "devagents-workspace", "/etc/passwd"));
    g_test_active = false;
}

test "driver approve reconstructs OrderOutcome and dispatches (Cursor #1)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const db_path = try std.fs.path.join(allocator, &.{ root, "runtime.db" });
    defer allocator.free(db_path);
    const catalog_path = try std.fs.path.join(allocator, &.{ root, "catalog.db" });
    defer allocator.free(catalog_path);
    {
        // cmdApprove opens its own connection and reads project rules from settings.
        var catalog = try db.Connection.open(allocator, catalog_path);
        defer catalog.close();
        try db.Migrator.init(allocator).migrate(catalog, &db.catalog_schema);
    }

    var order_id: i64 = 0;
    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const migrator = db.Migrator.init(allocator);
        try migrator.migrate(runtime, &db.runtime_schema);

        var mp = planner.MockPlanner.init(allocator);
        const pb = mp.backend();
        defer pb.deinit();

        var sa = superagent.Superagent.init(allocator, runtime, null, superagent.NoopMemory.backend(), 1);
        sa.order_origin = .untrusted;
        // Esta fixture verifica reconstrucción y despacho; QA ejecutable tiene sus propias pruebas.
        var outcome = try sa.processOrder("driver", "construye una calculadora CLI en C", &.{}, pb, null, null);
        defer outcome.deinit();
        order_id = outcome.order_id;

        try CliDriver.insertPendingApproval(runtime, outcome.order_id, "Test pending");
    }

    // Llamar cmdApprove sobre la orden planificada (cross-proceso: nueva conexión).
    g_test_active = true;
    defer g_test_active = false;
    g_test_len = 0;
    try CliDriver.cmdApprove(allocator, db_path, catalog_path, 1, true);

    // (a) Verificar JSON de salida: dispatched=true.
    {
        const json_str = g_test_buffer[0..g_test_len];
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const dispatched = parsed.value.object.get("dispatched") orelse return error.MissingField;
        try std.testing.expect(dispatched == .bool and dispatched.bool == true);
        const approved = parsed.value.object.get("approved") orelse return error.MissingField;
        try std.testing.expect(approved == .bool and approved.bool == true);
        const resolved = parsed.value.object.get("resolved") orelse return error.MissingField;
        try std.testing.expect(resolved == .bool and resolved.bool == true);
    }

    // (b) Verificar el estado terminal. AUDIT-UNAVAILABLE-P0: el catálogo
    // temporal no tiene proveedor con clave → la auditoría corre por el
    // MockWorker, cuyo verdict="mock-value" no es un veredicto — la orden
    // cierra 'audit_unavailable' (productor conservado, entrega bloqueada).
    // Este test verifica reconstrucción + despacho; la vía done con veredicto
    // real la cubren los tests C-API con la costura test_llm_fn.
    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const stmt = try runtime.prepare("SELECT status FROM orders WHERE id = ?");
        defer runtime.finalize(stmt);
        try db.bindInt(stmt, 1, order_id);
        try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
        const status_ptr = db.c.sqlite3_column_text(stmt, 0);
        const status = status_ptr[0..std.mem.len(status_ptr)];
        try std.testing.expectEqualStrings("audit_unavailable", status);
    }

    // (c) Verificar que se insertaron eventos worker_output.
    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const stmt = try runtime.prepare("SELECT count(*) FROM events WHERE kind = 'worker_output'");
        defer runtime.finalize(stmt);
        try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
        const count = db.c.sqlite3_column_int64(stmt, 0);
        try std.testing.expect(count >= 1); // al menos el reporte del superagente
    }
}

test "driver approve rejected does not dispatch (Cursor #1)" {
    const allocator = std.testing.allocator;
    const db_path = "test-driver-approve-reject.db";
    _ = DeleteFileA(db_path);
    defer _ = DeleteFileA(db_path);

    // Catálogo aislado en ":memory:" (HERMÉTICO; ver test de dispatch). Jamás toca
    // el catalog.db real del proyecto.
    const catalog_path = ":memory:";

    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const migrator = db.Migrator.init(allocator);
        try migrator.migrate(runtime, &db.runtime_schema);

        var mp = planner.MockPlanner.init(allocator);
        const pb = mp.backend();
        defer pb.deinit();

        var sa = superagent.Superagent.init(allocator, runtime, null, superagent.NoopMemory.backend(), 1);
        sa.order_origin = .untrusted;
        var outcome = try sa.processOrder("driver", "construye una calculadora CLI en C con tests", &.{}, pb, null, null);
        defer outcome.deinit();

        try CliDriver.insertPendingApproval(runtime, outcome.order_id, "Test pending");
    }

    g_test_active = true;
    defer g_test_active = false;
    g_test_len = 0;
    try CliDriver.cmdApprove(allocator, db_path, catalog_path, 1, false);

    // Verificar JSON: dispatched=false.
    {
        const json_str = g_test_buffer[0..g_test_len];
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const dispatched = parsed.value.object.get("dispatched") orelse return error.MissingField;
        try std.testing.expect(dispatched == .bool and dispatched.bool == false);
    }

    // Verificar que NO se insertaron eventos worker_output nuevos.
    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const stmt = try runtime.prepare("SELECT count(*) FROM events WHERE kind = 'worker_output'");
        defer runtime.finalize(stmt);
        try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
        const count = db.c.sqlite3_column_int64(stmt, 0);
        try std.testing.expectEqual(@as(i64, 0), count);
    }
}

fn cab011CountOrdersWithProject(conn: db.Connection, project: []const u8) !i64 {
    const stmt = try conn.prepare("SELECT COUNT(*) FROM orders WHERE project_id = ?");
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, project);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.NoRow;
    return db.c.sqlite3_column_int64(stmt, 0);
}

// (auditoria del segundo auditor: falta integracion en el MOTOR). El arreglo vive
// en la WebUI (mission_control.ts:2395 envia la orden de compactacion con el
// proyecto interno "__compact"), pero su correccion depende de una ruta del
// motor que hasta ahora solo se probaba con un CoreApi simulado. Esta prueba la
// recorre de verdad, sin red, con el MockPlanner determinista del motor:
//
//   mission_control.ts:2395 submitOrder(prompt, '__compact', '')
//     -> bridge core_api.ts:713 'core.order.submit'
//     -> da_order_submit            [core/src/c_api.zig:2499]
//     -> sup.processOrder           [core/src/c_api.zig:2574]
//     -> Superagent.processOrder    [core/src/superagent.zig:895]
//     -> insertOrderRow             [core/src/superagent.zig:7291]  (persiste project_id)
//   y la ocultacion en el historial:
//     listSessions (SQLite)         [core/src/session_store.zig:169]
//     lista en memoria              [core/src/c_api.zig:6611]
//
// El tramo da_order_submit/da_sessions_json vive en c_api.zig, que este encargo
// prohibe editar; se ejerce el MISMO processOrder y el MISMO listSessions y se
// deja anotado en el informe lo que no queda cubierto (el C-ABI y la lista viva).
test "CK-CAB-011: la orden interna __compact se procesa como 'default' por el motor y no entra en el historial del usuario" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    try db.Migrator.init(allocator).migrate(conn, &db.runtime_schema);

    var mp = planner.MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    var sa = superagent.Superagent.init(allocator, conn, null, superagent.NoopMemory.backend(), 1);

    // Prompt literal de la orden interna (mission_control.ts:2377-2395).
    const compact_prompt =
        "Resume la siguiente conversacion en un parrafo denso que conserve las " ++
        "decisiones tomadas, los archivos mencionados y lo que queda pendiente. " ++
        "Sin preambulo.\n\nusuario: crea una calculadora\nagente: hecha";

    // (1) Mismo texto por la misma ruta: 'default' y el proyecto interno "__compact".
    var user_outcome = try sa.processOrder("default", compact_prompt, &.{}, pb, null, null);
    defer user_outcome.deinit();
    var compact_outcome = try sa.processOrder(session_store.INTERNAL_PROJECT_PREFIX ++ "compact", compact_prompt, &.{}, pb, null, null);
    defer compact_outcome.deinit();

    // Ambas se ACEPTAN (sin error) y quedan en el MISMO estado: la unica
    // diferencia es el project_id, no el procesamiento.
    try std.testing.expect(user_outcome.order_id > 0 and compact_outcome.order_id > 0);
    try std.testing.expect(user_outcome.order_id != compact_outcome.order_id);
    try std.testing.expectEqual(user_outcome.status, compact_outcome.status);

    // El project_id llega intacto a la fila persistida de cada orden.
    try std.testing.expectEqual(@as(i64, 1), try cab011CountOrdersWithProject(conn, "default"));
    try std.testing.expectEqual(@as(i64, 1), try cab011CountOrdersWithProject(conn, "__compact"));

    // (2) Historial persistido (session_store.listSessions): la orden del usuario
    // aparece; la interna "__compact" queda oculta por el prefijo reservado.
    const store = try session_store.createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);
    const sessions = try store.listSessionsFn(allocator);
    defer {
        for (sessions) |s| {
            allocator.free(s.title);
            allocator.free(s.status);
            allocator.free(s.conversation_id);
        }
        allocator.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqual(user_outcome.order_id, sessions[0].id);

    // (3) Lo que depende del proyecto no se rompe: planificar (no despachar) no
    // crea ningun space, y el project_id "__compact" no abre ninguna ruta.
    try std.testing.expectEqual(@as(i64, 0), try cab011CountRows(conn, "SELECT COUNT(*) FROM spaces"));
}

fn cab011CountRows(conn: db.Connection, sql: []const u8) !i64 {
    const stmt = try conn.prepare(sql);
    defer conn.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.NoRow;
    return db.c.sqlite3_column_int64(stmt, 0);
}

//, parte 3: el aislamiento de una orden crea el directorio a partir
// del NOMBRE del space (`orden-<id>`, c_api.zig:8453), no del project_id; el
// project_id solo va como columna de `spaces` (spaces.zig:479). Se comprueba la
// misma llamada que hace el motor (ensureOrderSpace, c_api.zig:8455 ->
// spaces.createSpace, spaces.zig:363) con el project_id interno "__compact": la
// ruta creada es <base>\.devagents\spaces\orden-77, jamas <base>\.devagents\spaces\__compact.
test "CK-CAB-011: el project_id __compact no crea ninguna carpeta ni space a su nombre" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    try db.Migrator.init(allocator).migrate(conn, &db.runtime_schema);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(base);

    var sp = try spaces.createSpace(allocator, conn, "__compact", "orden-77", .order, base, .{});
    defer sp.deinit(allocator);

    // El project_id interno se guarda tal cual en la columna...
    try std.testing.expectEqualStrings("__compact", sp.project_id);
    // ...pero la ruta es la del NOMBRE del space, sin rastro del project_id.
    const expected = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-77", .{base});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, sp.worktree_path);
    try std.testing.expect(std.mem.indexOf(u8, sp.worktree_path, "__compact") == null);

    const created = sandbox.canonicalizeExisting(allocator, sp.worktree_path);
    defer if (created) |path| allocator.free(path);
    try std.testing.expect(created != null);

    const named_after_project = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "__compact", .{base});
    defer allocator.free(named_after_project);
    const unexpected = sandbox.canonicalizeExisting(allocator, named_after_project);
    defer if (unexpected) |path| allocator.free(path);
    try std.testing.expect(unexpected == null);
}

test "driver approve no despacha una orden terminal ni una fila ya resuelta (CK-CAB-019)" {
    const allocator = std.testing.allocator;
    const db_path = "test-driver-approve-terminal.db";
    _ = DeleteFileA(db_path);
    defer _ = DeleteFileA(db_path);
    const catalog_path = ":memory:";

    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const migrator = db.Migrator.init(allocator);
        try migrator.migrate(runtime, &db.runtime_schema);

        // Orden que ya terminó: no se debe volver a despachar.
        try runtime.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'x', 'done', 1)");
        try CliDriver.insertPendingApproval(runtime, 1, "Test pending terminal");
    }

    g_test_active = true;
    defer g_test_active = false;

    // Primer approve: resuelve la fila (id=1) pero NO despacha por ser terminal.
    {
        g_test_len = 0;
        try CliDriver.cmdApprove(allocator, db_path, catalog_path, 1, true);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, g_test_buffer[0..g_test_len], .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const dispatched = parsed.value.object.get("dispatched") orelse return error.MissingField;
        try std.testing.expect(dispatched == .bool and dispatched.bool == false);
    }

    // Segundo approve: la fila ya estaba resuelta; tampoco despacha ni falla.
    {
        g_test_len = 0;
        try CliDriver.cmdApprove(allocator, db_path, catalog_path, 1, true);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, g_test_buffer[0..g_test_len], .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const dispatched = parsed.value.object.get("dispatched") orelse return error.MissingField;
        try std.testing.expect(dispatched == .bool and dispatched.bool == false);
        const note = parsed.value.object.get("note") orelse return error.MissingField;
        try std.testing.expect(note == .string and std.mem.eql(u8, note.string, "already resolved"));
    }

    // Nunca se ejecutó el despacho: cero salidas de worker y una sola resolución.
    {
        var runtime = try db.Connection.open(allocator, db_path);
        defer runtime.close();
        const outs = try runtime.prepare("SELECT COUNT(*) FROM events WHERE kind = 'worker_output'");
        defer runtime.finalize(outs);
        try std.testing.expect(db.c.sqlite3_step(outs) == db.c.SQLITE_ROW);
        try std.testing.expectEqual(@as(i64, 0), db.c.sqlite3_column_int64(outs, 0));
        const chk = try runtime.prepare("SELECT resolved, approved FROM approvals WHERE id = 1");
        defer runtime.finalize(chk);
        try std.testing.expect(db.c.sqlite3_step(chk) == db.c.SQLITE_ROW);
        try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(chk, 0));
    }
}
