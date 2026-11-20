const std = @import("std");
const live_worker = @import("live_worker.zig");
const sync = @import("sync.zig");

pub const DispatchSnapshot = struct {
    found: bool = true,
    done: bool = false,
    has_thread: bool = false,
    timed_out: bool = false,
    start_ms: u64 = 0,
    timeout_ms: u64 = 240_000,
    ok: bool = true,
};

pub const DispatchEntry = struct {
    order_id: i64,
    thread: ?std.Thread = null,
    token: ?*live_worker.CancellationToken = null,
    start_ts_ms: u64 = 0,
    timeout_ms: u64 = 240_000,
    timed_out: bool = false,
    is_memory: bool = false,
    finished: bool = false,
    success: bool = true,
};

pub const default_max_finished_orders: usize = 4096;

pub const DispatchRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = sync.Mutex.init(),
    entries: std.ArrayListUnmanaged(DispatchEntry) = .empty,
    /// Ordenes con al menos un despacho terminado. Sobrevive a joinIfFinished
    /// (que retira la entrada y libera el token): da_order_cancel necesita
    /// saber que una orden .planned ya se despacho aunque su estado no se haya
    /// persistido (salida temprana) para no cancelarla como plan.
    finished_orders: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// Anillo con el orden de insercion de finished_orders para retirar la
    /// marca mas antigua al llegar al tope. Se asigna en el alta (begin es
    /// fallible) con exactamente max_finished_orders elementos.
    finished_order_ring: []i64 = &.{},
    finished_order_head: usize = 0,
    finished_order_len: usize = 0,
    /// Tope de marcas; parametro para poder probar la retirada con un valor
    /// pequeno. Una marca solo importa mientras la orden siga en
    /// .planned/.clarifying tras una salida temprana: 4096 basta de sobra.
    max_finished_orders: usize = default_max_finished_orders,
    closing: bool = false,

    pub fn init(allocator: std.mem.Allocator) DispatchRegistry {
        return initWithMarkLimit(allocator, default_max_finished_orders);
    }

    pub fn initWithMarkLimit(allocator: std.mem.Allocator, max_finished_orders: usize) DispatchRegistry {
        return .{
            .allocator = allocator,
            .max_finished_orders = @max(1, max_finished_orders),
        };
    }

    pub fn deinit(self: *DispatchRegistry) void {
        self.mutex.lock();
        self.closing = true;

        // Keep every entry reachable while its worker finishes, but never wait
        // for a worker while holding the mutex that finish() needs.
        for (self.entries.items) |*entry| {
            if (entry.token) |tok| tok.cancel();
        }
        self.mutex.unlock();

        var i: usize = 0;
        while (true) : (i += 1) {
            self.mutex.lock();
            if (i >= self.entries.items.len) {
                self.mutex.unlock();
                break;
            }
            const thread = self.entries.items[i].thread;
            self.entries.items[i].thread = null;
            self.mutex.unlock();

            if (thread) |t| t.join();
        }

        self.mutex.lock();
        for (self.entries.items) |*entry| {
            if (entry.token) |tok| {
                tok.release();
            }
        }
        self.entries.deinit(self.allocator);
        self.finished_orders.deinit(self.allocator);
        if (self.finished_order_ring.len > 0) self.allocator.free(self.finished_order_ring);
        self.finished_order_ring = &.{};
        self.mutex.unlock();
    }

    /// Reserva en el alta la capacidad que finish() necesita para insertar la
    /// marca sin asignar (putAssumeCapacity). Cubre todas las entradas vivas:
    /// cada una puede terminar y aportar una marca. El anillo se asigna aqui
    /// porque begin ya puede fallar y propagar el error.
    fn reserveFinishedMark(self: *DispatchRegistry) !void {
        if (self.finished_order_ring.len == 0) {
            self.finished_order_ring = try self.allocator.alloc(i64, self.max_finished_orders);
        }
        try self.finished_orders.ensureTotalCapacity(
            self.allocator,
            @intCast(self.finished_orders.count() + self.entries.items.len + 1),
        );
    }

    fn evictOldestFinished(self: *DispatchRegistry) void {
        if (self.finished_order_len == 0) return;
        const oldest = self.finished_order_ring[self.finished_order_head];
        _ = self.finished_orders.remove(oldest);
        self.finished_order_head = (self.finished_order_head + 1) % self.max_finished_orders;
        self.finished_order_len -= 1;
    }

    fn recordFinishedAssumeCapacity(self: *DispatchRegistry, order_id: i64) void {
        self.finished_orders.putAssumeCapacity(order_id, {});
        const slot = (self.finished_order_head + self.finished_order_len) % self.max_finished_orders;
        self.finished_order_ring[slot] = order_id;
        self.finished_order_len += 1;
    }

    pub fn begin(self: *DispatchRegistry, order_id: i64, is_memory: bool, start_ts: u64) !void {
        return self.beginWithTimeout(order_id, is_memory, start_ts, 240_000);
    }

    pub fn beginWithTimeout(self: *DispatchRegistry, order_id: i64, is_memory: bool, start_ts: u64, timeout_ms: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return error.Closing;
        for (self.entries.items) |item| {
            if (item.order_id == order_id and !item.finished) return error.DuplicateOrder;
            if (is_memory and item.is_memory and !item.finished) return error.MemoryBusy;
        }
        const may_add_mark = !self.finished_orders.contains(order_id);
        // Se reserva siempre, tambien si la orden ya tiene marca: el tope
        // puede retirar esa marca antes de que este despacho termine y el
        // finish volveria a insertar.
        try self.reserveFinishedMark();
        try self.entries.append(self.allocator, .{
            .order_id = order_id,
            .is_memory = is_memory,
            .start_ts_ms = start_ts,
            .timeout_ms = timeout_ms,
        });
        // Una marca solo hace falta mientras la orden pueda seguir .planned
        // tras una salida temprana; al llegar al tope se retira la mas antigua
        // en el alta, no cuando ya no hay hueco para insertar.
        if (may_add_mark and self.finished_orders.count() >= self.max_finished_orders) {
            self.evictOldestFinished();
        }
    }

    pub fn abortNeverStarted(self: *DispatchRegistry, order_id: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].order_id == order_id and !self.entries.items[i].finished) {
                if (self.entries.items[i].token) |tok| tok.release();
                _ = self.entries.swapRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn attachCancellationToken(self: *DispatchRegistry, order_id: i64, token: *live_worker.CancellationToken) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            if (entry.order_id == order_id and !entry.finished) {
                if (entry.token) |old| old.release();
                token.retain();
                entry.token = token;
                return true;
            }
        }
        return false;
    }

    pub fn retainCancellationToken(self: *DispatchRegistry, order_id: i64) ?*const live_worker.CancellationToken {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            if (entry.order_id == order_id and !entry.finished) {
                if (entry.token) |tok| {
                    tok.retain();
                    return tok;
                }
            }
        }
        return null;
    }

    pub fn setThread(self: *DispatchRegistry, order_id: i64, thread: std.Thread) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // The spawned worker may finish before its creator gets here. Select
        // the newest matching entry and attach the handle even if finish()
        // already marked it complete, so poll/deinit can still join it.
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.entries.items[i];
            if (entry.order_id == order_id) {
                entry.thread = thread;
                return;
            }
        }
    }

    /// r6 (auditoría el segundo auditor r5, P1-b): una orden puede tener a la vez
    /// una entrada TERMINADA antigua (aún sin retirar de la lista) y la entrada
    /// ACTIVA del comando reanudado. La activa manda: snapshot no puede
    /// devolver la terminada mientras exista una viva, o da_order_cancel
    /// tomaría la vía en vez de marcar el token de la activa. Solo si no
    /// hay ninguna activa se informa de la terminada. Devuelve el índice.
    fn selectEntry(self: *DispatchRegistry, order_id: i64) ?usize {
        var fallback: ?usize = null;
        for (self.entries.items, 0..) |entry, i| {
            if (entry.order_id != order_id) continue;
            if (!entry.finished) return i;
            if (fallback == null) fallback = i;
        }
        return fallback;
    }

    pub fn snapshot(self: *DispatchRegistry, order_id: i64) DispatchSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.selectEntry(order_id) orelse
            return .{ .found = false, .done = true, .has_thread = false, .timed_out = false, .start_ms = 0, .ok = true };
        const entry = &self.entries.items[idx];
        return .{
            .found = true,
            .done = entry.finished,
            .has_thread = entry.thread != null,
            .timed_out = entry.timed_out,
            .start_ms = entry.start_ts_ms,
            .timeout_ms = entry.timeout_ms,
            .ok = entry.success and !entry.timed_out,
        };
    }

    pub fn requestCancel(self: *DispatchRegistry, order_id: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        // r6 (P1-b): solo la entrada activa es accionable; una
        // terminada antigua de la misma orden no puede absorber la
        // cancelación (ya no hay nada que cancelar en ella) ni impedir que se
        // marque el token vivo.
        const idx = self.selectEntry(order_id) orelse return false;
        const entry = &self.entries.items[idx];
        if (entry.finished) return false;
        const tok = entry.token orelse return false;
        tok.flag.store(true, .release);
        return true;
    }

    pub fn finish(self: *DispatchRegistry, order_id: i64, success: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            if (entry.order_id == order_id and !entry.finished) {
                entry.finished = true;
                entry.success = success;
                if (!self.finished_orders.contains(order_id)) {
                    // El alta reservo hueco para esta marca: putAssumeCapacity
                    // no puede fallar ni perderla. Si el tope se lleno con
                    // entradas en vuelo, se retira la mas antigua aqui tambien
                    // para no superarlo.
                    if (self.finished_orders.count() >= self.max_finished_orders) {
                        self.evictOldestFinished();
                    }
                    self.recordFinishedAssumeCapacity(order_id);
                }
                return;
            }
        }
    }

    /// True si esta orden ya tuvo un despacho terminado, aunque su entrada ya
    /// no exista porque joinIfFinished la retiro.
    pub fn hasFinished(self: *DispatchRegistry, order_id: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.finished_orders.contains(order_id);
    }

    pub fn markTimedOut(self: *DispatchRegistry, order_id: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            if (entry.order_id == order_id and !entry.finished) {
                entry.timed_out = true;
                return true;
            }
        }
        return false;
    }

    pub fn joinIfFinished(self: *DispatchRegistry, order_id: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].order_id == order_id and self.entries.items[i].finished) {
                var entry = self.entries.swapRemove(i);
                if (entry.thread) |*t| {
                    t.join();
                }
                if (entry.token) |tok| {
                    tok.release();
                }
                return;
            }
            i += 1;
        }
    }

    pub fn hasAnyInFlight(self: *DispatchRegistry) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            if (!entry.finished) return true;
        }
        return false;
    }
};

test "CK-MOT-013: stalled order reaches its finite deadline and cancels only its worker" {
    var registry = DispatchRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const stalled = try live_worker.CancellationToken.create(std.testing.allocator);
    defer stalled.release();
    const healthy = try live_worker.CancellationToken.create(std.testing.allocator);
    defer healthy.release();
    try registry.beginWithTimeout(1, false, 10, 900_000);
    try registry.beginWithTimeout(2, false, 10, 3_600_000);
    try std.testing.expect(registry.attachCancellationToken(1, stalled));
    try std.testing.expect(registry.attachCancellationToken(2, healthy));
    // Clock and workers are doubles; this is the production poll predicate.
    for ([_]u64{ 900_009, 900_010 }) |now_ms| {
        const snap = registry.snapshot(1);
        if (!snap.done and !snap.timed_out and now_ms - snap.start_ms >= snap.timeout_ms) {
            try std.testing.expect(registry.markTimedOut(1));
            try std.testing.expect(registry.requestCancel(1));
        }
        try std.testing.expectEqual(now_ms == 900_010, stalled.isCancelled());
    }
    try std.testing.expect(registry.snapshot(1).timed_out);
    try std.testing.expect(!registry.snapshot(1).ok);
    try std.testing.expect(!healthy.isCancelled());
    registry.finish(1, true);
    try std.testing.expect(!registry.snapshot(1).ok);
}

test "registry keeps per-order timeout budgets isolated" {
    var registry = DispatchRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.beginWithTimeout(1, false, 10, 240_000);
    try registry.beginWithTimeout(2, false, 10, 900_000);
    try std.testing.expectEqual(@as(u64, 240_000), registry.snapshot(1).timeout_ms);
    try std.testing.expectEqual(@as(u64, 900_000), registry.snapshot(2).timeout_ms);
}

test "shutdown cancels worker and never joins while holding finish mutex" {
    const allocator = std.testing.allocator;
    var registry = DispatchRegistry.init(allocator);
    try registry.begin(1, false, 0);
    const token = try live_worker.CancellationToken.create(allocator);
    defer token.release();
    try std.testing.expect(registry.attachCancellationToken(1, token));
    const Ctx = struct {
        registry: *DispatchRegistry,
        token: *const live_worker.CancellationToken,
        fn run(ctx: *@This()) void {
            while (!ctx.token.isCancelled()) std.atomic.spinLoopHint();
            ctx.registry.finish(1, true);
        }
    };
    var ctx = Ctx{ .registry = &registry, .token = token };
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    registry.setThread(1, thread);
    registry.deinit();
}

test "E3.24: tormenta de cancelaciones — 32 despachos, 8 hilos, sin deadlock ni pérdida" {
    const allocator = std.testing.allocator;
    var registry = DispatchRegistry.init(allocator);
    defer registry.deinit();

    // 32 despachos en vuelo, cada uno con su CancellationToken real.
    const N = 32;
    var tokens: [N]*live_worker.CancellationToken = undefined;
    for (0..N) |i| {
        try registry.begin(@intCast(1000 + i), false, 0);
        tokens[i] = try live_worker.CancellationToken.create(allocator);
        try std.testing.expect(registry.attachCancellationToken(@intCast(1000 + i), tokens[i]));
    }
    defer for (&tokens) |tok| tok.release();

    // Tormenta: 8 hilos x 8 rondas de requestCancel+snapshot sobre los 32, con
    // un hilo extra que TERMINA órdenes mientras los demás las cancelan —
    // requestCancel contra finish es la carrera que el mutex debe ordenar.
    const Storm = struct {
        registry: *DispatchRegistry,
        base: i64,
        n: usize,
        finisher: bool,
        fn run(ctx: *@This()) void {
            for (0..8) |round| {
                for (0..ctx.n) |i| {
                    const oid = ctx.base + @as(i64, @intCast(i));
                    if (ctx.finisher) {
                        ctx.registry.finish(oid, false);
                        ctx.registry.joinIfFinished(oid);
                    } else {
                        _ = ctx.registry.requestCancel(oid);
                        _ = ctx.registry.snapshot(oid);
                    }
                }
                _ = round;
            }
        }
    };

    var ctx = Storm{ .registry = &registry, .base = 1000, .n = N, .finisher = false };
    var fin_ctx = Storm{ .registry = &registry, .base = 1000, .n = N / 2, .finisher = true };
    var threads: [9]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (0..spawned) |t| threads[t].join();
    for (0..8) |t| {
        threads[t] = try std.Thread.spawn(.{}, Storm.run, .{&ctx});
        spawned += 1;
    }
    threads[8] = try std.Thread.spawn(.{}, Storm.run, .{&fin_ctx});
    spawned += 1;
    for (0..spawned) |t| threads[t].join();
    spawned = 0;

    // Toda orden cancelada — la tormenta no pudo perder ninguna señal.
    for (0..N) |i| {
        try std.testing.expect(tokens[i].isCancelled());
    }
    // El registro queda coherente: todo lo no terminado se cierra ahora.
    for (0..N) |i| {
        const oid: i64 = @intCast(1000 + i);
        registry.finish(oid, false);
        registry.joinIfFinished(oid);
    }
    try std.testing.expect(!registry.hasAnyInFlight());
}

test "setThread retains handle when finish wins the race" {
    const allocator = std.testing.allocator;
    var registry = DispatchRegistry.init(allocator);
    defer registry.deinit();
    try registry.begin(2, false, 0);
    const Ctx = struct {
        registry: *DispatchRegistry,
        finished: *std.atomic.Value(bool),
        fn run(ctx: *@This()) void {
            ctx.registry.finish(2, true);
            ctx.finished.store(true, .release);
        }
    };
    var finished = std.atomic.Value(bool).init(false);
    var ctx = Ctx{ .registry = &registry, .finished = &finished };
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    while (!finished.load(.acquire)) std.atomic.spinLoopHint();
    registry.setThread(2, thread);
    const snap = registry.snapshot(2);
    try std.testing.expect(snap.done);
    try std.testing.expect(snap.has_thread);
    registry.joinIfFinished(2);
    try std.testing.expect(!registry.snapshot(2).found);
}

test "CK-CAB-019 r6 dispatch_registry: la entrada activa manda ante una terminada antigua" {
    const allocator = std.testing.allocator;
    var registry = DispatchRegistry.init(allocator);
    defer registry.deinit();

    // Entrada terminada antigua de la orden (sin token) que sigue en la lista:
    // el despacho anterior la terminó pero aún no la retiró.
    try registry.begin(7, false, 0);
    registry.finish(7, true);
    try std.testing.expect(registry.snapshot(7).done);

    // Entrada ACTIVA posterior (la del comando reanudado) con su token.
    try registry.begin(7, false, 10);
    const token = try live_worker.CancellationToken.create(allocator);
    defer token.release();
    try std.testing.expect(registry.attachCancellationToken(7, token));

    // La activa manda: ni snapshot la eclipsa la terminada...
    const snap = registry.snapshot(7);
    try std.testing.expect(snap.found);
    try std.testing.expect(!snap.done);
    try std.testing.expectEqual(@as(u64, 10), snap.start_ms);

    // ...ni requestCancel se pierde en la terminada: marca SU token.
    try std.testing.expect(registry.requestCancel(7));
    try std.testing.expect(token.isCancelled());

    // Terminada también la activa, solo queda la vieja: snapshot la informa
    // (fallback) y requestCancel no tiene nada que cancelar.
    registry.finish(7, true);
    try std.testing.expect(registry.snapshot(7).done);
    try std.testing.expect(!registry.requestCancel(7));
}

test "finished-order marks: fallo de reserva al registrar no registra el despacho ni deja marcas a medias" {
    const base = std.testing.allocator;
    // Las dos primeras asignaciones del alta son el anillo y la capacidad del
    // mapa de marcas. Un fallo en cualquiera debe abortar el alta sin entrada
    // ni marca, y el registro debe seguir utilizable despues.
    for ([_]usize{ 0, 1 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        var registry = DispatchRegistry.initWithMarkLimit(failing.allocator(), 4);
        defer registry.deinit();

        try std.testing.expectError(error.OutOfMemory, registry.beginWithTimeout(10, false, 1, 1000));
        try std.testing.expect(!registry.snapshot(10).found);
        try std.testing.expect(!registry.hasFinished(10));

        // La reserva fallida no dejo nada a medias: el mismo alta funciona
        // cuando el asignador vuelve a responder (FailingAllocator falla desde
        // fail_index en adelante, no solo en esa asignacion).
        failing.fail_index = std.math.maxInt(usize);
        try registry.beginWithTimeout(10, false, 1, 1000);
        registry.finish(10, true);
        try std.testing.expect(registry.hasFinished(10));
    }
}

test "finished-order marks: tope pequeno retira la marca mas antigua y conserva las recientes" {
    var registry = DispatchRegistry.initWithMarkLimit(std.testing.allocator, 3);
    defer registry.deinit();

    for ([_]i64{ 1, 2, 3 }) |id| {
        try registry.begin(id, false, 0);
        registry.finish(id, true);
    }
    try std.testing.expect(registry.hasFinished(1));
    try std.testing.expect(registry.hasFinished(2));
    try std.testing.expect(registry.hasFinished(3));

    // El cuarto alta retira la marca mas antigua antes de que su despacho
    // termine: el tope se respeta por registro, no solo al insertar.
    try registry.begin(4, false, 0);
    try std.testing.expect(!registry.hasFinished(1));
    try std.testing.expect(registry.hasFinished(2));
    try std.testing.expect(registry.hasFinished(3));
    registry.finish(4, true);
    try std.testing.expect(registry.hasFinished(4));

    try registry.begin(5, false, 0);
    try std.testing.expect(!registry.hasFinished(2));
    try std.testing.expect(registry.hasFinished(3));
    try std.testing.expect(registry.hasFinished(4));
    registry.finish(5, true);

    try std.testing.expect(!registry.hasFinished(1));
    try std.testing.expect(!registry.hasFinished(2));
    try std.testing.expect(registry.hasFinished(3));
    try std.testing.expect(registry.hasFinished(4));
    try std.testing.expect(registry.hasFinished(5));
}

test "finished-order marks: un alta fallida no pierde las marcas existentes" {
    const base = std.testing.allocator;
    // Se busca un indice de fallo que caiga en una ampliacion real (mapa o
    // lista de entradas; las primeras altas caben en la capacidad reservada).
    // Con entradas en vuelo, count + entries.len+1 acaba exigiendo crecer; ese
    // fallo no debe tocar la marca ya committed (la 1).
    var found = false;
    var fail_index: usize = 0;
    while (fail_index < 256 and !found) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        var registry = DispatchRegistry.initWithMarkLimit(failing.allocator(), 8);
        defer registry.deinit();

        registry.begin(1, false, 0) catch continue;
        registry.finish(1, true);
        if (!registry.hasFinished(1)) continue;

        var i: i64 = 2;
        var failed_at: ?i64 = null;
        while (i < 64) : (i += 1) {
            if (registry.begin(i, false, 0)) |_| {
                // Se deja en vuelo para que la siguiente alta necesite mas
                // capacidad; no se termina para no crear marcas nuevas.
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                failed_at = i;
                break;
            }
        }
        if (failed_at) |id| {
            try std.testing.expect(!registry.snapshot(id).found);
            try std.testing.expect(!registry.hasFinished(id));
            try std.testing.expect(registry.hasFinished(1));
            found = true;
        }
    }
    try std.testing.expect(found);
}
