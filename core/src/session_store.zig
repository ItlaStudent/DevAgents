const std = @import("std");
const db = @import("db.zig");

/// Un mensaje en una sesión de conversación.
pub const Message = struct {
    id: i64,
    order_id: i64,
    role: []const u8,
    content: []const u8,
    created_at: i64,
};

/// Info resumida de una sesión/orden.
pub const SessionInfo = struct {
    id: i64,
    title: []const u8,
    status: []const u8,
    created_at: i64,
    /// Hilo al que pertenece esta orden, o cadena vacia si no tiene.
    ///
    /// Existe para que la barra lateral pueda AGRUPAR. Una conversacion con
    /// cinco peticiones son cinco ordenes —y por tanto cinco filas— aunque el
    /// contexto sea continuo: el agente se acuerda de todo y el panel lo
    /// enseñaba troceado. El vinculo ya se escribia en `orders`
    /// (`setOrderConversationId`); lo unico que faltaba era exponerlo.
    conversation_id: []const u8,
    /// epoch SEGUNDOS en que la sesión se archivó, o 0 si sigue
    /// activa. El historial de la cabina oculta las archivadas por defecto; el
    /// interruptor «Ver archivadas» las pide aparte y ofrece «Restaurar».
    archived_at: i64,
};

/// qué sesiones devuelve el listado.
pub const SessionFilter = enum {
    /// Solo las activas (archived_at IS NULL). Es el comportamiento por defecto.
    active,
    /// Solo las archivadas (archived_at IS NOT NULL).
    archived,
    /// Todas, activas y archivadas.
    all,
};

/// Abstracción de almacén de sesiones (SESSIONS-PERSIST-06).
/// MVP: solo backend SQLite (runtime.db). La frontera está lista
/// para enchufar Postgres/remoto en el futuro sin tocar la GUI.
/// M8: prefijo de `project_id` reservado para las ordenes que lanza la propia
/// maquinaria, no el usuario. Va como prefijo y no como bandera booleana para
/// que el origen concreto siga siendo legible en la base (`__selftest`,
/// `__probe`...) sin migrar el esquema.
pub const INTERNAL_PROJECT_PREFIX = "__";

/// El `project_id` con el que corre el gate de aceptacion.
pub const SELFTEST_PROJECT = INTERNAL_PROJECT_PREFIX ++ "selftest";

pub const SessionStore = struct {
    /// Guarda un mensaje de conversación.
    saveMessage: *const fn (ctx: *anyopaque, order_id: i64, role: []const u8, content: []const u8, created_at: i64) db.DbError!void,
    /// Carga todos los mensajes de una orden, ordenados por created_at ASC.
    loadMessages: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, order_id: i64) db.DbError![]Message,
    /// Lista todas las sesiones ordenadas por created_at DESC.
    listSessions: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) db.DbError![]SessionInfo,
    /// como `listSessions` pero elige activas, archivadas o todas.
    listSessionsFiltered: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, filter: SessionFilter) db.DbError![]SessionInfo,
    /// archiva o desarchiva una sesión — TODAS las órdenes de su
    /// `conversation_id`. Archivar solo marca las órdenes terminales (una orden
    /// en curso nunca se archiva); desarchivar limpia la marca. Never borra.
    archiveSession: *const fn (ctx: *anyopaque, order_id: i64, archived: bool) db.DbError!void,
    /// archiva en UNA transacción todas las órdenes terminales
    /// anteriores a `before_secs` (epoch segundos) y devuelve cuántas archivó.
    archiveBefore: *const fn (ctx: *anyopaque, before_secs: i64, expected_count: ?i64) db.DbError!i64,
    previewArchiveBefore: *const fn (ctx: *anyopaque, before_secs: i64) db.DbError!i64,
    /// Renombra una sesión (persiste title).
    renameSession: *const fn (ctx: *anyopaque, order_id: i64, title: []const u8) db.DbError!void,
    /// S8: borra una sesión y TODO lo que cuelga de ella.
    deleteSession: *const fn (ctx: *anyopaque, order_id: i64) db.DbError!void,
    /// FASE-AGENTIC-1: carga TODOS los mensajes de TODAS las órdenes que
    /// comparten `conversation_id`, ordenados por created_at ASC — el hilo de
    /// conversación completo, cruzando órdenes.
    loadConversationMessages: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, conversation_id: []const u8) db.DbError![]Message,
    /// FASE-AGENTIC-1: vincula una orden a un hilo de conversación.
    setConversationId: *const fn (ctx: *anyopaque, order_id: i64, conversation_id: []const u8) db.DbError!void,
    /// Libera recursos del backend si aplica.
    deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,

    ctx: *anyopaque,

    pub inline fn saveMessageFn(self: SessionStore, order_id: i64, role: []const u8, content: []const u8, created_at: i64) db.DbError!void {
        return self.saveMessage(self.ctx, order_id, role, content, created_at);
    }

    pub inline fn loadMessagesFn(self: SessionStore, allocator: std.mem.Allocator, order_id: i64) db.DbError![]Message {
        return self.loadMessages(self.ctx, allocator, order_id);
    }

    pub inline fn listSessionsFn(self: SessionStore, allocator: std.mem.Allocator) db.DbError![]SessionInfo {
        return self.listSessions(self.ctx, allocator);
    }

    pub inline fn listSessionsFilteredFn(self: SessionStore, allocator: std.mem.Allocator, filter: SessionFilter) db.DbError![]SessionInfo {
        return self.listSessionsFiltered(self.ctx, allocator, filter);
    }

    pub inline fn archiveSessionFn(self: SessionStore, order_id: i64, archived: bool) db.DbError!void {
        return self.archiveSession(self.ctx, order_id, archived);
    }

    pub inline fn archiveBeforeFn(self: SessionStore, before_secs: i64) db.DbError!i64 {
        return self.archiveBefore(self.ctx, before_secs, null);
    }

    pub inline fn previewArchiveBeforeFn(self: SessionStore, before_secs: i64) db.DbError!i64 {
        return self.previewArchiveBefore(self.ctx, before_secs);
    }

    pub inline fn archiveBeforeCheckedFn(self: SessionStore, before_secs: i64, expected_count: i64) db.DbError!i64 {
        return self.archiveBefore(self.ctx, before_secs, expected_count);
    }

    pub inline fn renameSessionFn(self: SessionStore, order_id: i64, title: []const u8) db.DbError!void {
        return self.renameSession(self.ctx, order_id, title);
    }

    pub inline fn deleteSessionFn(self: SessionStore, order_id: i64) db.DbError!void {
        return self.deleteSession(self.ctx, order_id);
    }

    pub inline fn loadConversationMessagesFn(self: SessionStore, allocator: std.mem.Allocator, conversation_id: []const u8) db.DbError![]Message {
        return self.loadConversationMessages(self.ctx, allocator, conversation_id);
    }

    pub inline fn setConversationIdFn(self: SessionStore, order_id: i64, conversation_id: []const u8) db.DbError!void {
        return self.setConversationId(self.ctx, order_id, conversation_id);
    }

    pub inline fn deinitFn(self: SessionStore, allocator: std.mem.Allocator) void {
        return self.deinit(self.ctx, allocator);
    }
};

// ── Backend SQLite (runtime.db) ────────────────────────────────────────

/// pub: MULTISESSION-P0 (2026-07-12) — expuesto para que sessionStoreForConn
/// pueda usarse como scratch space del LLAMADOR (p. ej. el stack de
/// dispatchApprovedOrder), en vez de requerir allocator.create como
/// createSqliteStore.
pub const SqliteBackend = struct {
    conn: db.Connection,

    fn saveMessage(ctx: *anyopaque, order_id: i64, role: []const u8, content: []const u8, created_at: i64) db.DbError!void {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        const stmt = try self.conn.prepare("INSERT INTO messages (order_id, role, content, created_at) VALUES (?, ?, ?, ?)");
        defer self.conn.finalize(stmt);
        try db.bindInt(stmt, 1, order_id);
        try db.bindText(stmt, 2, role);
        try db.bindText(stmt, 3, content);
        try db.bindInt(stmt, 4, created_at);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    fn loadMessages(ctx: *anyopaque, allocator: std.mem.Allocator, order_id: i64) db.DbError![]Message {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        const stmt = try self.conn.prepare("SELECT id, order_id, role, content, created_at FROM messages WHERE order_id = ? ORDER BY created_at ASC, id ASC");
        defer self.conn.finalize(stmt);
        try db.bindInt(stmt, 1, order_id);
        var list = std.ArrayList(Message).empty;
        errdefer {
            for (list.items) |m| {
                allocator.free(m.role);
                allocator.free(m.content);
            }
            list.deinit(allocator);
        }
        while (true) {
            const step = db.c.sqlite3_step(stmt);
            if (step == db.c.SQLITE_DONE) break;
            if (step != db.c.SQLITE_ROW) return error.ExecFailed;
            const id = db.c.sqlite3_column_int64(stmt, 0);
            const oid = db.c.sqlite3_column_int64(stmt, 1);
            const role_ptr = db.c.sqlite3_column_text(stmt, 2);
            const role_len = db.c.sqlite3_column_bytes(stmt, 2);
            const content_ptr = db.c.sqlite3_column_text(stmt, 3);
            const content_len = db.c.sqlite3_column_bytes(stmt, 3);
            const created = db.c.sqlite3_column_int64(stmt, 4);
            const role_copy = try allocator.dupe(u8, role_ptr[0..@intCast(role_len)]);
            errdefer allocator.free(role_copy);
            const content_copy = try allocator.dupe(u8, content_ptr[0..@intCast(content_len)]);
            try list.append(allocator, .{
                .id = id,
                .order_id = oid,
                .role = role_copy,
                .content = content_copy,
                .created_at = created,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    fn listSessions(ctx: *anyopaque, allocator: std.mem.Allocator) db.DbError![]SessionInfo {
        // el historial por defecto enseña solo lo activo. Las
        // archivadas se piden aparte con «Ver archivadas».
        return listSessionsFiltered(ctx, allocator, .active);
    }

    fn listSessionsFiltered(ctx: *anyopaque, allocator: std.mem.Allocator, filter: SessionFilter) db.DbError![]SessionInfo {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        // M8: el historial es del USUARIO. Las ordenes que lanza la propia
        // maquinaria —hoy el gate de aceptacion, que mete cuatro por pasada—
        // NO son conversaciones suyas y no deben llenarle la barra lateral.
        //
        // No se borran ni se ocultan de `devagents debug`: siguen siendo ordenes
        // de pleno derecho, con su traza y sus archivos. Lo unico que cambia es
        // que no aparecen en la lista de sesiones.
        //
        // Se compara con `substr` y NO con `LIKE '__%'`: en SQLite el guion bajo
        // es comodin de UN caracter, asi que ese patron casa con cualquier
        // cadena de dos o mas y ocultaba el historial ENTERO. Lo cazo el test,
        // no la lectura.
        // P2 (16-oct-2026): el titulo de la barra lateral sale del TEXTO DEL
        // USUARIO, no del "entendimiento" del planificador. Aquel describia lo
        // que el agente creyo entender («El usuario solicita crear un ar…») y la
        // lista se llenaba de titulos roboticos entre los que no se reconocia la
        // propia peticion. El entendimiento solo se usa de relleno cuando no hay
        // texto del usuario (ordenes lanzadas sin prompt). Un renombrado
        // explicito (o.title) sigue ganando a todo.
        //
        // P4 (16-oct-2026): si el texto supera 80 caracteres se recorta y se le
        // añade «…» para que el recorte sea visible. La MISMA regla vive en
        // `c_api.getOrderTitle` (sesiones vivas): si una cambia, la otra debe
        // cambiar con ella o la fila cambia de titulo al pasar a la base.
        //
        // `archived_at` se expone para que la cabina pueda ocultar
        // la fila incluso si el motor devolviese ambas (defensa en profundidad),
        // y el funnel `{s}` final aplica el filtro activo/archivado/todas.
        const archived_clause: []const u8 = switch (filter) {
            .active => " AND o.archived_at IS NULL",
            .archived => " AND o.archived_at IS NOT NULL",
            .all => "",
        };
        var sql_buf: [4096]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf,
            \\WITH base AS (SELECT o.id AS id, o.status AS status, o.created_at AS created_at, COALESCE(o.conversation_id,'') AS conv, COALESCE(o.archived_at, 0) AS archived_at, COALESCE(o.title, NULLIF(TRIM(o.user_prompt), ''), (SELECT p.understanding FROM plans p WHERE p.order_id = o.id AND TRIM(COALESCE(p.understanding,'')) <> '' AND p.understanding NOT LIKE 'No pude planificar%' ORDER BY p.id DESC LIMIT 1)) AS raw FROM orders o WHERE substr(o.project_id, 1, 2) <> '{s}'{s}) SELECT id, TRIM(REPLACE(REPLACE(CASE WHEN LENGTH(raw) > 80 THEN SUBSTR(raw, 1, 80) || CHAR(8230) ELSE raw END, CHAR(10), ' '), CHAR(13), ' ')) AS title, status, created_at, conv, archived_at FROM base ORDER BY created_at DESC
        , .{ INTERNAL_PROJECT_PREFIX, archived_clause }) catch return error.ExecFailed;
        const stmt = try self.conn.prepare(sql);
        defer self.conn.finalize(stmt);
        var list = std.ArrayList(SessionInfo).empty;
        errdefer {
            for (list.items) |s| {
                allocator.free(s.title);
                allocator.free(s.status);
                allocator.free(s.conversation_id);
            }
            list.deinit(allocator);
        }
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const id = db.c.sqlite3_column_int64(stmt, 0);
            const title_ptr = db.c.sqlite3_column_text(stmt, 1);
            const title_len = db.c.sqlite3_column_bytes(stmt, 1);
            const status_ptr = db.c.sqlite3_column_text(stmt, 2);
            const status_len = db.c.sqlite3_column_bytes(stmt, 2);
            const created = db.c.sqlite3_column_int64(stmt, 3);
            const title_copy = try allocator.dupe(u8, title_ptr[0..@intCast(title_len)]);
            errdefer allocator.free(title_copy);
            const status_copy = try allocator.dupe(u8, status_ptr[0..@intCast(status_len)]);
            errdefer allocator.free(status_copy);
            const conv_ptr = db.c.sqlite3_column_text(stmt, 4);
            const conv_len = db.c.sqlite3_column_bytes(stmt, 4);
            const conv_copy = if (conv_ptr == null)
                try allocator.dupe(u8, "")
            else
                try allocator.dupe(u8, conv_ptr[0..@intCast(conv_len)]);
            errdefer allocator.free(conv_copy);
            try list.append(allocator, .{
                .id = id,
                .title = title_copy,
                .status = status_copy,
                .created_at = created,
                .conversation_id = conv_copy,
                .archived_at = db.c.sqlite3_column_int64(stmt, 5),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// archiva o desarchiva una sesión. Archivar marca TODAS las
    /// órdenes del hilo (`conversation_id`) para que la fila —que agrupa la
    /// conversación— desaparezca del historial con sus peticiones; una orden sin
    /// hilo se archiva sola. NUNCA borra: desarchivar es volver a NULL.
    ///
    /// Solo se archivan órdenes TERMINALES: una en curso no puede desaparecer
    /// del historial mientras trabaja (mismo criterio que el borrado).
    fn archiveSession(ctx: *anyopaque, order_id: i64, archived: bool) db.DbError!void {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));

        try self.conn.exec("BEGIN IMMEDIATE");
        errdefer self.conn.exec("ROLLBACK") catch {};

        // El destino y el hilo se resuelven en SQL sin truncar conversation_id.
        // Una interna no puede usarse como puerta de entrada a un hilo público.
        const terminal = " AND status IN ('done','failed','rejected','cancelled','audit_unavailable')";
        const sql = if (archived)
            "WITH target AS (SELECT id, conversation_id FROM orders WHERE id = ? AND substr(project_id,1,2) <> '__'" ++ terminal ++ ") " ++
                "UPDATE orders SET archived_at = COALESCE(archived_at, CAST(strftime('%s','now') AS INTEGER)) " ++
                "WHERE substr(project_id,1,2) <> '__' AND (id IN (SELECT id FROM target) OR conversation_id IN (SELECT NULLIF(conversation_id,'') FROM target))" ++ terminal
        else
            "WITH target AS (SELECT id, conversation_id FROM orders WHERE id = ? AND substr(project_id,1,2) <> '__') " ++
                "UPDATE orders SET archived_at = NULL WHERE substr(project_id,1,2) <> '__' " ++
                "AND (id IN (SELECT id FROM target) OR conversation_id IN (SELECT NULLIF(conversation_id,'') FROM target))";
        const stmt = try self.conn.prepare(sql);
        defer self.conn.finalize(stmt);
        try db.bindInt(stmt, 1, order_id);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
        try self.conn.exec("COMMIT");
    }

    // Una sesión es un hilo completo (o una orden legacy sin hilo). El corte se
    // aplica a la más reciente y todas sus órdenes deben ser terminales.
    const archive_candidates =
        "WITH eligible AS (SELECT o.id, CASE WHEN COALESCE(o.conversation_id,'') = '' THEN 'o:' || o.id ELSE 'c:' || o.conversation_id END AS session_key " ++
        "FROM orders o WHERE o.archived_at IS NULL AND o.created_at < ?1 AND substr(o.project_id,1,2) <> '__' " ++
        "AND o.status IN ('done','failed','rejected','cancelled','audit_unavailable') " ++
        "AND NOT EXISTS (SELECT 1 FROM orders sibling WHERE COALESCE(o.conversation_id,'') <> '' " ++
        "AND sibling.conversation_id = o.conversation_id AND substr(sibling.project_id,1,2) <> '__' " ++
        "AND (sibling.created_at >= ?1 OR sibling.status NOT IN ('done','failed','rejected','cancelled','audit_unavailable')))) ";

    fn previewArchiveBefore(ctx: *anyopaque, before_secs: i64) db.DbError!i64 {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        const stmt = try self.conn.prepare(archive_candidates ++ "SELECT COUNT(DISTINCT session_key) FROM eligible");
        defer self.conn.finalize(stmt);
        try db.bindInt(stmt, 1, before_secs);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.StepFailed;
        return db.c.sqlite3_column_int64(stmt, 0);
    }

    /// El recuento y la escritura usan exactamente los mismos candidatos y una
    /// transacción. Si cambiaron desde la confirmación, se pide confirmar otra vez.
    fn archiveBefore(ctx: *anyopaque, before_secs: i64, expected_count: ?i64) db.DbError!i64 {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        try self.conn.exec("BEGIN IMMEDIATE");
        errdefer self.conn.exec("ROLLBACK") catch {};
        const count = try previewArchiveBefore(ctx, before_secs);
        if (expected_count) |expected| {
            if (count != expected) return error.ArchiveChanged;
        }
        const stmt = try self.conn.prepare(archive_candidates ++
            "UPDATE orders SET archived_at = CAST(strftime('%s','now') AS INTEGER) WHERE id IN (SELECT id FROM eligible)");
        defer self.conn.finalize(stmt);
        try db.bindInt(stmt, 1, before_secs);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
        try self.conn.exec("COMMIT");
        return count;
    }

    fn renameSession(ctx: *anyopaque, order_id: i64, title: []const u8) db.DbError!void {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        const stmt = try self.conn.prepare("UPDATE orders SET title = ? WHERE id = ?");
        defer self.conn.finalize(stmt);
        try db.bindText(stmt, 1, title);
        try db.bindInt(stmt, 2, order_id);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    /// S8: borra la orden y TODO lo que cuelga de ella.
    ///
    /// Borrar solo la fila de `orders` dejaria mensajes y eventos huerfanos que
    /// nadie volveria a mirar y que siguen ocupando la base: `events` es de
    /// lejos la tabla que mas crece (219 `content_delta` en UNA orden). Las
    /// tablas van de la mas dependiente a la menos, y todo dentro de una
    /// transaccion: media sesion borrada seria peor que no borrarla.
    ///
    /// `plans`/`tasks`/`contracts` se cuelgan de la orden por `plan_id`, asi
    /// que se resuelven con subconsultas antes de que el plan desaparezca.
    fn deleteSession(ctx: *anyopaque, order_id: i64) db.DbError!void {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));

        try self.conn.exec("BEGIN IMMEDIATE");
        errdefer self.conn.exec("ROLLBACK") catch {};

        // The write transaction also protects this status check against another
        // connection changing an already-active order during deletion.
        const active = try self.conn.prepare("SELECT 1 FROM orders WHERE id = ? AND status IN ('pending','approved','running','awaiting_approval')");
        defer self.conn.finalize(active);
        try db.bindInt(active, 1, order_id);
        const active_step = db.c.sqlite3_step(active);
        if (active_step == db.c.SQLITE_ROW) return error.SessionActive;
        if (active_step != db.c.SQLITE_DONE) return error.StepFailed;

        const steps = [_][]const u8{
            "DELETE FROM contracts WHERE plan_id IN (SELECT id FROM plans WHERE order_id = ?)",
            "DELETE FROM tasks WHERE plan_id IN (SELECT id FROM plans WHERE order_id = ?)",
            "DELETE FROM plans WHERE order_id = ?",
            "DELETE FROM events WHERE order_id = ?",
            "DELETE FROM messages WHERE order_id = ?",
            "DELETE FROM usage_records WHERE order_id = ?",
            "DELETE FROM orders WHERE id = ?",
        };
        for (steps) |sql| {
            // A migrated runtime has every table. Any error must roll back the
            // complete session, including earlier successful DELETE statements.
            const stmt = try self.conn.prepare(sql);
            defer self.conn.finalize(stmt);
            try db.bindInt(stmt, 1, order_id);
            if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
        }
        try self.conn.exec("COMMIT");
    }

    /// FASE-AGENTIC-1: mensajes de TODAS las órdenes de una conversación, en
    /// orden cronológico — el hilo completo, no solo una orden.
    fn loadConversationMessages(ctx: *anyopaque, allocator: std.mem.Allocator, conversation_id: []const u8) db.DbError![]Message {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        const stmt = try self.conn.prepare(
            \\SELECT m.id, m.order_id, m.role, m.content, m.created_at
            \\FROM messages m JOIN orders o ON m.order_id = o.id
            \\WHERE o.conversation_id = ?
            \\ORDER BY m.created_at ASC, m.id ASC
        );
        defer self.conn.finalize(stmt);
        try db.bindText(stmt, 1, conversation_id);
        var list = std.ArrayList(Message).empty;
        errdefer {
            for (list.items) |m| {
                allocator.free(m.role);
                allocator.free(m.content);
            }
            list.deinit(allocator);
        }
        while (true) {
            const step = db.c.sqlite3_step(stmt);
            if (step == db.c.SQLITE_DONE) break;
            if (step != db.c.SQLITE_ROW) return error.ExecFailed;
            const id = db.c.sqlite3_column_int64(stmt, 0);
            const oid = db.c.sqlite3_column_int64(stmt, 1);
            const role_ptr = db.c.sqlite3_column_text(stmt, 2);
            const role_len = db.c.sqlite3_column_bytes(stmt, 2);
            const content_ptr = db.c.sqlite3_column_text(stmt, 3);
            const content_len = db.c.sqlite3_column_bytes(stmt, 3);
            const created = db.c.sqlite3_column_int64(stmt, 4);
            const role_copy = try allocator.dupe(u8, role_ptr[0..@intCast(role_len)]);
            errdefer allocator.free(role_copy);
            const content_copy = try allocator.dupe(u8, content_ptr[0..@intCast(content_len)]);
            try list.append(allocator, .{
                .id = id,
                .order_id = oid,
                .role = role_copy,
                .content = content_copy,
                .created_at = created,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// FASE-AGENTIC-1: vincula una orden a un hilo de conversación.
    fn setConversationId(ctx: *anyopaque, order_id: i64, conversation_id: []const u8) db.DbError!void {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        const stmt = try self.conn.prepare("UPDATE orders SET conversation_id = ? WHERE id = ?");
        defer self.conn.finalize(stmt);
        try db.bindText(stmt, 1, conversation_id);
        try db.bindInt(stmt, 2, order_id);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    fn deinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *SqliteBackend = @ptrCast(@alignCast(ctx));
        allocator.destroy(self);
    }
};

/// Crea un SessionStore con backend SQLite sobre `conn`.
/// `allocator` se usa solo para la estructura del backend.
pub fn createSqliteStore(allocator: std.mem.Allocator, conn: db.Connection) db.DbError!SessionStore {
    const backend = try allocator.create(SqliteBackend);
    backend.* = .{ .conn = conn };
    return .{
        .saveMessage = SqliteBackend.saveMessage,
        .loadMessages = SqliteBackend.loadMessages,
        .listSessions = SqliteBackend.listSessions,
        .listSessionsFiltered = SqliteBackend.listSessionsFiltered,
        .archiveSession = SqliteBackend.archiveSession,
        .archiveBefore = SqliteBackend.archiveBefore,
        .previewArchiveBefore = SqliteBackend.previewArchiveBefore,
        .renameSession = SqliteBackend.renameSession,
        .deleteSession = SqliteBackend.deleteSession,
        .loadConversationMessages = SqliteBackend.loadConversationMessages,
        .setConversationId = SqliteBackend.setConversationId,
        .deinit = SqliteBackend.deinit,
        .ctx = backend,
    };
}

fn noopDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    _ = ctx;
    _ = allocator;
}

/// MULTISESSION-P0 (2026-07-12): vista TEMPORAL de SessionStore ligada a `conn`,
/// sin poseer/cerrar la conexión — análoga a MemoryBundle.backendForConn.
/// `scratch` es memoria del LLAMADOR (p. ej. una var local en el scope de
/// dispatchApprovedOrder); su lifetime debe cubrir toda la vida útil del
/// SessionStore devuelto, y no debe escapar ese scope.
///
/// A diferencia de createSqliteStore, `.deinit` aquí es un no-op deliberado:
/// SqliteBackend.deinit normal hace `allocator.destroy(self)`, lo cual sería
/// UB si `scratch` no fue obtenido con `allocator.create` (aquí nunca lo es).
/// Esto hace la "no-posesión" estructuralmente imposible de violar por accidente
/// — no depende de que el llamador recuerde no llamar deinitFn().
pub fn sessionStoreForConn(conn: db.Connection, scratch: *SqliteBackend) SessionStore {
    scratch.* = .{ .conn = conn };
    return .{
        .saveMessage = SqliteBackend.saveMessage,
        .loadMessages = SqliteBackend.loadMessages,
        .listSessions = SqliteBackend.listSessions,
        .listSessionsFiltered = SqliteBackend.listSessionsFiltered,
        .archiveSession = SqliteBackend.archiveSession,
        .archiveBefore = SqliteBackend.archiveBefore,
        .previewArchiveBefore = SqliteBackend.previewArchiveBefore,
        .renameSession = SqliteBackend.renameSession,
        .deleteSession = SqliteBackend.deleteSession,
        .loadConversationMessages = SqliteBackend.loadConversationMessages,
        .setConversationId = SqliteBackend.setConversationId,
        .deinit = noopDeinit,
        .ctx = scratch,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "sqlite store roundtrip" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    // Seed una orden para que FK no falle
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hello world', 'pending', 42)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);

    try store.saveMessageFn(1, "user", "hola", 100);
    try store.saveMessageFn(1, "agent", "adios", 200);

    const msgs = try store.loadMessagesFn(allocator, 1);
    defer {
        for (msgs) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqualStrings("user", msgs[0].role);
    try std.testing.expectEqualStrings("hola", msgs[0].content);
    try std.testing.expectEqualStrings("agent", msgs[1].role);
    try std.testing.expectEqualStrings("adios", msgs[1].content);
}

test "sqlite store listSessions" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, title) VALUES (1, 'p', 'a', 'pending', 10, 'Alpha')");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (2, 'p', 'b', 'planned', 20)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);

    const sessions = try store.listSessionsFn(allocator);
    defer {
        for (sessions) |s| {
            allocator.free(s.title);
            allocator.free(s.status);
        }
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    // Orden DESC por created_at
    try std.testing.expectEqual(@as(i64, 2), sessions[0].id);
    try std.testing.expectEqualStrings("b", sessions[0].title); // fallback a user_prompt
    try std.testing.expectEqualStrings("planned", sessions[0].status);
    try std.testing.expectEqual(@as(i64, 1), sessions[1].id);
    try std.testing.expectEqualStrings("Alpha", sessions[1].title);
}

test "sqlite store loadConversationMessages: cruza varias ordenes del mismo hilo, ignora otras conversaciones" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    // orden 1 y 2 pertenecen a "conv-A"; orden 3 a "conv-B" (no debe aparecer).
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (1, 'p', 'recuerda 42', 'done', 10, 'conv-A')");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (2, 'p', 'que numero dije', 'done', 20, 'conv-A')");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (3, 'p', 'otro tema', 'done', 30, 'conv-B')");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);

    try store.saveMessageFn(1, "user", "recuerda 42", 100);
    try store.saveMessageFn(1, "agent", "listo, 42", 101);
    try store.saveMessageFn(2, "user", "que numero dije", 200);
    try store.saveMessageFn(2, "agent", "42", 201);
    try store.saveMessageFn(3, "user", "otro tema", 300);
    try store.saveMessageFn(3, "agent", "ok", 301);

    const msgs = try store.loadConversationMessagesFn(allocator, "conv-A");
    defer {
        for (msgs) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqualStrings("recuerda 42", msgs[0].content);
    try std.testing.expectEqualStrings("listo, 42", msgs[1].content);
    try std.testing.expectEqualStrings("que numero dije", msgs[2].content);
    try std.testing.expectEqualStrings("42", msgs[3].content);
}

test "sqlite store setConversationId" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'x', 'pending', 1)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);

    try store.setConversationIdFn(1, "conv-xyz");
    try store.saveMessageFn(1, "user", "hola", 10);

    const msgs = try store.loadConversationMessagesFn(allocator, "conv-xyz");
    defer {
        for (msgs) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("hola", msgs[0].content);
}

test "sqlite store renameSession" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'x', 'pending', 1)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);

    try store.renameSessionFn(1, "Nuevo Título");

    const sessions = try store.listSessionsFn(allocator);
    defer {
        for (sessions) |s| {
            allocator.free(s.title);
            allocator.free(s.status);
        }
        allocator.free(sessions);
    }
    try std.testing.expectEqualStrings("Nuevo Título", sessions[0].title);
}

// ── MULTISESSION-P0 (2026-07-12) — sessionStoreForConn ─────────────────

const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
}.GetTempPathA else @import("platform.zig").tempPath;

fn multisessionTestPath(tmp: *const std.testing.TmpDir, filename: []const u8) ![:0]u8 {
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

test "MULTISESSION-P0 SESSIONS-A: sessionStoreForConn's temporary view writes via the given conn" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_thread = try multisessionTestPath(&tmp, "sessions-a.db");
    defer allocator.free(path_thread);
    var conn_thread = try db.Connection.open(allocator, path_thread);
    defer conn_thread.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn_thread, &db.runtime_schema);
    try conn_thread.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hello', 'running', 1)");

    var scratch: SqliteBackend = undefined;
    const view = sessionStoreForConn(conn_thread, &scratch);
    try view.saveMessageFn(1, "agent", "via thread conn", 100);

    const stmt = try conn_thread.prepare("SELECT COUNT(*) FROM messages WHERE content = ?");
    defer conn_thread.finalize(stmt);
    try db.bindText(stmt, 1, "via thread conn");
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(stmt, 0));
}

test "MULTISESSION-P0 SESSIONS-B: sessionStoreForConn never touches a different connection" {
    const allocator = std.testing.allocator;
    var conn_main = try db.Connection.open(allocator, ":memory:");
    defer conn_main.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn_main, &db.runtime_schema);
    try conn_main.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hello', 'running', 1)");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_thread = try multisessionTestPath(&tmp, "sessions-b.db");
    defer allocator.free(path_thread);
    var conn_thread = try db.Connection.open(allocator, path_thread);
    defer conn_thread.close();
    try migrator.migrate(conn_thread, &db.runtime_schema);
    try conn_thread.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hello', 'running', 1)");

    var scratch: SqliteBackend = undefined;
    const view = sessionStoreForConn(conn_thread, &scratch);
    try view.saveMessageFn(1, "agent", "only in thread conn", 100);

    // conn_main (== st.db_conn del hilo principal) debe seguir en CERO.
    const stmt = try conn_main.prepare("SELECT COUNT(*) FROM messages");
    defer conn_main.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt, 0));
}

test "MULTISESSION-P0 SESSIONS-C: a message saved via the per-thread view is visible to the main reader (same file)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try multisessionTestPath(&tmp, "sessions-c.db");
    defer allocator.free(path);

    var conn_main = try db.Connection.open(allocator, path);
    defer conn_main.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn_main, &db.runtime_schema);
    try conn_main.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hello', 'running', 1)");

    const main_store = try createSqliteStore(allocator, conn_main);
    defer main_store.deinitFn(allocator);

    // El "hilo de dispatch" abre su PROPIA conexión al MISMO archivo.
    var conn_thread = try db.Connection.open(allocator, path);
    defer conn_thread.close();

    var scratch: SqliteBackend = undefined;
    const view = sessionStoreForConn(conn_thread, &scratch);
    try view.saveMessageFn(1, "agent", "escrito desde el hilo", 100);

    // El lector principal (st.sessions, atado a conn_main) debe verlo.
    const msgs = try main_store.loadMessagesFn(allocator, 1);
    defer {
        for (msgs) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("escrito desde el hilo", msgs[0].content);
}

test "MULTISESSION-P0 SESSIONS-D: st.sessions stays usable after the per-thread conn closes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try multisessionTestPath(&tmp, "sessions-d.db");
    defer allocator.free(path);

    var conn_main = try db.Connection.open(allocator, path);
    defer conn_main.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn_main, &db.runtime_schema);
    try conn_main.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'hello', 'running', 1)");

    const main_store = try createSqliteStore(allocator, conn_main);
    defer main_store.deinitFn(allocator);

    {
        var conn_thread = try db.Connection.open(allocator, path);
        var scratch: SqliteBackend = undefined;
        const view = sessionStoreForConn(conn_thread, &scratch);
        try view.saveMessageFn(1, "agent", "via thread, soon closed", 100);
        conn_thread.close(); // el "hilo" termina y cierra SU conexión.
    }

    // st.sessions (main_store) sigue perfectamente funcional tras cerrar el hilo.
    try main_store.saveMessageFn(1, "user", "via main after thread closed", 200);
    const msgs = try main_store.loadMessagesFn(allocator, 1);
    defer {
        for (msgs) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
}

test "MULTISESSION-P0 SESSIONS-F: two orders through the same per-thread view never mix conversation_id/order_id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try multisessionTestPath(&tmp, "sessions-f.db");
    defer allocator.free(path);

    var conn_thread = try db.Connection.open(allocator, path);
    defer conn_thread.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn_thread, &db.runtime_schema);
    try conn_thread.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (1, 'p', 'a', 'running', 1, 'conv-A')");
    try conn_thread.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (2, 'p', 'b', 'running', 2, 'conv-B')");

    var scratch: SqliteBackend = undefined;
    const view = sessionStoreForConn(conn_thread, &scratch);
    try view.saveMessageFn(1, "agent", "orden 1", 100);
    try view.saveMessageFn(2, "agent", "orden 2", 200);

    const msgs1 = try view.loadConversationMessagesFn(allocator, "conv-A");
    defer {
        for (msgs1) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(msgs1);
    }
    const msgs2 = try view.loadConversationMessagesFn(allocator, "conv-B");
    defer {
        for (msgs2) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(msgs2);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs1.len);
    try std.testing.expectEqualStrings("orden 1", msgs1[0].content);
    try std.testing.expectEqual(@as(usize, 1), msgs2.len);
    try std.testing.expectEqualStrings("orden 2", msgs2[0].content);
}

test "S8: borrar una sesion se lleva sus mensajes y eventos, y no toca las demas" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'la que se borra', 'done', 10)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (2, 'p', 'la que se queda', 'done', 20)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (1, 'x', 'content_delta', '{}', 1)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (2, 'x', 'content_delta', '{}', 1)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (3, 'x', 'order_done', '{}', 2)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);
    try store.saveMessageFn(1, "user", "hola", 100);
    try store.saveMessageFn(2, "user", "adios", 200);

    try store.deleteSessionFn(1);

    // La orden se fue, y con ella sus mensajes y sus eventos: borrar solo la
    // fila de `orders` dejaria huerfanos que nadie volveria a mirar y que
    // siguen ocupando la base — `events` es la tabla que mas crece.
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE id = 1"));
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM events WHERE order_id = 1"));
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM messages WHERE order_id = 1"));

    // Y la vecina sigue intacta, con lo suyo.
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE id = 2"));
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM events WHERE order_id = 2"));
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM messages WHERE order_id = 2"));
}

test "S8: borrar una sesion que no existe no es un error ni toca nada" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'unica', 'done', 10)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);
    try store.deleteSessionFn(99999);
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders"));
}

fn countRowsForTest(conn: db.Connection, sql: []const u8) !i64 {
    const stmt = try conn.prepare(sql);
    defer conn.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.NoRow;
    return db.c.sqlite3_column_int64(stmt, 0);
}

test "M8: las ordenes internas no aparecen en el historial del usuario" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    // Dos del usuario y dos que lanza la maquinaria. El gate de aceptacion
    // mete CUATRO por pasada; sin este filtro, el historial se llena de
    // ordenes que el usuario no reconoce ni pidio.
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'cli', 'mia 1', 'done', 10)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (2, '__selftest', 'gate 1', 'done', 20)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (3, 'default', 'mia 2', 'done', 30)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (4, '__probe', 'sonda', 'done', 40)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);
    const sessions = try store.listSessionsFn(allocator);
    defer {
        for (sessions) |s| {
            allocator.free(s.title);
            allocator.free(s.status);
        }
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    for (sessions) |s| {
        try std.testing.expect(std.mem.indexOf(u8, s.title, "gate") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.title, "sonda") == null);
    }
}

test "M8: ocultarlas del historial NO las borra ni las esconde de la traza" {
    // Siguen siendo ordenes de pleno derecho: `devagents debug` tiene que
    // poder abrirlas, y sus archivos siguen en disco. Lo unico que cambia es
    // que no salen en la lista de sesiones.
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (7, '__selftest', 'gate', 'done', 10)");

    const stmt = try conn.prepare("SELECT COUNT(*) FROM orders WHERE id = 7");
    defer conn.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(stmt, 0));
}

test "SESSION P2-TITULO: el titulo sale del texto del usuario; el entendimiento solo de relleno" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    // El usuario tecleo «Hola» y el planificador entendio otra cosa. La barra
    // lateral debe enseñar lo que el usuario pidio, no la paráfrasis del plan.
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'cli', 'Hola', 'done', 10)");
    try conn.exec("INSERT INTO plans (id, order_id, understanding, created_at) VALUES (1, 1, 'Crear un contador web con dos botones', 1)");

    // Un renombrado explicito del usuario gana SIEMPRE.
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (2, 'cli', 'Hola', 'done', 20)");
    try conn.exec("INSERT INTO plans (id, order_id, understanding, created_at) VALUES (2, 2, 'Otra cosa', 1)");
    try conn.exec("UPDATE orders SET title = 'Mi nombre a mano' WHERE id = 2");

    // Un plan que FALLO tiene por entendimiento un aviso de error nuestro: el
    // prompt sigue siendo mejor titulo (y ademas ya no se usa el error).
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (3, 'cli', 'Crea un reloj', 'failed', 30)");
    try conn.exec("INSERT INTO plans (id, order_id, understanding, created_at) VALUES (3, 3, 'No pude planificar: el proveedor LLM fallo', 1)");

    // Sin plan, el prompt es lo unico que hay.
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (4, 'cli', 'Sin plan', 'planned', 40)");

    // Sin texto del usuario (orden interna sin prompt), el entendimiento es el
    // unico relleno disponible.
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (5, 'cli', '', 'done', 50)");
    try conn.exec("INSERT INTO plans (id, order_id, understanding, created_at) VALUES (5, 5, 'Resumen sin prompt', 1)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);
    const sessions = try store.listSessionsFn(allocator);
    defer {
        for (sessions) |s| {
            allocator.free(s.title);
            allocator.free(s.status);
        }
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 5), sessions.len);
    // Vienen por created_at DESC: 5, 4, 3, 2, 1.
    try std.testing.expectEqualStrings("Resumen sin prompt", sessions[0].title);
    try std.testing.expectEqualStrings("Sin plan", sessions[1].title);
    try std.testing.expectEqualStrings("Crea un reloj", sessions[2].title);
    try std.testing.expectEqualStrings("Mi nombre a mano", sessions[3].title);
    try std.testing.expectEqualStrings("Hola", sessions[4].title);
}

test "session titulo largo: recorta a 80 y añade puntos suspensivos (P4)" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    // Prompt multilinea cuyo PRIMER renglon ya pasa de 80 caracteres: el
    // recorte debe caer dentro de la primera linea y cerrarse con «…». La
    // segunda linea no debe asomar (se recorta antes de aplanar el salto).
    const largo = "crea una aplicacion web con un contador que suba y baje con dos botones grandes ahora\nsegunda linea que no debe aparecer en el titulo";
    const ins = try conn.prepare("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'cli', ?, 'done', 10)");
    defer conn.finalize(ins);
    try db.bindText(ins, 1, largo);
    try std.testing.expect(db.c.sqlite3_step(ins) == db.c.SQLITE_DONE);

    // Un titulo corto no se toca ni lleva «…».
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (2, 'cli', 'Corto', 'done', 20)");

    const store = try createSqliteStore(allocator, conn);
    defer store.deinitFn(allocator);
    const sessions = try store.listSessionsFn(allocator);
    defer {
        for (sessions) |s| {
            allocator.free(s.title);
            allocator.free(s.status);
        }
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    // created_at DESC: id 2 (Corto) y luego id 1 (largo).
    try std.testing.expectEqualStrings("Corto", sessions[0].title);
    const t = sessions[1].title;
    // 80 caracteres de texto + el caracter «…» (U+2026, 3 bytes UTF-8) = 83.
    try std.testing.expectEqual(@as(usize, 83), t.len);
    try std.testing.expect(std.mem.endsWith(u8, t, "\u{2026}"));
    try std.testing.expect(std.mem.indexOf(u8, t, "segunda linea") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, t, '\n') == null);
    try std.testing.expect(std.mem.startsWith(u8, t, "crea una aplicacion web con un contador"));
}

test "SESSION-DELETE: active order is preserved" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','active','running',1)");
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);
    try store.saveMessageFn(1, "user", "preserve", 1);
    // Error family is checked by the C API; storage must reject before any delete.
    if (store.deleteSessionFn(1)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders"));
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM messages"));
}

test "SESSION-DELETE: prepare failure rolls back earlier deletes" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','done','done',1)");
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);
    try store.saveMessageFn(1, "user", "preserve", 1);
    // Simulate an invalid schema late in the transaction, after message deletion.
    try conn.exec("DROP TABLE usage_records");
    try std.testing.expectError(error.PrepareFailed, store.deleteSessionFn(1));
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders"));
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM messages"));
}

test "SESSION-DELETE: step failure rolls back earlier deletes" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1,'p','done','done',1)");
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);
    try store.saveMessageFn(1, "user", "preserve", 1);
    try conn.exec("CREATE TRIGGER deny_order_delete BEFORE DELETE ON orders BEGIN SELECT RAISE(ABORT, 'fixture'); END");
    try std.testing.expectError(error.ExecFailed, store.deleteSessionFn(1));
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders"));
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM messages"));
}

// ── (2026-10-16): archivo de sesiones ───────────────────────

fn freeSessionsForTest(allocator: std.mem.Allocator, sessions: []SessionInfo) void {
    for (sessions) |s| {
        allocator.free(s.title);
        allocator.free(s.status);
        allocator.free(s.conversation_id);
    }
    allocator.free(sessions);
}

fn cab003OpenStore(allocator: std.mem.Allocator) !db.Connection {
    const conn = try db.Connection.open(allocator, ":memory:");
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    return conn;
}

test "CK-CAB-003 archivo: el historial oculta las archivadas y las muestra con el filtro" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'cli', 'vieja', 'done', 10)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (2, 'cli', 'nueva', 'done', 20)");

    try store.archiveSessionFn(1, true);

    const activas = try store.listSessionsFn(a);
    defer freeSessionsForTest(a, activas);
    try std.testing.expectEqual(@as(usize, 1), activas.len);
    try std.testing.expectEqual(@as(i64, 2), activas[0].id);
    try std.testing.expectEqual(@as(i64, 0), activas[0].archived_at);

    const archivadas = try store.listSessionsFilteredFn(a, .archived);
    defer freeSessionsForTest(a, archivadas);
    try std.testing.expectEqual(@as(usize, 1), archivadas.len);
    try std.testing.expectEqual(@as(i64, 1), archivadas[0].id);
    try std.testing.expect(archivadas[0].archived_at > 0);

    const todas = try store.listSessionsFilteredFn(a, .all);
    defer freeSessionsForTest(a, todas);
    try std.testing.expectEqual(@as(usize, 2), todas.len);
}

test "CK-CAB-003 archivo: desarchivar devuelve la sesion al historial" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'cli', 'vuelve', 'done', 10)");
    try store.archiveSessionFn(1, true);
    {
        const archivadas = try store.listSessionsFilteredFn(a, .archived);
        defer freeSessionsForTest(a, archivadas);
        try std.testing.expectEqual(@as(usize, 1), archivadas.len);
    }

    try store.archiveSessionFn(1, false);

    const activas = try store.listSessionsFn(a);
    defer freeSessionsForTest(a, activas);
    try std.testing.expectEqual(@as(usize, 1), activas.len);
    try std.testing.expectEqual(@as(i64, 1), activas[0].id);
    try std.testing.expectEqual(@as(i64, 0), activas[0].archived_at);
}

test "CK-CAB-003 archivo: una orden en curso no se archiva" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'cli', 'trabajando', 'running', 10)");
    try store.archiveSessionFn(1, true);

    const activas = try store.listSessionsFn(a);
    defer freeSessionsForTest(a, activas);
    try std.testing.expectEqual(@as(usize, 1), activas.len);
    try std.testing.expectEqualStrings("running", activas[0].status);

    const archivadas = try store.listSessionsFilteredFn(a, .archived);
    defer freeSessionsForTest(a, archivadas);
    try std.testing.expectEqual(@as(usize, 0), archivadas.len);
}

test "CK-CAB-003 archivo: archivar una sesion arrastra toda su conversacion" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);

    // conv-A tiene dos órdenes cerradas y una en curso; conv-B es otra sesión.
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (1, 'cli', 'a1', 'done', 10, 'conv-A')");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (2, 'cli', 'a2', 'done', 20, 'conv-A')");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (3, 'cli', 'a3', 'running', 30, 'conv-A')");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at, conversation_id) VALUES (4, 'cli', 'b1', 'done', 40, 'conv-B')");

    try store.archiveSessionFn(1, true);

    // De conv-A quedan fuera las dos cerradas, pero la que trabaja sigue viva.
    // conv-B no se toca.
    const activas = try store.listSessionsFn(a);
    defer freeSessionsForTest(a, activas);
    try std.testing.expectEqual(@as(usize, 2), activas.len);
    try std.testing.expectEqual(@as(i64, 4), activas[0].id);
    try std.testing.expectEqual(@as(i64, 3), activas[1].id);

    const archivadas = try store.listSessionsFilteredFn(a, .archived);
    defer freeSessionsForTest(a, archivadas);
    try std.testing.expectEqual(@as(usize, 2), archivadas.len);

    // Desarchivar por CUALQUIER orden del hilo restaura la conversación entera.
    try store.archiveSessionFn(2, false);
    const tras = try store.listSessionsFn(a);
    defer freeSessionsForTest(a, tras);
    try std.testing.expectEqual(@as(usize, 4), tras.len);
}

test "CK-CAB-003 archivo: archivar anteriores a una fecha cuenta solo las terminales propias" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);

    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'cli', 'vieja', 'done', 10)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (2, 'cli', 'reciente', 'done', 100)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (3, '__selftest', 'gate', 'done', 10)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (4, 'cli', 'en curso', 'running', 10)");

    // Corte en 50: solo la orden 1 (terminal, propia, anterior) se archiva.
    const movidas = try store.archiveBeforeFn(50);
    try std.testing.expectEqual(@as(i64, 1), movidas);

    const activas = try store.listSessionsFn(a);
    defer freeSessionsForTest(a, activas);
    // Quedan visibles: 4 (running), 2 (reciente) y 3 (el gate interno NO se
    // archiva, pero tampoco aparece porque el historial lo oculta aparte).
    try std.testing.expectEqual(@as(usize, 2), activas.len);
    try std.testing.expectEqual(@as(i64, 2), activas[0].id);
    try std.testing.expectEqual(@as(i64, 4), activas[1].id);

    // El gate interno sigue SIN archivar (archiveBefore lo ignora).
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE id = 3 AND archived_at IS NOT NULL"));

    // Segunda pasada: idempotente, ya no hay nada anterior que archivar.
    try std.testing.expectEqual(@as(i64, 0), try store.archiveBeforeFn(50));
}

test "CK-CAB-003 archivo: individual excluye internas incluso dentro del hilo" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);
    try conn.exec("INSERT INTO orders(id,user_prompt,project_id,status,created_at,conversation_id) VALUES (1,'prueba','__probe','done',1,'compartido'),(2,'prueba','cli','done',2,'compartido'),(3,'prueba','__selftest','done',3,NULL)");
    try store.archiveSessionFn(1, true);
    try store.archiveSessionFn(3, true);
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE archived_at IS NOT NULL"));
    try store.archiveSessionFn(2, true);
    try std.testing.expectEqual(@as(i64, 1), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE archived_at IS NOT NULL"));
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE substr(project_id,1,2)='__' AND archived_at IS NOT NULL"));
}

test "CK-CAB-003 archivo: todos los estados vivos permanecen visibles" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);
    const estados = [_][]const u8{ "pending", "planning", "planned", "clarifying", "approved", "running", "awaiting_approval", "awaiting_best_of_n" };
    for (estados, 1..) |estado, id| {
        const stmt = try conn.prepare("INSERT INTO orders(id,user_prompt,project_id,status,created_at) VALUES (?,'prueba','cli',?,1)");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, @intCast(id));
        try db.bindText(stmt, 2, estado);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
        try store.archiveSessionFn(@intCast(id), true);
    }
    try std.testing.expectEqual(@as(i64, 0), try store.archiveBeforeFn(100));
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE archived_at IS NOT NULL"));
}

test "CK-CAB-003 archivo: masivo no parte hilos recientes ni vivos y cuenta sesiones" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);
    try conn.exec("INSERT INTO orders(id,user_prompt,project_id,status,created_at,conversation_id) VALUES (1,'prueba','cli','done',1,'viejo'),(2,'prueba','cli','failed',2,'viejo'),(3,'prueba','cli','done',1,'reciente'),(4,'prueba','cli','done',100,'reciente'),(5,'prueba','cli','done',1,'vivo'),(6,'prueba','cli','running',2,'vivo'),(7,'prueba','cli','cancelled',3,NULL)");
    try std.testing.expectEqual(@as(i64, 2), try store.archiveBeforeFn(50));
    try std.testing.expectEqual(@as(i64, 3), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE archived_at IS NOT NULL"));
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE id IN (3,4,5,6) AND archived_at IS NOT NULL"));
}

test "CK-CAB-003 archivo: fallo de escritura revierte todo el hilo" {
    const a = std.testing.allocator;
    var conn = try cab003OpenStore(a);
    defer conn.close();
    const store = try createSqliteStore(a, conn);
    defer store.deinitFn(a);
    try conn.exec("INSERT INTO orders(id,user_prompt,project_id,status,created_at,conversation_id) VALUES (1,'prueba','cli','done',1,'hilo'),(2,'prueba','cli','done',2,'hilo')");
    try conn.exec("CREATE TRIGGER archivo_falla BEFORE UPDATE OF archived_at ON orders WHEN NEW.id=2 BEGIN SELECT RAISE(ABORT,'fallo simulado'); END");
    try std.testing.expectError(error.ExecFailed, store.archiveSessionFn(1, true));
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE archived_at IS NOT NULL"));
    try std.testing.expectError(error.ExecFailed, store.archiveBeforeFn(50));
    try std.testing.expectEqual(@as(i64, 0), try countRowsForTest(conn, "SELECT COUNT(*) FROM orders WHERE archived_at IS NOT NULL"));
}
