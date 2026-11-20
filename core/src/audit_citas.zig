//! · parte de producto: las citas de un informe de auditoría se
//! comprueban leyendo el archivo, no se creen.
//!
//! El único informe completo de la campaña r4 (#739, 1588 eventos, lecturas
//! reales) se rechazó a mano porque sus `archivo:línea` apuntaban a código
//! distinto: `mcp_server.zig:87` era un bitmap PNG, `plugin_loader.zig:33` un
//! enum. El modelo SÍ leyó y aun así citó de memoria. Ninguna prueba lo veía:
//! el veredicto era un PASS bien formado.
//!
//! Aquí cada cita se abre con LA MISMA herramienta `read_file` que usó el
//! auditor (misma raíz, mismo sandbox), así que lo que el auditor pudo leer es
//! exactamente lo que se comprueba:
//!   - el archivo existe dentro de la raíz, y la línea existe en el archivo;
//!   - si la cita trae el texto citado entre comillas invertidas
//!     (`core/src/db.zig:48` `conn.exec(...)`), ese texto está de verdad en
//!     esa línea o a tres de distancia.
//! Una cita que no se sostiene invalida el informe entero: quien inventa una
//! referencia no ha demostrado haber leído las demás.

const std = @import("std");
const gte = @import("governed_tool_executor.zig");

pub const MAX_CITAS: usize = 64;
/// Tolerancia de líneas: los auditores cuentan desde la firma de la función
/// o desde el comentario de encima, y eso no es inventar.
pub const MARGEN_LINEAS: u32 = 3;
/// Tope de lectura por archivo, para no recorrer entero un volcado enorme.
const MAX_BYTES_ARCHIVO: usize = 4 * 1024 * 1024;

pub const Cita = struct {
    ruta: []const u8,
    linea: u32,
    /// Texto que el auditor dice que hay en esa línea, si lo dio.
    texto: ?[]const u8 = null,
};

pub const Motivo = enum { sin_archivo, fuera_de_rango, no_coincide };

pub const Resultado = struct {
    total: usize = 0,
    /// Con texto citado, y el texto está donde dice.
    verificadas: usize = 0,
    /// Sin texto citado: el archivo y la línea existen, y no se puede más.
    solo_existencia: usize = 0,
    fallidas: usize = 0,
    /// "ruta:línea (motivo); ..." de las fallidas, para el evento y el error.
    resumen: []u8 = &.{},

    pub fn deinit(self: *Resultado, allocator: std.mem.Allocator) void {
        if (self.resumen.len > 0) allocator.free(self.resumen);
        self.resumen = &.{};
    }
};

fn esCharDeRuta(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/' or c == '\\';
}

/// ¿El último segmento tiene una extensión de archivo (letras, no solo
/// números)? Descarta `127.0.0.1:9333`, horas y versiones.
fn tieneExtension(ruta: []const u8) bool {
    const sep = std.mem.lastIndexOfAny(u8, ruta, "/\\");
    const nombre = if (sep) |s| ruta[s + 1 ..] else ruta;
    const punto = std.mem.lastIndexOfScalar(u8, nombre, '.') orelse return false;
    if (punto == 0 and nombre.len < 3) return false;
    const ext = nombre[punto + 1 ..];
    if (ext.len == 0 or ext.len > 6) return false;
    var letras = false;
    for (ext) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
        if (std.ascii.isAlphabetic(c)) letras = true;
    }
    return letras;
}

/// Extrae las citas `ruta:línea` del informe. Devuelve cuántas escribió en
/// `out`, sin repetir la misma ruta y línea.
pub fn extraeCitas(texto: []const u8, out: []Cita) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < texto.len and n < out.len) : (i += 1) {
        if (texto[i] != ':' or i == 0 or i + 1 >= texto.len or !std.ascii.isDigit(texto[i + 1])) continue;
        // Hacia atrás: la ruta.
        var ini = i;
        while (ini > 0 and esCharDeRuta(texto[ini - 1])) ini -= 1;
        // Ruta absoluta de Windows: el «C:» de delante también es ruta.
        if (ini >= 2 and texto[ini - 1] == ':' and std.ascii.isAlphabetic(texto[ini - 2]) and
            (texto[ini] == '\\' or texto[ini] == '/') and (ini < 3 or !esCharDeRuta(texto[ini - 3])))
        {
            ini -= 2;
        }
        const ruta = std.mem.trimEnd(u8, texto[ini..i], ".");
        if (ruta.len < 3 or !tieneExtension(ruta)) continue;
        // Una URL no es una ruta del proyecto: se mira la palabra entera, que
        // en `http://host:3000/x.html:12` la ruta empezaría en «3000/».
        var palabra = ini;
        while (palabra > 0 and !std.ascii.isWhitespace(texto[palabra - 1]) and texto[palabra - 1] != '`' and texto[palabra - 1] != '(') palabra -= 1;
        if (std.mem.indexOf(u8, texto[palabra..i], "://") != null) continue;
        // Hacia delante: la línea (y un rango o columna que se ignoran).
        var j = i + 1;
        while (j < texto.len and std.ascii.isDigit(texto[j])) j += 1;
        if (j - (i + 1) > 7) continue;
        const linea = std.fmt.parseInt(u32, texto[i + 1 .. j], 10) catch continue;
        if (linea == 0) continue;
        if (j + 1 < texto.len and (texto[j] == '-' or texto[j] == ':') and std.ascii.isDigit(texto[j + 1])) {
            j += 1;
            while (j < texto.len and std.ascii.isDigit(texto[j])) j += 1;
        }
        // El texto citado: el primer tramo entre comillas invertidas o dobles
        // que sigue en la misma línea. Si la propia cita iba entre comillas,
        // la que la cierra no cuenta. (tanda 1): el auditor de la
        // orden 51 escribió `"docs/uno.txt:1":"UNO"` y, por mirar solo las
        // invertidas, la cita contó como «solo existencia».
        var k = j;
        if (k < texto.len and esComilla(texto[k]) and ini > 0 and texto[ini - 1] == texto[k]) k += 1;
        var cita_texto: ?[]const u8 = null;
        const tope = @min(texto.len, k + 80);
        var b = k;
        while (b < tope and texto[b] != '\n' and !esComilla(texto[b])) b += 1;
        if (b < tope and esComilla(texto[b])) {
            const cierre: [2]u8 = .{ texto[b], '\n' };
            if (std.mem.indexOfAnyPos(u8, texto, b + 1, &cierre)) |fin| {
                if (texto[fin] == texto[b]) {
                    const t = std.mem.trim(u8, texto[b + 1 .. fin], " \t");
                    if (t.len >= 3 and t.len <= 200) cita_texto = t;
                }
            }
        }
        var repetida = false;
        for (out[0..n]) |c| {
            if (c.linea == linea and std.mem.eql(u8, c.ruta, ruta)) repetida = true;
        }
        if (repetida) continue;
        out[n] = .{ .ruta = ruta, .linea = linea, .texto = cita_texto };
        n += 1;
        i = j;
    }
    return n;
}

fn esComilla(c: u8) bool {
    return c == '`' or c == '"';
}

/// Compara ignorando cuántos espacios o tabuladores hay entre palabras.
fn contieneSinEspacios(allocator: std.mem.Allocator, pajar: []const u8, aguja: []const u8) !bool {
    const p = try compacta(allocator, pajar);
    defer allocator.free(p);
    const a = try compacta(allocator, aguja);
    defer allocator.free(a);
    return a.len > 0 and std.mem.indexOf(u8, p, a) != null;
}

fn compacta(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len);
    var espacio = false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\r') {
            espacio = true;
            continue;
        }
        if (espacio and out.items.len > 0 and c != '\n') out.appendAssumeCapacity(' ');
        espacio = false;
        out.appendAssumeCapacity(c);
    }
    return out.toOwnedSlice(allocator);
}

/// Lee el archivo con la herramienta del auditor hasta cubrir `hasta_linea`.
/// null si la herramienta no lo sirve (no existe, fuera de la raíz, binario).
fn leeHasta(tool: *gte.GovernedToolExecutor, allocator: std.mem.Allocator, ruta: []const u8, hasta_linea: u32) !?[]u8 {
    var acumulado = std.ArrayList(u8).empty;
    defer acumulado.deinit(allocator);
    var offset: u64 = 0;
    while (acumulado.items.len < MAX_BYTES_ARCHIVO) {
        var args: std.Io.Writer.Allocating = .init(allocator);
        defer args.deinit();
        var js: std.json.Stringify = .{ .writer = &args.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("path");
        try js.write(ruta);
        try js.objectField("offset");
        try js.write(offset);
        try js.objectField("limit");
        try js.write(128 * 1024);
        try js.endObject();
        const resp = gte.GovernedToolExecutor.execute(tool, gte.READ_FILE_TOOL_NAME, args.written()) catch return null;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        if (parsed.value.object.get("error") != null) {
            if (acumulado.items.len == 0) return null;
            break;
        }
        const content = parsed.value.object.get("content") orelse return null;
        if (content != .string) return null;
        try acumulado.appendSlice(allocator, content.string);
        offset += content.string.len;
        const truncado = if (parsed.value.object.get("truncated")) |t| t == .bool and t.bool else false;
        if (!truncado or content.string.len == 0) break;
        if (std.mem.count(u8, acumulado.items, "\n") > hasta_linea) break;
    }
    return try allocator.dupe(u8, acumulado.items);
}

/// Comprueba las citas del informe contra los archivos bajo `raiz`.
pub fn verifica(allocator: std.mem.Allocator, raiz: []const u8, informe: []const u8) !Resultado {
    return verificaEnRaices(allocator, &.{raiz}, informe);
}

/// Como `verifica`, con varias raíces en orden de preferencia: la cita vale
/// contra la primera cuya herramienta de lectura sirve el archivo. Cada raíz
/// lleva su propio sandbox; ninguna amplía lo que otra deja leer.
pub fn verificaEnRaices(allocator: std.mem.Allocator, raices: []const []const u8, informe: []const u8) !Resultado {
    std.debug.assert(raices.len > 0 and raices.len <= 4);
    var citas: [MAX_CITAS]Cita = undefined;
    const n = extraeCitas(informe, &citas);
    var res = Resultado{ .total = n };
    if (n == 0) return res;

    var tools: [4]gte.GovernedToolExecutor = undefined;
    for (raices, 0..) |r, idx| tools[idx] = .{
        .policy = .{ .workspace_root = r },
        .plan_approved = true,
        .read_only = true,
        .allocator = allocator,
    };
    defer for (tools[0..raices.len]) |*t| {
        if (t.response) |r| allocator.free(r);
    };

    var resumen = std.ArrayList(u8).empty;
    errdefer resumen.deinit(allocator);

    for (citas[0..n]) |c| {
        const motivo: ?Motivo = blk: {
            const contenido = lectura: {
                for (tools[0..raices.len]) |*t| {
                    if (try leeHasta(t, allocator, c.ruta, c.linea + MARGEN_LINEAS)) |leido| break :lectura leido;
                }
                break :blk .sin_archivo;
            };
            defer allocator.free(contenido);
            // Líneas 1..N; la que se cita tiene que existir.
            var lineas = std.mem.splitScalar(u8, contenido, '\n');
            var num: u32 = 0;
            var ventana = std.ArrayList(u8).empty;
            defer ventana.deinit(allocator);
            const desde = if (c.linea > MARGEN_LINEAS) c.linea - MARGEN_LINEAS else 1;
            var existe = false;
            while (lineas.next()) |l| {
                num += 1;
                if (num == c.linea) existe = true;
                if (num >= desde and num <= c.linea + MARGEN_LINEAS) {
                    try ventana.appendSlice(allocator, l);
                    try ventana.append(allocator, '\n');
                }
                if (num > c.linea + MARGEN_LINEAS) break;
            }
            if (!existe) break :blk .fuera_de_rango;
            if (c.texto) |t| {
                if (!(try contieneSinEspacios(allocator, ventana.items, t))) break :blk .no_coincide;
                res.verificadas += 1;
            } else res.solo_existencia += 1;
            break :blk null;
        };
        if (motivo) |m| {
            res.fallidas += 1;
            if (resumen.items.len < 1500) {
                if (resumen.items.len > 0) try resumen.appendSlice(allocator, "; ");
                const txt = switch (m) {
                    .sin_archivo => "el archivo no existe en el proyecto",
                    .fuera_de_rango => "el archivo no tiene esa línea",
                    .no_coincide => "el texto citado no está en esa línea",
                };
                const linea = try std.fmt.allocPrint(allocator, "{s}:{d} ({s})", .{ c.ruta, c.linea, txt });
                defer allocator.free(linea);
                try resumen.appendSlice(allocator, linea);
            }
        }
    }
    res.resumen = try resumen.toOwnedSlice(allocator);
    return res;
}

/// FASE0-B2 (10-nov): citas de la tarea de una orden. Lo que escribe una
/// tarea despachada cae en `<raíz>\orden-<id>\` (persistTaskFiles), y el
/// auditor lo cita relativo a esa carpeta («saludo.txt:1»), no a la raíz del
/// worktree: medido en la pasada del 10-nov (hija 36), una subtarea correcta
/// quedaba «sin auditar» porque su cita se buscaba en la raíz. Cada cita se
/// prueba primero en la carpeta de la orden y después en la raíz; cada una con
/// su propio sandbox, así que una ruta que sale de la raíz sigue rechazada.
pub fn verificaDeOrden(allocator: std.mem.Allocator, raiz: []const u8, order_id: i64, informe: []const u8) !Resultado {
    if (order_id <= 0) return verifica(allocator, raiz, informe);
    const carpeta = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ std.mem.trimEnd(u8, raiz, "\\/"), order_id });
    defer allocator.free(carpeta);
    return verificaEnRaices(allocator, &.{ carpeta, raiz }, informe);
}

// ── Pruebas ──────────────────────────────────────────────────────────

test "extrae citas: relativas, absolutas, entre comillas, con y sin texto; no URLs ni IPs" {
    var out: [MAX_CITAS]Cita = undefined;
    const informe =
        \\B1 PASS: `core/src/db.zig:48` `conn.exec("PRAGMA busy_timeout = 5000")` fija el plazo.
        \\B2 FAIL: tools/mcp_server.zig:87 no valida nada.
        \\B3: ver C:\Workspace\x\proyecto\shell\host\main.cpp:201-210 `devArg`
        \\Ruido: http://localhost:3000/index.html:12 y 127.0.0.1:9333 a las 10:30, versión 0.16.0:1
        \\Repetida: core/src/db.zig:48
    ;
    const n = extraeCitas(informe, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("core/src/db.zig", out[0].ruta);
    try std.testing.expectEqual(@as(u32, 48), out[0].linea);
    try std.testing.expectEqualStrings("conn.exec(\"PRAGMA busy_timeout = 5000\")", out[0].texto.?);
    try std.testing.expectEqualStrings("tools/mcp_server.zig", out[1].ruta);
    try std.testing.expect(out[1].texto == null);
    try std.testing.expectEqualStrings("C:\\Workspace\\x\\proyecto\\shell\\host\\main.cpp", out[2].ruta);
    try std.testing.expectEqual(@as(u32, 201), out[2].linea);
    try std.testing.expectEqualStrings("devArg", out[2].texto.?);
}

test "E-102: una cita que apunta a otro código invalida el informe; las ciertas pasan" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "core/src");
    // Como la #739: mcp_server.zig:87 es un bitmap, no la validación citada.
    try tmp.dir.writeFile(io, .{ .sub_path = "core/src/mcp_server.zig", .data = "const a = 1;\n" ** 86 ++ "const PNG_BITMAP = [_]u8{ 0x89, 0x50 };\n" ++ "const b = 2;\n" ** 5 });
    try tmp.dir.writeFile(io, .{ .sub_path = "core/src/db.zig", .data = "// uno\n" ** 47 ++ "        conn.exec(\"PRAGMA busy_timeout = 5000\") catch {};\n" ++ "// fin\n" });
    var buf: [4096]u8 = undefined;
    const n_raiz = try tmp.dir.realPath(io, &buf);
    const raiz = buf[0..n_raiz];

    {
        var r = try verifica(a, raiz, "B1: core/src/db.zig:48 `conn.exec(\"PRAGMA busy_timeout = 5000\")` y core/src/db.zig:2 sin texto.");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 2), r.total);
        try std.testing.expectEqual(@as(usize, 1), r.verificadas);
        try std.testing.expectEqual(@as(usize, 1), r.solo_existencia);
        try std.testing.expectEqual(@as(usize, 0), r.fallidas);
    }
    {
        var r = try verifica(a, raiz,
            \\C1: core/src/mcp_server.zig:87 `if (!authed) return error.Unauthorized;` valida el token.
            \\C2: core/src/plugin_loader.zig:33 `pub fn load` carga sin firma.
            \\C3: core/src/db.zig:9000 cierra la conexión.
        );
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 3), r.total);
        try std.testing.expectEqual(@as(usize, 3), r.fallidas);
        try std.testing.expect(std.mem.indexOf(u8, r.resumen, "mcp_server.zig:87 (el texto citado no está en esa línea)") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.resumen, "plugin_loader.zig:33 (el archivo no existe en el proyecto)") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.resumen, "db.zig:9000 (el archivo no tiene esa línea)") != null);
    }
    {
        // El sandbox es el del auditor: fuera de la raíz no se sirve nada.
        var r = try verifica(a, raiz, "C4: ..\\..\\Windows\\win.ini:1 `[fonts]`");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), r.fallidas);
    }
}

test "E-102: el margen de tres líneas y los espacios distintos no son invención" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x.zig", .data = "/// doc\npub fn   suma(a: i32,  b: i32) i32 {\n    return a + b;\n}\n" });
    var buf: [4096]u8 = undefined;
    const n_raiz = try tmp.dir.realPath(io, &buf);
    var r = try verifica(a, buf[0..n_raiz], "x.zig:1 `pub fn suma(a: i32, b: i32) i32` y x.zig:4 `return a + b;`");
    defer r.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), r.verificadas);
    try std.testing.expectEqual(@as(usize, 0), r.fallidas);
}

test "CK-PUB-011: el texto citado entre comillas dobles se verifica por contenido" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/uno.txt", .data = "UNO\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/otro.txt", .data = "otra cosa\n" });
    var buf: [4096]u8 = undefined;
    const n_raiz = try tmp.dir.realPath(io, &buf);
    {
        // El informe real de la orden 51 (11-nov), literal.
        var r = try verifica(a, buf[0..n_raiz], "PASS - The file docs/uno.txt was created with the expected content 'UNO' on line 1. Citation: \"docs/uno.txt:1\":\"UNO\"");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), r.verificadas);
        try std.testing.expectEqual(@as(usize, 0), r.solo_existencia);
        try std.testing.expectEqual(@as(usize, 0), r.fallidas);
    }
    {
        // Comillas dobles tras una cita sin comillas, y un texto que no está.
        var r = try verifica(a, buf[0..n_raiz], "docs/uno.txt:1 \"UNO\"\ndocs/otro.txt:1 \"DOS\"");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), r.verificadas);
        try std.testing.expectEqual(@as(usize, 1), r.fallidas);
    }
}

test "FASE0-B2 citas en orden-<hija>: se resuelven en la carpeta de la orden y siguen sin salir de la raíz" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Worktree de la hija: el proyecto en la raíz y lo que escribió la hija
    // bajo `orden-36\` (persistTaskFiles), como en la pasada del 10-nov.
    try tmp.dir.createDirPath(io, "wt/orden-36");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/orden-36/saludo.txt", .data = "Hola, mundo.\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/README.md", .data = "# Proyecto\nlinea dos\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fuera.txt", .data = "secreto\n" });
    var buf: [4096]u8 = undefined;
    const n_tmp = try tmp.dir.realPath(io, &buf);
    var raiz_buf: [4096]u8 = undefined;
    const raiz = try std.fmt.bufPrint(&raiz_buf, "{s}" ++ std.fs.path.sep_str ++ "wt", .{buf[0..n_tmp]});

    {
        // La cita del auditor de la hija 36: relativa a su carpeta de orden.
        // Una cita por línea: el texto citado es el de su propia línea.
        var r = try verificaDeOrden(a, raiz, 36,
            \\PASS: saludo.txt:1 `Hola, mundo.`
            \\También orden-36/saludo.txt:1.
            \\Y README.md:2 `linea dos`
        );
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 3), r.total);
        try std.testing.expectEqual(@as(usize, 0), r.fallidas);
        try std.testing.expectEqual(@as(usize, 2), r.verificadas);
    }
    {
        // Lo que sale de la raíz de trabajo sigue rechazado, también desde la
        // carpeta de la orden; y una cita inventada sigue fallando.
        var r = try verificaDeOrden(a, raiz, 36, "FAIL: ..\\fuera.txt:1 `secreto` y ..\\..\\fuera.txt:1 y despedida.txt:1 y saludo.txt:7");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 4), r.total);
        try std.testing.expectEqual(@as(usize, 4), r.fallidas);
        try std.testing.expect(std.mem.indexOf(u8, r.resumen, "saludo.txt:7 (el archivo no tiene esa línea)") != null);
    }
    {
        // Otra orden no ve la carpeta de la 36 por el atajo.
        var r = try verificaDeOrden(a, raiz, 37, "saludo.txt:1");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), r.fallidas);
    }
}
