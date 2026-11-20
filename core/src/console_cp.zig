const std = @import("std");
const builtin = @import("builtin");

/// la CLI escribe UTF-8 (bytes crudos) a stdout/stdin, pero Windows
/// no interpreta esos bytes como UTF-8 si la consola queda en su pagina OEM
/// (850/437). El sintoma medido: `devagents-core.exe --help` muestra
/// «Programaci├│n»; con `chcp 65001` delante se lee bien. Este modulo fija la
/// pagina de codigos al arrancar y la RESTAURA al salir, tambien si `run`
/// devuelve error. Sin consola (salida redirigida a archivo o tuberia), las
/// llamadas devuelven 0 y el guard no toca nada: los bytes UTF-8 ya son
/// correctos y no se altera ninguna pagina ajena.
pub const UTF8_CODE_PAGE: u32 = 65001;

extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCP(code_page: u32) callconv(.winapi) c_int;

/// Llamadas al sistema inyectables: la prueba usa un doble que registra las
/// llamadas y simula la pagina actual, sin tocar la consola real.
pub const Api = struct {
    ctx: ?*anyopaque = null,
    get_output_cp: *const fn (?*anyopaque) u32,
    set_output_cp: *const fn (?*anyopaque, u32) c_int,
    get_input_cp: *const fn (?*anyopaque) u32,
    set_input_cp: *const fn (?*anyopaque, u32) c_int,
};

pub fn systemApi() Api {
    return .{
        .get_output_cp = systemGetOutputCp,
        .set_output_cp = systemSetOutputCp,
        .get_input_cp = systemGetInputCp,
        .set_input_cp = systemSetInputCp,
    };
}

fn systemGetOutputCp(_: ?*anyopaque) u32 {
    if (builtin.os.tag != .windows) return 0;
    return GetConsoleOutputCP();
}

fn systemSetOutputCp(_: ?*anyopaque, code_page: u32) c_int {
    if (builtin.os.tag != .windows) return 0;
    return SetConsoleOutputCP(code_page);
}

fn systemGetInputCp(_: ?*anyopaque) u32 {
    if (builtin.os.tag != .windows) return 0;
    return GetConsoleCP();
}

fn systemSetInputCp(_: ?*anyopaque, code_page: u32) c_int {
    if (builtin.os.tag != .windows) return 0;
    return SetConsoleCP(code_page);
}

/// Guard de la pagina de codigos: `install` guarda la pagina actual (0 = no hay
/// consola) y fija UTF-8; `restore` devuelve la original. Es idempotente: tras
/// restaurar, los valores guardados quedan a 0 y otra llamada no hace nada.
pub const Guard = struct {
    api: Api,
    saved_output_cp: u32 = 0,
    saved_input_cp: u32 = 0,

    pub fn install(api: Api) Guard {
        var guard = Guard{ .api = api };
        guard.saved_output_cp = api.get_output_cp(api.ctx);
        if (guard.saved_output_cp != 0) _ = api.set_output_cp(api.ctx, UTF8_CODE_PAGE);
        guard.saved_input_cp = api.get_input_cp(api.ctx);
        if (guard.saved_input_cp != 0) _ = api.set_input_cp(api.ctx, UTF8_CODE_PAGE);
        return guard;
    }

    /// r2: registra este guard en el modulo. `main` lo llama justo tras
    /// instalarlo para que `console_cp.exit` pueda restaurarlo en las salidas
    /// que usan `std.process.exit` (que NO ejecutan los `defer`).
    pub fn activate(self: *Guard) void {
        active_guard = self;
    }

    pub fn restore(self: *Guard) void {
        if (active_guard == self) active_guard = null;
        if (self.saved_output_cp != 0) {
            _ = self.api.set_output_cp(self.api.ctx, self.saved_output_cp);
            self.saved_output_cp = 0;
        }
        if (self.saved_input_cp != 0) {
            _ = self.api.set_input_cp(self.api.ctx, self.saved_input_cp);
            self.saved_input_cp = 0;
        }
    }
};

/// Guard activo (el de `main`). Sin el, `exit`/`restoreActive` no tocan nada:
/// los llamadores que no pasan por `main` (p. ej. c_api) se comportan igual
/// que antes de este modulo.
var active_guard: ?*Guard = null;

/// Restaura el guard activo, si lo hay. Idempotente.
pub fn restoreActive() void {
    if (active_guard) |guard| guard.restore();
}

/// Punto UNICO de salida de la CLI: restaura la pagina de consola y delega la
/// terminacion en `exit_fn`. En produccion `exit` pasa `systemExit`
/// (std.process.exit); la prueba inyecta un doble que registra el codigo y
/// devuelve, para comprobar la restauracion sin matar al runner.
pub fn exitWith(exit_fn: *const fn (u8) void, code: u8) void {
    restoreActive();
    exit_fn(code);
}

/// Salida de la CLI: `exitWith` + `std.process.exit`. Todo `std.process.exit`
/// de la CLI pasa por aqui para que la consola no se quede en 65001.
pub fn exit(code: u8) noreturn {
    exitWith(systemExit, code);
    unreachable; // systemExit no retorna: std.process.exit es noreturn.
}

fn systemExit(code: u8) void {
    std.process.exit(code);
}

const Fake = struct {
    output_cp: u32,
    input_cp: u32,
    output_sets: [8]u32 = [_]u32{0} ** 8,
    input_sets: [8]u32 = [_]u32{0} ** 8,
    output_set_count: usize = 0,
    input_set_count: usize = 0,

    fn api(self: *Fake) Api {
        return .{
            .ctx = self,
            .get_output_cp = getOutput,
            .set_output_cp = setOutput,
            .get_input_cp = getInput,
            .set_input_cp = setInput,
        };
    }

    fn getOutput(ctx: ?*anyopaque) u32 {
        return @as(*Fake, @ptrCast(@alignCast(ctx.?))).output_cp;
    }

    fn setOutput(ctx: ?*anyopaque, code_page: u32) c_int {
        const self = @as(*Fake, @ptrCast(@alignCast(ctx.?)));
        self.output_sets[self.output_set_count] = code_page;
        self.output_set_count += 1;
        self.output_cp = code_page;
        return 1;
    }

    fn getInput(ctx: ?*anyopaque) u32 {
        return @as(*Fake, @ptrCast(@alignCast(ctx.?))).input_cp;
    }

    fn setInput(ctx: ?*anyopaque, code_page: u32) c_int {
        const self = @as(*Fake, @ptrCast(@alignCast(ctx.?)));
        self.input_sets[self.input_set_count] = code_page;
        self.input_set_count += 1;
        self.input_cp = code_page;
        return 1;
    }
};

fn runGuarded(api: Api, fail: bool) !void {
    var guard = Guard.install(api);
    defer guard.restore();
    if (fail) return error.Boom;
}

test "CK-MOT-026: la CLI fija la consola a UTF-8 y restaura la original" {
    // Consola real (pagina 850): al instalar se fija 65001 y al restaurar vuelve 850.
    var fake: Fake = .{ .output_cp = 850, .input_cp = 850 };
    var guard = Guard.install(fake.api());
    try std.testing.expectEqual(@as(u32, 65001), fake.output_cp);
    try std.testing.expectEqual(@as(u32, 65001), fake.input_cp);
    guard.restore();
    try std.testing.expectEqual(@as(u32, 850), fake.output_cp);
    try std.testing.expectEqual(@as(u32, 850), fake.input_cp);
    try std.testing.expectEqualSlices(u32, &.{ 65001, 850 }, fake.output_sets[0..fake.output_set_count]);
    try std.testing.expectEqualSlices(u32, &.{ 65001, 850 }, fake.input_sets[0..fake.input_set_count]);

    // Ruta de error: el defer del guard restaura igual.
    var fake_err: Fake = .{ .output_cp = 850, .input_cp = 850 };
    try std.testing.expectError(error.Boom, runGuarded(fake_err.api(), true));
    try std.testing.expectEqual(@as(u32, 850), fake_err.output_cp);
    try std.testing.expectEqual(@as(u32, 850), fake_err.input_cp);
    try std.testing.expectEqualSlices(u32, &.{ 65001, 850 }, fake_err.output_sets[0..fake_err.output_set_count]);

    // Ruta normal: el defer del guard restaura igual.
    var fake_ok: Fake = .{ .output_cp = 850, .input_cp = 850 };
    try runGuarded(fake_ok.api(), false);
    try std.testing.expectEqual(@as(u32, 850), fake_ok.output_cp);
    try std.testing.expectEqual(@as(u32, 850), fake_ok.input_cp);

    // Sin consola (CP 0): no se toca nada, ni al instalar ni al restaurar.
    var fake_none: Fake = .{ .output_cp = 0, .input_cp = 0 };
    var guard_none = Guard.install(fake_none.api());
    guard_none.restore();
    try std.testing.expectEqual(@as(usize, 0), fake_none.output_set_count);
    try std.testing.expectEqual(@as(usize, 0), fake_none.input_set_count);

    // Consola con salida pero sin entrada (CP de entrada 0): solo se fija la salida.
    var fake_out_only: Fake = .{ .output_cp = 437, .input_cp = 0 };
    var guard_out_only = Guard.install(fake_out_only.api());
    try std.testing.expectEqual(@as(u32, 65001), fake_out_only.output_cp);
    guard_out_only.restore();
    try std.testing.expectEqual(@as(u32, 437), fake_out_only.output_cp);
    try std.testing.expectEqual(@as(usize, 0), fake_out_only.input_set_count);
}

/// Doble de `std.process.exit` para la prueba r2: registra el codigo recibido y
/// devuelve en vez de terminar el proceso del runner.
var fake_exit_code: u8 = 255;
var fake_exit_calls: usize = 0;

fn fakeExit(code: u8) void {
    fake_exit_code = code;
    fake_exit_calls += 1;
}

test "CK-MOT-026 r2: una salida con codigo distinto de 0 restaura la pagina antes de terminar" {
    fake_exit_code = 255;
    fake_exit_calls = 0;

    // main instala el guard y lo activa; la CLI sale con codigo 2 (comando
    // desconocido / uso invalido) por console_cp.exit.
    var fake: Fake = .{ .output_cp = 850, .input_cp = 850 };
    var guard = Guard.install(fake.api());
    guard.activate();

    exitWith(fakeExit, 2);

    // La pagina volvio a la original aunque la salida no sea por retorno.
    try std.testing.expectEqual(@as(u32, 850), fake.output_cp);
    try std.testing.expectEqual(@as(u32, 850), fake.input_cp);
    try std.testing.expectEqualSlices(u32, &.{ 65001, 850 }, fake.output_sets[0..fake.output_set_count]);
    try std.testing.expectEqualSlices(u32, &.{ 65001, 850 }, fake.input_sets[0..fake.input_set_count]);
    // La terminacion recibio el codigo pedido (ruta distinta de 0).
    try std.testing.expectEqual(@as(u8, 2), fake_exit_code);
    try std.testing.expectEqual(@as(usize, 1), fake_exit_calls);

    // El registro queda limpio: una segunda salida (o el defer de main) no
    // vuelve a tocar la consola.
    exitWith(fakeExit, 1);
    try std.testing.expectEqual(@as(usize, 2), fake_exit_calls);
    try std.testing.expectEqual(@as(u32, 850), fake.output_cp);
    try std.testing.expectEqual(@as(usize, 2), fake.output_set_count);
    try std.testing.expectEqual(@as(usize, 2), fake.input_set_count);
}
