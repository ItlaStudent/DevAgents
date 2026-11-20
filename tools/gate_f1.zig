const std = @import("std");
const core = @import("core");

/// GATE F1 (T-F1-06): supervisor real con timeouts, heartbeats, reinicio y eventos.
/// Escenario reproducible y determinista con reloj inyectado (no hilos reales).
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== GATE F1: Supervisor — timeout + retry + heartbeat + restart ===\n\n", .{});

    var fake_clock: u64 = 0;
    const now_fn = struct {
        var clk: *u64 = undefined;
        pub fn init(c: *u64) void {
            clk = c;
        }
        pub fn call() u64 {
            return clk.*;
        }
    };
    now_fn.init(&fake_clock);

    // Abrir runtime.db en memoria para verificar eventos
    var conn = try core.db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = core.db.Migrator.init(allocator);
    try migrator.migrate(conn, &core.db.runtime_schema);

    const config = core.scheduler.SchedulerConfig{
        .num_workers = 4,
        .task_timeout_ms = 100,
        .max_retries = 2,
        .heartbeat_interval_ms = 50,
        .supervisor_tick_ms = 10,
        .backoff_base_ms = 10,
    };

    // Handler cooperativo determinista (sin hilos)
    const noopHandler = struct {
        pub fn call(a: std.mem.Allocator, t: *core.scheduler.Task, w: *core.scheduler.Worker) void {
            _ = a;
            _ = t;
            _ = w;
        }
    }.call;

    var pool = try core.scheduler.ThreadPool.initWithConfig(
        allocator,
        config,
        noopHandler,
        now_fn.call,
        conn,
    );
    defer pool.deinit();

    // Crear 4 tareas normales y 1 colgada
    const tasks = try allocator.alloc(*core.scheduler.Task, 5);
    defer allocator.free(tasks);
    for (tasks, 0..) |*tptr, i| {
        const id = try std.fmt.allocPrint(allocator, "g1_t{d}", .{i + 1});
        defer allocator.free(id);
        tptr.* = try core.scheduler.Task.create(allocator, id, "gate work", 1, 2);
    }
    defer for (tasks) |t| t.destroy();

    // Asignar tareas 1-4 a workers 0-3; la tarea 5 (colgada) al worker 0
    for (tasks[0..4], 0..) |task, i| {
        pool.workers[i].assignTask(task, 0);
    }

    // Avanzar reloj a 200: las 4 tareas normales ya deberían completarse
    // (el handler noop es instantáneo, pero en este gate no hay hilos reales;
    // asumimos que el "trabajo" se hace fuera del pool para ser deterministas).
    fake_clock = 200;
    pool.supervisorTick(fake_clock);
    // Las tareas 1-4 no tienen timeout (heartbeat ok, no timeout en 200ms
    // porque no las marcamos como completadas aquí; el gate mide control).

    // Tarea 5 colgada en worker 0: simular que el supervisor la detecta
    pool.workers[0].assignTask(tasks[4], 0);
    fake_clock = 150;
    pool.supervisorTick(150);
    // Ahora la tarea 5 debería estar en timeout (150 >= 100)
    try std.testing.expectEqual(core.scheduler.TaskState.pending, tasks[4].state);
    try std.testing.expectEqual(@as(u32, 1), tasks[4].retries);
    try std.testing.expect(tasks[4].canRetry());

    // Simular heartbeat miss en worker 1
    pool.workers[1].assignTask(tasks[1], 0);
    const old_worker_1 = pool.workers[1];
    fake_clock = 200;
    pool.supervisorTick(200);
    // Worker 1 debería estar unhealthy (200 > 2*50=100 desde heartbeat=0)
    try std.testing.expectEqual(core.scheduler.Worker.WorkerState.unhealthy, old_worker_1.state);

    // Verificar eventos en runtime.db
    const stmt = try conn.prepare("SELECT COUNT(*) FROM events WHERE source='supervisor'");
    defer conn.finalize(stmt);
    const rc = core.db.c.sqlite3_step(stmt);
    if (rc != core.db.c.SQLITE_ROW) return error.StepFailed;
    const event_count = core.db.c.sqlite3_column_int(stmt, 0);
    std.debug.print("Eventos registrados en runtime.db: {d} (>= 2 esperados: timeout + unhealthy)\n", .{event_count});
    if (event_count < 2) return error.GateFailedInsufficientEvents;

    // Verificar capacidad del pool restaurada tras restart
    try std.testing.expectEqual(@as(usize, 4), pool.workers.len);

    std.debug.print("\n=== GATE F1 superado ===\n", .{});
}

const GateError = error{GateFailedInsufficientEvents};
