const std = @import("std");
const core = @import("core");

/// GATE F6 LIVE (T-F6-01): memoria compartida contra el BINARIO ENGRAM REAL.
///
/// A diferencia de `gate-f6` (mock determinista, sin red), este gate lanza el binario
/// engram real (`engram mcp`, transporte stdio) como proceso hijo y demuestra el recuerdo
/// entre sesiones CONTRA EL ALMACÉN REAL de engram:
///   Sesión 1: conecta, guarda un hallazgo (mem_save) y un resumen (mem_session_summary).
///   Sesión 2: NUEVA conexión (nuevo proceso engram), carga contexto (mem_context) y
///             verifica que el hallazgo de la sesión 1 fue recordado.
///
/// El binario engram se toma de la variable de entorno ENGRAM_BIN (por defecto "engram",
/// resuelto vía PATH). engram bindea la memoria al repo por git_root, así que se ejecuta
/// desde la raíz del proyecto y auto-detecta el proyecto (no se pasa `project` explícito).
///
/// Marcador estable: el recuerdo se prueba localizando MARKER en el contexto devuelto.
const MARKER = "GATE-F6-LIVE: usar RAII y defer para gestionar recursos en C/C++/Zig";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const engram_bin = std.process.Environ.getAlloc(init.minimal.environ, allocator, "ENGRAM_BIN") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try allocator.dupe(u8, "engram"),
        else => return err,
    };
    defer allocator.free(engram_bin);

    std.debug.print("=== GATE F6 LIVE — memoria compartida contra Engram REAL ===\n\n", .{});
    std.debug.print("Binario engram: {s}\n\n", .{engram_bin});

    // ── Sesión 1: guardar hallazgo + resumen ────────────────────────────
    std.debug.print("[Sesión 1] Conectando a engram y guardando hallazgo...\n", .{});
    {
        var mem = core.engram_memory.EngramMemory.connect(allocator, engram_bin, "") catch |e| {
            std.debug.print("  No se pudo conectar a engram ({s}). ¿Está instalado y en ENGRAM_BIN/PATH?\n", .{@errorName(e)});
            return e;
        };
        defer mem.deinit();
        const bk = mem.backend();
        bk.saveFinding(MARKER);
        bk.saveSessionSummary("Sesión de gate F6 live: 1 hallazgo guardado.", "");
        std.debug.print("  Hallazgo y resumen guardados (mem_save + mem_session_summary).\n", .{});
    }

    // ── Sesión 2: nueva conexión, recordar ──────────────────────────────
    std.debug.print("[Sesión 2] Nueva conexión, cargando contexto...\n", .{});
    var mem2 = try core.engram_memory.EngramMemory.connect(allocator, engram_bin, "");
    defer mem2.deinit();
    const bk2 = mem2.backend();
    const ctx = bk2.loadContext(allocator, "") orelse {
        std.debug.print("  mem_context devolvió null — sin recuerdo.\n", .{});
        return error.NoRecall;
    };
    defer allocator.free(ctx);

    if (std.mem.indexOf(u8, ctx, "GATE-F6-LIVE") == null) {
        std.debug.print("  El contexto NO contiene el marcador de la sesión 1.\n  Contexto: {s}\n", .{ctx});
        return error.MarkerNotRecalled;
    }

    std.debug.print("  ✓ loadContext devolvió contexto (no null)\n", .{});
    std.debug.print("  ✓ El contexto contiene el marcador de la sesión 1\n\n", .{});
    std.debug.print("=== GATE F6 LIVE: recuerdo entre sesiones contra Engram real VERIFICADO ===\n", .{});
}
