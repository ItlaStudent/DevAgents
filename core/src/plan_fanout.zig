//! core/src/plan_fanout.zig — E5.17: descomposición paralela determinista.
//!
//! Pasada del motor ENTRE el plan analizado (normalizePlan) y el cálculo de
//! olas (resolveWaves). Reglas genéricas y probadas:
//!   (a) una tarea con dos o más salidas en módulos distintos (módulo =
//!       directorio padre del archivo) se separa en tareas hermanas que
//!       comparten un contrato de interfaz — un contract_field
//!       `interfaz_compartida` que nombra la frontera;
//!   (b) las pruebas se separan en una tarea dependiente si el plan las
//!       mezcla con la implementación (owns con archivos de test y de
//!       producción a la vez);
//!   (c) las hermanas heredan los depends_on del original: caen en la
//!       primera ola válida — una tarea raíz se reparte en la ola 1;
//!   (d) NO se separa lo que se importa mutuamente: si dos grupos de
//!       salidas se referencian entre sí (aristas del repo-map en ambos
//!       sentidos) o el contrato nombra archivos de ambos, quedan juntos.
//!
//! `local_wave_sequential` queda intacto: esta pasada solo cambia el grafo
//! de tareas; la decisión local-secuencial vive en el despachador de olas.
//!
//! Determinista: mismo (tasks, map) → mismo resultado. Sin llamadas de red.

const std = @import("std");
const planner = @import("planner.zig");
const contracts = @import("contracts.zig");
const model_router = @import("model_router.zig");
const repo_map = @import("repo_map.zig");

pub const Options = struct {
    /// RepoMap del repo de la orden para la guardia (d). Null → solo la
    /// guardia por contrato (los archivos nuevos aún no tienen aristas).
    map: ?*const repo_map.RepoMap = null,
};

pub const Report = struct {
    antes: usize,
    despues: usize,
    /// Líneas "a:t1→t1-m1,t1-m2" / "b:t2→t2,t2-test" — owned por `allocator`.
    reglas: []const []const u8,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.reglas) |r| allocator.free(r);
        allocator.free(self.reglas);
    }
};

fn isProducerType(t: model_router.TaskType) bool {
    return switch (t) {
        .programar, .programar_c, .programar_cpp, .programar_zig => true,
        else => false,
    };
}

/// ¿El path pinta a archivo de pruebas? Basename `test_*`, `*_test.*`,
/// `*.test.*`, `*_spec.*` o un componente de directorio `test`/`tests`/
/// `spec`/`__tests__`/`testing`.
fn isTestPath(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    var last: []const u8 = "";
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(seg, "test") or std.ascii.eqlIgnoreCase(seg, "tests") or
            std.ascii.eqlIgnoreCase(seg, "spec") or std.ascii.eqlIgnoreCase(seg, "__tests__") or
            std.ascii.eqlIgnoreCase(seg, "testing")) return true;
        last = seg;
    }
    if (std.ascii.startsWithIgnoreCase(last, "test_") or std.ascii.startsWithIgnoreCase(last, "test-")) return true;
    const stem = last[0 .. std.mem.lastIndexOfScalar(u8, last, '.') orelse last.len];
    if (std.ascii.endsWithIgnoreCase(stem, "_test") or std.ascii.endsWithIgnoreCase(stem, ".test") or
        std.ascii.endsWithIgnoreCase(stem, "_spec") or std.ascii.endsWithIgnoreCase(stem, ".spec")) return true;
    return false;
}

/// Módulo de una salida = su directorio padre, separadores normalizados.
/// "src/a.py" → "src"; "a.py" → "" (raíz).
fn moduleOf(path: []const u8) []const u8 {
    var end: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') end = i;
    }
    return path[0..end];
}

/// ¿El grupo de archivos `ga` referencia al grupo `gb` en el mapa?
/// (arista directa nodo→nodo; los archivos nuevos no están en el mapa y
/// devuelven false — la guardia por contrato cubre ese caso).
fn groupReferences(map: *const repo_map.RepoMap, ga: []const []const u8, gb: []const []const u8) bool {
    for (ga) |fa| {
        const ia = nodeIndex(map, fa) orelse continue;
        for (gb) |fb| {
            const ib = nodeIndex(map, fb) orelse continue;
            for (map.nodes[ia].edges) |e| {
                if (e == ib) return true;
            }
        }
    }
    return false;
}

fn nodeIndex(map: *const repo_map.RepoMap, path: []const u8) ?usize {
    for (map.nodes, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n.path, path)) return i;
    }
    return null;
}

fn baseName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Guardia por contrato: un campo cuyo valor (o nombre) menciona basenames
/// de DOS grupos a la vez ata esos grupos — la interfaz ya está declarada
/// para ambos juntos. Cobertura del caso sin repo-map.
fn contractBinds(fields: []const planner.ContractField, ga: []const []const u8, gb: []const []const u8) bool {
    for (fields) |f| {
        const texts = [2][]const u8{ f.name, f.value orelse "" };
        for (texts) |txt| {
            if (txt.len == 0) continue;
            var hit_a = false;
            var hit_b = false;
            for (ga) |p| {
                const b = baseName(p);
                if (b.len >= 3 and std.mem.indexOf(u8, txt, b) != null) hit_a = true;
            }
            for (gb) |p| {
                const b = baseName(p);
                if (b.len >= 3 and std.mem.indexOf(u8, txt, b) != null) hit_b = true;
            }
            if (hit_a and hit_b) return true;
        }
    }
    return false;
}

/// ¿Alguna tarea productora podría ser candidata a fanout (owns ≥2)?
/// El llamador lo usa para decidir si merece cargar el repo-map.
pub fn needsRepoMap(tasks: []const planner.PlannedTask) bool {
    for (tasks) |t| {
        if (isProducerType(t.task_type) and t.owns.len >= 2) return true;
        if (t.owns.len >= 2) {
            var tests: usize = 0;
            for (t.owns) |o| {
                if (isTestPath(o)) tests += 1;
            }
            if (tests > 0 and tests < t.owns.len) return true;
        }
    }
    return false;
}

// ── Clonación de tareas (mismo reparto de propiedad que Plan.deinit) ────

fn freeTask(allocator: std.mem.Allocator, task: planner.PlannedTask) void {
    allocator.free(task.id);
    allocator.free(task.department);
    allocator.free(task.description);
    for (task.contract_fields) |field| {
        allocator.free(field.name);
        if (field.value) |value| allocator.free(value);
    }
    allocator.free(task.contract_fields);
    for (task.depends_on) |d| allocator.free(d);
    allocator.free(task.depends_on);
    for (task.owns) |o| allocator.free(o);
    if (task.owns.len > 0) allocator.free(task.owns);
    if (task.deliverable) |d| allocator.free(d);
}

fn cloneStrings(allocator: std.mem.Allocator, items: []const []const u8) ![][]const u8 {
    const copy = try allocator.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |s| allocator.free(s);
        allocator.free(copy);
    }
    for (items, 0..) |s, i| {
        copy[i] = try allocator.dupe(u8, s);
        filled = i + 1;
    }
    return copy;
}

fn cloneFields(allocator: std.mem.Allocator, fields: []const planner.ContractField) ![]planner.ContractField {
    const copy = try allocator.alloc(planner.ContractField, fields.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |field| {
            allocator.free(field.name);
            if (field.value) |value| allocator.free(value);
        }
        allocator.free(copy);
    }
    for (fields, 0..) |field, i| {
        copy[i] = .{
            .name = try allocator.dupe(u8, field.name),
            .field_type = field.field_type,
            .required = field.required,
            .value = if (field.value) |raw| try allocator.dupe(u8, raw) else null,
        };
        filled = i + 1;
    }
    return copy;
}

fn cloneTask(allocator: std.mem.Allocator, task: planner.PlannedTask) !planner.PlannedTask {
    return .{
        .id = try allocator.dupe(u8, task.id),
        .task_type = task.task_type,
        .department = try allocator.dupe(u8, task.department),
        .description = try allocator.dupe(u8, task.description),
        .contract_fields = try cloneFields(allocator, task.contract_fields),
        .depends_on = try cloneStrings(allocator, task.depends_on),
        .owns = try cloneStrings(allocator, task.owns),
        .deliverable = if (task.deliverable) |d| try allocator.dupe(u8, d) else null,
    };
}

/// Grupos de salidas por módulo, con fusión por la guardia (d).
/// Devuelve índices de owns por grupo (slices owned por `allocator`).
fn moduleGroups(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    fields: []const planner.ContractField,
    map: ?*const repo_map.RepoMap,
) ![][]usize {
    var parent = try allocator.alloc(usize, files.len);
    defer allocator.free(parent);
    for (parent, 0..) |*p, i| p.* = i;
    const find = struct {
        fn f(par: []usize, x: usize) usize {
            var r = x;
            while (par[r] != r) r = par[r];
            var c = x;
            while (par[c] != r) {
                const next = par[c];
                par[c] = r;
                c = next;
            }
            return r;
        }
    }.f;

    // Unir por módulo (mismo directorio padre).
    for (files, 0..) |a, i| {
        for (files[i + 1 ..], i + 1..) |b, j| {
            if (std.mem.eql(u8, moduleOf(a), moduleOf(b))) {
                const ra = find(parent, i);
                const rb = find(parent, j);
                if (ra != rb) parent[rb] = ra;
            }
        }
    }
    // Fusión (d): imports mutuos en el repo-map o contrato que ata ambos.
    for (files, 0..) |_, i| {
        for (i + 1..files.len) |j| {
            const ri = find(parent, i);
            const rj = find(parent, j);
            if (ri == rj) continue;
            // Listas del grupo de cada raíz — se calculan por pareja, n es
            // pequeño (owns de una tarea, típicamente <10).
            var gi = std.ArrayList([]const u8).empty;
            defer gi.deinit(allocator);
            var gj = std.ArrayList([]const u8).empty;
            defer gj.deinit(allocator);
            for (files, 0..) |f, k| {
                if (find(parent, k) == ri) try gi.append(allocator, f);
                if (find(parent, k) == rj) try gj.append(allocator, f);
            }
            const mutual = if (map) |m|
                groupReferences(m, gi.items, gj.items) and groupReferences(m, gj.items, gi.items)
            else
                false;
            if (mutual or contractBinds(fields, gi.items, gj.items)) parent[rj] = ri;
        }
    }

    // Materializar grupos en orden de primera aparición.
    var order = std.ArrayList(usize).empty;
    defer order.deinit(allocator);
    var groups = std.ArrayList([]usize).empty;
    errdefer {
        for (groups.items) |g| allocator.free(g);
        groups.deinit(allocator);
    }
    for (files, 0..) |_, i| {
        const r = find(parent, i);
        var pos: ?usize = null;
        for (order.items, 0..) |rr, k| {
            if (rr == r) pos = k;
        }
        if (pos == null) {
            pos = order.items.len;
            try order.append(allocator, r);
            try groups.append(allocator, try allocator.alloc(usize, 0));
        }
        const g = groups.items[pos.?];
        const grown = try allocator.alloc(usize, g.len + 1);
        @memcpy(grown[0..g.len], g);
        if (g.len > 0) allocator.free(g);
        grown[g.len] = i;
        groups.items[pos.?] = grown;
    }
    return groups.toOwnedSlice(allocator);
}

fn uniqueSuffixId(allocator: std.mem.Allocator, base: []const u8, suffix: []const u8, taken: std.StringHashMap(void)) ![]const u8 {
    var serial: usize = 0;
    while (true) : (serial += 1) {
        const candidate = if (serial == 0)
            try std.fmt.allocPrint(allocator, "{s}-{s}", .{ base, suffix })
        else
            try std.fmt.allocPrint(allocator, "{s}-{s}-{d}", .{ base, suffix, serial });
        if (!taken.contains(candidate)) return candidate;
        allocator.free(candidate);
    }
}

/// Añade a la hermana el contrato de interfaz compartido (regla a).
fn appendInterfaceField(allocator: std.mem.Allocator, task: *planner.PlannedTask, orig_id: []const u8) !void {
    const grown = try allocator.alloc(planner.ContractField, task.contract_fields.len + 1);
    for (task.contract_fields, 0..) |f, i| grown[i] = f;
    grown[task.contract_fields.len] = .{
        .name = try allocator.dupe(u8, "interfaz_compartida"),
        .field_type = contracts.FieldType.string,
        .required = false,
        .value = try std.fmt.allocPrint(allocator, "fanout:{s}", .{orig_id}),
    };
    if (task.contract_fields.len > 0) allocator.free(task.contract_fields);
    task.contract_fields = grown;
}

/// La pasada. Devuelve Report (y reescribe `plan.tasks`) solo si algo se
/// separó de verdad; null = plan intacto. Toda la memoria nueva sale del
/// allocator del plan — Plan.deinit la recoge como siempre.
pub fn apply(plan: *planner.Plan, opts: Options) !?Report {
    const allocator = plan.allocator;
    const antes = plan.tasks.len;

    var taken = std.StringHashMap(void).init(allocator);
    defer taken.deinit();
    for (plan.tasks) |t| try taken.put(t.id, {});

    var out = std.ArrayList(planner.PlannedTask).empty;
    errdefer {
        for (out.items) |t| freeTask(allocator, t);
        out.deinit(allocator);
    }
    var splits = std.StringHashMap([]const []const u8).init(allocator);
    defer {
        var it = splits.valueIterator();
        while (it.next()) |v| {
            for (v.*) |s| allocator.free(s);
            allocator.free(v.*);
        }
        splits.deinit();
    }
    var reglas = std.ArrayList([]const u8).empty;
    errdefer {
        for (reglas.items) |r| allocator.free(r);
        reglas.deinit(allocator);
    }
    var changed = false;

    for (plan.tasks) |orig| {
        // Reparto test/impl sobre las salidas.
        var test_idx = std.ArrayList(usize).empty;
        defer test_idx.deinit(allocator);
        var impl_idx = std.ArrayList(usize).empty;
        defer impl_idx.deinit(allocator);
        for (orig.owns, 0..) |o, i| {
            if (isTestPath(o)) try test_idx.append(allocator, i) else try impl_idx.append(allocator, i);
        }

        const splittable = orig.owns.len >= 2 and (isProducerType(orig.task_type) or orig.task_type == .testear or test_idx.items.len > 0);
        if (!splittable or impl_idx.items.len == 0) {
            try out.append(allocator, try cloneTask(allocator, orig));
            continue;
        }

        // Grupos de la parte de implementación (regla a + guardia d).
        var impl_files = try allocator.alloc([]const u8, impl_idx.items.len);
        defer allocator.free(impl_files);
        for (impl_idx.items, 0..) |idx, i| impl_files[i] = orig.owns[idx];
        const groups = try moduleGroups(allocator, impl_files, orig.contract_fields, opts.map);
        defer {
            for (groups) |g| allocator.free(g);
            allocator.free(groups);
        }

        const need_a = groups.len >= 2;
        const need_b = test_idx.items.len > 0;
        if (!need_a and !need_b) {
            try out.append(allocator, try cloneTask(allocator, orig));
            continue;
        }

        changed = true;
        var produced = std.ArrayList([]const u8).empty;
        defer produced.deinit(allocator);

        if (need_a) {
            // Regla (a): una hermana por grupo de módulo.
            for (groups, 0..) |g, gi| {
                var sib = try cloneTask(allocator, orig);
                errdefer freeTask(allocator, sib);
                allocator.free(sib.id);
                const suffix = try std.fmt.allocPrint(allocator, "m{d}", .{gi + 1});
                defer allocator.free(suffix);
                sib.id = try uniqueSuffixId(allocator, orig.id, suffix, taken);
                try taken.put(sib.id, {});
                var sib_owns = try allocator.alloc([]const u8, g.len);
                for (g, 0..) |idx, k| sib_owns[k] = try allocator.dupe(u8, impl_files[idx]);
                for (sib.owns) |o| allocator.free(o);
                if (sib.owns.len > 0) allocator.free(sib.owns);
                sib.owns = sib_owns;
                try appendInterfaceField(allocator, &sib, orig.id);
                try out.append(allocator, sib);
                try produced.append(allocator, try allocator.dupe(u8, sib.id));
            }
        } else {
            // Solo regla (b): el original queda como hermana de impl (mismo id).
            var sib = try cloneTask(allocator, orig);
            errdefer freeTask(allocator, sib);
            var sib_owns = try allocator.alloc([]const u8, impl_idx.items.len);
            for (impl_idx.items, 0..) |idx, k| sib_owns[k] = try allocator.dupe(u8, orig.owns[idx]);
            for (sib.owns) |o| allocator.free(o);
            if (sib.owns.len > 0) allocator.free(sib.owns);
            sib.owns = sib_owns;
            if (sib.task_type == .testear) sib.task_type = .programar;
            try out.append(allocator, sib);
            try produced.append(allocator, try allocator.dupe(u8, sib.id));
        }

        if (need_b) {
            // Regla (b): hermana `testear` que depende de toda la impl.
            var ts = try cloneTask(allocator, orig);
            errdefer freeTask(allocator, ts);
            allocator.free(ts.id);
            ts.id = try uniqueSuffixId(allocator, orig.id, "test", taken);
            try taken.put(ts.id, {});
            allocator.free(ts.department);
            ts.department = try allocator.dupe(u8, "testing");
            ts.task_type = .testear;
            var ts_owns = try allocator.alloc([]const u8, test_idx.items.len);
            for (test_idx.items, 0..) |idx, k| ts_owns[k] = try allocator.dupe(u8, orig.owns[idx]);
            for (ts.owns) |o| allocator.free(o);
            if (ts.owns.len > 0) allocator.free(ts.owns);
            ts.owns = ts_owns;
            // Depende de las hermanas de impl producidas, más las deps del
            // original (menos autorreferencia).
            var ts_deps = std.ArrayList([]const u8).empty;
            defer ts_deps.deinit(allocator);
            for (produced.items) |p| try ts_deps.append(allocator, try allocator.dupe(u8, p));
            for (orig.depends_on) |d| {
                if (std.mem.eql(u8, d, orig.id)) continue;
                try ts_deps.append(allocator, try allocator.dupe(u8, d));
            }
            for (ts.depends_on) |d| allocator.free(d);
            allocator.free(ts.depends_on);
            ts.depends_on = try ts_deps.toOwnedSlice(allocator);
            try out.append(allocator, ts);
            try produced.append(allocator, try allocator.dupe(u8, ts.id));
        }

        const owned_ids = try allocator.dupe([]const u8, produced.items);
        try splits.put(orig.id, owned_ids);
        try reglas.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{c}:{s}->{d} tareas",
            .{ if (need_a) @as(u8, 'a') else 'b', orig.id, produced.items.len },
        ));
    }

    // Reescribir dependencias externas: quien esperaba al original espera a
    // todas sus hermanas. Dentro de una tarea PRODUCIDA por un split, el dep
    // que apunta a su propio origen queda literal: la hermana impl conserva
    // ese id y expandirlo metería una dependencia sobre sí misma.
    if (splits.count() > 0) {
        var origin_of = std.StringHashMap([]const u8).init(allocator);
        defer origin_of.deinit();
        var sit = splits.iterator();
        while (sit.next()) |e| {
            for (e.value_ptr.*) |s| try origin_of.put(s, e.key_ptr.*);
        }
        for (out.items) |*t| {
            var touches = false;
            for (t.depends_on) |d| {
                if (splits.contains(d) and (origin_of.get(t.id) == null or !std.mem.eql(u8, origin_of.get(t.id).?, d))) touches = true;
            }
            if (!touches) continue;
            var deps = std.ArrayList([]const u8).empty;
            defer deps.deinit(allocator);
            for (t.depends_on) |d| {
                const own_origin = origin_of.get(t.id);
                if (splits.get(d)) |siblings| {
                    if (own_origin != null and std.mem.eql(u8, own_origin.?, d)) {
                        // Dep hacia el propio origen (la hermana impl que
                        // conserva su id): queda literal.
                        try deps.append(allocator, try allocator.dupe(u8, d));
                        continue;
                    }
                    for (siblings) |s| {
                        var seen = false;
                        for (deps.items) |e| {
                            if (std.mem.eql(u8, e, s)) seen = true;
                        }
                        if (!seen) try deps.append(allocator, try allocator.dupe(u8, s));
                    }
                } else {
                    var seen = false;
                    for (deps.items) |e| {
                        if (std.mem.eql(u8, e, d)) seen = true;
                    }
                    if (!seen) try deps.append(allocator, try allocator.dupe(u8, d));
                }
            }
            const owned = try deps.toOwnedSlice(allocator);
            for (t.depends_on) |d| allocator.free(d);
            allocator.free(t.depends_on);
            t.depends_on = owned;
        }
    }

    if (!changed) {
        // Plan intacto: los clones se liberan aquí y el original no se toca —
        // importante porque el llamador puede dar fixtures con literales.
        for (out.items) |t| freeTask(allocator, t);
        out.deinit(allocator);
        return null;
    }

    const old_tasks = plan.tasks;
    plan.tasks = try out.toOwnedSlice(allocator);
    for (old_tasks) |t| freeTask(allocator, t);
    allocator.free(old_tasks);

    return .{
        .antes = antes,
        .despues = plan.tasks.len,
        .reglas = try reglas.toOwnedSlice(allocator),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkTask(allocator: std.mem.Allocator, id: []const u8, owns: []const []const u8, deps: []const []const u8) planner.PlannedTask {
    return .{
        .id = allocator.dupe(u8, id) catch @panic("oom"),
        .task_type = .programar,
        .department = allocator.dupe(u8, "backend") catch @panic("oom"),
        .description = allocator.dupe(u8, id) catch @panic("oom"),
        .contract_fields = &.{},
        .depends_on = cloneStrings(allocator, deps) catch @panic("oom"),
        .owns = cloneStrings(allocator, owns) catch @panic("oom"),
        .deliverable = null,
    };
}

fn mkPlan(allocator: std.mem.Allocator, tasks: []planner.PlannedTask) planner.Plan {
    return .{
        .allocator = allocator,
        .understanding = allocator.dupe(u8, "fixture") catch @panic("oom"),
        .questions = &.{},
        .tasks = tasks,
        .kind = .build,
    };
}

fn taskById(tasks: []const planner.PlannedTask, id: []const u8) ?planner.PlannedTask {
    for (tasks) |t| {
        if (std.mem.eql(u8, t.id, id)) return t;
    }
    return null;
}

test "E5.17 regla (a): dos salidas en módulos distintos → hermanas paralelas" {
    const a = testing.allocator;
    var tasks = try a.alloc(planner.PlannedTask, 1);
    const owns = [_][]const u8{ "frontend/app.ts", "backend/api.zig" };
    tasks[0] = mkTask(a, "t1", &owns, &.{});
    var plan = mkPlan(a, tasks);
    defer plan.deinit();

    var rep = (try apply(&plan, .{})) orelse return error.NotApplied;
    defer rep.deinit(a);
    try testing.expectEqual(@as(usize, 1), rep.antes);
    try testing.expectEqual(@as(usize, 2), rep.despues);
    const s1 = taskById(plan.tasks, "t1-m1") orelse return error.MissingSibling;
    const s2 = taskById(plan.tasks, "t1-m2") orelse return error.MissingSibling;
    try testing.expectEqual(@as(usize, 0), s1.depends_on.len);
    try testing.expectEqual(@as(usize, 0), s2.depends_on.len);
    // Contrato de interfaz compartido presente en ambas.
    var found = false;
    for (s1.contract_fields) |f| {
        if (std.mem.eql(u8, f.name, "interfaz_compartida")) found = true;
    }
    try testing.expect(found);
    // Cada hermana posee solo su módulo.
    try testing.expectEqualStrings("frontend/app.ts", s1.owns[0]);
    try testing.expectEqualStrings("backend/api.zig", s2.owns[0]);
}

test "E5.17 regla (b): pruebas mezcladas → hermana testear dependiente" {
    const a = testing.allocator;
    var tasks = try a.alloc(planner.PlannedTask, 1);
    const owns = [_][]const u8{ "src/signer.py", "tests/test_signer.py" };
    tasks[0] = mkTask(a, "t1", &owns, &.{});
    var plan = mkPlan(a, tasks);
    defer plan.deinit();

    var rep = (try apply(&plan, .{})) orelse return error.NotApplied;
    defer rep.deinit(a);
    try testing.expectEqual(@as(usize, 2), rep.despues);
    const impl = taskById(plan.tasks, "t1") orelse return error.MissingImpl;
    try testing.expectEqual(model_router.TaskType.programar, impl.task_type);
    const tt = taskById(plan.tasks, "t1-test") orelse return error.MissingTest;
    try testing.expectEqual(model_router.TaskType.testear, tt.task_type);
    try testing.expectEqualStrings("testing", tt.department);
    try testing.expectEqual(@as(usize, 1), tt.depends_on.len);
    try testing.expectEqualStrings("t1", tt.depends_on[0]);
}

test "E5.17 guardia (d): contrato que ata dos módulos → no se separa" {
    const a = testing.allocator;
    var tasks = try a.alloc(planner.PlannedTask, 1);
    const owns = [_][]const u8{ "api/handler.zig", "web/form.ts" };
    var t = mkTask(a, "t1", &owns, &.{});
    // El contrato nombra basenames de ambos grupos → quedan juntos.
    const fields = try a.alloc(planner.ContractField, 1);
    fields[0] = .{
        .name = try a.dupe(u8, "flujo"),
        .field_type = .string,
        .required = false,
        .value = try a.dupe(u8, "form.ts llama a handler.zig"),
    };
    t.contract_fields = fields;
    tasks[0] = t;
    var plan = mkPlan(a, tasks);
    defer plan.deinit();

    const rep = try apply(&plan, .{});
    try testing.expect(rep == null);
    try testing.expectEqual(@as(usize, 1), plan.tasks.len);
}

test "E5.17 regla (c): hermanas de tarea raíz caen en la ola 1 (con dependientes reescritos)" {
    const a = testing.allocator;
    var tasks = try a.alloc(planner.PlannedTask, 2);
    const owns1 = [_][]const u8{ "m1/a.zig", "m2/b.zig" };
    tasks[0] = mkTask(a, "t1", &owns1, &.{});
    const owns2 = [_][]const u8{"docs/manual.md"};
    var t2 = mkTask(a, "t2", &owns2, &.{});
    t2.task_type = .documentar;
    const dep = [_][]const u8{"t1"};
    a.free(t2.depends_on);
    t2.depends_on = try cloneStrings(a, &dep);
    tasks[1] = t2;
    var plan = mkPlan(a, tasks);
    defer plan.deinit();

    var rep = (try apply(&plan, .{})) orelse return error.NotApplied;
    defer rep.deinit(a);
    try testing.expectEqual(@as(usize, 3), rep.despues);
    const t2r = taskById(plan.tasks, "t2").?;
    // El consumidor ahora depende de AMBAS hermanas.
    try testing.expectEqual(@as(usize, 2), t2r.depends_on.len);
}

test "E5.17 sin mezcla ni multimódulo → null, plan intacto" {
    const a = testing.allocator;
    var tasks = try a.alloc(planner.PlannedTask, 1);
    const owns = [_][]const u8{ "web/index.html", "web/app.ts" };
    tasks[0] = mkTask(a, "t1", &owns, &.{});
    var plan = mkPlan(a, tasks);
    defer plan.deinit();
    // Control negativo: sin la pasada, el fixture sigue en una sola tarea.
    try testing.expectEqual(@as(usize, 1), plan.tasks.len);
    const rep = try apply(&plan, .{});
    try testing.expect(rep == null);
    try testing.expectEqual(@as(usize, 1), plan.tasks.len);
}
