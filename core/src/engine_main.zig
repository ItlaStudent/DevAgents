//! D4 — el proceso HIJO del motor.
//!
//! Un ejecutable diminuto cuyo único trabajo, en este primer tramo, es servir
//! `da_status` por el bus de tuberías con nombre. La lógica vive en
//! `engine_process.serve`, no aquí: así el test de aceptación ejercita el mismo
//! código que corre en producción.
//!
//! Se invoca como `devagents-engine.exe --engine-pipe <nombre>`. Sin ese
//! argumento no arranca: un motor sin tubería no tiene con quién hablar, y
//! quedarse escuchando en un nombre por defecto sería peor que fallar.

const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var it = try init.minimal.args.iterateAllocator(allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |a| try args.append(allocator, a);

    var pipe_name: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (std.mem.eql(u8, args.items[i], "--engine-pipe") and i + 1 < args.items.len) {
            pipe_name = args.items[i + 1];
            i += 1;
        }
    }

    const name = pipe_name orelse {
        std.debug.print("uso: devagents-engine --engine-pipe <nombre>\n", .{});
        return error.MissingPipeName;
    };

    try core.engine_process.serve(allocator, name);
}
