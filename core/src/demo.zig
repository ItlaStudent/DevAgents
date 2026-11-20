const std = @import("std");
const core = @import("core");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== DevAgents Fase 1 Demo ===\n", .{});
    std.debug.print("El coordinador mock reparte 10 tareas a 4 workers paralelos\n\n", .{});

    var scheduler = try core.scheduler.Scheduler.init(allocator, core.scheduler.defaultWorkHandler);
    defer scheduler.deinit();

    // Crear 10 tareas
    for (0..10) |i| {
        const id = try std.fmt.allocPrint(allocator, "task-{d}", .{i});
        defer allocator.free(id);
        const desc = try std.fmt.allocPrint(allocator, "Process data chunk {d}", .{i});
        defer allocator.free(desc);
        const task = try core.scheduler.Task.create(allocator, id, desc, @intCast(10 - i), 2);
        try scheduler.enqueueTask(task);
    }
    std.debug.print("[+] 10 tareas encoladas\n\n", .{});

    // Iniciar scheduler (pool auto-crea 4 workers en hilos reales)
    try scheduler.start();
    std.debug.print("[*] Scheduler ejecutando con pool de 4 workers...\n", .{});
    scheduler.runAll();
    std.debug.print("    Progreso: {d}/10 completadas\n", .{scheduler.getCompletedTasks()});
    scheduler.stop();
    std.debug.print("\n[+] Scheduler detenido\n", .{});

    // Reporte
    const report = try scheduler.report(allocator);
    defer allocator.free(report);
    std.debug.print("\n{s}\n", .{report});

    // ── Sandbox por worker (T-F1-08) ─────────────────────────────────
    std.debug.print("[*] Sandbox FS por worker:\n", .{});
    var sb = try core.sandbox.Sandbox.init(allocator, "sandbox\\w1");
    defer sb.deinit();
    std.debug.print("    escritura en 'output/result.txt' permitida: {}\n", .{sb.isAllowed("output\\result.txt")});
    std.debug.print("    escritura en '..\\w2\\steal.txt' permitida: {} (rechazada)\n", .{sb.isAllowed("..\\w2\\steal.txt")});

    // ── Integración por contrato (T-F1-09) ───────────────────────────
    std.debug.print("\n[*] Validando piezas contra contrato antes de integrar...\n", .{});
    var contract = try core.contracts.Contract.init(allocator, "data-chunk", &.{
        .{ .name = "result", .field_type = .string, .required = true },
    });
    defer contract.deinit();

    var integrated: usize = 0;
    var rejected: usize = 0;
    for (scheduler.tasks.items) |task| {
        // Cada tarea completada produce una pieza con un campo `result`.
        const piece = [_]core.contracts.ProducedField{
            .{ .name = "result", .field_type = if (task.result != null) .string else .any },
        };
        if (task.result == null) {
            rejected += 1;
            continue;
        }
        core.contracts.Assembler.assemble(&contract, &piece) catch {
            rejected += 1;
            continue;
        };
        integrated += 1;
    }
    std.debug.print("    Piezas integradas por contrato: {d}/10 (rechazadas: {d})\n", .{ integrated, rejected });

    std.debug.print("\n=== Demo completado ===\n", .{});
}
