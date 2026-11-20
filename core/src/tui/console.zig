//! core/src/tui/console.zig — (E1): capa fina sobre la consola Win32.
//!
//! (d) del encargo: comprueba que hay consola de verdad, la pone en modo crudo
//! (sin eco ni línea, para leer teclas una a una), activa el procesado VT para
//! el dibujo, usa la pantalla alternativa y restaura TODO al salir. También
//! lee eventos con ReadConsoleInputW (así llegan las flechas y los acentos como
//! UNICODE, sin depender de la entrada VT).
//!
//! Sin consola (stdin o stdout redirigidos a tubería/archivo) la sesión NO
//! arranca: `interactiveAllowed` devuelve false y la CLI conserva el `--help`
//! exacto de siempre. Todo lo que se puede probar sin consola real es función
//! pura (probe reducido y conversión de evento a RawKey).

const std = @import("std");
const builtin = @import("builtin");
const keys = @import("keys.zig");

pub const Probe = struct {
    stdin_is_console: bool = false,
    stdout_is_console: bool = false,
};

/// ¿Se puede abrir la sesión interactiva? Hacen falta las DOS consolas.
pub fn interactiveAllowed(p: Probe) bool {
    return p.stdin_is_console and p.stdout_is_console;
}

// ── Tipos Win32 mínimos (definiciones propias, como el resto del proyecto) ──

pub const COORD = extern struct { X: i16, Y: i16 };
pub const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};
pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: extern union { UnicodeChar: u16, AsciiChar: u8 },
    dwControlKeyState: u32,
};
/// El equivalente en Win32 de INPUT_RECORD mide 20 bytes: WORD + unión de 16.
const EVENT_PAYLOAD = extern union {
    KeyEvent: KEY_EVENT_RECORD,
    raw: [16]u8,
};
pub const INPUT_RECORD = extern struct {
    EventType: u16,
    Event: EVENT_PAYLOAD,
};

const KEY_EVENT: u16 = 0x0001;
const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;

const SHIFT_PRESSED: u32 = 0x0010;
const LEFT_CTRL_PRESSED: u32 = 0x0008;
const RIGHT_CTRL_PRESSED: u32 = 0x0004;
const LEFT_ALT_PRESSED: u32 = 0x0002;
const RIGHT_ALT_PRESSED: u32 = 0x0001;

// Modos de consola.
const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
const ENABLE_LINE_INPUT: u32 = 0x0002;
const ENABLE_ECHO_INPUT: u32 = 0x0004;
const ENABLE_WINDOW_INPUT: u32 = 0x0008;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6;
const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;
const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(~@as(usize, 0));
const STILL_ACTIVE: u32 = 259;

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: ?*anyopaque, lpMode: *u32) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: ?*anyopaque, dwMode: u32) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: ?*anyopaque, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) c_int;
extern "kernel32" fn ReadConsoleInputW(hConsoleInput: ?*anyopaque, lpBuffer: [*]INPUT_RECORD, nLength: u32, lpNumberOfEventsRead: *u32) callconv(.winapi) c_int;
extern "kernel32" fn GetNumberOfConsoleInputEvents(hConsoleInput: ?*anyopaque, lpNumberOfEvents: *u32) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(hFile: ?*anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;

/// Sondeo del sistema real: ¿stdin y stdout son consola?
pub fn probeSystem() Probe {
    if (builtin.os.tag != .windows) return .{};
    var mode: u32 = 0;
    return .{
        .stdin_is_console = GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode) != 0,
        .stdout_is_console = GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0,
    };
}

/// Traducción pura de un KEY_EVENT_RECORD a la tecla cruda de la sesión.
pub fn rawFromKeyEvent(k: KEY_EVENT_RECORD) keys.RawKey {
    const cs = k.dwControlKeyState;
    return .{
        .vk = k.wVirtualKeyCode,
        .ch = k.uChar.UnicodeChar,
        .ctrl = (cs & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0,
        .shift = (cs & SHIFT_PRESSED) != 0,
        .alt = (cs & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0,
    };
}

/// Terminal de la sesión: entra en modo crudo + VT + pantalla alternativa,
/// dibuja fotogramas y lee teclas. `leave` restaura lo guardado.
pub const Terminal = struct {
    in_handle: ?*anyopaque = null,
    out_handle: ?*anyopaque = null,
    saved_in_mode: u32 = 0,
    saved_out_mode: u32 = 0,
    active: bool = false,

    pub fn enter() Terminal {
        var t = Terminal{};
        if (builtin.os.tag != .windows) return t;
        t.in_handle = GetStdHandle(STD_INPUT_HANDLE);
        t.out_handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if (GetConsoleMode(t.in_handle, &t.saved_in_mode) != 0) {
            var m = t.saved_in_mode;
            // Modo crudo: sin procesado de línea, sin eco y sin Ctrl+C del
            // sistema (el Ctrl+C crudo lo gestiona la sesión).
            m &= ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT);
            m |= ENABLE_WINDOW_INPUT;
            _ = SetConsoleMode(t.in_handle, m);
        }
        if (GetConsoleMode(t.out_handle, &t.saved_out_mode) != 0) {
            _ = SetConsoleMode(t.out_handle, t.saved_out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
        t.active = true;
        t.writeRaw("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        return t;
    }

    pub fn leave(self: *Terminal) void {
        if (!self.active) return;
        self.writeRaw("\x1b[0m\x1b[?25h\x1b[?1049l");
        if (builtin.os.tag == .windows) {
            if (self.saved_in_mode != 0) _ = SetConsoleMode(self.in_handle, self.saved_in_mode);
            if (self.saved_out_mode != 0) _ = SetConsoleMode(self.out_handle, self.saved_out_mode);
        }
        self.active = false;
    }

    /// Tamaño visible de la ventana (columnas × filas); 120×40 si no responde.
    pub fn size(self: *Terminal) struct { w: usize, h: usize } {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (builtin.os.tag == .windows and GetConsoleScreenBufferInfo(self.out_handle, &info) != 0) {
            const w: i32 = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
            const h: i32 = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
            return .{
                .w = @intCast(@max(w, 20)),
                .h = @intCast(@max(h, 8)),
            };
        }
        return .{ .w = 120, .h = 40 };
    }

    /// Vuelca un fotograma completo: limpia, dibuja con '\r\n' y deja el cursor
    /// en la celda indicada (1-based; 0 = no tocar).
    pub fn draw(
        self: *Terminal,
        allocator: std.mem.Allocator,
        text: []const u8,
        cursor_row: usize,
        cursor_col: usize,
    ) !void {
        if (!self.active) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "\x1b[2J\x1b[H");
        for (text) |c| {
            if (c == '\n') {
                try out.appendSlice(allocator, "\r\n");
            } else {
                try out.append(allocator, c);
            }
        }
        if (cursor_row > 0 and cursor_col > 0) {
            const pos = try std.fmt.allocPrint(allocator, "\x1b[{d};{d}H", .{ cursor_row, cursor_col });
            defer allocator.free(pos);
            try out.appendSlice(allocator, pos);
        }
        try out.appendSlice(allocator, "\x1b[?25h");
        self.writeRaw(out.items);
    }

    /// Siguiente evento de teclado. `blocking=false` devuelve null si no hay
    /// nada pendiente. Los eventos de redimensionado llegan como
    /// `keys.VK_RESIZE` (señal de redibujo, no tecla).
    pub fn readKey(self: *Terminal, blocking: bool) ?keys.RawKey {
        if (builtin.os.tag != .windows or !self.active) return null;
        if (!blocking) {
            var pending: u32 = 0;
            if (GetNumberOfConsoleInputEvents(self.in_handle, &pending) == 0 or pending == 0) return null;
        }
        var rec: INPUT_RECORD = undefined;
        while (true) {
            var read: u32 = 0;
            if (ReadConsoleInputW(self.in_handle, @ptrCast(&rec), 1, &read) == 0 or read == 0) return null;
            switch (rec.EventType) {
                KEY_EVENT => {
                    const k = rec.Event.KeyEvent;
                    if (k.bKeyDown == 0) continue; // soltado: se ignora
                    return rawFromKeyEvent(k);
                },
                WINDOW_BUFFER_SIZE_EVENT => return .{ .vk = keys.VK_RESIZE },
                else => {
                    if (!blocking) return null; // ratón/foco: se descartan
                },
            }
        }
    }

    fn writeRaw(self: *Terminal, data: []const u8) void {
        if (builtin.os.tag != .windows) return;
        const h = self.out_handle orelse GetStdHandle(STD_OUTPUT_HANDLE);
        if (h == INVALID_HANDLE_VALUE) return;
        var offset: usize = 0;
        while (offset < data.len) {
            var written: u32 = 0;
            const chunk: u32 = @intCast(@min(data.len - offset, 1 << 20));
            if (WriteFile(h, data.ptr + offset, chunk, &written, null) == 0) return;
            offset += written;
        }
    }
};

pub const Size = struct { w: usize, h: usize };

/// Tabla de operaciones de terminal que consume la sesión. Permite probar el
/// bucle entero con una pantalla falsa (sin consola real) y deja el Term de
/// producción detrás de la misma interfaz.
pub const Screen = struct {
    ctx: ?*anyopaque = null,
    read_key: *const fn (?*anyopaque, bool) ?keys.RawKey,
    draw: *const fn (?*anyopaque, std.mem.Allocator, []const u8, usize, usize) void,
    size_fn: *const fn (?*anyopaque) Size,
    leave: *const fn (?*anyopaque) void,

    pub fn readKey(self: Screen, blocking: bool) ?keys.RawKey {
        return self.read_key(self.ctx, blocking);
    }

    pub fn drawAll(self: Screen, allocator: std.mem.Allocator, text: []const u8, row: usize, col: usize) void {
        self.draw(self.ctx, allocator, text, row, col);
    }

    pub fn sizeOf(self: Screen) Size {
        return self.size_fn(self.ctx);
    }

    pub fn close(self: Screen) void {
        self.leave(self.ctx);
    }
};

fn screenReadKey(ctx: ?*anyopaque, blocking: bool) ?keys.RawKey {
    const t: *Terminal = @ptrCast(@alignCast(ctx.?));
    return t.readKey(blocking);
}

fn screenDraw(ctx: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8, row: usize, col: usize) void {
    const t: *Terminal = @ptrCast(@alignCast(ctx.?));
    t.draw(allocator, text, row, col) catch {};
}

fn screenSize(ctx: ?*anyopaque) Size {
    const t: *Terminal = @ptrCast(@alignCast(ctx.?));
    const s = t.size();
    return .{ .w = s.w, .h = s.h };
}

fn screenLeave(ctx: ?*anyopaque) void {
    const t: *Terminal = @ptrCast(@alignCast(ctx.?));
    t.leave();
}

/// Envuelve el Terminal real en la tabla de operaciones de la sesión.
pub fn screenOf(terminal: *Terminal) Screen {
    return .{
        .ctx = terminal,
        .read_key = screenReadKey,
        .draw = screenDraw,
        .size_fn = screenSize,
        .leave = screenLeave,
    };
}

extern "kernel32" fn TerminateProcess(hProcess: ?*anyopaque, uExitCode: u32) callconv(.winapi) c_int;
extern "kernel32" fn GetExitCodeProcess(hProcess: ?*anyopaque, lpExitCode: *u32) callconv(.winapi) c_int;

const testing = std.testing;

test "CK-MOT-027: la sesión solo arranca con consola de entrada Y de salida" {
    try testing.expect(interactiveAllowed(.{ .stdin_is_console = true, .stdout_is_console = true }));
    try testing.expect(!interactiveAllowed(.{ .stdin_is_console = false, .stdout_is_console = true }));
    try testing.expect(!interactiveAllowed(.{ .stdin_is_console = true, .stdout_is_console = false }));
    try testing.expect(!interactiveAllowed(.{}));
}

test "CK-MOT-027: KEY_EVENT_RECORD se traduce a RawKey con modificadores" {
    const plain = KEY_EVENT_RECORD{
        .bKeyDown = 1,
        .wRepeatCount = 1,
        .wVirtualKeyCode = 'A',
        .wVirtualScanCode = 0,
        .uChar = .{ .UnicodeChar = 'a' },
        .dwControlKeyState = 0,
    };
    const r = rawFromKeyEvent(plain);
    try testing.expectEqual(@as(u16, 'A'), r.vk);
    try testing.expectEqual(@as(u21, 'a'), r.ch);
    try testing.expect(!r.ctrl and !r.shift and !r.alt);

    const shift = KEY_EVENT_RECORD{
        .bKeyDown = 1,
        .wRepeatCount = 1,
        .wVirtualKeyCode = 0x09, // TAB
        .wVirtualScanCode = 0,
        .uChar = .{ .UnicodeChar = 0x09 },
        .dwControlKeyState = SHIFT_PRESSED,
    };
    const rs = rawFromKeyEvent(shift);
    try testing.expect(rs.shift);
    try testing.expectEqual(keys.Key.shift_tab, keys.decode(rs));

    const ctrl = KEY_EVENT_RECORD{
        .bKeyDown = 1,
        .wRepeatCount = 1,
        .wVirtualKeyCode = 0x43, // C
        .wVirtualScanCode = 0,
        .uChar = .{ .UnicodeChar = 3 },
        .dwControlKeyState = LEFT_CTRL_PRESSED,
    };
    try testing.expectEqual(keys.Key.ctrl_c, keys.decode(rawFromKeyEvent(ctrl)));

    const acento = KEY_EVENT_RECORD{
        .bKeyDown = 1,
        .wRepeatCount = 1,
        .wVirtualKeyCode = 0xBF,
        .wVirtualScanCode = 0,
        .uChar = .{ .UnicodeChar = 0xE1 }, // á
        .dwControlKeyState = 0,
    };
    try testing.expectEqual(keys.Key{ .char = 0xE1 }, keys.decode(rawFromKeyEvent(acento)));
}

test "CK-MOT-027: INPUT_RECORD mide lo que espera Win32 (20 bytes)" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(KEY_EVENT_RECORD));
    try testing.expectEqual(@as(usize, 20), @sizeOf(INPUT_RECORD));
    try testing.expectEqual(@as(usize, 16), @sizeOf(EVENT_PAYLOAD));
}
