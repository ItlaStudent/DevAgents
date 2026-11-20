//! core/src/tui/keys.zig — (E1): decodificador PURO de teclas.
//!
//! La capa de consola (console.zig) rellena `RawKey` desde KEY_EVENT_RECORD
//! (ReadConsoleInputW) y este módulo lo reduce a una acción de la sesión. Sin
//! consola, sin E/S y sin estado: se prueba con literales.

const std = @import("std");

/// Códigos virtuales de Windows que usamos (winuser.h).
pub const VK_BACK: u16 = 0x08;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_PRIOR: u16 = 0x21;
pub const VK_NEXT: u16 = 0x22;
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_DELETE: u16 = 0x2E;
pub const VK_O: u16 = 0x4F;
pub const VK_C: u16 = 0x43;

/// Sintético: el búfer de consola cambió de tamaño (WINDOW_BUFFER_SIZE_EVENT).
/// No es una tecla: el bucle la usa como señal para redibujar.
pub const VK_RESIZE: u16 = 0xFFFF;

/// Tecla cruda tal y como sale de la consola. `ch` es el carácter Unicode
/// (uChar) cuando la tecla es texto: aquí ya llegan los acentos, no hace falta
/// recomponer nada.
pub const RawKey = struct {
    vk: u16 = 0,
    ch: u21 = 0,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

/// Acción semántica de la sesión.
pub const Key = union(enum) {
    /// Texto que se inserta en la entrada (ya es un code point Unicode).
    char: u21,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    enter,
    escape,
    tab,
    shift_tab,
    page_up,
    page_down,
    ctrl_c,
    /// ctrl+o (E3): pliega o despliega el bloque de tarea enfocado.
    toggle_blocks,
    /// Redibujo (cambio de tamaño de la consola).
    resize,
    /// Tecla no usada por la sesión (PgUp/PgDn, ctrl+otra, alt+…).
    other,
};

/// Reduce un evento de teclado a la acción de la sesión. Cualquier tecla no
/// contemplada cae en `.other`: la sesión la ignora sin fallar.
pub fn decode(raw: RawKey) Key {
    // Ctrl+C se reconoce por el código virtual O por el carácter de control 3:
    // algunas consolas entregan uno u otro según el modo del teclado.
    if (raw.ctrl and (raw.vk == VK_C or raw.ch == 3)) return .ctrl_c;
    // Ctrl+O llega como VK_O con ctrl o como carácter de control 0x0F.
    if (raw.ctrl and (raw.vk == VK_O or raw.ch == 0x0F)) return .toggle_blocks;
    if (raw.vk == VK_RESIZE) return .resize;
    switch (raw.vk) {
        VK_BACK => return .backspace,
        VK_TAB => return if (raw.shift) .shift_tab else .tab,
        VK_RETURN => return .enter,
        VK_ESCAPE => return .escape,
        VK_END => return .end,
        VK_HOME => return .home,
        VK_LEFT => return .left,
        VK_UP => return .up,
        VK_RIGHT => return .right,
        VK_DOWN => return .down,
        VK_DELETE => return .delete,
        VK_PRIOR => return .page_up,
        VK_NEXT => return .page_down,
        else => {},
    }
    if (raw.ctrl or raw.alt) return .other;
    if (raw.ch >= 0x20 and raw.ch != 0x7F) return .{ .char = raw.ch };
    return .other;
}

const testing = std.testing;

test "CK-MOT-027: teclas de edición y control se decodifican" {
    try testing.expectEqual(Key.enter, decode(.{ .vk = VK_RETURN }));
    try testing.expectEqual(Key.backspace, decode(.{ .vk = VK_BACK }));
    try testing.expectEqual(Key.delete, decode(.{ .vk = VK_DELETE }));
    try testing.expectEqual(Key.left, decode(.{ .vk = VK_LEFT }));
    try testing.expectEqual(Key.right, decode(.{ .vk = VK_RIGHT }));
    try testing.expectEqual(Key.up, decode(.{ .vk = VK_UP }));
    try testing.expectEqual(Key.down, decode(.{ .vk = VK_DOWN }));
    try testing.expectEqual(Key.home, decode(.{ .vk = VK_HOME }));
    try testing.expectEqual(Key.end, decode(.{ .vk = VK_END }));
    try testing.expectEqual(Key.escape, decode(.{ .vk = VK_ESCAPE }));
    try testing.expectEqual(Key.tab, decode(.{ .vk = VK_TAB }));
    try testing.expectEqual(Key.shift_tab, decode(.{ .vk = VK_TAB, .shift = true }));
    try testing.expectEqual(Key.ctrl_c, decode(.{ .vk = VK_C, .ctrl = true }));
    try testing.expectEqual(Key.ctrl_c, decode(.{ .ch = 3, .ctrl = true }));
    try testing.expectEqual(Key.toggle_blocks, decode(.{ .vk = VK_O, .ctrl = true }));
    try testing.expectEqual(Key.toggle_blocks, decode(.{ .ch = 0x0F, .ctrl = true }));
    try testing.expectEqual(Key.resize, decode(.{ .vk = VK_RESIZE }));
    try testing.expectEqual(Key.page_up, decode(.{ .vk = VK_PRIOR }));
    try testing.expectEqual(Key.page_down, decode(.{ .vk = VK_NEXT }));
    try testing.expectEqual(Key.other, decode(.{ .vk = 0x41, .ctrl = true }));
}

test "CK-MOT-027: el texto llega como code point (acentos incluidos)" {
    try testing.expectEqual(@as(u21, 'a'), decode(.{ .ch = 'a', .vk = 0x41 }).char);
    try testing.expectEqual(@as(u21, 'á'), decode(.{ .ch = 0xE1 }).char);
    try testing.expectEqual(@as(u21, '?'), decode(.{ .ch = '?' }).char);
    // Shift y el símbolo del teclado: el carácter ya viene resuelto.
    try testing.expectEqual(@as(u21, '¿'), decode(.{ .ch = 0xBF, .shift = true }).char);
    // Control no imprimible sin ctrl+c: se ignora.
    try testing.expectEqual(Key.other, decode(.{ .ch = 0x01 }));
}
