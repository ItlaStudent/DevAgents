const std = @import("std");

/// Wrapper mínimo para SQLite embebido.
/// Usa la amalgamación C compilada vía build.zig.
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

// ── Turno de transacciones por conexión (10-nov) ───────────────────────────
// Una ranura por conexión (por su puntero, en una tabla fija), con propietario y
// profundidad para que el mismo hilo pueda anidar. Si la espera supera ~10 s
// se sigue sin turno (comportamiento anterior) para no bloquear nunca el motor
// por un abrazo mortal entre dos conexiones.
const TxKind = enum { begin, commit, rollback, other };

fn txKind(sql: []const u8) TxKind {
    const s = std.mem.trimStart(u8, sql, " \t\r\n");
    if (std.ascii.startsWithIgnoreCase(s, "BEGIN")) return .begin;
    if (std.ascii.startsWithIgnoreCase(s, "COMMIT") or std.ascii.startsWithIgnoreCase(s, "END")) return .commit;
    if (std.ascii.startsWithIgnoreCase(s, "ROLLBACK")) {
        // ROLLBACK TO <savepoint> no cierra la transacción.
        const rest = std.mem.trimStart(u8, s["ROLLBACK".len..], " \t\r\n");
        if (std.ascii.startsWithIgnoreCase(rest, "TO")) return .other;
        return .rollback;
    }
    return .other;
}

const TxSlot = struct {
    lock: std.atomic.Mutex = .unlocked,
    owner: std.atomic.Value(u64) = .init(0),
    depth: u32 = 0,
    /// El turno se tomó de verdad (false si se agotó la espera).
    held: bool = false,
};
var tx_slots: [32]TxSlot = [_]TxSlot{.{}} ** 32;

fn txSlotFor(handle: ?*c.sqlite3) *TxSlot {
    return &tx_slots[(@intFromPtr(handle) >> 4) % tx_slots.len];
}

const Sleep = @import("platform.zig").sleep;

fn txThreadId() u64 {
    return @as(u64, std.Thread.getCurrentId()) + 1;
}

fn txEnter(slot: *TxSlot) void {
    const me = txThreadId();
    if (slot.owner.load(.acquire) == me) {
        slot.depth += 1;
        return;
    }
    var waited: u32 = 0;
    while (!slot.lock.tryLock()) : (waited += 1) {
        if (waited >= 10_000) return; // ~10 s: se sigue sin turno.
        // POSIX tambien duerme 1 ms: un spinLoopHint agota las 10.000 vueltas
        // en microsegundos mientras el otro hilo conserva el turno (suite de
        // Linux, intermitente «dos hilos ... MISMA conexion»).
        Sleep(1);
    }
    slot.owner.store(me, .release);
    slot.depth = 1;
    slot.held = true;
}

fn txExit(slot: *TxSlot) void {
    if (slot.owner.load(.acquire) != txThreadId()) return;
    if (slot.depth > 1) {
        slot.depth -= 1;
        return;
    }
    slot.depth = 0;
    slot.owner.store(0, .release);
    if (slot.held) {
        slot.held = false;
        slot.lock.unlock();
    }
}

pub const DbError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    MigrateFailed,
    /// La base de datos fue creada por una versión más nueva (user_version > migraciones).
    /// Solución: usar la BD correcta o regenerarla (nunca editar a mano).
    DbSchemaAhead,
    OutOfMemory,
    /// TERMINAL-STATE-DESIGN-2026-07-12: un INSERT violó una restricción (p. ej. el
    /// índice único parcial de eventos terminales) — distinto de un StepFailed genérico
    /// para que el llamador pueda distinguir "dato en conflicto" de "error de motor".
    ConstraintViolation,
    InvalidTerminalTransition,
    SessionActive,
    ArchiveChanged,
    /// la copia de seguridad previa a migrar (VACUUM INTO) falló.
    /// La migración NO se aplicó y la base sigue como estaba. Causas típicas:
    /// disco lleno, permisos, antivirus. Reintentar cuando la carpeta de la
    /// base sea escribible.
    BackupFailed,
    /// r2: la copia se hizo, pero la poda no pudo garantizar la
    /// retención de `max_db_backups` (fallo real de enumeración o de borrado:
    /// permisos, antivirus, fichero abierto sin compartir borrado). La
    /// migración NO se aplica; la copia recién hecha se queda y la base no
    /// se toca.
    BackupRetentionFailed,
};

/// Conexión a una base de datos SQLite.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    /// Ruta del archivo de la base (copiada en `open`; null para `:memory:` o
    /// mientras no se haya registrado). la usa Migrator.migrate
    /// para respaldar la base con `VACUUM INTO` antes de tocarla.
    path: ?[]const u8 = null,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Connection {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path_z, &db);
        if (rc != c.SQLITE_OK) {
            return error.OpenFailed;
        }
        var conn = Connection{
            .allocator = allocator,
            .db = db,
        };
        if (std.mem.eql(u8, path, ":memory:")) {
            return conn;
        }
        // recordar la ruta para poder respaldar la base. Si la
        // copia de la ruta falla, se cierra el handle recién abierto para no
        // dejar recursos a medias.
        conn.path = allocator.dupe(u8, path) catch |e| {
            conn.close();
            return e;
        };
        conn.exec("PRAGMA busy_timeout = 5000") catch {};
        // BUG-1 (2026-08-12): WAL en vez de DELETE.
        //
        // Con `journal_mode = DELETE` SQLite admite UN escritor y los lectores
        // bloquean al escritor. El motor abre hasta TRES conexiones a
        // runtime.db a la vez —hilo principal, hilo de despacho y la propia del
        // planificador (H1)—, asi que la contencion no es teorica: la orden
        // #237 termino `done` con sus tres archivos escritos y CERO eventos de
        // tarea, porque cada INSERT moria en SQLITE_BUSY y `recordEvent` tiraba
        // el codigo de retorno. Reproducido en test
        // («BUG-1: con la base bloqueada por otro escritor...»).
        //
        // WAL permite un escritor Y lectores concurrentes sin bloquearse entre
        // si, que es exactamente la forma de este motor. La conversion la hace
        // SQLite sola al abrir y es reversible con `PRAGMA journal_mode=DELETE`.
        //
        // NO sirve sobre unidades de red; runtime.db y catalog.db son locales
        // (`%LOCALAPPDATA%\DevAgents`), asi que no aplica.
        conn.exec("PRAGMA journal_mode = WAL") catch {};
        // Con WAL, `NORMAL` sincroniza en los checkpoints en vez de en cada
        // commit: es el modo recomendado con WAL y evita pagar un fsync por
        // cada evento de traza, que es escritura de alta frecuencia.
        conn.exec("PRAGMA synchronous = NORMAL") catch {};
        return conn;
    }

    pub fn close(self: *Connection) void {
        if (self.path) |p| {
            self.allocator.free(p);
            self.path = null;
        }
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    /// Ejecuta SQL directo (DDL, DML simple).
    pub fn exec(self: Connection, sql: []const u8) DbError!void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        // 10-nov (órdenes 933, 940, 942 y 946): el motor comparte UNA conexión
        // entre el hilo que planifica y los del puente. Si uno abría su
        // transacción mientras otro tenía la suya, el BEGIN fallaba
        // (ExecFailed) y la orden quedaba sin cerrar. Las transacciones de una
        // misma conexión se turnan; el mismo hilo puede anidar.
        const kind = txKind(sql);
        const slot = txSlotFor(self.db);
        if (kind == .begin) txEnter(slot);
        const rc = c.sqlite3_exec(self.db, sql_z, null, null, null);
        switch (kind) {
            .begin => if (rc != c.SQLITE_OK) txExit(slot),
            .commit => if (rc == c.SQLITE_OK) txExit(slot),
            .rollback => txExit(slot),
            .other => {},
        }
        if (rc != c.SQLITE_OK) return error.ExecFailed;
    }

    /// Obtiene PRAGMA user_version.
    pub fn getUserVersion(self: Connection) DbError!i32 {
        const stmt = try self.prepare("PRAGMA user_version");
        defer self.finalize(stmt);
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return c.sqlite3_column_int(stmt, 0);
    }

    /// Establece PRAGMA user_version.
    pub fn setUserVersion(self: Connection, version: i32) DbError!void {
        const sql = try std.fmt.allocPrint(self.allocator, "PRAGMA user_version = {d}", .{version});
        defer self.allocator.free(sql);
        try self.exec(sql);
    }

    pub fn prepare(self: Connection, sql: []const u8) DbError!*c.sqlite3_stmt {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql_z, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        return stmt.?;
    }

    pub fn finalize(_: Connection, stmt: *c.sqlite3_stmt) void {
        _ = c.sqlite3_finalize(stmt);
    }

    /// Filas afectadas por el último INSERT/UPDATE/DELETE de esta conexión (sqlite3_changes).
    /// TERMINAL-STATE-DESIGN-2026-07-12: usado por tryCommitTerminal para detectar,
    /// sin carreras, si el UPDATE condicional realmente ganó la transición.
    pub fn changes(self: Connection) i64 {
        return @intCast(c.sqlite3_changes(self.db));
    }

    /// Transición terminal atómica (TERMINAL-STATE-DESIGN-2026-07-12): la DB es la
    /// autoridad. Un UPDATE condicional (solo desde estados no-terminales) y el
    /// INSERT del evento terminal viven en la MISMA transacción SQLite — un UPDATE
    /// separado seguido de un INSERT aparte no basta, porque un crash entre ambos
    /// dejaría estado terminal sin evento.
    ///
    /// - `changes()==0` tras el UPDATE (ya había un terminal) → ROLLBACK, `false`,
    ///   sin error: es la contención normal esperada, no una falla.
    /// - El INSERT falla por el índice único parcial (dato en conflicto, p. ej. un
    ///   evento terminal heredado que el UPDATE no vio) → ROLLBACK, conserva el
    ///   estado anterior, `error.ConstraintViolation`.
    /// - `new_status`/`event_kind` deben venir siempre de enums fijos (OrderStatus/
    ///   nombres de evento), nunca de texto arbitrario — el SQL es literal, sin
    ///   interpolación (CODING-STANDARDS §8); solo los VALORES se bindean.
    /// - `dispatch_failed` nunca debe pasar por aquí: no es terminal.
    pub fn tryCommitTerminal(
        self: Connection,
        order_id: i64,
        new_status: []const u8,
        event_kind: []const u8,
        event_source: []const u8,
        payload: []const u8,
        now_ms: i64,
    ) DbError!bool {
        const valid_pair = (std.mem.eql(u8, new_status, "done") and std.mem.eql(u8, event_kind, "order_done")) or
            (std.mem.eql(u8, new_status, "failed") and std.mem.eql(u8, event_kind, "order_failed")) or
            (std.mem.eql(u8, new_status, "cancelled") and std.mem.eql(u8, event_kind, "order_cancelled")) or
            // AUDIT-UNAVAILABLE-P0: la orden cerró sin auditoría válida. Es un
            // par terminal REAL pero NO entra en la lista del UPDATE de abajo:
            // el reintento manual (da_order_resume_async) debe poder comprometer
            // done/failed después — si estuviera excluida, el commit del
            // reintento devolvería changes()==0 y la orden quedaría clavada.
            // Tampoco entra en el índice único de eventos terminales: volver a
            // quedar 'audit_unavailable' tras un reintento emite un evento nuevo.
            (std.mem.eql(u8, new_status, "audit_unavailable") and std.mem.eql(u8, event_kind, "order_audit_unavailable_v1"));
        if (!valid_pair) return error.InvalidTerminalTransition;

        try self.exec("BEGIN IMMEDIATE");
        // Guard explícito de transacción: evita doble ROLLBACK. errdefer solo actúa
        // si tx_open sigue true — los caminos que ya emitieron su propio ROLLBACK/
        // COMMIT lo desactivan primero.
        var tx_open = true;
        errdefer {
            if (tx_open) self.exec("ROLLBACK") catch {};
        }

        const upd = try self.prepare(
            "UPDATE orders SET status = ? WHERE id = ? AND status NOT IN ('done','failed','rejected','cancelled')",
        );
        defer self.finalize(upd);
        try bindText(upd, 1, new_status);
        try bindInt(upd, 2, order_id);
        if (c.sqlite3_step(upd) != c.SQLITE_DONE) return error.StepFailed;

        if (self.changes() == 0) {
            tx_open = false;
            try self.exec("ROLLBACK");
            return false;
        }

        const ins = try self.prepare(
            "INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, ?, ?, ?, ?)",
        );
        defer self.finalize(ins);
        try bindInt(ins, 1, now_ms);
        try bindText(ins, 2, event_source);
        try bindText(ins, 3, event_kind);
        try bindText(ins, 4, payload);
        try bindInt(ins, 5, order_id);
        const ins_rc = c.sqlite3_step(ins);
        if (ins_rc == c.SQLITE_CONSTRAINT) return error.ConstraintViolation;
        if (ins_rc != c.SQLITE_DONE) return error.StepFailed;

        // tx_open se desactiva DESPUÉS de un COMMIT exitoso — si COMMIT falla, el
        // guard sigue activo y el errdefer intenta el único ROLLBACK de limpieza.
        try self.exec("COMMIT");
        tx_open = false;
        return true;
    }
};

/// Destructor SQLITE_TRANSIENT: indica a SQLite que copie el valor enlazado.
/// Necesario porque los slices de Zig no son persistentes ni null-terminated.
pub const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// ── API Win32 de enumeración/borrado ─────────────────────────
//
// El respaldo y la poda de copias necesitan listar y borrar archivos junto a
// la base. La conexión `Migrator.migrate` NO tiene un `std.Io` a mano (los
// llamadores no lo pasan y son intocables en esta tarea), y este fork expone
// el sistema de archivos por `std.Io`; por eso se usa Win32 directo, en la
// misma vía W del fix (c_api.zig:7342): la enumeración ANSI mutila rutas
// UTF-8 reales (p. ej. un usuario «José»).

/// WIN32_FIND_DATAW de la API W (cFileName UTF-16).
pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime_dwLowDateTime: u32,
    ftCreationTime_dwHighDateTime: u32,
    ftLastAccessTime_dwLowDateTime: u32,
    ftLastAccessTime_dwHighDateTime: u32,
    ftLastWriteTime_dwLowDateTime: u32,
    ftLastWriteTime_dwHighDateTime: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

const FindFirstFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *anyopaque) callconv(.winapi) std.os.windows.HANDLE;
}.FindFirstFileW else @import("providers").posix_files.FindFirstFileW;
const FindNextFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindNextFileW(hFindFile: std.os.windows.HANDLE, lpFindFileData: *anyopaque) callconv(.winapi) c_int;
}.FindNextFileW else @import("providers").posix_files.FindNextFileW;
const FindClose = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindClose(hFindFile: std.os.windows.HANDLE) callconv(.winapi) c_int;
}.FindClose else @import("providers").posix_files.FindClose;
const DeleteFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) c_int;
}.DeleteFileW else @import("providers").posix_files.DeleteFileW;
// r2: la poda exige la retención; para distinguir «sin coincidencias» de un
// error real de enumeración hace falta el código de error de las llamadas W.
const GetLastError = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
}.GetLastError else @import("providers").posix_files.GetLastError;
// r2 (solo prueba): marcar una copia de solo lectura para que DeleteFileW
// falle con ERROR_ACCESS_DENIED, y restaurarla al final de la prueba.
extern "kernel32" fn SetFileAttributesW(lpFileName: [*:0]const u16, dwFileAttributes: u32) callconv(.winapi) c_int;

pub const FILE_ATTRIBUTE_READONLY: u32 = 0x1;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
/// FindFirstFileW/FindNextFileW: no hay más coincidencias (fin normal de la
/// enumeración). Cualquier otro código de GetLastError es un fallo real y
/// debe abortar la migración (error.BackupRetentionFailed).
pub const ERROR_FILE_NOT_FOUND: u32 = 2;
pub const ERROR_NO_MORE_FILES: u32 = 18;

// ── Respaldo previo a migrar (, L3) ─────────────────────────────
//
// Antes de aplicar migraciones pendientes sobre una base existente y poblada
// se copia el fichero completo con `VACUUM INTO` (fotografía consistente, sin
// -wal/-shm) a `<base>.bak-v<versión_antigua>-<AAAAMMDD-HHMMSS>` (UTC), junto
// a la base. Máximo `max_db_backups` copias por base, podando las más
// antiguas. Si la copia falla, la migración NO se aplica (error.BackupFailed)
// y la base queda intacta; si la copia se hizo pero la poda no puede
// garantizar la retención (r2), tampoco se migra (error.BackupRetentionFailed)
// y la copia recién hecha se queda.

/// Máximo de copias `<base>.bak-v…` conservadas por base.
pub const max_db_backups: usize = 3;

/// Una copia detectada junto a la base: ruta completa (heap), versión antigua
/// retratada y su marca UTC.
const BackupEntry = struct {
    path: []u8,
    version: u32,
    stamp: [15]u8,
};

/// Nombre de fichero de copia ya validado contra el patrón exacto.
const BackupFileName = struct {
    name: []u8,
    version: u32,
    stamp: [15]u8,
};

///. Respalda la base antes de aplicar migraciones pendientes.
///
/// Reglas:
/// - Base en memoria (sin `path`) o sin ninguna tabla (`sqlite_master` vacío):
///   no hay nada que perder y no se copia.
/// - La copia se hace con `VACUUM INTO '<base>.bak-v<vieja>-<stamp>'`; ante
///   cualquier fallo (disco, permisos, destino ocupado) se devuelve
///   error.BackupFailed y la migración no llega a ejecutarse.
/// - Tras copiar se podan las copias antiguas (máx. `max_db_backups`). Si la
///   poda no puede garantizar la retención (r2), se devuelve
///   error.BackupRetentionFailed y la migración tampoco se ejecuta; la copia
///   recién hecha se queda.
/// - No hay restauración automática. Para volver atrás: cerrar DevAgents,
///   borrar `<base>` y sus `-wal`/`-shm` si existen, y renombrar la copia
///   elegida sobre `<base>`.
///
/// Devuelve la ruta de la copia hecha (memoria de `allocator`) o null si no
/// hacía falta copiar: la nombra si después falla una migración.
fn backupBeforePendingMigrations(allocator: std.mem.Allocator, conn: Connection, old_version: u32) DbError!?[]u8 {
    const base_path = conn.path orelse return null;
    if (!try hasAnyUserTable(conn)) return null;
    const stamp = try utcStampNow(conn);
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak-v{d}-{s}", .{ base_path, old_version, stamp });
    errdefer allocator.free(backup_path);
    // VACUUM INTO exige un literal SQL: se doblan las comillas simples (una
    // ruta de usuario puede contenerlas).
    const escaped = try escapeSqlLiteral(allocator, backup_path);
    defer allocator.free(escaped);
    const sql = try std.fmt.allocPrint(allocator, "VACUUM INTO '{s}'", .{escaped});
    defer allocator.free(sql);
    conn.exec(sql) catch return error.BackupFailed;
    try pruneOldBackups(allocator, base_path);
    return backup_path;
}

/// ¿La base tiene ya alguna tabla de usuario? Distingue "base existente con
/// datos" de un fichero recién creado por Connection.open (0 tablas), que no
/// debe generar copia al migrarse de 0.
fn hasAnyUserTable(conn: Connection) DbError!bool {
    const stmt = try conn.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'");
    defer conn.finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int64(stmt, 0) > 0;
}

/// Marca de tiempo UTC con el formato exacto del nombre de copia
/// (`AAAAMMDD-HHMMSS`). Este fork de Zig 0.16 no expone std.time en el
/// contrato del motor, así que la da SQLite (mismo patrón que
/// plugin_loader.zig:375).
fn utcStampNow(conn: Connection) DbError![15]u8 {
    const stmt = try conn.prepare("SELECT strftime('%Y%m%d-%H%M%S', 'now')");
    defer conn.finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    const txt = c.sqlite3_column_text(stmt, 0);
    if (txt == null) return error.StepFailed;
    const slice = std.mem.span(txt);
    if (slice.len != 15) return error.StepFailed;
    var out: [15]u8 = undefined;
    @memcpy(out[0..15], slice[0..15]);
    return out;
}

/// Copia `s` escapando comillas simples para interpolar en un literal SQL.
fn escapeSqlLiteral(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var extra: usize = 0;
    for (s) |ch| {
        if (ch == '\'') extra += 1;
    }
    const out = try allocator.alloc(u8, s.len + extra);
    var j: usize = 0;
    for (s) |ch| {
        out[j] = ch;
        j += 1;
        if (ch == '\'') {
            out[j] = '\'';
            j += 1;
        }
    }
    return out;
}

/// Valida `<base>.bak-v<dígitos>-<8 dígitos>-<6 dígitos>` (patrón de esta
/// tarea) sobre el nombre UTF-16 que devuelve Win32. Devuelve null —y el
/// fichero no se toca— ante cualquier desviación: la poda jamás borra algo
/// que no sea una copia propia.
fn parseBackupFileName(allocator: std.mem.Allocator, name_w: []const u16, prefix: []const u8) DbError!?BackupFileName {
    const name = std.unicode.utf16LeToUtf8Alloc(allocator, name_w) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // Un nombre que no decodifica no puede ser una copia propia: se
        // ignora (la poda jamás borra lo que no entiende).
        else => return null,
    };
    errdefer allocator.free(name);
    if (!std.mem.startsWith(u8, name, prefix)) {
        allocator.free(name);
        return null;
    }
    const rest = name[prefix.len..];
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {}
    if (i == 0 or rest.len != i + 1 + 8 + 1 + 6) {
        allocator.free(name);
        return null;
    }
    const version = std.fmt.parseInt(u32, rest[0..i], 10) catch {
        allocator.free(name);
        return null;
    };
    if (rest[i] != '-') {
        allocator.free(name);
        return null;
    }
    const stamp_s = rest[i + 1 ..][0..15];
    for (stamp_s[0..8]) |ch| {
        if (!std.ascii.isDigit(ch)) {
            allocator.free(name);
            return null;
        }
    }
    if (stamp_s[8] != '-') {
        allocator.free(name);
        return null;
    }
    for (stamp_s[9..]) |ch| {
        if (!std.ascii.isDigit(ch)) {
            allocator.free(name);
            return null;
        }
    }
    var stamp: [15]u8 = undefined;
    @memcpy(stamp[0..15], stamp_s);
    return BackupFileName{ .name = name, .version = version, .stamp = stamp };
}

/// Orden para la poda: copias más antiguas primero (marca UTC; empate de
/// marca, versión más baja primero).
fn backupsOlderFirst(_: void, a: BackupEntry, b: BackupEntry) bool {
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        if (a.stamp[i] != b.stamp[i]) return a.stamp[i] < b.stamp[i];
    }
    return a.version < b.version;
}

/// utf8ToUtf16LeAllocZ con el contrato de error del módulo: una ruta que no
/// sea UTF-8 válido (p. ej. con surrogates sueltos) no puede tratarse como
/// copia viable → BackupFailed, sin silencios.
fn toUtf16Z(allocator: std.mem.Allocator, s: []const u8) DbError![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.BackupFailed,
    };
}

/// ¿El código de `GetLastError` significa «no hay más coincidencias» en la
/// enumeración FindFirstFileW/FindNextFileW? (ERROR_FILE_NOT_FOUND=2,
/// ERROR_NO_MORE_FILES=18). Cualquier otro código es un fallo real.
fn isNoMatchesError(code: u32) bool {
    return code == ERROR_FILE_NOT_FOUND or code == ERROR_NO_MORE_FILES;
}

/// Poda las copias de `base_path`: borra las más antiguas hasta dejar
/// `max_db_backups` y solo archivos con el patrón exacto.
///
/// r2: la retención se EXIGE, no es best-effort. «Sin coincidencias»
/// (ERROR_FILE_NOT_FOUND / ERROR_NO_MORE_FILES) no es un error: no hay nada
/// que podar. Un fallo real de enumeración o un borrado que no se completa
/// (antivirus, permisos, fichero abierto sin compartir borrado) devuelve
/// error.BackupRetentionFailed y el migrador NO aplica la migración: la copia
/// recién hecha se queda y la base no se toca.
fn pruneOldBackups(allocator: std.mem.Allocator, base_path: []const u8) DbError!void {
    const dir = std.fs.path.dirname(base_path) orelse ".";
    const prefix = try std.fmt.allocPrint(allocator, "{s}.bak-v", .{std.fs.path.basename(base_path)});
    defer allocator.free(prefix);
    const pattern = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}*", .{ dir, prefix });
    defer allocator.free(pattern);
    const pattern_w = try toUtf16Z(allocator, pattern);
    defer allocator.free(pattern_w);

    var entries: std.ArrayList(BackupEntry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.path);
        entries.deinit(allocator);
    }

    var fd: WIN32_FIND_DATAW = undefined;
    const h = FindFirstFileW(pattern_w, @ptrCast(&fd));
    if (h == std.os.windows.INVALID_HANDLE_VALUE) {
        if (!isNoMatchesError(GetLastError())) return error.BackupRetentionFailed;
        return;
    }
    defer _ = FindClose(h);
    while (true) {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0) {
            const zlen = std.mem.indexOfScalar(u16, &fd.cFileName, 0) orelse fd.cFileName.len;
            if (try parseBackupFileName(allocator, fd.cFileName[0..zlen], prefix)) |parsed| {
                const full = try std.fs.path.join(allocator, &.{ dir, parsed.name });
                allocator.free(parsed.name);
                entries.append(allocator, .{ .path = full, .version = parsed.version, .stamp = parsed.stamp }) catch |e| {
                    allocator.free(full);
                    return e;
                };
            }
        }
        if (FindNextFileW(h, @ptrCast(&fd)) == 0) {
            if (!isNoMatchesError(GetLastError())) return error.BackupRetentionFailed;
            break;
        }
    }
    if (entries.items.len <= max_db_backups) return;
    std.mem.sort(BackupEntry, entries.items, {}, backupsOlderFirst);
    var idx: usize = 0;
    while (idx < entries.items.len - max_db_backups) : (idx += 1) {
        const w = try toUtf16Z(allocator, entries.items[idx].path);
        defer allocator.free(w);
        if (DeleteFileW(w) == 0) return error.BackupRetentionFailed;
    }
}

/// Enlaza un parámetro de texto (1-indexado) con copia transitoria.
/// Usar SIEMPRE en lugar de interpolar valores en el SQL: previene inyección (CODING-STANDARDS §8).
pub fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) DbError!void {
    if (c.sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.BindFailed;
}

/// Enlaza un parámetro entero (1-indexado).
pub fn bindInt(stmt: *c.sqlite3_stmt, idx: c_int, value: i64) DbError!void {
    if (c.sqlite3_bind_int64(stmt, idx, value) != c.SQLITE_OK) return error.BindFailed;
}

/// Enlaza un parámetro real/f64 (1-indexado). Para puntuaciones del router (§8).
pub fn bindDouble(stmt: *c.sqlite3_stmt, idx: c_int, value: f64) DbError!void {
    if (c.sqlite3_bind_double(stmt, idx, value) != c.SQLITE_OK) return error.BindFailed;
}

/// Enlaza un parámetro BLOB (1-indexado) con copia transitoria.
/// E5.15: vectores float32 little-endian en repo_embeddings.
pub fn bindBlob(stmt: *c.sqlite3_stmt, idx: c_int, bytes: []const u8) DbError!void {
    if (c.sqlite3_bind_blob(stmt, idx, bytes.ptr, @intCast(bytes.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.BindFailed;
}

// ── QA-A H1 (14-nov): migración serializada entre procesos ────────────────
//
// Reproducción de la QA: carpeta de datos nueva y 8 procesos de la CLI a la
// vez. Cada uno leía `user_version`, respaldaba y aplicaba migraciones con
// `exec` + `setUserVersion` sueltos: dos procesos aplicaban la misma migración
// (un `ALTER TABLE ADD COLUMN` dos veces), otro dejaba `user_version` por
// detrás de lo aplicado, y 7 de 8 salían con «No se pudo migrar runtime.db.»;
// a veces la base quedaba en la versión N con la N+1 ya aplicada en parte y no
// volvía a migrar nunca. Ahora: bloqueo exclusivo del SO sobre
// `<base>.migrate.lock` durante TODA la migración, `user_version` se relee
// bajo el bloqueo y cada migración va con su `user_version` en una
// transacción. Una base que ya quedó a medias se repara sola (ver
// `applyMigrationRepair`) o el error dice qué migración falló y por qué.

const CreateFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
}.CreateFileW else @import("providers").posix_files.CreateFileW;
const LockFileEx = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn LockFileEx(hFile: std.os.windows.HANDLE, dwFlags: u32, dwReserved: u32, nNumberOfBytesToLockLow: u32, nNumberOfBytesToLockHigh: u32, lpOverlapped: *Overlapped) callconv(.winapi) c_int;
}.LockFileEx else @import("providers").posix_files.LockFileEx;
const UnlockFileEx = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn UnlockFileEx(hFile: std.os.windows.HANDLE, dwReserved: u32, nNumberOfBytesToUnlockLow: u32, nNumberOfBytesToUnlockHigh: u32, lpOverlapped: *Overlapped) callconv(.winapi) c_int;
}.UnlockFileEx else @import("providers").posix_files.UnlockFileEx;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;

/// OVERLAPPED de Win32 (este fork no lo expone en std.os.windows).
const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?*anyopaque = null,
};
const LOCKFILE_FAIL_IMMEDIATELY: u32 = 0x1;
const LOCKFILE_EXCLUSIVE_LOCK: u32 = 0x2;
const ERROR_LOCK_VIOLATION: u32 = 33;
const ERROR_IO_PENDING: u32 = 997;
/// Espera máxima por el bloqueo de migración. Una migración real tarda
/// milisegundos (el respaldo, segundos con una base grande); pasado esto, el
/// otro proceso está colgado y se informa en vez de esperar para siempre.
pub const migrate_lock_wait_ms: u32 = 120_000;

/// Causa legible del último fallo de `Migrator.migrate` en este hilo: qué
/// paso o qué migración falló y el mensaje de SQLite. La lee el llamador
/// (CLI, motor) para no quedarse en «No se pudo migrar».
threadlocal var migrate_failure_buf: [1280]u8 = undefined;
threadlocal var migrate_failure_len: usize = 0;

pub fn migrateFailureText() []const u8 {
    if (migrate_failure_len == 0) return "sin detalle (el fallo no vino del migrador)";
    return migrate_failure_buf[0..migrate_failure_len];
}

fn setMigrateFailure(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&migrate_failure_buf, fmt, args) catch blk: {
        // Mensaje más largo que el búfer: se conserva el principio, marcado.
        const tail = "…";
        @memcpy(migrate_failure_buf[migrate_failure_buf.len - tail.len ..], tail);
        break :blk migrate_failure_buf[0..];
    };
    migrate_failure_len = s.len;
}

/// (resto): añade al fallo ya escrito la copia previa que se hizo
/// antes de migrar, para que quien lo lea sepa que sus datos están a salvo y
/// cómo volver atrás. Si no cabe entero, se conserva lo que quepa.
fn appendBackupToMigrateFailure(backup_path: []const u8, base_path: []const u8) void {
    const rest = migrate_failure_buf[migrate_failure_len..];
    const s = std.fmt.bufPrint(rest, ". Antes de migrar se guardó una copia en {s}: para volver atrás, cierra DevAgents y renómbrala sobre {s} (borra antes sus -wal y -shm si existen)", .{ backup_path, base_path }) catch rest;
    migrate_failure_len += s.len;
}

fn sqliteErrmsg(conn: Connection) []const u8 {
    const m = c.sqlite3_errmsg(conn.db);
    if (m == null) return "sin mensaje de SQLite";
    return std.mem.span(m);
}

/// Bloqueo exclusivo entre procesos (y entre conexiones del mismo proceso:
/// cada una abre su propio handle) sobre `<base>.migrate.lock`. Lo suelta el
/// SO si el proceso muere. El archivo se queda: no tiene datos y es inocuo.
const MigrateLock = struct {
    handle: std.os.windows.HANDLE,
    overlapped: Overlapped,

    fn acquire(allocator: std.mem.Allocator, base_path: []const u8) DbError!MigrateLock {
        const lock_path = try std.fmt.allocPrint(allocator, "{s}.migrate.lock", .{base_path});
        defer allocator.free(lock_path);
        const lock_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, lock_path) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => {
                setMigrateFailure("la ruta del bloqueo de migración no es UTF-8 válido: {s}", .{lock_path});
                return error.MigrateFailed;
            },
        };
        defer allocator.free(lock_w);
        const GENERIC_READ: u32 = 0x80000000;
        const GENERIC_WRITE: u32 = 0x40000000;
        const SHARE_ALL: u32 = 0x1 | 0x2 | 0x4;
        const OPEN_ALWAYS: u32 = 4;
        const h = CreateFileW(lock_w, GENERIC_READ | GENERIC_WRITE, SHARE_ALL, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (h == std.os.windows.INVALID_HANDLE_VALUE) {
            setMigrateFailure("no se pudo abrir el bloqueo de migración {s} (Win32 {d}); comprueba los permisos de la carpeta de datos", .{ lock_path, GetLastError() });
            return error.MigrateFailed;
        }
        var self = MigrateLock{ .handle = h, .overlapped = .{} };
        var waited: u32 = 0;
        while (LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &self.overlapped) == 0) {
            const code = GetLastError();
            if (code != ERROR_LOCK_VIOLATION and code != ERROR_IO_PENDING) {
                _ = CloseHandle(h);
                setMigrateFailure("no se pudo tomar el bloqueo de migración {s} (Win32 {d})", .{ lock_path, code });
                return error.MigrateFailed;
            }
            if (waited >= migrate_lock_wait_ms) {
                _ = CloseHandle(h);
                setMigrateFailure("otro proceso de DevAgents lleva más de {d} s migrando {s}; ciérralo y vuelve a intentarlo", .{ migrate_lock_wait_ms / 1000, base_path });
                return error.MigrateFailed;
            }
            Sleep(20);
            waited += 20;
        }
        return self;
    }

    fn release(self: *MigrateLock) void {
        // El cierre del handle también suelta el bloqueo; desbloquear antes lo
        // hace inmediato para el siguiente proceso que espera.
        _ = UnlockFileEx(self.handle, 0, 1, 0, &self.overlapped);
        _ = CloseHandle(self.handle);
    }
};

/// Parte `sql` en sentencias completas con `sqlite3_complete` (respeta
/// cadenas, comentarios y cuerpos `BEGIN … END` de los disparadores) y las
/// ejecuta en orden, comprobando IF NOT EXISTS antes del no-op de SQLite.
/// Solo al reparar se toleran columnas y objetos duplicados equivalentes.
fn applyMigrationStatements(conn: Connection, sql: []const u8, skipped: *usize, repair: bool) DbError!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        if (sql[i] != ';') continue;
        const candidate = try conn.allocator.dupeZ(u8, sql[start .. i + 1]);
        defer conn.allocator.free(candidate);
        if (c.sqlite3_complete(candidate) == 0) continue;
        start = i + 1;
        try execRepairStatement(conn, candidate, skipped, repair);
    }
    const rest = std.mem.trim(u8, sql[start..], " \t\r\n");
    if (rest.len > 0) {
        const last = try conn.allocator.dupeZ(u8, rest);
        defer conn.allocator.free(last);
        try execRepairStatement(conn, last, skipped, repair);
    }
}

fn execRepairStatement(conn: Connection, stmt_z: [:0]const u8, skipped: *usize, repair: bool) DbError!void {
    // T12B B-3 (auditor 3): `CREATE … IF NOT EXISTS` sobre un objeto homónimo
    // devuelve SQLITE_OK sin comparar la definición. Se comprueba antes de
    // ejecutar, para que una base con el objeto equivocado no pase por reparada.
    if (try checkIfNotExistsCollision(conn, stmt_z)) {
        skipped.* += 1;
        return;
    }
    if (c.sqlite3_exec(conn.db, stmt_z, null, null, null) == c.SQLITE_OK) return;
    if (!repair) return error.ExecFailed;
    const msg = sqliteErrmsg(conn);
    const duplicate_column = std.mem.startsWith(u8, msg, "duplicate column name");
    if (duplicate_column or std.mem.endsWith(u8, msg, "already exists")) {
        // T12 B2: «ya existe» solo vale si lo que existe es lo que la
        // migración crearía; si no, la base no es la esperada y se dice.
        if (duplicate_column) try checkExistingColumn(conn, stmt_z) else try checkExistingObject(conn, stmt_z);
        skipped.* += 1;
        return;
    }
    return error.ExecFailed;
}

/// T12B B-3: nombre del objeto de un `CREATE … IF NOT EXISTS nombre`, o null
/// si la sentencia no tiene esa forma. Quita las comillas del identificador.
fn createIfNotExistsName(a: std.mem.Allocator, sql: []const u8) !?[]u8 {
    var it = std.mem.tokenizeAny(u8, stripLeadingNoise(sql), " \t\r\n(");
    if (!std.ascii.eqlIgnoreCase(it.next() orelse return null, "create")) return null;
    var word = it.next() orelse return null;
    while (std.ascii.eqlIgnoreCase(word, "unique") or std.ascii.eqlIgnoreCase(word, "temp") or std.ascii.eqlIgnoreCase(word, "temporary")) {
        word = it.next() orelse return null;
    }
    if (!(std.ascii.eqlIgnoreCase(word, "table") or std.ascii.eqlIgnoreCase(word, "index") or
        std.ascii.eqlIgnoreCase(word, "trigger") or std.ascii.eqlIgnoreCase(word, "view"))) return null;
    if (!std.ascii.eqlIgnoreCase(it.next() orelse return null, "if")) return null;
    if (!std.ascii.eqlIgnoreCase(it.next() orelse return null, "not")) return null;
    if (!std.ascii.eqlIgnoreCase(it.next() orelse return null, "exists")) return null;
    const name = std.mem.trim(u8, it.next() orelse return null, "\"`[]");
    if (name.len == 0) return null;
    return try a.dupe(u8, name);
}

/// T12B B-3: si la sentencia es un `CREATE … IF NOT EXISTS` y el objeto ya
/// está en `sqlite_master`, compara su definición (falla si difiere) y
/// devuelve true para que el llamador no lo dé por aplicado sin mirar.
fn checkIfNotExistsCollision(conn: Connection, stmt: []const u8) DbError!bool {
    const a = conn.allocator;
    const name = (try createIfNotExistsName(a, stmt)) orelse return false;
    defer a.free(name);
    const q = try conn.prepare("SELECT 1 FROM sqlite_master WHERE name = ? COLLATE NOCASE AND sql IS NOT NULL");
    defer conn.finalize(q);
    try bindText(q, 1, name);
    if (c.sqlite3_step(q) != c.SQLITE_ROW) return false;
    try checkExistingObject(conn, stmt);
    return true;
}

/// T12 B2: causa del último desacuerdo de esquema encontrado al reparar (la
/// lee `applyOne` para el mensaje de fallo en vez del «already exists»).
threadlocal var repair_mismatch_buf: [640]u8 = undefined;
threadlocal var repair_mismatch_len: usize = 0;

fn setRepairMismatch(comptime fmt: []const u8, args: anytype) DbError {
    const text = std.fmt.bufPrint(&repair_mismatch_buf, fmt, args) catch blk: {
        const tail = "…";
        @memcpy(repair_mismatch_buf[repair_mismatch_buf.len - tail.len ..], tail);
        break :blk repair_mismatch_buf[0..];
    };
    repair_mismatch_len = text.len;
    return error.MigrateFailed;
}

/// Quita comentarios `--` y espacios del principio de una sentencia.
fn stripLeadingNoise(sql: []const u8) []const u8 {
    var rest = sql;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t\r\n");
        if (!std.mem.startsWith(u8, rest, "--")) return rest;
        const eol = std.mem.indexOfScalar(u8, rest, '\n') orelse return rest[rest.len..];
        rest = rest[eol + 1 ..];
    }
}

/// Forma comparable de una sentencia CREATE: minúsculas, sin `IF NOT
/// EXISTS`, sin comillas de identificador, espacios colapsados y sin
/// espacios junto a la puntuación, sin `;` final. Es la normalización que
/// SQLite aplica a `sqlite_master.sql` más la del texto de la migración.
fn normalizeCreateSql(a: std.mem.Allocator, sql: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pending_space = false;
    for (stripLeadingNoise(sql)) |raw| {
        const ch = std.ascii.toLower(raw);
        if (ch == '"' or ch == '`' or ch == '[' or ch == ']') continue;
        if (std.ascii.isWhitespace(ch)) {
            pending_space = out.items.len > 0;
            continue;
        }
        const punct = std.mem.indexOfScalar(u8, "(),;=", ch) != null;
        if (pending_space and !punct and !(out.items.len > 0 and std.mem.indexOfScalar(u8, "(,=", out.items[out.items.len - 1]) != null))
            try out.append(a, ' ');
        pending_space = false;
        try out.append(a, ch);
    }
    while (out.items.len > 0 and (out.items[out.items.len - 1] == ';' or out.items[out.items.len - 1] == ' ')) out.items.len -= 1;
    const text = try out.toOwnedSlice(a);
    defer a.free(text);
    const needle = " if not exists";
    if (std.mem.indexOf(u8, text, needle)) |at| return std.mem.concat(a, u8, &.{ text[0..at], text[at + needle.len ..] });
    return a.dupe(u8, text);
}

/// Nombre del objeto de un `CREATE [UNIQUE|TEMP] TABLE|INDEX|TRIGGER|VIEW
/// [IF NOT EXISTS] nombre` ya normalizado, o null si no es esa forma.
fn createdObjectName(normalized: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, normalized, " (");
    if (!std.mem.eql(u8, it.next() orelse return null, "create")) return null;
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, "unique") or std.mem.eql(u8, word, "temp") or std.mem.eql(u8, word, "temporary")) continue;
        if (!(std.mem.eql(u8, word, "table") or std.mem.eql(u8, word, "index") or std.mem.eql(u8, word, "trigger") or std.mem.eql(u8, word, "view"))) return null;
        return it.next();
    }
    return null;
}

fn checkExistingObject(conn: Connection, stmt: []const u8) DbError!void {
    const a = conn.allocator;
    const wanted = try normalizeCreateSql(a, stmt);
    defer a.free(wanted);
    const name = createdObjectName(wanted) orelse
        return setRepairMismatch("la sentencia «{s}» choca con un objeto que ya existe y no se puede comprobar qué es", .{wanted[0..@min(wanted.len, 160)]});
    const q = try conn.prepare("SELECT sql FROM sqlite_master WHERE lower(name) = ? AND sql IS NOT NULL");
    defer conn.finalize(q);
    try bindText(q, 1, name);
    if (c.sqlite3_step(q) != c.SQLITE_ROW)
        return setRepairMismatch("«{s}» dice que ya existe, pero no está en sqlite_master con su definición", .{name});
    const stored_raw = c.sqlite3_column_text(q, 0);
    const stored_len: usize = @intCast(c.sqlite3_column_bytes(q, 0));
    const stored = try normalizeCreateSql(a, if (stored_raw) |ptr| ptr[0..stored_len] else "");
    defer a.free(stored);
    if (!std.mem.eql(u8, stored, wanted))
        return setRepairMismatch("«{s}» ya existe con otra definición (en la base: «{s}»; la migración espera: «{s}»)", .{ name, stored[0..@min(stored.len, 200)], wanted[0..@min(wanted.len, 200)] });
}

/// Definición de la columna de un `ALTER TABLE t ADD [COLUMN] col tipo ...`.
const ColumnSpec = struct { table: []const u8, column: []const u8, decl_type: []const u8, not_null: bool, default: ?[]const u8 };

fn parseAddColumn(normalized: []const u8) ?ColumnSpec {
    var it = std.mem.tokenizeScalar(u8, normalized, ' ');
    if (!std.mem.eql(u8, it.next() orelse return null, "alter")) return null;
    if (!std.mem.eql(u8, it.next() orelse return null, "table")) return null;
    const table = it.next() orelse return null;
    if (!std.mem.eql(u8, it.next() orelse return null, "add")) return null;
    var column = it.next() orelse return null;
    if (std.mem.eql(u8, column, "column")) column = it.next() orelse return null;
    // Tipo: hasta la primera palabra de restricción.
    const rest_start = it.index;
    var type_end = rest_start;
    var spec = ColumnSpec{ .table = table, .column = column, .decl_type = "", .not_null = false, .default = null };
    while (it.next()) |word| {
        const keyword = for ([_][]const u8{ "not", "null", "default", "primary", "unique", "check", "references", "collate", "generated", "constraint", "as" }) |k| {
            if (std.mem.eql(u8, word, k) or std.mem.startsWith(u8, word, "check(") or std.mem.startsWith(u8, word, "default(")) break true;
        } else false;
        if (keyword) {
            const tail = normalized[it.index - word.len ..];
            spec.not_null = std.mem.indexOf(u8, tail, "not null") != null;
            if (std.mem.indexOf(u8, tail, "default")) |at| {
                const value = std.mem.trimStart(u8, tail[at + "default".len ..], " ");
                const end = if (value.len > 0 and value[0] == '(') (std.mem.indexOfScalar(u8, value, ')') orelse value.len - 1) + 1 else std.mem.indexOfScalar(u8, value, ' ') orelse value.len;
                spec.default = value[0..end];
            }
            break;
        }
        type_end = it.index;
    }
    spec.decl_type = std.mem.trim(u8, normalized[rest_start..type_end], " ");
    return spec;
}

fn checkExistingColumn(conn: Connection, stmt: []const u8) DbError!void {
    const a = conn.allocator;
    const wanted = try normalizeCreateSql(a, stmt);
    defer a.free(wanted);
    const spec = parseAddColumn(wanted) orelse
        return setRepairMismatch("la sentencia «{s}» choca con una columna que ya existe y no se puede comprobar cuál", .{wanted[0..@min(wanted.len, 160)]});
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT type, \"notnull\", dflt_value FROM pragma_table_info('{s}') WHERE lower(name) = ?", .{spec.table}, 0);
    defer a.free(sql);
    if (std.mem.indexOfAny(u8, spec.table, "'\\") != null) return setRepairMismatch("nombre de tabla no admitido en la reparación: {s}", .{spec.table});
    const q = try conn.prepare(sql);
    defer conn.finalize(q);
    try bindText(q, 1, spec.column);
    if (c.sqlite3_step(q) != c.SQLITE_ROW)
        return setRepairMismatch("la columna {s}.{s} dice que ya existe, pero pragma table_info no la muestra", .{ spec.table, spec.column });
    const type_raw = c.sqlite3_column_text(q, 0);
    const type_text = if (type_raw) |ptr| ptr[0..@intCast(c.sqlite3_column_bytes(q, 0))] else "";
    const not_null = c.sqlite3_column_int(q, 1) != 0;
    const dflt_raw = c.sqlite3_column_text(q, 2);
    const dflt: ?[]const u8 = if (dflt_raw) |ptr| ptr[0..@intCast(c.sqlite3_column_bytes(q, 2))] else null;
    const same_type = std.ascii.eqlIgnoreCase(std.mem.trim(u8, type_text, " "), spec.decl_type);
    const same_default = if (spec.default) |want| (if (dflt) |have| std.ascii.eqlIgnoreCase(std.mem.trim(u8, have, " "), want) else false) else dflt == null;
    if (!same_type or not_null != spec.not_null or !same_default)
        return setRepairMismatch("la columna {s}.{s} ya existe con otra definición (en la base: tipo «{s}», NOT NULL {s}, DEFAULT {s}; la migración espera: tipo «{s}», NOT NULL {s}, DEFAULT {s})", .{
            spec.table,                    spec.column,
            type_text,
            if (not_null) "sí" else "no",
            dflt orelse "ninguno",         spec.decl_type,
            if (spec.not_null) "sí" else "no",
            spec.default orelse "ninguno",
        });
}

/// Migrador de esquemas: aplica migraciones secuenciales idempotentes.
pub const Migrator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Migrator {
        return .{ .allocator = allocator };
    }

    /// Aplica migraciones pendientes. Cada migración es una función que recibe Connection.
    ///
    /// si hay al menos una migración pendiente y la base ya existe
    /// y tiene estructura (alguna tabla), primero se respalda con `VACUUM INTO`
    /// (ver `backupBeforePendingMigrations`). Si la copia falla, se devuelve
    /// error.BackupFailed y NO se aplica ninguna migración; si la poda no puede
    /// garantizar la retención (r2), error.BackupRetentionFailed y tampoco se
    /// aplica ninguna migración.
    ///
    /// QA-A H1: todo ocurre bajo el bloqueo `<base>.migrate.lock` (bases en
    /// archivo) y cada migración se aplica con su `user_version` en una
    /// transacción. Si falla, `migrateFailureText()` dice cuál y por qué.
    pub fn migrate(self: Migrator, conn: Connection, migrations: []const []const u8) DbError!void {
        migrate_failure_len = 0;
        var lock: ?MigrateLock = if (conn.path) |p| try MigrateLock.acquire(self.allocator, p) else null;
        defer if (lock) |*l| l.release();

        // Se lee BAJO el bloqueo: otro proceso pudo terminar de migrar
        // mientras este esperaba, y entonces no queda nada pendiente.
        const current = conn.getUserVersion() catch |e| {
            setMigrateFailure("no se pudo leer la versión del esquema: {s}", .{sqliteErrmsg(conn)});
            return e;
        };
        if (current < 0) {
            setMigrateFailure("versión de esquema negativa ({d}): la base no es de DevAgents o está dañada", .{current});
            return error.MigrateFailed;
        }
        if (current > migrations.len) {
            setMigrateFailure("la base está en el esquema v{d} y este programa solo conoce hasta v{d}: la creó una versión más nueva de DevAgents", .{ current, migrations.len });
            return error.DbSchemaAhead;
        }
        var backup_path: ?[]u8 = null;
        defer if (backup_path) |p| self.allocator.free(p);
        if (current < migrations.len) {
            backup_path = backupBeforePendingMigrations(self.allocator, conn, @intCast(current)) catch |e| {
                switch (e) {
                    error.BackupFailed => setMigrateFailure("no se pudo hacer la copia de seguridad previa (VACUUM INTO): {s}. No se aplicó ninguna migración; libera espacio o revisa los permisos y el antivirus", .{sqliteErrmsg(conn)}),
                    error.BackupRetentionFailed => setMigrateFailure("se hizo la copia previa pero no se pudieron borrar las copias viejas (<base>.bak-v*); no se aplicó ninguna migración", .{}),
                    else => setMigrateFailure("la copia de seguridad previa falló ({s}); no se aplicó ninguna migración", .{@errorName(e)}),
                }
                return e;
            };
        }
        var i: usize = @intCast(current);
        while (i < migrations.len) : (i += 1) {
            self.applyOne(conn, migrations, i) catch |e| {
                if (backup_path) |p| appendBackupToMigrateFailure(p, conn.path.?);
                return e;
            };
        }
    }

    /// Aplica la migración `i` (0-based; deja `user_version = i + 1`) dentro de
    /// una transacción. Si falla, se deshace y se intenta UNA reparación de
    /// una base que quedó a medias (la migración ya estaba aplicada en parte
    /// por un arranque concurrente antiguo); si tampoco, error con causa.
    fn applyOne(self: Migrator, conn: Connection, migrations: []const []const u8, i: usize) DbError!void {
        _ = self;
        const version: i32 = @intCast(i + 1);
        const nested = c.sqlite3_get_autocommit(conn.db) == 0;
        const begin_sql = if (nested) "SAVEPOINT da_migrate" else "BEGIN IMMEDIATE";
        const commit_sql = if (nested) "RELEASE da_migrate" else "COMMIT";
        const rollback_sql = if (nested) "ROLLBACK TO da_migrate; RELEASE da_migrate" else "ROLLBACK";

        conn.exec(begin_sql) catch |e| {
            setMigrateFailure("no se pudo abrir la transacción de la migración {d} de {d}: {s}", .{ version, migrations.len, sqliteErrmsg(conn) });
            return e;
        };
        var checked: usize = 0;
        if (applyMigrationStatements(conn, migrations[i], &checked, false)) |_| {
            try commitVersion(conn, version, commit_sql, rollback_sql, migrations.len);
            return;
        } else |_| {}

        // Primer intento fallido: se guarda la causa y se deshace todo.
        var first_buf: [384]u8 = undefined;
        const first = std.fmt.bufPrint(&first_buf, "{s}", .{sqliteErrmsg(conn)}) catch first_buf[0..];
        conn.exec(rollback_sql) catch {
            setMigrateFailure("falló la migración {d} de {d} ({s}) y además no se pudo deshacer: {s}", .{ version, migrations.len, first, sqliteErrmsg(conn) });
            return error.MigrateFailed;
        };

        // Reparación: sentencia a sentencia, dando por aplicadas las que ya
        // están en la base. Si la causa era otra, falla igual y se informa.
        conn.exec(begin_sql) catch |e| {
            setMigrateFailure("falló la migración {d} de {d} ({s}) y no se pudo reintentar: {s}", .{ version, migrations.len, first, sqliteErrmsg(conn) });
            return e;
        };
        var skipped: usize = 0;
        repair_mismatch_len = 0;
        applyMigrationStatements(conn, migrations[i], &skipped, true) catch {
            // T12 B2: un objeto que ya existía con otra definición se dice tal cual.
            const repair_msg = if (repair_mismatch_len > 0) repair_mismatch_buf[0..repair_mismatch_len] else sqliteErrmsg(conn);
            var repair_buf: [384]u8 = undefined;
            const repair = std.fmt.bufPrint(&repair_buf, "{s}", .{repair_msg}) catch repair_buf[0..];
            conn.exec(rollback_sql) catch |e| std.log.err("migración {d}: no se pudo deshacer la reparación: {s}", .{ version, @errorName(e) });
            setMigrateFailure("falló la migración {d} de {d}: {s}. La base sigue en la versión {d} sin cambios", .{ version, migrations.len, repair, version - 1 });
            return error.MigrateFailed;
        };
        if (skipped == 0) {
            // Sin nada que dar por aplicado, la reparación no es tal: el
            // primer fallo fue transitorio (p. ej. base ocupada) y ahora
            // pasó. Se acepta igual: la migración entera se aplicó.
            std.log.info("migración {d}: aplicada al segundo intento (antes: {s})", .{ version, first });
        } else {
            std.log.warn("migración {d}: estaba aplicada en parte ({d} sentencia(s) ya presentes, causa: {s}); se completó", .{ version, skipped, first });
        }
        try commitVersion(conn, version, commit_sql, rollback_sql, migrations.len);
    }

    fn commitVersion(conn: Connection, version: i32, commit_sql: []const u8, rollback_sql: []const u8, total: usize) DbError!void {
        conn.setUserVersion(version) catch |e| {
            setMigrateFailure("no se pudo fijar la versión {d} de {d}: {s}", .{ version, total, sqliteErrmsg(conn) });
            conn.exec(rollback_sql) catch |re| std.log.err("migración {d}: no se pudo deshacer: {s}", .{ version, @errorName(re) });
            return e;
        };
        conn.exec(commit_sql) catch |e| {
            setMigrateFailure("no se pudo confirmar la migración {d} de {d}: {s}", .{ version, total, sqliteErrmsg(conn) });
            conn.exec(rollback_sql) catch |re| std.log.err("migración {d}: no se pudo deshacer: {s}", .{ version, @errorName(re) });
            return e;
        };
    }
};

// ── Esquemas ───────────────────────────────────────────────────────────

/// Esquema de runtime.db (órdenes, tareas, eventos).
pub const runtime_schema = [_][]const u8{
    // V1: Tablas base
    \\CREATE TABLE IF NOT EXISTS orders (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id TEXT NOT NULL,
    \\    user_prompt TEXT NOT NULL,
    \\    spec_ref TEXT,
    \\    status TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS tasks (
    \\    id INTEGER PRIMARY KEY,
    \\    plan_id INTEGER,
    \\    parent_task_id INTEGER,
    \\    department TEXT NOT NULL,
    \\    task_type TEXT NOT NULL,
    \\    description TEXT NOT NULL,
    \\    contract_id INTEGER,
    \\    assigned_model_id INTEGER,
    \\    worker_id INTEGER,
    \\    status TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS events (
    \\    id INTEGER PRIMARY KEY,
    \\    ts INTEGER NOT NULL,
    \\    source TEXT NOT NULL,
    \\    kind TEXT NOT NULL,
    \\    payload_json TEXT NOT NULL
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS workers (
    \\    id INTEGER PRIMARY KEY,
    \\    pid INTEGER NOT NULL,
    \\    backend TEXT NOT NULL,
    \\    sandbox_path TEXT NOT NULL,
    \\    status TEXT NOT NULL,
    \\    started_at INTEGER NOT NULL,
    \\    ended_at INTEGER
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS contracts (
    \\    id INTEGER PRIMARY KEY,
    \\    plan_id INTEGER,
    \\    name TEXT NOT NULL,
    \\    interface_spec TEXT NOT NULL,
    \\    consumers_json TEXT NOT NULL,
    \\    producers_json TEXT NOT NULL
    \\);
    ,
    // V6: Planes del superagente (entendimiento + clarificaciones + aprobación). T-F4-02.
    \\CREATE TABLE IF NOT EXISTS plans (
    \\    id INTEGER PRIMARY KEY,
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    understanding TEXT NOT NULL,
    \\    clarifications_json TEXT,
    \\    approved INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL
    \\);
    ,
    // V7: Carpetas vinculadas (mounts). T-F8-01.
    \\CREATE TABLE IF NOT EXISTS mounts (
    \\    id INTEGER PRIMARY KEY,
    \\    path TEXT NOT NULL UNIQUE,
    \\    added_at INTEGER NOT NULL,
    \\    active INTEGER NOT NULL DEFAULT 1
    \\);
    ,
    // V8: Webhooks entrantes/salientes. T-F8-04.
    \\CREATE TABLE IF NOT EXISTS webhooks (
    \\    id INTEGER PRIMARY KEY,
    \\    direction TEXT NOT NULL CHECK(direction IN ('in','out')),
    \\    url TEXT NOT NULL,
    \\    event TEXT NOT NULL,
    \\    secret_encrypted TEXT,
    \\    active INTEGER NOT NULL DEFAULT 1
    \\);
    ,
    // V9: Aprobaciones pendientes/resueltas (BACKLOG-IDE-REMOTE Fase 1).
    \\CREATE TABLE IF NOT EXISTS approvals (
    \\    id INTEGER PRIMARY KEY,
    \\    task_id TEXT NOT NULL,
    \\    description TEXT NOT NULL,
    \\    approved INTEGER NOT NULL DEFAULT 0,
    \\    resolved INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL
    \\);
    ,
    // V10: Salud de modelos (HEALTH-01) — telemetría de éxito/fallo por
    // (proveedor, modelo) para que el superagente elija modelos entitled+vivos.
    // status ∈ ok|empty|auth_failed|quota|rate_limited|error. La pueblan tanto
    // `health probe` (activo) como el registro pasivo de cada llamada real.
    \\CREATE TABLE IF NOT EXISTS model_health (
    \\    model_id TEXT PRIMARY KEY,
    \\    ok_count INTEGER NOT NULL DEFAULT 0,
    \\    err_count INTEGER NOT NULL DEFAULT 0,
    \\    timeout_count INTEGER NOT NULL DEFAULT 0,
    \\    last_ok_at INTEGER,
    \\    last_err_at INTEGER,
    \\    last_err_kind TEXT
    \\);
    ,
    // V11: Timeline de progreso (UX-08) — cada evento pertenece a una orden
    // para que la GUI muestre la narrativa por tarea sin leer toda la tabla.
    // DEFAULT 0 para registros históricos/CLI que no están ligados a una orden.
    \\ALTER TABLE events ADD COLUMN order_id INTEGER NOT NULL DEFAULT 0
    \\;
    ,
    // V12: Título derivado/renombrable por sesión (SESSIONS-PERSIST-06).
    \\ALTER TABLE orders ADD COLUMN title TEXT
    \\;
    ,
    // V13: Mensajes de conversación por sesión (SESSIONS-PERSIST-06).
    \\CREATE TABLE IF NOT EXISTS messages (
    \\    id INTEGER PRIMARY KEY,
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    role TEXT NOT NULL,
    \\    content TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_messages_order ON messages(order_id, created_at);
    ,
    // V14: Memoria local persistente (fallback) — ENGRAM-WIRE-07.
    \\CREATE TABLE IF NOT EXISTS memory_findings (
    \\    id INTEGER PRIMARY KEY,
    \\    content TEXT NOT NULL,
    \\    type TEXT NOT NULL DEFAULT 'discovery',
    \\    project TEXT NOT NULL DEFAULT '',
    \\    created_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_memory_findings_project ON memory_findings(project, created_at DESC);
    ,
    \\CREATE TABLE IF NOT EXISTS memory_sessions (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT,
    \\    summary TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_memory_sessions_created ON memory_sessions(created_at DESC);
    ,
    // V15: Prefix del comando que generó la aprobación (sistema de permisos P2).
    // Permite resolver con alcance "sesión/siempre" añadiendo el prefix al allowlist.
    \\ALTER TABLE approvals ADD COLUMN command_prefix TEXT
    \\;
    ,
    // V16: P-EXEC-4 — campos para re-ejecutar comando al aprobar + vincular orden.
    \\ALTER TABLE approvals ADD COLUMN exe TEXT
    \\;
    ,
    \\ALTER TABLE approvals ADD COLUMN args_json TEXT
    \\;
    ,
    \\ALTER TABLE approvals ADD COLUMN order_id INTEGER NOT NULL DEFAULT 0
    \\;
    ,
    // V17: Token usage tracking (P08) — una fila por llamada LLM con tokens consumidos.
    // Se escribe desde el hilo de dispatch (como events) y se lee desde el hilo principal.
    \\CREATE TABLE IF NOT EXISTS usage_records (
    \\    id INTEGER PRIMARY KEY,
    \\    order_id INTEGER NOT NULL DEFAULT 0,
    \\    worker_id TEXT NOT NULL DEFAULT '',
    \\    provider TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    \\    completion_tokens INTEGER NOT NULL DEFAULT 0,
    \\    total_tokens INTEGER NOT NULL DEFAULT 0,
    \\    timestamp INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_usage_records_order ON usage_records(order_id);
    \\CREATE INDEX IF NOT EXISTS idx_usage_records_model ON usage_records(provider, model);
    ,
    // V18: D1 — artifact_path en tasks para persistir la ruta del archivo generado.
    //     Se actualiza desde runTaskInWave tras persistTask. Permite a la GUI
    //     listar artefactos por orden sin escanear el filesystem.
    \\ALTER TABLE tasks ADD COLUMN artifact_path TEXT
    ,
    // V19: tool_scores — P12-T5 learning: record (tool_name, task_type) success/failure.
    //     Moving average score like model_scores; used to weight pre-filter candidates.
    \\CREATE TABLE IF NOT EXISTS tool_scores (
    \\    tool_name TEXT NOT NULL,
    \\    task_type TEXT NOT NULL,
    \\    score REAL NOT NULL CHECK(score >= 0.0 AND score <= 1.0),
    \\    sample_count INTEGER NOT NULL DEFAULT 0 CHECK(sample_count >= 0),
    \\    updated_at INTEGER,
    \\    PRIMARY KEY (tool_name, task_type)
    \\);
    ,
    // V20: conversation_id en orders (loop agéntico, FASE 1) — agrupa órdenes
    // sucesivas de la misma conversación para que el planner recupere el
    // historial REAL (mensajes con resultados) en vez de depender solo del
    // ring buffer en RAM (que se pierde al reiniciar el motor y no distingue
    // entre conversaciones distintas). NULL = orden sin conversación explícita
    // (compat con clientes viejos que no la envían).
    \\ALTER TABLE orders ADD COLUMN conversation_id TEXT
    ,
    // Posición #24 (no "V21": los comentarios de versión de este arreglo llevan
    // tiempo desalineados de su índice real — contar elementos es la única fuente
    // de verdad, no el último número de comentario). TERMINAL-STATE-DESIGN-2026-07-12:
    // limpia duplicados históricos de eventos terminales (conserva MIN(id) por
    // order_id) y añade un índice único parcial que hace de la DB la autoridad
    // para "el primer terminal gana". Solo cubre order_done/order_failed/
    // order_cancelled — dispatch_failed no es terminal y queda fuera a propósito.
    \\DELETE FROM events
    \\WHERE kind IN ('order_done','order_failed','order_cancelled')
    \\  AND id NOT IN (
    \\    SELECT MIN(id) FROM events
    \\    WHERE kind IN ('order_done','order_failed','order_cancelled')
    \\    GROUP BY order_id
    \\  );
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_events_terminal_order
    \\    ON events(order_id)
    \\    WHERE kind IN ('order_done','order_failed','order_cancelled')
    ,
    // V21: Tabla spaces (T5)
    \\CREATE TABLE IF NOT EXISTS spaces (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id TEXT NOT NULL,
    \\    kind TEXT NOT NULL CHECK(kind IN ('order','main-checkout')),
    \\    name TEXT NOT NULL,
    \\    worktree_path TEXT NOT NULL,
    \\    branch TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    archived_at INTEGER
    \\);
    ,
    // V22: Tabla turns (T5)
    \\CREATE TABLE IF NOT EXISTS turns (
    \\    id INTEGER PRIMARY KEY,
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    status TEXT NOT NULL CHECK(status IN ('running','interrupted','resumable','completed')),
    \\    checkpoint_json TEXT NOT NULL,
    \\    started_at INTEGER NOT NULL,
    \\    ended_at INTEGER
    \\);
    ,
    // V23: Tabla pull_requests (T5)
    \\CREATE TABLE IF NOT EXISTS pull_requests (
    \\    id INTEGER PRIMARY KEY,
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    provider TEXT NOT NULL,
    \\    repo TEXT NOT NULL,
    \\    number INTEGER NOT NULL,
    \\    state TEXT NOT NULL CHECK(state IN ('none','ahead','open','ci_running','mergeable','merged','failed')),
    \\    url TEXT NOT NULL,
    \\    last_polled_at INTEGER NOT NULL
    \\);
    ,
    // V24: Columnas space_id y parent_order_id en orders (T5)
    \\ALTER TABLE orders ADD COLUMN space_id INTEGER REFERENCES spaces(id)
    ,
    \\ALTER TABLE orders ADD COLUMN parent_order_id INTEGER REFERENCES orders(id)
    ,
    // V25: H6 - tokens servidos desde la cache del proveedor.
    //
    // Sin esta columna el prompt caching es indemostrable: `prompt_tokens`
    // sale igual acierte o no la cache (el proveedor cobra menos, pero
    // cuenta los mismos tokens). Es el numerador de la unica cifra que
    // aqui importa: cuanto del prompt no hubo que volver a procesar.
    \\ALTER TABLE usage_records ADD COLUMN cached_tokens INTEGER NOT NULL DEFAULT 0
    ,
    // V26: H8 - la salud deja de ser del MODELO y pasa a ser del par
    // (modelo, clave).
    //
    // El usuario tiene tres claves de Gemini: dos de pago y una degradada. Con
    // `model_id` como clave primaria, los fallos de la mala se sumaban en la
    // MISMA fila que los aciertos de las buenas, y el router condenaba el
    // modelo para las tres. No habia forma de expresar "este modelo funciona
    // con esta clave y no con aquella", que es exactamente lo que pasa cuando
    // una clave no cubre el modelo (401) o se le agoto la cuota (429).
    //
    // Las filas historicas se conservan con key_label = '' : siguen contando
    // como evidencia, pero sin atribuir a nadie. La reconstruccion es
    // obligatoria porque no se puede quitar una PRIMARY KEY con ALTER.
    \\CREATE TABLE IF NOT EXISTS _model_health_v2 (
    \\    model_id TEXT NOT NULL,
    \\    key_label TEXT NOT NULL DEFAULT '',
    \\    ok_count INTEGER NOT NULL DEFAULT 0,
    \\    err_count INTEGER NOT NULL DEFAULT 0,
    \\    timeout_count INTEGER NOT NULL DEFAULT 0,
    \\    last_ok_at INTEGER,
    \\    last_err_at INTEGER,
    \\    last_err_kind TEXT,
    \\    PRIMARY KEY (model_id, key_label)
    \\);
    \\INSERT INTO _model_health_v2 (model_id, key_label, ok_count, err_count, timeout_count, last_ok_at, last_err_at, last_err_kind)
    \\    SELECT model_id, '', ok_count, err_count, timeout_count, last_ok_at, last_err_at, last_err_kind FROM model_health;
    \\DROP TABLE model_health;
    \\ALTER TABLE _model_health_v2 RENAME TO model_health;
    ,
    // V27: D8 - rondas de clarificación consumidas por orden.
    //
    // El planner puede responder kind:"clarify" con preguntas estructuradas en
    // vez de planificar a ciegas. Sin contador persistido, una orden podía
    // ciclar clarificaciones indefinidamente (cada LlmPlanner nace nuevo por
    // llamada). El tope (2) se enforce en el planner; esta columna es la
    // memoria del conteo entre respuestas y entre reinicios de la cabina.
    \\ALTER TABLE orders ADD COLUMN clarify_rounds INTEGER NOT NULL DEFAULT 0
    ,
    // SEMANTIC-GATE-T3: observable declarado de la orden (JSON array de
    // aserciones — ver semantic_gate.zig). NULL = nada declarado: el gate
    // semántico informa ran:false y no altera el veredicto del gate de
    // ejecución. Lo escribe da_order_set_expected o queda derivado del plan
    // (contract field 'expects' por tarea) si la columna está vacía.
    \\ALTER TABLE orders ADD COLUMN expected_result TEXT
    ,
    // V28: E1.19 — la clave que sirvió la llamada, por fila de uso.
    //
    // Sin ella, `usage_records` decía QUÉ modelo gastó tokens pero no CON QUÉ
    // cuenta: con varias claves por proveedor en rotación, un 401 o una cuota
    // agotada no se podía atribuir a la clave que lo causó. La etiqueta ya se
    // propagaba a `Live.key_label` y a los eventos task_provider_ok; ahora la
    // fila de uso también la conserva. Filas históricas: ''.
    \\ALTER TABLE usage_records ADD COLUMN key_label TEXT NOT NULL DEFAULT ''
    ,
    // V29: E5.04/ — concesiones de script de setup por (proyecto, hash).
    //
    // El script de preparación del worktree corre una vez aprobado por el
    // usuario; la concesión queda ligada a los BYTES aprobados (sha256 del
    // archivo), no a la ruta: si el script cambia, el hash deja de estar
    // concedido y vuelve a pedirse aprobación. La petición pendiente vive en
    // `approvals` con command_prefix 'worktree_script'; esta tabla guarda la
    // resolución aprobada para las siguientes órdenes del mismo proyecto.
    \\CREATE TABLE IF NOT EXISTS worktree_script_approvals (
    \\    project_id TEXT NOT NULL,
    \\    script_sha256 TEXT NOT NULL,
    \\    script_path TEXT NOT NULL,
    \\    approved_at INTEGER NOT NULL,
    \\    PRIMARY KEY (project_id, script_sha256)
    \\)
    ,
    // V30: E5.08 — categoría de coste por fila de uso. Los agentes externos
    // corren sobre la suscripción del usuario (cost_category='subscription'):
    // tokens solo si el agente los informa, dólares nulos (nunca inventados).
    // El contable de escaladas (emitAuxEscalations) distingue así una
    // suscripción de una llamada de API de pago. Filas históricas: 'api'.
    \\ALTER TABLE usage_records ADD COLUMN cost_category TEXT NOT NULL DEFAULT 'api'
    ,
    // V31: E5.13 (D-C3) — caché del repo-map por (raíz, HEAD, configuración).
    //     Guarda el grafo serializado (símbolos + aristas, nunca ranks: el
    //     PageRank es por consulta). La clave config es un sha256 de los topes
    //     del escaneo para que presupuestos distintos no colisionen.
    \\CREATE TABLE IF NOT EXISTS repo_map_cache (
    \\    repo_root TEXT NOT NULL,
    \\    head TEXT NOT NULL,
    \\    config TEXT NOT NULL,
    \\    built_at INTEGER NOT NULL,
    \\    files_count INTEGER NOT NULL,
    \\    symbols_count INTEGER NOT NULL,
    \\    map_json TEXT NOT NULL,
    \\    PRIMARY KEY (repo_root, head, config)
    \\)
    ,
    // V32: E5.15 (A-a) — índice de embeddings por trozo de código. Un vector
    //     float32 little-endian por (repo, ruta, hash del trozo, modelo): el
    //     hash (sha256 hex del texto del chunk) hace el índice incremental —
    //     solo se re-embeben los trozos cuyo contenido cambió; el modelo forma
    //     parte de la clave porque vectores de modelos distintos no se mezclan.
    \\CREATE TABLE IF NOT EXISTS repo_embeddings (
    \\    repo_root TEXT NOT NULL,
    \\    path TEXT NOT NULL,
    \\    chunk_hash TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    dim INTEGER NOT NULL,
    \\    vec BLOB NOT NULL,
    \\    embedded_at INTEGER NOT NULL,
    \\    PRIMARY KEY (repo_root, path, chunk_hash, model)
    \\)
    ,
    // V33: E5.18 (D-C5) — Best-of-N. La orden padre lleva best_of_n (0=apagado,
    //     2..4 = N candidatas) y best_of_n_members (JSON explícito opcional
    //     [{provider,model}]; null = se toman del enjambre fijado al aprobar).
    \\ALTER TABLE orders ADD COLUMN best_of_n INTEGER NOT NULL DEFAULT 0
    ,
    \\ALTER TABLE orders ADD COLUMN best_of_n_members TEXT
    ,
    // Una fila por candidata: hija real de la orden padre (child_order_id) con
    //     su space propio (orden-<padre>-m<k>) y sus métricas para el ranking
    //     determinista. rank NULL = aún sin posición (o empate no resuelto).
    \\CREATE TABLE IF NOT EXISTS best_of_n_candidates (
    \\    id INTEGER PRIMARY KEY,
    \\    parent_order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    member_idx INTEGER NOT NULL,
    \\    provider TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    child_order_id INTEGER,
    \\    space_id INTEGER,
    \\    plan_id INTEGER,
    \\    status TEXT NOT NULL DEFAULT 'pending',
    \\    gates_pass INTEGER NOT NULL DEFAULT 0,
    \\    gates_fail INTEGER NOT NULL DEFAULT 0,
    \\    tests_pass INTEGER NOT NULL DEFAULT 0,
    \\    tests_fail INTEGER NOT NULL DEFAULT 0,
    \\    audit_verdict TEXT,
    \\    cost_tokens INTEGER,
    \\    elapsed_ms INTEGER NOT NULL DEFAULT 0,
    \\    rank INTEGER,
    \\    chosen INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL
    \\)
    ,
    \\CREATE INDEX IF NOT EXISTS idx_bon_cands_parent ON best_of_n_candidates(parent_order_id)
    ,
    // E5.23: adjuntos inmutables por digest, separados del contenido de la orden.
    \\CREATE TABLE IF NOT EXISTS order_attachments (
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
    \\    name TEXT NOT NULL,
    \\    mime_type TEXT NOT NULL CHECK(mime_type IN ('image/png','image/jpeg','image/webp')),
    \\    extension TEXT NOT NULL CHECK(extension IN ('png','jpg','webp')),
    \\    size_bytes INTEGER NOT NULL CHECK(size_bytes > 0 AND size_bytes <= 5242880),
    \\    width INTEGER NOT NULL CHECK(width BETWEEN 1 AND 8192),
    \\    height INTEGER NOT NULL CHECK(height BETWEEN 1 AND 8192),
    \\    relative_path TEXT NOT NULL,
    \\    PRIMARY KEY(order_id, sha256),
    \\    CHECK(width * height <= 33554432)
    \\);
    \\CREATE TRIGGER IF NOT EXISTS order_attachments_limit BEFORE INSERT ON order_attachments
    \\WHEN NOT EXISTS(SELECT 1 FROM order_attachments WHERE order_id=NEW.order_id AND sha256=NEW.sha256)
    \\AND (SELECT COUNT(*) FROM order_attachments WHERE order_id=NEW.order_id) >= 4
    \\BEGIN SELECT RAISE(ABORT, 'attachment limit'); END;
    \\CREATE TRIGGER IF NOT EXISTS order_attachments_order BEFORE INSERT ON order_attachments
    \\WHEN NOT EXISTS(SELECT 1 FROM orders WHERE id=NEW.order_id)
    \\BEGIN SELECT RAISE(ABORT, 'attachment order missing'); END;
    ,
    // E5.29: transactional outgoing notifications. Only fixed state/id data,
    // never prompts, model output, URL credentials or plaintext secrets.
    \\ALTER TABLE webhooks ADD COLUMN format TEXT NOT NULL DEFAULT 'json' CHECK(format IN ('json','ntfy'));
    \\CREATE TABLE webhook_outbox (
    \\ id INTEGER PRIMARY KEY AUTOINCREMENT, webhook_id INTEGER NOT NULL,
    \\ order_id INTEGER NOT NULL DEFAULT 0, event TEXT NOT NULL,
    \\ attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3),
    \\ state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','sending','sent','failed')),
    \\ next_at INTEGER NOT NULL DEFAULT 0, last_error TEXT
    \\);
    \\CREATE INDEX webhook_outbox_pending ON webhook_outbox(state,next_at);
    \\CREATE TABLE order_notifications (id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL, state TEXT NOT NULL);
    \\CREATE TRIGGER webhook_order_transition AFTER UPDATE OF status ON orders
    \\WHEN OLD.status <> NEW.status AND NEW.status IN ('awaiting_approval','done','failed','audit_unavailable')
    \\BEGIN
    \\ INSERT INTO order_notifications(order_id,state) VALUES(NEW.id,NEW.status);
    \\ INSERT INTO webhook_outbox(webhook_id,order_id,event)
    \\ SELECT id,NEW.id,NEW.status FROM webhooks WHERE direction='out' AND active=1 AND (event='*' OR event=NEW.status);
    \\END;
    \\CREATE TRIGGER webhook_budget_transition AFTER INSERT ON events
    \\WHEN NEW.kind='budget_blocked_v1'
    \\BEGIN
    \\ INSERT INTO order_notifications(order_id,state) VALUES(COALESCE(NEW.order_id,0),'budget_blocked');
    \\ INSERT INTO webhook_outbox(webhook_id,order_id,event)
    \\ SELECT id,COALESCE(NEW.order_id,0),'budget_blocked' FROM webhooks WHERE direction='out' AND active=1 AND (event='*' OR event='budget_blocked');
    \\END;
    ,
    // V45: E5.29 / E-B9.1 — opt-in per receiver; existing hooks stay public-only.
    \\ALTER TABLE webhooks ADD COLUMN allow_private INTEGER NOT NULL DEFAULT 0 CHECK(allow_private IN (0,1));
    ,
    // V46: E5.27 — metadata de la incidencia leída por el motor. No claves ni
    // cuerpos externos en esta tabla; la orden conserva el contexto citado.
    \\CREATE TABLE IF NOT EXISTS order_issue_links (
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    source TEXT NOT NULL,
    \\    base_url TEXT NOT NULL,
    \\    project TEXT NOT NULL,
    \\    issue_id TEXT NOT NULL,
    \\    issue_url TEXT NOT NULL,
    \\    title TEXT NOT NULL,
    \\    PRIMARY KEY (order_id, source, base_url, project, issue_id)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_order_issue_links_order ON order_issue_links(order_id);
    ,
    // DS-SQLITE-INDICES (2026-10-16): índices para las DOS consultas calientes
    // de lectura, medidos en el estudio DS-TANDA2 (tools/sqlite_carga.zig).
    //
    // 1) listSessions (session_store.zig:168-169) lista `orders` filtrando por
    //    proyecto y ordena por `created_at DESC`. El índice sobre
    //    `orders(created_at DESC)` permite recorrer `orders` ya ordenado y
    //    elimina el `USE TEMP B-TREE FOR ORDER BY` (el filtro `substr(project_id)`
    //    no es indexable, así que el plan sigue siendo un recorrido —pero por
    //    índice— y NO un escaneo de tabla).
    //
    // 2) Eventos por orden (c_api.zig:6911 y :9851):
    //      WHERE order_id = ? ORDER BY ts ASC, id ASC
    //    El índice es `events(order_id, ts, id)` y NO `(order_id, id)` como
    //    proponía el borrador: el ORDER BY real termina en `ts, id` (no en `id`),
    //    así que incluir `ts` como segunda columna deja que SQLite satisfaga
    //    también el orden sin B-TREE temporal. Con `(order_id, id)` el filtro se
    //    resolvería por índice pero el orden seguiría necesitando el temp B-TREE.
    //    El único índice previo sobre `order_id` era el parcial
    //    idx_events_terminal_order (arriba), que solo cubre los eventos
    //    terminales; los `content_delta` (el grueso del volumen) no lo usaban.
    //
    // Idempotente (IF NOT EXISTS): una base creada con el esquema anterior migra
    // sin error (lo verifica el test "SQLITE-INDICES: base del esquema anterior
    // migra sin error"). Esta migración NO toca datos ni columnas.
    \\CREATE INDEX IF NOT EXISTS idx_events_order ON events(order_id, ts, id);
    \\CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at DESC)
    ,
    // (16-oct-2026): archivo de sesiones. El historial del usuario
    // acumula cientos de charlas de prueba que no se borran (borrar es
    // destructivo); `archived_at` (epoch SEGUNDOS, como `orders.created_at`)
    // marca una sesión como archivada y NULL = activa. El listado de sesiones
    // excluye las archivadas por defecto y solo las enseña con «Ver archivadas».
    // Desarchivar es volver a dejarla a NULL: no se pierde ningún dato.
    \\ALTER TABLE orders ADD COLUMN archived_at INTEGER
    ,
    // estado de avance escrito por el agente, por orden, sin pisar
    // al humano. `seq` monótono para el compare-and-swap («leer antes de
    // escribir»: writeProgress solo escribe si seq == expected_seq) y descarte
    // de reportes viejos. La nota se limita a 2 KiB de bytes UTF-8.
    \\CREATE TABLE IF NOT EXISTS order_progress (
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    state TEXT NOT NULL CHECK(state IN ('todo','in_progress','in_review','done')),
    \\    note TEXT NOT NULL DEFAULT '' CHECK(length(CAST(note AS BLOB)) <= 2048),
    \\    author TEXT NOT NULL CHECK(author IN ('agent','human')),
    \\    seq INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL,
    \\    PRIMARY KEY(order_id)
    \\);
    ,
    // A: notas humanas de diff y autoría por rangos; aditiva.
    \\CREATE TABLE IF NOT EXISTS review_notes (
    \\    id INTEGER PRIMARY KEY,
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    task_id INTEGER NOT NULL REFERENCES tasks(id),
    \\    file_path TEXT NOT NULL,
    \\    side TEXT NOT NULL CHECK(side IN ('old','new')),
    \\    line INTEGER NOT NULL CHECK(line >= 1),
    \\    line_hash TEXT NOT NULL,
    \\    context_hash TEXT NOT NULL,
    \\    body TEXT NOT NULL CHECK(length(CAST(body AS BLOB)) BETWEEN 1 AND 16384),
    \\    status TEXT NOT NULL CHECK(status IN ('open','submitted','resolved','orphaned')),
    \\    round INTEGER NOT NULL CHECK(round >= 1),
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_review_notes_order_task ON review_notes(order_id, task_id);
    \\CREATE TABLE IF NOT EXISTS artifact_line_authorship (
    \\    order_id INTEGER NOT NULL REFERENCES orders(id),
    \\    task_id INTEGER NOT NULL REFERENCES tasks(id),
    \\    file_path TEXT NOT NULL,
    \\    side TEXT NOT NULL CHECK(side IN ('old','new')),
    \\    line_start INTEGER NOT NULL CHECK(line_start >= 1),
    \\    line_end INTEGER NOT NULL CHECK(line_end >= line_start),
    \\    content_hash TEXT NOT NULL,
    \\    provider TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    author TEXT NOT NULL CHECK(author IN ('ai','human')),
    \\    PRIMARY KEY(order_id, task_id, file_path, side, line_start)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_artifact_line_authorship_order_task ON artifact_line_authorship(order_id, task_id);
    ,
    // V51: / E-GOV.1 — procedencia del artefacto (huellas de la
    // línea base del espacio). NULL en tareas viejas conserva el gate estricto;
    // nunca guarda una segunda copia del fuente.
    \\ALTER TABLE tasks ADD COLUMN artifact_provenance TEXT
    ,
    // V52: T12B B-2 — origen de la tarjeta: el digest de identidad de la
    // sesión MCP que la pidió ("" = cabina o fila anterior). Persistirlo hace
    // que la propiedad sobreviva a reiniciar el proceso devagents-mcp.
    \\ALTER TABLE approvals ADD COLUMN origin TEXT NOT NULL DEFAULT ''
};

/// Esquema de catalog.db (proveedores, claves y modelos).
pub const catalog_schema = [_][]const u8{
    // V1: Tablas base
    \\CREATE TABLE IF NOT EXISTS providers (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    base_url TEXT NOT NULL,
    \\    api_style TEXT NOT NULL,
    \\    is_free_tier INTEGER NOT NULL DEFAULT 1,
    \\    enabled INTEGER NOT NULL DEFAULT 1
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS api_keys (
    \\    id INTEGER PRIMARY KEY,
    \\    provider_id INTEGER NOT NULL REFERENCES providers(id),
    \\    label TEXT NOT NULL,
    \\    key_ciphertext BLOB NOT NULL,
    \\    quota_window TEXT,
    \\    quota_limit INTEGER,
    \\    quota_used INTEGER DEFAULT 0,
    \\    last_rotated_at INTEGER,
    \\    status TEXT NOT NULL DEFAULT 'active',
    \\    requests_count INTEGER DEFAULT 0,
    \\    last_used_at INTEGER
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS models (
    \\    id INTEGER PRIMARY KEY,
    \\    provider_id INTEGER NOT NULL REFERENCES providers(id),
    \\    model_name TEXT NOT NULL,
    \\    context_window INTEGER,
    \\    modalities TEXT,
    \\    is_free INTEGER NOT NULL DEFAULT 1,
    \\    latency_p50_ms INTEGER,
    \\    discovered_at INTEGER,
    \\    last_seen_at INTEGER,
    \\    available INTEGER NOT NULL DEFAULT 1
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS model_scores (
    \\    model_id INTEGER NOT NULL,
    \\    task_type TEXT NOT NULL CHECK(task_type IN ('planificar','programar','programar_c','programar_cpp','programar_zig','testear','auditar','corregir','documentar','investigar','resumir','ejecutar','disenar')),
    \\    score REAL NOT NULL CHECK(score >= 0.0 AND score <= 1.0),
    \\    sample_count INTEGER NOT NULL DEFAULT 0 CHECK(sample_count >= 0),
    \\    updated_at INTEGER,
    \\    FOREIGN KEY(model_id) REFERENCES models(id),
    \\    PRIMARY KEY (model_id, task_type)
    \\);
    ,
    // V5: Rebuild model_scores con CHECK corregido (ROUT-01b).
    //     Es un caché derivado; DROP+CREATE es seguro porque seedInitialScores
    //     repuebla los priors y los scores aprendidos se regeneran vía recordAuditVerdict.
    \\DROP TABLE IF EXISTS model_scores;
    \\CREATE TABLE model_scores (
    \\    model_id INTEGER NOT NULL,
    \\    task_type TEXT NOT NULL CHECK(task_type IN ('planificar','programar','programar_c','programar_cpp','programar_zig','testear','auditar','corregir','documentar','investigar','resumir','ejecutar','disenar')),
    \\    score REAL NOT NULL CHECK(score >= 0.0 AND score <= 1.0),
    \\    sample_count INTEGER NOT NULL DEFAULT 0 CHECK(sample_count >= 0),
    \\    updated_at INTEGER,
    \\    FOREIGN KEY(model_id) REFERENCES models(id),
    \\    PRIMARY KEY (model_id, task_type)
    \\);
    ,
    // V6: Rebuild model_scores con 'ejecutar' en el CHECK (P-EXEC).
    //     Same pattern as V5: DROP+CREATE is safe (cache derived, repopulated by seedInitialScores).
    \\DROP TABLE IF EXISTS model_scores;
    \\CREATE TABLE model_scores (
    \\    model_id INTEGER NOT NULL,
    \\    task_type TEXT NOT NULL CHECK(task_type IN ('planificar','programar','programar_c','programar_cpp','programar_zig','testear','auditar','corregir','documentar','investigar','resumir','ejecutar','disenar')),
    \\    score REAL NOT NULL CHECK(score >= 0.0 AND score <= 1.0),
    \\    sample_count INTEGER NOT NULL DEFAULT 0 CHECK(sample_count >= 0),
    \\    updated_at INTEGER,
    \\    FOREIGN KEY(model_id) REFERENCES models(id),
    \\    PRIMARY KEY (model_id, task_type)
    \\);
    ,
    // V7: columna is_favorite — "modelos favoritos" free-tier de alta funcionalidad
    // (el agente V4 Flash, Nemotron, Cohere Command a/r-plus) que el router prueba
    //     PRIMERO entre los free, para que la asignación inicial NO sea aleatoria.
    //     Se puebla en model_catalog.registerModel (patrón de nombre + is_free).
    //     ALTER ADD COLUMN es seguro/idempotente vía el migrador incremental (user_version):
    //     corre una sola vez en catalogs existentes y preserva filas y claves DPAPI.
    \\ALTER TABLE models ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0
    ,
    // V8: plugin_trust — ancla de confianza real (P01-T1). El hash esperado se pinnea
    //     en catalog.db al instalar/registrar el plugin, NO se deriva del propio DLL.
    //     loadTrustedFromCatalog compara contra este valor; fail-closed si no hay pin.
    \\CREATE TABLE IF NOT EXISTS plugin_trust (
    \\    name TEXT PRIMARY KEY,
    \\    sha256 TEXT NOT NULL,
    \\    pinned_at INTEGER NOT NULL
    \\)
    ,
    // V9: Rebuild model_scores con 'disenar' en el CHECK (P09 OpenDesign).
    //     model_scores es cache derivado; DROP+CREATE preserva el patrón V5/V6.
    \\DROP TABLE IF EXISTS model_scores;
    \\CREATE TABLE model_scores (
    \\    model_id INTEGER NOT NULL,
    \\    task_type TEXT NOT NULL CHECK(task_type IN ('planificar','programar','programar_c','programar_cpp','programar_zig','testear','auditar','corregir','documentar','investigar','resumir','ejecutar','disenar')),
    \\    score REAL NOT NULL CHECK(score >= 0.0 AND score <= 1.0),
    \\    sample_count INTEGER NOT NULL DEFAULT 0 CHECK(sample_count >= 0),
    \\    updated_at INTEGER,
    \\    FOREIGN KEY(model_id) REFERENCES models(id),
    \\    PRIMARY KEY (model_id, task_type)
    \\);
    ,
    // V10: Persistencia fuerte del catálogo de modelos.
    //      Garantiza una sola fila por proveedor+modelo, conserva el primer id como
    //      canónico y fusiona model_scores derivados antes de crear el índice único.
    \\CREATE TEMP TABLE IF NOT EXISTS _model_keep AS
    \\SELECT provider_id, model_name, MIN(id) AS keep_id
    \\FROM models
    \\GROUP BY provider_id, model_name;
    \\CREATE TEMP TABLE IF NOT EXISTS _model_scores_keep AS
    \\SELECT k.keep_id AS model_id, ms.task_type, MAX(ms.score) AS score,
    \\       SUM(ms.sample_count) AS sample_count, MAX(ms.updated_at) AS updated_at
    \\FROM model_scores ms
    \\JOIN models m ON m.id = ms.model_id
    \\JOIN _model_keep k ON k.provider_id = m.provider_id AND k.model_name = m.model_name
    \\GROUP BY k.keep_id, ms.task_type;
    \\DELETE FROM model_scores;
    \\INSERT INTO model_scores (model_id, task_type, score, sample_count, updated_at)
    \\SELECT model_id, task_type, score, sample_count, updated_at FROM _model_scores_keep;
    \\DELETE FROM models
    \\WHERE id NOT IN (SELECT keep_id FROM _model_keep);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_models_provider_model ON models(provider_id, model_name);
    \\DROP TABLE IF EXISTS _model_scores_keep;
    \\DROP TABLE IF EXISTS _model_keep;
    ,
    // V11: discovery_snapshots_v2
    \\CREATE TABLE IF NOT EXISTS discovery_snapshots_v2 (
    \\    provider TEXT NOT NULL,
    \\    model_id TEXT NOT NULL,
    \\    api_style TEXT NOT NULL,
    \\    wire_protocol TEXT NOT NULL,
    \\    endpoint_url TEXT NOT NULL,
    \\    cap_chat_status TEXT NOT NULL,
    \\    cap_chat_provenance TEXT NOT NULL,
    \\    cap_streaming_status TEXT NOT NULL,
    \\    cap_streaming_provenance TEXT NOT NULL,
    \\    cap_tool_calls_status TEXT NOT NULL,
    \\    cap_tool_calls_provenance TEXT NOT NULL,
    \\    cap_structured_output_status TEXT NOT NULL,
    \\    cap_structured_output_provenance TEXT NOT NULL,
    \\    cap_vision_status TEXT NOT NULL,
    \\    cap_vision_provenance TEXT NOT NULL,
    \\    cap_reasoning_status TEXT NOT NULL,
    \\    cap_reasoning_provenance TEXT NOT NULL,
    \\    cap_audio_input_status TEXT NOT NULL,
    \\    cap_audio_input_provenance TEXT NOT NULL,
    \\    cap_audio_output_status TEXT NOT NULL,
    \\    cap_audio_output_provenance TEXT NOT NULL,
    \\    cap_embeddings_status TEXT NOT NULL,
    \\    cap_embeddings_provenance TEXT NOT NULL,
    \\    context_window INTEGER,
    \\    max_output_tokens INTEGER,
    \\    pricing_prompt REAL,
    \\    pricing_completion REAL,
    \\    cost_category TEXT NOT NULL,
    \\    quota_limit TEXT,
    \\    auth_required INTEGER NOT NULL,
    \\    auth_env_var TEXT,
    \\    metadata_source TEXT NOT NULL,
    \\    metadata_updated_at TEXT NOT NULL,
    \\    metadata_reference_url TEXT,
    \\    metadata_payload_type TEXT NOT NULL,
    \\    health_state TEXT NOT NULL,
    \\    PRIMARY KEY (provider, model_id)
    \\)
    ,
    // V12: Columnas account_ref y priority en api_keys (T5)
    \\ALTER TABLE api_keys ADD COLUMN account_ref TEXT
    ,
    \\ALTER TABLE api_keys ADD COLUMN priority INTEGER NOT NULL DEFAULT 0
    ,
    // V13: Columna is_generative en models (T5)
    \\ALTER TABLE models ADD COLUMN is_generative INTEGER NOT NULL DEFAULT 1
    ,
    // V14: Salud de modelos en catalog.db (02-ARQUITECTURA.md §6.1).
    \\CREATE TABLE IF NOT EXISTS model_health (
    \\    model_id TEXT PRIMARY KEY,
    \\    ok_count INTEGER NOT NULL DEFAULT 0,
    \\    err_count INTEGER NOT NULL DEFAULT 0,
    \\    timeout_count INTEGER NOT NULL DEFAULT 0,
    \\    last_ok_at INTEGER,
    \\    last_err_at INTEGER,
    \\    last_err_kind TEXT
    \\)
    ,
    // V15: CHECK constraint en api_keys.status incluyendo 'cooling' (S2-5).
    \\CREATE TABLE IF NOT EXISTS _api_keys_v15 (
    \\    id INTEGER PRIMARY KEY,
    \\    provider_id INTEGER NOT NULL REFERENCES providers(id),
    \\    label TEXT NOT NULL,
    \\    key_ciphertext BLOB NOT NULL,
    \\    quota_window TEXT,
    \\    quota_limit INTEGER,
    \\    quota_used INTEGER DEFAULT 0,
    \\    last_rotated_at INTEGER,
    \\    status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','expired','revoked','quota_exceeded','cooling','rotated')),
    \\    requests_count INTEGER DEFAULT 0,
    \\    last_used_at INTEGER,
    \\    account_ref TEXT,
    \\    priority INTEGER NOT NULL DEFAULT 0
    \\);
    \\INSERT INTO _api_keys_v15 SELECT id, provider_id, label, key_ciphertext, quota_window, quota_limit, quota_used, last_rotated_at, status, requests_count, last_used_at, account_ref, priority FROM api_keys;
    \\DROP TABLE api_keys;
    \\ALTER TABLE _api_keys_v15 RENAME TO api_keys;
    ,
    // V16: Tabla settings para gobernanza y presupuesto (T1, T5)
    \\CREATE TABLE IF NOT EXISTS settings (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\)
    ,
    \\INSERT OR IGNORE INTO settings (key, value) VALUES ('governance_mode', 'hybrid')
    ,
    \\INSERT OR IGNORE INTO settings (key, value) VALUES ('monthly_budget_usd', '25.00')
    ,
    // V17: H8 - la salud deja de ser del MODELO y pasa a ser del par
    // (modelo, clave).
    //
    // El usuario tiene tres claves de Gemini: dos de pago y una degradada. Con
    // `model_id` como clave primaria, los fallos de la mala se sumaban en la
    // MISMA fila que los aciertos de las buenas, y el router condenaba el
    // modelo para las tres. No habia forma de expresar "este modelo funciona
    // con esta clave y no con aquella", que es exactamente lo que pasa cuando
    // una clave no cubre el modelo (401) o se le agoto la cuota (429).
    //
    // Las filas historicas se conservan con key_label = '' : siguen contando
    // como evidencia, pero sin atribuir a nadie. La reconstruccion es
    // obligatoria porque no se puede quitar una PRIMARY KEY con ALTER.
    \\CREATE TABLE IF NOT EXISTS _model_health_v2 (
    \\    model_id TEXT NOT NULL,
    \\    key_label TEXT NOT NULL DEFAULT '',
    \\    ok_count INTEGER NOT NULL DEFAULT 0,
    \\    err_count INTEGER NOT NULL DEFAULT 0,
    \\    timeout_count INTEGER NOT NULL DEFAULT 0,
    \\    last_ok_at INTEGER,
    \\    last_err_at INTEGER,
    \\    last_err_kind TEXT,
    \\    PRIMARY KEY (model_id, key_label)
    \\);
    \\INSERT INTO _model_health_v2 (model_id, key_label, ok_count, err_count, timeout_count, last_ok_at, last_err_at, last_err_kind)
    \\    SELECT model_id, '', ok_count, err_count, timeout_count, last_ok_at, last_err_at, last_err_kind FROM model_health;
    \\DROP TABLE model_health;
    \\ALTER TABLE _model_health_v2 RENAME TO model_health;
    ,
    // V18: MODELO-LOCAL — los proveedores que corren en la máquina del usuario
    // (Ollama) no tienen clave API. `is_local` los distingue para que las
    // consultas de `enabled` (reconcileProviderEnabled, syncProviderEnabled,
    // clearKeys) no los apaguen por no tener claves: para un proveedor local,
    // enabled es un dato del seed, no una consecuencia de api_keys.
    \\ALTER TABLE providers ADD COLUMN is_local INTEGER NOT NULL DEFAULT 0
    ,
    // E5.55: additive CLI detection cache and model pin options.
    \\CREATE TABLE external_agent_cache (
    \\    id INTEGER PRIMARY KEY CHECK(id=1),
    \\    payload_json TEXT NOT NULL,
    \\    detected_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE external_model_options (
    \\    provider TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    reasoning_effort TEXT NOT NULL,
    \\    PRIMARY KEY(provider,model)
    \\);
    \\INSERT OR IGNORE INTO settings(key,value) VALUES('external_agent_paths','{}');
    ,
    // capabilities inherited; personal memory/instructions opt-in.
    \\INSERT OR IGNORE INTO settings(key,value) VALUES('external_agent_inherit_personal_context','false');
    ,
    // HTTP and CLI identities share persistent, independent switches.
    \\CREATE TABLE model_preferences (
    \\    provider TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    show_in_selectors INTEGER NOT NULL DEFAULT 1 CHECK(show_in_selectors IN (0,1)),
    \\    allow_automatic INTEGER NOT NULL DEFAULT 1 CHECK(allow_automatic IN (0,1)),
    \\    PRIMARY KEY(provider,model)
    \\);
};

/// Esquema de ledger.db (evidencias y auditorías append-only).
pub const ledger_schema = [_][]const u8{
    // V1: Tablas base
    \\CREATE TABLE IF NOT EXISTS verifications (
    \\    id INTEGER PRIMARY KEY,
    \\    ts INTEGER NOT NULL,
    \\    task_id INTEGER,
    \\    command TEXT NOT NULL,
    \\    exit_code INTEGER NOT NULL,
    \\    output_hash TEXT NOT NULL,
    \\    output_path TEXT NOT NULL,
    \\    prev_hash TEXT,
    \\    row_hash TEXT NOT NULL
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS audit_ledger (
    \\    id INTEGER PRIMARY KEY,
    \\    ts INTEGER NOT NULL,
    \\    subject_kind TEXT NOT NULL,
    \\    subject_id INTEGER NOT NULL,
    \\    action TEXT NOT NULL,
    \\    verdict TEXT NOT NULL,
    \\    model_id TEXT NOT NULL,
    \\    provider TEXT NOT NULL,
    \\    evidence_ref TEXT NOT NULL,
    \\    notes TEXT,
    \\    prev_hash TEXT,
    \\    row_hash TEXT NOT NULL
    \\);
    ,
    // V2: Triggers para hacer audit_ledger append-only
    \\CREATE TRIGGER IF NOT EXISTS trg_audit_ledger_prevent_update
    \\BEFORE UPDATE ON audit_ledger
    \\BEGIN
    \\    SELECT RAISE(ABORT, 'audit_ledger is append-only; UPDATE rejected');
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS trg_audit_ledger_prevent_delete
    \\BEFORE DELETE ON audit_ledger
    \\BEGIN
    \\    SELECT RAISE(ABORT, 'audit_ledger is append-only; DELETE rejected');
    \\END;
    ,
    // V3: Triggers para verifications append-only
    \\CREATE TRIGGER IF NOT EXISTS trg_verifications_prevent_update
    \\BEFORE UPDATE ON verifications
    \\BEGIN
    \\    SELECT RAISE(ABORT, 'verifications is append-only; UPDATE rejected');
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS trg_verifications_prevent_delete
    \\BEFORE DELETE ON verifications
    \\BEGIN
    \\    SELECT RAISE(ABORT, 'verifications is append-only; DELETE rejected');
    \\END;
    ,
    // V4: Tabla usage_records en ledger.db (T5)
    \\CREATE TABLE IF NOT EXISTS usage_records (
    \\    id INTEGER PRIMARY KEY,
    \\    ts INTEGER NOT NULL,
    \\    provider TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    api_key_id INTEGER,
    \\    tokens_in INTEGER NOT NULL DEFAULT 0,
    \\    tokens_out INTEGER NOT NULL DEFAULT 0,
    \\    cost_usd REAL NOT NULL DEFAULT 0.0,
    \\    task_id TEXT
    \\);
    ,
    // V5: AUDIT-INDEP — subject_id es el índice de la tarea DENTRO de su orden
    // ("T1"→1), no un id global: sin order_id la derivación de checklist
    // fusionaba auditorías de órdenes distintas bajo el mismo subject_id.
    // DEFAULT 0 agrupa las filas históricas en una "orden desconocida" honesta.
    \\ALTER TABLE audit_ledger ADD COLUMN order_id INTEGER NOT NULL DEFAULT 0
    \\;
};

/// Calcula row_hash = SHA256(prev_hash || content) en hex.
pub fn computeRowHash(prev_hash: ?[]const u8, content: []const u8) [64]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    if (prev_hash) |ph| sha.update(ph);
    sha.update(content);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    sha.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

test "10-nov: txKind clasifica las sentencias de transaccion" {
    try std.testing.expectEqual(TxKind.begin, txKind("  BEGIN IMMEDIATE"));
    try std.testing.expectEqual(TxKind.begin, txKind("begin"));
    try std.testing.expectEqual(TxKind.commit, txKind("COMMIT"));
    try std.testing.expectEqual(TxKind.commit, txKind("END TRANSACTION"));
    try std.testing.expectEqual(TxKind.rollback, txKind("ROLLBACK"));
    try std.testing.expectEqual(TxKind.other, txKind("ROLLBACK TO sp1"));
    try std.testing.expectEqual(TxKind.other, txKind("INSERT INTO t VALUES (1)"));
}

test "10-nov: dos hilos con transacciones en la MISMA conexion no chocan" {
    // Antes: BEGIN IMMEDIATE de un hilo con la transaccion de otro abierta en
    // la misma conexion -> ExecFailed (ordenes 940, 942 y 946 sin cerrar).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const dir = try tmp.dir.realPathFileAlloc(threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "tx.db" });
    defer std.testing.allocator.free(path);
    var conn = try Connection.open(std.heap.c_allocator, path);
    defer conn.close();
    try conn.exec("CREATE TABLE t (v INTEGER)");
    const Worker = struct {
        fn run(cn: Connection, fails: *std.atomic.Value(u32)) void {
            for (0..200) |i| {
                cn.exec("BEGIN IMMEDIATE") catch {
                    _ = fails.fetchAdd(1, .monotonic);
                    continue;
                };
                const stmt = cn.prepare("INSERT INTO t (v) VALUES (?)") catch {
                    cn.exec("ROLLBACK") catch {};
                    _ = fails.fetchAdd(1, .monotonic);
                    continue;
                };
                bindInt(stmt, 1, @intCast(i)) catch {};
                _ = c.sqlite3_step(stmt);
                cn.finalize(stmt);
                cn.exec("COMMIT") catch {
                    cn.exec("ROLLBACK") catch {};
                    _ = fails.fetchAdd(1, .monotonic);
                };
            }
        }
    };
    var fails = std.atomic.Value(u32).init(0);
    const a = try std.Thread.spawn(.{}, Worker.run, .{ conn, &fails });
    const b = try std.Thread.spawn(.{}, Worker.run, .{ conn, &fails });
    a.join();
    b.join();
    try std.testing.expectEqual(@as(u32, 0), fails.load(.monotonic));
}

test "computeRowHash deterministic" {
    const a = computeRowHash(null, "hello");
    const b = computeRowHash(null, "hello");
    try std.testing.expectEqualStrings(&a, &b);
}

test "computeRowHash changes with prev_hash" {
    const a = computeRowHash(null, "hello");
    const b = computeRowHash(&a, "hello");
    // b should be different from a since prev_hash changed
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "computeRowHash chain" {
    const h1 = computeRowHash(null, "first");
    const h2 = computeRowHash(&h1, "second");
    const h3 = computeRowHash(&h2, "third");
    try std.testing.expect(std.mem.eql(u8, &h2, &computeRowHash(&h1, "second")));
    try std.testing.expect(std.mem.eql(u8, &h3, &computeRowHash(&h2, "third")));
}

test "ledger append-only triggers reject update" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &ledger_schema);
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (1,'test',1,'insert','pass','test-model','test','ref','abc')");
    const update_err = conn.exec("UPDATE audit_ledger SET verdict='fail' WHERE id=1");
    try std.testing.expectError(error.ExecFailed, update_err);
}

test "ledger append-only triggers reject delete" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &ledger_schema);
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (1,'test',1,'insert','pass','test-model','test','ref','abc')");
    const delete_err = conn.exec("DELETE FROM audit_ledger WHERE id=1");
    try std.testing.expectError(error.ExecFailed, delete_err);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "open and close in-memory db" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    try std.testing.expect(conn.db != null);
}

test "exec creates table" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.exec("INSERT INTO test (name) VALUES ('hello')");
}

test "migrate runtime schema" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &runtime_schema);
    const version = try conn.getUserVersion();
    try std.testing.expectEqual(@as(i32, runtime_schema.len), version);
}

test "runtime schema V20 orders.conversation_id column" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (1, 'p', 'hello', 'pending', 1, 'conv-abc')");
    const stmt = try conn.prepare("SELECT conversation_id FROM orders WHERE id = 1");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    const ptr = c.sqlite3_column_text(stmt, 0) orelse return error.TestUnexpectedNull;
    const len = c.sqlite3_column_bytes(stmt, 0);
    try std.testing.expectEqualStrings("conv-abc", ptr[0..@intCast(len)]);
}

test "runtime schema V13 messages table" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, title) VALUES (1, 'p', 'hello', 'pending', 1, 'Hello')");
    try conn.exec("INSERT INTO messages (order_id, role, content, created_at) VALUES (1, 'user', 'hi', 1)");
}

test "migrate ledger schema" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &ledger_schema);
    const version = try conn.getUserVersion();
    try std.testing.expectEqual(@as(i32, ledger_schema.len), version);
}

test "migrate catalog schema" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &catalog_schema);
    const version = try conn.getUserVersion();
    try std.testing.expectEqual(@as(i32, catalog_schema.len), version);
}

test "catalog schema V10 deduplicates persisted models before unique index" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, catalog_schema[0..9]);

    try conn.exec("INSERT INTO providers (id, name, base_url, api_style) VALUES (1, 'OpenRouter', 'https://openrouter.ai/api/v1', 'openai')");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, available) VALUES (1, 1, 'm', 128000, 1, 1)");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, available) VALUES (2, 1, 'm', 256000, 1, 1)");
    try conn.exec("INSERT INTO model_scores (model_id, task_type, score, sample_count, updated_at) VALUES (1, 'programar', 0.40, 2, 10)");
    try conn.exec("INSERT INTO model_scores (model_id, task_type, score, sample_count, updated_at) VALUES (2, 'programar', 0.90, 3, 20)");

    try migrator.migrate(conn, &catalog_schema);
    try std.testing.expectEqual(@as(i32, catalog_schema.len), try conn.getUserVersion());

    {
        const stmt = try conn.prepare("SELECT COUNT(*) FROM models WHERE provider_id=1 AND model_name='m'");
        defer conn.finalize(stmt);
        try std.testing.expect(c.sqlite3_step(stmt) == c.SQLITE_ROW);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(stmt, 0));
    }
    {
        const stmt = try conn.prepare("SELECT model_id, score, sample_count, updated_at FROM model_scores WHERE task_type='programar'");
        defer conn.finalize(stmt);
        try std.testing.expect(c.sqlite3_step(stmt) == c.SQLITE_ROW);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(stmt, 0));
        try std.testing.expectEqual(@as(c_int, 5), c.sqlite3_column_int(stmt, 2));
        try std.testing.expectEqual(@as(c_int, 20), c.sqlite3_column_int(stmt, 3));
    }
    const duplicate_insert = conn.exec("INSERT INTO models (provider_id, model_name, is_free) VALUES (1, 'm', 1)");
    try std.testing.expectError(error.ExecFailed, duplicate_insert);
}

// FIX 3 regresión: db con user_version mayor que migraciones → error accionable.
test "migrate rejects user_version ahead of available migrations" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    // Simular una BD creada por una versión más nueva.
    try conn.setUserVersion(100);
    var migrator = Migrator.init(allocator);
    try std.testing.expectError(error.DbSchemaAhead, migrator.migrate(conn, &catalog_schema));
}

test "catalog model_scores rejects unknown task type" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &catalog_schema);
    try conn.exec("INSERT INTO providers (id, name, base_url, api_style) VALUES (1, 'p', 'https://p', 'openai')");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, is_free) VALUES (1, 1, 'm', 1)");
    const insert_err = conn.exec("INSERT INTO model_scores (model_id, task_type, score, sample_count) VALUES (1, 'invalidar', 0.5, 0)");
    try std.testing.expectError(error.ExecFailed, insert_err);
}

test "catalog model_scores accepts design task type" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &catalog_schema);
    try conn.exec("INSERT INTO providers (id, name, base_url, api_style) VALUES (1, 'p', 'https://p', 'openai')");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, is_free) VALUES (1, 1, 'm', 1)");
    try conn.exec("INSERT INTO model_scores (model_id, task_type, score, sample_count) VALUES (1, 'disenar', 0.5, 0)");
}

// ── TERMINAL-STATE-DESIGN-2026-07-12 (P0): máquina terminal atómica ────────

const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
}.GetTempPathA else @import("platform.zig").tempPath;

fn terminalTestDbPath(tmp: *const std.testing.TmpDir, filename: []const u8) ![:0]u8 {
    var sys_buf: [1024]u8 = undefined;
    const len = GetTempPathA(1024, &sys_buf);
    const sys_temp = if (len > 0 and len < 1024) sys_buf[0..len] else "C:\\Windows\\Temp\\";
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}beats-test-{s}-{s}",
        .{ sys_temp, tmp.sub_path[0..], filename },
    );
    defer std.testing.allocator.free(path);
    return std.testing.allocator.dupeZ(u8, path);
}

test "TERMINAL-P0 D: runtime schema #24 dedupes historical terminal events and adds partial unique index" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, runtime_schema[0..23]);
    try std.testing.expectEqual(@as(i32, 23), try conn.getUserVersion());

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hi', 'done', 1)");
    // Duplicados históricos: dos terminales para la MISMA orden, posibles antes
    // de que existiera el índice único parcial.
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (1, 's', 'order_done', '{}', 1)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (2, 's', 'order_failed', '{}', 1)");
    // Evento no-terminal: la limpieza nunca debe tocarlo.
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (3, 's', 'agent_message', '{}', 1)");

    try migrator.migrate(conn, &runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());

    {
        const stmt = try conn.prepare("SELECT COUNT(*) FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
        defer conn.finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(stmt, 0));
    }
    {
        // Sobrevive el de MIN(id) — el evento 'order_done' (id=1), no el duplicado id=2.
        const stmt = try conn.prepare("SELECT kind FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
        defer conn.finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        const ptr = c.sqlite3_column_text(stmt, 0) orelse return error.TestUnexpectedNull;
        const len = c.sqlite3_column_bytes(stmt, 0);
        try std.testing.expectEqualStrings("order_done", ptr[0..@intCast(len)]);
    }
    {
        const stmt = try conn.prepare("SELECT COUNT(*) FROM events WHERE order_id = 1 AND kind = 'agent_message'");
        defer conn.finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(stmt, 0));
    }
    // El índice único parcial ya está activo: un tercer terminal para la misma orden falla.
    const dup = conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (4, 's', 'order_cancelled', '{}', 1)");
    try std.testing.expectError(error.ExecFailed, dup);
}

test "TERMINAL-P0 A: concurrent done vs failed on separate connections — exactly one wins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try terminalTestDbPath(&tmp, "race.db");
    defer std.testing.allocator.free(path);

    {
        var setup = try Connection.open(allocator, path);
        defer setup.close();
        var migrator = Migrator.init(allocator);
        try migrator.migrate(setup, &runtime_schema);
        try setup.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hi', 'running', 1)");
    }

    const RaceCtx = struct {
        path: [:0]const u8,
        status: []const u8,
        kind: []const u8,
        result: bool = false,

        fn run(self: *@This()) void {
            var conn = Connection.open(std.testing.allocator, self.path) catch return;
            defer conn.close();
            self.result = conn.tryCommitTerminal(1, self.status, self.kind, "test", "{}", 1) catch false;
        }
    };

    var ctx_done = RaceCtx{ .path = path, .status = "done", .kind = "order_done" };
    var ctx_failed = RaceCtx{ .path = path, .status = "failed", .kind = "order_failed" };

    const t1 = try std.Thread.spawn(.{}, RaceCtx.run, .{&ctx_done});
    const t2 = try std.Thread.spawn(.{}, RaceCtx.run, .{&ctx_failed});
    t1.join();
    t2.join();

    // Exactamente uno de los dos gana la carrera.
    try std.testing.expect(ctx_done.result != ctx_failed.result);

    var verify = try Connection.open(allocator, path);
    defer verify.close();

    const st_stmt = try verify.prepare("SELECT status FROM orders WHERE id = 1");
    defer verify.finalize(st_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st_stmt));
    const sptr = c.sqlite3_column_text(st_stmt, 0) orelse return error.TestUnexpectedNull;
    const slen = c.sqlite3_column_bytes(st_stmt, 0);
    const won_status: []const u8 = if (ctx_done.result) "done" else "failed";
    try std.testing.expectEqualStrings(won_status, sptr[0..@intCast(slen)]);

    const cnt_stmt = try verify.prepare("SELECT COUNT(*) FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
    defer verify.finalize(cnt_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cnt_stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(cnt_stmt, 0));

    const kind_stmt = try verify.prepare("SELECT kind FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
    defer verify.finalize(kind_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(kind_stmt));
    const kptr = c.sqlite3_column_text(kind_stmt, 0) orelse return error.TestUnexpectedNull;
    const klen = c.sqlite3_column_bytes(kind_stmt, 0);
    const won_kind: []const u8 = if (ctx_done.result) "order_done" else "order_failed";
    try std.testing.expectEqualStrings(won_kind, kptr[0..@intCast(klen)]);
}

test "TERMINAL-P0 E: concurrent done vs cancelled on separate connections — exactly one wins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try terminalTestDbPath(&tmp, "race_cancel_done.db");
    defer std.testing.allocator.free(path);

    {
        var setup = try Connection.open(allocator, path);
        defer setup.close();
        var migrator = Migrator.init(allocator);
        try migrator.migrate(setup, &runtime_schema);
        try setup.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hi', 'running', 1)");
    }

    const RaceCtx = struct {
        path: [:0]const u8,
        status: []const u8,
        kind: []const u8,
        result: bool = false,

        fn run(self: *@This()) void {
            var conn = Connection.open(std.testing.allocator, self.path) catch return;
            defer conn.close();
            self.result = conn.tryCommitTerminal(1, self.status, self.kind, "test", "{}", 1) catch false;
        }
    };

    var ctx_done = RaceCtx{ .path = path, .status = "done", .kind = "order_done" };
    var ctx_cancelled = RaceCtx{ .path = path, .status = "cancelled", .kind = "order_cancelled" };

    const t1 = try std.Thread.spawn(.{}, RaceCtx.run, .{&ctx_done});
    const t2 = try std.Thread.spawn(.{}, RaceCtx.run, .{&ctx_cancelled});
    t1.join();
    t2.join();

    // C2 item 8: exactamente uno de los dos gana — cancelación no es un caso
    // especial para tryCommitTerminal, comparte la misma garantía atómica.
    try std.testing.expect(ctx_done.result != ctx_cancelled.result);

    var verify = try Connection.open(allocator, path);
    defer verify.close();

    const st_stmt = try verify.prepare("SELECT status FROM orders WHERE id = 1");
    defer verify.finalize(st_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st_stmt));
    const sptr = c.sqlite3_column_text(st_stmt, 0) orelse return error.TestUnexpectedNull;
    const slen = c.sqlite3_column_bytes(st_stmt, 0);
    const won_status: []const u8 = if (ctx_done.result) "done" else "cancelled";
    try std.testing.expectEqualStrings(won_status, sptr[0..@intCast(slen)]);

    const cnt_stmt = try verify.prepare("SELECT COUNT(*) FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
    defer verify.finalize(cnt_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cnt_stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(cnt_stmt, 0));

    const kind_stmt = try verify.prepare("SELECT kind FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
    defer verify.finalize(kind_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(kind_stmt));
    const kptr = c.sqlite3_column_text(kind_stmt, 0) orelse return error.TestUnexpectedNull;
    const klen = c.sqlite3_column_bytes(kind_stmt, 0);
    const won_kind: []const u8 = if (ctx_done.result) "order_done" else "order_cancelled";
    try std.testing.expectEqualStrings(won_kind, kptr[0..@intCast(klen)]);
}

test "TERMINAL-P0 F: concurrent failed vs cancelled on separate connections — exactly one wins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try terminalTestDbPath(&tmp, "race_cancel_failed.db");
    defer std.testing.allocator.free(path);

    {
        var setup = try Connection.open(allocator, path);
        defer setup.close();
        var migrator = Migrator.init(allocator);
        try migrator.migrate(setup, &runtime_schema);
        try setup.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hi', 'running', 1)");
    }

    const RaceCtx = struct {
        path: [:0]const u8,
        status: []const u8,
        kind: []const u8,
        result: bool = false,

        fn run(self: *@This()) void {
            var conn = Connection.open(std.testing.allocator, self.path) catch return;
            defer conn.close();
            self.result = conn.tryCommitTerminal(1, self.status, self.kind, "test", "{}", 1) catch false;
        }
    };

    var ctx_failed = RaceCtx{ .path = path, .status = "failed", .kind = "order_failed" };
    var ctx_cancelled = RaceCtx{ .path = path, .status = "cancelled", .kind = "order_cancelled" };

    const t1 = try std.Thread.spawn(.{}, RaceCtx.run, .{&ctx_failed});
    const t2 = try std.Thread.spawn(.{}, RaceCtx.run, .{&ctx_cancelled});
    t1.join();
    t2.join();

    // C2 item 9: exactamente uno de los dos gana.
    try std.testing.expect(ctx_failed.result != ctx_cancelled.result);

    var verify = try Connection.open(allocator, path);
    defer verify.close();

    const st_stmt = try verify.prepare("SELECT status FROM orders WHERE id = 1");
    defer verify.finalize(st_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st_stmt));
    const sptr = c.sqlite3_column_text(st_stmt, 0) orelse return error.TestUnexpectedNull;
    const slen = c.sqlite3_column_bytes(st_stmt, 0);
    const won_status: []const u8 = if (ctx_failed.result) "failed" else "cancelled";
    try std.testing.expectEqualStrings(won_status, sptr[0..@intCast(slen)]);

    const cnt_stmt = try verify.prepare("SELECT COUNT(*) FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
    defer verify.finalize(cnt_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cnt_stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(cnt_stmt, 0));

    const kind_stmt = try verify.prepare("SELECT kind FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
    defer verify.finalize(kind_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(kind_stmt));
    const kptr = c.sqlite3_column_text(kind_stmt, 0) orelse return error.TestUnexpectedNull;
    const klen = c.sqlite3_column_bytes(kind_stmt, 0);
    const won_kind: []const u8 = if (ctx_failed.result) "order_failed" else "order_cancelled";
    try std.testing.expectEqualStrings(won_kind, kptr[0..@intCast(klen)]);
}

test "TERMINAL-P0 B: preexisting conflicting terminal event forces rollback of the UPDATE too" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &runtime_schema);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hi', 'running', 1)");
    // Evento terminal preexistente e inconsistente con orders.status — simula datos
    // heredados de antes de que este mecanismo existiera (o una corrupción real).
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (1, 's', 'order_done', '{}', 1)");

    const result = conn.tryCommitTerminal(1, "failed", "order_failed", "test", "{}", 2);
    try std.testing.expectError(error.ConstraintViolation, result);

    // El UPDATE se revirtió junto con el INSERT fallido: status intacto en 'running'.
    const stmt = try conn.prepare("SELECT status FROM orders WHERE id = 1");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    const ptr = c.sqlite3_column_text(stmt, 0) orelse return error.TestUnexpectedNull;
    const len = c.sqlite3_column_bytes(stmt, 0);
    try std.testing.expectEqualStrings("running", ptr[0..@intCast(len)]);

    // Sigue habiendo un único evento terminal: el preexistente, ninguno nuevo.
    const cnt_stmt = try conn.prepare("SELECT COUNT(*) FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
    defer conn.finalize(cnt_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cnt_stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(cnt_stmt, 0));
}

test "TERMINAL-P0 C: retrying an already-committed terminal is idempotent (false, no second event)" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hi', 'running', 1)");

    const first = try conn.tryCommitTerminal(1, "done", "order_done", "test", "{}", 1);
    try std.testing.expect(first);

    // Reintento del MISMO terminal (p. ej. reintento de red o reentrada del hilo).
    const second = try conn.tryCommitTerminal(1, "done", "order_done", "test", "{}", 2);
    try std.testing.expect(!second);

    const cnt_stmt = try conn.prepare("SELECT COUNT(*) FROM events WHERE order_id = 1 AND kind IN ('order_done','order_failed','order_cancelled')");
    defer conn.finalize(cnt_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cnt_stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(cnt_stmt, 0));
}

test "TERMINAL-P0 rejects non-terminal status and mismatched event kind" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hi', 'running', 1)");

    try std.testing.expectError(error.InvalidTerminalTransition, conn.tryCommitTerminal(1, "running", "dispatch_failed", "test", "{}", 1));
    try std.testing.expectError(error.InvalidTerminalTransition, conn.tryCommitTerminal(1, "done", "order_failed", "test", "{}", 1));
}

test "E-GOV.1: migracion V51 anade artifact_provenance sin tocar datos previos" {
    const a = std.testing.allocator;
    var conn = try Connection.open(a, ":memory:");
    defer conn.close();
    const migrator = Migrator.init(a);
    try migrator.migrate(conn, runtime_schema[0..50]);
    try std.testing.expectEqual(@as(i32, 50), try conn.getUserVersion());
    try conn.exec("INSERT INTO tasks (id,department,task_type,description,status,created_at) VALUES (987,'p','programar','prior task','completed',1)");
    try migrator.migrate(conn, &runtime_schema);
    try migrator.migrate(conn, &runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());
    const stmt = try conn.prepare("SELECT status, artifact_provenance FROM tasks WHERE id=987");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("completed", std.mem.span(c.sqlite3_column_text(stmt, 0).?));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(stmt, 1));
    try conn.exec("UPDATE tasks SET artifact_provenance='synthetic retained origin' WHERE id=987");
    try migrator.migrate(conn, &runtime_schema);
    const origin = try conn.prepare("SELECT artifact_provenance FROM tasks WHERE id=987");
    defer conn.finalize(origin);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(origin));
    try std.testing.expectEqualStrings("synthetic retained origin", std.mem.span(c.sqlite3_column_text(origin, 0).?));
}

test "T5: schema migrations create new tables/columns and pass integrity check" {
    const allocator = std.testing.allocator;

    // 1. runtime.db test
    {
        var conn = try Connection.open(allocator, ":memory:");
        defer conn.close();
        const migrator = Migrator.init(allocator);
        try migrator.migrate(conn, &runtime_schema);

        // Verify spaces, turns, pull_requests tables exist
        try conn.exec("INSERT INTO spaces (id, project_id, kind, name, worktree_path, branch, created_at) VALUES (1, 'p1', 'order', 'sp1', '/wt', 'main', 100)");
        try conn.exec("INSERT INTO turns (id, order_id, status, checkpoint_json, started_at) VALUES (1, 10, 'running', '{}', 100)");
        try conn.exec("INSERT INTO pull_requests (id, order_id, provider, repo, number, state, url, last_polled_at) VALUES (1, 10, 'github', 'repo', 1, 'open', 'https://pr', 100)");
        try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, space_id, parent_order_id) VALUES (10, 'p1', 'do it', 'running', 100, 1, NULL)");

        const integrity = try conn.prepare("PRAGMA integrity_check");
        defer conn.finalize(integrity);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(integrity));
        const ok_ptr = c.sqlite3_column_text(integrity, 0) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqualStrings("ok", std.mem.span(ok_ptr));
    }

    // 2. catalog.db test
    {
        var conn = try Connection.open(allocator, ":memory:");
        defer conn.close();
        const migrator = Migrator.init(allocator);
        try migrator.migrate(conn, &catalog_schema);

        try conn.exec("INSERT INTO providers (id, name, base_url, api_style) VALUES (1, 'prov', 'url', 'openai')");
        try conn.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, account_ref, priority) VALUES (1, 1, 'lbl', 'secret', 'acc1', 5)");
        try conn.exec("INSERT INTO models (id, provider_id, model_name, is_generative) VALUES (1, 1, 'mdl', 1)");

        const integrity = try conn.prepare("PRAGMA integrity_check");
        defer conn.finalize(integrity);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(integrity));
        const ok_ptr = c.sqlite3_column_text(integrity, 0) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqualStrings("ok", std.mem.span(ok_ptr));
    }

    // 3. ledger.db test
    {
        var conn = try Connection.open(allocator, ":memory:");
        defer conn.close();
        const migrator = Migrator.init(allocator);
        try migrator.migrate(conn, &ledger_schema);

        try conn.exec("INSERT INTO usage_records (id, ts, provider, model, tokens_in, tokens_out, cost_usd) VALUES (1, 100, 'p', 'm', 10, 20, 0.05)");

        const integrity = try conn.prepare("PRAGMA integrity_check");
        defer conn.finalize(integrity);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(integrity));
        const ok_ptr = c.sqlite3_column_text(integrity, 0) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqualStrings("ok", std.mem.span(ok_ptr));
    }
}

test "E5.23 additive attachment migration preserves old orders and enforces bounds" {
    const a = std.testing.allocator;
    var conn = try Connection.open(a, ":memory:");
    defer conn.close();
    const migrator = Migrator.init(a);
    try migrator.migrate(conn, runtime_schema[0..42]);
    try conn.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(23,'fixture','preserve me','pending',1)");
    try migrator.migrate(conn, &runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());
    try migrator.migrate(conn, &runtime_schema);
    const order = try conn.prepare("SELECT user_prompt FROM orders WHERE id=23");
    defer conn.finalize(order);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(order));
    try std.testing.expectEqualStrings("preserve me", std.mem.span(c.sqlite3_column_text(order, 0).?));
    for (0..4) |i| {
        const sql = try std.fmt.allocPrint(a, "INSERT INTO order_attachments VALUES(23,'{s}{d}','x.png','image/png','png',1,1,1,'attachments/23/x.png')", .{ "000000000000000000000000000000000000000000000000000000000000000", i });
        defer a.free(sql);
        try conn.exec(sql);
    }
    try std.testing.expectError(error.ExecFailed, conn.exec("INSERT INTO order_attachments VALUES(23,'0000000000000000000000000000000000000000000000000000000000000004','x.png','image/png','png',1,1,1,'attachments/23/x.png')"));
    try std.testing.expectError(error.ExecFailed, conn.exec("INSERT INTO order_attachments VALUES(404,'0000000000000000000000000000000000000000000000000000000000000004','x.png','image/png','png',1,1,1,'attachments/404/x.png')"));
    try std.testing.expectError(error.ExecFailed, conn.exec("INSERT INTO order_attachments VALUES(24,'bad','x.png','image/png','png',1,1,1,'attachments/24/x.png')"));
    const integrity = try conn.prepare("PRAGMA integrity_check");
    defer conn.finalize(integrity);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(integrity));
    try std.testing.expectEqualStrings("ok", std.mem.span(c.sqlite3_column_text(integrity, 0).?));
}

test "E5.55: migration initializes external CLI settings without replacing user values" {
    const a = std.testing.allocator;
    var conn = try Connection.open(a, ":memory:");
    defer conn.close();
    var m = Migrator.init(a);
    try m.migrate(conn, &catalog_schema);
    const q = try conn.prepare("SELECT value FROM settings WHERE key='external_agent_paths'");
    defer conn.finalize(q);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(q));
    try std.testing.expectEqualStrings("{}", std.mem.span(c.sqlite3_column_text(q, 0)));
    try conn.exec("UPDATE settings SET value='{\"codex\":\"C:/custom.exe\"}' WHERE key='external_agent_paths'");
    try m.migrate(conn, &catalog_schema);
    const check = try conn.prepare("SELECT value FROM settings WHERE key='external_agent_paths'");
    defer conn.finalize(check);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(check));
    try std.testing.expectEqualStrings("{\"codex\":\"C:/custom.exe\"}", std.mem.span(c.sqlite3_column_text(check, 0)));
}

// ── DS-SQLITE-INDICES (2026-10-16): las dos consultas de lectura calientes ──
//
// listSessions (session_store.zig:168-169) ordena `orders` por `created_at DESC`
// y los eventos por orden (c_api.zig:6911/9851) filtran por `events.order_id`
// ordenando por `ts ASC, id ASC`. Antes de la migración de índices ambas hacían
// un escaneo completo (listSessions además con `USE TEMP B-TREE FOR ORDER BY`).
// El test imprime el plan REAL (EXPLAIN QUERY PLAN) para que la evidencia
// rojo/verde sea salida cruda y no una afirmación de texto.

/// Devuelve el detalle de EXPLAIN QUERY PLAN concatenado (y lo imprime).
fn dumpEqp(conn: Connection, sql: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(std.testing.allocator);
    const esql = try std.fmt.allocPrint(std.testing.allocator, "EXPLAIN QUERY PLAN {s}", .{sql});
    defer std.testing.allocator.free(esql);
    const stmt = try conn.prepare(esql);
    defer conn.finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const p = c.sqlite3_column_text(stmt, 3);
        const n = c.sqlite3_column_bytes(stmt, 3);
        if (p == null) continue;
        const line = p[0..@intCast(n)];
        std.debug.print("    EQP: {s}\n", .{line});
        try buf.appendSlice(std.testing.allocator, line);
        try buf.append(std.testing.allocator, '\n');
    }
    return buf.toOwnedSlice(std.testing.allocator);
}

test "SQLITE-INDICES: consultas calientes de lectura usan indice" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = Migrator.init(allocator);
    try migrator.migrate(conn, &runtime_schema);

    // Query exacta de listSessions (session_store.zig:169). El ORDER BY es
    // `created_at DESC` (columna de `orders`).
    const list_sessions_sql = "SELECT o.id, o.status, o.created_at FROM orders o " ++
        "WHERE substr(o.project_id, 1, 2) <> 'DEV' ORDER BY created_at DESC";
    // Query exacta de eventos por orden (c_api.zig:6911). Filtro `order_id` y
    // ORDER BY `ts ASC, id ASC`.
    const events_by_order_sql = "SELECT id, ts, source, kind, payload_json FROM events " ++
        "WHERE order_id = ? ORDER BY ts ASC, id ASC LIMIT ? OFFSET ?";

    // Se calculan e imprimen LOS DOS planes antes de afirmar nada, para que la
    // evidencia roja muestre ambos aunque el primer expect falle.
    const plan_orders = try dumpEqp(conn, list_sessions_sql);
    defer allocator.free(plan_orders);
    const plan_events = try dumpEqp(conn, events_by_order_sql);
    defer allocator.free(plan_events);

    try std.testing.expect(std.mem.indexOf(u8, plan_orders, "USING INDEX idx_orders_created") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_orders, "TEMP B-TREE") == null);
    try std.testing.expect(std.mem.indexOf(u8, plan_events, "SEARCH events USING INDEX idx_events_order") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_events, "SCAN events") == null);
}

test "SQLITE-INDICES: base del esquema anterior migra sin error" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = Migrator.init(allocator);
    // Esquema PREVIO: sin la migración de índices (V47, índice 46). Fijo: ya
    // no es la última migración.
    try migrator.migrate(conn, runtime_schema[0..46]);
    try std.testing.expectEqual(@as(i32, 46), try conn.getUserVersion());
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','preservame','done',1)");
    // La migración pendiente debe aplicar sin error y sin perder el dato.
    try migrator.migrate(conn, &runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());
    // Idempotente: volver a migrar no falla.
    try migrator.migrate(conn, &runtime_schema);
    {
        const st = try conn.prepare("SELECT user_prompt FROM orders WHERE id = 1");
        defer conn.finalize(st);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st));
        try std.testing.expectEqualStrings("preservame", std.mem.span(c.sqlite3_column_text(st, 0)));
    }
    // Los dos índices existen en sqlite_master.
    {
        const st = try conn.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_events_order','idx_orders_created')");
        defer conn.finalize(st);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st));
        try std.testing.expectEqual(@as(c_int, 2), c.sqlite3_column_int(st, 0));
    }
}

fn cab003HasColumn(conn: Connection, table: []const u8, column: []const u8) !bool {
    const sql = try std.fmt.allocPrint(std.testing.allocator, "PRAGMA table_info({s})", .{table});
    defer std.testing.allocator.free(sql);
    const st = try conn.prepare(sql);
    defer conn.finalize(st);
    while (c.sqlite3_step(st) == c.SQLITE_ROW) {
        const name_ptr = c.sqlite3_column_text(st, 1);
        const name_len = c.sqlite3_column_bytes(st, 1);
        if (name_ptr == null) continue;
        if (std.mem.eql(u8, name_ptr[0..@intCast(name_len)], column)) return true;
    }
    return false;
}

test "CK-CAB-003 archivo: base existente migra añadiendo orders.archived_at sin perder datos" {
    const allocator = std.testing.allocator;
    var conn = try Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = Migrator.init(allocator);

    // Esquema PREVIO: exactamente el de antes de esta tarea (hasta la
    // migración de la columna de archivo, sin incluirla; añadió
    // migraciones después). Una base ya en producción no tiene `archived_at`
    // cuando el usuario actualiza.
    const idx_archivo = for (runtime_schema, 0..) |sql, i| {
        if (std.mem.indexOf(u8, sql, "ADD COLUMN archived_at") != null) break i;
    } else unreachable;
    try migrator.migrate(conn, runtime_schema[0..idx_archivo]);
    try std.testing.expect(!try cab003HasColumn(conn, "orders", "archived_at"));
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','preservame','done',1)");

    // La migración pendiente añade la columna sin tocar la fila existente.
    try migrator.migrate(conn, &runtime_schema);
    try std.testing.expect(try cab003HasColumn(conn, "orders", "archived_at"));
    try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());

    {
        const st = try conn.prepare("SELECT user_prompt, archived_at FROM orders WHERE id = 1");
        defer conn.finalize(st);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st));
        try std.testing.expectEqualStrings("preservame", std.mem.span(c.sqlite3_column_text(st, 0)));
        try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(st, 1));
    }

    // Idempotente: volver a migrar no falla ni duplica la columna.
    try migrator.migrate(conn, &runtime_schema);
    try std.testing.expect(try cab003HasColumn(conn, "orders", "archived_at"));
}

// ── (2026-10-18): respaldo del estado propio antes de migrar ────
//
// Antes de aplicar migraciones pendientes sobre una base que ya existe y tiene
// estructura, el migrador copia la base con `VACUUM INTO '<base>.bak-v<vieja>-
// <AAAAMMDD-HHMMSS>'` (UTC) junto a la base; si la copia falla, la migración
// no se aplica (error.BackupFailed). Se conservan como máximo
// `max_db_backups` copias por base, borrando solo archivos con ese patrón;
// si la poda no puede garantizar ese máximo (r2), la migración tampoco se
// aplica (error.BackupRetentionFailed) y la copia nueva se queda.
//
// Las pruebas usan SOLO la API pública existente (Connection.open +
// Migrator.init/migrate) y observan el sistema de archivos: así la corrida en
// rojo (sin el respaldo implementado) falla por aserción, no por compilación.

/// Cuenta archivos (no directorios) dentro de `dir_path` cuyo nombre contiene
/// `needle`. Rutas relativas al cwd de las pruebas (tmpDir vive dentro del
/// worktree, en.zig-cache/tmp). Enumeración por la vía W.
fn comp003CountBackups(allocator: std.mem.Allocator, dir_path: []const u8, needle: []const u8) !usize {
    const pattern = if (dir_path.len == 0)
        try std.fmt.allocPrint(allocator, "{s}*", .{needle})
    else
        try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}*", .{ dir_path, needle });
    defer allocator.free(pattern);
    const pattern_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, pattern);
    defer allocator.free(pattern_w);
    var fd: WIN32_FIND_DATAW = undefined;
    const h = FindFirstFileW(pattern_w, @ptrCast(&fd));
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return 0;
    defer _ = FindClose(h);
    var count: usize = 0;
    while (true) {
        const zlen = std.mem.indexOfScalar(u16, &fd.cFileName, 0) orelse fd.cFileName.len;
        const name = try std.unicode.utf16LeToUtf8Alloc(allocator, fd.cFileName[0..zlen]);
        defer allocator.free(name);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 and
            std.mem.indexOf(u8, name, needle) != null) count += 1;
        if (FindNextFileW(h, @ptrCast(&fd)) == 0) break;
    }
    return count;
}

/// Devuelve la ruta (heap) del primer archivo cuyo nombre contiene `needle`,
/// o null si no hay ninguno. La libera el llamador.
fn comp003FindBackupPath(allocator: std.mem.Allocator, dir_path: []const u8, needle: []const u8) !?[]u8 {
    const pattern = if (dir_path.len == 0)
        try std.fmt.allocPrint(allocator, "{s}*", .{needle})
    else
        try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}*", .{ dir_path, needle });
    defer allocator.free(pattern);
    const pattern_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, pattern);
    defer allocator.free(pattern_w);
    var fd: WIN32_FIND_DATAW = undefined;
    const h = FindFirstFileW(pattern_w, @ptrCast(&fd));
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return null;
    defer _ = FindClose(h);
    while (true) {
        const zlen = std.mem.indexOfScalar(u16, &fd.cFileName, 0) orelse fd.cFileName.len;
        const name = try std.unicode.utf16LeToUtf8Alloc(allocator, fd.cFileName[0..zlen]);
        defer allocator.free(name);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 and
            std.mem.indexOf(u8, name, needle) != null)
        {
            return try std.fs.path.join(allocator, &.{ dir_path, name });
        }
        if (FindNextFileW(h, @ptrCast(&fd)) == 0) break;
    }
    return null;
}

/// Comprueba que el nombre termina en `<needle><AAAAMMDD>-<HHMMSS>` (8 dígitos,
/// guion, 6 dígitos) para que la evidencia fije el formato documentado.
fn comp003BackupNameShapeOk(needle: []const u8, name: []const u8) bool {
    const at = std.mem.indexOf(u8, name, needle) orelse return false;
    const rest = name[at + needle.len ..];
    if (rest.len != 8 + 1 + 6) return false;
    for (rest[0..8]) |ch| if (!std.ascii.isDigit(ch)) return false;
    if (rest[8] != '-') return false;
    for (rest[9..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

test "CK-COMP-003: base con datos y migracion pendiente se respalda y la copia conserva los datos" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_abs);
    const db_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "comp003_t1.db", .{dir_abs});
    defer a.free(db_path);

    // Base "de producción": esquema viejo (V1..V5) y datos del usuario.
    {
        var conn = try Connection.open(a, db_path);
        defer conn.close();
        var m = Migrator.init(a);
        try m.migrate(conn, runtime_schema[0..5]);
        try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','dato uno','done',10)");
        try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (2,'p','dato dos','done',20)");
    }

    // Segunda apertura: hay migraciones pendientes → copia antes de tocar.
    {
        var conn = try Connection.open(a, db_path);
        defer conn.close();
        var m = Migrator.init(a);
        try m.migrate(conn, &runtime_schema);
        try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());
    }

    try std.testing.expectEqual(@as(usize, 1), try comp003CountBackups(a, dir_abs, "comp003_t1.db.bak-v"));
    const bak_path = (try comp003FindBackupPath(a, dir_abs, "comp003_t1.db.bak-v5-")) orelse return error.TestUnexpectedNull;
    defer a.free(bak_path);
    // El nombre cumple el patrón documentado: .bak-v5-AAAAMMDD-HHMMSS.
    try std.testing.expect(comp003BackupNameShapeOk(".bak-v5-", std.fs.path.basename(bak_path)));

    // La copia contiene los datos de ANTES y la versión antigua.
    var bak = try Connection.open(a, bak_path);
    defer bak.close();
    try std.testing.expectEqual(@as(i32, 5), try bak.getUserVersion());
    {
        const st = try bak.prepare("SELECT COUNT(*) FROM orders");
        defer bak.finalize(st);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st));
        try std.testing.expectEqual(@as(c_int, 2), c.sqlite3_column_int(st, 0));
    }
    {
        const st = try bak.prepare("SELECT user_prompt FROM orders WHERE id = 1");
        defer bak.finalize(st);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st));
        try std.testing.expectEqualStrings("dato uno", std.mem.span(c.sqlite3_column_text(st, 0)));
    }
}

test "CK-COMP-003: sin migraciones pendientes no se crea copia" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_abs);
    const db_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "comp003_t2.db", .{dir_abs});
    defer a.free(db_path);

    {
        var conn = try Connection.open(a, db_path);
        defer conn.close();
        var m = Migrator.init(a);
        // Base nueva vacía: aplica todo el esquema; no hay nada que respaldar.
        try m.migrate(conn, &runtime_schema);
        try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','dato','done',10)");
    }
    // Segunda apertura sin pendientes: idempotente y sin copia.
    {
        var conn = try Connection.open(a, db_path);
        defer conn.close();
        var m = Migrator.init(a);
        try m.migrate(conn, &runtime_schema);
        try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());
    }

    try std.testing.expectEqual(@as(usize, 0), try comp003CountBackups(a, dir_abs, "comp003_t2.db.bak-v"));
}

test "CK-COMP-003: base nueva vacia no se respalda" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_abs);
    const db_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "comp003_t3.db", .{dir_abs});
    defer a.free(db_path);

    // Archivo recién creado por sqlite3_open (sin tablas): migrar de 0 no copia.
    var conn = try Connection.open(a, db_path);
    defer conn.close();
    var m = Migrator.init(a);
    try m.migrate(conn, &runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());

    try std.testing.expectEqual(@as(usize, 0), try comp003CountBackups(a, dir_abs, "comp003_t3.db.bak-v"));
}

test "CK-COMP-003: cuatro migraciones sucesivas dejan como maximo 3 copias" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_abs);
    const db_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "comp003_t4.db", .{dir_abs});
    defer a.free(db_path);

    var conn = try Connection.open(a, db_path);
    defer conn.close();
    var m = Migrator.init(a);
    // Base nueva (v0→v4): sin copia, nada que perder.
    try m.migrate(conn, runtime_schema[0..4]);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','dato','done',10)");
    // Cuatro corridas con UNA migración pendiente cada una (como cuatro
    // aperturas de la cabina tras cuatro versiones nuevas): 4 copias → poda a 3.
    try m.migrate(conn, runtime_schema[0..5]);
    try m.migrate(conn, runtime_schema[0..6]);
    try m.migrate(conn, runtime_schema[0..7]);
    try m.migrate(conn, runtime_schema[0..8]);

    try std.testing.expectEqual(@as(usize, 3), try comp003CountBackups(a, dir_abs, "comp003_t4.db.bak-v"));
    // Se conservan las 3 más recientes (v5, v6, v7) y se podó la v4.
    try std.testing.expectEqual(@as(usize, 1), try comp003CountBackups(a, dir_abs, "comp003_t4.db.bak-v5-"));
    try std.testing.expectEqual(@as(usize, 1), try comp003CountBackups(a, dir_abs, "comp003_t4.db.bak-v6-"));
    try std.testing.expectEqual(@as(usize, 1), try comp003CountBackups(a, dir_abs, "comp003_t4.db.bak-v7-"));
    try std.testing.expectEqual(@as(usize, 0), try comp003CountBackups(a, dir_abs, "comp003_t4.db.bak-v4-"));
}

test "CK-COMP-003: copia imposible → BackupFailed y la migracion no se aplica" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_abs);
    const db_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "comp003_t5.db", .{dir_abs});
    defer a.free(db_path);

    {
        var setup = try Connection.open(a, db_path);
        defer setup.close();
        var m = Migrator.init(a);
        try m.migrate(setup, runtime_schema[0..1]);
        try setup.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','dato','done',10)");
    }

    var conn = try Connection.open(a, db_path);
    defer conn.close();
    var m = Migrator.init(a);
    // Simulación de copia imposible: `VACUUM INTO` —y solo él— falla de forma
    // garantizada dentro de una transacción abierta de la MISMA conexión
    // (SQLite lo rechaza con SQLITE_ERROR). Es el mismo camino de código que
    // un disco lleno o un permiso denegado: el VACUUM falla y la migración
    // no puede continuar.
    try conn.exec("BEGIN");
    const result = m.migrate(conn, runtime_schema[0..2]);
    try conn.exec("ROLLBACK");
    try std.testing.expectError(error.BackupFailed, result);

    // La base quedó intacta: versión antigua y sin copia creada.
    try std.testing.expectEqual(@as(i32, 1), try conn.getUserVersion());
    try std.testing.expectEqual(@as(usize, 0), try comp003CountBackups(a, dir_abs, "comp003_t5.db.bak-v"));
}

test "CK-COMP-003: si no se puede podar una copia vieja, BackupRetentionFailed y la migracion no se aplica" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_abs);
    const db_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "comp003_t6.db", .{dir_abs});
    defer a.free(db_path);
    const oldest = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "comp003_t6.db.bak-v1-20260101-000001", .{dir_abs});
    defer a.free(oldest);

    {
        var setup = try Connection.open(a, db_path);
        defer setup.close();
        var m = Migrator.init(a);
        try m.migrate(setup, runtime_schema[0..1]);
        try setup.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','dato','done',10)");
        // Tres copias antiguas VÁLIDAS con el patrón exacto y marcas de
        // 2026-01-01 (anteriores a cualquier copia nueva de hoy).
        const stamps = [_][]const u8{ "20260101-000001", "20260101-000002", "20260101-000003" };
        for (stamps) |stamp| {
            const p = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "comp003_t6.db.bak-v1-{s}", .{ dir_abs, stamp });
            defer a.free(p);
            const esc = try escapeSqlLiteral(a, p);
            defer a.free(esc);
            const sql = try std.fmt.allocPrint(a, "VACUUM INTO '{s}'", .{esc});
            defer a.free(sql);
            try setup.exec(sql);
        }
    }

    // La copia MÁS antigua queda de solo lectura: DeleteFileW fallará con
    // ERROR_ACCESS_DENIED y la poda no podrá garantizar el máximo de 3.
    const oldest_w = try std.unicode.utf8ToUtf16LeAllocZ(a, oldest);
    defer a.free(oldest_w);
    try std.testing.expect(SetFileAttributesW(oldest_w, FILE_ATTRIBUTE_READONLY) != 0);
    defer _ = SetFileAttributesW(oldest_w, FILE_ATTRIBUTE_NORMAL);

    var conn = try Connection.open(a, db_path);
    defer conn.close();
    var m = Migrator.init(a);
    const result = m.migrate(conn, runtime_schema[0..2]);
    try std.testing.expectError(error.BackupRetentionFailed, result);

    // Sin retención no hay migración: la versión sigue siendo la antigua...
    try std.testing.expectEqual(@as(i32, 1), try conn.getUserVersion());
    // ...la copia recién hecha se queda (4 copias: no se pudo podar)...
    try std.testing.expectEqual(@as(usize, 4), try comp003CountBackups(a, dir_abs, "comp003_t6.db.bak-v"));
    // ...y la copia no borrable sigue en su sitio.
    try std.testing.expectEqual(@as(usize, 1), try comp003CountBackups(a, dir_abs, "comp003_t6.db.bak-v1-20260101-000001"));
}

// ── QA-A H1 (14-nov): primer arranque concurrente ─────────────────────────
// Ocho conexiones independientes (como ocho procesos: cada una con su handle
// de SQLite y su handle del bloqueo) migran a la vez una base NUEVA. Sin el
// bloqueo y la transacción, varias aplicaban la misma migración y fallaban
// (`duplicate column name`, `table … already exists`) o dejaban
// `user_version` por detrás de lo aplicado.

fn qaA1TmpDbPath(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const dir_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_abs);
    return std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ dir_abs, name });
}

test "QA-A H1: ocho conexiones migrando a la vez una base nueva terminan todas bien" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const []const u8{ &runtime_schema, &catalog_schema }, 0..) |schema, idx| {
        const db_path = try qaA1TmpDbPath(a, &tmp, if (idx == 0) "qa_a_h1_runtime.db" else "qa_a_h1_catalog.db");
        defer a.free(db_path);
        const Worker = struct {
            fn run(path: []const u8, s: []const []const u8, fails: *std.atomic.Value(u32), first_error: *[256]u8) void {
                const ca = std.heap.c_allocator;
                var conn = Connection.open(ca, path) catch {
                    _ = fails.fetchAdd(1, .monotonic);
                    return;
                };
                defer conn.close();
                Migrator.init(ca).migrate(conn, s) catch {
                    if (fails.fetchAdd(1, .monotonic) == 0) {
                        _ = std.fmt.bufPrint(first_error, "{s}", .{migrateFailureText()}) catch {};
                    }
                };
            }
        };
        var fails = std.atomic.Value(u32).init(0);
        var first_error: [256]u8 = [_]u8{0} ** 256;
        var threads: [8]std.Thread = undefined;
        for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ db_path, schema, &fails, &first_error });
        for (threads) |t| t.join();
        if (fails.load(.monotonic) != 0) {
            std.debug.print("QA-A H1: {d} de 8 fallaron; primero: {s}\n", .{ fails.load(.monotonic), std.mem.sliceTo(&first_error, 0) });
        }
        try std.testing.expectEqual(@as(u32, 0), fails.load(.monotonic));
        var check = try Connection.open(a, db_path);
        defer check.close();
        try std.testing.expectEqual(@as(i32, @intCast(schema.len)), try check.getUserVersion());
        // Una base NUEVA no se respalda: ninguna conexión vio tablas a medias.
        const base_name = std.fs.path.basename(db_path);
        const dir_abs = std.fs.path.dirname(db_path).?;
        const needle = try std.fmt.allocPrint(a, "{s}.bak-v", .{base_name});
        defer a.free(needle);
        try std.testing.expectEqual(@as(usize, 0), try comp003CountBackups(a, dir_abs, needle));
    }
}

test "QA-A H1: una base que quedó a medias (versión N con la N+1 aplicada en parte) se repara sola" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try qaA1TmpDbPath(a, &tmp, "qa_a_h1_half.db");
    defer a.free(db_path);
    // La migración de varias sentencias que el arranque concurrente dejaba a
    // medias: `ALTER TABLE webhooks ADD COLUMN format …; CREATE TABLE
    // webhook_outbox …`.
    const marker = "ALTER TABLE webhooks ADD COLUMN format";
    const idx = for (runtime_schema, 0..) |m, i| {
        if (std.mem.startsWith(u8, m, marker)) break i;
    } else return error.TestUnexpectedResult;
    {
        var conn = try Connection.open(a, db_path);
        defer conn.close();
        try Migrator.init(a).migrate(conn, runtime_schema[0..idx]);
        // Solo la primera sentencia, fuera de transacción, y sin subir la
        // versión: el estado exacto que dejaba un proceso cortado.
        const first_stmt_end = std.mem.indexOfScalar(u8, runtime_schema[idx], ';').?;
        try conn.exec(runtime_schema[idx][0 .. first_stmt_end + 1]);
        try std.testing.expectEqual(@as(i32, @intCast(idx)), try conn.getUserVersion());
    }
    var conn = try Connection.open(a, db_path);
    defer conn.close();
    try Migrator.init(a).migrate(conn, &runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(runtime_schema.len)), try conn.getUserVersion());
    // Lo que faltaba de esa migración está: la tabla y su disparador.
    const q = try conn.prepare("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('webhook_outbox','webhook_order_transition')");
    defer conn.finalize(q);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(q));
    try std.testing.expectEqual(@as(i64, 2), c.sqlite3_column_int64(q, 0));
}

test "T12 B2: reparar no da por buena una tabla, un índice o una columna que existen con otra definición" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Case = struct { name: []const u8, pre: []const u8, ok: bool, cause: []const u8 };
    const schema = [_][]const u8{
        "CREATE TABLE base (id INTEGER PRIMARY KEY);",
        \\CREATE TABLE hijos (
        \\  id INTEGER PRIMARY KEY,
        \\  nombre TEXT NOT NULL
        \\);
        \\CREATE INDEX idx_hijos_nombre ON hijos(nombre);
        \\ALTER TABLE base ADD COLUMN estado TEXT NOT NULL DEFAULT 'nuevo';
        \\ALTER TABLE base ADD COLUMN nota TEXT;
        ,
    };
    for ([_]Case{
        // Lo que ya existe es idéntico (con otro espaciado y mayúsculas): se completa.
        .{ .name = "t12_b2_igual.db", .pre = "CREATE TABLE \"hijos\" (id integer primary key,   nombre text not null); ALTER TABLE base ADD COLUMN estado text NOT NULL DEFAULT 'nuevo';", .ok = true, .cause = "" },
        .{ .name = "t12_b2_tabla.db", .pre = "CREATE TABLE hijos (id INTEGER PRIMARY KEY, nombre BLOB);", .ok = false, .cause = "«hijos» ya existe con otra definición" },
        .{ .name = "t12_b2_indice.db", .pre = "CREATE TABLE hijos (id INTEGER PRIMARY KEY, nombre TEXT NOT NULL); CREATE INDEX idx_hijos_nombre ON hijos(id);", .ok = false, .cause = "«idx_hijos_nombre» ya existe con otra definición" },
        .{ .name = "t12_b2_columna.db", .pre = "ALTER TABLE base ADD COLUMN estado INTEGER;", .ok = false, .cause = "la columna base.estado ya existe con otra definición" },
        .{ .name = "t12_b2_default.db", .pre = "ALTER TABLE base ADD COLUMN estado TEXT NOT NULL DEFAULT 'viejo';", .ok = false, .cause = "DEFAULT 'viejo'" },
    }) |case| {
        const db_path = try qaA1TmpDbPath(a, &tmp, case.name);
        defer a.free(db_path);
        var conn = try Connection.open(a, db_path);
        defer conn.close();
        try Migrator.init(a).migrate(conn, schema[0..1]);
        try conn.exec(case.pre);
        if (case.ok) {
            try Migrator.init(a).migrate(conn, &schema);
            try std.testing.expectEqual(@as(i32, 2), try conn.getUserVersion());
        } else {
            try std.testing.expectError(error.MigrateFailed, Migrator.init(a).migrate(conn, &schema));
            const text = migrateFailureText();
            if (std.mem.indexOf(u8, text, case.cause) == null) {
                std.debug.print("T12 B2 {s}: causa inesperada: {s}\n", .{ case.name, text });
                return error.TestUnexpectedResult;
            }
            try std.testing.expectEqual(@as(i32, 1), try conn.getUserVersion());
        }
    }
}

test "T12B B-3: reparar no da por bueno un CREATE TABLE IF NOT EXISTS sobre otra definición" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // La primera sentencia fuerza la reparación (columna ya presente); la
    // segunda es la que el auditor 3 demostró que pasaba sin compararse.
    const schema = [_][]const u8{
        "CREATE TABLE base (id INTEGER PRIMARY KEY);",
        "ALTER TABLE base ADD COLUMN estado TEXT NOT NULL DEFAULT 'nuevo'; CREATE TABLE IF NOT EXISTS hijos (id INTEGER PRIMARY KEY, nombre TEXT NOT NULL);",
    };
    const Case = struct { name: []const u8, pre: []const u8, ok: bool };
    for ([_]Case{
        .{ .name = "t12b_b3_igual.db", .pre = "ALTER TABLE base ADD COLUMN estado TEXT NOT NULL DEFAULT 'nuevo'; CREATE TABLE hijos (id INTEGER PRIMARY KEY, nombre TEXT NOT NULL);", .ok = true },
        .{ .name = "t12b_b3_distinta.db", .pre = "ALTER TABLE base ADD COLUMN estado TEXT NOT NULL DEFAULT 'nuevo'; CREATE TABLE hijos (id INTEGER PRIMARY KEY, nombre BLOB);", .ok = false },
    }) |case| {
        const db_path = try qaA1TmpDbPath(a, &tmp, case.name);
        defer a.free(db_path);
        var conn = try Connection.open(a, db_path);
        defer conn.close();
        try Migrator.init(a).migrate(conn, schema[0..1]);
        try conn.exec(case.pre);
        if (case.ok) {
            try Migrator.init(a).migrate(conn, &schema);
            try std.testing.expectEqual(@as(i32, 2), try conn.getUserVersion());
        } else {
            try std.testing.expectError(error.MigrateFailed, Migrator.init(a).migrate(conn, &schema));
            const text = migrateFailureText();
            try std.testing.expect(std.mem.indexOf(u8, text, "«hijos» ya existe con otra definición") != null);
            try std.testing.expectEqual(@as(i32, 1), try conn.getUserVersion());
        }
    }
}

test "T12B B-3: IF NOT EXISTS compara también en el primer intento sin reparación previa" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |same| {
        var conn = try Connection.open(a, ":memory:");
        defer conn.close();
        try conn.exec(if (same) "CREATE TABLE Hijos (id INTEGER PRIMARY KEY, nombre TEXT NOT NULL)" else "CREATE TABLE Hijos (id INTEGER PRIMARY KEY, nombre BLOB)");
        const schema = [_][]const u8{"CREATE TABLE IF NOT EXISTS Hijos (id INTEGER PRIMARY KEY, nombre TEXT NOT NULL);"};
        if (same) {
            try Migrator.init(a).migrate(conn, &schema);
            try std.testing.expectEqual(@as(i32, 1), try conn.getUserVersion());
        } else {
            try std.testing.expectError(error.MigrateFailed, Migrator.init(a).migrate(conn, &schema));
            try std.testing.expectEqual(@as(i32, 0), try conn.getUserVersion());
        }
    }
}

test "T12B B-2: migración de origen de aprobaciones es idempotente y conserva las filas anteriores" {
    const a = std.testing.allocator;
    var conn = try Connection.open(a, ":memory:");
    defer conn.close();
    const n = runtime_schema.len;
    try Migrator.init(a).migrate(conn, runtime_schema[0 .. n - 1]);
    try conn.exec("INSERT INTO approvals(task_id, description, created_at) VALUES ('old', 'previa', 1)");
    try Migrator.init(a).migrate(conn, &runtime_schema);
    try conn.exec("UPDATE approvals SET origin = 'persistente' WHERE task_id = 'old'");
    // Simula la migración aplicada antes de registrar su versión.
    try conn.setUserVersion(@intCast(n - 1));
    try Migrator.init(a).migrate(conn, &runtime_schema);
    try Migrator.init(a).migrate(conn, &runtime_schema);
    const q = try conn.prepare("SELECT origin FROM approvals WHERE task_id = 'old'");
    defer conn.finalize(q);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(q));
    try std.testing.expectEqualStrings("persistente", std.mem.span(c.sqlite3_column_text(q, 0)));
    try std.testing.expectEqual(@as(i32, @intCast(n)), try conn.getUserVersion());
}

test "QA-A H1: una migración que falla de verdad dice cuál y por qué, y no deja nada a medias" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try qaA1TmpDbPath(a, &tmp, "qa_a_h1_bad.db");
    defer a.free(db_path);
    const schema = [_][]const u8{
        "CREATE TABLE uno (x INTEGER);",
        "CREATE TABLE dos (y INTEGER); ESTO NO ES SQL;",
    };
    var conn = try Connection.open(a, db_path);
    defer conn.close();
    try std.testing.expectError(error.MigrateFailed, Migrator.init(a).migrate(conn, &schema));
    const text = migrateFailureText();
    try std.testing.expect(std.mem.indexOf(u8, text, "migración 2 de 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "syntax error") != null);
    try std.testing.expectEqual(@as(i32, 1), try conn.getUserVersion());
    // La transacción deshizo la primera sentencia de la migración fallida.
    const q = try conn.prepare("SELECT COUNT(*) FROM sqlite_master WHERE name = 'dos'");
    defer conn.finalize(q);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(q));
    try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(q, 0));
}

test "QA-B 7 (CK-MOT-029): el fallo de una migración nombra la copia previa que se hizo" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try qaA1TmpDbPath(a, &tmp, "mot029_bak.db");
    defer a.free(db_path);
    var conn = try Connection.open(a, db_path);
    defer conn.close();
    // v1 con una tabla: la base ya «tiene datos» y la siguiente migración copia.
    try Migrator.init(a).migrate(conn, &.{"CREATE TABLE uno (x INTEGER);"});
    const schema = [_][]const u8{
        "CREATE TABLE uno (x INTEGER);",
        "CREATE TABLE dos (y INTEGER); ESTO NO ES SQL;",
    };
    try std.testing.expectError(error.MigrateFailed, Migrator.init(a).migrate(conn, &schema));
    const text = migrateFailureText();
    try std.testing.expect(std.mem.indexOf(u8, text, "migración 2 de 2") != null);
    const expected = try std.fmt.allocPrint(a, "{s}.bak-v1-", .{db_path});
    defer a.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renómbrala sobre") != null);
    // Una base nueva (sin tablas) no se copia: el mensaje no inventa una copia.
    const fresh_path = try qaA1TmpDbPath(a, &tmp, "mot029_fresh.db");
    defer a.free(fresh_path);
    var fresh = try Connection.open(a, fresh_path);
    defer fresh.close();
    try std.testing.expectError(error.MigrateFailed, Migrator.init(a).migrate(fresh, &schema));
    try std.testing.expect(std.mem.indexOf(u8, migrateFailureText(), ".bak-v") == null);
}

test "CK-PRV-004 C4 migration creates persistent independent switches" {
    const a = std.testing.allocator;
    var conn = try Connection.open(a, ":memory:");
    defer conn.close();
    try Migrator.init(a).migrate(conn, &catalog_schema);
    const q = try conn.prepare("PRAGMA table_info(model_preferences)");
    defer conn.finalize(q);
    var columns: usize = 0;
    while (c.sqlite3_step(q) == c.SQLITE_ROW) : (columns += 1) {}
    try std.testing.expectEqual(@as(usize, 4), columns);
}
