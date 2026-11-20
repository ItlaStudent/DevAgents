const std = @import("std");
const db = @import("db.zig");
const router = @import("model_router.zig");
const agents = @import("external_agents.zig");
const registry = @import("external_registry.zig");

pub const Role = struct { role: []const u8, provider: ?[]const u8, model: ?[]const u8 };
pub const Issue = struct { role: []const u8, provider: []const u8, model: []const u8, cause: []const u8, reason: []const u8, action: []const u8, severity: enum { block, warn } = .block, authorized: ?u64 = null, spent: ?u64 = null, remaining: ?u64 = null };

pub fn allowed(issues: []const Issue) bool {
    for (issues) |issue| if (issue.severity == .block) return false;
    return true;
}

pub fn check(a: std.mem.Allocator, catalog: db.Connection, mode: router.GovernanceMode, roles: []const Role, external: []const u8, runtime: ?db.Connection) ![]Issue {
    var issues: std.ArrayList(Issue) = .empty;
    errdefer issues.deinit(a);
    for (roles) |role| {
        const p = role.provider orelse continue;
        const m = role.model orelse continue;
        if (p.len == 0 or m.len == 0) continue;
        var issue: ?Issue = null;
        const base = Issue{ .role = role.role, .provider = p, .model = m, .cause = "", .reason = "", .action = "Cambia a un modelo elegible o usa tu suscripcion" };
        if (agents.isAgentProvider(p)) {
            if (!std.mem.eql(u8, role.role, "ejecutor") and !std.mem.eql(u8, p, "agent:codex")) {
                issue = base;
                issue.?.cause = "text_role_unsupported";
                issue.?.reason = "Este CLI no ofrece el protocolo de plan/veredicto; elige Codex o un modelo de nube para este rol";
            } else if (mode == .local_only) {
                issue = base;
                issue.?.cause = "governance_blocked";
                issue.?.reason = "Solo local bloquea la suscripcion de nube";
            } else {
                const pin = registry.resolvePin(a, catalog, external, p, m) catch |err| blk: {
                    issue = base;
                    issue.?.cause = @errorName(err);
                    issue.?.reason = "Suscripcion no disponible: sesion, modelo o binario sin confirmar; vuelve a detectar";
                    break :blk null;
                };
                if (pin) |resolved| {
                    defer resolved.deinit(a);
                    const eligibility = try @import("model_selection.zig").externalEligibility(a, external, p, m);
                    if (mode == .free_tier_first and !eligibility.free) {
                        issue = base;
                        issue.?.cause = "governance_blocked";
                        issue.?.reason = "Solo gratis bloquea este modelo de pago de OpenCode";
                    }
                }
            }
        } else {
            const q = try catalog.prepare("SELECT p.enabled,p.is_local,m.available,m.is_free,EXISTS(SELECT 1 FROM api_keys k WHERE k.provider_id=p.id AND k.status='active') FROM providers p JOIN models m ON m.provider_id=p.id WHERE p.name=? AND m.model_name=?");
            defer catalog.finalize(q);
            try db.bindText(q, 1, p);
            try db.bindText(q, 2, m);
            const rc = db.c.sqlite3_step(q);
            if (rc != db.c.SQLITE_ROW and rc != db.c.SQLITE_DONE) return error.StepFailed;
            const found = rc == db.c.SQLITE_ROW;
            const local = found and db.c.sqlite3_column_int(q, 1) != 0;
            const free = found and router.catalogModelIsFree(catalog, p, m);
            const keyed = found and db.c.sqlite3_column_int(q, 4) != 0;
            if (!found or db.c.sqlite3_column_int(q, 2) == 0) {
                issue = base;
                issue.?.cause = "model_unavailable";
                issue.?.reason = "Modelo no disponible en el catalogo; actualiza o cambia el modelo";
            } else if (!local and !keyed) {
                issue = base;
                issue.?.cause = "missing_key";
                issue.?.reason = "No hay clave activa para este proveedor";
            } else if (db.c.sqlite3_column_int(q, 0) == 0) {
                issue = base;
                issue.?.cause = "provider_unavailable";
                issue.?.reason = "Proveedor deshabilitado; revisa su estado o elige otro";
            } else if ((mode == .free_tier_first and !free) or (mode == .local_only and !local)) {
                issue = base;
                issue.?.cause = "governance_blocked";
                issue.?.reason = if (mode == .local_only) "Solo local bloquea este modelo de nube" else "Solo gratis bloquea este modelo de pago";
                issue.?.action = "Cambia a gratis o suscripcion, o permite pago para esta orden";
            }
            if (issue == null and !free and !local) {
                const budget = @import("spend_budget.zig").estado(catalog);
                if (budget.restantes() == 0) {
                    issue = base;
                    issue.?.cause = "paid_budget_exhausted";
                    issue.?.reason = "Cupo de llamadas de pago agotado; no se enviara la solicitud";
                    issue.?.action = "Autorizar mas llamadas en Configuracion > Gobernanza o cambiar a gratis/suscripcion";
                    issue.?.authorized = budget.autorizadas;
                    issue.?.spent = budget.consumidas;
                    issue.?.remaining = budget.restantes();
                }
            }
        }
        if (issue == null and runtime != null and !agents.isAgentProvider(p)) {
            // Recent observed failures are warnings before sending, with a bounded cooldown.
            const q = try runtime.?.prepare("SELECT MAX(last_err_at),MAX(last_ok_at),MAX(last_err_kind) FROM model_health WHERE model_id=?");
            defer runtime.?.finalize(q);
            const id = try std.fmt.allocPrint(a, "{s}/{s}", .{ p, m });
            defer a.free(id);
            try db.bindText(q, 1, id);
            if (db.c.sqlite3_step(q) != db.c.SQLITE_ROW) return error.StepFailed;
            const last_error = db.c.sqlite3_column_int64(q, 0);
            const last_ok = db.c.sqlite3_column_int64(q, 1);
            const now = @import("health.zig").nowSeconds(runtime.?);
            if (last_error > last_ok and last_error <= now and now - last_error < 60) {
                issue = base;
                issue.?.cause = "provider_recent_failure";
                issue.?.reason = "Este modelo fallo en el ultimo minuto: clave, cuota, disponibilidad o respuesta; revisa Diagnostico";
                issue.?.action = "Elige otro modelo, comprueba el proveedor o reintenta tras un minuto";
            }
        }
        if (issue) |i| try issues.append(a, i);
    }
    if (roles.len >= 3) {
        const producer = roles[1];
        const audit = roles[2];
        if (producer.provider != null and producer.model != null and audit.provider != null and audit.model != null and
            agents.crossModelManufacturerExcluded(producer.provider.?, producer.model.?, audit.provider.?, audit.model.?))
            try issues.append(a, .{ .role = "auditor", .provider = audit.provider.?, .model = audit.model.?, .cause = "audit_manufacturer_conflict", .reason = "El auditor tiene el mismo fabricante que el productor o no se puede confirmar su independencia", .action = "Elige un auditor de otro fabricante" });
        if (audit.provider == null) {
            const availability = try independentAuditors(a, catalog, mode, if (producer.provider != null) producer else roles[0], external);
            if (availability.without_preferences and !availability.with_preferences)
                try issues.append(a, .{ .role = "auditor", .provider = producer.provider orelse "", .model = producer.model orelse "", .cause = "audit_unavailable_by_preferences", .reason = "Los vetos dejan sin auditor independiente al modo auditado", .action = "Permite al router un modelo de otro proveedor y fabricante, o fija un auditor independiente a mano", .severity = .warn })
            else if (availability.producer_known and !availability.without_preferences)
                // QA primerizo (11-nov): sin claves y solo con Ollama, Orquestado
                // auditaba sin auditor («Proveedor no declarado») y nada lo decía
                // antes de enviar. Se avisa; no bloquea.
                try issues.append(a, .{ .role = "auditor", .provider = producer.provider orelse "", .model = producer.model orelse "", .cause = "audit_unavailable", .reason = "No hay ningún modelo de otro fabricante para auditar: el trabajo se entregará sin auditoría independiente", .action = "Añade una clave de otro proveedor o detecta un agente (Codex, Claude Code, Gemini) en Configuración", .severity = .warn });
        }
    }
    return issues.toOwnedSlice(a);
}

const AuditorAvailability = struct { without_preferences: bool = false, with_preferences: bool = false, producer_known: bool = false };

/// Sin claves, el router no ofrece productores; si hay un modelo local listo,
/// ese es quien producirá (Automático recurre a los locales).
fn firstLocalModel(a: std.mem.Allocator, catalog: db.Connection) !?[2][]u8 {
    const q = catalog.prepare("SELECT p.name, m.model_name FROM models m JOIN providers p ON p.id = m.provider_id WHERE p.is_local = 1 AND p.enabled = 1 AND m.available = 1 ORDER BY m.id LIMIT 1") catch return null;
    defer catalog.finalize(q);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_ROW) return null;
    const pc = db.c.sqlite3_column_text(q, 0) orelse return null;
    const mc = db.c.sqlite3_column_text(q, 1) orelse return null;
    const prov = try a.dupe(u8, std.mem.span(pc));
    errdefer a.free(prov);
    return .{ prov, try a.dupe(u8, std.mem.span(mc)) };
}

fn independentAuditors(a: std.mem.Allocator, catalog: db.Connection, mode: router.GovernanceMode, producer: Role, external: []const u8) !AuditorAvailability {
    var availability: AuditorAvailability = .{};
    var r = router.Router.init(a, catalog, null, @import("health.zig").nowSeconds(catalog));
    defer r.deinitHealthCache();
    var producers = try r.rankCandidates(.{ .task_type = .programar, .required_context = 0, .governance_mode = mode });
    defer {
        for (producers.items) |candidate| candidate.deinit(a);
        producers.deinit(a);
    }
    const local = if (producer.provider == null and producers.items.len == 0) try firstLocalModel(a, catalog) else null;
    defer if (local) |l| {
        a.free(l[0]);
        a.free(l[1]);
    };
    const p = producer.provider orelse if (producers.items.len != 0) producers.items[0].provider_name else if (local) |l| l[0] else return availability;
    const m = producer.model orelse if (producers.items.len != 0) producers.items[0].model_name else if (local) |l| l[1] else return availability;
    availability.producer_known = true;
    // Hold the producer fixed. The second set is exactly the eligible baseline
    // intersected with allow_automatic; no catalog settings are mutated.
    var auditors = try r.rankCandidatesBeforePreferences(.{ .task_type = .auditar, .required_context = 0, .governance_mode = mode });
    defer {
        for (auditors.items) |candidate| candidate.deinit(a);
        auditors.deinit(a);
    }
    for (auditors.items) |candidate| {
        if (std.mem.eql(u8, p, candidate.provider_name) or agents.crossModelManufacturerExcluded(p, m, candidate.provider_name, candidate.model_name)) continue;
        availability.without_preferences = true;
        const preferences = try @import("model_selection.zig").get(catalog, candidate.provider_name, candidate.model_name);
        if (preferences.allow_automatic) {
            availability.with_preferences = true;
            return availability;
        }
    }
    // Only Codex currently implements the CLI verdict protocol.
    if (mode == .local_only) return availability;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, external, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidCatalog;
    for (parsed.value.array.items) |agent| {
        if (agent != .object) continue;
        const provider = agent.object.get("provider") orelse continue;
        if (provider != .string or !std.mem.eql(u8, provider.string, "agent:codex") or std.mem.eql(u8, p, provider.string)) continue;
        const models = agent.object.get("models") orelse continue;
        if (models != .array) continue;
        for (models.array.items) |model| {
            if (model != .object) continue;
            const slug = model.object.get("slug") orelse continue;
            if (slug != .string or agents.crossModelManufacturerExcluded(p, m, provider.string, slug.string)) continue;
            const eligibility = try @import("model_selection.zig").externalEligibility(a, external, provider.string, slug.string);
            if (!eligibility.chat or (mode == .free_tier_first and !eligibility.free)) continue;
            const pin = registry.resolvePin(a, catalog, external, provider.string, slug.string) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => continue,
            };
            pin.deinit(a);
            availability.without_preferences = true;
            const preferences = try @import("model_selection.zig").get(catalog, provider.string, slug.string);
            if (preferences.allow_automatic) {
                availability.with_preferences = true;
                return availability;
            }
        }
    }
    return availability;
}

test "ORDENES preflight missing key paid down unknown and manufacturer conflict" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    try c.exec("INSERT INTO providers(id,name,base_url,api_style,enabled,is_local) VALUES(1,'Cohere','http://127.0.0.1','cohere',1,0)");
    try c.exec("INSERT INTO models(provider_id,model_name,is_free,available) VALUES(1,'paid',0,1),(1,'down',1,0)");
    const roles = [_]Role{ .{ .role = "planificador", .provider = "Cohere", .model = "paid" }, .{ .role = "ejecutor", .provider = "Cohere", .model = "down" }, .{ .role = "auditor", .provider = "Cohere", .model = "unknown" } };
    const first = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(first);
    try std.testing.expectEqual(@as(usize, 4), first.len);
    try std.testing.expectEqualStrings("missing_key", first[0].cause);
    try std.testing.expectEqualStrings("model_unavailable", first[1].cause);
    try std.testing.expectEqualStrings("audit_manufacturer_conflict", first[3].cause);
    try c.exec("INSERT INTO api_keys(provider_id,label,key_ciphertext,status) VALUES(1,'synthetic',X'00','active')");
    const paid = try check(a, c, .free_tier_first, roles[0..1], "[]", null);
    defer a.free(paid);
    try std.testing.expectEqual(@as(usize, 1), paid.len);
    try std.testing.expectEqualStrings("governance_blocked", paid[0].cause);
    try @import("spend_budget.zig").autorizar(c, 1);
    const permitted = try check(a, c, .hybrid, roles[0..1], "[]", null);
    defer a.free(permitted);
    try std.testing.expectEqual(@as(usize, 0), permitted.len);
    try c.exec("UPDATE providers SET enabled=0");
    const down = try check(a, c, .hybrid, roles[0..1], "[]", null);
    defer a.free(down);
    try std.testing.expectEqualStrings("provider_unavailable", down[0].cause);
    try c.exec("DROP TABLE models");
    try std.testing.expectError(error.PrepareFailed, check(a, c, .hybrid, roles[0..1], "[]", null));
}

test "ORDENES subscription is free eligible with cross manufacturer auditor" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    const external = "[{\"provider\":\"agent:codex\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/codex.exe\",\"version\":\"0.159.2\",\"models\":[{\"slug\":\"gpt-6.1-sol\"}]}]";
    const roles = [_]Role{.{ .role = "planificador", .provider = "agent:codex", .model = "gpt-6.1-sol" }};
    const eligible = try check(a, c, .free_tier_first, &roles, external, null);
    defer a.free(eligible);
    try std.testing.expectEqual(@as(usize, 0), eligible.len);
    const blocked = try check(a, c, .local_only, &roles, external, null);
    defer a.free(blocked);
    try std.testing.expectEqualStrings("governance_blocked", blocked[0].cause);
    const missing = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(missing);
    try std.testing.expect(missing.len == 1);
}

test "ORDENES preflight surfaces recent failures without permanent lockout" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    var rt = try db.Connection.open(a, ":memory:");
    defer rt.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    try db.Migrator.init(a).migrate(rt, &db.runtime_schema);
    try c.exec("INSERT INTO providers(id,name,base_url,api_style,enabled,is_local) VALUES(1,'Cohere','http://127.0.0.1','cohere',1,0)");
    try c.exec("INSERT INTO models(provider_id,model_name,is_free,available) VALUES(1,'free',1,1)");
    try c.exec("INSERT INTO api_keys(provider_id,label,key_ciphertext,status) VALUES(1,'synthetic',X'00','active')");
    const roles = [_]Role{.{ .role = "planificador", .provider = "Cohere", .model = "free" }};
    try @import("health.zig").record(rt, "Cohere", "free", .timeout, 0);
    const blocked = try check(a, c, .free_tier_first, &roles, "[]", rt);
    defer a.free(blocked);
    try std.testing.expectEqualStrings("provider_recent_failure", blocked[0].cause);
    try rt.exec("UPDATE model_health SET last_err_at=last_err_at-61");
    const old = try check(a, c, .free_tier_first, &roles, "[]", rt);
    defer a.free(old);
    try std.testing.expectEqual(@as(usize, 0), old.len);
    try rt.exec("DROP TABLE model_health");
    try std.testing.expectError(error.PrepareFailed, check(a, c, .free_tier_first, &roles, "[]", rt));
}

test "ORDENES R2 modes x budget x free paid subscription preflight" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    try c.exec("INSERT INTO providers(id,name,base_url,api_style,enabled,is_local) VALUES(1,'Cohere','http://127.0.0.1','cohere',1,0)");
    try c.exec("INSERT INTO models(provider_id,model_name,is_free,available) VALUES(1,'paid',0,1),(1,'free',1,1)");
    try c.exec("INSERT INTO api_keys(provider_id,label,key_ciphertext,status) VALUES(1,'synthetic',X'00','active')");
    const external = "[{\"provider\":\"agent:codex\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/codex.exe\",\"version\":\"0.159.2\",\"models\":[{\"slug\":\"gpt-6.1-sol\"}]}]";
    const budget = @import("spend_budget.zig");
    for ([_]router.GovernanceMode{ .free_tier_first, .hybrid, .paid_tier_first }) |mode| {
        for ([_]u64{ 200, 201 }) |authorized| {
            try budget.autorizar(c, authorized);
            try c.exec("INSERT INTO settings(key,value) VALUES('paid_calls_spent','200') ON CONFLICT(key) DO UPDATE SET value='200'");
            for ([_]Role{
                .{ .role = "planificador", .provider = "Cohere", .model = "free" },
                .{ .role = "planificador", .provider = "Cohere", .model = "paid" },
                .{ .role = "planificador", .provider = "agent:codex", .model = "gpt-6.1-sol" },
            }, 0..) |role, kind| {
                const issues = try check(a, c, mode, &.{role}, external, null);
                defer a.free(issues);
                const governance_block = kind == 1 and mode == .free_tier_first;
                const budget_block = kind == 1 and authorized == 200 and !governance_block;
                try std.testing.expectEqual(@as(usize, if (governance_block or budget_block) 1 else 0), issues.len);
                if (governance_block) try std.testing.expectEqualStrings("governance_blocked", issues[0].cause);
                if (budget_block) try std.testing.expectEqualStrings("paid_budget_exhausted", issues[0].cause);
                try std.testing.expectEqual(@as(u64, 200), budget.estado(c).consumidas);
            }
        }
    }
}

test "CK-PRV-004 C5 veto leaves no independent automatic auditor in preflight" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    try c.exec("CREATE TABLE IF NOT EXISTS model_preferences(provider TEXT NOT NULL,model TEXT NOT NULL,show_in_selectors INTEGER NOT NULL DEFAULT 1,allow_automatic INTEGER NOT NULL DEFAULT 1,PRIMARY KEY(provider,model))");
    try c.exec("INSERT INTO providers(id,name,base_url,api_style,enabled) VALUES(1,'Cohere','http://fixture','cohere',1),(2,'Google AI Studio','http://fixture','google_gemini',1)");
    try c.exec("INSERT INTO api_keys(provider_id,label,key_ciphertext,status) VALUES(1,'synthetic',X'00','active'),(2,'synthetic',X'00','active')");
    try c.exec("INSERT INTO models(provider_id,model_name,is_free,available) VALUES(1,'command-a',1,1),(2,'gemini-flash',1,1)");
    const roles = [_]Role{ .{ .role = "planificador", .provider = null, .model = null }, .{ .role = "ejecutor", .provider = "Cohere", .model = "command-a" }, .{ .role = "auditor", .provider = null, .model = null } };
    try c.exec("INSERT INTO model_preferences VALUES('Google AI Studio','gemini-flash',1,0)");
    const issues = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(issues);
    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("audit_unavailable_by_preferences", issues[0].cause);
    try std.testing.expectEqual(.warn, issues[0].severity);
    try std.testing.expect(allowed(issues));
    try c.exec("UPDATE model_preferences SET allow_automatic=1");
    const restored = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(restored);
    try std.testing.expectEqual(@as(usize, 0), restored.len);
    try std.testing.expect(allowed(restored));
}

test "CK-PRV-004 C3 preflight does not classify paid OpenCode as a free subscription" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    const external = "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/opencode.exe\",\"version\":\"1\",\"models\":[{\"slug\":\"opencode/claude-opus-5\",\"zero_cost\":false}]}]";
    const roles = [_]Role{.{ .role = "ejecutor", .provider = "agent:opencode", .model = "opencode/claude-opus-5" }};
    const issues = try check(a, c, .free_tier_first, &roles, external, null);
    defer a.free(issues);
    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("governance_blocked", issues[0].cause);
}

test "CK-PRV-004 r2-2 irrelevant veto must not blame preferences for missing key governance or independence" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    try c.exec("INSERT INTO providers(id,name,base_url,api_style,enabled) VALUES(1,'Cohere','http://fixture','cohere',1),(2,'Google AI Studio','http://fixture','google_gemini',1)");
    try c.exec("INSERT INTO api_keys(provider_id,label,key_ciphertext,status) VALUES(1,'synthetic',X'00','active')");
    try c.exec("INSERT INTO models(provider_id,model_name,is_free,available) VALUES(1,'command-a',1,1),(1,'command-r',1,1),(2,'gemini-flash',1,1)");
    const roles = [_]Role{ .{ .role = "planificador", .provider = null, .model = null }, .{ .role = "ejecutor", .provider = "Cohere", .model = "command-a" }, .{ .role = "auditor", .provider = null, .model = null } };
    try c.exec("INSERT INTO model_preferences VALUES('Cohere','command-r',1,0)");
    const missing_key = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(missing_key);
    try expectOnlyHonestAuditWarning(missing_key);
    try c.exec("INSERT INTO api_keys(provider_id,label,key_ciphertext,status) VALUES(2,'synthetic',X'00','active')");
    try c.exec("UPDATE models SET is_free=0 WHERE provider_id=2");
    const paid = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(paid);
    try expectOnlyHonestAuditWarning(paid);
    try c.exec("UPDATE models SET available=0 WHERE provider_id=2");
    const same_maker = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(same_maker);
    try expectOnlyHonestAuditWarning(same_maker);
    // Explicitly selected auditors still report their original blocking cause.
    const explicit = [_]Role{.{ .role = "auditor", .provider = "Google AI Studio", .model = "gemini-flash" }};
    const unavailable = try check(a, c, .free_tier_first, &explicit, "[]", null);
    defer a.free(unavailable);
    try std.testing.expectEqualStrings("model_unavailable", unavailable[0].cause);
}

/// Sin auditor independiente posible, el único aviso permitido es el honesto
/// («no hay modelo de otro fabricante»), nunca culpar a las preferencias.
fn expectOnlyHonestAuditWarning(issues: []const Issue) !void {
    for (issues) |i| {
        try std.testing.expectEqualStrings("audit_unavailable", i.cause);
        try std.testing.expectEqual(.warn, i.severity);
    }
    try std.testing.expect(allowed(issues));
}

test "QA primerizo: sin claves y solo Ollama, Orquestado avisa que no habrá auditor independiente" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    try c.exec("INSERT INTO providers(id,name,base_url,api_style,enabled,is_local) VALUES(1,'Ollama','http://127.0.0.1:11434','openai',1,1)");
    try c.exec("INSERT INTO models(provider_id,model_name,is_free,available) VALUES(1,'qwen2.5:7b',1,1)");
    const roles = [_]Role{ .{ .role = "planificador", .provider = null, .model = null }, .{ .role = "ejecutor", .provider = null, .model = null }, .{ .role = "auditor", .provider = null, .model = null } };
    const issues = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(issues);
    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("audit_unavailable", issues[0].cause);
    try std.testing.expect(allowed(issues));
    // Sin ningún modelo no hay a quién auditar: ese caso lo cubre el aviso de «sin modelos».
    try c.exec("DELETE FROM models");
    const empty = try check(a, c, .free_tier_first, &roles, "[]", null);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
