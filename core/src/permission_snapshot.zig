const std = @import("std");
const executor = @import("executor.zig");

/// ROLES-MODELO: resuelve el pin efectivo de un rol. El pin específico del rol
/// solo cuenta si trae provider Y model; si falta alguno, cae al pin general
/// de la orden (plan). El ejecutor NUNCA es respaldo del auditor: eso lo
/// decide el llamador pasando `plan` (no `exec`) como fallback.
fn resolvePin(role_p: ?[]const u8, role_m: ?[]const u8, plan_p: ?[]const u8, plan_m: ?[]const u8) struct { p: ?[]const u8, m: ?[]const u8 } {
    if (role_p != null and role_p.?.len > 0 and role_m != null and role_m.?.len > 0)
        return .{ .p = role_p, .m = role_m };
    return .{ .p = plan_p, .m = plan_m };
}

fn dupeOptZ(allocator: std.mem.Allocator, s: ?[]const u8) !?[:0]const u8 {
    return if (s) |v| try allocator.dupeZ(u8, v) else null;
}

fn dupeList(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (items) |s| {
        out[n] = try allocator.dupe(u8, s);
        n += 1;
    }
    return out;
}

fn freeList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |s| allocator.free(s);
    allocator.free(items);
}

pub const OwnedModelSelection = struct {
    provider: ?[:0]const u8 = null,
    model: ?[:0]const u8 = null,
    forced_provider: ?[:0]const u8 = null,
    forced_model: ?[:0]const u8 = null,
    /// ROLES-MODELO: pin efectivo del ejecutor (exec ?? plan, resuelto en initClone).
    exec_provider: ?[:0]const u8 = null,
    exec_model: ?[:0]const u8 = null,
    /// ROLES-MODELO: pin efectivo del auditor (audit ?? automático, resuelto en initClone).
    audit_provider: ?[:0]const u8 = null,
    audit_model: ?[:0]const u8 = null,
    /// ENJAMBRE: JSON `[{provider,model}]` del conjunto elegido por el usuario.
    /// Capturado por orden para que un cambio posterior del usuario no mute
    /// una orden en vuelo.
    swarm_json: ?[:0]const u8 = null,

    pub fn initClone(allocator: std.mem.Allocator, provider: ?[:0]const u8, model: ?[:0]const u8) !OwnedModelSelection {
        return initCloneRoles(allocator, provider, model, null, null, null, null, null);
    }

    /// Clona los tres pines de rol y los resuelve: exec cae al pin de plan; audit sin pin se enruta
    /// con exclusión del fabricante productor.
    pub fn initCloneRoles(
        allocator: std.mem.Allocator,
        plan_p: ?[]const u8,
        plan_m: ?[]const u8,
        exec_p: ?[]const u8,
        exec_m: ?[]const u8,
        audit_p: ?[]const u8,
        audit_m: ?[]const u8,
        swarm_json: ?[]const u8,
    ) !OwnedModelSelection {
        const p = try dupeOptZ(allocator, plan_p);
        errdefer if (p) |v| allocator.free(v);
        const m = try dupeOptZ(allocator, plan_m);
        errdefer if (m) |v| allocator.free(v);
        const eff_exec = resolvePin(exec_p, exec_m, p, m);
        const ep = try dupeOptZ(allocator, eff_exec.p);
        errdefer if (ep) |v| allocator.free(v);
        const em = try dupeOptZ(allocator, eff_exec.m);
        errdefer if (em) |v| allocator.free(v);
        const eff_audit = resolvePin(audit_p, audit_m, null, null);
        const ap = try dupeOptZ(allocator, eff_audit.p);
        errdefer if (ap) |v| allocator.free(v);
        const am = try dupeOptZ(allocator, eff_audit.m);
        errdefer if (am) |v| allocator.free(v);
        const sj = try dupeOptZ(allocator, swarm_json);
        errdefer if (sj) |v| allocator.free(v);
        return .{
            .provider = p,
            .model = m,
            .forced_provider = p,
            .forced_model = m,
            .exec_provider = ep,
            .exec_model = em,
            .audit_provider = ap,
            .audit_model = am,
            .swarm_json = sj,
        };
    }

    pub fn deinit(self: *OwnedModelSelection, allocator: std.mem.Allocator) void {
        if (self.provider) |p| allocator.free(p);
        if (self.model) |m| allocator.free(m);
        if (self.exec_provider) |p| allocator.free(p);
        if (self.exec_model) |m| allocator.free(m);
        if (self.audit_provider) |p| allocator.free(p);
        if (self.audit_model) |m| allocator.free(m);
        if (self.swarm_json) |s| allocator.free(s);
        self.* = undefined;
    }
};

pub const OwnedPermissionSnapshot = struct {
    /// Pin del coordinador/planificador (también pin heredado por el ejecutor).
    forced_provider: ?[:0]const u8 = null,
    forced_model: ?[:0]const u8 = null,
    /// ROLES-MODELO: pin efectivo del ejecutor (exec ?? plan).
    exec_forced_provider: ?[:0]const u8 = null,
    exec_forced_model: ?[:0]const u8 = null,
    /// ROLES-MODELO: pin efectivo del auditor (audit ?? automático). Jamás cae al pin
    /// del ejecutor: un auditor con el modelo constructor no es independiente.
    audit_forced_provider: ?[:0]const u8 = null,
    audit_forced_model: ?[:0]const u8 = null,
    /// ENJAMBRE: JSON `[{provider,model}]` capturado con la aprobación —
    /// el despacho usa el conjunto que el usuario tenía al aprobar la orden.
    swarm_json: ?[:0]const u8 = null,
    /// T2d-D1 (12-nov): política de permisos viva al lanzar la orden. Hasta
    /// ahora se descartaba (resto del porte F0-T2) y `permissionConfig()`
    /// devolvía siempre `.normal` sin listas: Directo y el despacho
    /// orquestado ignoraban el modo elegido en la cabina.
    mode: executor.PermissionMode = .normal,
    allow_prefixes: []const []const u8 = &.{},
    deny_prefixes: []const []const u8 = &.{},
    session_allow: []const []const u8 = &.{},

    pub fn initClone(
        allocator: std.mem.Allocator,
        mode: executor.PermissionMode,
        allow: []const []const u8,
        deny: []const []const u8,
        session_allow: []const []const u8,
        provider: ?[:0]const u8,
        model: ?[:0]const u8,
    ) !OwnedPermissionSnapshot {
        return initCloneRoles(allocator, mode, allow, deny, session_allow, provider, model, null, null, null, null, null);
    }

    /// Misma captura que initClone pero con los pines de ejecutor y auditor
    /// ya resueltos (exec ?? plan, audit ?? automático independiente).
    pub fn initCloneRoles(
        allocator: std.mem.Allocator,
        mode: executor.PermissionMode,
        allow: []const []const u8,
        deny: []const []const u8,
        session_allow: []const []const u8,
        provider: ?[]const u8,
        model: ?[]const u8,
        exec_p: ?[]const u8,
        exec_m: ?[]const u8,
        audit_p: ?[]const u8,
        audit_m: ?[]const u8,
        swarm_json: ?[]const u8,
    ) !OwnedPermissionSnapshot {
        const al = try dupeList(allocator, allow);
        errdefer freeList(allocator, al);
        const dl = try dupeList(allocator, deny);
        errdefer freeList(allocator, dl);
        const sl = try dupeList(allocator, session_allow);
        errdefer freeList(allocator, sl);
        const p = try dupeOptZ(allocator, provider);
        errdefer if (p) |v| allocator.free(v);
        const m = try dupeOptZ(allocator, model);
        errdefer if (m) |v| allocator.free(v);
        const eff_exec = resolvePin(exec_p, exec_m, p, m);
        const ep = try dupeOptZ(allocator, eff_exec.p);
        errdefer if (ep) |v| allocator.free(v);
        const em = try dupeOptZ(allocator, eff_exec.m);
        errdefer if (em) |v| allocator.free(v);
        const eff_audit = resolvePin(audit_p, audit_m, null, null);
        const ap = try dupeOptZ(allocator, eff_audit.p);
        errdefer if (ap) |v| allocator.free(v);
        const am = try dupeOptZ(allocator, eff_audit.m);
        errdefer if (am) |v| allocator.free(v);
        const sj = try dupeOptZ(allocator, swarm_json);
        errdefer if (sj) |v| allocator.free(v);
        return .{
            .forced_provider = p,
            .forced_model = m,
            .exec_forced_provider = ep,
            .exec_forced_model = em,
            .audit_forced_provider = ap,
            .audit_forced_model = am,
            .swarm_json = sj,
            .mode = mode,
            .allow_prefixes = al,
            .deny_prefixes = dl,
            .session_allow = sl,
        };
    }

    /// La configuración apunta a memoria del snapshot: vive mientras él viva.
    pub fn permissionConfig(self: OwnedPermissionSnapshot) executor.PermissionConfig {
        return .{
            .mode = self.mode,
            .allow_prefixes = self.allow_prefixes,
            .deny_prefixes = self.deny_prefixes,
            .session_allow = self.session_allow,
        };
    }

    /// sustituye SOLO los pines de modelo por los de una selección
    /// persistida (resume tras reinicio: los globales ya no reflejan con qué
    /// se lanzó la orden). Los permisos quedan intactos — son política viva,
    /// no dato de la orden. Los campos de `sel` vienen ya resueltos
    /// (exec ?? plan) — se reemplazan tal cual.
    pub fn applyModelSelection(self: *OwnedPermissionSnapshot, allocator: std.mem.Allocator, sel: *const OwnedModelSelection) !void {
        const p = try dupeOptZ(allocator, sel.forced_provider);
        errdefer if (p) |v| allocator.free(v);
        const m = try dupeOptZ(allocator, sel.forced_model);
        errdefer if (m) |v| allocator.free(v);
        const ep = try dupeOptZ(allocator, sel.exec_provider);
        errdefer if (ep) |v| allocator.free(v);
        const em = try dupeOptZ(allocator, sel.exec_model);
        errdefer if (em) |v| allocator.free(v);
        const ap = try dupeOptZ(allocator, sel.audit_provider);
        errdefer if (ap) |v| allocator.free(v);
        const am = try dupeOptZ(allocator, sel.audit_model);
        errdefer if (am) |v| allocator.free(v);
        const sj = try dupeOptZ(allocator, sel.swarm_json);
        errdefer if (sj) |v| allocator.free(v);
        if (self.forced_provider) |v| allocator.free(v);
        if (self.forced_model) |v| allocator.free(v);
        if (self.exec_forced_provider) |v| allocator.free(v);
        if (self.exec_forced_model) |v| allocator.free(v);
        if (self.audit_forced_provider) |v| allocator.free(v);
        if (self.audit_forced_model) |v| allocator.free(v);
        if (self.swarm_json) |v| allocator.free(v);
        self.forced_provider = p;
        self.forced_model = m;
        self.exec_forced_provider = ep;
        self.exec_forced_model = em;
        self.audit_forced_provider = ap;
        self.audit_forced_model = am;
        self.swarm_json = sj;
    }

    pub fn deinit(self: *OwnedPermissionSnapshot, allocator: std.mem.Allocator) void {
        if (self.forced_provider) |p| allocator.free(p);
        if (self.forced_model) |m| allocator.free(m);
        if (self.exec_forced_provider) |p| allocator.free(p);
        if (self.exec_forced_model) |m| allocator.free(m);
        if (self.audit_forced_provider) |p| allocator.free(p);
        if (self.audit_forced_model) |m| allocator.free(m);
        if (self.swarm_json) |s| allocator.free(s);
        freeList(allocator, self.allow_prefixes);
        freeList(allocator, self.deny_prefixes);
        freeList(allocator, self.session_allow);
        self.* = undefined;
    }
};

test "T2d-D1: el snapshot de permisos conserva modo y listas" {
    const a = std.testing.allocator;
    var snap = try OwnedPermissionSnapshot.initClone(a, .autonomous, &.{"git status"}, &.{"rm"}, &.{"zig build"}, null, null);
    defer snap.deinit(a);
    const cfg = snap.permissionConfig();
    try std.testing.expectEqual(executor.PermissionMode.autonomous, cfg.mode);
    try std.testing.expectEqualStrings("git status", cfg.allow_prefixes[0]);
    try std.testing.expectEqualStrings("rm", cfg.deny_prefixes[0]);
    try std.testing.expectEqualStrings("zig build", cfg.session_allow[0]);
}

test "ORDENES model snapshot keeps automatic audit independent of plan pin" {
    const a = std.testing.allocator;
    var selection = try OwnedModelSelection.initCloneRoles(a, "agent:codex", "gpt-6.1-sol", null, null, null, null, null);
    defer selection.deinit(a);
    try std.testing.expectEqualStrings("agent:codex", selection.exec_provider.?);
    try std.testing.expect(selection.audit_provider == null);
    try std.testing.expect(selection.audit_model == null);
}
