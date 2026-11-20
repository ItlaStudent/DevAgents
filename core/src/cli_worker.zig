const std = @import("std");
const planner = @import("planner.zig");
const sandbox = @import("sandbox.zig");
const worker_backend = @import("worker_backend.zig");
const sync = @import("sync.zig");
const process_tree = @import("process_tree.zig");

// T4: Win32 functions for process termination and timing.
const windows = std.os.windows;
extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: u32) c_int;
const Sleep = @import("platform.zig").sleep;
extern "kernel32" fn CancelSynchronousIo(hThread: windows.HANDLE) c_int;

/// E5.07: cómo se alimenta el stdin del hijo.
pub const StdinMode = enum {
    /// Contrato original: la tarea serializada como JSON por stdin.
    task_json,
    /// El prompt (task.description) como texto plano por stdin.
    prompt_text,
    /// El prompt viaja por argv; stdin se cierra al instante (EOF inmediato)
    /// para que el CLI no espere más entrada.
    none,
};

/// E5.07: callback de streaming — una llamada por línea completa de stdout,
/// desde el hilo lector. `line` solo es válida durante la llamada.
pub const LineSink = struct {
    ctx: *anyopaque,
    callFn: *const fn (ctx: *anyopaque, line: []const u8) void,

    pub fn call(self: LineSink, line: []const u8) void {
        self.callFn(self.ctx, line);
    }
};

/// E5.07: resultado de una corrida headless — stdout+stderr mezclados por
/// orden de llegada, acotados a `transcript_cap`.
pub const CollectOutcome = struct {
    output: []u8,
    truncated: bool,
    /// null cuando el proceso no llegó a salir (timeout/límite → kill).
    exit_code: ?u8,
    timed_out: bool,
    /// E5.08: el kill lo pidió `abort_flag` (p. ej. tope de turnos), no el
    /// reloj. `timed_out` queda false para distinguirlo en el informe.
    limit_hit: bool = false,
    cancelled: bool = false,
    /// El trabajo no quedó sin procesos activos en el tope: quien restaure
    /// permisos del espacio debe fallar visible en vez de restaurar a ciegas.
    tree_stuck: bool = false,

    pub fn deinit(self: *CollectOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

/// Cota por defecto de la transcripción capturada (stdout+stderr).
pub const DEFAULT_TRANSCRIPT_CAP: usize = 256 * 1024;

/// Silencio tras el que se avisa de que el agente externo no da señales.
pub const IDLE_NOTICE_MS: u64 = 90 * 1000;

/// ExternalCliWorker: proceso hijo supervisado (mismo patrón StdioTransport de mcp_client.zig).
/// Lanza el CLI como proceso hijo con pipes stdin/stdout, envía la tarea por stdin,
/// captura stdout como artefactos JSON, timeout de proceso, kill integrado.
///
/// E5.07 (adaptadores headless): `cwd` fija el worktree del hijo, `stdin_mode`
/// el canal del prompt, `sink` emite cada línea de stdout en vivo (streaming →
/// eventos), stderr se mezcla en la misma transcripción acotada y el hijo nace
/// sin ventana (`create_no_window`). El adaptador puede fijar `environ_map`
/// para retirar claves del hijo sin cambiar el entorno del anfitrión.
///
/// Binario/args configurables. Testeable sin red contra ejecutable mock versionado.
/// Para tests sin proceso real, inyectar `mock_output` con `setMockOutput`.
pub const ExternalCliWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    timeout_ms: u64,
    /// Si está set, `runImpl`/`runCollect` usan esto como stdout del hijo en
    /// lugar de spawn real.
    mock_output: ?[]const u8 = null,
    /// E5.07: cwd del hijo (el worktree). null = hereda el del proceso.
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    stdin_mode: StdinMode = .task_json,
    sink: ?LineSink = null,
    /// Native cleanup warnings bypass transcript parsing/turn accounting.
    cleanup_sink: ?LineSink = null,
    transcript_cap: usize = DEFAULT_TRANSCRIPT_CAP,
    /// E5.08: aborto externo. Cuando el flag se levanta (tope de turnos,
    /// cancelación de orden), el bucle de espera mata al hijo igual que un
    /// timeout pero el outcome llega con `limit_hit` en vez de `timed_out`.
    abort_flag: ?*const std.atomic.Value(bool) = null,
    is_cancelled_fn: ?*const fn (?*anyopaque) bool = null,
    cancelled_ctx: ?*anyopaque = null,
    /// F13 (10-nov): aviso de inactividad. Si el hijo pasa
    /// `idle_notice_ms` sin escribir una línea (stdout o stderr), se llama a
    /// `idle_sink` con los segundos de silencio en decimal, y de nuevo cada
    /// `idle_notice_ms` mientras siga callado. Solo avisa: el tope sigue
    /// siendo `timeout_ms` (OpenCode gratuito estuvo 13 min mudo, orden 930).
    idle_sink: ?LineSink = null,
    idle_notice_ms: u64 = IDLE_NOTICE_MS,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, timeout_ms: u64) ExternalCliWorker {
        return .{ .allocator = allocator, .io = io, .argv = argv, .timeout_ms = timeout_ms };
    }

    pub fn setMockOutput(self: *ExternalCliWorker, output: []const u8) void {
        self.mock_output = output;
    }

    pub fn backend(self: *ExternalCliWorker) worker_backend.WorkerBackend {
        return .{ .ptr = self, .runFn = runImpl, .deinitFn = noopDeinit };
    }

    fn noopDeinit(_: *anyopaque) void {}

    fn runImpl(ctx: *anyopaque, allocator: std.mem.Allocator, task: planner.PlannedTask, sb: sandbox.Sandbox) worker_backend.WorkerError!worker_backend.WorkerResult {
        const self: *ExternalCliWorker = @ptrCast(@alignCast(ctx));

        // Obtener stdout (mock o real).
        var owned_output: ?[]u8 = null;
        defer if (owned_output) |o| allocator.free(o);

        const output = if (self.mock_output) |mo|
            mo
        else blk: {
            var oc = try self.runCollect(allocator, task);
            if (oc.timed_out) {
                oc.deinit(allocator);
                return error.Timeout;
            }
            owned_output = oc.output;
            break :blk oc.output;
        };

        // Parsear salida como JSON de artefactos.
        var artifacts = try parseArtifactsFromOutput(allocator, output);
        errdefer {
            var j: usize = 0;
            while (j < artifacts.items.len) : (j += 1) artifacts.items[j].deinit(allocator);
            artifacts.deinit(allocator);
        }

        // (corrección tras la auditoría, punto 1): el parser es
        // compartido, pero la asignación de la ruta esperada (un cuerpo con la
        // ruta puesta en la etiqueta del campo) debe aplicarse también en este
        // recorrido, no solo en `NativeWorker.runImpl`. Mismo punto único.
        try worker_backend.assignArtifactRoutes(allocator, task, &artifacts);

        // Validar sandbox.
        {
            var j: usize = 0;
            const len = artifacts.items.len;
            while (j < len) : (j += 1) {
                if (!sb.isAllowed(artifacts.items[j].path)) {
                    return error.SandboxDenied;
                }
            }
        }

        return worker_backend.WorkerResult{
            .task_id = try allocator.dupe(u8, task.id),
            .artifacts = try artifacts.toOwnedSlice(allocator),
            .success = true,
            .error_msg = try allocator.dupe(u8, ""),
        };
    }

    /// T4/E5.07: contexto de un hilo lector (stdout o stderr). Ambos lectores
    /// comparten `output` bajo `output_mu`; solo stdout invoca `sink`.
    const ReaderCtx = struct {
        reader: *std.Io.File.Reader,
        output: *std.ArrayList(u8),
        output_mu: *sync.Mutex,
        cap: usize,
        truncated: *std.atomic.Value(bool),
        allocator: std.mem.Allocator,
        /// Nº de lectores terminados (el hilo principal espera a 2).
        done: *std.atomic.Value(u32),
        sink: ?LineSink,
        /// Líneas leídas (de cualquiera de los dos pipes): mide la inactividad.
        activity: *std.atomic.Value(u64),
    };

    /// Con el trabajo atascado un descendiente puede seguir sujetando los pipes
    /// y los lectores nunca verían EOF. Cancelar su ReadFile síncrono los libera
    /// (con tope de 5 s; pasado el tope el join queda como último recurso).
    fn unblockReaders(out_thr: *const std.Thread, err_thr: *const std.Thread, done: *std.atomic.Value(u32)) void {
        if (@import("builtin").os.tag != .windows) return;
        var waited: u32 = 0;
        while (done.load(.acquire) != 2 and waited < 5000) : (waited += 10) {
            _ = CancelSynchronousIo(out_thr.getHandle());
            _ = CancelSynchronousIo(err_thr.getHandle());
            Sleep(10);
        }
    }

    fn readerThread(ctx: *ReaderCtx) void {
        while (true) {
            const maybe = ctx.reader.interface.takeDelimiter('\n') catch {
                // StreamTooLong/ReadFailed: la línea no cabe o el pipe murió —
                // se marca truncado y el hilo termina (EOF lógico).
                ctx.truncated.store(true, .release);
                break;
            };
            const line = maybe orelse break;
            _ = ctx.activity.fetchAdd(1, .release);
            if (ctx.sink) |s| s.call(line);
            ctx.output_mu.lock();
            const room = ctx.cap -| ctx.output.items.len;
            const take = @min(line.len, room);
            if (take > 0) ctx.output.appendSlice(ctx.allocator, line[0..take]) catch {};
            if (take == line.len and ctx.output.items.len < ctx.cap)
                ctx.output.append(ctx.allocator, '\n') catch {};
            if (take < line.len or (ctx.output.items.len >= ctx.cap and line.len > 0))
                ctx.truncated.store(true, .release);
            ctx.output_mu.unlock();
        }
        _ = ctx.done.fetchAdd(1, .acq_rel);
    }

    /// E5.07: ejecuta el hijo y devuelve la transcripción acotada (stdout+stderr),
    /// el código de salida y si hubo timeout. A diferencia del camino JSON,
    /// un timeout NO pierde la salida parcial: vuelve con `timed_out=true`.
    /// stdin se alimenta según `stdin_mode` y se cierra siempre (EOF al hijo).
    pub fn runCollect(self: *ExternalCliWorker, allocator: std.mem.Allocator, task: planner.PlannedTask) worker_backend.WorkerError!CollectOutcome {
        if (self.is_cancelled_fn) |check| {
            if (check(self.cancelled_ctx)) return .{ .output = try allocator.dupe(u8, ""), .truncated = false, .exit_code = null, .timed_out = false, .cancelled = true };
        }
        if (self.mock_output) |mo| {
            const n = @min(mo.len, self.transcript_cap);
            return .{
                .output = try allocator.dupe(u8, mo[0..n]),
                .truncated = mo.len > self.transcript_cap,
                .exit_code = 0,
                .timed_out = false,
            };
        }

        if (@import("builtin").os.tag == .windows and self.argv.len > 0 and @import("executor.zig").isBatchShim(self.argv[0]))
            try @import("windows_cmd.zig").validateArgs(self.argv[0], self.argv[1..]);
        var child_environment = if (self.environ_map) |environment|
            try environment.clone(allocator)
        else
            @import("platform.zig").environ().createMap(allocator) catch |failure| switch (failure) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    std.debug.print("cli worker: could not read child environment: {s}\n", .{@errorName(failure)});
                    return error.SpawnFailed;
                },
            };
        defer child_environment.deinit();
        try child_environment.put("DEVAGENTS_COMMAND_CHILD", "1");
        var tree = try process_tree.ProcessTree.init();
        if (self.cleanup_sink) |sink| tree.notice = .{ .ctx = sink.ctx, .callFn = sink.callFn };
        defer tree.deinit();
        var child = std.process.spawn(self.io, .{
            .argv = self.argv,
            .environ_map = &child_environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = if (self.cwd) |d| .{ .path = d } else .inherit,
            // E5.07: un CLI headless no abre ventana de consola propia.
            .create_no_window = true,
            .start_suspended = @import("builtin").os.tag == .windows,
            .pgid = process_tree.ProcessTree.spawn_pgid,
        }) catch return error.SpawnFailed;

        errdefer {
            tree.deinit();
            child.kill(self.io);
        }
        try tree.attachAndResume(&child);

        {
            var stdin_buf: [1024]u8 = undefined;
            var stdin_writer = child.stdin.?.writerStreaming(self.io, &stdin_buf);
            switch (self.stdin_mode) {
                .task_json => {
                    // Serializar la tarea como JSON con escape correcto
                    // (std.json.Stringify) en vez de std.fmt.allocPrint, que no
                    // escapa comillas/backslashes/newlines.
                    var json_out: std.Io.Writer.Allocating = .init(self.allocator);
                    defer json_out.deinit();
                    var js: std.json.Stringify = .{ .writer = &json_out.writer, .options = .{} };
                    js.beginObject() catch return error.SpawnFailed;
                    js.objectField("id") catch return error.SpawnFailed;
                    js.write(task.id) catch return error.SpawnFailed;
                    js.objectField("desc") catch return error.SpawnFailed;
                    js.write(task.description) catch return error.SpawnFailed;
                    js.objectField("type") catch return error.SpawnFailed;
                    js.write(task.task_type.toText()) catch return error.SpawnFailed;
                    js.endObject() catch return error.SpawnFailed;
                    stdin_writer.interface.writeAll(json_out.written()) catch return error.ProcessDied;
                    stdin_writer.interface.writeByte('\n') catch return error.ProcessDied;
                },
                .prompt_text => {
                    // EOF delimita el prompt: conservar sus bytes, incluidos
                    // saltos de línea, sin añadir texto al contrato del CLI.
                    stdin_writer.interface.writeAll(task.description) catch return error.ProcessDied;
                },
                .none => {},
            }
            stdin_writer.interface.flush() catch return error.ProcessDied;
            // EOF inmediato: los CLIs que leen el prompt por stdin no esperan más.
            child.stdin.?.close(self.io);
            child.stdin = null;
        }

        var stdout_buf_arr: [256 * 1024]u8 = undefined;
        var stderr_buf_arr: [16 * 1024]u8 = undefined;
        var out_reader = child.stdout.?.readerStreaming(self.io, &stdout_buf_arr);
        var err_reader = child.stderr.?.readerStreaming(self.io, &stderr_buf_arr);
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        var output_mu: sync.Mutex = .init();
        var done = std.atomic.Value(u32).init(0);
        var truncated = std.atomic.Value(bool).init(false);
        var activity = std.atomic.Value(u64).init(0);

        var out_ctx = ReaderCtx{
            .reader = &out_reader,
            .output = &output,
            .output_mu = &output_mu,
            .cap = self.transcript_cap,
            .truncated = &truncated,
            .allocator = allocator,
            .done = &done,
            .sink = self.sink,
            .activity = &activity,
        };
        var err_ctx = ReaderCtx{
            .reader = &err_reader,
            .output = &output,
            .output_mu = &output_mu,
            .cap = self.transcript_cap,
            .truncated = &truncated,
            .allocator = allocator,
            .done = &done,
            .sink = null,
            .activity = &activity,
        };
        const out_thr = std.Thread.spawn(.{}, readerThread, .{&out_ctx}) catch return error.SpawnFailed;
        const err_thr = std.Thread.spawn(.{}, readerThread, .{&err_ctx}) catch {
            // Sin segundo hilo el pipe de stderr llenaría y colgaría al hijo:
            // kill → EOF en stdout → el primer hilo sale y se puede unir.
            tree.deinit();
            if (@import("builtin").os.tag != .windows) child.kill(self.io);
            out_thr.join();
            child.kill(self.io);
            return error.SpawnFailed;
        };

        // T4: el camino feliz vuelve en cuanto ambos pipes llegan a EOF; un hijo
        // colgado se mata al vencer el deadline.
        const poll_ms: u64 = 10;
        var waited: u64 = 0;
        var aborted = false;
        var cancelled = false;
        var parent_exited = false;
        var idle = IdleWatch{ .every_ms = self.idle_notice_ms };
        while (waited < self.timeout_ms) {
            if (self.idle_sink) |sink| idle.tick(activity.load(.acquire), poll_ms, sink);
            if (self.is_cancelled_fn) |check| {
                if (check(self.cancelled_ctx)) {
                    cancelled = true;
                    break;
                }
            }
            if (tree.parentExited(&child)) {
                parent_exited = true;
                tree.deinit();
                break;
            }
            if (@import("builtin").os.tag != .windows and done.load(.acquire) == 2) break;
            if (self.abort_flag) |f| {
                if (f.load(.acquire)) {
                    aborted = true;
                    break;
                }
            }
            Sleep(@intCast(poll_ms));
            waited += poll_ms;
        }

        if ((parent_exited or (@import("builtin").os.tag != .windows and done.load(.acquire) == 2)) and !cancelled) {
            if (tree.stuck) unblockReaders(&out_thr, &err_thr, &done);
            out_thr.join();
            err_thr.join();
            const term = child.wait(self.io) catch return error.ProcessDied;
            const code: ?u8 = switch (term) {
                .exited => |c| c,
                else => null,
            };
            return .{
                .output = try output.toOwnedSlice(allocator),
                .truncated = truncated.load(.acquire),
                .exit_code = code,
                .timed_out = false,
                .tree_stuck = tree.stuck,
            };
        }

        // Terminate the whole job before joining readers or restoring ACLs.
        tree.deinit();
        if (@import("builtin").os.tag != .windows) child.kill(self.io);
        if (tree.stuck) unblockReaders(&out_thr, &err_thr, &done);
        out_thr.join();
        err_thr.join();
        child.kill(self.io);
        return .{
            .output = try output.toOwnedSlice(allocator),
            .truncated = true,
            .exit_code = null,
            .timed_out = !aborted and !cancelled,
            .limit_hit = aborted,
            .cancelled = cancelled,
            .tree_stuck = tree.stuck,
        };
    }
};

/// Cuenta el silencio entre líneas del hijo y avisa cada `every_ms` de
/// silencio seguido. Separado del bucle de espera para probarlo sin procesos.
const IdleWatch = struct {
    every_ms: u64,
    seen: u64 = 0,
    silent_ms: u64 = 0,
    next_ms: u64 = 0,

    fn tick(self: *IdleWatch, lines: u64, step_ms: u64, sink: LineSink) void {
        if (self.every_ms == 0) return;
        if (self.next_ms == 0) self.next_ms = self.every_ms;
        if (lines != self.seen) {
            self.seen = lines;
            self.silent_ms = 0;
            self.next_ms = self.every_ms;
            return;
        }
        self.silent_ms += step_ms;
        if (self.silent_ms < self.next_ms) return;
        self.next_ms += self.every_ms;
        var buf: [24]u8 = undefined;
        const secs = std.fmt.bufPrint(&buf, "{d}", .{self.silent_ms / 1000}) catch return;
        sink.call(secs);
    }
};

test "CK-PUB-009 F13: IdleWatch avisa tras el silencio, repite y se reinicia con salida" {
    const Rec = struct {
        calls: [8][24]u8 = undefined,
        lens: [8]usize = undefined,
        n: usize = 0,
        fn call(ctx: *anyopaque, line: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.calls[self.n][0..line.len], line);
            self.lens[self.n] = line.len;
            self.n += 1;
        }
        fn text(self: *const @This(), i: usize) []const u8 {
            return self.calls[i][0..self.lens[i]];
        }
    };
    var rec: Rec = .{};
    const sink: LineSink = .{ .ctx = &rec, .callFn = Rec.call };
    var w = IdleWatch{ .every_ms = 1000 };
    // 0,9 s callado: nada.
    for (0..9) |_| w.tick(0, 100, sink);
    try std.testing.expectEqual(@as(usize, 0), rec.n);
    // 1 s: primer aviso; 2 s: segundo.
    w.tick(0, 100, sink);
    try std.testing.expectEqual(@as(usize, 1), rec.n);
    try std.testing.expectEqualStrings("1", rec.text(0));
    for (0..10) |_| w.tick(0, 100, sink);
    try std.testing.expectEqual(@as(usize, 2), rec.n);
    try std.testing.expectEqualStrings("2", rec.text(1));
    // Llega una línea: el contador vuelve a cero y no avisa antes de 1 s.
    w.tick(1, 100, sink);
    for (0..9) |_| w.tick(1, 100, sink);
    try std.testing.expectEqual(@as(usize, 2), rec.n);
    w.tick(1, 100, sink);
    try std.testing.expectEqual(@as(usize, 3), rec.n);
    try std.testing.expectEqualStrings("1", rec.text(2));
}

fn parseArtifactsFromOutput(allocator: std.mem.Allocator, raw: []const u8) worker_backend.WorkerError!std.ArrayList(worker_backend.Artifact) {
    // P9: un ÚNICO parser de artefactos en el motor. Este camino (el worker de
    // CLI) tenía SU PROPIA copia del parser manual, tercera encarnación del
    // mismo contrato que `live_worker.extractJsonArray` +
    // `worker_backend.parseLlmResponse`. Las tres arrastraron el mismo defecto
    // (respuesta buena tirada a basura por la restricción "debe empezar con [")
    // y la tercera se descubrió solo tras arreglar las otras dos. Aquí se une a
    // la implementación única: extrae el JSON (prosa/fences/objeto suelto) y lo
    // parsea con el mismo std.json que la interfaz, aliasing fuera del parser
    // manual (que además descodificaba escapes al revés y perdía contenido
    // multilínea).
    return worker_backend.parseArtifacts(allocator, raw);
}

/// Fuzz wrapper: calls parseArtifactsFromOutput and cleans up. Used by tools/fuzz.zig.
pub fn fuzz_parseArtifactsFromOutput(allocator: std.mem.Allocator, raw: []const u8) !void {
    var result = try parseArtifactsFromOutput(allocator, raw);
    defer {
        for (result.items) |*a| a.deinit(allocator);
        result.deinit(allocator);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parse artifacts from CLI stdout JSON" {
    const allocator = std.testing.allocator;
    const raw = "[{\"field\":\"source.c\",\"content\":\"int main(){return 0;}\"}]";
    var artifacts = try parseArtifactsFromOutput(allocator, raw);
    defer {
        var j: usize = 0;
        while (j < artifacts.items.len) : (j += 1) artifacts.items[j].deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("source.c", artifacts.items[0].path);
}

test "parse artifacts rejects non-JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArtifact, parseArtifactsFromOutput(allocator, "hello"));
}

test "REGRESION-148 (CLI): un objeto suelto es UN artefacto, no un rechazo" {
    const allocator = std.testing.allocator;
    var artifacts = try parseArtifactsFromOutput(allocator,
        \\{"field":"source.py","content":"print('hola')"}
    );
    defer {
        for (artifacts.items) |*a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("source.py", artifacts.items[0].path);
    try std.testing.expectEqualStrings("print('hola')", artifacts.items[0].content);
}

test "cli worker config stores argv and timeout" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mock.exe", "--task" };
    var cli = ExternalCliWorker.init(allocator, std.testing.io, &argv, 5000);
    const bk = cli.backend();
    defer bk.deinit();
    try std.testing.expectEqual(@as(u64, 5000), cli.timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), cli.argv.len);
}

test "cli worker mock output parses artifacts through WorkerBackend" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"mock.exe"};
    var cli = ExternalCliWorker.init(allocator, std.testing.io, &argv, 5000);
    cli.setMockOutput("[{\"field\":\"source.c\",\"content\":\"int main(){return 0;}\"}]");
    const bk = cli.backend();
    defer bk.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source.c", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "test task",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t1");
    defer sb.deinit();

    const result = try bk.run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try std.testing.expectEqualStrings("source.c", result.artifacts[0].path);
    try std.testing.expectEqualStrings("int main(){return 0;}", result.artifacts[0].content);
}

test "cli worker mock output rejects sandbox escape" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"mock.exe"};
    var cli = ExternalCliWorker.init(allocator, std.testing.io, &argv, 5000);
    cli.setMockOutput("[{\"field\":\"..\\\\outside.txt\",\"content\":\"stolen\"}]");
    const bk = cli.backend();
    defer bk.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source.c", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t2",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "escape test",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t2");
    defer sb.deinit();

    try std.testing.expectError(error.SandboxDenied, bk.run(allocator, task, sb));
}

test "cli worker JSON escapes special characters in task description" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"mock.exe"};
    var cli = ExternalCliWorker.init(allocator, std.testing.io, &argv, 5000);
    cli.setMockOutput("[{\"field\":\"out.c\",\"content\":\"ok\"}]");
    const bk = cli.backend();
    defer bk.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "out.c", .field_type = .string, .required = true };

    // Description with quotes, backslashes, newlines, and unicode-ish chars.
    const task = planner.PlannedTask{
        .id = "t3",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "He said \"hello\" and \\path\\to\\file\nNew line here",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t3");
    defer sb.deinit();

    const result = try bk.run(allocator, task, sb);
    defer result.deinit(allocator);

    // The mock output is valid JSON, so the task succeeds.
    // The key assertion is that spawnAndCollect didn't produce broken JSON.
    // Since we use mock_output, the JSON serialization happens in spawnAndCollect
    // which is only called when mock_output is null. To test the JSON directly,
    // we verify the stringify produces valid JSON by parsing it back.
    try std.testing.expect(result.success);

    // Direct test: build JSON with std.json.Stringify and verify it's valid.
    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    var js: std.json.Stringify = .{ .writer = &json_out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("id");
    try js.write("t3");
    try js.objectField("desc");
    try js.write("He said \"hello\" and \\path\\to\\file\nNew line here");
    try js.objectField("type");
    try js.write("programar_c");
    try js.endObject();

    const json_str = json_out.written();
    // Parse it back to verify it's valid JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.object.count());
    const desc = parsed.value.object.get("desc").?;
    try std.testing.expectEqualStrings("He said \"hello\" and \\path\\to\\file\nNew line here", desc.string);
}

test "T4: cli worker timeout kills hung process and returns error.Timeout" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const allocator = std.testing.allocator;
    // Use a real Io for spawning a real process (env heredado: el hijo
    // necesita PATH como en producción — ver dispatchExternalAgent).
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    // cmd.exe writes "start" to stdout (pipe), then runs a long for loop
    // without writing more. The reader thread reads "start", then blocks on
    // takeDelimiter waiting for the next line. After 500ms, the main thread
    // kills the process → reader unblocks (EOF) → error.Timeout.
    const argv = [_][]const u8{ "cmd.exe", "/c", "echo start&for /L %i in (1,1,10000000) do @ver>nul" };
    var cli = ExternalCliWorker.init(allocator, io, &argv, 500);
    const bk = cli.backend();
    defer bk.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "out.c", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t4-timeout",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "timeout test",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t4-timeout");
    defer sb.deinit();

    // This should return error.Timeout, NOT hang.
    try std.testing.expectError(error.Timeout, bk.run(allocator, task, sb));
}

test "E5.09: spawn hereda el entorno del proceso (PATH visible para shims .cmd)" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: comprueba la expansion de %PATH% con cmd.exe; omitida en Linux");
    const allocator = std.testing.allocator;
    // Mismo contrato que dispatchExternalAgent: el Io de spawn lleva el bloque
    // de entorno global. Con `environ = .empty` el hijo recibiría un bloque
    // vacío y `echo %PATH%` imprimiría el literal sin expandir — que era el
    // fallo en vivo de los shims .cmd (""node"" no se reconoce).
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();

    const argv = [_][]const u8{ "cmd.exe", "/d", "/c", "echo %PATH%" };
    var cli = ExternalCliWorker.init(allocator, io, &argv, 15000);
    cli.stdin_mode = .none;

    const task = planner.PlannedTask{
        .id = "e509-env",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "",
        .contract_fields = &.{},
        .depends_on = &.{},
    };

    var oc = try cli.runCollect(allocator, task);
    defer oc.deinit(allocator);
    try std.testing.expectEqual(@as(?u8, 0), oc.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, oc.output, "%PATH%") == null);
    try std.testing.expect(std.mem.indexOf(u8, oc.output, "Windows") != null);
}

test "CK-SEG-020 external CLI child receives approval guard even with supplied environment" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    var supplied = try @import("platform.zig").environ().createMap(a);
    defer supplied.deinit();
    try supplied.put("DEVAGENTS_COMMAND_CHILD", "0");
    for ([_]?*const std.process.Environ.Map{ null, &supplied }) |environment| {
        const argv = [_][]const u8{ "cmd.exe", "/d", "/c", "set DEVAGENTS_COMMAND_CHILD" };
        var cli = ExternalCliWorker.init(a, threaded.io(), &argv, 10000);
        cli.environ_map = environment;
        cli.stdin_mode = .none;
        const task = planner.PlannedTask{ .id = "seg020-cli", .task_type = .programar_c, .department = "programacion", .description = "", .contract_fields = &.{}, .depends_on = &.{} };
        var result = try cli.runCollect(a, task);
        defer result.deinit(a);
        try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "DEVAGENTS_COMMAND_CHILD=1") != null);
    }
}

test "RELOJ TREE a descendant cannot break away from the session job" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: objeto Job de Windows (breakaway, arbol de la sesion); en Linux la contencion es posix_partial o cgroup v2");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var cli = ExternalCliWorker.init(a, io, &.{ exe, "--headless", "tree-breakaway" }, 30000);
    cli.cwd = path;
    cli.stdin_mode = .none;
    var result = try cli.runCollect(a, .{ .id = "tree", .task_type = .auditar, .department = "auditoria", .description = "", .contract_fields = &.{}, .depends_on = &.{} });
    defer result.deinit(a);
    const allowed = "BREAKAWAY=allowed;pid=";
    if (std.mem.indexOf(u8, result.output, allowed)) |at| {
        // Si el sistema lo permitiera, el descendiente fugado no debe quedar vivo.
        const start = at + allowed.len;
        const end = std.mem.indexOfScalarPos(u8, result.output, start, '\n') orelse result.output.len;
        const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, result.output[start..end], "\r"), 10);
        @import("process_tree.zig").expectTestProcessStopped(pid) catch {};
        return error.JobBreakawayAllowed;
    }
    try std.testing.expect(std.mem.indexOf(u8, result.output, "BREAKAWAY=denied;code=5") != null);
    try std.testing.expect(!result.tree_stuck);
}

test "RELOJ TREE CLI kills detached descendants before success error timeout or cancellation returns" {
    const Cancel = struct {
        flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn line(raw: *anyopaque, text: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.mem.startsWith(u8, text, "DESCENDANT_PID=")) self.flag.store(true, .release);
        }
        fn check(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.flag.load(.acquire);
        }
    };
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    for ([_][]const u8{ "tree-success", "tree-error", "tree-hang", "tree-cancel" }) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(path);
        var cancel: Cancel = .{};
        var cli = ExternalCliWorker.init(a, io, &.{ exe, "--headless", scenario }, if (std.mem.eql(u8, scenario, "tree-hang")) 3000 else 30000);
        cli.cwd = path;
        cli.stdin_mode = .none;
        if (std.mem.eql(u8, scenario, "tree-cancel")) {
            cli.sink = .{ .ctx = &cancel, .callFn = Cancel.line };
            cli.is_cancelled_fn = Cancel.check;
            cli.cancelled_ctx = &cancel;
        }
        var result = try cli.runCollect(a, .{ .id = "tree", .task_type = .auditar, .department = "auditoria", .description = "", .contract_fields = &.{}, .depends_on = &.{} });
        defer result.deinit(a);
        const marker = "DESCENDANT_PID=";
        const start = (std.mem.indexOf(u8, result.output, marker) orelse return error.MissingDescendantId) + marker.len;
        const end = std.mem.indexOfScalarPos(u8, result.output, start, '\n') orelse return error.MissingDescendantId;
        const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, result.output[start..end], "\r"), 10);
        try @import("process_tree.zig").expectTestProcessStopped(pid);
        if (std.mem.eql(u8, scenario, "tree-success")) try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
        if (std.mem.eql(u8, scenario, "tree-error")) try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
        if (std.mem.eql(u8, scenario, "tree-hang")) try std.testing.expect(result.timed_out);
        if (std.mem.eql(u8, scenario, "tree-cancel")) try std.testing.expect(result.cancelled and !result.timed_out and !result.limit_hit);
    }
}

// ── Corrección tras la auditoría (16-oct 04:52), punto 1 (MEDIA) ────────
// El worker CLI comparte el parser pero NO aplicaba la asignación de ruta:
// un `field:"source"` se quedaba con esa etiqueta como destino.
test "CK-MOT-022 r2: el worker CLI asigna la ruta esperada al cuerpo" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"mock.exe"};
    var cli = ExternalCliWorker.init(allocator, std.testing.io, &argv, 5000);
    cli.setMockOutput("[{\"field\":\"source\",\"content\":\"<!DOCTYPE html><html><head><title>Calculadora Web</title></head></html>\"}]");
    const bk = cli.backend();
    defer bk.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t-cli-mot022",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea una calculadora web en un solo archivo index.html.",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-cli-mot022");
    defer sb.deinit();

    const result = try bk.run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try std.testing.expectEqualStrings("index.html", result.artifacts[0].path);
    try std.testing.expect(std.mem.indexOf(u8, result.artifacts[0].content, "Calculadora Web") != null);
}

test "SEC2 custom batch stdlib: argv intacto stdin hostil y expansión rechazada" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const python = try @import("executor.zig").resolveAllowedExeExt(a, "python", ".exe");
    defer a.free(python);
    const script = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "record.py", .{base});
    defer a.free(script);
    const shim = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "record.cmd", .{base});
    defer a.free(shim);
    try tmp.dir.writeFile(io, .{ .sub_path = "record.py", .data = "import sys,json\nwith open('runs.txt','a') as f: f.write('1')\nprint(json.dumps({'argv':sys.argv[1:], 'stdin':sys.stdin.buffer.read().decode('utf-8')}))\n" });
    const body = try std.fmt.allocPrint(a, "@echo off\r\n\"{s}\" \"{s}\" %*\r\n", .{ python, script });
    defer a.free(body);
    try tmp.dir.writeFile(io, .{ .sub_path = "record.cmd", .data = body });
    const args = [_][]const u8{ shim, "& echo injected > marker.txt", "a & | ^ < > ( )", "", "C:\\folder\\file", "niño" };
    var worker = ExternalCliWorker.init(a, io, &args, 15000);
    worker.cwd = base;
    worker.stdin_mode = .prompt_text;
    const prompt = "& | ^ %PATH% ! < > ( ) \"\r\nsegunda línea\n";
    const task: planner.PlannedTask = .{ .id = "SEC2-batch", .task_type = .programar_c, .department = "programacion", .description = prompt, .contract_fields = &.{}, .depends_on = &.{} };
    var result = try worker.runCollect(a, task);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
    try std.testing.expect(!result.timed_out and !result.truncated);
    const Echo = struct { argv: []const []const u8, stdin: []const u8 };
    var echoed = try std.json.parseFromSlice(Echo, a, result.output, .{});
    defer echoed.deinit();
    try std.testing.expectEqualStrings(prompt, echoed.value.stdin);
    try std.testing.expectEqual(args.len - 1, echoed.value.argv.len);
    for (args[1..], echoed.value.argv) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "marker.txt", .{}));
    for ([_][]const u8{ "%PATH%", "!value!", "\"& echo injected", "x\ny", "x\ry", "trail\\", "C:\\folder\\" }) |unsafe| {
        const unsafe_args = [_][]const u8{ shim, unsafe };
        worker.argv = &unsafe_args;
        try std.testing.expectError(error.UnsafeBatchArgument, worker.runCollect(a, task));
    }
    const runs = try tmp.dir.readFileAlloc(io, "runs.txt", a, .limited(16));
    defer a.free(runs);
    try std.testing.expectEqualStrings("1", runs);
}
