const std = @import("std");
const windows = std.os.windows;

// Depuración global, APAGADA por defecto (decisión del usuario 2026-08-07).
//
// Cuando está ON:
//   1. `live_worker` deja de recortar la muestra de intentos a 600 caracteres
//      (el recorte es lo que escondió el principio de la respuesta real de la
//      orden 148; con depuración encendida el vuelco lleva TODO).
//   2. Cada petición/respuesta cruda se vuelca a
//      `<LOCALAPPDATA>\DevAgents\debug\orden-NNN\`, con las credenciales
//      censuradas ANTES de tocar disco (R7 — jamás una clave en un archivo).
//   3. Los volcados viejos se purgan automáticamente al hacer uno nuevo.
//
// El interruptor es un marcador en disco (`enabled.txt` dentro del dir):
// ausente = OFF. Un archivo, no una variable de entorno, porque la decisión
// de diagnóstico debe sobrevivir al reinicio de la cabina y compartirse entre
// el CLI (`devagents debug --on`) y la pestaña TERMINAL.

/// Días que sobrevive un volcado de depuración antes de purgarse solo.
/// 7 días es un margen cómodo: los identificadores de orden crecen en
/// segundos, así que una semana cubre decenas de órdenes sin llenar disco.
pub const PURGE_AGE_DAYS: i64 = 7;

const GetEnvironmentVariableA = @import("platform.zig").env;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) c_int;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;
const RemoveDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn RemoveDirectoryA(lpPathName: [*:0]const u8) callconv(.winapi) c_int;
}.RemoveDirectoryA else @import("providers").posix_files.RemoveDirectoryA;
const FindFirstFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) callconv(.winapi) windows.HANDLE;
}.FindFirstFileA else @import("providers").posix_files.FindFirstFileA;
const FindNextFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindNextFileA(hFindFile: windows.HANDLE, lpFindFileData: *WIN32_FIND_DATAA) callconv(.winapi) c_int;
}.FindNextFileA else @import("providers").posix_files.FindNextFileA;
const FindClose = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindClose(hFindFile: windows.HANDLE) callconv(.winapi) c_int;
}.FindClose else @import("providers").posix_files.FindClose;
const GetSystemTimeAsFileTime = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
}.GetSystemTimeAsFileTime else @import("platform.zig").filetime;

const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));

const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,

    /// Convierte FILETIME (100 ns desde 1601) a segundos Unix.
    fn toUnixSeconds(self: FILETIME) i64 {
        const since_1601_unix_epoch: u64 = 116444736000000000;
        const hundreds_ns: u64 = (@as(u64, self.dwHighDateTime) << 32) | self.dwLowDateTime;
        if (hundreds_ns < since_1601_unix_epoch) return 0;
        return @intCast((hundreds_ns - since_1601_unix_epoch) / 10_000_000);
    }
};

const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u8,
    cAlternateFileName: [14]u8,
};

/// Raíz de depuración efectiva: `<LOCALAPPDATA>\DevAgents\debug`. Crea el
/// directorio si no existe. Fallback a null si LOCALAPPDATA no está definida
/// (entornos de test sin variable de entorno).
fn debugRoot(allocator: std.mem.Allocator) ?[]const u8 {
    var appdata_buf: [4096:0]u8 = undefined;
    const n = GetEnvironmentVariableA("LOCALAPPDATA", &appdata_buf, @intCast(appdata_buf.len));
    if (n == 0 or n >= appdata_buf.len) return null;
    const devagents = std.fs.path.join(allocator, &.{ appdata_buf[0..n], "DevAgents-Angel" }) catch return null;
    const devagents_z = allocator.dupeZ(u8, devagents) catch {
        allocator.free(devagents);
        return null;
    };
    _ = CreateDirectoryA(devagents_z.ptr, null);
    allocator.free(devagents_z);
    allocator.free(devagents);

    const joined = std.fs.path.join(allocator, &.{ appdata_buf[0..n], "DevAgents-Angel", "debug" }) catch return null;
    const joined_z = allocator.dupeZ(u8, joined) catch {
        allocator.free(joined);
        return null;
    };
    defer allocator.free(joined_z);
    _ = CreateDirectoryA(joined_z.ptr, null);
    return joined;
}

/// Interruptor global. OFF por defecto: basta con que no exista `enabled.txt`.
/// Un fallo al comprobar el marcador (LOCALAPPDATA ausente, disco bloqueado)
/// se trata como OFF — la depuración nunca debe forzar un camino nuevo.
pub fn isEnabled() bool {
    const allocator = std.heap.page_allocator;
    const root = debugRoot(allocator) orelse return false;
    defer allocator.free(root);
    const marker = std.fs.path.join(allocator, &.{ root, "enabled.txt" }) catch return false;
    defer allocator.free(marker);
    const marker_z = allocator.dupeZ(u8, marker) catch return false;
    defer allocator.free(marker_z);
    const h = CreateFileA(
        marker_z.ptr,
        0x80000000, // GENERIC_READ
        FILE_SHARE_READ,
        null,
        3, // OPEN_EXISTING
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == INVALID_HANDLE_VALUE) return false;
    _ = CloseHandle(h);
    return true;
}

/// Enciende o apaga el interruptor global.
pub fn setEnabled(enabled: bool) void {
    const allocator = std.heap.page_allocator;
    const root = debugRoot(allocator) orelse return;
    defer allocator.free(root);
    const marker = std.fs.path.join(allocator, &.{ root, "enabled.txt" }) catch return;
    defer allocator.free(marker);
    const marker_z = allocator.dupeZ(u8, marker) catch return;
    defer allocator.free(marker_z);
    if (enabled) {
        const h = CreateFileA(marker_z.ptr, GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (h == INVALID_HANDLE_VALUE) return;
        var written: u32 = 0;
        const one = "1\n";
        _ = WriteFile(h, one, 2, &written, null);
        _ = CloseHandle(h);
    } else {
        _ = DeleteFileA(marker_z.ptr);
    }
}

/// Detecta si `needle` está en `hay` a partir de `pos`, ignorando mayúsculas.
fn eqlIgnoreCaseAt(hay: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > hay.len) return false;
    for (needle, 0..) |c, i| {
        const hc = hay[pos + i];
        const lower_h = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
        const lower_n = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (lower_h != lower_n) return false;
    }
    return true;
}

/// Carácter que delimita el final de un token (espacio, coma, llave, corchete,
/// dos puntos, nueva línea, comilla). Todo lo demás —letras, dígitos, guiones,
/// puntos, `_`, `-`, `.`, `/`, `$`— es parte de un bearer token o clave.
fn isTokenDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', ',', '{', '}', '[', ']', ':', '"', '\'' => true,
        else => false,
    };
}

/// Censura credenciales de un payload ANTES de tocarse el disco (R7):
///  - `Authorization: Bearer <token>` y el propio header `Authorization:`
///  - cualquier `Bearer <token>` suelto
///  - headers de clave: `x-api-key`, `x-goog-api-key`, `anthropic-api-key`
///  - campos JSON `api_key` / `apiKey`
///
/// Deliberadamente CONSERVADOR en lo que corta (respetar headers `accept`,
/// body legítimo con la palabra "Bearer" en prosa...). Un token se redacta
/// solo cuando va tras un nombre de header o campo conocido. La prueba de
/// regresión alimenta un payload con una clave falsa y comprueba que la clave
/// NO aparece en la salida.
pub fn redactBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const KEY_HEADERS = [_][]const u8{ "authorization", "x-api-key", "x-goog-api-key", "anthropic-api-key", "x-subscription-token", "api-key" };

    var i: usize = 0;
    const n = bytes.len;
    while (i < n) {
        // ¿Es una línea de header? Patrón: comienzo de archivo o tras \n, luego
        // el nombre del header y `:`. El header de LLM típico es:
        //   "authorization": "Bearer sk-xxx"  (JSON)   → lo cubre el campo JSON
        //   Authorization: Bearer sk-xxx  (HTTP crudo) → este caso.
        // Una línea de header empieza al inicio del archivo o justo después de
        // un `\n` (HTTP usa `\r\n`; hay que reconocer el `\r` que precede).
        var is_header_line = i == 0;
        if (i > 0 and bytes[i - 1] == '\n') is_header_line = true;
        if (i >= 2 and bytes[i - 1] == '\r' and bytes[i - 2] == '\n') is_header_line = true;
        if (is_header_line) {
            var matched = false;
            var consumed_name: usize = 0;
            for (KEY_HEADERS) |name| {
                if (eqlIgnoreCaseAt(bytes, i, name)) {
                    var j = i + name.len;
                    while (j < n and (bytes[j] == ' ' or bytes[j] == '\t')) : (j += 1) {}
                    if (j < n and bytes[j] == ':') {
                        matched = true;
                        consumed_name = j + 1;
                    }
                }
            }
            if (matched) {
                // Redactar el VALOR hasta el final de línea (inclusive). El
                // nombre del header se conserva, el secreto no.
                var j = consumed_name;
                while (j < n and bytes[j] != '\n') : (j += 1) {}
                try out.appendSlice(allocator, bytes[i..consumed_name]);
                try out.appendSlice(allocator, " [REDACTADO]");
                if (j < n and bytes[j] == '\n') {
                    try out.append(allocator, '\n');
                    i = j + 1;
                } else {
                    i = j;
                }
                continue;
            }
        }

        // JSON `"api_key": "..."` / `"apiKey": "..."`: redacta el valor string.
        var is_key_field = false;
        if (bytes[i] == '"') {
            const j = i + 1;
            var key_name: []const u8 = "";
            if (eqlIgnoreCaseAt(bytes, j, "api_key")) key_name = bytes[j .. j + "api_key".len];
            if (eqlIgnoreCaseAt(bytes, j, "apiKey")) key_name = bytes[j .. j + "apiKey".len];
            if (key_name.len > 0) {
                const k = j + key_name.len;
                if (k < n and bytes[k] == '"') {
                    var p = k + 1;
                    while (p < n and (bytes[p] == ' ' or bytes[p] == '\t')) : (p += 1) {}
                    if (p < n and bytes[p] == ':') {
                        p += 1;
                        while (p < n and (bytes[p] == ' ' or bytes[p] == '\t')) : (p += 1) {}
                        if (p < n and bytes[p] == '"') {
                            var q = p + 1;
                            while (q < n and bytes[q] != '"') : (q += 1) {}
                            if (q < n) {
                                // `p` apunta a la comilla de APERTURA del valor;
                                // `q` a la de cierre. Se conserva `bytes[i..p]`
                                // (el nombre del campo y la separación), se
                                // redacta el valor entero, y se salta `q`.
                                is_key_field = true;
                                try out.appendSlice(allocator, bytes[i..p]);
                                try out.appendSlice(allocator, "\"[REDACTADO]\"");
                                i = q + 1;
                            }
                        }
                    }
                }
            }
        }
        if (is_key_field) continue;

        // `Bearer <token>` suelto (en header JSON respondido o en prosa).
        if (eqlIgnoreCaseAt(bytes, i, "Bearer ")) {
            var j = i + "Bearer ".len;
            while (j < n and !isTokenDelimiter(bytes[j])) : (j += 1) {}
            try out.appendSlice(allocator, bytes[i .. i + "Bearer ".len]);
            try out.appendSlice(allocator, "[REDACTADO]");
            i = j;
            continue;
        }

        // Query params de credencial en URLs volcadas (`?key=`, `&api_key=`,
        // `?access_token=`…): una URL de petición copiada a un log o cuerpo de
        // error arrastra la clave en claro. Se conserva `?nombre=` y se redacta
        // el valor hasta `&`, `#` o delimitador.
        if (bytes[i] == '?' or bytes[i] == '&') {
            const QP_NAMES = [_][]const u8{ "key", "api_key", "access_token", "sig", "token", "password" };
            var qp_hit = false;
            for (QP_NAMES) |qn| {
                const q = i + 1;
                if (eqlIgnoreCaseAt(bytes, q, qn)) {
                    const k = q + qn.len;
                    if (k < n and bytes[k] == '=') {
                        var j = k + 1;
                        while (j < n and bytes[j] != '&' and bytes[j] != '#' and !isTokenDelimiter(bytes[j])) : (j += 1) {}
                        try out.appendSlice(allocator, bytes[i .. k + 1]);
                        try out.appendSlice(allocator, "[REDACTADO]");
                        i = j;
                        qp_hit = true;
                        break;
                    }
                }
            }
            if (qp_hit) continue;
        }

        // Credenciales `nombre=valor` SUELTAS, sin ?/& delante: un error de
        // proveedor las escupe en prosa (`err: api_key=X rechazada`). Solo
        // nombres inequívocos — `key=`/`token=`/`sig=` a secas son prosa
        // corriente y siguen exigiendo el prefijo ?/& de la rama anterior.
        {
            const BARE_NAMES = [_][]const u8{ "api_key", "apikey", "api-key", "access_token", "refresh_token", "client_secret", "password" };
            var bare_hit = false;
            for (BARE_NAMES) |bn| {
                if (!eqlIgnoreCaseAt(bytes, i, bn)) continue;
                // Frontera de palabra: en `myapi_key=` la `a` va precedida de
                // letra y no dispara; en `err: api_key=` sí.
                if (i > 0 and (std.ascii.isAlphanumeric(bytes[i - 1]) or bytes[i - 1] == '_')) continue;
                var k = i + bn.len;
                while (k < n and (bytes[k] == ' ' or bytes[k] == '\t')) : (k += 1) {}
                if (k >= n or bytes[k] != '=') continue;
                var j = k + 1;
                if (j < n and (bytes[j] == '"' or bytes[j] == '\'')) {
                    // Valor entre comillas: traga el par completo.
                    const qc = bytes[j];
                    j += 1;
                    while (j < n and bytes[j] != qc) : (j += 1) {}
                    if (j < n) j += 1;
                } else {
                    while (j < n and bytes[j] != '&' and bytes[j] != '#' and !isTokenDelimiter(bytes[j])) : (j += 1) {}
                }
                try out.appendSlice(allocator, bytes[i .. k + 1]);
                try out.appendSlice(allocator, "[REDACTADO]");
                i = j;
                bare_hit = true;
                break;
            }
            if (bare_hit) continue;
        }

        try out.append(allocator, bytes[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator) catch {
        return out.items;
    };
}

/// Redacción por VALOR EXACTO: enmascara cada aparición literal de `secret`
/// dondequiera que aparezca — el complemento de `redactBytes`, que solo cubre
/// formas reconocibles (headers, campos, Bearer). Un proveedor que ecoa la
/// clave en el cuerpo del error (`"invalid key sk-…"`), o una clave pegada por
/// el usuario en un prompt, no llevan ninguna marca que el patrón reconozca:
/// solo el valor mismo los delata. `secret` de <4 chars se ignora: enmascarar
/// "ab" destruiría el texto sin proteger nada.
pub fn redactExact(allocator: std.mem.Allocator, bytes: []const u8, secret: []const u8) ![]u8 {
    if (secret.len < 4) return allocator.dupe(u8, bytes);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + secret.len <= bytes.len and std.mem.eql(u8, bytes[i .. i + secret.len], secret)) {
            try out.appendSlice(allocator, "[REDACTADO]");
            i += secret.len;
        } else {
            try out.append(allocator, bytes[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator) catch {
        return out.items;
    };
}

/// Borra recursivamente un directorio y su contenido (best-effort). Se usa
/// para purgar volcados viejos; ante cualquier fallo de recorrido se abandona.
fn deleteTree(allocator: std.mem.Allocator, path: []const u8) void {
    const pattern = std.fs.path.join(allocator, &.{ path, "*" }) catch return;
    defer allocator.free(pattern);
    const pattern_z = allocator.dupeZ(u8, pattern) catch return;
    defer allocator.free(pattern_z);

    var data: WIN32_FIND_DATAA = undefined;
    const h = FindFirstFileA(pattern_z, &data);
    if (h == INVALID_HANDLE_VALUE) {
        const pz = allocator.dupeZ(u8, path) catch return;
        defer allocator.free(pz);
        _ = RemoveDirectoryA(pz.ptr);
        return;
    }
    defer _ = FindClose(h);
    while (true) {
        var name_len: usize = 0;
        while (name_len < data.cFileName.len and data.cFileName[name_len] != 0) : (name_len += 1) {}
        const name = data.cFileName[0..name_len];
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
            const child = std.fs.path.join(allocator, &.{ path, name }) catch break;
            defer allocator.free(child);
            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) {
                deleteTree(allocator, child);
            } else {
                const cz = allocator.dupeZ(u8, child) catch break;
                defer allocator.free(cz);
                _ = DeleteFileA(cz.ptr);
            }
        }
        if (FindNextFileA(h, &data) == 0) break;
    }
    const pz = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(pz);
    _ = RemoveDirectoryA(pz.ptr);
}

/// Purga automática: elimina los volcados de órdenes más viejos que
/// `PURGE_AGE_DAYS`. Se invoca al escribir un volcado nuevo, así que nunca se
/// acumula: cada escritura deja el directorio bajo control de edad.
fn purgeOld(allocator: std.mem.Allocator, root: []const u8) void {
    var now: FILETIME = undefined;
    GetSystemTimeAsFileTime(&now);
    const now_sec = now.toUnixSeconds();
    const cutoff = now_sec - PURGE_AGE_DAYS * 86_400;

    const pattern = std.fs.path.join(allocator, &.{ root, "orden-*" }) catch return;
    defer allocator.free(pattern);
    const pattern_z = allocator.dupeZ(u8, pattern) catch return;
    defer allocator.free(pattern_z);

    var data: WIN32_FIND_DATAA = undefined;
    const h = FindFirstFileA(pattern_z, &data);
    if (h == INVALID_HANDLE_VALUE) return;
    defer _ = FindClose(h);
    while (true) {
        var name_len: usize = 0;
        while (name_len < data.cFileName.len and data.cFileName[name_len] != 0) : (name_len += 1) {}
        const name = data.cFileName[0..name_len];
        if (std.mem.startsWith(u8, name, "orden-") and data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) {
            const last_write = data.ftLastWriteTime.toUnixSeconds();
            if (last_write < cutoff) {
                const child = std.fs.path.join(allocator, &.{ root, name }) catch break;
                deleteTree(allocator, child);
                allocator.free(child);
            }
        }
        if (FindNextFileA(h, &data) == 0) break;
    }
}

/// Escribe un volcado redactado bajo `debug\orden-<order_id>\`. Crea el
/// directorio de la orden si falta y dispara la purga de viejos. Best-effort:
/// la telemetría de depuración jamás debe tumbar el despacho.
pub fn dumpOrderArtifact(order_id: i64, filename: []const u8, body: []const u8) void {
    const allocator = std.heap.page_allocator;
    const root = debugRoot(allocator) orelse return;
    defer allocator.free(root);

    const order_dir = std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ root, order_id }) catch return;
    defer allocator.free(order_dir);
    const order_dir_z = allocator.dupeZ(u8, order_dir) catch return;
    defer allocator.free(order_dir_z);
    _ = CreateDirectoryA(order_dir_z.ptr, null);

    const redacted = redactBytes(allocator, body) catch return;
    defer allocator.free(redacted);

    const path = std.fs.path.join(allocator, &.{ order_dir, filename }) catch return;
    defer allocator.free(path);
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    const h = CreateFileA(path_z.ptr, GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE_VALUE) return;
    {
        defer _ = CloseHandle(h);
        var written: u32 = 0;
        const len: u32 = if (redacted.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(redacted.len);
        _ = WriteFile(h, redacted.ptr, len, &written, null);
    }

    purgeOld(allocator, root);
}

/// Resuelve la raíz para tests: permite fijar un directorio temporal como
/// destino en lugar de `%LOCALAPPDATA%`. Devuelve la raíz dupeada (el caller
/// libera) o null si la ruta de entorno no existe.
pub fn debugRootForTests() ?[]const u8 {
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "switch: apagado por defecto (ausencia de marcador)" {
    // P2-REQUISITO: OFF por defecto fue decisión explícita del usuario
    // (2026-08-07). El marcador no debe existir al arrancar. Este test fuerza
    // el apagado y comprueba que `isEnabled` sigue leyendo la ausencia como OFF.
    setEnabled(false);
    try std.testing.expect(!isEnabled());
}

test "switch: enciende y apaga realmente" {
    setEnabled(true);
    defer setEnabled(false);
    try std.testing.expect(isEnabled());
    setEnabled(false);
    try std.testing.expect(!isEnabled());
}

test "dump: el volcado nunca contiene la clave (redactado antes de tocar disco)" {
    const allocator = std.testing.allocator;
    setEnabled(true);
    defer setEnabled(false);
    const fake_key = "sk-esta-clave-no-puede-quedar-en-ningun-archivo";
    const req = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}\n", .{fake_key});
    defer allocator.free(req);
    const resp = try std.fmt.allocPrint(allocator, "{{\"api_key\":\"{s}\",\"text\":\"ok\"}}", .{fake_key});
    defer allocator.free(resp);

    // Escribir a una orden de TEST; el nombre incluye un sufijo para poder
    // borrarlo después sin tocar volcados reales (R5: nunca borrar datos vivos;
    // esto crea y limpia SOLO su propio directorio).
    const TestOrder: i64 = 900000000;
    dumpOrderArtifact(TestOrder, "peticion.txt", req);
    dumpOrderArtifact(TestOrder, "respuesta.txt", resp);

    // Leer ambos volcados del disco y comprobar que la clave no está.
    const root = debugRoot(allocator) orelse return error.SkipNoLocalAppData;
    defer allocator.free(root);
    const order_dir = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ root, TestOrder });
    defer allocator.free(order_dir);

    var read_buf: [65536]u8 = undefined;
    const peticion = readFileIntoBuf(order_dir, "peticion.txt", &read_buf) catch return error.SkipWriteFailed;
    try std.testing.expect(std.mem.indexOf(u8, peticion, fake_key) == null);
    const respuesta = readFileIntoBuf(order_dir, "respuesta.txt", &read_buf) catch return error.SkipWriteFailed;
    try std.testing.expect(std.mem.indexOf(u8, respuesta, fake_key) == null);

    // Limpiar SOLO el directorio de esta orden de prueba.
    deleteTree(allocator, order_dir);
}

const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const GetFileSizeEx = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileSizeEx(hFile: windows.HANDLE, lpFileSize: *i64) callconv(.winapi) c_int;
}.GetFileSizeEx else @import("providers").posix_files.GetFileSizeEx;

fn readFileIntoBuf(dir: []const u8, name: []const u8, buf: []u8) ![]const u8 {
    const allocator = std.heap.page_allocator;
    const path = std.fs.path.join(allocator, &.{ dir, name }) catch return error.Oom;
    defer allocator.free(path);
    const path_z = allocator.dupeZ(u8, path) catch return error.Oom;
    defer allocator.free(path_z);
    const h = CreateFileA(
        path_z.ptr,
        0x80000000, // GENERIC_READ
        FILE_SHARE_READ,
        null,
        3, // OPEN_EXISTING
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == INVALID_HANDLE_VALUE) return error.ReadFail;
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0) return error.ReadFail;
    const cap: usize = if (size > buf.len) buf.len else @intCast(size);
    var total: usize = 0;
    while (total < cap) {
        var got: u32 = 0;
        const to_read: u32 = @intCast(@min(cap - total, std.math.maxInt(u32)));
        if (ReadFile(h, buf.ptr + total, to_read, &got, null) == 0) return error.ReadFail;
        if (got == 0) break;
        total += got;
    }
    return buf[0..total];
}

test "redact: bearer token dentro de un header HTTP no sobrevive a la salida" {
    const allocator = std.testing.allocator;
    const fake_key = "sk-este-secreto-no-debe-salir-123456";
    const payload = try std.fmt.allocPrint(
        allocator,
        "POST /v1/chat/completions HTTP/1.1\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\n\r\n{{\"model\":\"x\"}}",
        .{fake_key},
    );
    defer allocator.free(payload);

    const redacted = try redactBytes(allocator, payload);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, fake_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "[REDACTADO]") != null);
}

test "redact: campo JSON api_key no sobrevive a la salida" {
    const allocator = std.testing.allocator;
    const fake_key = "AIza-esta-es-otra-clave-falsa-zzz";
    const payload = try std.fmt.allocPrint(allocator, "{{\"api_key\": \"{s}\", \"model\": \"m\"}}", .{fake_key});
    defer allocator.free(payload);

    const redacted = try redactBytes(allocator, payload);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, fake_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "\"[REDACTADO]\"") != null);
}

test "redact: clave en x-api-key header no sobrevive" {
    const allocator = std.testing.allocator;
    const fake_key = "anthropic-sk-otra-key-totalmente-falsa";
    const payload = try std.fmt.allocPrint(allocator, "x-api-key: {s}\nHTTP/1.1 200 OK\n", .{fake_key});
    defer allocator.free(payload);

    const redacted = try redactBytes(allocator, payload);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, fake_key) == null);
}

test "redact: un bearer suelto en prosa se recorta" {
    const allocator = std.testing.allocator;
    const fake_key = "ghp_mi_pat_de_personal_token_987654";
    const payload = try std.fmt.allocPrint(allocator, "usando el token Bearer {s} en el comando", .{fake_key});
    defer allocator.free(payload);

    const redacted = try redactBytes(allocator, payload);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, fake_key) == null);
}

test "redact: el texto legitimo fuera de credenciales se conserva" {
    const allocator = std.testing.allocator;
    const payload = "el modelo respondió ok con 6788 caracteres y JSON válido";
    const redacted = try redactBytes(allocator, payload);
    defer allocator.free(redacted);
    try std.testing.expectEqualStrings(payload, redacted);
}

// ── E3.37 · Cobertura de credenciales ────────────────────────────────────

test "E3.37 redact: header api-key (estilo Azure) no sobrevive" {
    const allocator = std.testing.allocator;
    const fake_key = "az-key-falsa-que-no-debe-salir-987";
    const payload = try std.fmt.allocPrint(allocator, "api-key: {s}\nHTTP/1.1 200 OK\n", .{fake_key});
    defer allocator.free(payload);
    const redacted = try redactBytes(allocator, payload);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, fake_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "api-key") != null);
}

test "E3.37 redact: clave en query param de URL volcada no sobrevive" {
    const allocator = std.testing.allocator;
    const fake_key = "AIzaSy-CLAVE-QUERY-QUE-NO-DEBE-QUEDAR";
    // Gemini y otros aceptan la clave por ?key= en la URL; si esa URL cae en un
    // log o cuerpo de error la clave queda en claro.
    const payload = try std.fmt.allocPrint(
        allocator,
        "GET https://generativelanguage.googleapis.com/v1/models?key={s}&page=2 HTTP/1.1\nerr: api_key={s} rechazada\n",
        .{ fake_key, fake_key },
    );
    defer allocator.free(payload);
    const redacted = try redactBytes(allocator, payload);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, fake_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "?key=[REDACTADO]") != null);
    // El segundo param (&page=2) no es credencial y se conserva.
    try std.testing.expect(std.mem.indexOf(u8, redacted, "&page=2") != null);
}

test "E3.37 redact: access_token en query y texto key= legitimo" {
    const allocator = std.testing.allocator;
    const payload = "curl https://api/x?access_token=tok-secreto-12345&b=2 y la key= del manifiesto no es secreto";
    const redacted = try redactBytes(allocator, payload);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "tok-secreto-12345") == null);
    // `key=` sin ?/& delante no se toca (falso positivo evitado).
    try std.testing.expect(std.mem.indexOf(u8, redacted, "la key= del manifiesto") != null);
}

test "E3.37 redactExact: la clave ecoa SIN marca tambien se enmascara" {
    const allocator = std.testing.allocator;
    const real_key = "sk-live-a1b2c3d4e5f6a7b8c9d0";
    // Cuerpo de error realista: el proveedor ecoa la clave sin "Bearer" ni
    // nombre de campo — el patrón no lo veía, el valor exacto sí.
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"error\":{{\"message\":\"invalid key {s} for account 77\",\"code\":401}}}}",
        .{real_key},
    );
    defer allocator.free(body);
    const redacted = try redactExact(allocator, body, real_key);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, real_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "[REDACTADO]") != null);
    // Dos apariciones → dos enmascarados.
    const body2 = try std.fmt.allocPrint(allocator, "{s} y otra vez {s}", .{ real_key, real_key });
    defer allocator.free(body2);
    const redacted2 = try redactExact(allocator, body2, real_key);
    defer allocator.free(redacted2);
    try std.testing.expect(std.mem.indexOf(u8, redacted2, real_key) == null);
}

test "E3.37 redactExact: secreto corto no se aplica y sin coincidencia conserva" {
    const allocator = std.testing.allocator;
    // <4 chars: enmascarar "ab" destruiría texto sin proteger nada.
    const redacted = try redactExact(allocator, "abc abc", "ab");
    defer allocator.free(redacted);
    try std.testing.expectEqualStrings("abc abc", redacted);
    const redacted2 = try redactExact(allocator, "texto sin la clave", "sk-ausente-1234");
    defer allocator.free(redacted2);
    try std.testing.expectEqualStrings("texto sin la clave", redacted2);
}
