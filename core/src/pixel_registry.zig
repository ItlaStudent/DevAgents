const std = @import("std");
const model_router = @import("model_router.zig");
const agent_def = @import("agent_def.zig");
const windows = std.os.windows;

pub const RegistryError = error{ OutOfMemory, ParseError, FileNotFound, InvalidJson };

// ── Carga del dev-team.json real (Win32 directo, fork-safe) ──────────────
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?windows.HANDLE) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const GetFileSize = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileSize(hFile: windows.HANDLE, lpFileSizeHigh: ?*u32) u32;
}.GetFileSize else @import("providers").posix_files.GetFileSize;
const GetEnvironmentVariableA = @import("platform.zig").env;

/// 9-nov: el dev-team.json de Pixel Enterprise (proyecto hermano) solo se
/// carga si la variable de entorno DEVAGENTS_PIXEL_TEAM apunta a él. Antes
/// había una ruta fija del equipo del propietario, que ya no existía y no puede ir
/// en un binario público.
pub const Specialist = struct {
    name: []const u8,
    department: []const u8,
    task_types: []const model_router.TaskType,
    system_prompt: []const u8,
    description: []const u8,
    model_hint: ?[]const u8,
    source: enum { native, pixel },

    pub fn deinit(self: *const Specialist, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.department);
        allocator.free(self.task_types);
        allocator.free(self.system_prompt);
        allocator.free(self.description);
        if (self.model_hint) |m| allocator.free(m);
    }
};

pub const PixelDivision = struct {
    id: []const u8,
    name: []const u8,
    emoji: []const u8,
    agent_ids: [][]const u8,
    room_id: []const u8,

    pub fn deinit(self: *const PixelDivision, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.emoji);
        allocator.free(self.room_id);
        for (self.agent_ids) |a| allocator.free(a);
        allocator.free(self.agent_ids);
    }
};

pub const UnifiedRegistry = struct {
    allocator: std.mem.Allocator,
    specialists: []Specialist,
    divisions: []PixelDivision,

    pub fn deinit(self: *UnifiedRegistry) void {
        for (self.specialists) |s| s.deinit(self.allocator);
        self.allocator.free(self.specialists);
        for (self.divisions) |d| d.deinit(self.allocator);
        self.allocator.free(self.divisions);
    }

    pub fn findByDepartment(self: *const UnifiedRegistry, dept: []const u8) ?*const Specialist {
        for (self.specialists) |*s| {
            if (std.mem.eql(u8, s.department, dept)) return s;
        }
        return null;
    }

    pub fn findByTaskType(self: *const UnifiedRegistry, tt: model_router.TaskType) ?*const Specialist {
        for (self.specialists) |*s| {
            for (s.task_types) |st| {
                if (st == tt) return s;
            }
        }
        return null;
    }

    pub fn modelHintForDept(self: *const UnifiedRegistry, dept: []const u8) ?[]const u8 {
        const s = self.findByDepartment(dept) orelse return null;
        return s.model_hint;
    }
};

pub fn loadFromJson(allocator: std.mem.Allocator, json_text: []const u8) RegistryError!UnifiedRegistry {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
        return error.ParseError;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    var spec_list = std.ArrayList(Specialist).empty;
    errdefer {
        for (spec_list.items) |s| s.deinit(allocator);
        spec_list.deinit(allocator);
    }
    try appendNativeSpecialists(allocator, &spec_list);

    if (root.get("agents")) |agents_v| {
        if (agents_v == .array) {
            for (agents_v.array.items) |item| {
                if (item != .object) continue;
                const s = try specialistFromPixelAgent(allocator, item.object);
                try spec_list.append(allocator, s);
            }
        }
    }

    var div_list = std.ArrayList(PixelDivision).empty;
    errdefer {
        for (div_list.items) |d| d.deinit(allocator);
        div_list.deinit(allocator);
    }
    if (root.get("divisions")) |divs_v| {
        if (divs_v == .array) {
            for (divs_v.array.items) |item| {
                if (item != .object) continue;
                const d = try divisionFromJson(allocator, item.object);
                try div_list.append(allocator, d);
            }
        }
    }

    return UnifiedRegistry{
        .allocator = allocator,
        .specialists = try spec_list.toOwnedSlice(allocator),
        .divisions = try div_list.toOwnedSlice(allocator),
    };
}

/// Lee `path` completo vía Win32 (compatible con el fork de Zig).
fn readFileAllocZ(allocator: std.mem.Allocator, path: [*:0]const u8) ![]const u8 {
    const GENERIC_READ: u32 = 0x80000000;
    const FILE_SHARE_READ: u32 = 0x00000001;
    const OPEN_EXISTING: u32 = 3;
    const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
    const h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return error.FileNotFound;
    defer _ = CloseHandle(h);
    const size = GetFileSize(h, null);
    if (size == 0xFFFFFFFF) return error.ReadFailed;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var read_bytes: u32 = 0;
    if (ReadFile(h, buf.ptr, size, &read_bytes, null) == 0 or read_bytes != size) return error.ReadFailed;
    return buf;
}

/// Carga el registro unificado desde el dev-team.json real (ruta env
/// DEVAGENTS_PIXEL_TEAM; sin ella, solo nativos). DEGRADACIÓN GRACEFUL:
/// si el archivo falta o el JSON es inválido, devuelve un registro SOLO con los
/// 5 especialistas nativos (nunca null / all-or-nothing). Solo propaga OutOfMemory.
/// Esta es la ÚNICA vía de carga; la usan tanto el C-API (GUI) como el CLI.
pub fn loadUnifiedDefault(allocator: std.mem.Allocator) RegistryError!UnifiedRegistry {
    var env_buf: [1024:0]u8 = undefined;
    const env_len = GetEnvironmentVariableA("DEVAGENTS_PIXEL_TEAM", &env_buf, @intCast(env_buf.len));
    if (env_len == 0 or env_len >= env_buf.len) return loadFromJson(allocator, "{}");
    const path: [*:0]const u8 = @as([*:0]u8, @ptrCast(&env_buf));

    const json_text = readFileAllocZ(allocator, path) catch {
        // Archivo ausente/ilegible → solo nativos (no all-or-nothing).
        return loadFromJson(allocator, "{}");
    };
    defer allocator.free(json_text);

    return loadFromJson(allocator, json_text) catch |e| {
        if (e == error.OutOfMemory) return e;
        // JSON inválido → degradar a solo nativos.
        return loadFromJson(allocator, "{}");
    };
}

fn appendNativeSpecialists(allocator: std.mem.Allocator, list: *std.ArrayList(Specialist)) RegistryError!void {
    const natives = &[_]struct { dept: []const u8, def: []const u8 }{
        .{ .dept = "programacion", .def = agent_def.PROGRAMACION_DEF },
        .{ .dept = "testing", .def = agent_def.TESTING_DEF },
        .{ .dept = "auditoria", .def = agent_def.AUDITORIA_DEF },
        .{ .dept = "correccion", .def = agent_def.CORRECCION_DEF },
        .{ .dept = "documentacion", .def = agent_def.DOCUMENTACION_DEF },
    };
    for (natives) |n| {
        const def = agent_def.parseAgentDef(allocator, n.def) catch |e| {
            return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidJson;
        };
        defer def.deinit(allocator);
        const sys_prompt = try allocator.dupe(u8, def.system_prompt);
        errdefer allocator.free(sys_prompt);
        const task_types = try allocator.dupe(model_router.TaskType, def.task_types);
        errdefer allocator.free(task_types);
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, def.name),
            .department = try allocator.dupe(u8, n.dept),
            .task_types = task_types,
            .system_prompt = sys_prompt,
            .description = try allocator.dupe(u8, def.description),
            .model_hint = null,
            .source = .native,
        });
    }
}

fn specialistFromPixelAgent(allocator: std.mem.Allocator, obj: std.json.ObjectMap) RegistryError!Specialist {
    const name = getString(obj, "name") orelse return error.InvalidJson;
    const role = getString(obj, "role") orelse return error.InvalidJson;
    const specialization = getString(obj, "specialization") orelse return error.InvalidJson;
    const model = getString(obj, "model");

    var skills: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (skills.items) |s| allocator.free(s);
        skills.deinit(allocator);
    }
    if (obj.get("skills")) |skills_v| {
        if (skills_v == .array) {
            for (skills_v.array.items) |sv| {
                if (sv == .string) {
                    try skills.append(allocator, try allocator.dupe(u8, sv.string));
                }
            }
        }
    }

    const task_types = try inferTaskTypes(allocator, role, specialization, skills.items);
    errdefer allocator.free(task_types);
    const system_prompt = try buildSystemPrompt(allocator, name, role, specialization, skills.items);
    errdefer allocator.free(system_prompt);
    const department = try allocator.dupe(u8, specialization);
    errdefer allocator.free(department);
    const model_hint = if (model) |m| try allocator.dupe(u8, m) else null;
    errdefer if (model_hint) |m| allocator.free(m);
    const description = try std.fmt.allocPrint(allocator, "Especialista Pixel: {s} ({s})", .{ name, role });
    errdefer allocator.free(description);

    for (skills.items) |s| allocator.free(s);
    skills.deinit(allocator);

    return Specialist{
        .name = try allocator.dupe(u8, name),
        .department = department,
        .task_types = task_types,
        .system_prompt = system_prompt,
        .description = description,
        .model_hint = model_hint,
        .source = .pixel,
    };
}

fn divisionFromJson(allocator: std.mem.Allocator, obj: std.json.ObjectMap) RegistryError!PixelDivision {
    const id = getString(obj, "id") orelse return error.InvalidJson;
    const name = getString(obj, "name") orelse return error.InvalidJson;
    const emoji = getString(obj, "emoji") orelse "";
    const room_id = getString(obj, "roomId") orelse return error.InvalidJson;

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |a| allocator.free(a);
        ids.deinit(allocator);
    }
    if (obj.get("agentIds")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |item| {
                if (item == .string) {
                    try ids.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }
    return PixelDivision{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .emoji = try allocator.dupe(u8, emoji),
        .agent_ids = try ids.toOwnedSlice(allocator),
        .room_id = try allocator.dupe(u8, room_id),
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn inferTaskTypes(allocator: std.mem.Allocator, role: []const u8, specialization: []const u8, skills: [][]const u8) RegistryError![]model_router.TaskType {
    var list = std.ArrayList(model_router.TaskType).empty;
    errdefer list.deinit(allocator);
    const spec_lower = try std.ascii.allocLowerString(allocator, specialization);
    defer allocator.free(spec_lower);
    const role_lower = try std.ascii.allocLowerString(allocator, role);
    defer allocator.free(role_lower);

    const is_frontend = std.mem.indexOf(u8, spec_lower, "frontend") != null;
    const is_backend = std.mem.indexOf(u8, spec_lower, "backend") != null;
    const is_infra = std.mem.indexOf(u8, spec_lower, "infrastructure") != null or std.mem.indexOf(u8, spec_lower, "devops") != null;
    const is_testing = std.mem.indexOf(u8, spec_lower, "testing") != null or std.mem.eql(u8, role_lower, "qa");
    const is_lead = std.mem.indexOf(u8, spec_lower, "leadership") != null or std.mem.indexOf(u8, spec_lower, "architecture") != null;
    const is_security = std.mem.indexOf(u8, spec_lower, "security") != null;
    const is_developer = std.mem.eql(u8, role_lower, "developer");

    if (is_frontend or is_backend or is_infra or is_developer) {
        try list.append(allocator, .programar);
        try list.append(allocator, .programar_c);
        try list.append(allocator, .programar_cpp);
        try list.append(allocator, .programar_zig);
    }
    if (is_testing) try list.append(allocator, .testear);
    if (is_lead) {
        try list.append(allocator, .planificar);
        try list.append(allocator, .auditar);
    }
    if (is_security) try list.append(allocator, .auditar);

    for (skills) |sk| {
        const skl = try std.ascii.allocLowerString(allocator, sk);
        defer allocator.free(skl);
        if (std.mem.indexOf(u8, skl, "planning") != null and !containsTaskType(list.items, .planificar)) try list.append(allocator, .planificar);
        if ((std.mem.indexOf(u8, skl, "code-review") != null or std.mem.indexOf(u8, skl, "audit") != null) and !containsTaskType(list.items, .auditar)) try list.append(allocator, .auditar);
        if ((std.mem.indexOf(u8, skl, "test") != null or std.mem.indexOf(u8, skl, "e2e") != null) and !containsTaskType(list.items, .testear)) try list.append(allocator, .testear);
    }
    if (list.items.len == 0) try list.append(allocator, .programar);
    return list.toOwnedSlice(allocator);
}

fn containsTaskType(items: []const model_router.TaskType, tt: model_router.TaskType) bool {
    for (items) |it| if (it == tt) return true;
    return false;
}

fn buildSystemPrompt(allocator: std.mem.Allocator, name: []const u8, role: []const u8, specialization: []const u8, skills: [][]const u8) RegistryError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const header = try std.fmt.allocPrint(allocator, "Eres {s}, un agente especialista en {s} ({s}) de DevAgents.\n", .{ name, specialization, role });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);
    if (skills.len > 0) {
        try out.appendSlice(allocator, "Tus habilidades incluyen: ");
        for (skills, 0..) |sk, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, sk);
        }
        try out.appendSlice(allocator, ".\n");
    }
    // T7 (e): las reglas de código llegan en el bloque
    // [REGLAS DEL PROYECTO] (por defecto agent_def.CLEAN_CODE_RULES).
    try out.appendSlice(allocator, "Reglas estrictas:\n" ++
        "- Escribe SOLO dentro del sandbox asignado.\n" ++
        "- Sigue las [REGLAS DEL PROYECTO] que acompañan al encargo.\n");
    return out.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

const FIXTURE =
    \\{"agents":[{"id":"frontend-1","name":"Frontend Alpha","role":"developer",
    \\ "specialization":"frontend","skills":["react","typescript"],
    \\ "model":"opencode/gpt-5-nano","runtime":"opencode","spriteBase":"mage","color":"cyan"},
    \\ {"id":"qa-1","name":"QA Alpha","role":"qa","specialization":"testing",
    \\ "skills":["e2e-testing","automation"],"model":"opencode/gpt-5-nano"}],
    \\ "divisions":[{"id":"frontend","name":"Frontend Division","emoji":"\\u{1f3a8}",
    \\ "agentIds":["frontend-1"],"roomId":"skill-lab"}]}
;

test "loadFromJson parses 2 pixel agents + 1 division + 5 natives" {
    const allocator = std.testing.allocator;
    var reg = try loadFromJson(allocator, FIXTURE);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 7), reg.specialists.len); // 5 natives + 2 pixel
    try std.testing.expectEqual(@as(usize, 1), reg.divisions.len);

    // Verificar especialista frontend.
    const frontend = reg.findByDepartment("frontend");
    try std.testing.expect(frontend != null);
    try std.testing.expectEqualStrings("Frontend Alpha", frontend.?.name);
    try std.testing.expect(frontend.?.source == .pixel);
    try std.testing.expect(std.mem.indexOf(u8, frontend.?.system_prompt, "react") != null);
    try std.testing.expect(frontend.?.model_hint != null);
    try std.testing.expectEqualStrings("opencode/gpt-5-nano", frontend.?.model_hint.?);

    // QA: findByDepartment("testing") devuelve el nativo primero (orden de insercion).
    const native_testing = reg.findByDepartment("testing");
    try std.testing.expect(native_testing != null);
    try std.testing.expectEqualStrings("Testing", native_testing.?.name);
    try std.testing.expect(native_testing.?.source == .native);

    // Verificar que QA Alpha existe escaneando la lista.
    var found_qa = false;
    for (reg.specialists) |s| {
        if (std.mem.eql(u8, s.name, "QA Alpha")) {
            found_qa = true;
            try std.testing.expect(std.mem.indexOf(u8, s.system_prompt, "e2e-testing") != null);
            try std.testing.expect(s.source == .pixel);
            break;
        }
    }
    try std.testing.expect(found_qa);
}

test "findByTaskType returns specialist for programar" {
    const allocator = std.testing.allocator;
    var reg = try loadFromJson(allocator, FIXTURE);
    defer reg.deinit();
    const s = reg.findByTaskType(.programar);
    try std.testing.expect(s != null);
    // Nativo "programacion" es el primer que soporta programar.
    try std.testing.expectEqualStrings("programacion", s.?.department);
}

test "findByDepartment returns native testing" {
    const allocator = std.testing.allocator;
    var reg = try loadFromJson(allocator, FIXTURE);
    defer reg.deinit();
    const s = reg.findByDepartment("testing");
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("Testing", s.?.name);
    try std.testing.expect(s.?.source == .native);
}

test "loadFromJson empty object returns only natives" {
    const allocator = std.testing.allocator;
    var reg = try loadFromJson(allocator, "{}");
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 5), reg.specialists.len);
    try std.testing.expectEqual(@as(usize, 0), reg.divisions.len);
}

test "loadFromJson malformed returns ParseError" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ParseError, loadFromJson(allocator, "{bad"));
}

// PIXEL-DEVTEAM-05: regresión contra la FORMA REAL del dev-team.json de Pixel
// Enterprise (8 agentes + 4 divisiones). El FIXTURE sintético anterior solo tenía
// 2 agentes; este reproduce la estructura del archivo real para probar que el
// parser la procesa de punta a punta (no solo el caso de juguete).
const REAL_SHAPE_FIXTURE =
    \\{
    \\  "name": "Development Team",
    \\  "description": "Equipo de desarrollo software ágil",
    \\  "version": "1.0.0",
    \\  "agents": [
    \\    {"id":"dev-lead","name":"Dev Lead","role":"coordinator","specialization":"technical-leadership","skills":["architecture","code-review","mentoring","planning"],"model":"opencode/minimax-m2.5-free","runtime":"opencode","spriteBase":"warrior","color":"blue"},
    \\    {"id":"frontend-1","name":"Frontend Alpha","role":"developer","specialization":"frontend","skills":["react","vue","css","typescript"],"model":"opencode/gpt-5-nano","runtime":"opencode","spriteBase":"mage","color":"cyan"},
    \\    {"id":"frontend-2","name":"Frontend Beta","role":"developer","specialization":"frontend","skills":["react","angular","ui-design","accessibility"],"model":"opencode/gpt-5-nano","runtime":"opencode","spriteBase":"mage","color":"cyan"},
    \\    {"id":"backend-1","name":"Backend Alpha","role":"developer","specialization":"backend","skills":["nodejs","python","databases","api-design"],"model":"opencode/nemotron-3-super-free","runtime":"opencode","spriteBase":"soldier","color":"red"},
    \\    {"id":"backend-2","name":"Backend Beta","role":"developer","specialization":"backend","skills":["rust","go","microservices","kafka"],"model":"opencode/nemotron-3-super-free","runtime":"opencode","spriteBase":"soldier","color":"red"},
    \\    {"id":"devops-1","name":"DevOps Alpha","role":"devops","specialization":"infrastructure","skills":["docker","kubernetes","ci-cd","terraform"],"model":"opencode/minimax-m2.5-free","runtime":"opencode","spriteBase":"archer","color":"green"},
    \\    {"id":"qa-1","name":"QA Alpha","role":"qa","specialization":"testing","skills":["e2e-testing","performance","security","automation"],"model":"opencode/gpt-5-nano","runtime":"opencode","spriteBase":"slime","color":"default"},
    \\    {"id":"qa-2","name":"QA Beta","role":"qa","specialization":"testing","skills":["unit-testing","integration","manual-testing","bug-reports"],"model":"opencode/gpt-5-nano","runtime":"opencode","spriteBase":"slime","color":"default"}
    \\  ],
    \\  "divisions": [
    \\    {"id":"frontend","name":"Frontend Division","emoji":"F","agentIds":["frontend-1","frontend-2"],"roomId":"skill-lab"},
    \\    {"id":"backend","name":"Backend Division","emoji":"B","agentIds":["backend-1","backend-2"],"roomId":"war-room"},
    \\    {"id":"devops","name":"DevOps Division","emoji":"D","agentIds":["devops-1"],"roomId":"ops-desk"},
    \\    {"id":"qa","name":"QA Division","emoji":"Q","agentIds":["qa-1","qa-2"],"roomId":"quiet-bay"}
    \\  ],
    \\  "config": {"sessionCap": 8},
    \\  "rooms": []
    \\}
;

test "PIXEL-DEVTEAM-05: parser procesa la forma real (8 agentes + 4 divisiones)" {
    const allocator = std.testing.allocator;
    var reg = try loadFromJson(allocator, REAL_SHAPE_FIXTURE);
    defer reg.deinit();

    // 5 nativos + 8 Pixel = 13 especialistas; 4 divisiones.
    try std.testing.expectEqual(@as(usize, 13), reg.specialists.len);
    try std.testing.expectEqual(@as(usize, 4), reg.divisions.len);

    // Dev Lead (technical-leadership) → planifica y audita; model_hint correcto.
    const lead = blk: {
        for (reg.specialists) |*s| {
            if (std.mem.eql(u8, s.name, "Dev Lead")) break :blk s;
        }
        break :blk null;
    };
    try std.testing.expect(lead != null);
    try std.testing.expect(lead.?.source == .pixel);
    try std.testing.expect(containsTaskType(lead.?.task_types, .planificar));
    try std.testing.expect(containsTaskType(lead.?.task_types, .auditar));
    try std.testing.expect(lead.?.model_hint != null);
    try std.testing.expectEqualStrings("opencode/minimax-m2.5-free", lead.?.model_hint.?);

    // Backend → programa; QA → testea; DevOps (infrastructure) → programa.
    const backend = reg.findByDepartment("backend");
    try std.testing.expect(backend != null);
    try std.testing.expect(containsTaskType(backend.?.task_types, .programar));

    var qa_ok = false;
    var devops_ok = false;
    for (reg.specialists) |*s| {
        if (std.mem.eql(u8, s.name, "QA Alpha")) qa_ok = containsTaskType(s.task_types, .testear);
        if (std.mem.eql(u8, s.name, "DevOps Alpha")) devops_ok = containsTaskType(s.task_types, .programar);
    }
    try std.testing.expect(qa_ok);
    try std.testing.expect(devops_ok);

    // División backend referencia a sus 2 agentes.
    const div_backend = blk: {
        for (reg.divisions) |*d| {
            if (std.mem.eql(u8, d.id, "backend")) break :blk d;
        }
        break :blk null;
    };
    try std.testing.expect(div_backend != null);
    try std.testing.expectEqual(@as(usize, 2), div_backend.?.agent_ids.len);
}
