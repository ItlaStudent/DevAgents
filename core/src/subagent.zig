//! D7 (P14/E3) — contexto y presupuesto por subagente.
//!
//! El problema que resuelve, tal como se enunció el 2026-08-09: *"cuando una
//! tarea es ruidosa (revisar 10.000 líneas de logs, ejecutar suites masivas de
//! tests o hacer búsquedas exploratorias), el superagente delega en un
//! subagente con su propia ventana de contexto; los logs detallados no
//! contaminan el presupuesto de tokens del hilo principal"*.
//!
//! Hasta aquí no había nada de eso. Todas las tareas de una ola compartían el
//! mismo `FanoutContext` y **el mismo bloque de contexto**: `buildUpstreamContext`
//! concatenaba TODOS los archivos guardados hasta ese momento, en orden de
//! guardado, y cortaba al llegar a 32 KB. Dos consecuencias medibles:
//!
//! 1. **Todo el mundo ve todo.** Una tarea que depende solo de `t1` recibía
//!    también lo que produjeron ramas con las que no tiene nada que ver.
//! 2. **El que llega primero se lo come.** El tope de 32 KB se reparte por
//!    orden de llegada: un artefacto grande de la rama A dejaba a la rama B
//!    con cero contexto, sin que nada lo dijera. Eso no es un presupuesto, es
//!    una carrera.
//!
//! Este módulo es la parte decidible —y por tanto probable— de las dos: a quién
//! ve cada subagente, y cuánto sitio le toca. No lee archivos ni habla con
//! nadie; eso sigue en `superagent.zig`.

const std = @import("std");
const planner = @import("planner.zig");
const model_router = @import("model_router.zig");

/// Tope total del bloque de contexto ascendente. Es el que ya usaba
/// `buildUpstreamContext`; se conserva para no cambiar el tamaño del prompt.
pub const TOPE_CONTEXTO_TOTAL: usize = 32 * 1024;

/// Presupuesto de una rama.
pub const Presupuesto = struct {
    /// Bytes de contexto ascendente que puede consumir ESTE subagente.
    bytes_contexto: usize,
    /// Llamadas al LLM que puede gastar la rama antes de rendirse.
    ///
    /// Hoy solo lo consume la cadena de candidatos de `runTaskInWave`. Vale
    /// como tope duro: un subagente en bucle no puede quemar la cuota entera.
    max_llamadas: usize = 4,
};

/// Reparto del tope total entre las ramas vivas de la ola.
///
/// A partes iguales y con suelo: con muchas ramas, un reparto exacto daría
/// trozos tan pequeños que no cabría ni la cabecera de un archivo, y un
/// contexto truncado a media línea confunde al modelo más que no darle nada.
/// Por debajo del suelo se prefiere dar el suelo aunque la suma pase del tope:
/// el corte real por archivo sigue existiendo aguas abajo.
pub const SUELO_POR_RAMA: usize = 4 * 1024;

pub fn presupuestoPorRama(ramas: usize) Presupuesto {
    if (ramas == 0) return .{ .bytes_contexto = TOPE_CONTEXTO_TOTAL };
    const parte = TOPE_CONTEXTO_TOTAL / ramas;
    return .{ .bytes_contexto = @max(parte, SUELO_POR_RAMA) };
}

/// ¿Esta tarea juzga la ENTREGA o construye una pieza?
///
/// Un auditor o un probador que solo ve su rama no puede hacer su trabajo: la
/// entrega es la ORDEN, no la tarea. Es exactamente lo que costó las órdenes
/// #184 y #186 —un `index.html` que enlazaba archivos que nadie entregó pasó
/// la auditoría— y lo que arregló M4. Aislar al auditor sería reabrir aquello.
///
/// Así que el aislamiento se aplica a quien PRODUCE. Quien VERIFICA ve todo.
pub fn juzgaLaEntregaEntera(t: model_router.TaskType) bool {
    return switch (t) {
        .auditar, .testear => true,
        .programar, .programar_c, .programar_cpp, .programar_zig, .planificar, .corregir, .documentar, .investigar, .resumir, .ejecutar, .disenar, .ui => false,
    };
}

/// Cierre transitivo de `depends_on` para `task_id`, sin incluirse a sí misma.
///
/// El grafo ya viene sin ciclos (`resolveWaves` los detecta antes), pero esta
/// función NO da eso por hecho: lleva su propia marca de visitados. Una tarea
/// que se cuele con un ciclo debe dar una lista finita, no colgar el despacho.
///
/// El llamador es propietario del slice devuelto (los elementos son préstamos de
/// `tasks`, no copias).
pub fn ancestrosDe(
    allocator: std.mem.Allocator,
    tasks: []const planner.PlannedTask,
    task_id: []const u8,
) ![]const []const u8 {
    var vistos = std.StringHashMap(void).init(allocator);
    defer vistos.deinit();
    var salida = std.ArrayList([]const u8).empty;
    errdefer salida.deinit(allocator);

    var pila = std.ArrayList([]const u8).empty;
    defer pila.deinit(allocator);
    try pila.append(allocator, task_id);

    while (pila.pop()) |actual| {
        const t = buscarTarea(tasks, actual) orelse continue;
        for (t.depends_on) |dep| {
            if (vistos.contains(dep)) continue;
            try vistos.put(dep, {});
            try salida.append(allocator, dep);
            try pila.append(allocator, dep);
        }
    }

    return salida.toOwnedSlice(allocator);
}

fn buscarTarea(tasks: []const planner.PlannedTask, id: []const u8) ?planner.PlannedTask {
    for (tasks) |t| {
        if (std.mem.eql(u8, t.id, id)) return t;
    }
    return null;
}

/// Los índices de `rutas` que este subagente puede ver.
///
/// `duenos[i]` es el `task_id` que produjo `rutas[i]`; los dos arrays van en
/// paralelo y deben tener la misma longitud (si no, se devuelve vacío en vez de
/// indexar fuera: un desajuste es un defecto del llamador, no algo que deba
/// reventar en un hilo de fanout).
///
/// El llamador es propietario del slice devuelto.
pub fn indicesVisibles(
    allocator: std.mem.Allocator,
    tasks: []const planner.PlannedTask,
    task_id: []const u8,
    task_type: model_router.TaskType,
    rutas: []const []const u8,
    duenos: []const []const u8,
) ![]const usize {
    var salida = std.ArrayList(usize).empty;
    errdefer salida.deinit(allocator);
    if (rutas.len != duenos.len) return salida.toOwnedSlice(allocator);

    if (juzgaLaEntregaEntera(task_type)) {
        for (0..rutas.len) |i| try salida.append(allocator, i);
        return salida.toOwnedSlice(allocator);
    }

    const ancestros = try ancestrosDe(allocator, tasks, task_id);
    defer allocator.free(ancestros);

    for (duenos, 0..) |dueno, i| {
        for (ancestros) |a| {
            if (std.mem.eql(u8, a, dueno)) {
                try salida.append(allocator, i);
                break;
            }
        }
    }
    return salida.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

fn tareaDePrueba(id: []const u8, tipo: model_router.TaskType, deps: [][]const u8) planner.PlannedTask {
    return .{
        .id = id,
        .task_type = tipo,
        .department = "programacion",
        .description = "x",
        .contract_fields = &.{},
        .depends_on = deps,
    };
}

test "D7: los ancestros son el cierre TRANSITIVO, no solo los padres" {
    const allocator = std.testing.allocator;
    var t1_deps = [_][]const u8{};
    var t2_deps = [_][]const u8{"t1"};
    var t3_deps = [_][]const u8{"t2"};
    const tasks = [_]planner.PlannedTask{
        tareaDePrueba("t1", .programar, &t1_deps),
        tareaDePrueba("t2", .programar, &t2_deps),
        tareaDePrueba("t3", .programar, &t3_deps),
    };

    const a3 = try ancestrosDe(allocator, &tasks, "t3");
    defer allocator.free(a3);
    try std.testing.expectEqual(@as(usize, 2), a3.len);

    const a1 = try ancestrosDe(allocator, &tasks, "t1");
    defer allocator.free(a1);
    try std.testing.expectEqual(@as(usize, 0), a1.len);
}

test "D7: un ciclo no cuelga el despacho ni repite ancestros" {
    // `resolveWaves` ya rechaza ciclos, pero esta funcion corre en hilos de
    // fanout: si algun dia entra un grafo sucio, tiene que devolver algo finito.
    const allocator = std.testing.allocator;
    var a_deps = [_][]const u8{"tB"};
    var b_deps = [_][]const u8{"tA"};
    const tasks = [_]planner.PlannedTask{
        tareaDePrueba("tA", .programar, &a_deps),
        tareaDePrueba("tB", .programar, &b_deps),
    };
    const anc = try ancestrosDe(allocator, &tasks, "tA");
    defer allocator.free(anc);
    try std.testing.expectEqual(@as(usize, 2), anc.len);
}

test "D7: dos ramas hermanas NO se ven entre si" {
    // El criterio de aceptacion de D7, en su forma decidible: t2 y t3 cuelgan
    // las dos de t1 y son hermanas. t3 debe ver lo de t1 y lo suyo, jamas lo de
    // t2. Antes de este modulo veia los tres archivos, porque el contexto era
    // uno solo para toda la ola.
    const allocator = std.testing.allocator;
    var t1_deps = [_][]const u8{};
    var t2_deps = [_][]const u8{"t1"};
    var t3_deps = [_][]const u8{"t1"};
    const tasks = [_]planner.PlannedTask{
        tareaDePrueba("t1", .programar, &t1_deps),
        tareaDePrueba("t2", .programar, &t2_deps),
        tareaDePrueba("t3", .programar, &t3_deps),
    };
    const rutas = [_][]const u8{ "base.zig", "rama_a.zig" };
    const duenos = [_][]const u8{ "t1", "t2" };

    const vis = try indicesVisibles(allocator, &tasks, "t3", .programar, &rutas, &duenos);
    defer allocator.free(vis);
    try std.testing.expectEqual(@as(usize, 1), vis.len);
    try std.testing.expectEqual(@as(usize, 0), vis[0]); // solo base.zig, de t1
}

test "D7: el auditor SI ve la entrega entera" {
    // Aislar al auditor reabriria M4 (ordenes #184 y #186): un index.html que
    // enlaza archivos que nadie entrego, aprobado porque el auditor no los
    // miraba. La entrega es la ORDEN.
    const allocator = std.testing.allocator;
    var t1_deps = [_][]const u8{};
    var t2_deps = [_][]const u8{"t1"};
    var taud_deps = [_][]const u8{"t1"};
    const tasks = [_]planner.PlannedTask{
        tareaDePrueba("t1", .programar, &t1_deps),
        tareaDePrueba("t2", .programar, &t2_deps),
        tareaDePrueba("taud", .auditar, &taud_deps),
    };
    const rutas = [_][]const u8{ "index.html", "styles.css" };
    const duenos = [_][]const u8{ "t1", "t2" };

    const vis = try indicesVisibles(allocator, &tasks, "taud", .auditar, &rutas, &duenos);
    defer allocator.free(vis);
    try std.testing.expectEqual(@as(usize, 2), vis.len);
}

test "D7: el presupuesto se reparte, no se lo come el primero" {
    // Con 4 ramas, ninguna puede reclamar los 32 KB enteros.
    const p4 = presupuestoPorRama(4);
    try std.testing.expectEqual(TOPE_CONTEXTO_TOTAL / 4, p4.bytes_contexto);
    try std.testing.expect(p4.bytes_contexto * 4 <= TOPE_CONTEXTO_TOTAL);

    // Con una sola rama, se lo lleva todo: no hay a quien dejar sitio.
    try std.testing.expectEqual(TOPE_CONTEXTO_TOTAL, presupuestoPorRama(1).bytes_contexto);

    // Con muchas, manda el suelo: un trozo de 300 bytes no es contexto, es ruido.
    try std.testing.expectEqual(SUELO_POR_RAMA, presupuestoPorRama(100).bytes_contexto);

    // Cero ramas no divide entre cero.
    try std.testing.expectEqual(TOPE_CONTEXTO_TOTAL, presupuestoPorRama(0).bytes_contexto);
}

test "D7: un desajuste rutas/duenos no indexa fuera" {
    const allocator = std.testing.allocator;
    var deps = [_][]const u8{};
    const tasks = [_]planner.PlannedTask{tareaDePrueba("t1", .programar, &deps)};
    const rutas = [_][]const u8{ "a", "b" };
    const duenos = [_][]const u8{"t1"};
    const vis = try indicesVisibles(allocator, &tasks, "t1", .programar, &rutas, &duenos);
    defer allocator.free(vis);
    try std.testing.expectEqual(@as(usize, 0), vis.len);
}
