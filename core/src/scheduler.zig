const std = @import("std");
const sync = @import("sync.zig");
const ConcurrentQueue = @import("concurrent_queue.zig").ConcurrentQueue;
const db = @import("db.zig");

const Sleep = @import("platform.zig").sleep;
const GetTickCount64 = @import("platform.zig").ticks;

fn sleepMs(ms: u32) void {
    Sleep(ms);
}

/// Configuración del scheduler (FR-003).
pub const SchedulerConfig = struct {
    num_workers: usize = 4,
    task_timeout_ms: u64 = 30_000,
    max_retries: u32 = 3,
    heartbeat_interval_ms: u64 = 1_000,
    supervisor_tick_ms: u64 = 50,
    backoff_base_ms: u64 = 100,
};

pub const TaskState = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

pub const Task = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    description: []const u8,
    priority: u32,
    state: TaskState,
    assigned_worker: ?[]const u8,
    retries: u32,
    max_retries: u32,
    result: ?[]const u8,
    error_msg: ?[]const u8,
    created_at_ms: u64,
    started_at_ms: ?u64,
    completed_at_ms: ?u64,
    deadline_reenqueue_ms: ?u64,
    /// la tarea está en la cola del pool. Evita que `submitAll` la
    /// empuje otra vez mientras espera (antes la ejecutaban dos workers).
    en_cola: std.atomic.Value(bool),
    /// cuántos workers están dentro del handler con ella. Tras un
    /// timeout el supervisor suelta `current_task` pero el hilo sigue
    /// corriendo; mientras esto no sea 0, la tarea no se libera.
    en_manos: std.atomic.Value(u32),

    pub fn create(allocator: std.mem.Allocator, id: []const u8, description: []const u8, priority: u32, max_retries: u32) !*Task {
        const self = try allocator.create(Task);
        errdefer allocator.destroy(self);
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);
        const desc_copy = try allocator.dupe(u8, description);
        errdefer allocator.free(desc_copy);
        self.* = .{
            .allocator = allocator,
            .id = id_copy,
            .description = desc_copy,
            .priority = priority,
            .state = .pending,
            .assigned_worker = null,
            .retries = 0,
            .max_retries = max_retries,
            .result = null,
            .error_msg = null,
            .created_at_ms = 0,
            .started_at_ms = null,
            .completed_at_ms = null,
            .deadline_reenqueue_ms = null,
            .en_cola = std.atomic.Value(bool).init(false),
            .en_manos = std.atomic.Value(u32).init(0),
        };
        return self;
    }

    pub fn isTerminal(self: Task) bool {
        return switch (self.state) {
            .completed, .failed, .cancelled => true,
            .pending, .running => false,
        };
    }

    pub fn destroy(self: *Task) void {
        if (self.result) |r| self.allocator.free(r);
        if (self.error_msg) |e| self.allocator.free(e);
        if (self.assigned_worker) |w| self.allocator.free(w);
        self.allocator.free(self.description);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn setResult(self: *Task, result: []const u8) !void {
        if (self.result) |r| self.allocator.free(r);
        self.result = try self.allocator.dupe(u8, result);
        self.state = .completed;
    }

    pub fn setResultAt(self: *Task, result: []const u8, now: u64) !void {
        try self.setResult(result);
        self.completed_at_ms = now;
    }

    pub fn setError(self: *Task, err_msg: []const u8) !void {
        if (self.error_msg) |e| self.allocator.free(e);
        self.error_msg = try self.allocator.dupe(u8, err_msg);
        self.state = .failed;
        self.retries += 1;
    }

    pub fn setErrorAt(self: *Task, err_msg: []const u8, now: u64) !void {
        try self.setError(err_msg);
        self.completed_at_ms = now;
    }

    pub fn canRetry(self: Task) bool {
        return self.retries < self.max_retries;
    }

    pub fn resetForRetry(self: *Task) void {
        self.state = .pending;
        self.started_at_ms = null;
        self.completed_at_ms = null;
        if (self.assigned_worker) |w| {
            self.allocator.free(w);
            self.assigned_worker = null;
        }
    }

    pub fn clearError(self: *Task) void {
        if (self.error_msg) |e| {
            self.allocator.free(e);
            self.error_msg = null;
        }
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    state: WorkerState,
    current_task: ?*Task,
    thread: ?std.Thread,
    heartbeat: std.atomic.Value(u64),
    heartbeat_at_ms: std.atomic.Value(u64),
    cancel: std.atomic.Value(bool),

    pub const WorkerState = enum {
        idle,
        busy,
        failed,
        stopped,
        unhealthy,
    };

    pub fn create(allocator: std.mem.Allocator, id: []const u8) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);
        self.* = .{
            .allocator = allocator,
            .id = id_copy,
            .state = .idle,
            .current_task = null,
            .thread = null,
            .heartbeat = std.atomic.Value(u64).init(0),
            .heartbeat_at_ms = std.atomic.Value(u64).init(0),
            .cancel = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    pub fn destroy(self: *Worker) void {
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn assignTask(self: *Worker, task: *Task, now: u64) void {
        self.current_task = task;
        self.cancel.store(false, .seq_cst);
        self.heartbeat_at_ms.store(now, .seq_cst);
        self.heartbeat.store(self.heartbeat.load(.seq_cst) +% 1, .seq_cst);
        task.state = .running;
        task.assigned_worker = self.allocator.dupe(u8, self.id) catch null;
        task.started_at_ms = now;
        self.state = .busy;
    }

    pub fn pumpHeartbeat(self: *Worker, now: u64) void {
        self.heartbeat_at_ms.store(now, .seq_cst);
        self.heartbeat.store(self.heartbeat.load(.seq_cst) +% 1, .seq_cst);
    }

    pub fn completeTask(self: *Worker, result: []const u8, now: u64) !void {
        if (self.current_task) |task| {
            try task.setResultAt(result, now);
        }
        self.current_task = null;
        self.state = .idle;
    }

    pub fn failTask(self: *Worker, err_msg: []const u8, now: u64) !void {
        if (self.current_task) |task| {
            try task.setErrorAt(err_msg, now);
        }
        self.current_task = null;
        self.state = .idle;
    }
};

pub const TaskHandler = *const fn (allocator: std.mem.Allocator, task: *Task, worker: *Worker) void;

/// Función de reloj monótono inyectable (default GetTickCount64 en Windows).
pub const NowFn = *const fn () u64;

fn defaultNow() u64 {
    return GetTickCount64();
}

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '"');
    for (input) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    // JSON prohíbe los caracteres de control en crudo. Igual
                    // que shell/host/bridge.cpp: \u00XX en hex minúscula.
                    var esc: [6]u8 = undefined;
                    _ = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c});
                    try buf.appendSlice(allocator, &esc);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
    return buf.toOwnedSlice(allocator);
}

/// Registra un evento en runtime.db (FR-010). §8: parámetros enlazados.
fn logEvent(allocator: std.mem.Allocator, db_conn: ?db.Connection, now: u64, source: []const u8, kind: []const u8, payload_json: []const u8) void {
    defer {
        if (payload_json.len > 0) {
            allocator.free(payload_json);
        }
    }
    const conn = db_conn orelse return;
    const stmt = conn.prepare("INSERT INTO events (ts, source, kind, payload_json) VALUES (?, ?, ?, ?)") catch return;
    defer conn.finalize(stmt);
    _ = db.bindInt(stmt, 1, @intCast(now)) catch return;
    _ = db.bindText(stmt, 2, source) catch return;
    _ = db.bindText(stmt, 3, kind) catch return;
    _ = db.bindText(stmt, 4, payload_json) catch return;
    _ = db.c.sqlite3_step(stmt);
}

/// Calcula backoff exponencial: base * 2^retries (saturado en max_int).
fn backoffMs(base: u64, retries: u32) u64 {
    var result: u64 = base;
    var i: u32 = 0;
    while (i < retries) : (i += 1) {
        if (result > std.math.maxInt(u64) / 2) break;
        result *= 2;
    }
    return result;
}

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: []*Worker,
    detached_workers: std.ArrayList(*Worker),
    task_queue: *ConcurrentQueue(*Task),
    handler: TaskHandler,
    running: bool,
    supervisor_thread: ?std.Thread,
    config: SchedulerConfig,
    now_fn: NowFn,
    db_conn: ?db.Connection,
    mutex: sync.Mutex,

    pub fn init(allocator: std.mem.Allocator, num_workers: usize, handler: TaskHandler) !ThreadPool {
        return try initWithConfig(allocator, .{ .num_workers = num_workers }, handler, defaultNow, null);
    }

    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        config: SchedulerConfig,
        handler: TaskHandler,
        now_fn: NowFn,
        db_conn: ?db.Connection,
    ) !ThreadPool {
        const queue = try allocator.create(ConcurrentQueue(*Task));
        queue.* = ConcurrentQueue(*Task).init(allocator);

        const workers = try allocator.alloc(*Worker, config.num_workers);
        for (workers, 0..) |*wptr, i| {
            const id = try std.fmt.allocPrint(allocator, "w{d}", .{i + 1});
            const worker = try Worker.create(allocator, id);
            allocator.free(id);
            wptr.* = worker;
        }

        return .{
            .allocator = allocator,
            .workers = workers,
            .detached_workers = std.ArrayList(*Worker).empty,
            .task_queue = queue,
            .handler = handler,
            .running = false,
            .supervisor_thread = null,
            .config = config,
            .now_fn = now_fn,
            .db_conn = db_conn,
            .mutex = sync.Mutex.init(),
        };
    }

    pub fn deinit(self: *ThreadPool) void {
        self.stop();
        for (self.workers) |worker| {
            worker.destroy();
        }
        self.allocator.free(self.workers);
        for (self.detached_workers.items) |worker| {
            worker.destroy();
        }
        self.detached_workers.deinit(self.allocator);
        self.task_queue.deinit();
        self.allocator.destroy(self.task_queue);
    }

    fn joinDetachedWorkers(self: *ThreadPool) void {
        while (self.detached_workers.items.len > 0) {
            const worker = self.detached_workers.pop().?;
            if (worker.thread) |t| {
                t.join();
                worker.thread = null;
            }
            worker.destroy();
        }
    }

    pub fn submit(self: *ThreadPool, task: *Task) !void {
        task.en_cola.store(true, .seq_cst);
        self.task_queue.push(task) catch |err| {
            task.en_cola.store(false, .seq_cst);
            return err;
        };
    }

    pub fn start(self: *ThreadPool) !void {
        self.running = true;
        for (self.workers) |worker| {
            const pool_ptr = @as(*ThreadPool, @ptrCast(self));
            worker.thread = try std.Thread.spawn(.{}, workerRoutine, .{ pool_ptr, worker });
        }
        self.supervisor_thread = try std.Thread.spawn(.{}, supervisorLoop, .{self});
    }

    pub fn stop(self: *ThreadPool) void {
        self.running = false;
        if (self.supervisor_thread) |st| {
            st.join();
            self.supervisor_thread = null;
        }
        for (self.workers) |worker| {
            if (worker.thread) |t| {
                t.join();
                worker.thread = null;
            }
        }
        self.joinDetachedWorkers();
    }

    pub fn pending(self: *ThreadPool) usize {
        return self.task_queue.len();
    }

    /// Bucle supervisor: un solo hilo, event loop cada supervisor_tick_ms (FR-009, FR-010).
    fn supervisorLoop(pool: *ThreadPool) void {
        while (pool.running) {
            const now = pool.now_fn();
            pool.supervisorTick(now);
            sleepMs(@intCast(pool.config.supervisor_tick_ms));
        }
    }

    /// Función PURA y testeable: aplica timeout, retry con backoff, heartbeat, reinicio.
    /// Se ejecuta bajo el mutex del pool.
    pub fn supervisorTick(self: *ThreadPool, now: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.workers.len) : (i += 1) {
            const worker = self.workers[i];

            // Heartbeat check (FR-009): worker must have pumped within 2x interval
            if (worker.state == .busy) {
                const last_hb = worker.heartbeat_at_ms.load(.seq_cst);
                if (now > last_hb and (now - last_hb) > 2 * self.config.heartbeat_interval_ms) {
                    worker.state = .unhealthy;
                    const payload = self.buildEventPayload("{\"worker\":", worker.id, ",\"reason\":\"heartbeat_missed\"}") catch "";
                    logEvent(self.allocator, self.db_conn, now, "supervisor", "unhealthy", payload);
                    // Reiniciar: marcar tarea como timeout y reintentar
                    if (worker.current_task) |task| {
                        self.handleTaskFailure(worker, task, now, "heartbeat_missed") catch {};
                    }
                    self.replaceWorker(i, now);
                    continue;
                }
            }

            // Timeout check (FR-004 / SC-002)
            if (worker.state == .busy) {
                if (worker.current_task) |task| {
                    if (task.started_at_ms) |started| {
                        if (now >= started and (now - started) >= self.config.task_timeout_ms) {
                            worker.cancel.store(true, .seq_cst);
                            self.handleTaskFailure(worker, task, now, "timeout") catch {};
                            worker.state = .idle;
                            worker.current_task = null;
                            continue;
                        }
                    }
                }
            }
        }
    }

    fn buildEventPayload(self: *ThreadPool, prefix: []const u8, id: []const u8, suffix: []const u8) ![]u8 {
        const esc = try escapeJsonString(self.allocator, id);
        defer self.allocator.free(esc);
        return std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ prefix, esc, suffix });
    }

    fn handleTaskFailure(self: *ThreadPool, worker: *Worker, task: *Task, now: u64, reason: []const u8) !void {
        task.setErrorAt(reason, now) catch {};
        const esc_id = try escapeJsonString(self.allocator, task.id);
        defer self.allocator.free(esc_id);
        const esc_wid = try escapeJsonString(self.allocator, worker.id);
        defer self.allocator.free(esc_wid);
        const esc_reason = try escapeJsonString(self.allocator, reason);
        defer self.allocator.free(esc_reason);
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"task\":{s},\"worker\":{s},\"reason\":{s}}}", .{ esc_id, esc_wid, esc_reason });
        defer self.allocator.free(payload);
        logEvent(self.allocator, self.db_conn, now, "supervisor", "timeout", self.allocator.dupe(u8, payload) catch "");
        if (task.canRetry()) {
            const backoff = backoffMs(self.config.backoff_base_ms, task.retries);
            task.deadline_reenqueue_ms = now + backoff;
            task.resetForRetry();
            task.clearError();
            const retry_payload = try std.fmt.allocPrint(self.allocator, "{{\"task\":{s},\"retries\":{d},\"backoff_ms\":{d}}}", .{ esc_id, task.retries, backoff });
            defer self.allocator.free(retry_payload);
            logEvent(self.allocator, self.db_conn, now, "supervisor", "retry", self.allocator.dupe(u8, retry_payload) catch "");
            try self.submit(task);
        } else {
            task.deadline_reenqueue_ms = null;
            const esc_payload = try std.fmt.allocPrint(self.allocator, "{{\"task\":{s},\"retries\":{d},\"reason\":{s}}}", .{ esc_id, task.retries, esc_reason });
            defer self.allocator.free(esc_payload);
            logEvent(self.allocator, self.db_conn, now, "supervisor", "escalated", self.allocator.dupe(u8, esc_payload) catch "");
        }
    }

    /// "Reiniciar" worker in-process: reemplazar el worker atascado con uno nuevo (FR-009).
    /// El hilo viejo se detacha (abandona) porque no se puede matar con seguridad.
    fn replaceWorker(self: *ThreadPool, idx: usize, now: u64) void {
        const old = self.workers[idx];
        const esc_id = escapeJsonString(self.allocator, old.id) catch return;
        defer self.allocator.free(esc_id);
        const payload = std.fmt.allocPrint(self.allocator, "{{\"worker\":{s},\"reason\":\"unhealthy\"}}", .{esc_id}) catch return;
        defer self.allocator.free(payload);
        logEvent(self.allocator, self.db_conn, now, "supervisor", "restart", self.allocator.dupe(u8, payload) catch "");
        const new_id = std.fmt.allocPrint(self.allocator, "w{d}_r{d}", .{ idx + 1, now }) catch return;
        defer self.allocator.free(new_id);
        const replacement = Worker.create(self.allocator, new_id) catch return;
        replacement.thread = std.Thread.spawn(.{}, workerRoutine, .{ self, replacement }) catch null;
        if (replacement.thread == null) {
            replacement.destroy();
            return;
        }
        self.detached_workers.append(self.allocator, old) catch {};
        self.workers[idx] = replacement;
    }

    fn workerRoutine(pool: *ThreadPool, worker: *Worker) void {
        while (pool.running) {
            const task = pool.task_queue.pop();
            if (task) |t| {
                // Filtro de backoff: si la tarea tiene deadline_reenqueue_ms futuro, reinsertar.
                if (t.deadline_reenqueue_ms) |deadline| {
                    if (deadline > pool.now_fn()) {
                        pool.task_queue.push(t) catch {};
                        sleepMs(1);
                        continue;
                    }
                    t.deadline_reenqueue_ms = null;
                }
                const now = pool.now_fn();
                pool.mutex.lock();
                // Cancelada mientras esperaba en la cola: no se ejecuta.
                if (t.state == .cancelled) {
                    t.en_cola.store(false, .seq_cst);
                    pool.mutex.unlock();
                    continue;
                }
                // Primero en_manos y luego en_cola: quien vea en_cola=false ya
                // ve la tarea en manos de este worker.
                _ = t.en_manos.fetchAdd(1, .seq_cst);
                t.en_cola.store(false, .seq_cst);
                worker.assignTask(t, now);
                pool.mutex.unlock();
                // Pump heartbeat before handler (covers short tasks)
                worker.pumpHeartbeat(now);
                pool.handler(pool.allocator, t, worker);
                if (worker.cancel.load(.seq_cst)) {
                    // Cancelación cooperativa: el handler debió parar.
                }
                pool.mutex.lock();
                worker.current_task = null;
                worker.state = .idle;
                _ = t.en_manos.fetchSub(1, .seq_cst);
                pool.mutex.unlock();
            } else {
                sleepMs(1);
            }
        }
        pool.mutex.lock();
        worker.state = .stopped;
        pool.mutex.unlock();
    }
};

/// `tasks` guarda solo las tareas vivas. Las terminales (completada,
/// fallida, cancelada) que ya no están en la cola ni en manos de un worker se
/// liberan en el siguiente `submitAll`, y quedan contadas en `retiradas`. Antes
/// se retenían hasta `deinit`: +636 MB en el soak de 20 min (E3.19), y cada
/// recuento recorría todas las tareas de la historia.
/// Consecuencia para quien llama: tras `submitAll`, un puntero a una tarea ya
/// terminada puede no ser válido. Su resultado se lee antes.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(*Task),
    workers: std.ArrayList(*Worker),
    pool: *ThreadPool,
    mutex: sync.Mutex,
    running: bool,
    retiradas: Retiradas = .{},

    pub const Retiradas = struct {
        completadas: usize = 0,
        fallidas: usize = 0,
        canceladas: usize = 0,

        pub fn total(self: Retiradas) usize {
            return self.completadas + self.fallidas + self.canceladas;
        }
    };

    pub fn init(allocator: std.mem.Allocator, handler: TaskHandler) !Scheduler {
        return try initWithConfig(allocator, .{}, handler, defaultNow, null);
    }

    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        config: SchedulerConfig,
        handler: TaskHandler,
        now_fn: NowFn,
        db_conn: ?db.Connection,
    ) !Scheduler {
        const pool = try allocator.create(ThreadPool);
        pool.* = try ThreadPool.initWithConfig(allocator, config, handler, now_fn, db_conn);
        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(*Task).empty,
            .workers = std.ArrayList(*Worker).empty,
            .pool = pool,
            .mutex = sync.Mutex.init(),
            .running = false,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.stop();
        for (self.tasks.items) |task| {
            task.destroy();
        }
        self.tasks.deinit(self.allocator);
        for (self.workers.items) |worker| {
            worker.destroy();
        }
        self.workers.deinit(self.allocator);
        self.pool.deinit();
        self.allocator.destroy(self.pool);
    }

    pub fn addWorker(self: *Scheduler, worker: *Worker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.workers.append(self.allocator, worker);
    }

    pub fn enqueueTask(self: *Scheduler, task: *Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tasks.append(self.allocator, task);
    }

    pub fn start(self: *Scheduler) !void {
        self.running = true;
        try self.pool.start();
    }

    pub fn stop(self: *Scheduler) void {
        self.running = false;
        self.pool.stop();
    }

    /// Libera las tareas terminales que nadie más toca y las cuenta. Exige
    /// `self.mutex`; toma el del pool para que ni el supervisor ni un worker
    /// estén mirando la tarea mientras se decide.
    fn reapLocked(self: *Scheduler) usize {
        self.pool.mutex.lock();
        defer self.pool.mutex.unlock();
        var quedan: usize = 0;
        var liberadas: usize = 0;
        for (self.tasks.items) |task| {
            if (self.esLiberable(task)) {
                switch (task.state) {
                    .completed => self.retiradas.completadas += 1,
                    .failed => self.retiradas.fallidas += 1,
                    .cancelled => self.retiradas.canceladas += 1,
                    .pending, .running => unreachable,
                }
                task.destroy();
                liberadas += 1;
            } else {
                self.tasks.items[quedan] = task;
                quedan += 1;
            }
        }
        self.tasks.shrinkRetainingCapacity(quedan);
        return liberadas;
    }

    fn esLiberable(self: *Scheduler, task: *Task) bool {
        if (!task.isTerminal()) return false;
        // Orden: en_cola antes que en_manos (el worker los escribe al revés).
        if (task.en_cola.load(.seq_cst)) return false;
        if (task.en_manos.load(.seq_cst) != 0) return false;
        for (self.pool.workers) |w| {
            if (w.current_task == task) return false;
        }
        return true;
    }

    /// Libera ya las tareas terminadas (lo mismo que hace `submitAll`).
    pub fn reapTerminal(self: *Scheduler) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.reapLocked();
    }

    pub fn submitAll(self: *Scheduler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapLocked();
        // Bajo el mutex del pool: el supervisor re-encola reintentos con él
        // tomado, así que aquí no se ve una tarea «pendiente y fuera de la
        // cola» a medio camino de volver a ella.
        self.pool.mutex.lock();
        defer self.pool.mutex.unlock();
        for (self.tasks.items) |task| {
            if (task.state == .pending and !task.en_cola.load(.seq_cst)) {
                try self.pool.submit(task);
            }
        }
    }

    pub fn runAll(self: *Scheduler) void {
        self.submitAll() catch return;
        while (self.running) {
            const pending = self.getPendingTasks();
            const queue_len = self.pool.pending();
            if (pending == 0 and queue_len == 0) break;
            sleepMs(5);
        }
    }

    pub fn getCompletedTasks(self: *Scheduler) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = self.retiradas.completadas;
        for (self.tasks.items) |task| {
            if (task.state == .completed) count += 1;
        }
        return count;
    }

    pub fn getFailedTasks(self: *Scheduler) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = self.retiradas.fallidas;
        for (self.tasks.items) |task| {
            if (task.state == .failed) count += 1;
        }
        return count;
    }

    pub fn getPendingTasks(self: *Scheduler) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.tasks.items) |task| {
            if (task.state == .pending) count += 1;
        }
        return count;
    }

    pub fn cancelAllPending(self: *Scheduler) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Con el mutex del pool: un worker decide bajo él si ejecuta la tarea.
        self.pool.mutex.lock();
        defer self.pool.mutex.unlock();
        for (self.tasks.items) |task| {
            if (task.state == .pending) {
                task.state = .cancelled;
            }
        }
    }

    pub fn report(self: *Scheduler, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        const append = struct {
            fn do(list: *std.ArrayList(u8), alloc: std.mem.Allocator, str: []const u8) !void {
                try list.appendSlice(alloc, str);
            }
        }.do;
        try append(&buf, allocator, "Scheduler Report\n");
        try append(&buf, allocator, "==================\n");
        try append(&buf, allocator, "Pool workers: ");
        const wcount = try std.fmt.allocPrint(allocator, "{d}\n", .{self.pool.workers.len});
        defer allocator.free(wcount);
        try append(&buf, allocator, wcount);
        const total = try std.fmt.allocPrint(allocator, "Total tasks: {d}\n", .{self.tasks.items.len + self.retiradas.total()});
        defer allocator.free(total);
        try append(&buf, allocator, total);
        var completed_count: usize = self.retiradas.completadas;
        var failed_count: usize = self.retiradas.fallidas;
        var pending_count: usize = 0;
        var cancelled_count: usize = self.retiradas.canceladas;
        for (self.tasks.items) |task| {
            switch (task.state) {
                .completed => completed_count += 1,
                .failed => failed_count += 1,
                .pending => pending_count += 1,
                .cancelled => cancelled_count += 1,
                else => {},
            }
        }
        const completed = try std.fmt.allocPrint(allocator, "Completed: {d}\n", .{completed_count});
        defer allocator.free(completed);
        try append(&buf, allocator, completed);
        const failed = try std.fmt.allocPrint(allocator, "Failed: {d}\n", .{failed_count});
        defer allocator.free(failed);
        try append(&buf, allocator, failed);
        const pending = try std.fmt.allocPrint(allocator, "Pending: {d}\n", .{pending_count});
        defer allocator.free(pending);
        try append(&buf, allocator, pending);
        const cancelled = try std.fmt.allocPrint(allocator, "Cancelled: {d}\n", .{cancelled_count});
        defer allocator.free(cancelled);
        try append(&buf, allocator, cancelled);
        const retired = try std.fmt.allocPrint(allocator, "Retired (freed): {d}\n", .{self.retiradas.total()});
        defer allocator.free(retired);
        try append(&buf, allocator, retired);
        try append(&buf, allocator, "\nTask Details:\n");
        for (self.tasks.items) |task| {
            const worker_str = if (task.assigned_worker) |w| w else "none";
            const line = try std.fmt.allocPrint(allocator, "  {s}: {s} (state={s}, worker={s}, retries={d})\n", .{
                task.id,
                task.description,
                @tagName(task.state),
                worker_str,
                task.retries,
            });
            defer allocator.free(line);
            try append(&buf, allocator, line);
        }
        return buf.toOwnedSlice(allocator);
    }
};

pub fn defaultWorkHandler(allocator: std.mem.Allocator, task: *Task, worker: *Worker) void {
    _ = worker;
    const result = std.fmt.allocPrint(allocator, "completed: {s}", .{task.id}) catch {
        task.setError("alloc failed") catch {};
        return;
    };
    defer allocator.free(result);
    task.setResult(result) catch {
        task.setError("setResult failed") catch {};
    };
}

test "task lifecycle" {
    const allocator = std.testing.allocator;
    const task = try Task.create(allocator, "t1", "do work", 10, 3);
    defer task.destroy();

    try std.testing.expectEqualStrings("t1", task.id);
    try std.testing.expectEqual(TaskState.pending, task.state);
    try std.testing.expectEqual(@as(u32, 0), task.retries);
    try std.testing.expect(task.canRetry());

    try task.setResult("done");
    try std.testing.expectEqual(TaskState.completed, task.state);
    try std.testing.expectEqualStrings("done", task.result.?);
}

test "task retry" {
    const allocator = std.testing.allocator;
    const task = try Task.create(allocator, "t2", "fail me", 5, 2);
    defer task.destroy();

    try task.setError("boom");
    try std.testing.expectEqual(@as(u32, 1), task.retries);
    try std.testing.expect(task.canRetry());

    task.resetForRetry();
    try std.testing.expectEqual(TaskState.pending, task.state);
    try std.testing.expectEqual(@as(u32, 1), task.retries);

    try task.setError("boom again");
    try std.testing.expectEqual(@as(u32, 2), task.retries);
    try std.testing.expect(!task.canRetry());
}

test "worker assign and complete" {
    const allocator = std.testing.allocator;
    const task = try Task.create(allocator, "t3", "quick", 1, 0);
    defer task.destroy();
    const worker = try Worker.create(allocator, "w1");
    defer worker.destroy();

    worker.assignTask(task, 0);
    try std.testing.expectEqual(Worker.WorkerState.busy, worker.state);
    try std.testing.expectEqual(TaskState.running, task.state);

    try worker.completeTask("ok", 0);
    try std.testing.expectEqual(Worker.WorkerState.idle, worker.state);
    try std.testing.expectEqual(TaskState.completed, task.state);
    try std.testing.expectEqualStrings("ok", task.result.?);
    try std.testing.expectEqual(@as(?u64, 0), task.completed_at_ms);
}

test "scheduler enqueue and dispatch with thread pool" {
    const allocator = std.testing.allocator;
    var scheduler = try Scheduler.init(allocator, defaultWorkHandler);
    defer scheduler.deinit();

    const task = try Task.create(allocator, "t4", "test", 1, 0);
    try scheduler.enqueueTask(task);

    try scheduler.start();
    scheduler.runAll();
    scheduler.stop();

    try std.testing.expectEqual(@as(usize, 1), scheduler.getCompletedTasks());
}

test "scheduler multiple tasks in parallel" {
    const allocator = std.testing.allocator;
    var scheduler = try Scheduler.init(allocator, defaultWorkHandler);
    defer scheduler.deinit();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const id = try std.fmt.allocPrint(allocator, "t{d}", .{i + 1});
        defer allocator.free(id);
        const task = try Task.create(allocator, id, "parallel work", 1, 0);
        try scheduler.enqueueTask(task);
    }

    try scheduler.start();
    scheduler.runAll();
    scheduler.stop();

    try std.testing.expectEqual(@as(usize, 8), scheduler.getCompletedTasks());
    try std.testing.expectEqual(@as(usize, 0), scheduler.getPendingTasks());
}

test "scheduler report format" {
    const allocator = std.testing.allocator;
    var scheduler = try Scheduler.init(allocator, defaultWorkHandler);
    defer scheduler.deinit();

    const task = try Task.create(allocator, "r1", "report", 1, 0);
    try scheduler.enqueueTask(task);

    try scheduler.start();
    scheduler.runAll();
    scheduler.stop();

    const rep = try scheduler.report(allocator);
    defer allocator.free(rep);
    try std.testing.expect(std.mem.indexOf(u8, rep, "Completed: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "r1") != null);
}

test "cancel pending tasks" {
    const allocator = std.testing.allocator;
    var scheduler = try Scheduler.init(allocator, defaultWorkHandler);
    defer scheduler.deinit();

    const task = try Task.create(allocator, "c1", "cancel me", 1, 0);
    try scheduler.enqueueTask(task);

    scheduler.cancelAllPending();
    // Tras cancelar, la tarea pasa a .cancelled, por lo que ya NO cuenta como pendiente.
    try std.testing.expectEqual(@as(usize, 0), scheduler.getPendingTasks());
    const t = scheduler.tasks.items[0];
    try std.testing.expectEqual(TaskState.cancelled, t.state);
}

// ── retención de tareas y doble despacho ──────────────────────────

var e81_ejecuciones = std.atomic.Value(usize).init(0);

fn e81Handler(allocator: std.mem.Allocator, task: *Task, worker: *Worker) void {
    _ = e81_ejecuciones.fetchAdd(1, .seq_cst);
    defaultWorkHandler(allocator, task, worker);
}

fn e81Espera(scheduler: *Scheduler) void {
    var ms: usize = 0;
    while (ms < 10_000) : (ms += 1) {
        if (scheduler.getPendingTasks() == 0 and scheduler.pool.pending() == 0) {
            // Lo último que suelta un worker es en_manos: esperar a que no quede nada vivo.
            scheduler.mutex.lock();
            var vivas: usize = 0;
            for (scheduler.tasks.items) |t| {
                if (!t.isTerminal() or t.en_manos.load(.seq_cst) != 0) vivas += 1;
            }
            scheduler.mutex.unlock();
            if (vivas == 0) return;
        }
        sleepMs(1);
    }
}

test "E-81: submitAll no vuelve a encolar una tarea que ya espera en la cola" {
    const allocator = std.testing.allocator;
    var scheduler = try Scheduler.init(allocator, defaultWorkHandler);
    defer scheduler.deinit();

    for (0..3) |i| {
        const id = try std.fmt.allocPrint(allocator, "dup{d}", .{i});
        defer allocator.free(id);
        try scheduler.enqueueTask(try Task.create(allocator, id, "una vez", 1, 0));
    }
    // Sin arrancar el pool: todo lo que se empuje se queda en la cola.
    try scheduler.submitAll();
    try scheduler.submitAll();
    try scheduler.submitAll();
    try std.testing.expectEqual(@as(usize, 3), scheduler.pool.pending());
}

test "E-81: cada tarea se ejecuta una sola vez aunque submitAll se llame en bucle" {
    const allocator = std.testing.allocator;
    e81_ejecuciones.store(0, .seq_cst);
    var scheduler = try Scheduler.initWithConfig(allocator, .{ .num_workers = 4 }, e81Handler, defaultNow, null);
    defer scheduler.deinit();

    for (0..40) |i| {
        const id = try std.fmt.allocPrint(allocator, "once{d}", .{i});
        defer allocator.free(id);
        try scheduler.enqueueTask(try Task.create(allocator, id, "una vez", 1, 0));
    }
    for (0..20) |_| try scheduler.submitAll();
    try scheduler.start();
    for (0..20) |_| try scheduler.submitAll();
    e81Espera(&scheduler);
    scheduler.stop();

    try std.testing.expectEqual(@as(usize, 40), e81_ejecuciones.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 40), scheduler.getCompletedTasks());
}

test "E-81: las tareas terminadas se liberan y el recuento se conserva" {
    const allocator = std.testing.allocator;
    var scheduler = try Scheduler.initWithConfig(allocator, .{ .num_workers = 4 }, defaultWorkHandler, defaultNow, null);
    defer scheduler.deinit();
    try scheduler.start();

    var enviadas: usize = 0;
    var max_vivas: usize = 0;
    for (0..50) |_| {
        for (0..20) |_| {
            const id = try std.fmt.allocPrint(allocator, "r{d}", .{enviadas});
            defer allocator.free(id);
            try scheduler.enqueueTask(try Task.create(allocator, id, "ronda", 1, 0));
            enviadas += 1;
        }
        try scheduler.submitAll();
        max_vivas = @max(max_vivas, scheduler.tasks.items.len);
        e81Espera(&scheduler);
    }
    _ = scheduler.reapTerminal();
    scheduler.stop();

    // 1000 tareas en total y nunca más de dos rondas vivas a la vez.
    try std.testing.expect(max_vivas <= 40);
    try std.testing.expectEqual(@as(usize, 0), scheduler.tasks.items.len);
    try std.testing.expectEqual(@as(usize, 1000), scheduler.getCompletedTasks());
    try std.testing.expectEqual(@as(usize, 1000), scheduler.retiradas.completadas);

    const rep = try scheduler.report(allocator);
    defer allocator.free(rep);
    try std.testing.expect(std.mem.indexOf(u8, rep, "Total tasks: 1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "Completed: 1000") != null);
}

test "E-81: una tarea cancelada mientras espera en la cola no se ejecuta" {
    const allocator = std.testing.allocator;
    e81_ejecuciones.store(0, .seq_cst);
    var scheduler = try Scheduler.initWithConfig(allocator, .{ .num_workers = 2 }, e81Handler, defaultNow, null);
    defer scheduler.deinit();

    try scheduler.enqueueTask(try Task.create(allocator, "c-cola", "cancelada en cola", 1, 0));
    try scheduler.submitAll();
    scheduler.cancelAllPending();
    try scheduler.start();
    var ms: usize = 0;
    while (scheduler.pool.pending() > 0 and ms < 5_000) : (ms += 1) sleepMs(1);
    sleepMs(20);
    scheduler.stop();

    try std.testing.expectEqual(@as(usize, 0), e81_ejecuciones.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), scheduler.reapTerminal());
    try std.testing.expectEqual(@as(usize, 1), scheduler.retiradas.canceladas);
}

// ── Tests deterministas del supervisor (reloj inyectado) ────────────────

var fake_clock: u64 = 0;
fn fakeNow() u64 {
    return fake_clock;
}

test "supervisorTick timeout retries with backoff then escalates" {
    const allocator = std.testing.allocator;
    fake_clock = 0;

    const config = SchedulerConfig{
        .num_workers = 1,
        .task_timeout_ms = 100,
        .max_retries = 3,
        .heartbeat_interval_ms = 1000,
        .supervisor_tick_ms = 50,
        .backoff_base_ms = 10,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, defaultWorkHandler, fakeNow, null);
    defer pool.deinit();

    const task = try Task.create(allocator, "to1", "timeout test", 1, 3);
    defer task.destroy();

    // Simular tarea asignada al worker hace mucho tiempo
    pool.workers[0].assignTask(task, 0);

    // Tick en now=0: todavía dentro del timeout (0 < 100)
    pool.supervisorTick(0);
    try std.testing.expectEqual(TaskState.running, task.state);

    // Tick en now=100: cruza el deadline → timeout, reintenta (retries=1 < 3)
    pool.supervisorTick(100);
    try std.testing.expectEqual(TaskState.pending, task.state);
    try std.testing.expectEqual(@as(u32, 1), task.retries);
    try std.testing.expectEqual(@as(?u64, 120), task.deadline_reenqueue_ms); // backoffMs(10,1)=20; 100+20=120

    // Worker vuelve a idle después de timeout
    try std.testing.expectEqual(Worker.WorkerState.idle, pool.workers[0].state);

    // Segunda asignación (reenqueue ahora que deadline expiró)
    fake_clock = 120;
    pool.workers[0].assignTask(task, 120);

    // Tick en now=220: segundo timeout, reintenta (retries=2 < 3)
    pool.supervisorTick(220);
    try std.testing.expectEqual(TaskState.pending, task.state);
    try std.testing.expectEqual(@as(u32, 2), task.retries);
    try std.testing.expectEqual(@as(?u64, 260), task.deadline_reenqueue_ms); // backoffMs(10,2)=40; 220+40=260

    // Tercera vez → max_retries agotado → escalada (retries=3, 3 < 3 es falso)
    fake_clock = 260;
    pool.workers[0].assignTask(task, 260);
    pool.supervisorTick(360);
    try std.testing.expectEqual(TaskState.failed, task.state);
    try std.testing.expectEqual(@as(u32, 3), task.retries);
    try std.testing.expect(!task.canRetry());
    try std.testing.expectEqual(@as(?u64, null), task.deadline_reenqueue_ms);
}

test "supervisorTick heartbeat miss marks unhealthy and replaces worker" {
    const allocator = std.testing.allocator;
    fake_clock = 0;

    const config = SchedulerConfig{
        .num_workers = 2,
        .task_timeout_ms = 10_000,
        .max_retries = 2,
        .heartbeat_interval_ms = 100,
        .supervisor_tick_ms = 50,
        .backoff_base_ms = 10,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, defaultWorkHandler, fakeNow, null);
    defer pool.deinit();

    const task = try Task.create(allocator, "hb1", "heartbeat test", 1, 2);
    defer task.destroy();

    pool.workers[0].assignTask(task, 0);

    // Tick en now=50: todavía dentro del doble intervalo (0 + 200)
    pool.supervisorTick(50);
    try std.testing.expectEqual(Worker.WorkerState.busy, pool.workers[0].state);

    // Guardar referencia al worker original antes del reemplazo
    const old_worker = pool.workers[0];

    // Tick en now=250: heartbeat faltante (> 200ms sin pump)
    pool.supervisorTick(250);
    try std.testing.expectEqual(Worker.WorkerState.unhealthy, old_worker.state);

    // El pool no arrancó: el hilo nuevo pasa de idle a stopped. Unirlo antes
    // de leer su estado evita depender de cuál de los dos hilos recibe CPU.
    try std.testing.expectEqual(config.num_workers, pool.workers.len);
    const replacement = pool.workers[0];
    try std.testing.expect(replacement != old_worker);
    try std.testing.expectEqualStrings("w1_r250", replacement.id);
    const thread = replacement.thread orelse return error.NoAparecioElHiloNuevo;
    thread.join();
    replacement.thread = null;
    try std.testing.expectEqual(Worker.WorkerState.stopped, replacement.state);
    try std.testing.expectEqual(@as(usize, 1), pool.detached_workers.items.len);
    try std.testing.expectEqual(old_worker, pool.detached_workers.items[0]);
    try std.testing.expectEqual(TaskState.pending, task.state);
    try std.testing.expectEqual(@as(u32, 1), task.retries);
    try std.testing.expectEqual(@as(?u64, 270), task.deadline_reenqueue_ms);
    try std.testing.expectEqual(@as(usize, 1), pool.pending());
}

test "supervisorTick respects num_workers and max_retries" {
    const allocator = std.testing.allocator;
    fake_clock = 0;

    const config = SchedulerConfig{
        .num_workers = 3,
        .task_timeout_ms = 50,
        .max_retries = 2,
        .heartbeat_interval_ms = 1000,
        .supervisor_tick_ms = 50,
        .backoff_base_ms = 10,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, defaultWorkHandler, fakeNow, null);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 3), pool.workers.len);

    const task = try Task.create(allocator, "lim1", "limits", 1, 2);
    defer task.destroy();
    pool.workers[0].assignTask(task, 0);

    // Primer timeout: retries=1 < 2 → re-encola
    pool.supervisorTick(60);
    try std.testing.expectEqual(TaskState.pending, task.state);
    try std.testing.expect(task.canRetry());

    // Segundo timeout: retries=2, 2 < 2 es falso → escalada
    fake_clock = 10;
    pool.workers[0].assignTask(task, 10);
    pool.supervisorTick(70);
    try std.testing.expectEqual(TaskState.failed, task.state);
    try std.testing.expect(!task.canRetry());
}

test "supervisor event logging inserts row in runtime.db" {
    const allocator = std.testing.allocator;
    fake_clock = 0;

    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    const config = SchedulerConfig{
        .num_workers = 1,
        .task_timeout_ms = 50,
        .max_retries = 0,
        .heartbeat_interval_ms = 1000,
        .supervisor_tick_ms = 50,
        .backoff_base_ms = 10,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, defaultWorkHandler, fakeNow, conn);
    defer pool.deinit();

    const task = try Task.create(allocator, "ev1", "event test", 1, 0);
    defer task.destroy();
    pool.workers[0].assignTask(task, 0);

    pool.supervisorTick(60);

    const stmt = try conn.prepare("SELECT COUNT(*) FROM events WHERE kind='timeout'");
    defer conn.finalize(stmt);
    const rc = db.c.sqlite3_step(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, rc);
    const count = db.c.sqlite3_column_int(stmt, 0);
    try std.testing.expect(count >= 1);
}

// ── Test de integración con hilos reales ────────────────────────────────

var hang_entered: std.Io.Event = .unset;
var hang_release: std.Io.Event = .unset;
var hang_clock: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var hang_io: std.Io = undefined;

fn hangingNow() u64 {
    return hang_clock.load(.acquire);
}

fn hangingHandler(allocator: std.mem.Allocator, task: *Task, worker: *Worker) void {
    _ = allocator;
    _ = task;
    worker.pumpHeartbeat(hangingNow());
    hang_entered.set(hang_io);
    hang_release.waitUncancelable(hang_io);
}

test "integration: real threads with cooperative timeout and pool survives" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    hang_io = threaded.io();
    hang_entered = .unset;
    hang_release = .unset;
    hang_clock.store(0, .release);

    const config = SchedulerConfig{
        .num_workers = 2,
        .task_timeout_ms = 80,
        .max_retries = 0,
        .heartbeat_interval_ms = 500,
        .supervisor_tick_ms = 20,
        .backoff_base_ms = 10,
    };

    var scheduler = try Scheduler.initWithConfig(allocator, config, hangingHandler, hangingNow, null);
    defer scheduler.deinit();
    defer hang_release.set(hang_io);

    const task = try Task.create(allocator, "hang1", "hang test", 1, 0);
    try scheduler.enqueueTask(task);

    try scheduler.start();
    try scheduler.submitAll();
    // El reloj avanza sólo después de que el handler real entre. El timeout
    // sigue siendo 80 ms; la máquina ocupada no decide cuándo se inspecciona.
    hang_entered.waitUncancelable(hang_io);
    hang_clock.store(80, .release);
    scheduler.pool.supervisorTick(80);
    // fallida por timeout pero con el handler aún corriendo — no se libera.
    try std.testing.expectEqual(TaskState.failed, task.state);
    try std.testing.expectEqual(@as(usize, 0), scheduler.reapTerminal());
    try std.testing.expectEqual(@as(usize, 1), scheduler.tasks.items.len);
    hang_release.set(hang_io);
    scheduler.stop();

    try std.testing.expectEqual(TaskState.failed, task.state);
    try std.testing.expectEqualStrings("timeout", task.error_msg.?);
    // Pool sigue vivo: al menos 2 workers operativos
    try std.testing.expectEqual(@as(usize, 2), scheduler.pool.workers.len);
}

// ── Tests de cierre de carreras ─────────────────────────────────────────

/// Handler largo que late cada iteración para mantenerse sano.
fn longHealthyHandler(allocator: std.mem.Allocator, task: *Task, worker: *Worker) void {
    _ = allocator;
    _ = task;
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        worker.pumpHeartbeat(defaultNow());
        sleepMs(1);
    }
}

test "healthy long task survives beyond 2x heartbeat interval" {
    const allocator = std.testing.allocator;
    fake_clock = 0;

    const config = SchedulerConfig{
        .num_workers = 1,
        .task_timeout_ms = 5000,
        .max_retries = 0,
        .heartbeat_interval_ms = 10,
        .supervisor_tick_ms = 5,
        .backoff_base_ms = 1,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, longHealthyHandler, fakeNow, null);
    defer pool.deinit();

    const task = try Task.create(allocator, "lh1", "long healthy", 1, 0);
    defer task.destroy();

    pool.workers[0].assignTask(task, 0);

    // Simular que el handler late (determinista, sin hilos reales)
    pool.workers[0].pumpHeartbeat(25);
    pool.workers[0].pumpHeartbeat(50);

    // Avanzamos el reloj 50ms (5× heartbeat_interval) pero estamos dentro del task_timeout.
    fake_clock = 50;
    pool.supervisorTick(50);

    // Worker sigue busy (no unhealthy), tarea sigue running
    try std.testing.expectEqual(Worker.WorkerState.busy, pool.workers[0].state);
    try std.testing.expectEqual(TaskState.running, task.state);
    try std.testing.expectEqual(@as(?[]const u8, null), task.error_msg);
}

test "worker state mutation is mutex-protected under supervisor and worker" {
    const allocator = std.testing.allocator;
    fake_clock = 0;

    const config = SchedulerConfig{
        .num_workers = 1,
        .task_timeout_ms = 30_000,
        .max_retries = 0,
        .heartbeat_interval_ms = 1000,
        .supervisor_tick_ms = 50,
        .backoff_base_ms = 10,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, defaultWorkHandler, fakeNow, null);
    defer pool.deinit();

    const task = try Task.create(allocator, "race1", "race test", 1, 0);
    defer task.destroy();

    pool.workers[0].assignTask(task, 0);
    pool.supervisorTick(0);
    // supervisorTick ahora lee worker.state bajo mutex; workerRoutine escribe bajo mutex.
    // Sin crash = no race detectable con el modelo de memoria de Zig.
    try std.testing.expectEqual(Worker.WorkerState.busy, pool.workers[0].state);
}

test "deinit after worker replacement joins detached threads safely" {
    const allocator = std.testing.allocator;

    const config = SchedulerConfig{
        .num_workers = 1,
        .task_timeout_ms = 50,
        .max_retries = 0,
        .heartbeat_interval_ms = 10,
        .supervisor_tick_ms = 5,
        .backoff_base_ms = 1,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, defaultWorkHandler, defaultNow, null);

    const task = try Task.create(allocator, "rep1", "replacement", 1, 0);
    defer task.destroy();

    pool.workers[0].assignTask(task, 0);

    // Forzar heartbeat miss para reemplazo
    const original = pool.workers[0];
    const now = defaultNow();
    pool.supervisorTick(now + 100);

    // No depender del idle transitorio del hilo nuevo: probar su identidad y
    // dejar la unión de ese hilo a deinit, que es la garantía de esta prueba.
    try std.testing.expect(pool.workers[0] != original);
    try std.testing.expect(pool.workers[0].thread != null);
    try std.testing.expectEqual(@as(usize, 1), pool.detached_workers.items.len);

    // deinit une el hilo nuevo y libera también el worker reemplazado.
    pool.deinit();
    // Si no hay crash/use-after-free, el test pasa.
}

test "long task with periodic heartbeat is not marked unhealthy" {
    const allocator = std.testing.allocator;
    fake_clock = 0;

    const config = SchedulerConfig{
        .num_workers = 1,
        .task_timeout_ms = 30_000,
        .max_retries = 0,
        .heartbeat_interval_ms = 50,
        .supervisor_tick_ms = 10,
        .backoff_base_ms = 1,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, longHealthyHandler, fakeNow, null);
    defer pool.deinit();

    const task = try Task.create(allocator, "hb-long", "long with heartbeat", 1, 0);
    defer task.destroy();

    pool.workers[0].assignTask(task, 0);

    // Simular 500ms de ejecución con heartbeats cada 25ms (determinista)
    var now: u64 = 0;
    while (now < 500) : (now += 25) {
        pool.workers[0].pumpHeartbeat(now);
        fake_clock = now;
        pool.supervisorTick(now);
    }

    // Worker sigue busy, tarea sigue running, sin error
    try std.testing.expectEqual(Worker.WorkerState.busy, pool.workers[0].state);
    try std.testing.expectEqual(TaskState.running, task.state);
    try std.testing.expectEqual(@as(?[]const u8, null), task.error_msg);
}

test "re-enqueue after timeout is safe if worker drops task first" {
    const allocator = std.testing.allocator;
    fake_clock = 0;

    const config = SchedulerConfig{
        .num_workers = 1,
        .task_timeout_ms = 100,
        .max_retries = 2,
        .heartbeat_interval_ms = 1000,
        .supervisor_tick_ms = 50,
        .backoff_base_ms = 10,
    };

    var pool = try ThreadPool.initWithConfig(allocator, config, defaultWorkHandler, fakeNow, null);
    defer pool.deinit();

    const task = try Task.create(allocator, "safe1", "safe retry", 1, 2);
    defer task.destroy();

    pool.workers[0].assignTask(task, 0);
    pool.supervisorTick(0);
    try std.testing.expectEqual(TaskState.running, task.state);

    // Timeout: supervisor marca cancel, handleTaskFailure, worker.idle, task=null
    fake_clock = 100;
    pool.supervisorTick(100);
    try std.testing.expectEqual(TaskState.pending, task.state);
    try std.testing.expectEqual(@as(u32, 1), task.retries);
    try std.testing.expect(task.canRetry());
    try std.testing.expectEqual(Worker.WorkerState.idle, pool.workers[0].state);
    try std.testing.expectEqual(@as(?*Task, null), pool.workers[0].current_task);
}

test "F8-T2: 12 or more concurrent workers run without race conditions or leaks" {
    const allocator = std.testing.allocator;
    const config = SchedulerConfig{
        .num_workers = 12,
        .task_timeout_ms = 5000,
        .max_retries = 1,
        .heartbeat_interval_ms = 1000,
        .supervisor_tick_ms = 50,
        .backoff_base_ms = 10,
    };

    var scheduler = try Scheduler.initWithConfig(allocator, config, defaultWorkHandler, defaultNow, null);
    defer scheduler.deinit();

    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const id = try std.fmt.allocPrint(allocator, "f8_t{d}", .{i + 1});
        defer allocator.free(id);
        const task = try Task.create(allocator, id, "massive parallel work", 1, 0);
        try scheduler.enqueueTask(task);
    }

    try scheduler.start();
    scheduler.runAll();
    scheduler.stop();

    try std.testing.expectEqual(@as(usize, 24), scheduler.getCompletedTasks());
    try std.testing.expectEqual(@as(usize, 0), scheduler.getPendingTasks());
}

test "CK-MOT-021: escapeJsonString escapa todo control <0x20 y produce JSON válido" {
    const allocator = std.testing.allocator;

    // Entrada: TODOS los controles 0x00..0x1F seguidos de '\\' y '"'.
    var raw: [34]u8 = undefined;
    var n: usize = 0;
    var b: u8 = 0;
    while (b < 0x20) : (b += 1) {
        raw[n] = b;
        n += 1;
    }
    raw[n] = '\\';
    n += 1;
    raw[n] = '"';
    n += 1;
    const input = raw[0..n];

    // Salida exacta esperada: \\, \", \n, \r y \t como hoy; el resto de
    // controles <0x20 como \u00XX (hex minúscula, igual que bridge.cpp).
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(allocator);
    try expected.append(allocator, '"');
    b = 0;
    while (b < 0x20) : (b += 1) {
        switch (b) {
            0x09 => try expected.appendSlice(allocator, "\\t"),
            0x0A => try expected.appendSlice(allocator, "\\n"),
            0x0D => try expected.appendSlice(allocator, "\\r"),
            else => {
                var esc: [6]u8 = undefined;
                _ = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{b});
                try expected.appendSlice(allocator, &esc);
            },
        }
    }
    try expected.appendSlice(allocator, "\\\\");
    try expected.appendSlice(allocator, "\\\"");
    try expected.append(allocator, '"');

    const escaped = try escapeJsonString(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings(expected.items, escaped);

    // El resultado debe ser JSON válido y decodificar exactamente la entrada.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, escaped, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .string);
    try std.testing.expectEqualStrings(input, parsed.value.string);
}
