//! core/src/tui/session.zig — (E1): bucle interactivo de la sesión.
//!
//! Une las piezas puras (state, render, keys) con la consola (console) y con
//! el producto real (host) a través de PUERTOS inyectables: el bucle no llama
//! a nada del sistema directamente, así se prueba entero con una pantalla y un
//! backend falsos.
//!
//! Entrada real: `devagents` sin argumentos SOLO cuando stdin y stdout son
//! consola; en cualquier otro caso la CLI conserva el `--help` exacto de
//! siempre (criterio 1 de).

const std = @import("std");
const state = @import("state.zig");
const render = @import("render.zig");
const keys = @import("keys.zig");
const console = @import("console.zig");
const host = @import("host.zig");
const interaction = @import("interaction.zig");
const progress = @import("progress.zig");

pub const HelpFn = *const fn () anyerror!void;

/// Puertos de la sesión: el bucle habla solo con estos punteros.
pub const Ports = struct {
    ctx: ?*anyopaque = null,
    config: *const fn (?*anyopaque, std.mem.Allocator) anyerror!state.Config,
    get_governance: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]u8,
    set_governance: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!void,
    list_models: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]u8,
    run_order: *const fn (?*anyopaque, std.mem.Allocator, []const u8, host.OrderSink) anyerror!u32,
    /// E3: contenido de un archivo del proyecto para instantáneas y diffs.
    /// Sin este puerto los bloques solo listan las rutas (criterio 3).
    read_file: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]u8 = null,
};

/// Entrada de `devagents` sin argumentos: sesión interactiva si hay consola
/// real; si no (tubería, archivo, CI), el `--help` de siempre sin cambios.
pub fn runNoArgs(allocator: std.mem.Allocator, probe: console.Probe, help_fn: HelpFn) !void {
    if (!console.interactiveAllowed(probe)) return help_fn();
    var terminal = console.Terminal.enter();
    if (!terminal.active) {
        terminal.leave();
        return help_fn();
    }
    defer terminal.leave();
    var h = host.Host.init(allocator) catch return help_fn();
    defer h.deinit();
    const ports = Ports{
        .ctx = &h,
        .config = host.portConfig,
        .get_governance = host.portGetGovernance,
        .set_governance = host.portSetGovernance,
        .list_models = host.portListModels,
        .run_order = host.portRunOrder,
        .read_file = host.portReadFile,
    };
    return runOn(allocator, console.screenOf(&terminal), ports);
}

/// Bucle de la sesión sobre una pantalla cualquiera (real o falsa en pruebas).
pub fn runOn(allocator: std.mem.Allocator, screen: console.Screen, ports: Ports) !void {
    defer screen.close();

    const cfg = ports.config(ports.ctx, allocator) catch state.Config{
        .project_root = ".",
        .project_name = "DevAgents",
        .branch = "sin git",
        .model = "auto (router)",
        .governance = "Híbrido",
    };
    var st = try state.State.init(allocator, cfg);
    defer st.deinit();

    // La gobernanza real manda: refresca la etiqueta al arrancar.
    if (ports.get_governance(ports.ctx, allocator)) |code| {
        defer allocator.free(code);
        st.setGovernanceLabel(code) catch {};
    } else |_| {}

    while (true) {
        try drawNow(allocator, screen, &st);
        const raw = screen.readKey(true) orelse continue;
        var outcome = st.apply(keys.decode(raw)) catch |e| blk: {
            st.appendLine(.err, @errorName(e)) catch {};
            break :blk state.Outcome{};
        };
        defer outcome.deinit(allocator);
        switch (outcome.kind) {
            .none => {},
            .exit => return,
            .order => try runOrderFlow(allocator, screen, &st, ports, outcome.text),
            .governance_set => try governFlow(allocator, &st, ports, outcome.text),
            .models_show => try modelsFlow(allocator, &st, ports),
        }
    }
}

fn drawNow(allocator: std.mem.Allocator, screen: console.Screen, st: *state.State) !void {
    const sz = screen.sizeOf();
    var res = try render.frame(allocator, st, sz.w, sz.h, !st.no_color);
    defer res.frame.deinit(allocator);
    screen.drawAll(allocator, res.frame.buf, res.cursor.row, res.cursor.col);
}

fn governFlow(
    allocator: std.mem.Allocator,
    st: *state.State,
    ports: Ports,
    code: []const u8,
) !void {
    if (!state.govAliasKnown(code)) {
        const msg = try std.fmt.allocPrint(allocator, "«{s}» no es un modo conocido. Usa free, hybrid, paid o local.", .{code});
        defer allocator.free(msg);
        try st.appendLine(.err, msg);
        return;
    }
    ports.set_governance(ports.ctx, allocator, code) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "No se pudo guardar la gobernanza ({s}).", .{@errorName(e)});
        defer allocator.free(msg);
        try st.appendLine(.err, msg);
        return;
    };
    const canon = state.govCanonical(code);
    try st.setGovernanceLabel(canon);
    const msg = try std.fmt.allocPrint(allocator, "Gobernanza: {s} ({s})", .{ state.govLabel(canon), canon });
    defer allocator.free(msg);
    try st.appendLine(.ok, msg);
}

fn modelsFlow(allocator: std.mem.Allocator, st: *state.State, ports: Ports) !void {
    const text = ports.list_models(ports.ctx, allocator) catch {
        try st.appendLine(.err, "No se pudo leer el catálogo de modelos.");
        return;
    };
    defer allocator.free(text);
    try st.openPanelText(.models, "Modelos", text);
    const msg = try std.fmt.allocPrint(allocator, "Modelo activo: {s}. El catálogo está en el panel.", .{st.model});
    defer allocator.free(msg);
    try st.appendLine(.notice, msg);
}

/// Estado compartido entre el bucle y la orden en curso (salida y cancelación).
const PumpCtx = struct {
    allocator: std.mem.Allocator,
    screen: console.Screen,
    st: *state.State,
    cancel: bool = false,
    failure: ?anyerror = null,
    declined: bool = false,
    editing: bool = false,
    order_text: []const u8 = "",
    reply: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(u8) = .empty,
    ports_ctx: ?*anyopaque = null,
    read_file: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]u8 = null,
};

fn pumpEmit(ctxp: ?*anyopaque, chunk: []const u8) void {
    const p: *PumpCtx = @ptrCast(@alignCast(ctxp.?));
    p.pending.appendSlice(p.allocator, chunk) catch |e| {
        p.failure = e;
        p.cancel = true;
        return;
    };
    flushPending(p, false);
}

fn pumpTick(ctxp: ?*anyopaque) bool {
    const p: *PumpCtx = @ptrCast(@alignCast(ctxp.?));
    while (p.screen.readKey(false)) |raw| {
        if (keys.decode(raw) == .ctrl_c) p.cancel = true;
    }
    drawNow(p.allocator, p.screen, p.st) catch |e| {
        p.failure = e;
        p.cancel = true;
    };
    return p.cancel;
}

fn pumpRequest(ctxp: ?*anyopaque, request: interaction.Request) []const u8 {
    const p: *PumpCtx = @ptrCast(@alignCast(ctxp.?));
    return requestInput(p, request) catch |e| {
        p.failure = e;
        p.cancel = true;
        p.st.appendLine(.err, @errorName(e)) catch {
            return interaction.CANCEL;
        };
        return interaction.CANCEL;
    };
}

/// E3: aviso de avance del hijo (`task`/`file`). No se dibuja aquí (lo hace el
/// siguiente sondeo del bucle de orden); solo se actualiza el estado.
fn pumpProgress(ctxp: ?*anyopaque, line: []const u8) void {
    const p: *PumpCtx = @ptrCast(@alignCast(ctxp.?));
    if (progress.parseFileReport(line)) |rep| {
        var after: ?[]u8 = null;
        if (p.read_file) |read| after = read(p.ports_ctx, p.allocator, rep.path) catch null;
        defer if (after) |buf| p.allocator.free(buf);
        _ = p.st.progress.applyFileReport(line, after) catch |e| {
            p.failure = e;
            p.cancel = true;
        };
        return;
    }
    _ = p.st.progress.applyTaskReport(line) catch |e| {
        p.failure = e;
        p.cancel = true;
    };
}

fn requestInput(p: *PumpCtx, request: interaction.Request) ![]const u8 {
    flushPending(p, true);
    p.st.transcript_scroll = 0;
    if (p.cancel or p.declined or p.editing) return interaction.CANCEL;
    p.st.closePanel();
    defer p.st.closePanel();
    switch (request) {
        // E3 (criterio 4): permiso pendiente del hijo. Todavía no hay canal
        // vivo durante el despacho; la UI y el protocolo quedan listos y
        // probados para cuando el hijo pueda pedirlo (v. informe E3).
        .perm => |desc| {
            p.st.panel.kind = .permission;
            p.st.panel.title = desc;
            p.st.permission_sel = 0;
            while (true) {
                try drawNow(p.allocator, p.screen, p.st);
                const raw = p.screen.readKey(true) orelse continue;
                const key = keys.decode(raw);
                if (key == .page_up or key == .page_down) continue;
                if (key == .ctrl_c) {
                    p.cancel = true;
                    return interaction.CANCEL;
                }
                if (key == .escape) return interaction.CANCEL;
                var choice: ?usize = null;
                switch (key) {
                    .up, .left => p.st.permission_sel = (p.st.permission_sel + 2) % 3,
                    .down, .right, .tab => p.st.permission_sel = (p.st.permission_sel + 1) % 3,
                    .enter => choice = p.st.permission_sel,
                    .char => |cp| if (cp >= '1' and cp <= '3') {
                        choice = cp - '1';
                    },
                    else => {},
                }
                if (choice) |selected| return switch (selected) {
                    0 => "1",
                    1 => "2",
                    else => interaction.CANCEL,
                };
            }
        },
        else => {},
    }
    if (request == .approve) {
        // El mismo plan ya está en la transcripción, incluso en modo automático.
        if (p.st.auto_approve) {
            try drawNow(p.allocator, p.screen, p.st);
            return "1";
        }
        p.st.panel.kind = .approval;
        p.st.panel.title = "APROBACIÓN DEL PLAN";
        p.st.approval_sel = 0;
    } else {
        p.st.panel.kind = .clarification;
        p.st.panel.title = "ACLARACIÓN · escribe tu respuesta y pulsa enter; esc cancela";
        p.st.clearInput();
    }
    while (true) {
        try drawNow(p.allocator, p.screen, p.st);
        const raw = p.screen.readKey(true) orelse continue;
        const key = keys.decode(raw);
        if (key == .page_up or key == .page_down) {
            _ = try p.st.apply(key);
            continue;
        }
        if (key == .ctrl_c or key == .escape) {
            p.cancel = key == .ctrl_c;
            p.declined = true;
            p.st.clearInput();
            return interaction.CANCEL;
        }
        if (key == .shift_tab) {
            try p.st.toggleApproval();
            // Cambiar el modo no confirma la orden que ya espera una elección.
            continue;
        }
        if (request == .approve) {
            var choice: ?usize = null;
            switch (key) {
                .up, .left => p.st.approval_sel = (p.st.approval_sel + 2) % 3,
                .down, .right, .tab => p.st.approval_sel = (p.st.approval_sel + 1) % 3,
                .enter => choice = p.st.approval_sel,
                .char => |cp| if (cp >= '1' and cp <= '3') {
                    choice = cp - '1';
                },
                else => {},
            }
            if (choice) |selected| switch (selected) {
                0 => return "1",
                1 => {
                    p.editing = true;
                    p.st.clearInput();
                    try p.st.insertSlice(p.order_text);
                    return "2";
                },
                else => {
                    p.declined = true;
                    return interaction.CANCEL;
                },
            };
        } else switch (key) {
            .char => |cp| if (p.st.inputText().len < 16000) {
                try p.st.insertCodepoint(cp);
            },
            .backspace => p.st.backspace(),
            .delete => p.st.deleteForward(),
            .left => p.st.moveLeft(),
            .right => p.st.moveRight(),
            .home => p.st.moveHome(),
            .end => p.st.moveEnd(),
            .enter => {
                if (std.mem.trim(u8, p.st.inputText(), " \t").len == 0) continue;
                p.reply.clearRetainingCapacity();
                try p.reply.appendSlice(p.allocator, "answer ");
                try p.reply.appendSlice(p.allocator, p.st.inputText());
                try p.st.appendLine(.command, p.st.inputText());
                p.st.clearInput();
                return p.reply.items;
            },
            else => {},
        }
    }
}

/// E3: una línea de la salida del plan puede ser una tarea (`[id] …`) o un
/// archivo declarado (`Archivo: …`). Además de dársela al estado de progreso,
/// la instantánea previa se toma AQUÍ, antes de que el hijo escriba nada.
fn notePlanLine(p: *PumpCtx, line: []const u8) void {
    if (progress.parsePlanFilePath(line)) |path| {
        if (p.read_file) |read| {
            const content = read(p.ports_ctx, p.allocator, path) catch null;
            p.st.progress.setSnapshot(path, content) catch |e| {
                if (content) |buf| p.allocator.free(buf);
                p.failure = e;
                p.cancel = true;
            };
        }
    }
    _ = p.st.progress.feedPlanLine(line) catch |e| {
        p.failure = e;
        p.cancel = true;
    };
}

fn flushPending(p: *PumpCtx, final: bool) void {
    while (std.mem.indexOfScalar(u8, p.pending.items, '\n')) |idx| {
        const line = std.mem.trimEnd(u8, p.pending.items[0..idx], "\r");
        p.st.appendLine(.output, line) catch |e| {
            p.failure = e;
            p.cancel = true;
            return;
        };
        notePlanLine(p, line);
        std.mem.copyForwards(u8, p.pending.items, p.pending.items[idx + 1 ..]);
        p.pending.shrinkRetainingCapacity(p.pending.items.len - (idx + 1));
    }
    if (final and p.pending.items.len > 0) {
        p.st.appendLine(.output, p.pending.items) catch |e| {
            p.failure = e;
            p.cancel = true;
            return;
        };
        notePlanLine(p, p.pending.items);
        p.pending.clearRetainingCapacity();
    }
}

fn runOrderFlow(
    allocator: std.mem.Allocator,
    screen: console.Screen,
    st: *state.State,
    ports: Ports,
    text: []const u8,
) !void {
    st.setBusy(true);
    defer st.setBusy(false);
    st.order_active = true;
    st.order_text.clearRetainingCapacity();
    try st.order_text.appendSlice(allocator, text);
    st.transcript_scroll = 0;
    try st.appendLine(.notice, "Preparando la orden (devagents order). El plan se mostrará antes de ejecutar. Ctrl+C cancela.");
    try drawNow(allocator, screen, st);

    var pctx = PumpCtx{
        .allocator = allocator,
        .screen = screen,
        .st = st,
        .order_text = text,
        .ports_ctx = ports.ctx,
        .read_file = ports.read_file,
    };
    defer pctx.pending.deinit(allocator);
    defer pctx.reply.deinit(allocator);
    const sink = host.OrderSink{ .ctx = &pctx, .emit = pumpEmit, .pump = pumpTick, .request = pumpRequest, .progress = pumpProgress };
    const code = ports.run_order(ports.ctx, allocator, text, sink) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "No se pudo ejecutar la orden: {s}", .{@errorName(e)});
        defer allocator.free(msg);
        try st.appendLine(.err, msg);
        return;
    };
    flushPending(&pctx, true);
    if (pctx.failure) |failure| return failure;

    if (pctx.editing) {
        try st.appendLine(.notice, "Edita la orden y pulsa enter para obtener un plan nuevo y aprobarlo.");
    } else if (pctx.declined) {
        try st.appendLine(.notice, "Orden descartada. No se ejecutaron tareas.");
    } else if (pctx.cancel) {
        try st.appendLine(.notice, "Orden cancelada con Ctrl+C.");
    } else if (code == 0) {
        try st.appendLine(.ok, "Orden completada (código 0).");
    } else {
        const msg = try std.fmt.allocPrint(allocator, "La orden terminó con código {d}.", .{code});
        defer allocator.free(msg);
        try st.appendLine(.err, msg);
    }
}

const testing = std.testing;

// ── Dobles de prueba: pantalla falsa con guion de teclas y backend falso ──

const FakeScreen = struct {
    script: []const keys.RawKey,
    pos: usize = 0,
    frames: usize = 0,
    last_frame: std.ArrayList(u8) = .empty,
    closed: bool = false,
    saw_approval: bool = false,
    saw_auto: bool = false,
    saw_always: bool = false,
    saw_progress: bool = false,
    saw_folded: bool = false,
    saw_permission: bool = false,
    poll_key: ?keys.RawKey = null,

    fn screen(self: *FakeScreen) console.Screen {
        return .{
            .ctx = self,
            .read_key = readKey,
            .draw = drawFrame,
            .size_fn = sizeFrame,
            .leave = leave,
        };
    }

    fn readKey(ctx: ?*anyopaque, block: bool) ?keys.RawKey {
        const self: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        // Con bloqueo=false (sondeo del bucle de orden) no hay teclas pendientes
        // en el guion: igual que la consola real cuando el usuario no pulsa nada.
        if (!block) {
            defer self.poll_key = null;
            return self.poll_key;
        }
        if (self.pos >= self.script.len) {
            // Agotado el guion: Ctrl+C para que un test colgado termine pronto.
            return .{ .vk = keys.VK_C, .ctrl = true };
        }
        const k = self.script[self.pos];
        self.pos += 1;
        return k;
    }

    fn drawFrame(ctx: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8, _: usize, _: usize) void {
        const self: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        self.frames += 1;
        self.last_frame.clearRetainingCapacity();
        self.last_frame.appendSlice(allocator, text) catch {};
        if (std.mem.indexOf(u8, text, "APROBACIÓN DEL PLAN") != null) self.saw_approval = true;
        if (std.mem.indexOf(u8, text, "Aprobar automáticamente (--yes)") != null) self.saw_auto = true;
        if (std.mem.indexOf(u8, text, "Pedir siempre") != null) self.saw_always = true;
        if (std.mem.indexOf(u8, text, " EJECUCIÓN DE LA ORDEN") != null) self.saw_progress = true;
        if (std.mem.indexOf(u8, text, "\x1b[38;2;154;149;142m▸ ") != null) self.saw_folded = true;
        if (std.mem.indexOf(u8, text, "PERMISO PENDIENTE") != null) self.saw_permission = true;
    }

    fn sizeFrame(_: ?*anyopaque) console.Size {
        return .{ .w = 120, .h = 40 };
    }

    fn leave(ctx: ?*anyopaque) void {
        const self: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        self.closed = true;
    }
};

const FakeBackend = struct {
    order_calls: usize = 0,
    order_text: [64]u8 = undefined,
    order_len: usize = 0,
    gov_calls: usize = 0,
    gov_code: [16]u8 = undefined,
    gov_len: usize = 0,
    models_calls: usize = 0,
    order_exit: u32 = 0,
    order_fails: bool = false,
    dispatches: usize = 0,
    term: ?*FakeScreen = null,
    plan_visible_on_dispatch: bool = false,
    clarify: bool = false,
    answer_text: [128]u8 = undefined,
    answer_len: usize = 0,
    cancel_during_execution: bool = false,
    plan_lines: bool = false,
    progress_events: bool = false,
    perm_request: bool = false,
    perm_reply: [8]u8 = undefined,
    perm_reply_len: usize = 0,
    protected_runs: usize = 0,
    file_reads: usize = 0,

    fn ports(self: *FakeBackend) Ports {
        return .{
            .ctx = self,
            .config = cfg,
            .get_governance = getGov,
            .set_governance = setGov,
            .list_models = listModels,
            .run_order = runOrder,
            .read_file = readFile,
        };
    }

    /// Dos lecturas de `calculadora/index.html`: la instantánea (plan) y el
    /// contenido final (informe de archivo), como el disco real en E3.
    fn readFile(ctx: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.eql(u8, path, "calculadora/index.html")) return null;
        self.file_reads += 1;
        const buf: ?[]u8 = try allocator.dupe(u8, if (self.file_reads == 1) "<h1>Hola</h1>\n" else "<h1>Hola!</h1>\n");
        return buf;
    }

    fn cfg(_: ?*anyopaque, _: std.mem.Allocator) anyerror!state.Config {
        return .{
            .project_root = "C:\\proyectos\\calculadora",
            .project_name = "calculadora",
            .branch = "main",
            .model = "auto (router)",
            .governance = "Solo gratis",
        };
    }

    fn getGov(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "free_tier_first");
    }

    fn setGov(ctx: ?*anyopaque, _: std.mem.Allocator, code: []const u8) anyerror!void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        self.gov_calls += 1;
        const n = @min(code.len, self.gov_code.len);
        std.mem.copyForwards(u8, self.gov_code[0..n], code[0..n]);
        self.gov_len = n;
    }

    fn listModels(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        self.models_calls += 1;
        return allocator.dupe(u8, "Provider | Model | Context | Free\n-------|-------|-------|-----\nopencode | deepseek-v4.1-flash-free | 128k | yes\n");
    }

    fn runOrder(ctx: ?*anyopaque, _: std.mem.Allocator, text: []const u8, sink: host.OrderSink) anyerror!u32 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        self.order_calls += 1;
        const n = @min(text.len, self.order_text.len);
        std.mem.copyForwards(u8, self.order_text[0..n], text[0..n]);
        self.order_len = n;
        if (self.order_fails) return error.SpawnFailed;
        if (self.clarify) {
            sink.emit(sink.ctx, "Entendimiento: falta el lenguaje\n[target-language] ¿Qué lenguaje?\n - Zig\n - Python\n");
            const answer = sink.request(sink.ctx, .answer);
            if (!std.mem.startsWith(u8, answer, "answer ")) return 0;
            self.answer_len = @min(answer.len, self.answer_text.len);
            @memcpy(self.answer_text[0..self.answer_len], answer[0..self.answer_len]);
        }
        if (self.plan_lines) {
            sink.emit(sink.ctx, "Entendimiento: crear calculadora.\nPLAN PROPUESTO (orden #42):\n  [t1] Escribe la web (programar) → opencode/deepseek-free\n     Archivo: calculadora/index.html\n");
        } else {
            sink.emit(sink.ctx, "Entendimiento: crear calculadora con pruebas.\nPLAN PROPUESTO (orden #42):\n1. Programación → proveedor/modelo\n   Archivo: calculadora/index.html\n2. Testing → otro/modelo\n3. Auditoría → fabricante/modelo\n");
        }
        if (!interaction.approved(sink.request(sink.ctx, .approve))) return 0;
        if (self.term) |term| {
            const frame = term.last_frame.items;
            self.plan_visible_on_dispatch = std.mem.indexOf(u8, frame, "PLAN PROPUESTO") != null and
                std.mem.indexOf(u8, frame, "calculadora/index.html") != null and
                std.mem.indexOf(u8, frame, text) != null;
            if (self.cancel_during_execution) term.poll_key = rawCtrlC();
        }
        if (self.perm_request) {
            const reply = sink.request(sink.ctx, .{ .perm = "Ejecutar npm test" });
            const rn = @min(reply.len, self.perm_reply.len);
            @memcpy(self.perm_reply[0..rn], reply[0..rn]);
            self.perm_reply_len = rn;
            if (std.mem.eql(u8, reply, "1") or std.mem.eql(u8, reply, "2")) self.protected_runs += 1;
        }
        self.dispatches += 1;
        // E3: informes de avance del despacho (mismo orden que el hijo real:
        // task_done y file_written tras el despacho, superagent.zig:3451).
        if (self.progress_events) {
            sink.progress(sink.ctx, interaction.TASK ++ " t1 ok 1000 4400 opencode/deepseek-free Escribe la web");
            sink.progress(sink.ctx, interaction.FILE ++ " t1 calculadora/index.html");
        }
        sink.emit(sink.ctx, "Linea uno de la orden\nLinea dos ");
        const cancelled = sink.pump(sink.ctx);
        if (cancelled) return 130;
        sink.emit(sink.ctx, "de la orden\n");
        return self.order_exit;
    }
};

fn rawChar(c: u21) keys.RawKey {
    return .{ .ch = c };
}

fn rawCtrlC() keys.RawKey {
    return .{ .vk = keys.VK_C, .ctrl = true };
}

fn rawEnter() keys.RawKey {
    return .{ .vk = keys.VK_RETURN };
}

fn rawToggle() keys.RawKey {
    return .{ .vk = keys.VK_O, .ctrl = true };
}

test "CK-MOT-027: sin consola la entrada sin argumentos conserva el --help" {
    const a = testing.allocator;
    try runNoArgs(a, .{ .stdin_is_console = false, .stdout_is_console = false }, fakeHelp);
    try testing.expectEqual(@as(usize, 1), help_calls);
    try runNoArgs(a, .{ .stdin_is_console = true, .stdout_is_console = false }, fakeHelp);
    try testing.expectEqual(@as(usize, 2), help_calls);
    try runNoArgs(a, .{ .stdin_is_console = false, .stdout_is_console = true }, fakeHelp);
    try testing.expectEqual(@as(usize, 3), help_calls);
}

var help_calls: usize = 0;

fn fakeHelp() anyerror!void {
    help_calls += 1;
}

test "CK-MOT-027 E2: shift-tab anuncia aprobacion automatica equivalente a --yes" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ .{ .vk = keys.VK_TAB, .shift = true }, rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{};
    try runOn(a, term.screen(), backend.ports());
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "--yes") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Aprobar automáticamente") != null);
    try testing.expectEqual(@as(usize, 0), backend.order_calls);
}

test "CK-MOT-027 E2: el plan y sus archivos se dibujan antes de despachar una sola vez" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), rawChar('1'), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{ .term = &term };
    try runOn(a, term.screen(), backend.ports());
    try testing.expectEqual(@as(usize, 1), backend.dispatches);
    try testing.expectEqual(@as(usize, 1), backend.order_calls);
    try testing.expect(backend.plan_visible_on_dispatch);
    try testing.expect(term.saw_approval);
}

test "CK-MOT-027 E2: 3 esc y ctrl-c descartan sin ejecutar" {
    const a = testing.allocator;
    const choices = [_]keys.RawKey{ rawChar('3'), .{ .vk = keys.VK_ESCAPE }, rawCtrlC() };
    for (choices) |choice| {
        var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), choice, rawCtrlC() } };
        defer term.last_frame.deinit(a);
        var backend = FakeBackend{};
        try runOn(a, term.screen(), backend.ports());
        try testing.expectEqual(@as(usize, 1), backend.order_calls);
        try testing.expectEqual(@as(usize, 0), backend.dispatches);
        try testing.expect(term.saw_approval);
    }
}

test "CK-MOT-027 E2: 2 edita y vuelve a aprobar la orden editada" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), rawChar('2'), rawChar('y'), rawEnter(), rawChar('1'), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{ .term = &term };
    try runOn(a, term.screen(), backend.ports());
    try testing.expectEqual(@as(usize, 2), backend.order_calls);
    try testing.expectEqual(@as(usize, 1), backend.dispatches);
    try testing.expectEqualStrings("xy", backend.order_text[0..backend.order_len]);
    try testing.expect(backend.plan_visible_on_dispatch);
}

test "CK-MOT-027 E2: flechas tab y enter seleccionan aprobar editar o descartar" {
    const a = testing.allocator;
    const routes = [_][]const keys.RawKey{
        &.{rawEnter()},
        &.{ .{ .vk = keys.VK_DOWN }, .{ .vk = keys.VK_UP }, rawEnter() },
        &.{ .{ .vk = keys.VK_RIGHT }, .{ .vk = keys.VK_LEFT }, rawEnter() },
        &.{ .{ .vk = keys.VK_UP }, rawEnter() },
        &.{ .{ .vk = keys.VK_DOWN }, .{ .vk = keys.VK_TAB }, rawEnter() },
        &.{ .{ .vk = keys.VK_TAB }, rawEnter() },
    };
    for (routes, 0..) |route, i| {
        var script: std.ArrayList(keys.RawKey) = .empty;
        defer script.deinit(a);
        try script.appendSlice(a, &.{ rawChar('x'), rawEnter() });
        try script.appendSlice(a, route);
        try script.append(a, rawCtrlC());
        var term = FakeScreen{ .script = script.items };
        defer term.last_frame.deinit(a);
        var backend = FakeBackend{};
        try runOn(a, term.screen(), backend.ports());
        try testing.expectEqual(@as(usize, if (i < 3) 1 else 0), backend.dispatches);
        if (i == 5) try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Edita la orden") != null);
    }
}

test "CK-MOT-027 E2: automatico dibuja el plan y volver a pedir siempre exige aprobacion" {
    const a = testing.allocator;
    const shift = keys.RawKey{ .vk = keys.VK_TAB, .shift = true };
    var term = FakeScreen{ .script = &.{ shift, rawChar('x'), rawEnter(), shift, rawChar('y'), rawEnter(), rawChar('3'), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{ .term = &term };
    try runOn(a, term.screen(), backend.ports());
    try testing.expectEqual(@as(usize, 2), backend.order_calls);
    try testing.expectEqual(@as(usize, 1), backend.dispatches);
    try testing.expect(backend.plan_visible_on_dispatch);
    try testing.expect(term.saw_auto and term.saw_always and term.saw_approval);
}

test "CK-MOT-027 E2: aclaraciones aceptan texto dentro de sesion incluso con automatico" {
    const a = testing.allocator;
    for ([_]bool{ false, true }) |automatic| {
        var script: std.ArrayList(keys.RawKey) = .empty;
        defer script.deinit(a);
        if (automatic) try script.append(a, .{ .vk = keys.VK_TAB, .shift = true });
        try script.appendSlice(a, &.{ rawChar('x'), rawEnter(), rawEnter(), rawChar('Z'), rawChar('i'), rawChar('g'), rawEnter() });
        if (!automatic) try script.append(a, rawChar('1'));
        try script.append(a, rawCtrlC());
        var term = FakeScreen{ .script = script.items };
        defer term.last_frame.deinit(a);
        var backend = FakeBackend{ .clarify = true };
        try runOn(a, term.screen(), backend.ports());
        try testing.expectEqual(@as(usize, 1), backend.dispatches);
        try testing.expectEqualStrings("answer Zig", backend.answer_text[0..backend.answer_len]);
    }
}

test "CK-MOT-027 E2: esc cancela aclaracion y ctrl-c cancela la ejecucion" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), .{ .vk = keys.VK_ESCAPE }, rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{ .clarify = true };
    try runOn(a, term.screen(), backend.ports());
    try testing.expectEqual(@as(usize, 0), backend.dispatches);
    var running = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), rawChar('1'), rawCtrlC() } };
    defer running.last_frame.deinit(a);
    var executing = FakeBackend{ .term = &running, .cancel_during_execution = true };
    try runOn(a, running.screen(), executing.ports());
    try testing.expectEqual(@as(usize, 1), executing.dispatches);
    try testing.expect(std.mem.indexOf(u8, running.last_frame.items, "Orden cancelada con Ctrl+C.") != null);
}

test "CK-MOT-027: una orden escrita llega al backend con el flujo existente" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('h'), rawChar('o'), rawChar('l'), rawChar('a'), rawEnter(), rawChar('1'), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{};
    try runOn(a, term.screen(), backend.ports());

    try testing.expect(term.closed);
    try testing.expectEqual(@as(usize, 1), backend.order_calls);
    try testing.expectEqualStrings("hola", backend.order_text[0..backend.order_len]);
    // La salida de la orden y el cierre quedan en el último fotograma.
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Linea uno de la orden") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Linea dos de la orden") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Orden completada (código 0).") != null);
}

test "CK-MOT-027: /gobernanza cambia el modo por el puerto y lo anuncia" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('/'), rawChar('g'), rawChar('o'), rawChar('b'), rawEnter(), rawChar('4'), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{};
    try runOn(a, term.screen(), backend.ports());

    try testing.expectEqual(@as(usize, 1), backend.gov_calls);
    try testing.expectEqualStrings("local_only", backend.gov_code[0..backend.gov_len]);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Gobernanza: Solo local (local_only)") != null);
}

test "CK-MOT-027: /modelo vuelca el catálogo en el panel" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('/'), rawChar('m'), rawChar('o'), rawChar('d'), rawEnter(), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{};
    try runOn(a, term.screen(), backend.ports());

    try testing.expectEqual(@as(usize, 1), backend.models_calls);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "deepseek-v4.1-flash-free") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Modelo activo: auto (router)") != null);
}

test "CK-MOT-027: si lanzar la orden falla, la sesión lo dice y sigue viva" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{ .order_fails = true };
    try runOn(a, term.screen(), backend.ports());

    try testing.expectEqual(@as(usize, 1), backend.order_calls);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "No se pudo ejecutar la orden: SpawnFailed") != null);
}

test "CK-MOT-027 E3: avance por tareas con diff y ctrl+o durante una orden real" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), rawChar('1'), rawToggle(), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{ .term = &term, .plan_lines = true, .progress_events = true };
    try runOn(a, term.screen(), backend.ports());

    try testing.expectEqual(@as(usize, 1), backend.dispatches);
    // Dos lecturas del archivo: instantánea (plan) y contenido final (informe).
    try testing.expectEqual(@as(usize, 2), backend.file_reads);
    try testing.expect(term.saw_progress);
    try testing.expect(term.saw_folded);
    // El último fotograma es tras ctrl+o: bloque desplegado con recuentos y diff
    // (con color: el signo y el texto abren tramos SGR propios).
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Escribe la web · hecha · opencode/deepseek-free · 3,4 s") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "calculadora/index.html") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "\x1b[38;2;121;153;106m+1") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "\x1b[38;2;196;85;61m−1") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "<h1>Hola!</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "<h1>Hola</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, term.last_frame.items, "Orden completada (código 0).") != null);
}

test "CK-MOT-027 E3: la sesion presenta el permiso pendiente y responde por su canal" {
    const a = testing.allocator;
    const denials = [_]keys.RawKey{ rawChar('2'), .{ .vk = keys.VK_ESCAPE } };
    for (denials) |denial| {
        var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), rawChar('1'), denial, rawCtrlC() } };
        defer term.last_frame.deinit(a);
        var backend = FakeBackend{ .perm_request = true };
        try runOn(a, term.screen(), backend.ports());
        try testing.expect(backend.perm_reply_len > 0);
        const reply = backend.perm_reply[0..backend.perm_reply_len];
        try testing.expectEqualStrings(if (denial.ch == '2') "2" else interaction.CANCEL, reply);
        try testing.expect(term.saw_permission);
        try testing.expectEqual(@as(usize, 1), backend.dispatches);
    }
}

test "CK-MOT-027 E3 r2: denegar con 3 o Escape impide la accion protegida" {
    const a = testing.allocator;
    const denials = [_]keys.RawKey{ rawChar('3'), .{ .vk = keys.VK_ESCAPE } };
    for (denials) |denial| {
        var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), rawChar('1'), denial, rawCtrlC() } };
        defer term.last_frame.deinit(a);
        var backend = FakeBackend{ .perm_request = true };
        try runOn(a, term.screen(), backend.ports());
        try testing.expect(term.saw_permission);
        try testing.expectEqual(@as(usize, 1), backend.perm_reply_len);
        try testing.expectEqualStrings(interaction.CANCEL, backend.perm_reply[0..backend.perm_reply_len]);
        try testing.expectEqual(@as(usize, 0), backend.protected_runs);
    }
}

test "CK-MOT-027 E3 r2: permitir una vez ejecuta la accion protegida" {
    const a = testing.allocator;
    var term = FakeScreen{ .script = &.{ rawChar('x'), rawEnter(), rawChar('1'), rawChar('1'), rawCtrlC() } };
    defer term.last_frame.deinit(a);
    var backend = FakeBackend{ .perm_request = true };
    try runOn(a, term.screen(), backend.ports());
    try testing.expect(term.saw_permission);
    try testing.expectEqualStrings("1", backend.perm_reply[0..backend.perm_reply_len]);
    try testing.expectEqual(@as(usize, 1), backend.protected_runs);
}
