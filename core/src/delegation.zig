//! USUARIO-NUEVO B (10-nov, decisión del propietario): modo «DevAgents». El modelo
//! de la conversación (Directo) delega subtareas en paralelo con la
//! herramienta `delegate_tasks`. Este módulo es la parte PURA: validar los
//! argumentos, traducir cada rol al par (task_type, departamento) del
//! planificador, construir el plan de cada subtarea, detectar archivos que dos
//! subtareas tocan a la vez y dar las frases llanas. La ejecución entra por el
//! camino de siempre (orden hija + worktree propio + dispatchApprovedOrder,
//! como las candidatas de best-of-N) y vive en c_api.zig.
const std = @import("std");
const model_router = @import("model_router.zig");
const planner = @import("planner.zig");

pub const TOOL_NAME = "delegate_tasks";
/// Máximo de subtareas por llamada: cada una abre un worktree y una orden.
pub const MAX_SUBTASKS: usize = 4;
pub const MAX_INSTRUCTION_BYTES: usize = 8 * 1024;
pub const MAX_FILES: usize = 16;
pub const MAX_PATH_BYTES: usize = 256;

pub const TOOL_DESCRIPTION =
    "Delega subtareas INDEPENDIENTES en otros modelos, en paralelo. Cada subtarea trabaja en su propia copia del proyecto (worktree de git), " ++
    "la audita otro modelo y, si sale bien, sus archivos se integran en la carpeta del proyecto. Úsala solo cuando la petición tenga partes que se pueden hacer a la vez " ++
    "(p. ej. el backend y la página, o el código y su documentación); para lo sencillo trabaja tú directamente. " ++
    "Args: tasks = lista de 1 a 4 objetos {role, instruction, files?, model?}. role: programar, testear, documentar, corregir, disenar o auditar. " ++
    "instruction: qué debe hacer, completo y autosuficiente (la subtarea no ve esta conversación). files: rutas relativas que debe crear o tocar (opcional). " ++
    "model: omítelo salvo que el usuario nombre un modelo; entonces \"Proveedor|modelo\" (sin él lo elige DevAgents). Espera a que terminen todas y devuelve, por subtarea, " ++
    "estado, archivos, veredicto de auditoría, si se integró y, si no, el motivo en «error» y dónde quedó su trabajo («worktree»). " ++
    "Al responder, di al usuario cuántas se integraron y, por cada una que no, ese motivo con lo que puede hacer, sin resumirlo ni inventarlo. Una subtarea no puede volver a delegar.";

pub const TOOL_PARAMETERS =
    \\{"type":"object","properties":{"tasks":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"object","properties":{"role":{"type":"string","enum":["programar","testear","documentar","corregir","disenar","auditar"]},"instruction":{"type":"string"},"files":{"type":"array","items":{"type":"string"}},"model":{"type":"string"}},"required":["role","instruction"],"additionalProperties":false}}},"required":["tasks"],"additionalProperties":false}
;

pub const Role = struct {
    task_type: model_router.TaskType,
    department: []const u8,
    /// Nombre que se enseña al usuario.
    label: []const u8,
};

/// Roles admitidos (y sus alias por departamento). Ninguno es `ejecutar` ni
/// `ui`: una subtarea produce o revisa archivos, no lanza comandos sueltos.
pub fn roleFor(text: []const u8) ?Role {
    const t = std.mem.trim(u8, text, " \t");
    const table = [_]struct { names: []const []const u8, role: Role }{
        .{ .names = &.{ "programar", "programacion", "programación", "codigo", "código" }, .role = .{ .task_type = .programar, .department = "programacion", .label = "Programación" } },
        .{ .names = &.{ "testear", "testing", "pruebas", "tests" }, .role = .{ .task_type = .testear, .department = "testing", .label = "Pruebas" } },
        .{ .names = &.{ "documentar", "documentacion", "documentación", "docs" }, .role = .{ .task_type = .documentar, .department = "documentacion", .label = "Documentación" } },
        .{ .names = &.{ "corregir", "correccion", "corrección" }, .role = .{ .task_type = .corregir, .department = "correccion", .label = "Corrección" } },
        .{ .names = &.{ "disenar", "diseñar", "diseno", "diseño" }, .role = .{ .task_type = .disenar, .department = "diseno", .label = "Diseño" } },
        .{ .names = &.{ "auditar", "auditoria", "auditoría", "revisar" }, .role = .{ .task_type = .auditar, .department = "auditoria", .label = "Auditoría" } },
    };
    for (table) |row| {
        for (row.names) |name| if (std.ascii.eqlIgnoreCase(t, name)) return row.role;
    }
    return null;
}

pub const Subtask = struct {
    role: Role,
    instruction: []u8,
    files: [][]u8,
    provider: ?[]u8 = null,
    model: ?[]u8 = null,
    /// B1e (11-nov): `model` pedido que no cumple "Proveedor|modelo". No tumba
    /// la subtarea: se despacha con selección automática y su resultado lo
    /// dice (`modelNote`). Texto ya saneado (sin controles), recortado.
    ignored_model: ?[]u8 = null,

    fn deinit(self: *Subtask, a: std.mem.Allocator) void {
        a.free(self.instruction);
        for (self.files) |f| a.free(f);
        a.free(self.files);
        if (self.provider) |p| a.free(p);
        if (self.model) |m| a.free(m);
        if (self.ignored_model) |m| a.free(m);
    }
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    items: []Subtask,

    pub fn deinit(self: *Request) void {
        for (self.items) |*s| s.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const ParseError = error{
    InvalidArguments,
    EmptyRequest,
    TooManySubtasks,
    UnknownRole,
    EmptyInstruction,
    InstructionTooLong,
    InvalidFile,
    TooManyFiles,
    InvalidModel,
};

/// Frase llana para el modelo (y, a través de él, para el usuario).
pub fn parseErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.InvalidArguments => "Los argumentos no son válidos: se espera {\"tasks\":[{\"role\",\"instruction\",\"files\"?,\"model\"?}]}.",
        error.EmptyRequest => "No hay ninguna subtarea que delegar.",
        error.TooManySubtasks => std.fmt.comptimePrint("Como máximo se delegan {d} subtareas por llamada. Agrupa el trabajo o haz una parte tú.", .{MAX_SUBTASKS}),
        error.UnknownRole => "Rol desconocido. Usa programar, testear, documentar, corregir, disenar o auditar.",
        error.EmptyInstruction => "Una subtarea no tiene instrucción.",
        error.InstructionTooLong => std.fmt.comptimePrint("Una instrucción supera {d} KB; resúmela.", .{MAX_INSTRUCTION_BYTES / 1024}),
        error.InvalidFile => "Una ruta de «files» no es válida: tiene que ser relativa al proyecto, sin «..» ni unidad.",
        error.TooManyFiles => std.fmt.comptimePrint("Una subtarea declara más de {d} archivos.", .{MAX_FILES}),
        error.InvalidModel => "«model» tiene que ser un texto \"Proveedor|modelo\"; omítelo y lo elige DevAgents.",
        else => "No se pudo leer la petición de delegación.",
    };
}

pub fn parseErrorCode(e: anyerror) []const u8 {
    return switch (e) {
        error.TooManySubtasks => "too_many_subtasks",
        error.UnknownRole => "unknown_role",
        error.EmptyRequest => "empty_request",
        error.EmptyInstruction, error.InstructionTooLong => "invalid_instruction",
        error.InvalidFile, error.TooManyFiles => "invalid_files",
        error.InvalidModel => "invalid_model",
        else => "invalid_arguments",
    };
}

fn validRelativePath(p: []const u8) bool {
    if (p.len == 0 or p.len > MAX_PATH_BYTES) return false;
    if (std.fs.path.isAbsolute(p) or std.mem.indexOfScalar(u8, p, ':') != null) return false;
    for (p) |c| if (c < 32) return false;
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn validModelPart(s: []const u8) bool {
    if (s.len == 0 or s.len > 256) return false;
    for (s) |c| if (c < 32 or c == '"') return false;
    return true;
}

pub fn parse(a: std.mem.Allocator, args_json: []const u8) (ParseError || error{OutOfMemory})!Request {
    var parsed = std.json.parseFromSlice(std.json.Value, a, args_json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    var keys = parsed.value.object.iterator();
    while (keys.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, "tasks")) return error.InvalidArguments;
    const tasks_v = parsed.value.object.get("tasks") orelse return error.InvalidArguments;
    if (tasks_v != .array) return error.InvalidArguments;
    if (tasks_v.array.items.len == 0) return error.EmptyRequest;
    if (tasks_v.array.items.len > MAX_SUBTASKS) return error.TooManySubtasks;

    var list = std.ArrayList(Subtask).empty;
    errdefer {
        for (list.items) |*s| s.deinit(a);
        list.deinit(a);
    }
    for (tasks_v.array.items) |tv| {
        if (tv != .object) return error.InvalidArguments;
        var fields = tv.object.iterator();
        while (fields.next()) |entry| {
            const k = entry.key_ptr.*;
            if (!std.mem.eql(u8, k, "role") and !std.mem.eql(u8, k, "instruction") and !std.mem.eql(u8, k, "files") and !std.mem.eql(u8, k, "model")) return error.InvalidArguments;
        }
        const role_v = tv.object.get("role") orelse return error.UnknownRole;
        if (role_v != .string) return error.UnknownRole;
        const role = roleFor(role_v.string) orelse return error.UnknownRole;
        const instr_v = tv.object.get("instruction") orelse return error.EmptyInstruction;
        if (instr_v != .string) return error.EmptyInstruction;
        const instr = std.mem.trim(u8, instr_v.string, " \t\r\n");
        if (instr.len == 0) return error.EmptyInstruction;
        if (instr.len > MAX_INSTRUCTION_BYTES) return error.InstructionTooLong;

        var files = std.ArrayList([]u8).empty;
        errdefer {
            for (files.items) |f| a.free(f);
            files.deinit(a);
        }
        if (tv.object.get("files")) |fv| {
            if (fv != .array) return error.InvalidFile;
            if (fv.array.items.len > MAX_FILES) return error.TooManyFiles;
            for (fv.array.items) |item| {
                if (item != .string or !validRelativePath(item.string)) return error.InvalidFile;
                const copy = try a.dupe(u8, item.string);
                files.append(a, copy) catch |e| {
                    a.free(copy);
                    return e;
                };
            }
        }
        var provider: ?[]u8 = null;
        var model: ?[]u8 = null;
        var ignored_model: ?[]u8 = null;
        errdefer {
            if (provider) |p| a.free(p);
            if (model) |m| a.free(m);
            if (ignored_model) |m| a.free(m);
        }
        if (tv.object.get("model")) |mv| {
            if (mv != .string) return error.InvalidModel;
            const text = std.mem.trim(u8, mv.string, " ");
            if (text.len > 0) {
                const bar = std.mem.indexOfScalar(u8, text, '|');
                if (bar != null and validModelPart(text[0..bar.?]) and validModelPart(text[bar.? + 1 ..])) {
                    provider = try a.dupe(u8, text[0..bar.?]);
                    model = try a.dupe(u8, text[bar.? + 1 ..]);
                } else {
                    // Formato inválido: se ignora y elige DevAgents.
                    const shown = text[0..@min(text.len, MAX_IGNORED_MODEL_BYTES)];
                    const copy = try a.dupe(u8, shown);
                    for (copy) |*c| {
                        if (c.* < 32 or c.* == '"') c.* = ' ';
                    }
                    ignored_model = copy;
                }
            }
        }
        const owned_instr = try a.dupe(u8, instr);
        errdefer a.free(owned_instr);
        const owned_files = try files.toOwnedSlice(a);
        errdefer {
            for (owned_files) |f| a.free(f);
            a.free(owned_files);
        }
        try list.append(a, .{ .role = role, .instruction = owned_instr, .files = owned_files, .provider = provider, .model = model, .ignored_model = ignored_model });
        provider = null;
        model = null;
        ignored_model = null;
    }
    return .{ .allocator = a, .items = try list.toOwnedSlice(a) };
}

const MAX_IGNORED_MODEL_BYTES: usize = 120;

/// P1-3 (hueco de B1e): un par "Proveedor|modelo" bien formado que no figura
/// en el catálogo tampoco tumba la subtarea. Se pasa a `ignored_model` (con
/// el mismo saneado y recorte que el formato inválido) y la subtarea queda
/// en selección automática. `a` es el asignador de la petición (`Request`).
pub fn ignoreModel(sub: *Subtask, a: std.mem.Allocator) !void {
    const p = sub.provider orelse return;
    const m = sub.model orelse return;
    const full = try std.fmt.allocPrint(a, "{s}|{s}", .{ p, m });
    defer a.free(full);
    const copy = try a.dupe(u8, full[0..@min(full.len, MAX_IGNORED_MODEL_BYTES)]);
    for (copy) |*c| {
        if (c.* < 32 or c.* == '"') c.* = ' ';
    }
    if (sub.ignored_model) |old| a.free(old);
    sub.ignored_model = copy;
    a.free(p);
    a.free(m);
    sub.provider = null;
    sub.model = null;
}

/// Frase llana para una subtarea cuyo `model` se ignoró. Propiedad de `a`.
pub fn modelNote(a: std.mem.Allocator, sub: Subtask) !?[]u8 {
    const asked = sub.ignored_model orelse return null;
    return try std.fmt.allocPrint(a, "el modelo pedido «{s}» no es válido; lo eligió DevAgents", .{asked});
}

/// Añade `model_note` a cada subtarea del resultado de `delegate_tasks` cuyo
/// `model` pedido se ignoró. El resultado lo construye el despachador (c_api)
/// con el orden de `tasks`; si los argumentos o el resultado no se pueden
/// leer (p. ej. un error de argumentos), se devuelve tal cual. Propiedad de `a`.
pub fn annotateIgnoredModels(a: std.mem.Allocator, args_json: []const u8, result_json: []const u8) ![]u8 {
    var req = parse(a, args_json) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return a.dupe(u8, result_json),
    };
    defer req.deinit();
    const any_ignored = for (req.items) |s| {
        if (s.ignored_model != null) break true;
    } else false;
    if (!any_ignored) return a.dupe(u8, result_json);
    var parsed = std.json.parseFromSlice(std.json.Value, a, result_json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return a.dupe(u8, result_json),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return a.dupe(u8, result_json);
    const subs = parsed.value.object.getPtr("subtasks") orelse return a.dupe(u8, result_json);
    if (subs.* != .array) return a.dupe(u8, result_json);
    const arena = parsed.arena.allocator();
    for (subs.array.items, 0..) |*item, i| {
        if (i >= req.items.len or item.* != .object) continue;
        const note = (try modelNote(arena, req.items[i])) orelse continue;
        try item.object.put(arena, "model_note", .{ .string = note });
    }
    return std.json.Stringify.valueAlloc(a, parsed.value, .{});
}

/// Plan de una subtarea en el MISMO formato que devuelve el planificador
/// (lo lee `llm_planner.taskFromJson`). Un productor lleva detrás su tarea de
/// auditoría (otro modelo, por la exclusión de autoauditoría del router);
/// una subtarea de auditoría ya es la revisión.
pub fn planJson(a: std.mem.Allocator, sub: Subtask) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("understanding");
    try js.write(sub.instruction);
    try js.objectField("tasks");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("id");
    try js.write("t1");
    try js.objectField("task_type");
    try js.write(sub.role.task_type.toText());
    try js.objectField("department");
    try js.write(sub.role.department);
    try js.objectField("description");
    try js.write(sub.instruction);
    try js.objectField("depends_on");
    try js.beginArray();
    try js.endArray();
    try js.objectField("owns");
    try js.beginArray();
    for (sub.files) |f| try js.write(f);
    try js.endArray();
    try js.objectField("contract_fields");
    try js.beginArray();
    if (sub.role.task_type == .auditar) {
        try writeField(&js, "verdict", true);
    } else {
        try writeField(&js, "source", true);
        try writeField(&js, "filename", false);
    }
    try js.endArray();
    try js.endObject();
    if (sub.role.task_type != .auditar) {
        try js.beginObject();
        try js.objectField("id");
        try js.write("t2");
        try js.objectField("task_type");
        try js.write("auditar");
        try js.objectField("department");
        try js.write("auditoria");
        try js.objectField("description");
        try js.write("Audita lo que produjo t1 frente a su instrucción: lee los archivos reales y da PASS o FAIL con evidencia.");
        try js.objectField("depends_on");
        try js.beginArray();
        try js.write("t1");
        try js.endArray();
        try js.objectField("contract_fields");
        try js.beginArray();
        try writeField(&js, "verdict", true);
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return out.toOwnedSlice();
}

fn writeField(js: *std.json.Stringify, name: []const u8, required: bool) !void {
    try js.beginObject();
    try js.objectField("name");
    try js.write(name);
    try js.objectField("type");
    try js.write("string");
    try js.objectField("required");
    try js.write(required);
    try js.endObject();
}

/// Tarea auditora del plan de una subtarea (`planJson` pone la auditoría como
/// t2; una subtarea de rol «auditar» es t1). Su informe (`t2.txt`, `t2.md`…,
/// el nombre lo pone el motor de órdenes con el id de la tarea) es evidencia:
/// se queda en el worktree y no se copia al proyecto.
pub fn auditTaskId(sub: Subtask) []const u8 {
    return if (sub.role.task_type == .auditar) "t1" else "t2";
}

fn isAuditArtifact(rel: []const u8, audit_id: []const u8) bool {
    if (std.mem.indexOfScalar(u8, rel, '/') != null) return false;
    const stem = if (std.mem.lastIndexOfScalar(u8, rel, '.')) |dot| rel[0..dot] else rel;
    return std.ascii.eqlIgnoreCase(stem, audit_id);
}

pub const Pick = enum { work, audit_report };

/// Rutas DESTINO (relativas a la carpeta del proyecto, con «/») de lo que una
/// subtarea cambió en su worktree: quita la carpeta `orden-<hija>` en la que
/// escribe el motor de órdenes y lo repetido. `pick` elige el trabajo (sin el
/// informe del auditor) o solo el informe. Propiedad de `a`.
pub fn destinationFiles(a: std.mem.Allocator, changed: []const []const u8, child_order_id: i64, audit_id: []const u8, pick: Pick) ![][]const u8 {
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "orden-{d}/", .{child_order_id});
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |p| a.free(p);
        out.deinit(a);
    }
    for (changed) |raw| {
        const norm = try a.dupe(u8, raw);
        std.mem.replaceScalar(u8, norm, '\\', '/');
        const rel = if (std.mem.startsWith(u8, norm, prefix)) norm[prefix.len..] else norm;
        const is_report = isAuditArtifact(rel, audit_id);
        const skip = rel.len == 0 or (is_report != (pick == .audit_report)) or for (out.items) |seen| {
            if (samePath(seen, rel)) break true;
        } else false;
        if (skip) {
            a.free(norm);
            continue;
        }
        const owned = a.dupe(u8, rel) catch |e| {
            a.free(norm);
            return e;
        };
        a.free(norm);
        out.append(a, owned) catch |e| {
            a.free(owned);
            return e;
        };
    }
    return out.toOwnedSlice(a);
}

/// Rutas que más de una subtarea cambió. `sets[i]` = archivos cambiados por
/// la subtarea i (null = no se integra: falló o no se pudo leer). Devuelve,
/// por subtarea, si alguno de sus archivos coincide con el de otra. La que
/// llega primero (índice menor) se integra; las demás quedan en su worktree
/// para revisarlas a mano. Nunca se pisa en silencio un archivo ajeno.
pub fn conflictMask(a: std.mem.Allocator, sets: []const ?[]const []const u8) ![]bool {
    const mask = try a.alloc(bool, sets.len);
    @memset(mask, false);
    for (sets, 0..) |maybe, i| {
        const mine = maybe orelse continue;
        for (sets[0..i]) |earlier_maybe| {
            const earlier = earlier_maybe orelse continue;
            if (overlaps(mine, earlier)) {
                mask[i] = true;
                break;
            }
        }
    }
    return mask;
}

fn overlaps(x: []const []const u8, y: []const []const u8) bool {
    for (x) |p| for (y) |q| if (samePath(p, q)) return true;
    return false;
}

fn samePath(p: []const u8, q: []const u8) bool {
    if (p.len != q.len) return false;
    for (p, q) |c1, c2| {
        const n1: u8 = if (c1 == '\\') '/' else std.ascii.toLower(c1);
        const n2: u8 = if (c2 == '\\') '/' else std.ascii.toLower(c2);
        if (n1 != n2) return false;
    }
    return true;
}

/// Remate D2 (10-nov): el último fallo de proveedor del auditor de una
/// subtarea, leído de su `task_provider_failed` (con `rate_daily` de la
/// Parte A). Todo prestado del JSON del evento.
pub const AuditFailure = struct {
    provider: []const u8 = "",
    model: []const u8 = "",
    http_status: ?i64 = null,
    daily: bool = false,
    /// Lo que dijo el proveedor (ya censurado por `excerpt`).
    said: []const u8 = "",
};

/// Por qué una subtarea quedó «sin auditar», en llano y con qué puede hacer el
/// usuario. Sin fallo de proveedor registrado, el auditor respondió pero sin
/// un veredicto usable. Propiedad de `a`.
pub fn unauditedText(a: std.mem.Allocator, failure: ?AuditFailure) ![]u8 {
    return unauditedTextWith(a, failure, "");
}

/// Como `unauditedText`; `motor_detail` es el motivo que dio el motor al
/// descartar el veredicto (p. ej. citas que no se sostienen), sin prefijo.
pub fn unauditedTextWith(a: std.mem.Allocator, failure: ?AuditFailure, motor_detail: []const u8) ![]u8 {
    const f = failure orelse {
        const prefix = "audit_unavailable: ";
        const d = std.mem.trim(u8, if (std.mem.startsWith(u8, motor_detail, prefix)) motor_detail[prefix.len..] else motor_detail, " ");
        if (d.len > 0)
            return std.fmt.allocPrint(a, "Sin auditar: su auditor respondió, pero DevAgents no pudo dar por bueno su veredicto ({s}), y sin auditoría la entrega se bloquea. Qué puedes hacer: volver a pedirlo; si se repite, añade en Configuración › Proveedores la clave de otro proveedor para que la audite otro modelo.", .{d});
        return a.dupe(u8, "Sin auditar: su auditor respondió, pero sin un veredicto usable (PASS o FAIL con evidencia), y sin auditoría la entrega se bloquea. Qué puedes hacer: volver a pedirlo; si se repite, añade en Configuración › Proveedores la clave de otro proveedor para que la audite otro modelo.");
    };
    const who_model = if (f.model.len > 0) f.model else "el modelo auditor";
    const who = if (f.provider.len > 0)
        try std.fmt.allocPrint(a, "{s} de {s}", .{ who_model, f.provider })
    else
        try a.dupe(u8, who_model);
    defer a.free(who);
    const prefix = "[texto externo] ";
    const said_raw = std.mem.trim(u8, f.said, " ");
    const said = if (std.mem.startsWith(u8, said_raw, prefix)) said_raw[prefix.len..] else said_raw;
    const quoted = if (said.len > 0 and !std.mem.eql(u8, said, "[REDACTADO]"))
        try std.fmt.allocPrint(a, " El proveedor dijo: «{s}».", .{said})
    else
        try a.dupe(u8, "");
    defer a.free(quoted);
    const status = f.http_status orelse 0;
    const provider = if (f.provider.len > 0) f.provider else "ese proveedor";
    if (status == 429 and f.daily)
        return std.fmt.allocPrint(a, "Sin auditar: su auditor ({s}) no pudo revisarla porque se agotó la cuota gratuita de hoy de {s} (HTTP 429).{s} Qué puedes hacer: esperar a que se renueve la cuota (suele ser al día siguiente), añadir en Configuración › Proveedores otra clave de {s} o la de otro proveedor para que audite otro modelo, o permitir modelos de pago en Configuración › Gobernanza; después vuelve a pedirlo.", .{ who, provider, quoted, provider });
    if (status == 429)
        return std.fmt.allocPrint(a, "Sin auditar: su auditor ({s}) recibió un límite de peticiones de {s} (HTTP 429, demasiadas en poco tiempo).{s} Qué puedes hacer: esperar unos minutos y volver a pedirlo, o añadir en Configuración › Proveedores la clave de otro proveedor para que audite otro modelo.", .{ who, provider, quoted });
    if (status == 402)
        return std.fmt.allocPrint(a, "Sin auditar: {s} rechazó la auditoría por falta de saldo o cuota en tu cuenta (HTTP 402).{s} Qué puedes hacer: revisar tu plan en {s} o añadir la clave de otro proveedor en Configuración › Proveedores; después vuelve a pedirlo.", .{ who, quoted, provider });
    if (status == 401 or status == 403)
        return std.fmt.allocPrint(a, "Sin auditar: {s} rechazó la clave del auditor ({s}, HTTP {d}).{s} Qué puedes hacer: revisar o cambiar la clave en Configuración › Proveedores; después vuelve a pedirlo.", .{ provider, who, status, quoted });
    if (status > 0)
        return std.fmt.allocPrint(a, "Sin auditar: su auditor ({s}) falló al responder (HTTP {d}).{s} Qué puedes hacer: volver a pedirlo; si se repite, añade en Configuración › Proveedores la clave de otro proveedor para que audite otro modelo.", .{ who, status, quoted });
    return std.fmt.allocPrint(a, "Sin auditar: su auditor ({s}) no devolvió una respuesta usable (sin conexión, tiempo agotado o respuesta ilegible).{s} Qué puedes hacer: volver a pedirlo; si se repite, añade en Configuración › Proveedores la clave de otro proveedor para que audite otro modelo.", .{ who, quoted });
}

pub const NO_GIT_TEXT = "No se delegó: la carpeta del proyecto no es un repositorio git, y cada subtarea necesita su propio worktree para no pisar el trabajo de las demás. Pulsa «Iniciar git aquí» (el botón aparece en la conversación, junto a este aviso) o ejecuta `git init` en la carpeta, y vuelve a pedirlo; mientras tanto puedo hacerlo yo directamente aquí.";
pub const CANCELLED_TEXT = "Delegación detenida a petición tuya: las subtareas en marcha se cancelaron y no se integró nada de ellas.";
pub const BUSY_TEXT = "Ya hay una delegación en marcha en esta conversación; espera a que termine.";

// ── Pruebas ───────────────────────────────────────────────────────────────

test "USUARIO-NUEVO B: delegate_tasks valida argumentos, roles, rutas, modelo y límite" {
    const a = std.testing.allocator;
    var ok = try parse(a,
        \\{"tasks":[{"role":"programar","instruction":"  crea api.js  ","files":["src/api.js"]},{"role":"documentación","instruction":"README","model":"OpenRouter|x/y:free"}]}
    );
    defer ok.deinit();
    try std.testing.expectEqual(@as(usize, 2), ok.items.len);
    try std.testing.expectEqual(model_router.TaskType.programar, ok.items[0].role.task_type);
    try std.testing.expectEqualStrings("crea api.js", ok.items[0].instruction);
    try std.testing.expectEqualStrings("src/api.js", ok.items[0].files[0]);
    try std.testing.expect(ok.items[0].provider == null);
    try std.testing.expectEqualStrings("documentacion", ok.items[1].role.department);
    try std.testing.expectEqualStrings("OpenRouter", ok.items[1].provider.?);
    try std.testing.expectEqualStrings("x/y:free", ok.items[1].model.?);

    const cases = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "no es json", .err = error.InvalidArguments },
        .{ .json = "{\"tasks\":[]}", .err = error.EmptyRequest },
        .{ .json = "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\"},{\"role\":\"programar\",\"instruction\":\"b\"},{\"role\":\"programar\",\"instruction\":\"c\"},{\"role\":\"programar\",\"instruction\":\"d\"},{\"role\":\"programar\",\"instruction\":\"e\"}]}", .err = error.TooManySubtasks },
        .{ .json = "{\"tasks\":[{\"role\":\"ejecutar\",\"instruction\":\"dir\"}]}", .err = error.UnknownRole },
        .{ .json = "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"   \"}]}", .err = error.EmptyInstruction },
        .{ .json = "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\",\"files\":[\"../fuera.txt\"]}]}", .err = error.InvalidFile },
        .{ .json = "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\",\"files\":[\"C:\\\\x.txt\"]}]}", .err = error.InvalidFile },
        // Un `model` que no es texto sigue siendo error de argumentos; uno mal
        // formado se tolera (prueba siguiente).
        .{ .json = "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\",\"model\":5}]}", .err = error.InvalidModel },
        .{ .json = "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\",\"extra\":1}]}", .err = error.InvalidArguments },
        .{ .json = "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\"}],\"depth\":2}", .err = error.InvalidArguments },
    };
    for (cases) |c| {
        try std.testing.expectError(c.err, parse(a, c.json));
        // Cada error tiene su frase llana, sin nombre de error de Zig.
        try std.testing.expect(std.mem.indexOf(u8, parseErrorText(c.err), @errorName(c.err)) == null);
    }
    // Sin fugas en un fallo a mitad de lista.
    // Se falla en cada reserva por turno: o OutOfMemory sin fugas, o éxito.
    var fail_index: usize = 0;
    while (fail_index < 512) : (fail_index += 1) {
        var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        if (parse(fail.allocator(), "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\",\"files\":[\"x\",\"y\"],\"model\":\"P|m\"},{\"role\":\"testear\",\"instruction\":\"b\"}]}")) |got| {
            var r = got;
            r.deinit();
            break;
        } else |e| try std.testing.expectEqual(error.OutOfMemory, e);
    }
    try std.testing.expect(fail_index < 512);
}

test "B1e: un «model» mal formado no tumba la subtarea; elige DevAgents y el resultado lo dice" {
    const a = std.testing.allocator;
    // Visto en vivo el 11-nov: el modelo rellenó `model` sin «|» y fallaron las dos.
    const args = "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\",\"model\":\"command-a-03-2025\"},{\"role\":\"testear\",\"instruction\":\"b\",\"model\":\"|\"},{\"role\":\"documentar\",\"instruction\":\"c\",\"model\":\"Cohere|command-a\"}]}";
    var req = try parse(a, args);
    defer req.deinit();
    try std.testing.expectEqual(@as(usize, 3), req.items.len);
    try std.testing.expect(req.items[0].provider == null and req.items[0].model == null);
    try std.testing.expectEqualStrings("command-a-03-2025", req.items[0].ignored_model.?);
    try std.testing.expect(req.items[1].provider == null and req.items[1].model == null);
    try std.testing.expectEqualStrings("Cohere", req.items[2].provider.?);
    try std.testing.expect(req.items[2].ignored_model == null);
    const note = (try modelNote(a, req.items[0])).?;
    defer a.free(note);
    try std.testing.expectEqualStrings("el modelo pedido «command-a-03-2025» no es válido; lo eligió DevAgents", note);
    try std.testing.expect((try modelNote(a, req.items[2])) == null);

    // El resultado del despachador gana «model_note» solo en las ignoradas.
    const result = "{\"ok\":true,\"subtasks\":[{\"index\":1,\"status\":\"done\"},{\"index\":2,\"status\":\"done\"},{\"index\":3,\"status\":\"done\"}],\"integrated\":3}";
    const out = try annotateIgnoredModels(a, args, result);
    defer a.free(out);
    var p = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer p.deinit();
    const subs = p.value.object.get("subtasks").?.array.items;
    try std.testing.expectEqualStrings("el modelo pedido «command-a-03-2025» no es válido; lo eligió DevAgents", subs[0].object.get("model_note").?.string);
    try std.testing.expectEqualStrings("el modelo pedido «|» no es válido; lo eligió DevAgents", subs[1].object.get("model_note").?.string);
    try std.testing.expect(subs[2].object.get("model_note") == null);
    try std.testing.expectEqual(@as(i64, 3), p.value.object.get("integrated").?.integer);
    // Sin modelos ignorados, o con argumentos ilegibles, el resultado no cambia.
    const same = try annotateIgnoredModels(a, "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"a\"}]}", result);
    defer a.free(same);
    try std.testing.expectEqualStrings(result, same);
    const bad = try annotateIgnoredModels(a, "no es json", "{\"ok\":false}");
    defer a.free(bad);
    try std.testing.expectEqualStrings("{\"ok\":false}", bad);
    // Sin fugas si falla una reserva en cualquier punto.
    var fail_index: usize = 0;
    while (fail_index < 1024) : (fail_index += 1) {
        var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        if (annotateIgnoredModels(fail.allocator(), args, result)) |got| {
            fail.allocator().free(got);
            break;
        } else |e| try std.testing.expectEqual(error.OutOfMemory, e);
    }
    try std.testing.expect(fail_index < 1024);
}

test "USUARIO-NUEVO B: el plan de una subtarea es el del planificador, con su auditoría" {
    const a = std.testing.allocator;
    var req = try parse(a, "{\"tasks\":[{\"role\":\"programar\",\"instruction\":\"crea api.js\",\"files\":[\"api.js\"]},{\"role\":\"auditar\",\"instruction\":\"revisa web\"}]}");
    defer req.deinit();
    const prod = try planJson(a, req.items[0]);
    defer a.free(prod);
    var p1 = try std.json.parseFromSlice(std.json.Value, a, prod, .{});
    defer p1.deinit();
    const t = p1.value.object.get("tasks").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), t.len);
    try std.testing.expectEqualStrings("programar", t[0].object.get("task_type").?.string);
    try std.testing.expectEqualStrings("api.js", t[0].object.get("owns").?.array.items[0].string);
    try std.testing.expectEqualStrings("auditar", t[1].object.get("task_type").?.string);
    try std.testing.expectEqualStrings("t1", t[1].object.get("depends_on").?.array.items[0].string);
    // El validador del planificador lo acepta tal cual (tipos, departamentos, contratos).
    var plan = try @import("llm_planner.zig").planFromJson(a, prod);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.tasks.len);
    try std.testing.expectEqual(model_router.TaskType.auditar, plan.tasks[1].task_type);
    const audit = try planJson(a, req.items[1]);
    defer a.free(audit);
    var p2 = try std.json.parseFromSlice(std.json.Value, a, audit, .{});
    defer p2.deinit();
    try std.testing.expectEqual(@as(usize, 1), p2.value.object.get("tasks").?.array.items.len);
}

test "USUARIO-NUEVO B: lo cambiado se cuenta en la raíz del proyecto, sin el informe del auditor" {
    const a = std.testing.allocator;
    // El informe del auditor se llama como su tarea, con la extensión que le
    // dé el modelo (medido en vivo: t2.txt y t2.md).
    const changed = [_][]const u8{ "orden-17/saludo.py", "orden-17\\t2.txt", "orden-17/T2.md", "orden-17/sub/x.py", "orden-17/sub/t2.txt", "README.md", "orden-17/saludo.py" };
    const got = try destinationFiles(a, &changed, 17, "t2", .work);
    defer {
        for (got) |p| a.free(p);
        a.free(got);
    }
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("saludo.py", got[0]);
    try std.testing.expectEqualStrings("sub/x.py", got[1]);
    try std.testing.expectEqualStrings("sub/t2.txt", got[2]);
    try std.testing.expectEqualStrings("README.md", got[3]);
    const reports = try destinationFiles(a, &changed, 17, "t2", .audit_report);
    defer {
        for (reports) |p| a.free(p);
        a.free(reports);
    }
    try std.testing.expectEqual(@as(usize, 2), reports.len);
    try std.testing.expectEqualStrings("t2.txt", reports[0]);
    try std.testing.expectEqualStrings("T2.md", reports[1]);
}

test "Remate D2: «sin auditar» dice por qué y qué hacer (cuota diaria, ráfaga, clave, sin veredicto)" {
    const a = std.testing.allocator;
    const daily = try unauditedText(a, .{ .provider = "OpenRouter", .model = "google/gemma:free", .http_status = 429, .daily = true, .said = "[texto externo] Rate limit exceeded: free-models-per-day." });
    defer a.free(daily);
    try std.testing.expect(std.mem.indexOf(u8, daily, "se agotó la cuota gratuita de hoy de OpenRouter") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "google/gemma:free de OpenRouter") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "«Rate limit exceeded: free-models-per-day.»") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "[texto externo]") == null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "esperar") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "Configuración › Proveedores") != null);
    const burst = try unauditedText(a, .{ .provider = "OpenRouter", .model = "x:free", .http_status = 429 });
    defer a.free(burst);
    try std.testing.expect(std.mem.indexOf(u8, burst, "demasiadas en poco tiempo") != null);
    try std.testing.expect(std.mem.indexOf(u8, burst, "cuota gratuita de hoy") == null);
    const key = try unauditedText(a, .{ .provider = "Cohere", .model = "c", .http_status = 401 });
    defer a.free(key);
    try std.testing.expect(std.mem.indexOf(u8, key, "rechazó la clave") != null);
    const none = try unauditedText(a, null);
    defer a.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "sin un veredicto usable") != null);
    // Medido en vivo (orden 36): el auditor citó una ruta que no existe y el
    // motor descartó el veredicto; se dice ese motivo.
    const cites = try unauditedTextWith(a, null, "audit_unavailable: 1 de 1 citas del informe no se sostienen al abrir el archivo: saludo.txt:1");
    defer a.free(cites);
    try std.testing.expect(std.mem.indexOf(u8, cites, "(1 de 1 citas del informe no se sostienen") != null);
    try std.testing.expect(std.mem.indexOf(u8, cites, "audit_unavailable:") == null);
    // Nunca el texto genérico de transporte del motor ni nombres de error de Zig.
    for ([_][]const u8{ daily, burst, key, none }) |t| {
        try std.testing.expect(std.mem.indexOf(u8, t, "fallo de transporte") == null);
        try std.testing.expect(std.mem.indexOf(u8, t, "RateLimited") == null);
    }
}

test "USUARIO-NUEVO B: dos subtareas que tocan el mismo archivo no se pisan" {
    const a = std.testing.allocator;
    const s0 = [_][]const u8{ "src/api.js", "README.md" };
    const s1 = [_][]const u8{"web/index.html"};
    const s2 = [_][]const u8{"SRC\\API.JS"};
    const sets = [_]?[]const []const u8{ &s0, &s1, null, &s2 };
    const mask = try conflictMask(a, &sets);
    defer a.free(mask);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, true }, mask);
}
