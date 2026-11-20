//! / H-G1-PERF - presupuesto del motor headless.
//!
//! Comprueba, sobre artefactos ReleaseSafe, que el binario del motor y la DLL
//! del nucleo no superan el limite de tamano y que el arranque headless del
//! motor (spawn + tuberia lista, el mismo camino que usa la cabina) no supera
//! el limite de tiempo como MEDIANA de cinco corridas.
//!
//! Uso:
//!   perf-budget-check <motor.exe> <nucleo.dll|-> <max_mb> <max_arranque_ms>
//!
//! Sale con error si cualquiera de los dos presupuestos se incumple. El limite
//! se recibe por argumento para poder demostrar el rojo sin tocar el codigo
//! (se le pasa un limite mas bajo).

const std = @import("std");
const core = @import("core");

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

const RUNS = 5;

fn usage() noreturn {
    std.debug.print(
        "uso: perf-budget-check <motor.exe> <nucleo.dll|-> <max_mb> <max_arranque_ms>\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const engine_path = args.next() orelse usage();
    const dll_path = args.next() orelse usage();
    const max_mb = std.fmt.parseInt(u64, args.next() orelse usage(), 10) catch usage();
    const max_startup_ms = std.fmt.parseInt(u64, args.next() orelse usage(), 10) catch usage();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const max_bytes = max_mb * 1_000_000;
    var failed = false;

    std.debug.print("[PERF] limite de tamano: {d} MB ({d} bytes)\n", .{ max_mb, max_bytes });
    if (try checkSize(io, "motor", engine_path, max_bytes)) failed = true;
    if (!std.mem.eql(u8, dll_path, "-")) {
        if (try checkSize(io, "DLL nucleo", dll_path, max_bytes)) failed = true;
    }

    std.debug.print("[PERF] limite de arranque headless: {d} ms (mediana de {d} corridas)\n", .{ max_startup_ms, RUNS });
    var samples: [RUNS]u64 = undefined;
    for (&samples, 0..) |*sample, i| {
        sample.* = try measureStartup(allocator, engine_path, i);
    }
    sortU64(samples[0..]);
    const median = samples[RUNS / 2];
    std.debug.print("[PERF] muestras: {any} ms; mediana: {d} ms\n", .{ samples, median });
    if (median > max_startup_ms) {
        std.debug.print(
            "[PERF] INCUMPLE arranque: mediana {d} ms > {d} ms\n",
            .{ median, max_startup_ms },
        );
        failed = true;
    }

    if (failed) {
        std.debug.print("[PERF] RESULT: FAIL\n", .{});
        return error.PerfBudgetExceeded;
    }
    std.debug.print("[PERF] RESULT: PASS\n", .{});
}

fn checkSize(io: std.Io, label: []const u8, path: []const u8, max_bytes: u64) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        std.debug.print("[PERF] {s}: no se pudo medir '{s}': {s}\n", .{ label, path, @errorName(err) });
        return true;
    };
    const mb = @as(f64, @floatFromInt(stat.size)) / 1_000_000.0;
    const over = stat.size > max_bytes;
    std.debug.print(
        "[PERF] {s}: {s} = {d} bytes ({d:.2} MB) -> {s}\n",
        .{ label, path, stat.size, mb, if (over) "INCUMPLE" else "ok" },
    );
    return over;
}

fn measureStartup(allocator: std.mem.Allocator, engine_path: []const u8, index: usize) !u64 {
    const session = try std.fmt.allocPrint(
        allocator,
        "perf-budget-{d}-{d}",
        .{ GetTickCount64(), index },
    );
    defer allocator.free(session);
    const pipe_name = try core.engine_process.pipeNameFor(allocator, session);
    defer allocator.free(pipe_name);

    var supervisor = try core.engine_process.Supervisor.init(allocator, engine_path, pipe_name);
    defer supervisor.deinit();

    const started = GetTickCount64();
    try supervisor.start();
    const elapsed = GetTickCount64() - started;
    const pid = supervisor.childPid() orelse 0;
    std.debug.print("[PERF] arranque #{d}: {d} ms (pid={d})\n", .{ index + 1, elapsed, pid });
    return elapsed;
}

fn sortU64(values: []u64) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const value = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > value) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = value;
    }
}
