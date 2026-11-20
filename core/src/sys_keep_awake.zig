const std = @import("std");
const builtin = @import("builtin");

// Windows SetThreadExecutionState flags
pub const ES_SYSTEM_REQUIRED: u32 = 0x00000001;
pub const ES_DISPLAY_REQUIRED: u32 = 0x00000002;
pub const ES_CONTINUOUS: u32 = 0x80000000;

extern "kernel32" fn SetThreadExecutionState(esFlags: u32) callconv(.winapi) u32;

var is_awake_active: bool = false;

/// Activa keep-awake para evitar que el SO se suspenda durante ejecuciones largas de agentes (G3).
pub fn enableKeepAwake() void {
    if (builtin.os.tag == .windows) {
        _ = SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
        is_awake_active = true;
    }
}

/// Restaura el estado normal de suspensión cuando las tareas agénticas finalizan.
pub fn disableKeepAwake() void {
    if (builtin.os.tag == .windows) {
        _ = SetThreadExecutionState(ES_CONTINUOUS);
        is_awake_active = false;
    }
}

/// Consulta si el keep-awake está actualmente activo.
pub fn isKeepAwakeActive() bool {
    return is_awake_active;
}

test "keep awake toggle test" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: SetThreadExecutionState (mantener el equipo despierto) es de Windows; en Linux no esta disponible en esta version");
    enableKeepAwake();
    try std.testing.expect(isKeepAwakeActive());
    disableKeepAwake();
    try std.testing.expect(!isKeepAwakeActive());
}
