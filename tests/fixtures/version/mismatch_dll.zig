//! deliberate DLL double for the orchestrator's real cabina test.
//! No engine initialization: the host must reject it before da_core_init.
pub export fn da_build_identity_v1() callconv(.c) [*:0]const u8 {
    return "fixture-old/abi0.bus0.ui0";
}
