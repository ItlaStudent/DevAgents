//! SEMANTIC-GATE-T3 — capa de verificación de intención SOBRE el gate de
//! ejecución existente (no lo reemplaza).
//!
//! El gate de ejecución demuestra que las tareas corrieron y produjeron
//! artefactos íntegros; no demuestra que el resultado sea lo que la orden
//! pedía (falso verde C1: una calculadora que devuelve 999 para 6+3 pasaba
//! el gate de alcance). Esta capa evalúa un OBSERVABLE DECLARADO — campo
//! `orders.expected_result` o contract field `expects` del plan — con
//! comprobaciones deterministas: un PASS exige que lo declarado se cumpla
//! de verdad y un FAIL reporta la diferencia concreta (esperado vs. real).
//!
//! Nada aquí llama a un modelo: las aserciones son mecánicas (existe el
//! archivo, contiene el literal, la salida registrada contiene el literal).
//! Declaraciones soportadas (array JSON):
//!
//!   {"kind":"file_exists","path":"index.html"}
//!   {"kind":"file_contains","path":"index.html","needle":"HOLA"}
//!   {"kind":"file_not_contains","path":"index.html","needle":"TODO"}
//!   {"kind":"output_contains","task_id":"t2","needle":"9"}   (task_id opcional)

const std = @import("std");
const prose_artifact = @import("prose_artifact.zig");

/// Trusted inventory from the dispatcher, independent of model assertions.
pub const ProseEvidence = struct {
    path: []const u8,
    description: []const u8,
    task_id: []const u8,
};

pub const Kind = enum {
    file_exists,
    file_contains,
    file_not_contains,
    output_contains,

    pub fn fromText(s: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Kind, f.name);
        }
        return null;
    }
};

pub const Assertion = struct {
    kind: Kind,
    /// Ruta relativa al directorio de la orden (file_*).
    path: []const u8 = "",
    /// Literal esperado (file_contains / file_not_contains / output_contains).
    needle: []const u8 = "",
    /// Tarea cuya salida registrada se inspecciona (output_contains; vacío =
    /// todas las salidas registradas de la orden concatenadas).
    task_id: []const u8 = "",

    pub fn deinit(self: Assertion, a: std.mem.Allocator) void {
        a.free(self.path);
        a.free(self.needle);
        a.free(self.task_id);
    }
};

/// Salida real registrada por una tarea durante la ejecución (stdout).
pub const OutputEvidence = struct {
    task_id: []const u8,
    stdout: []const u8,
};

pub const Check = struct {
    assertion: Assertion,
    ok: bool,
    /// Lo observado de verdad (extracto acotado), para el diff honesto.
    actual: []const u8,
    /// Texto de la diferencia cuando !ok (vacío si ok).
    difference: []const u8,
};

pub const Verdict = enum { pass, fail };

pub const Result = struct {
    /// false cuando no había aserciones que evaluar (nada declarado).
    ran: bool,
    verdict: Verdict,
    checks: []Check,
    /// Diferencias unidas en un solo texto (vacío si pass).
    differences_text: []const u8,

    pub fn deinit(self: *Result, a: std.mem.Allocator) void {
        for (self.checks) |c| {
            c.assertion.deinit(a);
            a.free(c.actual);
            a.free(c.difference);
        }
        a.free(self.checks);
        a.free(self.differences_text);
    }
};

const MAX_ASSERTION_TEXT = 4096;
const MAX_ACTUAL_SNIPPET = 200;

/// Parsea un array JSON de aserciones. Falla si el JSON no es un array, si un
/// elemento no es objeto, si `kind` es desconocido o si falta el campo que el
/// kind exige (path en file_*, needle en *_contains).
pub fn parseAssertions(a: std.mem.Allocator, json_str: []const u8) ![]Assertion {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_str, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidJson;

    var list = std.ArrayList(Assertion).empty;
    errdefer {
        for (list.items) |as| as.deinit(a);
        list.deinit(a);
    }
    for (parsed.value.array.items) |item| {
        if (item != .object) return error.InvalidJson;
        const o = item.object;
        const kind_v = o.get("kind") orelse return error.InvalidJson;
        if (kind_v != .string) return error.InvalidJson;
        const kind = Kind.fromText(kind_v.string) orelse return error.InvalidJson;

        const path = try jsonText(a, o.get("path"));
        errdefer a.free(path);
        const needle = try jsonText(a, o.get("needle"));
        errdefer a.free(needle);
        const task_id = try jsonText(a, o.get("task_id"));
        errdefer a.free(task_id);

        switch (kind) {
            .file_exists, .file_contains, .file_not_contains => {
                if (path.len == 0) return error.InvalidJson;
                if (kind != .file_exists and needle.len == 0) return error.InvalidJson;
            },
            .output_contains => {
                if (needle.len == 0) return error.InvalidJson;
            },
        }
        if (path.len > MAX_ASSERTION_TEXT or needle.len > MAX_ASSERTION_TEXT or task_id.len > MAX_ASSERTION_TEXT)
            return error.InvalidJson;

        try list.append(a, .{ .kind = kind, .path = path, .needle = needle, .task_id = task_id });
    }
    return list.toOwnedSlice(a);
}

fn jsonText(a: std.mem.Allocator, v: ?std.json.Value) ![]const u8 {
    const val = v orelse return try a.dupe(u8, "");
    if (val != .string) return error.InvalidJson;
    return try a.dupe(u8, val.string);
}

/// Una ruta declarada es segura solo si es relativa y no escapa del
/// directorio de la orden: sin unidad absoluta, sin "..", sin separadores al
/// inicio.
fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (path.len >= 2 and path[1] == ':') return false; // C:\...
    if (path[0] == '/' or path[0] == '\\') return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

const INVALID_HANDLE_VALUE: std.os.windows.HANDLE = @ptrFromInt(~@as(usize, 0));
const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?std.os.windows.HANDLE,
    ) std.os.windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(
        hFile: std.os.windows.HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: *u32,
        lpOverlapped: ?*anyopaque,
    ) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const GetFileSizeEx = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileSizeEx(hFile: std.os.windows.HANDLE, lpFileSize: *i64) c_int;
}.GetFileSizeEx else @import("providers").posix_files.GetFileSizeEx;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: std.os.windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;
const RemoveDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn RemoveDirectoryA(lpPathName: [*:0]const u8) c_int;
}.RemoveDirectoryA else @import("providers").posix_files.RemoveDirectoryA;
const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) std.os.windows.BOOL;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;
const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) u32;
}.GetTempPathA else @import("platform.zig").tempPath;

fn fileExists(path: []const u8, buf: *[4096]u8) bool {
    const z = std.fmt.bufPrintZ(buf, "{s}", .{path}) catch return false;
    const h = CreateFileA(z.ptr, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE_VALUE) return false;
    _ = CloseHandle(h);
    return true;
}

fn readFileBounded(a: std.mem.Allocator, path: []const u8, max_bytes: usize) !?[]u8 {
    const z = try a.dupeZ(u8, path);
    defer a.free(z);
    const h = CreateFileA(z.ptr, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0) return error.ReadFailed;
    const to_read: usize = @intCast(@min(size, @as(i64, @intCast(max_bytes))));
    const buf = try a.alloc(u8, to_read);
    errdefer a.free(buf);
    var total: usize = 0;
    while (total < to_read) {
        var got: u32 = 0;
        const want: u32 = @intCast(@min(to_read - total, std.math.maxInt(u32)));
        if (ReadFile(h, buf.ptr + total, want, &got, null) == 0) return error.ReadFailed;
        if (got == 0) break;
        total += got;
    }
    return buf[0..total];
}

fn snippetOf(a: std.mem.Allocator, content: []const u8) ![]const u8 {
    const n = @min(content.len, MAX_ACTUAL_SNIPPET);
    if (content.len <= MAX_ACTUAL_SNIPPET) return try a.dupe(u8, content);
    return try std.fmt.allocPrint(a, "{s}…[{d} bytes total]", .{ content[0..n], content.len });
}

/// Evalúa las aserciones contra el directorio de la orden y las salidas
/// registradas. `order_dir` es la raíz de los artefactos (los paths declarados
/// se resuelven bajo ella; un escape es FAIL honesto, no skip).
pub fn run(
    a: std.mem.Allocator,
    order_dir: []const u8,
    assertions: []const Assertion,
    outputs: []const OutputEvidence,
) !Result {
    return runWithProse(a, order_dir, assertions, outputs, &.{});
}

pub fn runWithProse(
    a: std.mem.Allocator,
    order_dir: []const u8,
    assertions: []const Assertion,
    outputs: []const OutputEvidence,
    prose: []const ProseEvidence,
) !Result {
    if (assertions.len == 0 and prose.len == 0) {
        return .{
            .ran = false,
            .verdict = .pass,
            .checks = try a.alloc(Check, 0),
            .differences_text = try a.dupe(u8, ""),
        };
    }

    var checks = std.ArrayList(Check).empty;
    errdefer {
        for (checks.items) |c| {
            c.assertion.deinit(a);
            a.free(c.actual);
            a.free(c.difference);
        }
        checks.deinit(a);
    }
    var diffs = std.ArrayList(u8).empty;
    defer diffs.deinit(a);

    var attr_buf: [4096]u8 = undefined;
    var any_fail = false;

    for (assertions) |as| {
        var ok = false;
        var actual: []const u8 = "";
        var difference: []const u8 = "";
        errdefer {
            a.free(actual);
            a.free(difference);
        }

        switch (as.kind) {
            .file_exists, .file_contains, .file_not_contains => {
                if (!safeRelativePath(as.path)) {
                    actual = try std.fmt.allocPrint(a, "ruta declarada '{s}' fuera del directorio de la orden", .{as.path});
                    difference = try std.fmt.allocPrint(a, "{s}: la ruta declarada '{s}' escapa del directorio de la orden", .{ @tagName(as.kind), as.path });
                } else {
                    const abs = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ order_dir, as.path });
                    defer a.free(abs);
                    const exists = fileExists(abs, &attr_buf);
                    if (!exists) {
                        actual = try std.fmt.allocPrint(a, "archivo '{s}' no existe en {s}", .{ as.path, order_dir });
                        difference = try std.fmt.allocPrint(a, "{s} '{s}': esperado presente, observado ausente", .{ @tagName(as.kind), as.path });
                    } else if (as.kind == .file_exists) {
                        ok = true;
                        actual = try std.fmt.allocPrint(a, "archivo '{s}' presente", .{as.path});
                    } else {
                        const content = (try readFileBounded(a, abs, 1 << 20)) orelse try a.dupe(u8, "");
                        defer a.free(content);
                        const found = std.mem.indexOf(u8, content, as.needle) != null;
                        if (as.kind == .file_contains) {
                            ok = found;
                            actual = try snippetOf(a, content);
                            if (!ok) {
                                difference = try std.fmt.allocPrint(a, "file_contains '{s}': se esperaba el literal '{s}', no está en el archivo ({d} bytes leídos)", .{ as.path, as.needle, content.len });
                            }
                        } else {
                            ok = !found;
                            actual = try snippetOf(a, content);
                            if (!ok) {
                                difference = try std.fmt.allocPrint(a, "file_not_contains '{s}': se esperaba ausencia del literal '{s}', pero está presente", .{ as.path, as.needle });
                            }
                        }
                    }
                }
            },
            .output_contains => {
                var haystack = std.ArrayList(u8).empty;
                defer haystack.deinit(a);
                var matched_task = false;
                for (outputs) |o| {
                    if (as.task_id.len > 0 and !std.mem.eql(u8, o.task_id, as.task_id)) continue;
                    matched_task = true;
                    try haystack.appendSlice(a, o.stdout);
                    try haystack.append(a, '\n');
                }
                if (!matched_task) {
                    actual = try std.fmt.allocPrint(a, "sin salida registrada para la tarea '{s}' (nunca ejecutó o no produjo stdout)", .{as.task_id});
                    difference = try std.fmt.allocPrint(a, "output_contains: la tarea '{s}' no tiene salida registrada — no hay evidencia que comprobar", .{as.task_id});
                } else {
                    ok = std.mem.indexOf(u8, haystack.items, as.needle) != null;
                    actual = try snippetOf(a, haystack.items);
                    if (!ok) {
                        difference = try std.fmt.allocPrint(a, "output_contains: se esperaba el literal '{s}' en la salida de '{s}', no aparece", .{ as.needle, if (as.task_id.len > 0) as.task_id else "todas las tareas" });
                    }
                }
            },
        }

        if (!ok) {
            any_fail = true;
            if (diffs.items.len > 0) try diffs.appendSlice(a, "\n");
            try diffs.appendSlice(a, difference);
        }
        // El check POSEE su copia de la aserción: el llamador libera su slice
        // por su cuenta y el Result queda autocontenido.
        try checks.append(a, .{
            .assertion = .{
                .kind = as.kind,
                .path = try a.dupe(u8, as.path),
                .needle = try a.dupe(u8, as.needle),
                .task_id = try a.dupe(u8, as.task_id),
            },
            .ok = ok,
            .actual = actual,
            .difference = difference,
        });
    }

    for (prose) |file| {
        const content = (try readFileBounded(a, file.path, 1 << 20)) orelse try a.dupe(u8, "");
        defer a.free(content);
        var reason = prose_artifact.invalidReason(file.path, content, file.description);
        // una pieza de prosa en un idioma concluyente distinto al de
        // la orden se rechaza con causa legible; el código/JSON/config queda
        // fuera (languageMismatchReason lo comprueba por la forma del cuerpo).
        if (reason == null) reason = prose_artifact.languageMismatchReason(content, file.description);
        const difference = if (reason) |why|
            try std.fmt.allocPrint(a, "prosa '{s}': {s}", .{ file.path, why })
        else
            try a.dupe(u8, "");
        errdefer a.free(difference);
        if (reason != null) {
            any_fail = true;
            if (diffs.items.len > 0) try diffs.appendSlice(a, "\n");
            try diffs.appendSlice(a, difference);
        }
        const path = try a.dupe(u8, file.path);
        errdefer a.free(path);
        const needle = try a.dupe(u8, "");
        errdefer a.free(needle);
        const task_id = try a.dupe(u8, file.task_id);
        errdefer a.free(task_id);
        const actual = try snippetOf(a, content);
        errdefer a.free(actual);
        try checks.append(a, .{
            .assertion = .{ .kind = .file_exists, .path = path, .needle = needle, .task_id = task_id },
            .ok = reason == null,
            .actual = actual,
            .difference = difference,
        });
    }

    return .{
        .ran = true,
        .verdict = if (any_fail) .fail else .pass,
        .checks = try checks.toOwnedSlice(a),
        .differences_text = try diffs.toOwnedSlice(a),
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

test "SEMANTIC-GATE parseAssertions: válido, inválido y kinds desconocidos" {
    const a = std.testing.allocator;
    const ok = try parseAssertions(a,
        \\[{"kind":"file_exists","path":"a.html"},{"kind":"file_contains","path":"a.html","needle":"HOLA"},{"kind":"output_contains","task_id":"t2","needle":"9"}]
    );
    defer {
        for (ok) |as| as.deinit(a);
        a.free(ok);
    }
    try std.testing.expectEqual(@as(usize, 3), ok.len);
    try std.testing.expectEqual(Kind.file_contains, ok[1].kind);
    try std.testing.expectEqualStrings("t2", ok[2].task_id);

    try std.testing.expectError(error.InvalidJson, parseAssertions(a, "{\"kind\":\"file_exists\"}"));
    try std.testing.expectError(error.InvalidJson, parseAssertions(a, "[{\"kind\":\"noseque\",\"path\":\"x\"}]"));
    try std.testing.expectError(error.InvalidJson, parseAssertions(a, "[{\"kind\":\"file_contains\",\"path\":\"x\"}]")); // falta needle
    try std.testing.expectError(error.InvalidJson, parseAssertions(a, "[{\"kind\":\"file_exists\"}]")); // falta path
}

test "SEMANTIC-GATE run: file_exists/file_contains pass y fail con diferencia concreta" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // tmp.sub_path es el componente aleatorio; el archivo se crea en el temp
    // del sistema via Win32 (misma convención que isolatedTestPath en c_api).
    var sys_buf: [1024]u8 = undefined;
    const sys_len = GetTempPathA(1024, &sys_buf);
    const sys_temp = if (sys_len > 0 and sys_len < 1024) sys_buf[0..sys_len] else "C:\\Windows\\Temp\\";
    const dir = try std.fmt.allocPrint(a, "{s}beats-semgate-{s}", .{ sys_temp, tmp.sub_path[0..] });
    defer a.free(dir);
    const dir_z = try a.dupeZ(u8, dir);
    defer a.free(dir_z);
    _ = CreateDirectoryA(dir_z.ptr, null);
    defer _ = RemoveDirectoryA(dir_z.ptr);
    const fpath = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "hola.html", .{dir});
    defer a.free(fpath);
    const fpath_z = try a.dupeZ(u8, fpath);
    defer a.free(fpath_z);
    {
        const GENERIC_WRITE: u32 = 0x40000000;
        const CREATE_ALWAYS: u32 = 2;
        const hf = CreateFileA(fpath_z.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        try std.testing.expect(hf != INVALID_HANDLE_VALUE);
        const body = "<html><body>HOLA MUNDO</body></html>";
        var written: u32 = 0;
        try std.testing.expect(WriteFile(hf, body.ptr, @intCast(body.len), &written, null) != 0);
        _ = CloseHandle(hf);
    }
    defer _ = DeleteFileA(fpath_z.ptr);

    const assertions = try parseAssertions(a,
        \\[{"kind":"file_exists","path":"hola.html"},{"kind":"file_contains","path":"hola.html","needle":"HOLA MUNDO"},{"kind":"file_not_contains","path":"hola.html","needle":"ADIÓS"},{"kind":"file_contains","path":"hola.html","needle":"ESTO NO ESTÁ"},{"kind":"file_exists","path":"falta.txt"}]
    );
    defer {
        for (assertions) |as| as.deinit(a);
        a.free(assertions);
    }

    var res = try run(a, dir, assertions, &.{});
    defer res.deinit(a);
    try std.testing.expect(res.ran);
    try std.testing.expectEqual(Verdict.fail, res.verdict);
    try std.testing.expect(res.checks[0].ok);
    try std.testing.expect(res.checks[1].ok);
    try std.testing.expect(res.checks[2].ok);
    try std.testing.expect(!res.checks[3].ok);
    try std.testing.expect(!res.checks[4].ok);
    // La diferencia es concreta: dice qué literal se esperaba y dónde.
    try std.testing.expect(std.mem.indexOf(u8, res.differences_text, "ESTO NO ESTÁ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.differences_text, "falta.txt") != null);
}

test "SEMANTIC-GATE run: output_contains usa la salida registrada y path escape falla honesto" {
    const a = std.testing.allocator;
    const outputs = [_]OutputEvidence{
        .{ .task_id = "t2", .stdout = "compilando...\n6+3 = 9\nok" },
    };
    const assertions = try parseAssertions(a,
        \\[{"kind":"output_contains","task_id":"t2","needle":"6+3 = 9"},{"kind":"output_contains","task_id":"t9","needle":"x"},{"kind":"file_exists","path":"..\\..\\secrets.txt"}]
    );
    defer {
        for (assertions) |as| as.deinit(a);
        a.free(assertions);
    }
    var res = try run(a, "C:\\tmp", assertions, &outputs);
    defer res.deinit(a);
    try std.testing.expect(res.ran);
    try std.testing.expectEqual(Verdict.fail, res.verdict);
    try std.testing.expect(res.checks[0].ok); // el observable declarado se cumplió
    try std.testing.expect(!res.checks[1].ok); // sin salida registrada para t9
    try std.testing.expect(!res.checks[2].ok); // escape de ruta = FAIL honesto
    try std.testing.expect(std.mem.indexOf(u8, res.differences_text, "t9") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.differences_text, "escapa") != null);
}

test "MOT018 semantic file_exists cannot approve prose metadata" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    for ([_][]const u8{ "documentacion", "docs/api-key-risks.txt", "api-key-risks.txt" }) |body| {
        try tmp.dir.writeFile(io, .{ .sub_path = "api-key-risks.txt", .data = body });
        const path = try tmp.dir.realPathFileAlloc(io, "api-key-risks.txt", a);
        defer a.free(path);
        var result = try runWithProse(a, root, &.{.{ .kind = .file_exists, .path = "api-key-risks.txt" }}, &.{}, &.{.{ .path = path, .description = "Documenta los riesgos de guardar claves de API", .task_id = "t1" }});
        defer result.deinit(a);
        try std.testing.expect(result.ran);
        try std.testing.expectEqual(Verdict.fail, result.verdict);
    }
}

test "MOT018 fix run preserves declared assertion semantics for empty and metadata files" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    for ([_][]const u8{ "", "documentacion", "file.txt" }) |body| {
        try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = body });
        var result = try run(a, root, &.{
            .{ .kind = .file_exists, .path = "file.txt" },
            .{ .kind = .file_contains, .path = "file.txt", .needle = body },
            .{ .kind = .file_not_contains, .path = "file.txt", .needle = "NEVER_PRESENT" },
        }, &.{});
        defer result.deinit(a);
        try std.testing.expectEqual(Verdict.pass, result.verdict);
        try std.testing.expectEqual(@as(usize, 3), result.checks.len);
    }
}

test "SEMANTIC-GATE run: sin aserciones = ran:false (no fabrica veredicto)" {
    const a = std.testing.allocator;
    var res = try run(a, "C:\\tmp", &.{}, &.{});
    defer res.deinit(a);
    try std.testing.expect(!res.ran);
    try std.testing.expectEqual(Verdict.pass, res.verdict);
}

test "MOT017 gate rejects English prose for a Spanish order and accepts Spanish" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const es_order = "Documenta brevemente en un texto los riesgos de guardar claves de API en texto plano";
    const en_body = "Storing API keys in plain text exposes accounts to unauthorized access and unexpected charges. Keep secrets out of repositories and logs, restrict access and revoke leaked keys.";
    const es_body = "Las claves de API en texto plano pueden filtrarse en repositorios y copias de seguridad. Usa un gestor de secretos y revoca las claves expuestas de inmediato.";

    try tmp.dir.writeFile(io, .{ .sub_path = "risks.txt", .data = en_body });
    const path = try tmp.dir.realPathFileAlloc(io, "risks.txt", a);
    defer a.free(path);
    var result = try runWithProse(a, root, &.{}, &.{}, &.{.{ .path = path, .description = es_order, .task_id = "t1" }});
    defer result.deinit(a);
    try std.testing.expect(result.ran);
    try std.testing.expectEqual(Verdict.fail, result.verdict);
    try std.testing.expect(std.mem.indexOf(u8, result.differences_text, "inglés") != null);

    try tmp.dir.writeFile(io, .{ .sub_path = "risks.txt", .data = es_body });
    var result2 = try runWithProse(a, root, &.{}, &.{}, &.{.{ .path = path, .description = es_order, .task_id = "t1" }});
    defer result2.deinit(a);
    try std.testing.expectEqual(Verdict.pass, result2.verdict);
}
