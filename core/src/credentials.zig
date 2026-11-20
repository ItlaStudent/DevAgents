const std = @import("std");
const db = @import("db.zig");
const dpapi = @import("dpapi.zig");
const http_client = @import("providers").http_client;

/// Errores del gestor de credenciales.
pub const CredentialError = error{
    DbError,
    EncryptFailed,
    DecryptFailed,
    KeyNotFound,
    ProviderNotFound,
    /// Se agotaron todas las claves activas del proveedor (todas rate-limited/rotadas).
    AllKeysExhausted,
    /// El envío falló por auth (401/403): clave sin derecho al modelo.
    AuthFailed,
    /// El envío falló por una causa no recuperable (no es rate-limit).
    SendFailed,
};

/// Resultado de un intento de envío, usado por el driver de rotación.
pub const AttemptOutcome = enum {
    /// Éxito: se registra el uso de la clave y se termina.
    ok,
    /// Rate-limited (HTTP 429): rota la clave y reintenta con la siguiente.
    rate_limited,
    /// Auth-failed (HTTP 401/403): clave sin derecho. Propaga sin reintentar.
    auth_failed,
    /// Error no recuperable: se propaga sin reintentar.
    fatal,
};

/// Gestor de credenciales: N claves por proveedor, cifrado DPAPI, rotación.
pub const CredentialManager = struct {
    allocator: std.mem.Allocator,
    db: db.Connection,
    /// E1.14: segundos que una clave marcada `rotated` (429/quota) permanece
    /// fuera del pool antes de volver a ser candidata. Es el backoff: la clave
    /// no muere para siempre, se enfría y se reincorpora sola.
    rotation_cooldown_s: i64 = 60,
    // Numeric diagnostics only: sqlite3_errmsg can contain caller-controlled secrets.
    key_error: struct {
        stage: enum { validate, encrypt, prepare, bind, insert } = .validate,
        sqlite_code: c_int = 0,
        sqlite_extended: c_int = 0,
        win32: u32 = 0,
    } = .{},

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !CredentialManager {
        const conn = try db.Connection.open(allocator, db_path);
        var migrator = db.Migrator.init(allocator);
        try migrator.migrate(conn, &db.catalog_schema);
        return .{
            .allocator = allocator,
            .db = conn,
        };
    }

    pub fn deinit(self: *CredentialManager) void {
        self.db.close();
    }

    /// Añade un proveedor al catálogo (parámetros enlazados — sin inyección SQL).
    pub fn addProvider(self: *CredentialManager, name: []const u8, base_url: []const u8, api_style: []const u8, is_free: bool) !void {
        try http_client.validateCredentialUrl(base_url);
        const sql =
            \\INSERT INTO providers (name, base_url, api_style, is_free_tier, enabled)
            \\VALUES (?, ?, ?, ?, 1)
            \\ON CONFLICT(name) DO UPDATE SET
            \\  base_url = excluded.base_url,
            \\  api_style = excluded.api_style,
            \\  is_free_tier = excluded.is_free_tier,
            \\  enabled = 1
        ;
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        try db.bindText(stmt, 1, name);
        try db.bindText(stmt, 2, base_url);
        try db.bindText(stmt, 3, api_style);
        try db.bindInt(stmt, 4, if (is_free) 1 else 0);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.DbError;
    }

    /// Añade una clave API para un proveedor (clave cifrada DPAPI; parámetros enlazados).
    pub fn addKey(self: *CredentialManager, provider_name: []const u8, label: []const u8, key: []const u8) !void {
        self.key_error = .{};
        errdefer {
            self.key_error.sqlite_code = db.c.sqlite3_errcode(self.db.db);
            self.key_error.sqlite_extended = db.c.sqlite3_extended_errcode(self.db.db);
        }
        // E3.39-D: una clave vacía quedaba almacenada como fila 'active' —
        // el proveedor aparecía usable (rankCandidates filtra por EXISTENCIA
        // de clave activa) pero la llamada salía sin Authorization y moría
        // aguas abajo. Los proveedores locales no pasan por aquí: funcionan
        // sin clave por diseño (is_local=1).
        if (key.len == 0) return error.EmptyKey;
        self.key_error.stage = .encrypt;
        // T9: fuera de Windows la clave va al archivo 0600 de ~/.config/devagents
        // (posix_keys); la base guarda solo la referencia proveedor/etiqueta.
        const ciphertext = (if (@import("builtin").os.tag == .windows)
            dpapi.encrypt(self.allocator, key)
        else
            @import("posix_keys.zig").store(self.allocator, provider_name, label, key)) catch |e| {
            if (@import("builtin").os.tag == .windows and e == error.EncryptFailed) self.key_error.win32 = @intFromEnum(std.os.windows.GetLastError());
            return e;
        };
        defer self.allocator.free(ciphertext);
        const sql = "INSERT INTO api_keys (provider_id, label, key_ciphertext, status) " ++
            "SELECT id, ?, ?, 'active' FROM providers WHERE name = ?";
        self.key_error.stage = .prepare;
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        self.key_error.stage = .bind;
        try db.bindText(stmt, 1, label);
        if (db.c.sqlite3_bind_blob(stmt, 2, ciphertext.ptr, @intCast(ciphertext.len), db.SQLITE_TRANSIENT) != db.c.SQLITE_OK) return error.EncryptFailed;
        try db.bindText(stmt, 3, provider_name);
        self.key_error.stage = .insert;
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.DbError;
        // Añadir una clave es una señal explícita de "quiero usar este proveedor de nuevo":
        // reactivarlo si había quedado enabled=0 por quedarse sin claves anteriormente.
        self.syncProviderEnabled(provider_name) catch {};
    }

    /// Sincroniza `providers.enabled` con la existencia de al menos una clave activa.
    /// Un proveedor sin ninguna clave utilizable no debe seguir apareciendo como
    /// habilitado en el catálogo/router/UI (listModels, catalog_info, rankCandidates
    /// ya filtran por p.enabled=1 — pero nada ponía este flag a 0 automáticamente al
    /// quedarse sin claves, dejando proveedores "fantasma" visibles en todas partes
    /// tras borrar/rotar sus claves). Best-effort: nunca falla la operación de claves
    /// que lo invoca si esta sincronización falla.
    fn syncProviderEnabled(self: *CredentialManager, provider_name: []const u8) !void {
        const count_stmt = try self.db.prepare(
            "SELECT COUNT(*) FROM api_keys WHERE provider_id = (SELECT id FROM providers WHERE name = ?) AND status = 'active'",
        );
        defer self.db.finalize(count_stmt);
        try db.bindText(count_stmt, 1, provider_name);
        if (db.c.sqlite3_step(count_stmt) != db.c.SQLITE_ROW) return error.DbError;
        const active_count = db.c.sqlite3_column_int64(count_stmt, 0);

        // MODELO-LOCAL: un proveedor local (Ollama) no vive de api_keys —
        // quedarse sin claves no lo apaga jamás.
        const update_stmt = try self.db.prepare("UPDATE providers SET enabled = (is_local = 1 OR ?) WHERE name = ?");
        defer self.db.finalize(update_stmt);
        try db.bindInt(update_stmt, 1, if (active_count > 0) 1 else 0);
        try db.bindText(update_stmt, 2, provider_name);
        if (db.c.sqlite3_step(update_stmt) != db.c.SQLITE_DONE) return error.DbError;
    }

    /// Inserta/refresca la clave de un proveedor bajo una ETIQUETA dada. P6 (multi-cuenta):
    /// el borrado previo se acota a la MISMA etiqueta — así re-ingresar "cuenta-1" la refresca
    /// (sin dejar claves viejas corruptas), pero dar de alta "cuenta-2" COEXISTE con "cuenta-1"
    /// en vez de borrarla (antes el DELETE de TODAS las activas hacía imposible el multi-cuenta).
    pub fn replaceKey(self: *CredentialManager, provider_name: []const u8, label: []const u8, key: []const u8) !void {
        const del_sql = "DELETE FROM api_keys WHERE provider_id = (SELECT id FROM providers WHERE name = ?) AND label = ?";
        const del_stmt = try self.db.prepare(del_sql);
        defer self.db.finalize(del_stmt);
        try db.bindText(del_stmt, 1, provider_name);
        try db.bindText(del_stmt, 2, label);
        if (db.c.sqlite3_step(del_stmt) != db.c.SQLITE_DONE) return error.DbError;
        try self.addKey(provider_name, label, key);
    }

    /// Elimina TODAS las claves de un proveedor (o de todos si provider_name es null).
    /// Uso: reset limpio del catálogo cuando el usuario revoca/rota claves. Devuelve
    /// el número de filas eliminadas. Los proveedores permanecen (solo se vacían claves).
    pub fn clearKeys(self: *CredentialManager, provider_name: ?[]const u8) !usize {
        if (@import("builtin").os.tag != .windows) try @import("posix_keys.zig").remove(self.allocator, provider_name, null);
        if (provider_name) |name| {
            const sql = "DELETE FROM api_keys WHERE provider_id = (SELECT id FROM providers WHERE name = ?)";
            const stmt = try self.db.prepare(sql);
            defer self.db.finalize(stmt);
            try db.bindText(stmt, 1, name);
            if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.DbError;
            const changes: usize = @intCast(db.c.sqlite3_changes(self.db.db));
            self.syncProviderEnabled(name) catch {};
            return changes;
        }
        const stmt = try self.db.prepare("DELETE FROM api_keys");
        defer self.db.finalize(stmt);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.DbError;
        const changes: usize = @intCast(db.c.sqlite3_changes(self.db.db));
        // Se vaciaron TODAS las claves de TODOS los proveedores: deshabilitarlos a todos
        // (cada uno se reactiva individualmente al recibir una clave nueva vía addKey).
        // MODELO-LOCAL: los proveedores de la máquina (is_local=1) no dependen de
        // claves — quedan habilitados aunque el barrido deje api_keys vacía.
        const disable_all = self.db.prepare("UPDATE providers SET enabled = is_local") catch return changes;
        defer self.db.finalize(disable_all);
        _ = db.c.sqlite3_step(disable_all);
        return changes;
    }

    /// Elimina las claves de un proveedor. Si `label` se da, borra SOLO esa etiqueta
    /// (multi-cuenta: quitar "cuenta-2" sin tocar "cuenta-1"); si es null, borra todas
    /// las del proveedor. Devuelve el número de filas eliminadas. Lo usa la tool MCP
    /// `remove_key` para que el usuario gestione claves desde Configuración sin lanzar
    /// key-admin.exe (que abría catalog.db con un esquema desfasado → DbSchemaAhead).
    pub fn removeKey(self: *CredentialManager, provider_name: []const u8, label: ?[]const u8) !usize {
        const lbl = label orelse return self.clearKeys(provider_name);
        if (@import("builtin").os.tag != .windows) try @import("posix_keys.zig").remove(self.allocator, provider_name, lbl);
        const sql = "DELETE FROM api_keys WHERE provider_id = (SELECT id FROM providers WHERE name = ?) AND label = ?";
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        try db.bindText(stmt, 1, provider_name);
        try db.bindText(stmt, 2, lbl);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.DbError;
        const changes: usize = @intCast(db.c.sqlite3_changes(self.db.db));
        // Si esa era la ÚLTIMA clave activa del proveedor, deshabilitarlo — evita que
        // siga apareciendo como "disponible" en Modelos/OpenDesign/Router sin ninguna
        // clave que lo respalde (era exactamente el síntoma reportado: proveedores
        // "eliminados" seguían visibles en todas partes).
        self.syncProviderEnabled(provider_name) catch {};
        return changes;
    }

    /// JSON array de claves registradas (SIN el material secreto): [{provider,label,status}].
    /// Alimenta la vista de Configuración para que el usuario vea y elimine claves por
    /// etiqueta. NUNCA expone key_ciphertext.
    pub fn keysJson(self: *CredentialManager, allocator: std.mem.Allocator) ![]u8 {
        // E1.13 multi-cuenta: cada clave expone etiqueta, estado, prioridad y
        // cuota (límite/usado) para que la UI las muestre y las edite.
        const stmt = try self.db.prepare(
            \\SELECT p.name, k.label, k.status,
            \\       COALESCE(k.priority, 0), COALESCE(k.quota_limit, 0),
            \\       COALESCE(k.quota_used, 0), COALESCE(k.requests_count, 0),
            \\       CASE WHEN k.last_used_at IS NOT NULL AND k.id =
            \\            (SELECT k2.id FROM api_keys k2 WHERE k2.provider_id = k.provider_id
            \\             ORDER BY k2.last_used_at DESC, k2.id DESC LIMIT 1)
            \\            THEN 1 ELSE 0 END
            \\FROM api_keys k JOIN providers p ON k.provider_id = p.id
            \\ORDER BY p.name, COALESCE(k.priority, 0), k.label
        );
        defer self.db.finalize(stmt);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginArray();
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            try js.beginObject();
            try js.objectField("provider");
            try js.write(std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
            try js.objectField("label");
            const label_c = db.c.sqlite3_column_text(stmt, 1);
            try js.write(if (label_c == null) "" else std.mem.span(label_c));
            try js.objectField("status");
            const status_c = db.c.sqlite3_column_text(stmt, 2);
            try js.write(if (status_c == null) "" else std.mem.span(status_c));
            try js.objectField("priority");
            try js.write(db.c.sqlite3_column_int64(stmt, 3));
            try js.objectField("quota_limit");
            try js.write(db.c.sqlite3_column_int64(stmt, 4));
            try js.objectField("quota_used");
            try js.write(db.c.sqlite3_column_int64(stmt, 5));
            try js.objectField("requests_count");
            try js.write(db.c.sqlite3_column_int64(stmt, 6));
            // E1.14: clave en uso — la última que sirvió una llamada del proveedor.
            try js.objectField("in_use");
            try js.write(db.c.sqlite3_column_int(stmt, 7) == 1);
            try js.endObject();
        }
        try js.endArray();
        return allocator.dupe(u8, out.written());
    }

    /// E1.13: edita prioridad/cuota/estado de una clave por (provider, label).
    /// `priority`/`quota_limit` con <0 = no tocar ese campo; `status` vacío =
    /// no tocar. Devuelve true si la clave existía.
    pub fn updateKeyMeta(self: *CredentialManager, provider_name: []const u8, label: []const u8, priority: i64, quota_limit: i64, status: []const u8) !bool {
        const find = try self.db.prepare(
            \\SELECT k.id FROM api_keys k JOIN providers p ON k.provider_id = p.id
            \\WHERE p.name = ? AND k.label = ? LIMIT 1
        );
        defer self.db.finalize(find);
        try db.bindText(find, 1, provider_name);
        try db.bindText(find, 2, label);
        if (db.c.sqlite3_step(find) != db.c.SQLITE_ROW) return false;
        const key_id = db.c.sqlite3_column_int64(find, 0);

        if (priority >= 0) {
            const s = try self.db.prepare("UPDATE api_keys SET priority = ? WHERE id = ?");
            defer self.db.finalize(s);
            try db.bindInt(s, 1, priority);
            try db.bindInt(s, 2, key_id);
            if (db.c.sqlite3_step(s) != db.c.SQLITE_DONE) return error.ExecFailed;
        }
        if (quota_limit >= 0) {
            const s = try self.db.prepare("UPDATE api_keys SET quota_limit = ? WHERE id = ?");
            defer self.db.finalize(s);
            try db.bindInt(s, 1, quota_limit);
            try db.bindInt(s, 2, key_id);
            if (db.c.sqlite3_step(s) != db.c.SQLITE_DONE) return error.ExecFailed;
        }
        if (status.len > 0) {
            const s = try self.db.prepare("UPDATE api_keys SET status = ? WHERE id = ?");
            defer self.db.finalize(s);
            try db.bindText(s, 1, status);
            try db.bindInt(s, 2, key_id);
            if (db.c.sqlite3_step(s) != db.c.SQLITE_DONE) return error.ExecFailed;
        }
        return true;
    }

    /// Obtiene una clave candidata para un proveedor (parámetros enlazados).
    ///
    /// E1.14 — selección multi-cuenta, conservando el reparto round-robin que ya
    /// existía (`last_used_at ASC, id ASC`): TODAS las claves del proveedor se
    /// turnan, sea cual sea su etiqueta. La prioridad es metadato visible
    /// (E1.13), NO criterio de selección — ordenar por ella rompería el reparto.
    /// Lo que sí cambia:
    ///  - Una clave `active` con `quota_limit>0` ya consumido no es candidata.
    ///  - Una clave `rotated` vuelve a ser candidata pasado `rotation_cooldown_s`
    ///    (backoff: no muere para siempre, se reincorpora sola al pool).
    pub fn getKey(self: *CredentialManager, provider_name: []const u8) !?[]const u8 {
        const sql = "SELECT k.key_ciphertext, k.id FROM api_keys k JOIN providers p ON k.provider_id = p.id " ++
            "WHERE p.name = ? " ++
            "AND (k.status = 'active' " ++
            "     OR (k.status = 'rotated' AND k.last_rotated_at IS NOT NULL " ++
            "         AND CAST(k.last_rotated_at AS INTEGER) <= CAST(strftime('%s','now') AS INTEGER) - ?)) " ++
            "AND NOT (COALESCE(k.quota_limit,0) > 0 AND COALESCE(k.quota_used,0) >= COALESCE(k.quota_limit,0)) " ++
            "ORDER BY k.last_used_at ASC, k.id ASC LIMIT 1";
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        try db.bindText(stmt, 1, provider_name);
        try db.bindInt(stmt, 2, self.rotation_cooldown_s);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
        const blob = db.c.sqlite3_column_blob(stmt, 0);
        const len = db.c.sqlite3_column_bytes(stmt, 0);
        const key_id = db.c.sqlite3_column_int64(stmt, 1);
        const ciphertext = @as([*]const u8, @ptrCast(blob))[0..@intCast(len)];
        const plain = switch (@import("builtin").os.tag) {
            .windows => try dpapi.decrypt(self.allocator, ciphertext),
            else => try @import("posix_keys.zig").resolve(self.allocator, ciphertext),
        };

        // LA ROTACION NO ROTABA. El orden es `last_used_at ASC, id ASC`, pero
        // nadie escribia nunca `last_used_at`: se quedaba NULL en todas las
        // claves, asi que la consulta devolvia SIEMPRE la de menor id. Con tres
        // cuentas de Gemini dadas de alta, la 2 y la 3 no se usaron jamas — y si
        // la primera estaba agotada o rota, TODAS las llamadas al proveedor
        // fallaban aunque hubiera cuota de sobra en las otras dos.
        self.markKeyUsed(key_id) catch {};
        return plain;
    }

    /// Marca una clave como recien usada. Best-effort: fallar aqui empeora el
    /// reparto pero no debe tumbar la llamada que ya tiene su clave.
    fn markKeyUsed(self: *CredentialManager, key_id: i64) !void {
        const stmt = try self.db.prepare(
            "UPDATE api_keys SET last_used_at = strftime('%s','now') WHERE id = ?",
        );
        defer self.db.finalize(stmt);
        try db.bindInt(stmt, 1, key_id);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    /// Etiqueta de la clave que `getKey` devolvería ahora mismo.
    ///
    /// La rotación es round-robin (`ORDER BY last_used_at ASC, id ASC`), así que
    /// con varias cuentas del mismo proveedor cada llamada puede salir por una
    /// distinta. Sin saber CUÁL se usó es imposible atribuir un 401 o un agotado
    /// de cuota a la cuenta correcta — que es justo lo que hace falta cuando se
    /// tienen tres claves de Gemini con contadores separados.
    pub fn peekKeyLabel(self: *CredentialManager, provider_name: []const u8) !?[]const u8 {
        // E1.14: mismo filtro de candidatas que getKey (cuota, backoff) para que
        // la etiqueta anunciada sea la que realmente se va a usar. Round-robin
        // intacto: sin priority en el ORDER BY.
        const sql = "SELECT k.label FROM api_keys k JOIN providers p ON k.provider_id = p.id " ++
            "WHERE p.name = ? " ++
            "AND (k.status = 'active' " ++
            "     OR (k.status = 'rotated' AND k.last_rotated_at IS NOT NULL " ++
            "         AND CAST(k.last_rotated_at AS INTEGER) <= CAST(strftime('%s','now') AS INTEGER) - ?)) " ++
            "AND NOT (COALESCE(k.quota_limit,0) > 0 AND COALESCE(k.quota_used,0) >= COALESCE(k.quota_limit,0)) " ++
            "ORDER BY k.last_used_at ASC, k.id ASC LIMIT 1";
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        try db.bindText(stmt, 1, provider_name);
        try db.bindInt(stmt, 2, self.rotation_cooldown_s);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
        const ptr = db.c.sqlite3_column_text(stmt, 0);
        if (ptr == null) return null;
        return try self.allocator.dupe(u8, ptr[0..std.mem.len(ptr)]);
    }

    /// Obtiene una clave activa concreta. Se usa cuando el caller acaba de
    /// insertar/reemplazar una etiqueta y debe verificar esa fila, no la primera
    /// clave del proveedor según el orden de rotación.
    pub fn getKeyByLabel(self: *CredentialManager, provider_name: []const u8, label: []const u8) !?[]const u8 {
        const sql = "SELECT k.key_ciphertext FROM api_keys k JOIN providers p ON k.provider_id = p.id " ++
            "WHERE p.name = ? AND k.label = ? AND k.status = 'active' LIMIT 1";
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        try db.bindText(stmt, 1, provider_name);
        try db.bindText(stmt, 2, label);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
        const blob = db.c.sqlite3_column_blob(stmt, 0);
        const len = db.c.sqlite3_column_bytes(stmt, 0);
        const ciphertext = @as([*]const u8, @ptrCast(blob))[0..@intCast(len)];
        return switch (@import("builtin").os.tag) {
            .windows => try dpapi.decrypt(self.allocator, ciphertext),
            else => try @import("posix_keys.zig").resolve(self.allocator, ciphertext),
        };
    }

    /// Marca la clave activa más antigua como rotada (exhausta o rate-limited).
    pub fn rotateKey(self: *CredentialManager, provider_name: []const u8) !void {
        // Se rota la clave que ACABA DE USARSE, es decir la de `last_used_at`
        // más RECIENTE. Antes esta consulta ordenaba igual que `getKey`
        // (ASC), y solo acertaba porque `last_used_at` no se escribía nunca y
        // todas empataban en NULL. Al empezar a sellar el uso —necesario para
        // que la rotación reparta de verdad entre cuentas— ese ASC pasó a
        // señalar a la clave SIGUIENTE: se marcaba como agotada la que aún no
        // se había probado y se reintentaba con la que acababa de fallar.
        const sql = "UPDATE api_keys SET status = 'rotated', last_rotated_at = strftime('%s','now') " ++
            "WHERE id = (SELECT k.id FROM api_keys k JOIN providers p ON k.provider_id = p.id " ++
            // `last_used_at DESC` (SQLite pone los NULL AL FINAL en DESC) toma
            // la clave que se acaba de usar; si ninguna se ha usado todavia,
            // todas empatan en NULL y desempata `id ASC`, que retira la primera
            // — el comportamiento historico que esperan los tests de rotacion
            // sin uso previo.
            "WHERE p.name = ? AND k.status = 'active' ORDER BY k.last_used_at DESC, k.id ASC LIMIT 1)";
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        try db.bindText(stmt, 1, provider_name);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.DbError;
    }

    /// Incrementa el contador de uso y la cuota consumida de la clave que ACABA
    /// de servir la llamada — la de `last_used_at` más reciente (getKey la selló
    /// con markKeyUsed justo antes). Antes ordenaba ASC y cargaba el uso a la
    /// clave MENOS reciente, no a la que trabajó. `quota_used` es lo que E1.14
    /// confronta con `quota_limit` para dejar de ofrecer una clave al tope.
    pub fn recordUsage(self: *CredentialManager, provider_name: []const u8) !void {
        const sql = "UPDATE api_keys SET requests_count = requests_count + 1, " ++
            "quota_used = COALESCE(quota_used,0) + 1, last_used_at = strftime('%s','now') " ++
            "WHERE id = (SELECT k.id FROM api_keys k JOIN providers p ON k.provider_id = p.id " ++
            "WHERE p.name = ? AND k.status = 'active' ORDER BY k.last_used_at DESC, k.id DESC LIMIT 1)";
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        try db.bindText(stmt, 1, provider_name);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.DbError;
    }

    /// Driver de envío con rotación automática ante 429 (T-F2-05).
    /// Obtiene la clave activa, invoca `sendFn`; ante `.rate_limited` rota y reintenta
    /// con la siguiente clave; ante `.ok` registra el uso y termina; ante `.fatal` propaga.
    /// Si se agotan las claves activas, devuelve `AllKeysExhausted`.
    pub fn sendWithRotation(
        self: *CredentialManager,
        provider_name: []const u8,
        ctx: *anyopaque,
        sendFn: *const fn (ctx: *anyopaque, key: []const u8) AttemptOutcome,
    ) !void {
        while (true) {
            const key = (try self.getKey(provider_name)) orelse return error.AllKeysExhausted;
            defer self.allocator.free(key);
            switch (sendFn(ctx, key)) {
                .ok => {
                    try self.recordUsage(provider_name);
                    return;
                },
                .rate_limited => {
                    try self.rotateKey(provider_name);
                    continue;
                },
                .auth_failed => return error.AuthFailed,
                .fatal => return error.SendFailed,
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "credential manager init and migrate" {
    const allocator = std.testing.allocator;
    const path = ":memory:";
    var cm = try CredentialManager.init(allocator, path);
    defer cm.deinit();
}

test "credential manager add provider and key" {
    const allocator = std.testing.allocator;
    const path = ":memory:";
    var cm = try CredentialManager.init(allocator, path);
    defer cm.deinit();
    try cm.addProvider("TestProvider", "https://api.test.com/v1", "openai", true);
    try cm.addKey("TestProvider", "default", "test-key-123");
    const key = try cm.getKey("TestProvider");
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("test-key-123", key.?);
    if (key) |k| allocator.free(k);
}

test "credential manager long key roundtrip (70 chars, NVIDIA format)" {
    const allocator = std.testing.allocator;
    const path = ":memory:";
    var cm = try CredentialManager.init(allocator, path);
    defer cm.deinit();
    try cm.addProvider("NVIDIA API", "https://integrate.api.nvidia.com/v1", "openai", true);
    const long_key = "nvapi-dummy123456789012345678901234567890123456789012345678901234567890123";
    try std.testing.expectEqual(@as(usize, 74), long_key.len);
    try cm.addKey("NVIDIA API", "default", long_key);
    const roundtrip = try cm.getKey("NVIDIA API");
    try std.testing.expect(roundtrip != null);
    try std.testing.expectEqualStrings(long_key, roundtrip.?);
    if (roundtrip) |k| allocator.free(k);
}

test "P6: replaceKey con MISMA etiqueta refresca la clave (sin dejar la vieja)" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("NVIDIA API", "https://integrate.api.nvidia.com/v1", "openai", true);
    try cm.addKey("NVIDIA API", "cuenta-1", "nvapi-test1234567890");
    const new_key = "nvapi-dummy987654321012345678901234567890123456789012345678901234567890123456";
    // Misma etiqueta → reemplaza esa cuenta (refresco), no acumula.
    try cm.replaceKey("NVIDIA API", "cuenta-1", new_key);
    const key = try cm.getKey("NVIDIA API");
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings(new_key, key.?);
    if (key) |k| allocator.free(k);
}

test "P6: alta de SEGUNDA cuenta (etiqueta distinta) coexiste, no borra la primera" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("Cerebras", "https://api.cerebras.ai/v1", "openai", true);
    try cm.addKey("Cerebras", "cuenta-1", "csk-cuenta-uno-000000000000000000000000");
    // Segunda cuenta con etiqueta distinta: DEBE coexistir (multi-cuenta real, madre 1.2).
    try cm.replaceKey("Cerebras", "cuenta-2", "csk-cuenta-dos-111111111111111111111111");
    const stmt = try cm.db.prepare("SELECT COUNT(*) FROM api_keys WHERE provider_id=(SELECT id FROM providers WHERE name='Cerebras') AND status='active'");
    defer cm.db.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(c_int, 2), db.c.sqlite3_column_int(stmt, 0));
}

test "PORTABLE-KEY-ADMIN: roundtrip verifies the requested label when provider has multiple keys" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("NVIDIA API", "https://integrate.api.nvidia.com/v1", "openai", true);
    try cm.addKey("NVIDIA API", "first", "nvapi-test00000000000000000000000000000000000000000000000000000000000001");
    try cm.addKey("NVIDIA API", "second", "nvapi-test11111111111111111111111111111111111111111111111111111111111112");
    const second = try cm.getKeyByLabel("NVIDIA API", "second");
    try std.testing.expect(second != null);
    defer allocator.free(second.?);
    try std.testing.expectEqualStrings("nvapi-test11111111111111111111111111111111111111111111111111111111111112", second.?);
}

test "credential manager key rotation" {
    const allocator = std.testing.allocator;
    const path = ":memory:";
    var cm = try CredentialManager.init(allocator, path);
    defer cm.deinit();
    try cm.addProvider("TestProvider", "https://api.test.com/v1", "openai", true);
    try cm.addKey("TestProvider", "key1", "secret1");
    try cm.addKey("TestProvider", "key2", "secret2");
    try cm.rotateKey("TestProvider");
    const key = try cm.getKey("TestProvider");
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("secret2", key.?);
    if (key) |k| allocator.free(k);
}

fn isProviderEnabled(cm: *CredentialManager, name: []const u8) !bool {
    const stmt = try cm.db.prepare("SELECT enabled FROM providers WHERE name = ?");
    defer cm.db.finalize(stmt);
    try db.bindText(stmt, 1, name);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.ProviderNotFound;
    return db.c.sqlite3_column_int(stmt, 0) == 1;
}

test "GOBERNANZA-CATALOGO: removeKey deshabilita el proveedor al quedarse sin claves activas" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("NVIDIA API", "https://integrate.api.nvidia.com/v1", "openai", true);
    try cm.addKey("NVIDIA API", "default", "nvapi-test-key-000000000000000000");
    try std.testing.expect(try isProviderEnabled(&cm, "NVIDIA API"));

    _ = try cm.removeKey("NVIDIA API", "default");
    try std.testing.expect(!try isProviderEnabled(&cm, "NVIDIA API"));
}

test "GOBERNANZA-CATALOGO: removeKey NO deshabilita si quedan otras claves activas (multi-cuenta)" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("NVIDIA API", "https://integrate.api.nvidia.com/v1", "openai", true);
    try cm.addKey("NVIDIA API", "cuenta-1", "nvapi-test000000000000000000001");
    try cm.addKey("NVIDIA API", "cuenta-2", "nvapi-test000000000000000000002");

    _ = try cm.removeKey("NVIDIA API", "cuenta-1");
    try std.testing.expect(try isProviderEnabled(&cm, "NVIDIA API"));
}

test "GOBERNANZA-CATALOGO: addKey reactiva un proveedor que habia quedado deshabilitado" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("NVIDIA API", "https://integrate.api.nvidia.com/v1", "openai", true);
    try cm.addKey("NVIDIA API", "default", "nvapi-test-key-000000000000000000");
    _ = try cm.removeKey("NVIDIA API", "default");
    try std.testing.expect(!try isProviderEnabled(&cm, "NVIDIA API"));

    try cm.addKey("NVIDIA API", "default", "nvapi-test000000000000000000003");
    try std.testing.expect(try isProviderEnabled(&cm, "NVIDIA API"));
}

test "GOBERNANZA-CATALOGO: clearKeys(null) deshabilita TODOS los proveedores" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("NVIDIA API", "https://integrate.api.nvidia.com/v1", "openai", true);
    try cm.addProvider("Cerebras", "https://api.cerebras.ai/v1", "openai", true);
    try cm.addKey("NVIDIA API", "default", "nvapi-test-key-000000000000000000");
    try cm.addKey("Cerebras", "default", "csk-test-key-0000000000000000000000");

    _ = try cm.clearKeys(null);
    try std.testing.expect(!try isProviderEnabled(&cm, "NVIDIA API"));
    try std.testing.expect(!try isProviderEnabled(&cm, "Cerebras"));
}

test "MODELO-LOCAL: clearKeys(null) y removeKey no apagan un proveedor local" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("NVIDIA API", "https://integrate.api.nvidia.com/v1", "openai", true);
    // Un proveedor local llega al catálogo con is_local=1 (lo pone el seed de
    // ALL_PROVIDERS); aquí se simula directamente para no acoplar el test al
    // sembrado completo.
    try cm.addProvider("Ollama", "http://127.0.0.1:11434/v1", "openai", true);
    try cm.db.exec("UPDATE providers SET is_local=1 WHERE name='Ollama'");
    try cm.addKey("NVIDIA API", "default", "nvapi-test-key-000000000000000000");

    // Barrido global: la nube se apaga, el local no.
    _ = try cm.clearKeys(null);
    try std.testing.expect(!try isProviderEnabled(&cm, "NVIDIA API"));
    try std.testing.expect(try isProviderEnabled(&cm, "Ollama"));

    // Y la ruta individual (removeKey/clearKeys(nombre)) tampoco lo apaga:
    // simula un usuario que "quitó la clave" de Ollama — su enabled no vive
    // de api_keys.
    _ = try cm.clearKeys("Ollama");
    try std.testing.expect(try isProviderEnabled(&cm, "Ollama"));
    _ = try cm.removeKey("Ollama", null);
    try std.testing.expect(try isProviderEnabled(&cm, "Ollama"));
}

test "credential manager resists SQL injection in provider name" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    // Proveedor legítimo + un nombre malicioso tratado como literal (no como SQL).
    try cm.addProvider("Safe", "https://api.safe.com/v1", "openai", true);
    try cm.addKey("Safe", "k", "good-secret");
    const evil = "Robert'); DROP TABLE providers;--";
    try cm.addProvider(evil, "https://x", "openai", true);
    // La tabla 'providers' sigue existiendo y el proveedor legítimo conserva su clave.
    const key = try cm.getKey("Safe");
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("good-secret", key.?);
    if (key) |k| allocator.free(k);
    // El nombre malicioso se almacenó literal: no hay clave para él, pero la consulta no rompe.
    const none = try cm.getKey(evil);
    try std.testing.expect(none == null);
}

const RotationTestCtx = struct {
    calls: usize = 0,
    saw_secret1: bool = false,
    saw_secret2: bool = false,
};

fn mockSendRateLimitFirstKey(ctx_ptr: *anyopaque, key: []const u8) AttemptOutcome {
    const ctx: *RotationTestCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.calls += 1;
    // Comparar AQUÍ (la clave es propiedad del driver y se libera tras retornar):
    // no se debe almacenar el slice.
    if (std.mem.eql(u8, key, "secret1")) {
        ctx.saw_secret1 = true;
        return .rate_limited;
    }
    if (std.mem.eql(u8, key, "secret2")) ctx.saw_secret2 = true;
    return .ok;
}

test "429 rotates key and retry succeeds" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("Prov", "https://x/v1", "openai", true);
    try cm.addKey("Prov", "k1", "secret1");
    try cm.addKey("Prov", "k2", "secret2");

    var ctx = RotationTestCtx{};
    try cm.sendWithRotation("Prov", &ctx, mockSendRateLimitFirstKey);

    // Dos intentos: secret1 (429) → rota → secret2 (ok).
    try std.testing.expectEqual(@as(usize, 2), ctx.calls);
    try std.testing.expect(ctx.saw_secret1);
    try std.testing.expect(ctx.saw_secret2);

    // La clave activa que queda es la que funcionó.
    const active = try cm.getKey("Prov");
    try std.testing.expect(active != null);
    try std.testing.expectEqualStrings("secret2", active.?);
    if (active) |k| allocator.free(k);
}

fn mockSendAlwaysRateLimited(ctx_ptr: *anyopaque, key: []const u8) AttemptOutcome {
    _ = key;
    const ctx: *RotationTestCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.calls += 1;
    return .rate_limited;
}

test "429 exhausting all keys returns AllKeysExhausted" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("Prov", "https://x/v1", "openai", true);
    try cm.addKey("Prov", "k1", "s1");
    try cm.addKey("Prov", "k2", "s2");

    var ctx = RotationTestCtx{};
    try std.testing.expectError(error.AllKeysExhausted, cm.sendWithRotation("Prov", &ctx, mockSendAlwaysRateLimited));
    // Se intentó con ambas claves antes de agotarse.
    try std.testing.expectEqual(@as(usize, 2), ctx.calls);
}

fn mockSendAuthFailed(ctx_ptr: *anyopaque, key: []const u8) AttemptOutcome {
    _ = key;
    const ctx: *RotationTestCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.calls += 1;
    return .auth_failed;
}

test "auth_failed returns error.AuthFailed without rotating" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("Prov", "https://x/v1", "openai", true);
    try cm.addKey("Prov", "k1", "s1");
    try cm.addKey("Prov", "k2", "s2");

    var ctx = RotationTestCtx{};
    try std.testing.expectError(error.AuthFailed, cm.sendWithRotation("Prov", &ctx, mockSendAuthFailed));
    // Solo 1 intento: auth_failed no rota la clave.
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
}

// ── E1.14: cuota y backoff en la selección, con round-robin intacto ─────

test "E1.14: el reparto entre claves sigue siendo round-robin (prioridad no selecciona)" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("P", "https://x/v1", "openai", true);
    try cm.addKey("P", "k1", "s-1");
    try cm.addKey("P", "k2", "s-2");
    // Aunque k2 tenga prioridad máxima, el turno elige la MENOS usada (round-robin).
    _ = try cm.updateKeyMeta("P", "k2", 99, -1, "");
    // k2 ya se usó hace rato (last_used_at viejo), k1 nunca (NULL = la menos usada).
    {
        const s = try cm.db.prepare("UPDATE api_keys SET last_used_at = '1000000' WHERE label = 'k2'");
        defer cm.db.finalize(s);
        try std.testing.expect(db.c.sqlite3_step(s) == db.c.SQLITE_DONE);
    }
    // La candidata es k1 (nunca usada), no k2 pese a su prioridad 99.
    const label = (try cm.peekKeyLabel("P")).?;
    defer allocator.free(label);
    try std.testing.expectEqualStrings("k1", label);
}

test "E1.14: clave con cuota agotada no es candidata" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("P", "https://x/v1", "openai", true);
    try cm.addKey("P", "con_cupo", "s-1");
    try cm.addKey("P", "sin_cupo", "s-2");
    // sin_cupo tiene prioridad máxima pero cuota ya consumida al tope.
    _ = try cm.updateKeyMeta("P", "sin_cupo", 99, 1, "");
    // consume su única unidad de cuota directamente
    {
        const s = try cm.db.prepare("UPDATE api_keys SET quota_used = 1 WHERE label = 'sin_cupo'");
        defer cm.db.finalize(s);
        try std.testing.expect(db.c.sqlite3_step(s) == db.c.SQLITE_DONE);
    }
    const label = try cm.peekKeyLabel("P");
    try std.testing.expect(label != null);
    defer allocator.free(label.?);
    // Aunque tiene más prioridad, la cuota agotada la descarta → cae a con_cupo.
    try std.testing.expectEqualStrings("con_cupo", label.?);
}

test "E1.14: clave rotated se reincorpora tras el cooldown (backoff)" {
    const allocator = std.testing.allocator;
    var cm = try CredentialManager.init(allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("P", "https://x/v1", "openai", true);
    try cm.addKey("P", "unica", "s-1");

    // La roto: queda 'rotated' y, con cooldown normal, no es candidata.
    try cm.rotateKey("P");
    try std.testing.expect((try cm.peekKeyLabel("P")) == null);

    // Con el cooldown ya vencido (0s inyectado) se reincorpora — backoff real.
    cm.rotation_cooldown_s = 0;
    const label = try cm.peekKeyLabel("P");
    try std.testing.expect(label != null);
    defer allocator.free(label.?);
    try std.testing.expectEqualStrings("unica", label.?);
}

test "SEC-RED configurar proveedor rechaza HTTP remoto sin cambiar lo guardado" {
    var cm = try CredentialManager.init(std.testing.allocator, ":memory:");
    defer cm.deinit();
    try cm.addProvider("SecurityFixture", "https://example.invalid/v1", "openai", true);
    try std.testing.expectError(error.InsecureCredentialTransport, cm.addProvider("SecurityFixture", "http://example.invalid/v1", "openai", true));
    try std.testing.expectError(error.InsecureCredentialTransport, cm.addProvider("SecurityFixture", "http://localhost.:11434/v1", "openai", true));
    const stmt = try cm.db.prepare("SELECT base_url FROM providers WHERE name='SecurityFixture'");
    defer cm.db.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("https://example.invalid/v1", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
    try cm.addProvider("SecurityFixture", "http://127.42.0.1:8000/v1", "openai", true);
    try cm.addProvider("SecurityFixture", "http://localhost:11434/v1", "openai", true);
    try cm.addProvider("SecurityFixture", "http://LOCALHOST:11434/v1", "openai", true);
}
