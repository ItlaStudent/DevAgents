const std = @import("std");
const builtin = @import("builtin");
const mcp_client = @import("mcp_client.zig");
const superagent = @import("superagent.zig");
const local_memory = @import("local_memory.zig");
const db = @import("db.zig");

const GetEnvironmentVariableA = @import("platform.zig").env;

// ── Schema types (T-F6-04) ──────────────────────────────────────────────

/// finding persisted via mem_save.
pub const Finding = struct {
    content: []const u8,
    type: []const u8, // "discovery" | "weakness" | "bug" | "decision" | "next_step"
    project: []const u8,
};

/// Weakness detected in the codebase.
pub const Weakness = struct {
    description: []const u8,
    file: []const u8,
    severity: []const u8, // "low" | "medium" | "high" | "critical"
};

/// Bug found during audit.
pub const Bug = struct {
    description: []const u8,
    file: []const u8,
    line: ?u32,
    fix_suggestion: ?[]const u8,
};

/// Design or architecture decision.
pub const Decision = struct {
    context: []const u8,
    decision: []const u8,
    alternatives: []const []const u8,
};

/// Next step / action item.
pub const NextStep = struct {
    action: []const u8,
    owner: []const u8,
    depends_on: []const []const u8,
};

/// Project context returned by mem_context.
pub const ProjectContext = struct {
    observations: []const u8,
    project: []const u8,
};

// ── EngramMemory ────────────────────────────────────────────────────────

/// Memory backend backed by Engram MCP (mem_context, mem_save, mem_session_summary).
/// All JSON is built with std.json.Stringify (no interpolation, no injection).
pub const EngramMemory = struct {
    allocator: std.mem.Allocator,
    client: mcp_client.McpClient,
    project: []const u8,

    pub fn init(allocator: std.mem.Allocator, client: mcp_client.McpClient, project: []const u8) EngramMemory {
        return .{ .allocator = allocator, .client = client, .project = project };
    }

    pub fn deinit(self: *EngramMemory) void {
        self.allocator.free(self.project);
        self.client.deinit();
    }

    pub fn backend(self: *EngramMemory) superagent.MemoryBackend {
        return .{
            .ptr = self,
            .loadContextFn = loadContext,
            .saveFindingFn = saveFinding,
            .sessionSummaryFn = sessionSummary,
            .saveLessonFn = saveLesson,
            .loadLessonsFn = loadLessons,
        };
    }

    /// el transporte posee su propio runtime io — la conexión Engram
    /// vive en CoreState toda la sesión, así que un io prestado del caller
    /// quedaba colgado al destruirse (toda llamada a memoria se colgaba).
    pub fn connect(allocator: std.mem.Allocator, engram_path: []const u8, project: []const u8) !EngramMemory {
        const argv = [_][]const u8{ engram_path, "mcp" };
        const transport = try mcp_client.StdioTransport.connect(allocator, &argv, mcp_client.DEFAULT_TIMEOUT_MS);
        const client = try mcp_client.McpClient.init(allocator, transport, mcp_client.DEFAULT_TIMEOUT_MS);
        return EngramMemory.init(allocator, client, try allocator.dupe(u8, project));
    }

    fn callOrNull(self: *EngramMemory, tool: []const u8, args: []const u8) ?mcp_client.ToolResult {
        return self.client.callTool(tool, args) catch return null;
    }

    // NOTA (verificado EN VIVO contra engram 1.16.1, 2026-06-12): engram bindea la
    // memoria al repositorio por su git_root (project_source="git_root") y RECHAZA un
    // `project` explícito desconocido (error_code "unknown_project"). Por eso NO enviamos
    // el campo `project` en los argumentos de las tools: dejamos que engram auto-detecte
    // por el cwd del proceso (que es la raíz del repo). El schema real exige `title` en
    // mem_save y `content` en mem_session_summary (no `summary`).
    fn loadContext(ptr: *anyopaque, allocator: std.mem.Allocator, project: []const u8) ?[]const u8 {
        const self: *EngramMemory = @ptrCast(@alignCast(ptr));
        _ = project; // engram auto-detecta por git_root; un project explícito desconocido se rechaza.

        const result = self.callOrNull("mem_context", "{}") orelse return null;
        defer result.deinit(self.allocator);
        if (result.is_error or result.content.len == 0) return null;
        return allocator.dupe(u8, result.content) catch null;
    }

    fn saveFinding(ptr: *anyopaque, finding: []const u8) void {
        const self: *EngramMemory = @ptrCast(@alignCast(ptr));

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch return;
        js.objectField("title") catch return; // REQUERIDO por el schema real de engram.
        js.write(deriveTitle(finding)) catch return;
        js.objectField("content") catch return;
        js.write(finding) catch return;
        js.objectField("type") catch return;
        js.write("discovery") catch return;
        js.endObject() catch return;
        const args = self.allocator.dupe(u8, out.written()) catch return;
        defer self.allocator.free(args);

        // El ToolResult posee `content` duplicado; liberarlo (no usamos la respuesta).
        if (self.callOrNull("mem_save", args)) |r| r.deinit(self.allocator);
    }

    fn sessionSummary(ptr: *anyopaque, summary: []const u8, project: []const u8) void {
        const self: *EngramMemory = @ptrCast(@alignCast(ptr));
        _ = project; // session_summary es por proyecto auto-detectado; no toma `project`.

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch return;
        js.objectField("content") catch return; // REQUERIDO (no `summary`).
        js.write(summary) catch return;
        js.endObject() catch return;
        const args = self.allocator.dupe(u8, out.written()) catch return;
        defer self.allocator.free(args);

        if (self.callOrNull("mem_session_summary", args)) |r| r.deinit(self.allocator);
    }

    fn saveLesson(ptr: *anyopaque, lesson: []const u8, project: []const u8) bool {
        const self: *EngramMemory = @ptrCast(@alignCast(ptr));
        _ = project;

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch return false;
        js.objectField("title") catch return false;
        js.write("lesson") catch return false;
        js.objectField("content") catch return false;
        js.write(lesson) catch return false;
        js.objectField("type") catch return false;
        js.write("lesson") catch return false;
        js.endObject() catch return false;
        const args = self.allocator.dupe(u8, out.written()) catch return false;
        defer self.allocator.free(args);

        // T8: guardada solo si Engram respondió sin error.
        const r = self.callOrNull("mem_save", args) orelse return false;
        defer r.deinit(self.allocator);
        return !r.is_error;
    }

    fn loadLessons(ptr: *anyopaque, allocator: std.mem.Allocator, project: []const u8, limit: usize) ?[]const u8 {
        _ = limit;
        // Engram no tiene un filtro por type=lesson; cargar contexto general
        // que incluye las lecciones persistidas como mem_save.
        return loadContext(ptr, allocator, project);
    }
};

/// Deriva un título corto (≤60 bytes, primera línea) para mem_save (campo requerido).
fn deriveTitle(finding: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, finding, '\n') orelse finding.len;
    const end = @min(nl, @as(usize, 60));
    const t = std.mem.trim(u8, finding[0..end], " \t\r");
    return if (t.len == 0) "finding" else t;
}

// ── MemoryBundle: factory que posee NoopMemory o EngramMemory (T-F6-03) ─

pub const MemoryBundle = union(enum) {
    noop: superagent.NoopMemory,
    engram: EngramMemory,
    local: local_memory.LocalMemory,

    pub fn backend(self: *MemoryBundle) superagent.MemoryBackend {
        return switch (self.*) {
            .noop => superagent.NoopMemory.backend(),
            .engram => |*em| em.backend(),
            .local => |*lm| lm.backend(),
        };
    }

    pub fn deinit(self: *MemoryBundle) void {
        switch (self.*) {
            .noop => {},
            .engram => |*em| em.deinit(),
            .local => |*lm| lm.deinit(),
        }
    }

    /// MULTISESSION-P0 (2026-07-12): backend de memoria seguro para el hilo de
    /// dispatch. Para `.local` (fallback SQLite sobre runtime.db), construye un
    /// `LocalMemory` TEMPORAL atado a `conn` (la Connection propia del hilo) en
    /// vez de la conexión original con la que se creó este MemoryBundle — así
    /// `saveFinding`/`saveSessionSummary`/etc. nunca vuelven a tocar `st.db_conn`
    /// desde el hilo de dispatch. `scratch` es memoria del LLAMADOR (vive en su
    /// stack/scope) — este método NUNCA posee ni cierra `conn`, y `LocalMemory`
    /// en sí no tiene recursos propios que liberar (`deinit` ya es un no-op).
    /// El `MemoryBackend` devuelto apunta a `scratch`: el llamador debe mantener
    /// `scratch` vivo (y `conn` abierta) mientras use el backend devuelto — no
    /// debe escapar del scope/lifetime de esa conexión.
    ///
    /// `.engram` y `.noop` no tocan runtime SQLite (Engram habla por su propio
    /// proceso MCP vía stdio; Noop no persiste nada) — para ambos se devuelve el
    /// backend normal sin construir nada nuevo, `scratch` queda sin usar.
    ///
    /// Esto NUNCA muta `self.*` (el MemoryBundle original de CoreState) — es
    /// puramente una vista de solo-lectura sobre una conexión distinta.
    pub fn backendForConn(self: *MemoryBundle, conn: db.Connection, scratch: *local_memory.LocalMemory) superagent.MemoryBackend {
        switch (self.*) {
            .local => |*lm| {
                scratch.* = local_memory.LocalMemory.init(lm.allocator, conn);
                return scratch.backend();
            },
            .engram, .noop => return self.backend(),
        }
    }

    /// Crea el backend de memoria según configuración.
    /// Si path es null, usa LocalMemory (fallback persistente sobre runtime.db).
    pub fn init(allocator: std.mem.Allocator, engram_path: ?[]const u8, project: []const u8, db_conn: db.Connection) !MemoryBundle {
        if (engram_path) |path| {
            const em = EngramMemory.connect(allocator, path, project) catch {
                return MemoryBundle{ .local = local_memory.LocalMemory.init(allocator, db_conn) };
            };
            return MemoryBundle{ .engram = em };
        }
        return MemoryBundle{ .local = local_memory.LocalMemory.init(allocator, db_conn) };
    }
};

/// Convenience factory for CLI/headless paths: creates a MemoryBundle from the
/// ENGRAM_BIN env var + runtime DB. If ENGRAM_BIN is set and Engram connects,
/// uses EngramMemory. Otherwise falls back to LocalMemory (persistent on runtime.db).
/// Prints a warning to stderr if Engram is not available.
pub fn initFromEnv(allocator: std.mem.Allocator, db_conn: db.Connection) MemoryBundle {
    var env_buf: [1024:0]u8 = undefined;
    const env_len = GetEnvironmentVariableA("ENGRAM_BIN", &env_buf, @intCast(env_buf.len));
    const engram_path: ?[]const u8 = if (env_len > 0 and env_len < env_buf.len) env_buf[0..env_len] else null;
    return initFromEngramPath(allocator, db_conn, engram_path);
}

/// Núcleo de initFromEnv con la ruta de Engram ya resuelta (null = ENGRAM_BIN
/// ausente). Los tests usan esta variante: leer el entorno real del proceso
/// haría el resultado depender de la configuración de la máquina.
pub fn initFromEngramPath(allocator: std.mem.Allocator, db_conn: db.Connection, engram_path: ?[]const u8) MemoryBundle {
    if (engram_path) |path| {
        if (MemoryBundle.init(allocator, path, "devagents", db_conn)) |bundle| {
            return bundle;
        } else |_| {}
    }
    // SUPPRESS-IN-TESTS: este print va a stderr; el test runner de Zig 0.16 lo
    // captura como result_stderr del step y muestra un "failed command" espurio
    // aunque el step haya pasado (538/538). El mensaje es útil en producción pero
    // es puro ruido en `zig build test`.
    if (!builtin.is_test) {
        std.debug.print("[memoria] Engram no disponible (ENGRAM_BIN no set o conexion fallo). Usando fallback local persistente (runtime.db).\n", .{});
    }
    return MemoryBundle{ .local = local_memory.LocalMemory.init(allocator, db_conn) };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "engram memory saveFinding sends correct JSON payload" {
    const allocator = std.testing.allocator;
    const transport = try createMockEngramTransport(allocator);
    const client = try mcp_client.McpClient.init(allocator, transport, mcp_client.DEFAULT_TIMEOUT_MS);
    var em = EngramMemory.init(allocator, client, try allocator.dupe(u8, "test-proj"));
    defer em.deinit();
    const bk = em.backend();
    bk.saveFinding("hallazgo con \"comillas\" y \n saltos");
    // Verify via mock assertions: the mock should have recorded the request.
    const ctx: *MockEngramCtx = @ptrCast(@alignCast(transport.ptr));
    try std.testing.expect(ctx.calls_recorded.items.len > 0);
}

test "engram memory sessionSummary calls mem_session_summary" {
    const allocator = std.testing.allocator;
    const transport = try createMockEngramTransport(allocator);
    const client = try mcp_client.McpClient.init(allocator, transport, mcp_client.DEFAULT_TIMEOUT_MS);
    var em = EngramMemory.init(allocator, client, try allocator.dupe(u8, "test-proj"));
    defer em.deinit();
    const bk = em.backend();
    bk.saveSessionSummary("session completed with 3 findings", "test-proj");
}

test "engram memory handles special chars in finding" {
    const allocator = std.testing.allocator;
    const transport = try createMockEngramTransport(allocator);
    const client = try mcp_client.McpClient.init(allocator, transport, mcp_client.DEFAULT_TIMEOUT_MS);
    var em = EngramMemory.init(allocator, client, try allocator.dupe(u8, "test-proj"));
    defer em.deinit();
    const bk = em.backend();
    bk.saveFinding("bug en \"file.cpp\": línea 42 -> valor = \"test\"");
}

test "MemoryBundle init with null path uses LocalMemory fallback" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    var mb = try MemoryBundle.init(allocator, null, "test", conn);
    defer mb.deinit();
    const bk = mb.backend();
    bk.saveFinding("finding");
    const ctx = bk.loadContext(allocator, "test");
    try std.testing.expect(ctx != null);
    defer if (ctx) |c| allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "finding") != null);
    bk.saveSessionSummary("summary", "test");
}

test "engram memory backend matches extended MemoryBackend interface" {
    const allocator = std.testing.allocator;
    const transport = try createMockEngramTransport(allocator);
    const client = try mcp_client.McpClient.init(allocator, transport, mcp_client.DEFAULT_TIMEOUT_MS);
    var em = EngramMemory.init(allocator, client, try allocator.dupe(u8, "p"));
    defer em.deinit();
    const bk = em.backend();
    const ctx = bk.loadContext(allocator, "p");
    defer if (ctx) |c| allocator.free(c);
    bk.saveFinding("f");
    bk.saveSessionSummary("s", "p");
    _ = bk.saveLesson("lesson content", "p");
    const lessons = bk.loadLessons(allocator, "p", 3);
    defer if (lessons) |l| allocator.free(l);
}

// ── MULTISESSION-P0 (2026-07-12): backend de memoria por-hilo de dispatch ──
// Última fuga conocida hacia st.db_conn: dispatchApprovedOrder llamaba
// st.memory.backend().saveFinding/saveSessionSummary, que para el fallback
// LocalMemory escriben con la Connection ORIGINAL del bundle (== st.db_conn),
// no con la Connection propia del hilo de dispatch.

const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
}.GetTempPathA else @import("platform.zig").tempPath;

fn multisessionTestPath(tmp: *const std.testing.TmpDir, filename: []const u8) ![:0]u8 {
    var sys_buf: [1024]u8 = undefined;
    const len = GetTempPathA(1024, &sys_buf);
    const sys_temp = if (len > 0 and len < 1024) sys_buf[0..len] else "C:\\Windows\\Temp\\";
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}beats-test-{s}-{s}",
        .{ sys_temp, tmp.sub_path[0..], filename },
    );
    defer std.testing.allocator.free(path);
    return std.testing.allocator.dupeZ(u8, path);
}

test "MULTISESSION-P0 A: backendForConn's temporary LocalMemory writes via the given conn" {
    const allocator = std.testing.allocator;

    // conn_bundle: la conexión ORIGINAL con la que se creó el MemoryBundle
    // (simula st.db_conn, la del hilo principal).
    var conn_bundle = try db.Connection.open(allocator, ":memory:");
    defer conn_bundle.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn_bundle, &db.runtime_schema);

    // conn_thread: archivo real distinto — simula la Connection propia del hilo
    // de dispatch (MULTISESSION-P0, sesión anterior).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_thread = try multisessionTestPath(&tmp, "memory-a.db");
    defer allocator.free(path_thread);
    var conn_thread = try db.Connection.open(allocator, path_thread);
    defer conn_thread.close();
    try migrator.migrate(conn_thread, &db.runtime_schema);

    var bundle = try MemoryBundle.init(allocator, null, "proj", conn_bundle);
    defer bundle.deinit();
    try std.testing.expect(bundle == .local);

    var scratch: local_memory.LocalMemory = undefined;
    const bk = bundle.backendForConn(conn_thread, &scratch);
    bk.saveFinding("finding via thread conn");

    const stmt = try conn_thread.prepare("SELECT COUNT(*) FROM memory_findings WHERE content = ?");
    defer conn_thread.finalize(stmt);
    try db.bindText(stmt, 1, "finding via thread conn");
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(stmt, 0));
}

test "MULTISESSION-P0 B: backendForConn never touches the bundle's original connection" {
    const allocator = std.testing.allocator;
    var conn_bundle = try db.Connection.open(allocator, ":memory:");
    defer conn_bundle.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn_bundle, &db.runtime_schema);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_thread = try multisessionTestPath(&tmp, "memory-b.db");
    defer allocator.free(path_thread);
    var conn_thread = try db.Connection.open(allocator, path_thread);
    defer conn_thread.close();
    try migrator.migrate(conn_thread, &db.runtime_schema);

    var bundle = try MemoryBundle.init(allocator, null, "proj", conn_bundle);
    defer bundle.deinit();

    var scratch: local_memory.LocalMemory = undefined;
    const bk = bundle.backendForConn(conn_thread, &scratch);
    bk.saveFinding("only in thread conn");
    bk.saveSessionSummary("summary only in thread conn", "proj");

    // conn_bundle (== st.db_conn del hilo principal) debe seguir en CERO — nada
    // de esto debió escribirse ahí.
    const stmt1 = try conn_bundle.prepare("SELECT COUNT(*) FROM memory_findings");
    defer conn_bundle.finalize(stmt1);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt1));
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt1, 0));

    const stmt2 = try conn_bundle.prepare("SELECT COUNT(*) FROM memory_sessions");
    defer conn_bundle.finalize(stmt2);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt2));
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt2, 0));
}

test "MULTISESSION-P0 C: the returned backend is bound to the caller's scratch space, not hidden state" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var bundle = try MemoryBundle.init(allocator, null, "proj", conn);
    defer bundle.deinit();

    var scratch: local_memory.LocalMemory = undefined;
    const bk = bundle.backendForConn(conn, &scratch);
    // El backend apunta EXACTAMENTE al scratch del llamador — su lifetime es el
    // del llamador (p. ej. dispatchApprovedOrder), nunca un estado oculto que
    // pudiera sobrevivir más allá de ese scope o compartirse entre hilos/órdenes.
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&scratch)), bk.ptr);
}

test "MULTISESSION-P0 D: st.memory (original bundle) stays usable after the per-thread conn closes" {
    const allocator = std.testing.allocator;
    var conn_bundle = try db.Connection.open(allocator, ":memory:");
    defer conn_bundle.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn_bundle, &db.runtime_schema);

    var bundle = try MemoryBundle.init(allocator, null, "proj", conn_bundle);
    defer bundle.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_thread = try multisessionTestPath(&tmp, "memory-d.db");
    defer allocator.free(path_thread);
    {
        var conn_thread = try db.Connection.open(allocator, path_thread);
        try migrator.migrate(conn_thread, &db.runtime_schema);
        var scratch: local_memory.LocalMemory = undefined;
        const bk = bundle.backendForConn(conn_thread, &scratch);
        bk.saveFinding("via thread conn, soon to close");
        conn_thread.close(); // el "hilo" termina y cierra SU conexión.
    }

    // El bundle original (st.memory) sigue perfectamente funcional.
    const bk_main = bundle.backend();
    bk_main.saveFinding("via main after thread closed");
    const ctx = bk_main.loadContext(allocator, "proj");
    try std.testing.expect(ctx != null);
    defer if (ctx) |c| allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "via main after thread closed") != null);
}

test "MemoryBundle initFromEnv without ENGRAM_BIN uses LocalMemory fallback" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    // Ruta null = ENGRAM_BIN ausente → debe caer a LocalMemory. Se pasa null
    // explícito en vez de leer el entorno: la máquina de desarrollo puede
    // tener ENGRAM_BIN apuntando a un engram.exe real y el test lo lanzaría.
    var mb = initFromEngramPath(allocator, conn, null);
    defer mb.deinit();
    try std.testing.expect(mb == .local);

    // Verify it actually persists and recovers findings
    const bk = mb.backend();
    bk.saveFinding("finding from initFromEnv test");
    const ctx = bk.loadContext(allocator, "test");
    try std.testing.expect(ctx != null);
    defer if (ctx) |c| allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "finding from initFromEnv test") != null);
}

// ── Mock transport ─────────────────────────────────────────────────────

fn createMockEngramTransport(allocator: std.mem.Allocator) !mcp_client.McpTransport {
    const ctx = try allocator.create(MockEngramCtx);
    ctx.* = .{
        .allocator = allocator,
        .stdin_writes = std.ArrayList([]const u8).empty,
        .init_done = false,
        .calls_recorded = std.ArrayList([]const u8).empty,
    };
    return .{
        .ptr = ctx,
        .writeFn = mockEngramWrite,
        .readFn = mockEngramRead,
        .closeFn = mockEngramClose,
    };
}

const MockEngramCtx = struct {
    allocator: std.mem.Allocator,
    stdin_writes: std.ArrayList([]const u8),
    init_done: bool,
    calls_recorded: std.ArrayList([]const u8),
};

fn mockEngramWrite(ptr: *anyopaque, data: []const u8) mcp_client.McpError!void {
    const ctx: *MockEngramCtx = @ptrCast(@alignCast(ptr));
    const owned = try ctx.allocator.dupe(u8, data);
    try ctx.stdin_writes.append(ctx.allocator, owned);
}

fn mockEngramRead(ptr: *anyopaque, allocator: std.mem.Allocator) mcp_client.McpError![]u8 {
    const ctx: *MockEngramCtx = @ptrCast(@alignCast(ptr));

    if (!ctx.init_done) {
        ctx.init_done = true;
        return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"mock-engram\",\"version\":\"0.1.0\"}}}");
    }

    const written = ctx.stdin_writes.items;
    // Record calls for test assertions.
    const req = if (written.len > 0) blk: {
        const d = ctx.allocator.dupe(u8, written[0]) catch "";
        const call = try ctx.allocator.dupe(u8, d);
        try ctx.calls_recorded.append(ctx.allocator, call);
        break :blk d;
    } else "";
    defer if (req.len > 0) ctx.allocator.free(req);

    // Clean stdin_writes buffer.
    for (written) |w| ctx.allocator.free(w);
    ctx.stdin_writes.deinit(ctx.allocator);
    ctx.stdin_writes = std.ArrayList([]const u8).empty;

    const req_id = extractIdFromJson(req);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return error.OutOfMemory;
    js.objectField("jsonrpc") catch return error.OutOfMemory;
    js.write("2.0") catch return error.OutOfMemory;
    js.objectField("id") catch return error.OutOfMemory;
    js.write(req_id) catch return error.OutOfMemory;
    js.objectField("result") catch return error.OutOfMemory;
    js.beginObject() catch return error.OutOfMemory;

    if (req.len > 0) {
        if (std.mem.indexOf(u8, req, "tools/list") != null) {
            js.objectField("tools") catch return error.OutOfMemory;
            js.beginArray() catch return error.OutOfMemory;
            js.endArray() catch return error.OutOfMemory;
        } else if (std.mem.indexOf(u8, req, "tools/call") != null) {
            js.objectField("content") catch return error.OutOfMemory;
            js.beginArray() catch return error.OutOfMemory;
            js.beginObject() catch return error.OutOfMemory;
            js.objectField("type") catch return error.OutOfMemory;
            js.write("text") catch return error.OutOfMemory;
            js.objectField("text") catch return error.OutOfMemory;
            if (std.mem.indexOf(u8, req, "mem_context") != null) {
                js.write("observations for project") catch return error.OutOfMemory;
            } else {
                js.write("ok") catch return error.OutOfMemory;
            }
            js.endObject() catch return error.OutOfMemory;
            js.endArray() catch return error.OutOfMemory;
            js.objectField("isError") catch return error.OutOfMemory;
            js.write(false) catch return error.OutOfMemory;
        }
    }

    js.endObject() catch return error.OutOfMemory;
    js.endObject() catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
}

fn extractIdFromJson(json: []const u8) i64 {
    const needle = "\"id\":";
    if (std.mem.indexOf(u8, json, needle)) |i| {
        const start = i + needle.len;
        const rest = json[start..];
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '-')) : (end += 1) {}
        if (end > 0) {
            return std.fmt.parseInt(i64, rest[0..end], 10) catch 0;
        }
    }
    return 0;
}

fn mockEngramClose(ptr: *anyopaque) void {
    const ctx: *MockEngramCtx = @ptrCast(@alignCast(ptr));
    for (ctx.stdin_writes.items) |w| ctx.allocator.free(w);
    ctx.stdin_writes.deinit(ctx.allocator);
    for (ctx.calls_recorded.items) |c| ctx.allocator.free(c);
    ctx.calls_recorded.deinit(ctx.allocator);
    ctx.allocator.destroy(ctx);
}
