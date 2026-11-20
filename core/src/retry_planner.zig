//! core/src/retry_planner.zig — Reintento acotado con backoff exponencial y
//! jitter para HTTP 429 (B2).
//!
//! Por qué existe: un 429 suele ser un techo TRANSITORIO (peticiones
//! concurrentes del propio enjambre, ventana por segundo del proveedor) y no
//! cuota agotada — eso es 402/`quota`, que se clasifica aparte. La cadena de
//! fallback lo trataba igual que un fallo terminal: quemaba el candidato al
//! instante y saltaba al siguiente. Con doce candidatos y N tareas en paralelo
//! pegando al mismo proveedor, esa estampida PROVOCABA el 429 que luego
//! "confirmaba" la caída — el sistema se auto-limitaba.
//!
//! Qué hace y qué NO hace:
//!   - Reintenta el MISMO candidato solo ante `error.RateLimited`, con espera
//!     exponencial + jitter y presupuesto total acotado.
//!   - Cualquier otro error (auth, quota, red, timeout) pasa directo: no es
//!     asunto de este módulo.
//!   - NO rota la clave: `rotateKey` la marca `rotated` de forma permanente —
//!     un techo de un segundo no justifica retirar una cuenta que funciona.
//!   - NO reintenta efectos de lado: la costura es la llamada al proveedor,
//!     no la orden — la orden existe una sola vez aguas arriba.
//!
//! La espera es interrumpible por el token de cancelación de la orden: una
//! cancelación explícita nunca espera detrás de un backoff.
//!
//! Todo es inyectable (sleep, jitter, cancelación, telemetría) para que los
//! tests sean deterministas sin tocar reloj ni red.

const std = @import("std");

const Sleep = @import("platform.zig").sleep;
const BCryptGenRandom = if (@import("builtin").os.tag == .windows) struct {
    extern "bcrypt" fn BCryptGenRandom(hAlgorithm: ?*anyopaque, pbBuffer: [*]u8, cbBuffer: u32, dwFlags: u32) callconv(.winapi) i32;
}.BCryptGenRandom else @import("platform.zig").random;

/// Política de reintento ante 429.
pub const Policy = struct {
    /// Reintentos EXTRA sobre el mismo candidato tras el primer 429.
    /// Cada reintento es una llamada HTTP real (con su puerta de gobernanza y
    /// presupuesto), no un bucle interno gratis.
    max_retries: u32 = 3,
    /// Espera base del primer reintento; crece x2 por reintento hasta `cap_ms`.
    base_ms: u64 = 500,
    cap_ms: u64 = 4_000,
    /// Tope de espera ACUMULADA por candidato. Un 429 permanente no puede
    /// secuestrar la cadena: agotado el presupuesto se propaga el error y el
    /// llamador degrada al siguiente candidato igual que antes.
    total_budget_ms: u64 = 8_000,
};

/// La que usan los despachos y el planner en producción.
pub const default_policy = Policy{};

/// Backoff exponencial con "equal jitter":
///     span  = min(cap_ms, base_ms << retry_index)
///     wait  = span/2 + jitter,  jitter ∈ [0, span/2)
///
/// La mitad fija garantiza cotas inferiores ESTRICTAMENTE crecientes entre
/// reintentos (250, 500, 1000... con la política por defecto); la mitad
/// sorteada decorrelaciona las ráfagas del enjambre — sin jitter, todas las
/// tareas que recibieron 429 a la vez reintentarían en el mismo instante y
/// provocarían el siguiente.
///
/// `jitter_permille` ∈ [0, 1023] lo aporta el llamador (aleatorio del SO en
/// producción, fijo en tests): esta función es pura y comprobable.
pub fn backoffMs(policy: Policy, retry_index: u32, jitter_permille: u64) u64 {
    const shift: u6 = @intCast(@min(retry_index, 20));
    const grown = std.math.mul(u64, policy.base_ms, @as(u64, 1) << shift) catch policy.cap_ms;
    const span = @min(policy.cap_ms, @max(grown, policy.base_ms));
    const half = span / 2;
    const jitter = half * @min(jitter_permille, 1023) / 1024;
    return half + jitter;
}

/// Ganchos del driver. Todo campo es opcional: sin sleep_fn se duerme de
/// verdad (kernel32 Sleep), sin jitter_fn se sortea con BCryptGenRandom
/// (CNG — este fork de Zig no expone std.crypto.random; mismo patrón que
/// c_api.zig y mcp_server.zig), sin cancelación no se comprueba, sin
/// on_retry_fn no hay telemetría.
pub const Hooks = struct {
    sleep_ctx: ?*anyopaque = null,
    sleep_fn: ?*const fn (ctx: ?*anyopaque, wait_ms: u64) void = null,
    cancel_ctx: ?*anyopaque = null,
    is_cancelled_fn: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// Devuelve una muestra en [0, 1023] para el jitter.
    jitter_ctx: ?*anyopaque = null,
    jitter_fn: ?*const fn (ctx: ?*anyopaque) u64 = null,
    /// Telemetría por reintento programado (retry_index empieza en 0).
    retry_ctx: ?*anyopaque = null,
    on_retry_fn: ?*const fn (ctx: ?*anyopaque, retry_index: u32, wait_ms: u64) void = null,
    /// 10-nov (USUARIO-NUEVO A6): lo que el proveedor dijo en ESTE 429.
    hint_ctx: ?*anyopaque = null,
    hint_fn: ?*const fn (ctx: ?*anyopaque) Hint = null,
};

/// Indicación del proveedor tras un 429.
pub const Hint = struct {
    /// Cuota agotada (p. ej. diaria): reintentar en segundos solo gasta
    /// llamadas. Se propaga el 429 sin esperar.
    give_up: bool = false,
    /// `Retry-After` / `X-RateLimit-Reset` convertidos a espera en ms.
    wait_ms: ?u64 = null,
};

fn isCancelled(hooks: Hooks) bool {
    const f = hooks.is_cancelled_fn orelse return false;
    const ctx = hooks.cancel_ctx orelse return false;
    return f(ctx);
}

fn jitterSample(hooks: Hooks) u64 {
    if (hooks.jitter_fn) |f| return f(hooks.jitter_ctx);
    var bytes: [8]u8 = undefined;
    if (BCryptGenRandom(null, &bytes, bytes.len, 0x00000002) != 0) {
        // Sin entropía del SO se devuelve 0: la mitad fija del backoff sigue
        // siendo una espera válida — peor decorrelación entre workers, jamás
        // un fallo funcional.
        return 0;
    }
    return std.mem.readInt(u64, &bytes, .little) % 1024;
}

/// Duerme en tramos cortos mirando la cancelación entre tramos. Un Sleep(8s)
/// seguido ignoraría un cancelar explícito durante toda la espera — el token
/// es la voz del usuario y se escucha cada 50 ms.
fn sleepInterruptible(hooks: Hooks, wait_ms: u64) error{Cancelled}!void {
    var remaining = wait_ms;
    while (remaining > 0) {
        if (isCancelled(hooks)) return error.Cancelled;
        const slice = @min(remaining, @as(u64, 50));
        if (hooks.sleep_fn) |f| {
            f(hooks.sleep_ctx, slice);
        } else {
            Sleep(@intCast(slice));
        }
        remaining -= slice;
    }
}

/// Ejecuta `call_fn` reintentando SOLO ante `error.RateLimited`.
///
/// Devuelve void si algún intento completa; propaga el error original cuando
///   - el error no es RateLimited (sin espera ni reintento),
///   - se agotan `max_retries`,
///   - el presupuesto `total_budget_ms` no admite la siguiente espera,
///   - o la cancelación interrumpe (error.Cancelled, no el 429 original).
///
/// El mismo `call_ctx` viaja a TODOS los intentos: el driver no crea órdenes,
/// ni tareas, ni envíos — solo repite la llamada de proveedor que le dieron.
pub fn run(
    policy: Policy,
    hooks: Hooks,
    call_ctx: ?*anyopaque,
    call_fn: *const fn (ctx: ?*anyopaque) anyerror!void,
) anyerror!void {
    var retry_index: u32 = 0;
    var waited_ms: u64 = 0;
    while (true) {
        call_fn(call_ctx) catch |e| {
            if (e != error.RateLimited) return e;
            if (isCancelled(hooks)) return error.Cancelled;
            if (retry_index >= policy.max_retries) return e;
            const hint: Hint = if (hooks.hint_fn) |f| f(hooks.hint_ctx) else .{};
            // A6: el proveedor dijo que la cuota se agotó → no se gasta más.
            if (hint.give_up) return e;
            var wait = backoffMs(policy, retry_index, jitterSample(hooks));
            // A6: se respeta la espera que pide el proveedor; si no cabe en
            // el presupuesto, se propaga ya en vez de reintentar antes de tiempo.
            if (hint.wait_ms) |asked| wait = @max(wait, asked);
            if (waited_ms + wait > policy.total_budget_ms) return e;
            if (hooks.on_retry_fn) |f| f(hooks.retry_ctx, retry_index, wait);
            retry_index += 1;
            waited_ms += wait;
            try sleepInterruptible(hooks, wait);
            continue;
        };
        return;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

const FakeCall = struct {
    fails_left: usize,
    calls: usize = 0,
    /// Puntero recibido en cada llamada: la prueba de "no duplica" es que es
    /// SIEMPRE el mismo — el driver repite la llamada, no crea trabajo nuevo.
    last_ctx: ?*anyopaque = null,
    same_ctx_every_time: bool = true,
    fail_error: anyerror = error.RateLimited,

    fn call(raw: ?*anyopaque) anyerror!void {
        const self: *FakeCall = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls > 1 and self.last_ctx != raw) self.same_ctx_every_time = false;
        self.last_ctx = raw;
        if (self.fails_left > 0) {
            self.fails_left -= 1;
            return self.fail_error;
        }
    }
};

/// Registra cada CORTE de la espera interrumpible (<= 50 ms): la espera
/// lógica programada se verifica aparte, vía el hook on_retry.
const FakeClock = struct {
    waits: [64]u64 = [_]u64{0} ** 64,
    count: usize = 0,

    fn sleep(raw: ?*anyopaque, wait_ms: u64) void {
        const self: *FakeClock = @ptrCast(@alignCast(raw.?));
        if (self.count < self.waits.len) {
            self.waits[self.count] = wait_ms;
            self.count += 1;
        }
    }

    fn total(self: *const FakeClock) u64 {
        var t: u64 = 0;
        for (self.waits[0..self.count]) |w| t += w;
        return t;
    }
};

fn zeroJitter(_: ?*anyopaque) u64 {
    return 0;
}

test "USUARIO-NUEVO A6: cuota diaria agotada = una sola llamada; Retry-After se respeta o se propaga" {
    const Hints = struct {
        fn daily(_: ?*anyopaque) Hint {
            return .{ .give_up = true };
        }
        fn three_seconds(_: ?*anyopaque) Hint {
            return .{ .wait_ms = 3000 };
        }
        fn one_minute(_: ?*anyopaque) Hint {
            return .{ .wait_ms = 60_000 };
        }
    };
    var clock = FakeClock{};
    var hooks = fakeHooks(&clock);
    hooks.hint_fn = Hints.daily;
    var call = FakeCall{ .fails_left = 10 };
    try std.testing.expectError(error.RateLimited, run(default_policy, hooks, &call, FakeCall.call));
    try std.testing.expectEqual(@as(usize, 1), call.calls);
    try std.testing.expectEqual(@as(u64, 0), clock.total());

    clock = .{};
    hooks = fakeHooks(&clock);
    hooks.hint_fn = Hints.three_seconds;
    call = .{ .fails_left = 1 };
    try run(default_policy, hooks, &call, FakeCall.call);
    try std.testing.expectEqual(@as(usize, 2), call.calls);
    try std.testing.expectEqual(@as(u64, 3000), clock.total());

    clock = .{};
    hooks = fakeHooks(&clock);
    hooks.hint_fn = Hints.one_minute;
    call = .{ .fails_left = 10 };
    try std.testing.expectError(error.RateLimited, run(default_policy, hooks, &call, FakeCall.call));
    try std.testing.expectEqual(@as(usize, 1), call.calls);
    try std.testing.expectEqual(@as(u64, 0), clock.total());
}

const ScriptedCancel = struct {
    /// Devuelve true a partir de la consulta n.º `armed_at` (1-based).
    armed_at: usize,
    checks: usize = 0,

    fn isCancelled(raw: ?*anyopaque) bool {
        const self: *ScriptedCancel = @ptrCast(@alignCast(raw.?));
        self.checks += 1;
        return self.checks >= self.armed_at;
    }
};

fn fakeHooks(clock: *FakeClock) Hooks {
    return .{
        .sleep_ctx = clock,
        .sleep_fn = FakeClock.sleep,
        .jitter_fn = zeroJitter,
    };
}

test "B2 backoffMs: exponencial, tope cap_ms y jitter acotado" {
    const p = Policy{ .base_ms = 500, .cap_ms = 4_000, .max_retries = 10, .total_budget_ms = 999_999 };
    // Sin jitter la espera es exactamente la mitad fija del span.
    try std.testing.expectEqual(@as(u64, 250), backoffMs(p, 0, 0));
    try std.testing.expectEqual(@as(u64, 500), backoffMs(p, 1, 0));
    try std.testing.expectEqual(@as(u64, 1_000), backoffMs(p, 2, 0));
    try std.testing.expectEqual(@as(u64, 2_000), backoffMs(p, 3, 0));
    // Cap: a partir de 4_000 el span no crece más.
    try std.testing.expectEqual(@as(u64, 2_000), backoffMs(p, 4, 0));
    try std.testing.expectEqual(@as(u64, 2_000), backoffMs(p, 20, 0));
    // Con jitter máximo la espera queda por debajo del span (permille ≤ 1023).
    try std.testing.expect(backoffMs(p, 0, 1023) < 500);
    try std.testing.expect(backoffMs(p, 0, 1023) >= 250);
    // Rangos disjuntos → estrictamente creciente sea cual sea el jitter.
    var prev_max: u64 = 0;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const lo = backoffMs(p, i, 0);
        const hi = backoffMs(p, i, 1023);
        try std.testing.expect(lo > prev_max);
        try std.testing.expect(lo <= hi);
        prev_max = hi;
    }
}

test "B2: un 429 transitorio reintenta con esperas crecientes y completa" {
    var fake = FakeCall{ .fails_left = 2 };
    var clock = FakeClock{};
    var rec = RetryRecorder{};
    var hooks = fakeHooks(&clock);
    hooks.retry_ctx = &rec;
    hooks.on_retry_fn = RetryRecorder.onRetry;
    try run(
        .{ .base_ms = 500, .cap_ms = 4_000, .max_retries = 3, .total_budget_ms = 8_000 },
        hooks,
        &fake,
        FakeCall.call,
    );
    // 1 intento + 2 reintentos, sobre el MISMO contexto: ni orden ni envío nuevo.
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expect(fake.same_ctx_every_time);
    // Dos esperas lógicas, estrictamente crecientes (jitter=0 → mitad fija).
    try std.testing.expectEqual(@as(usize, 2), rec.count);
    try std.testing.expectEqual(@as(u64, 250), rec.waits[0]);
    try std.testing.expectEqual(@as(u64, 500), rec.waits[1]);
    // El reloj fake durmió la suma real en cortes de <= 50 ms: 750 ms en total.
    try std.testing.expectEqual(@as(u64, 750), clock.total());
    try std.testing.expect(clock.count > 2);
}

test "B2: un 429 persistente agota los reintentos y falla honesto" {
    var fake = FakeCall{ .fails_left = 99 };
    var clock = FakeClock{};
    try std.testing.expectError(error.RateLimited, run(
        .{ .base_ms = 500, .cap_ms = 4_000, .max_retries = 3, .total_budget_ms = 8_000 },
        fakeHooks(&clock),
        &fake,
        FakeCall.call,
    ));
    // 1 + max_retries intentos, 1750 ms dormidos en cortes. El error
    // propagado es el RateLimited real — no se disfraza ni se inventa otro.
    try std.testing.expectEqual(@as(usize, 4), fake.calls);
    try std.testing.expectEqual(@as(u64, 250 + 500 + 1_000), clock.total());
}

test "B2: un error que no es 429 pasa directo, sin espera ni reintento" {
    var fake = FakeCall{ .fails_left = 5, .fail_error = error.AuthFailed };
    var clock = FakeClock{};
    try std.testing.expectError(error.AuthFailed, run(
        default_policy,
        fakeHooks(&clock),
        &fake,
        FakeCall.call,
    ));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), clock.count);
}

test "B2: la cancelación interrumpe la espera y no llama más" {
    var fake = FakeCall{ .fails_left = 9 };
    var clock = FakeClock{};
    // Se arma en la segunda consulta: la primera es la de "¿cancelado ya?" tras
    // el primer 429; la siguiente sale dentro de sleepInterruptible.
    var cancel = ScriptedCancel{ .armed_at = 2 };
    var hooks = fakeHooks(&clock);
    hooks.cancel_ctx = &cancel;
    hooks.is_cancelled_fn = ScriptedCancel.isCancelled;
    try std.testing.expectError(error.Cancelled, run(
        default_policy,
        hooks,
        &fake,
        FakeCall.call,
    ));
    // Se cortó durante la primera espera: una sola llamada al proveedor y el
    // error propagado es Cancelled, no RateLimited ni un falso éxito. El
    // corte puede llegar ANTES del primer tramo de sueño: cero dormido.
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(u64, 0), clock.total());
}

test "B2: el presupuesto total de espera corta antes de agotar max_retries" {
    var fake = FakeCall{ .fails_left = 9 };
    var clock = FakeClock{};
    // Presupuesto de 300 ms: admite la primera espera (250) pero la segunda
    // (500) lo rompería → se propaga RateLimited tras 2 llamadas.
    try std.testing.expectError(error.RateLimited, run(
        .{ .base_ms = 500, .cap_ms = 4_000, .max_retries = 5, .total_budget_ms = 300 },
        fakeHooks(&clock),
        &fake,
        FakeCall.call,
    ));
    // Solo se pagó la primera espera (250 ms): la segunda (500) rompería el
    // presupuesto → se propaga el RateLimited tras la segunda llamada.
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(u64, 250), clock.total());
}

const RetryRecorder = struct {
    indices: [8]u32 = [_]u32{0} ** 8,
    waits: [8]u64 = [_]u64{0} ** 8,
    count: usize = 0,

    fn onRetry(raw: ?*anyopaque, retry_index: u32, wait_ms: u64) void {
        const self: *RetryRecorder = @ptrCast(@alignCast(raw.?));
        self.indices[self.count] = retry_index;
        self.waits[self.count] = wait_ms;
        self.count += 1;
    }
};

test "B2: on_retry recibe índice y espera de cada reintento programado" {
    var fake = FakeCall{ .fails_left = 2 };
    var clock = FakeClock{};
    var rec = RetryRecorder{};
    var hooks = fakeHooks(&clock);
    hooks.retry_ctx = &rec;
    hooks.on_retry_fn = RetryRecorder.onRetry;
    try run(default_policy, hooks, &fake, FakeCall.call);
    try std.testing.expectEqual(@as(usize, 2), rec.count);
    try std.testing.expectEqual(@as(u32, 0), rec.indices[0]);
    try std.testing.expectEqual(@as(u32, 1), rec.indices[1]);
    try std.testing.expect(rec.waits[1] > rec.waits[0]);
}
