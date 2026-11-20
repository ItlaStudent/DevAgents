const std = @import("std");
const core = @import("core");

/// La CLI es una superficie de usuario: los `std.log.debug` de los módulos
/// (sondas de sesión de las CLI externas, p. ej.) se colaban en `doctor` y en
/// la salida normal. En Debug el nivel por defecto es `.debug`; aquí se sube a
/// `.warn` para que solo queden avisos y errores reales.
pub const std_options: std.Options = .{
    .log_level = .warn,
    .unexpected_error_tracing = false,
};

pub fn main(init: std.process.Init) !void {
    // la salida es UTF-8; fijar la pagina de consola para que
    // Windows la muestre como tal y restaurarla al salir, tambien en error.
    var cp_guard = core.console_cp.Guard.install(core.console_cp.systemApi());
    defer cp_guard.restore();
    // r2: las salidas de la CLI con std.process.exit no ejecutan los defer;
    // activar el guard para que core.console_cp.exit lo restaure tambien ahi.
    cp_guard.activate();

    const allocator = init.gpa;
    var it = try init.minimal.args.iterateAllocator(allocator);
    defer it.deinit();

    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(allocator);
    while (it.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    try core.cli.Cli.run(allocator, arg_list.items);
}
