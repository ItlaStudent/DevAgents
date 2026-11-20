const std = @import("std");
const tool_discovery = @import("tool_discovery.zig");
const model_router = @import("model_router.zig");

pub const Department = enum {
    programacion,
    testing,
    auditoria,
    correccion,
    documentacion,
    diseno,

    pub fn fromText(text: []const u8) ?Department {
        const map = std.StaticStringMap(Department).initComptime(.{
            .{ "programacion", .programacion },
            .{ "testing", .testing },
            .{ "auditoria", .auditoria },
            .{ "correccion", .correccion },
            .{ "documentacion", .documentacion },
            .{ "diseno", .diseno },
        });
        return map.get(text);
    }

    pub fn toText(self: Department) []const u8 {
        return switch (self) {
            .programacion => "programacion",
            .testing => "testing",
            .auditoria => "auditoria",
            .correccion => "correccion",
            .documentacion => "documentacion",
            .diseno => "diseno",
        };
    }
};

pub const AgentDef = struct {
    name: []const u8,
    department: Department,
    task_types: []const model_router.TaskType,
    system_prompt: []const u8,
    description: []const u8,

    pub fn deinit(self: *const AgentDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.task_types);
        allocator.free(self.system_prompt);
        allocator.free(self.description);
    }
};

pub const AgentDefError = error{
    OutOfMemory,
    MissingFrontmatter,
    MissingField,
    InvalidDepartment,
    InvalidTaskType,
    EmptySystemPrompt,
};

/// Parsea una definición de agente desde contenido markdown con frontmatter YAML.
/// Reutiliza `parseFrontmatter` de tool_discovery (sin duplicar, FR-002/SC-003 de spec 012).
pub fn parseAgentDef(allocator: std.mem.Allocator, content: []const u8) AgentDefError!AgentDef {
    var fm = try tool_discovery.parseFrontmatter(allocator, content) orelse return error.MissingFrontmatter;
    defer fm.deinit();

    const name = fm.get("name") orelse return error.MissingField;
    const dept_text = fm.get("department") orelse return error.MissingField;
    const dept = Department.fromText(dept_text) orelse return error.InvalidDepartment;
    const task_types_text = fm.get("task_types") orelse return error.MissingField;
    const system_prompt = fm.get("system_prompt") orelse return error.MissingField;

    if (system_prompt.len == 0) return error.EmptySystemPrompt;

    const desc = fm.get("description");
    const description = if (desc) |d| d else "";

    const task_types = try parseTaskTypes(allocator, task_types_text);
    errdefer allocator.free(task_types);

    return AgentDef{
        .name = try allocator.dupe(u8, name),
        .department = dept,
        .task_types = task_types,
        .system_prompt = try allocator.dupe(u8, system_prompt),
        .description = try allocator.dupe(u8, description),
    };
}

fn parseTaskTypes(allocator: std.mem.Allocator, text: []const u8) AgentDefError![]const model_router.TaskType {
    var list = std.ArrayList(model_router.TaskType).empty;
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, text, " \t\r\n[],\"'");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        const tt = taskTypeFromText(token) orelse return error.InvalidTaskType;
        try list.append(allocator, tt);
    }

    return list.toOwnedSlice(allocator);
}

fn taskTypeFromText(text: []const u8) ?model_router.TaskType {
    const map = std.StaticStringMap(model_router.TaskType).initComptime(.{
        .{ "planificar", .planificar },
        .{ "programar", .programar },
        .{ "programar_c", .programar_c },
        .{ "programar_cpp", .programar_cpp },
        .{ "programar_zig", .programar_zig },
        .{ "testear", .testear },
        .{ "auditar", .auditar },
        .{ "corregir", .corregir },
        .{ "documentar", .documentar },
        .{ "investigar", .investigar },
        .{ "resumir", .resumir },
        .{ "ejecutar", .ejecutar },
        .{ "ui", .ui },
        .{ "disenar", .disenar },
    });
    return map.get(text);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parse valid agent definition" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: Programación
        \\department: programacion
        \\task_types: ["programar_c", "programar_cpp", "programar_zig"]
        \\system_prompt: Eres un agente de programación experto en C, C++ y Zig.
        \\description: Departamento de implementación de código fuente.
        \\---
        \\# Programación
        \\
        \\Este departamento escribe el código fuente del proyecto.
    ;

    const def = try parseAgentDef(allocator, content);
    defer def.deinit(allocator);

    try std.testing.expectEqualStrings("Programación", def.name);
    try std.testing.expectEqual(Department.programacion, def.department);
    try std.testing.expectEqual(@as(usize, 3), def.task_types.len);
    try std.testing.expectEqual(model_router.TaskType.programar_c, def.task_types[0]);
    try std.testing.expectEqual(model_router.TaskType.programar_cpp, def.task_types[1]);
    try std.testing.expectEqual(model_router.TaskType.programar_zig, def.task_types[2]);
    try std.testing.expect(def.system_prompt.len > 0);
    try std.testing.expect(def.description.len > 0);
}

test "rejects missing frontmatter" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingFrontmatter, parseAgentDef(allocator, "solo texto sin frontmatter"));
}

test "rejects invalid department" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: X
        \\department: inventado
        \\task_types: [programar_c]
        \\system_prompt: hace algo
        \\---
    ;
    try std.testing.expectError(error.InvalidDepartment, parseAgentDef(allocator, content));
}

test "rejects empty system_prompt" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: X
        \\department: testing
        \\task_types: [testear]
        \\system_prompt:
        \\---
    ;
    try std.testing.expectError(error.EmptySystemPrompt, parseAgentDef(allocator, content));
}

test "rejects invalid task_type" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: X
        \\department: auditoria
        \\task_types: [volar]
        \\system_prompt: audita cosas
        \\---
    ;
    try std.testing.expectError(error.InvalidTaskType, parseAgentDef(allocator, content));
}

test "parses all six base departments without error" {
    const allocator = std.testing.allocator;
    const fixtures = [_]struct { raw: []const u8 }{
        .{ .raw = PROGRAMACION_DEF },
        .{ .raw = TESTING_DEF },
        .{ .raw = AUDITORIA_DEF },
        .{ .raw = CORRECCION_DEF },
        .{ .raw = DOCUMENTACION_DEF },
        .{ .raw = DISENO_DEF },
    };
    for (fixtures) |f| {
        const def = try parseAgentDef(allocator, f.raw);
        defer def.deinit(allocator);
        // Afirmar contenido real del system_prompt, no solo len>0 (previene falso-verde).
        try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "RAII") != null or
            std.mem.indexOf(u8, def.system_prompt, "DevAgents") != null);
        try std.testing.expect(def.description.len > 0);
    }
}

test "parse deparment with block scalar loads multiline system_prompt" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: Programación
        \\department: programacion
        \\task_types: [programar_c, programar_cpp, programar_zig, corregir]
        \\system_prompt: |
        \\  Eres un agente del departamento de Programación de DevAgents.
        \\  Usa RAII para la gestión de recursos.
        \\  Escribe SOLO dentro del sandbox asignado.
        \\description: Departamento de implementación de código fuente.
        \\---
        \\# Programación
    ;

    const def = try parseAgentDef(allocator, content);
    defer def.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "RAII") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "DevAgents") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "sandbox") != null);
}

test "parse deparment without block scalar (inline) still works" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: Testing
        \\department: testing
        \\task_types: [testear]
        \\system_prompt: Eres un agente de testing. Usa testeos rigurosos.
        \\description: Departamento de testing.
        \\---
        \\# Testing
    ;

    const def = try parseAgentDef(allocator, content);
    defer def.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "testeos") != null);
}

test "parse real programacion.md from agents/ loads full prompt with RAII" {
    const allocator = std.testing.allocator;
    const content = PROGRAMACION_DEF;
    const def = try parseAgentDef(allocator, content);
    defer def.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "RAII") != null);
    // T7: las reglas viajan en [REGLAS DEL PROYECTO] (CLEAN_CODE_RULES por defecto).
    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "[REGLAS DEL PROYECTO]") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "sandbox") != null);
    try std.testing.expect(def.system_prompt.len > 20);
    try std.testing.expect(std.mem.indexOf(u8, CLEAN_CODE_RULES, "RAII") != null);
    try std.testing.expect(std.mem.indexOf(u8, CLEAN_CODE_RULES, "Maneja todo error") != null);
}

test "parse real auditoria.md from agents/ loads full prompt with 'modelo DISTINTO'" {
    const allocator = std.testing.allocator;
    const content = AUDITORIA_DEF;
    const def = try parseAgentDef(allocator, content);
    defer def.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "DISTINTO") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "falso-verde") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.system_prompt, "parámetros enlazados") != null);
}

// ── Definiciones base de los 5 departamentos ───────────────────────────

/// T7 (e): reglas de código limpio por defecto de «Reglas del
/// proyecto». Una sola fuente: el bloque [REGLAS DEL PROYECTO] que llega a
/// Directo, Orquestado, Colmena, delegación y CLIs externas sale de aquí
/// cuando el proyecto no tiene reglas propias (core/src/project_rules.zig).
pub const CLEAN_CODE_RULES =
    \\Reglas de código limpio (aplican a cualquier lenguaje, con sus idioms):
    \\- Maneja todo error explícitamente (nunca ignores códigos de retorno/excepciones).
    \\- Libera recursos de forma determinista (RAII/defer/with/try-finally según el lenguaje).
    \\- Sin estado global mutable sin justificación.
    \\- Sin números ni cadenas mágicas: constantes con nombre.
    \\- Funciones cortas y enfocadas; nombres autoexplicativos.
    \\- Acompaña con pruebas cuando aplique.
    \\- Aplica el formateador estándar del lenguaje antes de entregar.
;

pub const PROGRAMACION_DEF =
    \\---
    \\name: Programación
    \\department: programacion
    \\task_types: [programar, programar_c, programar_cpp, programar_zig, corregir]
    \\system_prompt: |
    \\  Eres un agente del departamento de Programación de DevAgents.
    \\  Implementas código en EL LENGUAJE que pida el usuario o sea el más adecuado para
    \\  la tarea (Python, JavaScript, Go, Rust, C, C++, Zig, etc.). NOTA: DevAgents (la
    \\  herramienta) está escrito en C/C++/Zig por eficiencia, pero eso NO limita el código
    \\  que TÚ produces — programa en lo que la orden requiera.
    \\  Sigue las [REGLAS DEL PROYECTO] que acompañan al encargo (por defecto, las de código
    \\  limpio de DevAgents: errores explícitos, RAII/defer, funciones cortas...), adaptadas
    \\  al lenguaje.
    \\  Reglas estrictas:
    \\  - Escribe SOLO dentro del sandbox asignado.
    \\description: Departamento de implementación de código fuente en cualquier lenguaje.
    \\---
;

pub const TESTING_DEF =
    \\---
    \\name: Testing
    \\department: testing
    \\task_types: [testear]
    \\system_prompt: |
    \\  Eres un agente del departamento de Testing de DevAgents.
    \\  Tu función es verificar que el código producido por Programación
    \\  compila, pasa los tests y cumple los estándares.
    \\  Reglas estrictas:
    \\  - Ejecuta zig build test / herramientas de test del proyecto.
    \\  - Un test que no se ejecuta es un test que falló (lección anti-falso-verde).
    \\  - Registra TODA evidencia en audit_ledger (action=BUILD).
    \\  - Reporta: pass/fail, cobertura, warnings, fugas de memoria.
    \\  - Escribe SOLO dentro del sandbox asignado.
    \\description: Ejecuta compilación, tests y sanitizers; registra evidencias.
    \\---
;

pub const AUDITORIA_DEF =
    \\---
    \\name: Auditoría
    \\department: auditoria
    \\task_types: [auditar]
    \\system_prompt: |
    \\  Eres un agente del departamento de Auditoría de DevAgents.
    \\  Tu función es revisar el código y las evidencias de testing con
    \\  escepticismo profesional. Eres la defensa contra el falso-verde.
    \\  Reglas estrictas:
    \\  - DEBES usar un modelo DISTINTO al que generó el código (Principio V).
    \\  - Revisa: cumplimiento de specs, de las [REGLAS DEL PROYECTO] y de la constitución.
    \\  - Busca: stubs disfrazados, asserts triviales, specs incumplidas.
    \\  - Verifica: parámetros enlazados (no interpolación SQL), escape JSON.
    \\  - Un ✖ bien fundado vale más que diez ✔ de cortesía.
    \\  - Registra veredicto en audit_ledger (action=AUDIT, verdict=PASS|FAIL).
    \\  - Si FAIL, enumera hallazgos concretos con referencia a spec/estándar.
    \\  - Cada cita va como archivo:línea seguido del texto LITERAL de esa línea
    \\    entre comillas invertidas. El motor abre el archivo y comprueba cada una:
    \\    una sola cita que no está donde dices invalida el informe entero.
    \\description: Revisa código con modelo distinto al constructor; registra veredictos.
    \\---
;

pub const CORRECCION_DEF =
    \\---
    \\name: Corrección
    \\department: correccion
    \\task_types: [corregir]
    \\system_prompt: |
    \\  Eres un agente del departamento de Corrección de DevAgents.
    \\  Tu función es arreglar los hallazgos reportados por Auditoría.
    \\  Reglas estrictas:
    \\  - Cada corrección referencia el ID del hallazgo de auditoría.
    \\  - No introduzcas nuevos problemas al corregir.
    \\  - Si un hallazgo no es corregible, documéntalo como deuda explícita.
    \\  - Tras corregir, la pieza vuelve a Testing → Auditoría.
    \\  - Registra cada fix en audit_ledger (action=FIX).
    \\  - Escribe SOLO dentro del sandbox asignado.
    \\description: Corrige hallazgos de auditoría; re-abre el ciclo de validación.
    \\---
;

pub const DOCUMENTACION_DEF =
    \\---
    \\name: Documentación
    \\department: documentacion
    \\task_types: [documentar, resumir]
    \\system_prompt: |
    \\  Eres un agente del departamento de Documentación de DevAgents.
    \\  Tu función es generar y mantener la documentación del proyecto.
    \\  Reglas estrictas:
    \\  - Documenta QUÉ y POR QUÉ, no CÓMO (el código es autoexplicativo).
    \\  - Actualiza CHANGELOG.md, ROADMAP.md y specs afectadas.
    \\  - Genera reportes piramidales consolidando hallazgos de todos los deptos.
    \\  - Escribe en el sandbox asignado o en docs/ si la tarea lo autoriza.
    \\description: Genera y mantiene documentación técnica y reportes consolidados.
    \\---
;

pub const DISENO_DEF =
    \\---
    \\name: Diseño
    \\department: diseno
    \\task_types: [disenar]
    \\system_prompt: |
    \\  Eres un agente del departamento de Diseño de DevAgents.
    \\  Tu función es generar prompts de diseño para Open Design y ejecutarlos
    \\  via el bridge MCP de Open Design.
    \\  Reglas estrictas:
    \\  - Analiza la orden del usuario y genera un prompt de diseño claro y específico.
    \\  - El prompt debe incluir: tipo de diseño, estilo, dimensiones, colores, contexto.
    \\  - Entrega el prompt en el campo 'prompt' del contrato.
    \\  - El resultado de Open Design (URL o artefacto) se registra en 'result'.
    \\  - Si Open Design no está disponible, reporta la degradación claramente.
    \\  - Colabora con Auditoría para validar que el diseño cumple la orden.
    \\description: Genera prompts de diseño y los ejecuta via Open Design bridge MCP.
    \\---
;
