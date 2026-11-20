const std = @import("std");
const core = @import("core");
const providers = @import("providers");

/// Administración de claves API (ARCHITECTURE §6): ingesta una clave al catálogo
/// cifrada con DPAPI vía CredentialManager. La clave NUNCA se imprime ni se loguea;
/// solo se reporta el resultado y el tamaño del ciphertext almacenado.
///
/// Uso:
///   key-admin <provider> <key> [label]       — ingesta/rota clave
///   key-admin --disable <provider>           — deshabilita proveedor (enabled=0)
///   key-admin --enable  <provider>           — re-habilita proveedor (enabled=1)
///   key-admin --clear-keys [provider]        — vacía claves (de un proveedor o de todos)
///   key-admin --status                        — lista proveedores y claves (read-only, sin claves)
/// S3 / FIRE-04: el catalogo vive en %LOCALAPPDATA%\DevAgents, no junto al cwd.
///
/// Abrirlo por nombre RELATIVO hacia que `key-admin --status` informara «0 claves
/// activas» ejecutado desde la raiz del repositorio, mientras el motor estaba usando
/// cinco: creaba un catalog.db vacio en el cwd y reportaba sobre el. Un diagnostico que
/// miente en silencio es peor que no tener diagnostico, y este modulo (`paths`) existe
/// exactamente para que el CLI y la cabina miren el MISMO archivo.
fn openCatalog(allocator: std.mem.Allocator) !core.credentials.CredentialManager {
    const path = try core.paths.catalogDb(allocator);
    defer allocator.free(path);
    return core.credentials.CredentialManager.init(allocator, path);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var it = try init.minimal.args.iterateAllocator(allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    const first = it.next() orelse return usage();

    if (std.mem.eql(u8, first, "--status")) {
        return statusReport(allocator);
    }

    if (std.mem.eql(u8, first, "--disable") or std.mem.eql(u8, first, "--enable")) {
        const provider_name = it.next() orelse return usage();
        const enable: bool = std.mem.eql(u8, first, "--enable");
        return toggleProvider(allocator, provider_name, enable);
    }

    if (std.mem.eql(u8, first, "--clear-keys")) {
        // Opcional: nombre de proveedor. Sin argumento → vacía TODAS las claves.
        const maybe_provider = it.next();
        return clearKeys(allocator, maybe_provider);
    }

    // Normal flow: key-admin <provider> <key> [label]
    const provider_name = first;
    const key = it.next() orelse return usage();
    const label = it.next() orelse "default";

    const cfg = findProvider(provider_name) orelse {
        std.debug.print("Proveedor desconocido: '{s}'. Válidos:\n", .{provider_name});
        for (providers.providers.ALL_PROVIDERS) |p| std.debug.print("  - {s}\n", .{p.name});
        return error.UnknownProvider;
    };

    var cm = try openCatalog(allocator);
    defer cm.deinit();

    try cm.addProvider(cfg.name, cfg.base_url, @tagName(cfg.api_style), cfg.is_free_tier);
    // addProvider es INSERT OR IGNORE: si el proveedor ya existía con base_url vieja,
    // sincronizarla con la config compilada (fuente de verdad).
    try syncBaseUrl(&cm, cfg.name, cfg.base_url);
    try cm.replaceKey(cfg.name, label, key);

    // Verificación inmediata: la clave se recupera y descifra correctamente.
    const roundtrip = (try cm.getKeyByLabel(cfg.name, label)) orelse return error.KeyNotStored;
    defer allocator.free(roundtrip);
    const ok = std.mem.eql(u8, roundtrip, key);
    // T9 fase B: en Linux no hay DPAPI; la clave va a ~/.config/devagents/keys.json (0600).
    const where = if (@import("builtin").os.tag == .windows) "cifrada (DPAPI" else "en archivo privado 0600 (sin DPAPI";
    std.debug.print("[key-admin] {s}: clave '{s}' almacenada {s}, {d} chars) — roundtrip {s}\n", .{
        cfg.name, label, where, key.len, if (ok) "OK" else "FALLIDO",
    });
    if (!ok) return error.RoundtripMismatch;
}

fn syncBaseUrl(cm: *core.credentials.CredentialManager, name: []const u8, base_url: []const u8) !void {
    const stmt = try cm.db.prepare("UPDATE providers SET base_url = ? WHERE name = ?");
    defer cm.db.finalize(stmt);
    try core.db.bindText(stmt, 1, base_url);
    try core.db.bindText(stmt, 2, name);
    if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_DONE) return error.DbError;
}

fn findProvider(name: []const u8) ?providers.providers.ProviderConfig {
    for (providers.providers.ALL_PROVIDERS) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn toggleProvider(allocator: std.mem.Allocator, name: []const u8, enable: bool) !void {
    _ = allocator;
    var cm = try openCatalog(std.heap.page_allocator);
    defer cm.deinit();
    try ensureProviders(&cm);

    const stmt = try cm.db.prepare("UPDATE providers SET enabled = ? WHERE name = ?");
    defer cm.db.finalize(stmt);
    try core.db.bindInt(stmt, 1, if (enable) 1 else 0);
    try core.db.bindText(stmt, 2, name);
    if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_DONE) return error.DbError;

    const changes = core.db.c.sqlite3_changes(cm.db.db);
    if (changes == 0) {
        std.debug.print("[key-admin] Proveedor '{s}' no encontrado en catalog.db — sin cambios.\n", .{name});
        return error.ProviderNotFound;
    }
    std.debug.print("[key-admin] Proveedor '{s}' {s} (enabled={d}, {d} filas afectadas).\n", .{
        name, if (enable) "re-habilitado" else "deshabilitado", @as(i64, if (enable) 1 else 0), changes,
    });
}

fn clearKeys(allocator: std.mem.Allocator, provider_name: ?[]const u8) !void {
    var cm = try openCatalog(allocator);
    defer cm.deinit();
    try ensureProviders(&cm);
    const removed = try cm.clearKeys(provider_name);
    if (provider_name) |name| {
        std.debug.print("[key-admin] {d} clave(s) eliminada(s) del proveedor '{s}'.\n", .{ removed, name });
    } else {
        std.debug.print("[key-admin] {d} clave(s) eliminada(s) de TODOS los proveedores.\n", .{removed});
    }
}

fn statusReport(allocator: std.mem.Allocator) !void {
    var cm = try openCatalog(allocator);
    defer cm.deinit();
    try ensureProviders(&cm);

    const stmt = try cm.db.prepare("SELECT p.name, p.enabled, p.is_free_tier, " ++
        "(SELECT COUNT(*) FROM api_keys k WHERE k.provider_id = p.id AND k.status = 'active') " ++
        "FROM providers p ORDER BY p.id");
    defer cm.db.finalize(stmt);

    var provider_count: usize = 0;
    var total_keys: usize = 0;
    std.debug.print("[key-admin] Provider status (read-only):\n", .{});
    while (core.db.c.sqlite3_step(stmt) == core.db.c.SQLITE_ROW) {
        const name_ptr = core.db.c.sqlite3_column_text(stmt, 0);
        const name = if (name_ptr) |p| p[0..std.mem.len(p)] else "(null)";
        const enabled = core.db.c.sqlite3_column_int(stmt, 1);
        const is_free = core.db.c.sqlite3_column_int(stmt, 2);
        const key_count = core.db.c.sqlite3_column_int(stmt, 3);
        std.debug.print("  {s}: enabled={d} free_tier={d} keys={d}\n", .{ name, enabled, is_free, key_count });
        provider_count += 1;
        total_keys += @intCast(key_count);
    }
    std.debug.print("[key-admin] Total: {d} providers, {d} active keys\n", .{ provider_count, total_keys });
}

fn ensureProviders(cm: *core.credentials.CredentialManager) !void {
    for (providers.providers.ALL_PROVIDERS) |cfg| {
        try cm.addProvider(cfg.name, cfg.base_url, @tagName(cfg.api_style), cfg.is_free_tier);
        try syncBaseUrl(cm, cfg.name, cfg.base_url);
    }
}

fn usage() !void {
    std.debug.print(
        \\Uso:
        \\  key-admin <provider> <key> [label]   — ingesta/rota clave
        \\  key-admin --disable <provider>       — deshabilita proveedor
        \\  key-admin --enable  <provider>       — re-habilita proveedor
        \\  key-admin --clear-keys [provider]    — vacía claves (de un proveedor o de todos)
        \\  key-admin --status                    — lista proveedores y claves (read-only)
        \\
    , .{});
    return error.MissingArgs;
}
