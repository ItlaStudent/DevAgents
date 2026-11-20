//! el parser ÚNICO de artefactos del motor.
//!
//! De un blob del proveedor (prosa, fences, o JSON puro) a una lista de
//! `{path, content}`. Aquí vivían tres implementaciones del mismo contrato:
//! `live_worker.extractJsonArray` (extracción textual), `worker_backend.parseLlmResponse`
//! (validación con std.json) y `cli_worker.parseArtifactsFromOutput` (parser manual del
//! worker de CLI). Las tres arrastraron el mismo defecto: decidir QUÉ trozo del texto es
//! el JSON por la forma del texto (primer `[` .. último `]`, o «debe empezar por [») en
//! vez de localizar el JSON de artefactos por sí mismo. Una respuesta buena —objeto
//! suelto, corchetes dentro del código generado, prosa/fences alrededor— se tiraba a
//! basura como `empty` (orden 148: 6788 caracteres válidos; 69/75 modelos a cero).
//!
//! `parseArtifacts` es el contrato unificado: prueba los candidatos balanceados en
//! orden (arrays primero, luego objetos, luego el texto entero) y se queda con el
//! primero que parsea como contrato. `parseArtifactsJson` es el pivote estricto
//! (JSON ya aislado) que usaban `worker_backend.parseLlmResponse` y sus llamadas.
//!
//! Las tres rutas (live_worker, worker_backend y cli_worker) delegan aquí; en
//! `worker_backend` quedan solo alias de compatibilidad para los llamadores que no
//! cambian de firma.
const std = @import("std");

pub const Artifact = struct {
    path: []const u8,
    content: []const u8,
    /// / E-GOV.1: procedencia recogida por el motor (línea base del
    /// espacio), nunca deducida del JSON del modelo. `null` conserva el gate
    /// estricto para artefactos nuevos o sin procedencia.
    inherited_placeholders: ?[]const @import("artifact_quality.zig").LineHash = null,

    pub fn deinit(self: *const Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
        if (self.inherited_placeholders) |lines| allocator.free(lines);
    }
};

/// Errores del parser: subconjunto de `worker_backend.WorkerError` (InvalidArtifact
/// + OutOfMemory), para que los envoltorios del worker los propaguen sin cambios.
pub const ParseError = error{ OutOfMemory, InvalidArtifact };

/// Par de `open`/`close` BALANCEADO dentro de `text`, ignorando los que aparezcan
/// DENTRO de strings JSON (y sus escapes) — que es justo donde vive el código fuente
/// que emiten los modelos. Null si ninguno llega a cerrar, lo cual es la firma real
/// de una respuesta truncada.
///
/// El estado de string se calcula SIEMPRE desde 0, nunca desde el candidato: si ese
/// corchete vive DENTRO de una string JSON —el caso de la orden 148,
/// `botones = [\"7\"]` dentro del código— arrancar ahí se creería fuera de la string
/// y se comería los escapes al revés. Los corchetes del código generado así no son
/// candidatos.
///
/// Auditoría el segundo auditor lote 9 (hallazgo medio): un `open` sin pareja en la prosa (p. ej.
/// `prosa [ sin cerrar` antes del JSON) no puede secuestrar la búsqueda. Si el
/// candidato no cierra, se reanuda tras ese `open` y se prueba el siguiente en vez
/// de dar el texto entero por perdido.
pub fn scanBalanced(text: []const u8, open: u8, close: u8) ?[]const u8 {
    const cand = scanBalancedFrom(text, 0, open, close) orelse return null;
    return cand.slice;
}

/// Candidato balanceado: su slice y el índice (en `text`) del primer byte después
/// del cierre. Permite recorrer el texto candidato a candidato sin recalcular
/// offsets por punteros.
const Candidate = struct { slice: []const u8, end: usize };

/// Índice del primer `open` en/después de `from` que está FUERA de una string JSON.
/// El estado de string se recalcula desde 0 para no confundir los corchetes que
/// viven dentro del código emitido (orden 148) con contenedores.
fn nextOpenOutsideString(text: []const u8, from: usize, open: u8) ?usize {
    var in_str = false;
    var esc = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (i >= from and c == open) return i;
    }
    return null;
}

/// Índice del primer byte después del cierre del par que empieza en `start`
/// (que debe ser un `open` fuera de string), o null si no llega a cerrar.
fn balancedEnd(text: []const u8, start: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var i: usize = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == open) {
            depth += 1;
        } else if (c == close and depth > 0) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn scanBalancedFrom(text: []const u8, from: usize, open: u8, close: u8) ?Candidate {
    var cursor = from;
    while (cursor < text.len) {
        const start = nextOpenOutsideString(text, cursor, open) orelse return null;
        if (balancedEnd(text, start, open, close)) |end| {
            return .{ .slice = text[start..end], .end = end };
        }
        // Candidato malformado o sin cerrar (un `[` suelto en la prosa): se
        // reanuda después de ese `open`, no se descarta el resto del texto.
        cursor = start + 1;
    }
    return null;
}

/// Extrae el primer array JSON balanceado de un blob que puede llevar prosa o
/// fenced blocks alrededor. Sin array envolvente, un objeto suelto es UN artefacto
/// y se devuelve igual. Si no hay nada, devuelve el texto tal cual (el parser lo
/// rechazará con error.InvalidArtifact). Es el contrato textual que usan los
/// diagnósticos (`live_worker`) para aislar el JSON de un blob.
pub fn extractJsonArray(text: []const u8) []const u8 {
    if (scanBalanced(text, '[', ']')) |slice| return slice;
    if (scanBalanced(text, '{', '}')) |slice| return slice;
    return text;
}

/// contrato ÚNICO de parseo de artefactos del motor. De un blob (con
/// prosa, fences, o JSON puro) a una lista de `{path, content}`.
///
/// El bug de las tres copias era decidir el trozo por su forma textual: el primer
/// par balanceado podía ser una casilla `- [x]`, un enlace markdown `[texto](url)`
/// o un array ajeno, y el candidato correcto —más adelante— se perdía entero.
/// Aquí se prueban los candidatos EN ORDEN (arrays primero, luego objetos, luego
/// el texto entero) y gana el primero que parsea como contrato.
pub fn parseArtifacts(allocator: std.mem.Allocator, raw: []const u8) ParseError!std.ArrayList(Artifact) {
    // Se prueban los candidatos EN ORDEN hasta que uno parsea como contrato.
    // El primero ya no basta: `[x]` (casilla), `[texto](url)` (enlace markdown)
    // o un array ajeno en la prosa son candidatos textualmente válidos pero no
    // el contrato; antes se entregaba el primero y la respuesta buena se perdía.
    const pairs: [2][2]u8 = .{ .{ '[', ']' }, .{ '{', '}' } };
    for (pairs) |pair| {
        var cursor: usize = 0;
        while (scanBalancedFrom(raw, cursor, pair[0], pair[1])) |cand| {
            if (parseArtifactsJson(allocator, cand.slice)) |list| {
                return list;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidArtifact => {},
            }
            cursor = cand.end;
        }
    }
    // Último recurso (mismo contrato que la extracción textual previa): el texto
    // entero. Un blob sin corchetes válidos falla aquí con InvalidArtifact.
    return parseArtifactsJson(allocator, raw);
}

/// Parsea el JSON de artefactos YA AISLADO: espera un array de objetos
/// {field, content} (o un objeto suelto, que es UN artefacto). Usa std.json
/// (robusto ante escapes \n \" \uXXXX, anidamiento y contenido largo); el parser
/// hecho a mano previo fallaba con la salida real de los modelos. Si el JSON está
/// malformado o falta algún campo string, devuelve error.InvalidArtifact.
/// Era `worker_backend.parseLlmResponse`; aquí es el pivote del parser único.
pub fn parseArtifactsJson(allocator: std.mem.Allocator, raw: []const u8) ParseError!std.ArrayList(Artifact) {
    var list = std.ArrayList(Artifact).empty;
    errdefer {
        var j: usize = 0;
        while (j < list.items.len) : (j += 1) {
            list.items[j].deinit(allocator);
        }
        list.deinit(allocator);
    }

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    // Se acepta tambien `{`: un objeto suelto es el contrato de UN artefacto, y
    // exigir el array envolvente tiraba respuestas perfectas a la basura
    // (orden 148: 6.788 caracteres de tkinter validos clasificados `empty`).
    if (trimmed.len < 2 or (trimmed[0] != '[' and trimmed[0] != '{')) return error.InvalidArtifact;

    // Los modelos suelen emitir saltos de línea/tab LITERALES dentro de las strings
    // (código fuente multilínea), que el JSON estricto prohíbe. Se escapan antes de
    // parsear (no-op si el JSON ya es válido: no hay control chars crudos en strings).
    // Auditoría el segundo auditor lote 9 (hallazgo bajo): OutOfMemory NO es entrada inválida;
    // se propaga para que el worker no lo disfrace de respuesta vacía. Solo los
    // errores de entrada se convierten en InvalidArtifact.
    const sanitized = try escapeRawControlChars(allocator, trimmed);
    defer allocator.free(sanitized);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, sanitized, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArtifact,
    };
    defer parsed.deinit();

    // Un objeto suelto se normaliza a lista de un elemento en vez de rechazarse.
    var single: [1]std.json.Value = undefined;
    const items: []const std.json.Value = switch (parsed.value) {
        .array => |arr| blk: {
            if (arr.items.len == 0) return error.InvalidArtifact;
            break :blk arr.items;
        },
        .object => blk: {
            single[0] = parsed.value;
            break :blk single[0..1];
        },
        else => return error.InvalidArtifact,
    };
    for (items) |item| {
        if (item != .object) return error.InvalidArtifact;
        // el contrato canónico usa `field` (nombre) + `content`
        // (cuerpo), pero los modelos reales también nombran el destino con
        // `path`, `filename`, `file` o `name`. Rechazarlos tiraba a la basura
        // respuestas perfectas; eran la ruta del artefacto con otro nombre.
        const path_v = artifactPathValue(item.object) orelse
            return error.InvalidArtifact;
        const content_v = firstStringKey(item.object, &.{ "content", "code", "text", "source" }) orelse
            return error.InvalidArtifact;
        // Un objeto sin cuerpo (content vacío o solo espacios) no es un
        // artefacto entregable, SALVO que el propio nombre declare un archivo
        // que legítimamente puede estar vacío (`__init__.py`, `.gitkeep`,
        // `.keep`) o que su ruta sea una etiqueta de cuerpo (caso provisional
        // que `assignArtifactRoutes` decide con la tarea delante). En lo demás
        // se descarta en vez de contar como entrega vacía.
        if (std.mem.trim(u8, content_v, " \t\r\n").len == 0) {
            if (!canBeEmptyFileName(path_v) and !isBodyLabel(path_v)) continue;
        }

        const path = try allocator.dupe(u8, path_v);
        errdefer allocator.free(path);
        const cleaned = stripMarkdownFence(content_v);
        const body = try allocator.dupe(u8, cleaned);
        errdefer allocator.free(body);
        try list.append(allocator, .{ .path = path, .content = body });
    }

    // Si todos los objetos venían sin cuerpo, no queda artefacto: es un vacío.
    if (list.items.len == 0) return error.InvalidArtifact;

    return list;
}

/// primera clave de `keys` presente en el objeto cuyo valor sea una
/// cadena. El orden de `keys` fija la precedencia (p. ej. `path` antes que
/// `field` antes que `name`, para no confundir la clave del contrato con un
/// nombre genérico del modelo).
fn firstStringKey(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| {
        if (obj.get(k)) |v| {
            if (v == .string) return v.string;
        }
    }
    return null;
}

/// (auditoría, punto 3): entre los alias de ruta, prefiere el valor
/// que PARECE un nombre de archivo (extensión conocida o nombre conocido sin
/// extensión: `Dockerfile`, `Makefile`, `LICENSE`) sobre una etiqueta de cuerpo
/// (`source`, `code`…). Así `{"path":"source","filename":"index.html"}` se
/// entrega como `index.html`, no como `source`. Si ninguno parece nombre de
/// archivo, mantiene la precedencia canónica de `keys` para no cambiar el
/// comportamiento previo en los casos legítimos.
fn artifactPathValue(obj: std.json.ObjectMap) ?[]const u8 {
    const keys = [_][]const u8{ "path", "filename", "file", "field", "name" };
    var first: ?[]const u8 = null;
    for (keys) |k| {
        if (obj.get(k)) |v| {
            if (v != .string) continue;
            if (first == null) first = v.string;
            if (looksLikeFilename(v.string)) return v.string;
        }
    }
    return first;
}

/// B8: desvalla contenido envuelto en ```markdown ... ``` o ```...``` por el LLM
/// dentro del campo `content` de un artefacto. Si el contenido no tiene vallas
/// externas válidas, lo devuelve tal cual.
pub fn stripMarkdownFence(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");

    // (2026-08-15): la valla no siempre son TRES comillas invertidas.
    //
    // Orden #343, `script.js` de Cohere: el contenido llegó abriendo con UNA
    // sola comilla invertida en su propia línea y sin cerrarla. El archivo se
    // escribió tal cual, `node` lo rechazó con `SyntaxError: Unexpected end of
    // input`, la tarea falló y la orden entera acabó `failed` — con los tres
    // archivos en disco y el HTML y el CSS perfectos. El mismo patrón aparece
    // en la #334.
    //
    // Se trata aparte de la valla de B8 porque el caso REAL viene sin cierre:
    // el desvallado de tres comillas exige apertura Y cierre, así que este se
    // le colaba entero. Una comilla invertida sola en la primera línea no es
    // código válido en ningún lenguaje que este motor entregue; quitarla es
    // seguro y es lo único que separa un entregable roto de uno que corre.
    if (trimmed.len > 1 and trimmed[0] == '`' and !std.mem.startsWith(u8, trimmed, "```")) {
        const fin_linea = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return raw;
        const cabecera = std.mem.trim(u8, trimmed[1..fin_linea], " \t\r");
        // La primera línea debe ser la comilla sola o `<lenguaje>: nada más.
        // Si hay código detrás, no es una valla y no se toca.
        if (cabecera.len <= 12 and !std.mem.containsAtLeastScalar(u8, cabecera, 1, ' ')) {
            var cuerpo = trimmed[fin_linea + 1 ..];
            cuerpo = std.mem.trimEnd(u8, cuerpo, " \t\r\n");
            // Y si además cerró, se quita el cierre.
            if (cuerpo.len > 0 and cuerpo[cuerpo.len - 1] == '`') {
                cuerpo = std.mem.trimEnd(u8, cuerpo[0 .. cuerpo.len - 1], " \t\r\n");
            }
            if (cuerpo.len > 0) return cuerpo;
        }
        return raw;
    }

    if (!std.mem.startsWith(u8, trimmed, "```")) return raw;
    if (!std.mem.endsWith(u8, trimmed, "```")) return raw;
    if (trimmed.len < 6) return raw;

    const first_nl = std.mem.indexOfScalar(u8, trimmed[3..], '\n') orelse return raw;
    const body_start = 3 + first_nl + 1;
    const body_end = trimmed.len - 3;
    if (body_end < body_start) return raw;

    var slice = trimmed[body_start..body_end];
    if (slice.len > 0 and slice[slice.len - 1] == '\n') {
        slice = slice[0 .. slice.len - 1];
        if (slice.len > 0 and slice[slice.len - 1] == '\r') {
            slice = slice[0 .. slice.len - 1];
        }
    }
    return slice;
}

/// Etiqueta de CAMPO (cuerpo del entregable), no nombre de archivo. Espejo de
/// las listas de `workspace.findBodyArtifact` y `prose_artifact.isMetadataField`
/// para decidir si el `path` de un artefacto es en realidad el nombre del campo.
pub fn isBodyLabel(label: []const u8) bool {
    const names = [_][]const u8{
        "source",    "code",          "codigo",
        "código",
        "content",   "contenido",     "response",
        "respuesta", "answer",        "result",
        "resultado", "summary",       "resumen",
        "readme",    "documentation", "documentacion",
        "documentación",
        "markdown",  "document",      "documento",
        "doc",       "text",          "texto",
        "exit_code", "stdout",        "stderr",
        "html",      "css",           "javascript",
        "script",
    };
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(label, n)) return true;
    }
    return false;
}

/// Punto 4 (auditoría): nombres de archivo que LEGÍTIMAMENTE pueden entregarse
/// vacíos (marcadores de paquete o de directorio). Un cuerpo vacío solo se
/// acepta si el propio nombre lo declara como tal.
pub fn canBeEmptyFileName(name: []const u8) bool {
    const base = std.mem.trim(u8, basenameLocal(name), " \t\r\n");
    const names = [_][]const u8{ "__init__.py", ".gitkeep", ".keep" };
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(base, n)) return true;
    }
    return false;
}

pub fn basenameLocal(path: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' or path[i] == '\\') start = i + 1;
    }
    return path[start..];
}

/// Nombre con una extensión de archivo conocida (misma tabla que
/// `workspace.hasKnownCodeExtension`) o un nombre conocido SIN extensión
/// (`Dockerfile`, `Makefile`, `LICENSE`…). Distingue un nombre de archivo real
/// de una etiqueta de campo o de una palabra suelta.
pub fn looksLikeFilename(name: []const u8) bool {
    const base = basenameLocal(name);
    if (base.len == 0 or !std.mem.eql(u8, base, name)) return false;
    const ext = std.fs.path.extension(base);
    if (ext.len >= 2) {
        const known = [_][]const u8{
            ".py",  ".js",   ".mjs",  ".cjs", ".ts",   ".tsx",  ".jsx", ".html", ".htm",
            ".css", ".scss", ".json", ".zig", ".c",    ".h",    ".cpp", ".hpp",  ".cc",
            ".rs",  ".go",   ".java", ".cs",  ".rb",   ".php",  ".sh",  ".bat",  ".ps1",
            ".sql", ".md",   ".txt",  ".yml", ".yaml", ".toml", ".xml", ".svg",
        };
        for (known) |k| {
            if (std.ascii.eqlIgnoreCase(ext, k)) return true;
        }
    }
    // Nombres conocidos sin extensión (punto 3 de la auditoría). No son
    // etiquetas de cuerpo: son nombres de archivo reales.
    const named = [_][]const u8{
        "Dockerfile",     "Containerfile", "Makefile",    "GNUmakefile",
        "LICENSE",        "LICENCE",       "COPYING",     "Procfile",
        "Gemfile",        "Rakefile",      "Vagrantfile", "Justfile",
        "CMakeLists.txt", "__init__.py",   ".gitkeep",    ".keep",
        ".gitignore",
    };
    for (named) |n| {
        if (std.ascii.eqlIgnoreCase(base, n)) return true;
    }
    return false;
}

/// Escapa saltos de línea, retornos de carro y tabs LITERALES que aparezcan DENTRO de
/// una string JSON (los modelos los emiten al devolver código multilínea). Fuera de
/// strings no toca nada. Si el JSON ya es válido (sin control chars crudos), devuelve
/// una copia idéntica. No decodifica ni revalida — eso lo hace std.json después.
///
/// (campaña E3-T1): dentro de una string, una secuencia `\x` que NO es un
/// escape JSON válido ("\/bfnrtu) se escapa como `\\x` en vez de copiarse tal
/// cual. Los modelos escriben `\.` (regex), `\w`, `C:\` constantemente en el
/// `content` de los artefactos y el parser estricto de std.json rechazaba el
/// documento entero — medido: 19/19 órdenes reales fallaban con
/// `provider_failed status:empty` tras recibir cientos de bytes correctos
/// (orden 694: regex `\.` en 723 bytes → InvalidArtifact → order_failed).
/// excepcion `\'` → `'`, comilla simple sobreescapada que JSON no
/// necesita escapar. Los pares validos `\\` se consumen antes y se conservan.
pub fn escapeRawControlChars(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var in_string = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (in_string) {
            if (c == '\\') {
                if (i + 1 < raw.len) {
                    const n = raw[i + 1];
                    // escapes JSON válidos: " \ / b f n r t u — se copian tal cual
                    if (n == '"' or n == '\\' or n == '/' or n == 'b' or n == 'f' or
                        n == 'n' or n == 'r' or n == 't' or n == 'u')
                    {
                        try out.append(allocator, c);
                        try out.append(allocator, n);
                    } else if (n == '\'') {
                        // Sobreescape del modelo: conservarlo rompe JS como alert(\'hola\').
                        try out.append(allocator, n);
                    } else {
                        // `\x` inválido: es un backslash literal del modelo
                        try out.appendSlice(allocator, "\\\\");
                        try out.append(allocator, n);
                    }
                    i += 1;
                    continue;
                }
                // backslash suelto al final de la entrada: escaparlo también
                try out.appendSlice(allocator, "\\\\");
                continue;
            }
            switch (c) {
                '"' => {
                    in_string = false;
                    try out.append(allocator, c);
                },
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try out.append(allocator, c),
            }
        } else {
            if (c == '"') in_string = true;
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────

fn expectArtifacts(raw: []const u8, expected_paths: []const []const u8) !void {
    const allocator = std.testing.allocator;
    var artifacts = try parseArtifacts(allocator, raw);
    defer {
        for (artifacts.items) |*a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(expected_paths.len, artifacts.items.len);
    for (expected_paths, 0..) |path, i| {
        try std.testing.expectEqualStrings(path, artifacts.items[i].path);
    }
}

test "CK-MOT-014: la cerca ```json entre prosa se parsea (caso de live_worker)" {
    try expectArtifacts(
        \\Claro, aquí tienes el archivo:
        \\```json
        \\[{"field":"index.html","content":"<h1>Hola</h1>"}]
        \\```
    , &.{"index.html"});
}

test "CK-MOT-014: las casillas [x] de la prosa no rompen la extracción (el bug)" {
    // El caso del bug: la extracción por forma textual se queda con la primera
    // casilla `[x]`, parseLlmResponse la rechaza y la respuesta entera —que sí
    // trae los dos entregables— se clasifica `empty`.
    try expectArtifacts(
        \\He preparado los archivos:
        \\- [x] index.html
        \\- [ ] styles.css
        \\
        \\```json
        \\[{"field":"index.html","content":"<h1>Hola</h1>"},{"field":"styles.css","content":"body { margin: 0; }"}]
        \\```
    , &.{ "index.html", "styles.css" });
}

test "CK-MOT-014: un array ajeno en la prosa no descarta el contrato que viene después" {
    // `["--json", "-v"]` es JSON válido, pero no es el contrato (sus items no
    // son objetos): el parser debe seguir buscando en vez de rendirse.
    try expectArtifacts(
        \\Usa las banderas ["--json", "-v"] y luego entrega:
        \\[{"field":"a.txt","content":"uno"}]
    , &.{"a.txt"});
}

test "CK-MOT-014: JSON desnudo, array y objeto suelto (caso de worker_backend)" {
    try expectArtifacts(
        \\[{"field":"a.txt","content":"uno"},{"field":"b.txt","content":"dos"}]
    , &.{ "a.txt", "b.txt" });
    try expectArtifacts(
        \\{"field":"source.py","content":"print('hola')"}
    , &.{"source.py"});
}

test "CK-MOT-014: corchetes, llaves y comillas escapadas dentro de las cadenas" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"field":"source.py","content":"botones = [\"7\", \"8\", \"9\"]\nfila = botones[0]\nprint(\"x = {}\".format([1, 2]))"}
    ;
    var artifacts = try parseArtifacts(allocator, raw);
    defer {
        for (artifacts.items) |*a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("source.py", artifacts.items[0].path);
    try std.testing.expectEqualStrings(
        "botones = [\"7\", \"8\", \"9\"]\nfila = botones[0]\nprint(\"x = {}\".format([1, 2]))",
        artifacts.items[0].content,
    );
}

test "CK-MOT-014: vacío y basura se rechazan" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArtifact, parseArtifacts(allocator, ""));
    try std.testing.expectError(error.InvalidArtifact, parseArtifacts(allocator, "   \n\t "));
    try std.testing.expectError(error.InvalidArtifact, parseArtifacts(allocator, "nada"));
    try std.testing.expectError(error.InvalidArtifact, parseArtifacts(allocator, "[]"));
    try std.testing.expectError(error.InvalidArtifact, parseArtifacts(allocator, "```json\n```"));
}

test "CK-MOT-014: scanBalanced respeta strings y detecta truncado" {
    try std.testing.expect(scanBalanced("[{\"field\":\"a\",\"content\":\"x", '[', ']') == null);
    try std.testing.expect(scanBalanced("[{\"field\":\"a\",\"content\":\"x\"}]", '[', ']') != null);
    // Un ']' dentro de una string NO cierra el array.
    try std.testing.expect(scanBalanced("[\"]\"]", '[', ']') != null);
    try std.testing.expect(scanBalanced("[\"]\"", '[', ']') == null);
}

test "CK-MOT-014: extractJsonArray conserva su contrato textual" {
    try std.testing.expectEqualStrings(
        \\[{"field":"a","content":"b"}]
    , extractJsonArray(
        \\Claro, aquí tienes:
        \\```json
        \\[{"field":"a","content":"b"}]
        \\```
    ));
    // Sin corchetes: devuelve el texto tal cual (el parser lo rechazará).
    try std.testing.expectEqualStrings("nada", extractJsonArray("nada"));
}

// ── Tests r2 (auditoría el segundo auditor, lote 9) ──────────────────────

test "CK-MOT-014 r2: un corchete de apertura suelto en la prosa no descarta el JSON" {
    // Hallazgo medio (artifact_parser.zig:121): el `[` sin pareja de la prosa
    // se tragaba el array posterior y el parser perdía los artefactos. El
    // ejemplo exacto del hallazgo (un artefacto) debe seguir saliendo bien...
    try expectArtifacts(
        \\prosa [ sin cerrar
        \\[{"field":"a.txt","content":"x"}]
    , &.{"a.txt"});
    // ...y con dos artefactos el rescate por objeto solo entregaba el primero:
    // la respuesta se truncaba. Hay que recuperar el array completo.
    try expectArtifacts(
        \\prosa [ sin cerrar
        \\[{"field":"a.txt","content":"x"},{"field":"b.txt","content":"y"}]
    , &.{ "a.txt", "b.txt" });
}

test "CK-MOT-014 r2: dos corchetes de apertura sueltos en la prosa no descartan el JSON" {
    try expectArtifacts(
        \\prosa [ y otra [ suelta
        \\[{"field":"a.txt","content":"x"},{"field":"b.txt","content":"y"}]
    , &.{ "a.txt", "b.txt" });
}

test "CK-MOT-014 r2: todo fallo de asignación se propaga como OutOfMemory" {
    // Hallazgo bajo (artifact_parser.zig:161 y :164): los `catch` convertían
    // también OutOfMemory en InvalidArtifact. Se fuerza el fallo en CADA
    // asignación de una corrida limpia: todas deben salir como OutOfMemory
    // (nunca como InvalidArtifact), tanto por escapeRawControlChars como por
    // std.json.parseFromSlice.
    const base = std.testing.allocator;
    const raw = "[{\"field\":\"a.txt\",\"content\":\"x\"}]";

    var counter = std.testing.FailingAllocator.init(base, .{});
    {
        var ok = try parseArtifactsJson(counter.allocator(), raw);
        for (ok.items) |*a| a.deinit(counter.allocator());
        ok.deinit(counter.allocator());
    }
    try std.testing.expect(counter.alloc_index > 0);

    var index: usize = 0;
    while (index < counter.alloc_index) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = index });
        if (parseArtifactsJson(failing.allocator(), raw)) |list_value| {
            var list = list_value;
            for (list.items) |*a| a.deinit(failing.allocator());
            list.deinit(failing.allocator());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        var failing_lookup = std.testing.FailingAllocator.init(base, .{ .fail_index = index });
        try std.testing.expectError(error.OutOfMemory, parseArtifacts(failing_lookup.allocator(), raw));
    }
}
