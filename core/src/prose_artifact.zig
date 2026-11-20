//! Shared lower bound for prose deliveries. This rejects transport metadata and
//! obviously insufficient explanations; it does not claim semantic correctness.
const std = @import("std");
const lang_detect = @import("lang_detect.zig");

pub fn isTextPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".txt", ".md", ".markdown", ".text" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

/// The extension alone cannot turn a program/test output into a prose task.
/// Intent (structured output, literals, short notes) is checked in invalidReason.
pub fn isProseDelivery(path: []const u8, task_type: anytype) bool {
    if (!isTextPath(path)) return false;
    return switch (task_type) {
        .documentar, .investigar, .resumir, .auditar => true,
        else => false,
    };
}

/// classification, exposed so the prompt and the gate share the very
/// same notion of "prose task" (documentar/investigar/resumir/auditar).
pub fn isProseTaskType(task_type: anytype) bool {
    return switch (task_type) {
        .documentar, .investigar, .resumir, .auditar => true,
        else => false,
    };
}

/// Explicit instruction appended to a prose worker's prompt so the deliverable
/// is written in the order's language. null when the task is not prose or the
/// order's language is not conclusive (then nothing is imposed).
pub fn proseLanguageInstruction(task_type: anytype, description: []const u8) ?[]const u8 {
    if (!isProseTaskType(task_type)) return null;
    return switch (lang_detect.detect(description)) {
        .es => "Responde en español. Redacta todo el entregable de prosa en español.",
        .en => "Responde en inglés. Redacta todo el entregable de prosa en inglés.",
        .unknown => null,
    };
}

/// Cuerpo con pinta de código, JSON, marcado o configuración: no se juzga por
/// idioma (una variable o una clave inglesa no significa que la prosa lo esté).
fn looksStructuredOrCode(body: []const u8) bool {
    const t = std.mem.trim(u8, body, " \t\r\n");
    if (t.len == 0) return false;
    if (t[0] == '{' or t[0] == '[' or t[0] == '<') return true;
    if (std.mem.indexOf(u8, body, "```") != null) return true;
    for ([_][]const u8{
        "def ",     "function ", "class ",  "import ",  "#include", "console.log(",
        "print(",   "=>",        "();",     "package ", "public ",  "private ",
        "void ",    "fn ",       "return ", "</",       "SELECT ",  "INSERT ",
        "const ",   "let ",      "var ",    "std::",    "#!",       "<?php",
        "require(", "#!/",
    }) |sig| {
        if (std.mem.indexOf(u8, body, sig) != null) return true;
    }
    // Configuración tipo clave=valor / clave: valor en TODAS las líneas.
    var it = std.mem.splitScalar(u8, body, '\n');
    var total: usize = 0;
    var structured: usize = 0;
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (l.len == 0) continue;
        total += 1;
        if (isKeyValueLine(l)) structured += 1;
    }
    return total > 0 and structured == total;
}

fn isKeyValueLine(line: []const u8) bool {
    const sep = std.mem.indexOfAny(u8, line, "=:") orelse return false;
    if (sep == 0 or sep + 1 >= line.len) return false;
    const key = std.mem.trim(u8, line[0..sep], " \t");
    if (key.len == 0) return false;
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

/// Cause to reject a prose deliverable whose detected language is conclusive and
/// different from the order's. Returns null for code/JSON/config bodies and for
/// inconclusive cases. Call it only on prose-task deliverables.
pub fn languageMismatchReason(raw: []const u8, description: []const u8) ?[]const u8 {
    const body = std.mem.trim(u8, raw, " \t\r\n");
    if (body.len == 0) return null;
    if (requestsStructuredOutput(description)) return null;
    if (looksStructuredOrCode(body)) return null;
    const order_lang = lang_detect.detect(description);
    if (order_lang == .unknown) return null;
    const body_lang = lang_detect.detect(body);
    if (body_lang == .unknown or body_lang == order_lang) return null;
    return switch (order_lang) {
        .es => "el entregable está en inglés y la orden en español",
        .en => "el entregable está en español y la orden en inglés",
        .unknown => null,
    };
}

pub fn isMetadataField(field: []const u8) bool {
    for ([_][]const u8{ "filename", "file_name", "filepath", "file_path", "path", "archivo", "nombre_archivo", "type", "task_type", "department", "id", "status", "expects" }) |name| {
        if (std.ascii.eqlIgnoreCase(field, name)) return true;
    }
    return false;
}

fn basename(path: []const u8) []const u8 {
    const last = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[last + 1 ..];
}

fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    if (text.len < needle.len) return false;
    for (0..text.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn requestsLiteral(description: []const u8, body: []const u8) bool {
    if (body.len == 0) return false;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, description, offset, body)) |pos| {
        const end = pos + body.len;
        const quoted = pos > 0 and end < description.len and
            (description[pos - 1] == '"' or description[pos - 1] == '\'' or description[pos - 1] == '`') and
            description[end] == description[pos - 1];
        const before = std.mem.trimEnd(u8, description[0..if (quoted) pos - 1 else pos], " \t\r\n");
        for ([_][]const u8{ "diga", "contenga", "contenido:", "contenido es", "literal", "literalmente", "exactamente", "exactly", "contains", "saying", "content:" }) |marker| {
            if (before.len >= marker.len and std.ascii.eqlIgnoreCase(before[before.len - marker.len ..], marker)) return true;
        }
        offset = end;
    }
    return false;
}

fn requestsBriefText(description: []const u8) bool {
    for ([_][]const u8{
        "una frase",      "una oracion",
        "una oración",
        "una linea",
        "una línea",
        "one sentence",   "single sentence",
        "one line",       "single line",
        "nota breve",     "nota corta",
        "short note",     "brief note",
        "texto corto",    "short text",
        "resumen breve",  "short summary",
        "pocas palabras", "few words",
    }) |phrase| {
        if (containsIgnoreCase(description, phrase)) return true;
    }
    return false;
}

fn requestsStructuredOutput(description: []const u8) bool {
    // These describe the requested representation, not an incidental mention
    // of "document", "risk", or a language in a prose explanation.
    for ([_][]const u8{
        "archivo de configuracion",
        "archivo de configuración",
        "configuration file",
        "config file",
        "como json",
        "as json",
        "json en ",
        "json in ",
        "codigo python en ",
        "código python en ",
        "codigo en ",
        "código en ",
        "code in ",
        "python code",
        "script en ",
        "script in ",
    }) |phrase| {
        if (containsIgnoreCase(description, phrase)) return true;
    }
    return false;
}

fn requestsExplanation(description: []const u8) bool {
    var request = std.mem.trim(u8, description, " \t\r\n");
    for ([_][]const u8{ "please ", "por favor " }) |prefix| {
        if (request.len >= prefix.len and std.ascii.eqlIgnoreCase(request[0..prefix.len], prefix)) request = request[prefix.len..];
    }
    const end = std.mem.indexOfAny(u8, request, " \t\r\n:,.!?") orelse request.len;
    // A task label alone supplies no requested topic or extent to measure.
    if (std.mem.trim(u8, request[end..], " \t\r\n:,.!?").len == 0) return false;
    for ([_][]const u8{ "documenta", "documentar", "document", "explica", "explicar", "explain", "analiza", "analizar", "analyze", "analyse", "investiga", "investigar", "investigate", "resume", "resumir", "summarize", "summarise" }) |verb| {
        if (std.ascii.eqlIgnoreCase(request[0..end], verb)) return true;
    }
    for ([_][]const u8{ "un documento", "una explicacion", "una explicación", "a document", "an explanation", "write documentation" }) |phrase| {
        if (containsIgnoreCase(request, phrase)) return true;
    }
    return false;
}

/// The description must be the actual task/order request, never the generated
/// document. Empty description preserves legitimate short literal files (S21).
pub fn invalidReason(path: []const u8, raw: []const u8, description: []const u8) ?[]const u8 {
    if (!isTextPath(path)) return null;
    const body = std.mem.trim(u8, raw, " \t\r\n");
    if (body.len == 0) return "entregable de prosa vacio";
    // A requested literal can itself be a path or a task label. The empty
    // artifact is still invalid, and all ordinary metadata remains rejected.
    if (requestsLiteral(description, body)) return null;
    if (std.ascii.eqlIgnoreCase(body, path) or std.ascii.eqlIgnoreCase(body, basename(path)) or
        (std.mem.indexOfAny(u8, body, " \t\r\n") == null and
            std.mem.indexOfAny(u8, body, "/\\") != null and
            std.ascii.eqlIgnoreCase(basename(body), basename(path)))) return "el contenido es su propia ruta";
    for ([_][]const u8{ "documentacion", "documentación", "documentation", "documentar", "auditoria", "auditoría", "auditar", "programacion", "programación", "programar", "investigar", "resumir", "testear", "corregir", "ejecutar", "disenar", "planificar" }) |label| {
        if (std.ascii.eqlIgnoreCase(body, label)) return "el contenido es un tipo de tarea o departamento";
    }
    if (body.len < 80 and requestsExplanation(description) and
        !requestsBriefText(description) and !requestsStructuredOutput(description))
    {
        return "prosa insuficiente para la explicacion solicitada (menos de 80 bytes)";
    }
    return null;
}

test "MOT018 prose policy preserves requested literals and rejects metadata" {
    try std.testing.expect(isTextPath("README.MD"));
    try std.testing.expect(!isTextPath("result"));
    try std.testing.expect(!isTextPath("main.py"));
    try std.testing.expect(isMetadataField("file_path"));
    try std.testing.expect(isMetadataField("TASK_TYPE"));
    try std.testing.expect(!isMetadataField("text"));
    const request = "Documenta brevemente los riesgos de guardar claves de API en texto plano";
    for ([_][]const u8{ "", "  \n", "documentacion", "documentar", "risks.txt", "docs/risks.txt", "docs\\risks.txt", "Riesgos de API." }) |bad| {
        try std.testing.expect(invalidReason("risks.txt", bad, request) != null);
    }
    try std.testing.expect(invalidReason("risks.txt", "Las claves de API en texto plano pueden filtrarse en repositorios y copias de seguridad. Usa un gestor de secretos, limita los permisos y revoca las claves expuestas.", request) == null);
    try std.testing.expect(invalidReason("a.txt", "UNO", "") == null);
    try std.testing.expect(invalidReason("a.txt", "UNO", "Crea un documento cuyo contenido es UNO") == null);
    try std.testing.expect(invalidReason("a.md", "hola", "Documenta con el literal 'hola'") == null);
    try std.testing.expect(invalidReason("a.md", "hola", "Documenta con el literal `hola`") == null);
    try std.testing.expect(invalidReason("a.md", "hola", "Documenta con el literal \"hola\"") == null);
    try std.testing.expect(invalidReason("main.py", "documentacion", request) == null);
}

test "MOT018 fix preserves short configuration JSON and code in text files" {
    try std.testing.expect(invalidReason("settings.txt", "document=enabled\n", "Crea un archivo de configuracion settings.txt con la opcion document") == null);
    try std.testing.expect(invalidReason("data.txt", "{\"document\":true}", "Documenta el resultado como JSON en data.txt") == null);
    try std.testing.expect(invalidReason("code.txt", "print(42)\n", "Documenta el ejemplo con codigo Python en code.txt") == null);
}

test "MOT018 fix accepts explicit short notes summaries and path literals" {
    try std.testing.expect(invalidReason("note.txt", "Usa un gestor de secretos.", "Documenta una nota breve sobre claves API") == null);
    try std.testing.expect(invalidReason("summary.txt", "Las claves expuestas permiten acceso y gastos no autorizados", "Resume en una frase los riesgos de guardar claves de API") == null);
    try std.testing.expect(invalidReason("summary.txt", "Plaintext keys expose accounts.", "Summarize the risks in one sentence") == null);
    try std.testing.expect(invalidReason("risks.txt", "docs/risks.txt", "Escribe literalmente 'docs/risks.txt' en risks.txt") == null);
    try std.testing.expect(invalidReason("note.txt", "documentacion", "Escribe el literal 'documentacion' en note.txt") == null);
}

test "MOT018 fix a quoted destination is not a requested literal body" {
    try std.testing.expect(invalidReason("risks.txt", "docs/risks.txt", "Documenta los riesgos de claves API en 'docs/risks.txt'") != null);
    try std.testing.expect(invalidReason("risks.txt", "risks.txt", "Document the risks in \"risks.txt\"") != null);
    try std.testing.expect(invalidReason("risks.txt", "risks.txt", "Write 'risks.txt' with an explanation of API key risks") != null);
}

test "MOT018 fix English explanations reject trivial prose and accept the body" {
    const request = "Document the risks of storing API keys in plain text in risks.txt";
    try std.testing.expect(invalidReason("risks.txt", "API risks.", request) != null);
    try std.testing.expect(invalidReason("risks.txt", "Storing API keys in plain text exposes accounts to unauthorized access and unexpected charges. Keep secrets out of repositories and logs, restrict access and revoke leaked keys immediately.", request) == null);
    try std.testing.expect(invalidReason("note.txt", "Useful note.", "Create note.txt for the document field") == null);
}

test "MOT018 fix excludes extensionless build license log and csv files" {
    for ([_][]const u8{ "Dockerfile", "Makefile", "LICENSE", "events.log", "data.csv" }) |path| {
        try std.testing.expect(!isTextPath(path));
        try std.testing.expect(invalidReason(path, "MIT", "Documenta y analiza el resultado") == null);
    }
}

test "MOT018 fix a bare task label does not impose explanation length" {
    try std.testing.expect(invalidReason("informe.md", "# Informe\n\nHallazgos del analisis.", "Documentar") == null);
    try std.testing.expect(invalidReason("informe.md", "documentacion", "Documentar") != null);
    try std.testing.expect(invalidReason("informe.md", "", "Documentar") != null);
}

test "MOT017 prose task classification reused for the language rule" {
    const mr = @import("model_router.zig");
    try std.testing.expect(isProseTaskType(mr.TaskType.documentar));
    try std.testing.expect(isProseTaskType(mr.TaskType.investigar));
    try std.testing.expect(isProseTaskType(mr.TaskType.resumir));
    try std.testing.expect(isProseTaskType(mr.TaskType.auditar));
    try std.testing.expect(!isProseTaskType(mr.TaskType.programar_c));
    try std.testing.expect(!isProseTaskType(mr.TaskType.testear));
}

test "MOT017 prose language instruction follows the order language" {
    const mr = @import("model_router.zig");
    const es_order = "Documenta brevemente en un texto los riesgos de guardar claves de API en texto plano";
    const en_order = "Document the risks of storing API keys in plain text";
    try std.testing.expect(containsIgnoreCase(proseLanguageInstruction(mr.TaskType.documentar, es_order).?, "español"));
    try std.testing.expect(containsIgnoreCase(proseLanguageInstruction(mr.TaskType.documentar, en_order).?, "inglés"));
    try std.testing.expect(proseLanguageInstruction(mr.TaskType.documentar, "hola") == null);
    try std.testing.expect(proseLanguageInstruction(mr.TaskType.programar_c, es_order) == null);
    try std.testing.expect(proseLanguageInstruction(mr.TaskType.auditar, es_order) != null);
}

test "MOT017 gate rejects English prose for a Spanish order and accepts Spanish" {
    const es_order = "Documenta brevemente en un texto los riesgos de guardar claves de API en texto plano";
    const en_order = "Document the risks of storing API keys in plain text";
    const es_body = "Las claves de API en texto plano pueden filtrarse en repositorios y copias de seguridad. Usa un gestor de secretos y revoca las claves expuestas.";
    const en_body = "Storing API keys in plain text exposes accounts to unauthorized access and unexpected charges. Keep secrets out of repositories and logs.";

    try std.testing.expect(containsIgnoreCase(languageMismatchReason(en_body, es_order).?, "inglés"));
    try std.testing.expect(languageMismatchReason(es_body, es_order) == null);
    try std.testing.expect(languageMismatchReason(en_body, en_order) == null);
    try std.testing.expect(containsIgnoreCase(languageMismatchReason(es_body, en_order).?, "español"));
}

test "MOT017 gate does not judge code json or config by language" {
    const es_order = "Documenta los riesgos de guardar claves de API en texto plano";
    try std.testing.expect(languageMismatchReason("print(\"Hello world\")", es_order) == null);
    try std.testing.expect(languageMismatchReason("{\"document\": true, \"value\": \"yes\"}", es_order) == null);
    try std.testing.expect(languageMismatchReason("document=enabled\nversion=2", es_order) == null);
    try std.testing.expect(languageMismatchReason("#include <stdio.h>\nint main() { return 0; }", es_order) == null);
    // Una orden que pide explícitamente JSON/código no impone el idioma al cuerpo.
    try std.testing.expect(languageMismatchReason("{\"ok\": true}", "Documenta el resultado como JSON en data.txt") == null);
}
