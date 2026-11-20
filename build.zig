const std = @import("std");

fn exportedRevision(b: *std.Build) []const u8 {
    const bytes = b.build_root.handle.readFileAlloc(b.graph.io, "DEVAGENTS-REVISION", b.allocator, .limited(128)) catch |err| switch (err) {
        error.FileNotFound => return "",
        else => std.debug.panic("Cannot read DEVAGENTS-REVISION: {s}", .{@errorName(err)}),
    };
    const revision = std.mem.trim(u8, bytes, "\r\n ");
    if (revision.len != 12) @panic("Invalid DEVAGENTS-REVISION length");
    for (revision) |c| if (!std.ascii.isHex(c)) @panic("Invalid DEVAGENTS-REVISION");
    return revision;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SEC5 P1 (rama e5-sec-os, integrada el 12-nov-2026 en la tanda 3): banco de
    // pruebas del aislamiento AppContainer, deliberadamente fuera de `test`, del
    // motor, de la DLL y del host. Base de F1.8; no cambia el producto.
    if (target.result.os.tag == .windows) {
        const governed = b.createModule(.{
            .root_source_file = b.path("core/src/governed_process.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        governed.addIncludePath(b.path("core/src"));
        const sec5_parent = b.createModule(.{
            .root_source_file = b.path("tests/sec5_os.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const sec5_child = b.createModule(.{
            .root_source_file = b.path("tests/sec5_child.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const sec5_recovery = b.createModule(.{
            .root_source_file = b.path("tests/sec5_recover.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        for ([_]*std.Build.Module{ sec5_parent, sec5_child, sec5_recovery }) |module| {
            module.addImport("governed_process", governed);
            module.addIncludePath(b.path("tests"));
            module.addIncludePath(b.path("core/src"));
            module.addCSourceFiles(.{
                .files = &.{"tests/sec5_fixture.c"},
                .flags = &.{ "-std=c11", "-DUNICODE", "-D_UNICODE", "-Wall", "-Wextra", "-Werror" },
            });
            for ([_][]const u8{ "kernel32", "advapi32", "user32", "shell32", "bcrypt", "userenv", "ntdll", "ole32", "ws2_32" }) |library|
                module.linkSystemLibrary(library, .{});
        }
        const parent_exe = b.addExecutable(.{ .name = "sec5-os", .root_module = sec5_parent });
        const child_exe = b.addExecutable(.{ .name = "sec5-child", .root_module = sec5_child });
        const recovery_exe = b.addExecutable(.{ .name = "sec5-recover", .root_module = sec5_recovery });
        const sec5_run = b.addRunArtifact(parent_exe);
        sec5_run.addArtifactArg(child_exe);
        if (b.args) |args| sec5_run.addArgs(args);
        sec5_run.has_side_effects = true;
        const sec5_step = b.step("test-sec5-os", "P1: real Windows restricted-token fixtures (requires representative standard user)");
        sec5_step.dependOn(&sec5_run.step);
        sec5_step.dependOn(&b.addInstallArtifact(parent_exe, .{}).step);
        sec5_step.dependOn(&b.addInstallArtifact(child_exe, .{}).step);
        const sec5_compile = b.step("build-sec5-os", "Compile/install SEC5 fixtures without measuring OS isolation");
        sec5_compile.dependOn(&b.addInstallArtifact(parent_exe, .{}).step);
        sec5_compile.dependOn(&b.addInstallArtifact(child_exe, .{}).step);
        sec5_compile.dependOn(&b.addInstallArtifact(recovery_exe, .{}).step);
        const identity_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        identity_module.addCSourceFiles(.{
            .files = &.{"tests/sec5_identity_control.c"},
            .flags = &.{ "-std=c11", "-DUNICODE", "-D_UNICODE", "-Wall", "-Wextra", "-Werror" },
        });
        identity_module.linkSystemLibrary("kernel32", .{});
        identity_module.linkSystemLibrary("ntdll", .{});
        const identity_exe = b.addExecutable(.{ .name = "sec5-identity-control", .root_module = identity_module });
        sec5_compile.dependOn(&b.addInstallArtifact(identity_exe, .{}).step);
    }

    // root.VERSION remains the single product-version source.
    const root_source = @embedFile("core/src/root.zig");
    const version_marker = "pub const VERSION = \"";
    const version_start = std.mem.indexOf(u8, root_source, version_marker).? + version_marker.len;
    const product_version = root_source[version_start..][0..std.mem.indexOfScalar(u8, root_source[version_start..], '"').?];
    var git_code: u8 = 0;
    const git_output = b.runAllowFail(&.{ "git", "rev-parse", "--short=12", "HEAD" }, &git_code, .ignore) catch "";
    const git_hash = if (git_code == 0 and git_output.len != 0) std.mem.trim(u8, git_output, "\r\n ") else exportedRevision(b);
    const identity = b.fmt("{s}{s}{s}/abi1.bus1.ui1", .{ product_version, if (git_hash.len > 0) "+" else "", git_hash });
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "identity", identity);
    const version_files = b.addWriteFiles();
    _ = version_files.add("build_version.h", b.fmt("#pragma once\n#define DA_BUILD_IDENTITY \"{s}\"\n", .{identity}));

    const semantic_version = std.SemanticVersion.parse(product_version) catch @panic("Invalid core.VERSION");
    const version_rc = version_files.add("build_version.rc", b.fmt("1 VERSIONINFO\nFILEVERSION {d},{d},{d},0\nPRODUCTVERSION {d},{d},{d},0\nFILEOS 0x40004L\nFILETYPE 0x1L\nBEGIN\n BLOCK \"StringFileInfo\"\n BEGIN\n  BLOCK \"040904b0\"\n  BEGIN\n   VALUE \"ProductVersion\", \"{s}\"\n  END\n END\n BLOCK \"VarFileInfo\"\n BEGIN\n  VALUE \"Translation\", 0x0409, 1200\n END\nEND\n", .{ semantic_version.major, semantic_version.minor, semantic_version.patch, semantic_version.major, semantic_version.minor, semantic_version.patch, identity }));

    // ── SQLite embebido (C) ────────────────────────────────────────────
    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_mod.addCSourceFiles(.{
        .files = &.{"core/src/db/sqlite3.c"},
        // NDEBUG desactiva los assert() internos de SQLite.
        //
        // Sin esta bandera, `sqlite3.c` se compilaba con los assert ACTIVOS en
        // las builds Debug, que son las que se usan a diario. Un assert de la
        // CRT no lanza excepción: llama a abort(), que en Windows es
        // ExitProcess(3) — sin diálogo, sin entrada en el registro de sucesos y
        // sin pasar por el filtro de excepciones de main.cpp. Es exactamente el
        // síntoma de `da_health_probe_all_json`: la aplicación desaparecía de
        // golpe con código de salida 3.
        //
        // Es el paso 1 del plan de CRASH-SONDEO-SALUD.md, el más barato de los
        // cuatro, y llevaba abierto desde el 2026-08-05 sin ejecutarse.
        //
        // SQLITE_THREADSAFE=1 (modo serializado) no cambia el valor por
        // defecto: se declara explícito porque el motor abre conexiones desde
        // varios hilos y esa suposición ya ha costado dos crashes (el
        // `event_conn` huérfano y el handle copiado de `TimedCallCtx`). Un
        // valor del que depende la seguridad de la memoria no debe quedar
        // implícito.
        .flags = &.{ "-DNDEBUG", "-DSQLITE_THREADSAFE=1" },
    });
    const sqlite_lib = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = sqlite_mod,
    });
    b.installArtifact(sqlite_lib);

    // ── Módulo providers (Zig) ───────────────────────────────────────
    const providers_mod = b.createModule(.{
        .root_source_file = b.path("providers/src/root.zig"),
        .target = target,
        .optimize = optimize,
        // T9: fuera de Windows la capa de plataforma (providers/src/platform.zig)
        // va sobre libc (getenv, getcwd, nanosleep).
        .link_libc = target.result.os.tag != .windows,
    });

    // ── Módulo core (Zig) ──────────────────────────────────────────────
    const core_mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addIncludePath(version_files.getDirectory());
    core_mod.addIncludePath(b.path("core/src/db"));
    core_mod.linkLibrary(sqlite_lib);
    core_mod.addImport("providers", providers_mod);
    core_mod.addOptions("build_version", version_options);
    if (target.result.os.tag == .windows) {
        core_mod.addCSourceFiles(.{ .files = &.{"shell/host/version_report.c"}, .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        core_mod.linkSystemLibrary("version", .{});
    }
    if (target.result.os.tag == .windows) addCoreNative(core_mod, false);
    if (target.result.os.tag == .linux) addCorePosix(core_mod);

    // Módulo core SOLO para pruebas: mismo código, pero la C de seguridad se
    // compila con los puntos de prueba (DA_TEST_SEAMS). Producción nunca los exporta.
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_test_mod.addIncludePath(version_files.getDirectory());
    core_test_mod.addIncludePath(b.path("core/src/db"));
    core_test_mod.linkLibrary(sqlite_lib);
    core_test_mod.addImport("providers", providers_mod);
    core_test_mod.addAnonymousImport("cli_quota_fixtures", .{ .root_source_file = b.path("tests/fixtures/CK-COMP-007/fixtures.zig") });
    core_test_mod.addOptions("build_version", version_options);
    if (target.result.os.tag == .windows) {
        core_test_mod.addCSourceFiles(.{ .files = &.{"shell/host/version_report.c"}, .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        core_test_mod.linkSystemLibrary("version", .{});
    }
    if (target.result.os.tag == .windows) addCoreNative(core_test_mod, true);
    if (target.result.os.tag == .linux) addCorePosix(core_test_mod);

    // Ejecutable DevAgents core (headless)
    const core_exe_mod = b.createModule(.{
        .root_source_file = b.path("core/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_exe_mod.addImport("core", core_mod);

    const core_exe = b.addExecutable(.{
        .name = "devagents-core",
        .root_module = core_exe_mod,
    });
    if (target.result.os.tag == .windows) core_exe.root_module.addWin32ResourceFile(.{ .file = version_rc });
    b.installArtifact(core_exe);
    // T7 (d): la CLI se llama `devagents`, como `code` o `codex`.
    // Es el MISMO binario que devagents-core (una sola compilación, copiado con
    // otro nombre); devagents-core se conserva porque el host y las pruebas lo
    // lanzan por ese nombre.
    const cli_alias_install = b.addInstallBinFile(core_exe.getEmittedBin(), if (target.result.os.tag == .windows) "devagents.exe" else "devagents");
    b.getInstallStep().dependOn(&cli_alias_install.step);

    // ── D4: proceso hijo del motor ────────────────────────────────────
    //
    // El primer tramo de sacar el motor del proceso de la cabina: un ejecutable
    // aparte que atiende `da_status` por el bus de tuberias. El resto de la
    // frontera C-ABI sigue por DLL. `engine_process.Supervisor` lo arranca, y su
    // test de aceptacion lo mata para comprobar que el llamador sobrevive.
    const engine_exe_mod = b.createModule(.{
        .root_source_file = b.path("core/src/engine_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_exe_mod.addImport("core", core_mod);
    const engine_exe = b.addExecutable(.{
        .name = "devagents-engine",
        .root_module = engine_exe_mod,
    });
    b.installArtifact(engine_exe);

    // T9 (F0.11, parte motor): fuera de Windows solo existen el
    // motor, la CLI, el MCP y key-admin. La cabina (host WebView2, DLL, WebUI y
    // pruebas C++) es Win32 y su porte es otra fase: aqui no se declara, para
    // que `zig build` sin paso no intente compilarla. Pasos:
    //   headless        instala devagents-core/devagents, motor, MCP y key-admin
    //   check-headless  compila lo anterior y sus pruebas sin ejecutarlas
    //                   (sirve en cruzado: -Dtarget=x86_64-linux-gnu)
    //   test-headless   ejecuta las pruebas del motor, proveedores y MCP
    if (target.result.os.tag != .windows) {
        addHeadlessSteps(b, .{
            .target = target,
            .optimize = optimize,
            .core_mod = core_mod,
            .core_test_mod = core_test_mod,
            .providers_mod = providers_mod,
            .core_exe = core_exe,
            .engine_exe = engine_exe,
            .cli_alias_install = cli_alias_install,
        });
        return;
    }

    // ── Ejecutable demo ───────────────────────────────────────────────
    const demo_exe_mod = b.createModule(.{
        .root_source_file = b.path("core/src/demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_exe_mod.addImport("core", core_mod);
    const demo_exe = b.addExecutable(.{
        .name = "devagents-demo",
        .root_module = demo_exe_mod,
    });
    b.installArtifact(demo_exe);

    const run_demo = b.addRunArtifact(demo_exe);
    const demo_step = b.step("demo", "Run DevAgents demo (10 tasks / 4 workers)");
    demo_step.dependOn(&run_demo.step);

    // ── Librería ABI de plugins (C) ────────────────────────────────────
    const plugins_abi_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugins_abi_mod.addIncludePath(b.path("plugins-abi/include"));
    plugins_abi_mod.addCSourceFiles(.{
        .files = &.{"plugins-abi/src/da_plugin.c"},
    });

    const plugins_abi = b.addLibrary(.{
        .name = "devagents_plugin_abi",
        .root_module = plugins_abi_mod,
    });
    b.installArtifact(plugins_abi);

    // ── Núcleo como BIBLIOTECA DINÁMICA (DLL) para la cabina ────────────
    const core_dll_root = b.createModule(.{
        .root_source_file = b.path("shell/host/core_dll_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_dll_root.addImport("core", core_mod);
    const core_dll = b.addLibrary(.{
        .name = "devagents_core",
        .root_module = core_dll_root,
        .linkage = .dynamic,
    });
    core_dll.win32_module_definition = b.path("shell/host/devagents_core.def");
    if (target.result.os.tag == .windows) core_dll.root_module.addWin32ResourceFile(.{ .file = version_rc });
    b.installArtifact(core_dll);

    // ── / H-G1-PERF: presupuesto del motor en ReleaseSafe ────
    //
    // La suite corre en Debug, asi que un presupuesto de tamano medido sobre
    // la salida de la suite no dice nada. Estos artefactos se compilan aparte
    // con ReleaseSafe y el checker los mide y arranca de verdad (spawn +
    // tuberia lista), que es el mismo camino que usa la cabina. No se
    // instalan con `zig build install`: solo los produce `test-perf-budget`.
    //
    // El MOTOR y la DLL van en ReleaseSafe, como en el paquete. Hasta el 13-nov
    // la DLL se medía en ReleaseFast: el @cImport de stdio.h de
    // `da_checklist_json` (c_api.zig), con las cabeceras MinGW y fortify, no
    // compilaba en ReleaseSafe con el translate-c de Zig 0.16. Ese @cImport se
    // sustituyó por `readFileBounded` (Win32) y `runtime-binaries
    // -Doptimize=ReleaseSafe` compila los cuatro binarios (tanda 4,).
    const perf_optimize = std.builtin.OptimizeMode.ReleaseSafe;
    const perf_dll_optimize = std.builtin.OptimizeMode.ReleaseSafe;
    const perf_sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = perf_optimize,
        .link_libc = true,
    });
    perf_sqlite_mod.addCSourceFiles(.{
        .files = &.{"core/src/db/sqlite3.c"},
        .flags = &.{ "-DNDEBUG", "-DSQLITE_THREADSAFE=1" },
    });
    const perf_sqlite_lib = b.addLibrary(.{
        .name = "sqlite3_perf",
        .root_module = perf_sqlite_mod,
    });

    const providers_perf_mod = b.createModule(.{
        .root_source_file = b.path("providers/src/root.zig"),
        .target = target,
        .optimize = perf_optimize,
    });
    const core_perf_mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = perf_optimize,
    });
    core_perf_mod.addIncludePath(version_files.getDirectory());
    core_perf_mod.addIncludePath(b.path("core/src/db"));
    core_perf_mod.linkLibrary(perf_sqlite_lib);
    core_perf_mod.addImport("providers", providers_perf_mod);
    core_perf_mod.addOptions("build_version", version_options);
    if (target.result.os.tag == .windows) {
        core_perf_mod.addCSourceFiles(.{ .files = &.{"shell/host/version_report.c"}, .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        core_perf_mod.linkSystemLibrary("version", .{});
        addCoreNative(core_perf_mod, false);
    }

    const engine_perf_mod = b.createModule(.{
        .root_source_file = b.path("core/src/engine_main.zig"),
        .target = target,
        .optimize = perf_optimize,
        .link_libc = true,
    });
    engine_perf_mod.addImport("core", core_perf_mod);
    const engine_perf_exe = b.addExecutable(.{
        .name = "devagents-engine-perf",
        .root_module = engine_perf_mod,
    });
    const install_engine_perf = b.addInstallArtifact(engine_perf_exe, .{});

    const core_perf_dll_mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = perf_dll_optimize,
    });
    core_perf_dll_mod.addIncludePath(version_files.getDirectory());
    core_perf_dll_mod.addIncludePath(b.path("core/src/db"));
    core_perf_dll_mod.linkLibrary(perf_sqlite_lib);
    core_perf_dll_mod.addImport("providers", providers_perf_mod);
    core_perf_dll_mod.addOptions("build_version", version_options);
    if (target.result.os.tag == .windows) {
        core_perf_dll_mod.addCSourceFiles(.{ .files = &.{"shell/host/version_report.c"}, .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        core_perf_dll_mod.linkSystemLibrary("version", .{});
        addCoreNative(core_perf_dll_mod, false);
    }

    const core_perf_dll_root = b.createModule(.{
        .root_source_file = b.path("shell/host/core_dll_root.zig"),
        .target = target,
        .optimize = perf_dll_optimize,
    });
    core_perf_dll_root.addImport("core", core_perf_dll_mod);
    const core_perf_dll = b.addLibrary(.{
        .name = "devagents_core_perf",
        .root_module = core_perf_dll_root,
        .linkage = .dynamic,
    });
    core_perf_dll.win32_module_definition = b.path("shell/host/devagents_core.def");
    if (target.result.os.tag == .windows) core_perf_dll.root_module.addWin32ResourceFile(.{ .file = version_rc });
    const install_core_perf = b.addInstallArtifact(core_perf_dll, .{});

    const perf_check_mod = b.createModule(.{
        .root_source_file = b.path("tools/perf_budget_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    perf_check_mod.addImport("core", core_mod);
    const perf_check_exe = b.addExecutable(.{
        .name = "perf-budget-check",
        .root_module = perf_check_mod,
    });
    b.installArtifact(perf_check_exe);

    const run_perf_budget = b.addRunArtifact(perf_check_exe);
    run_perf_budget.addArg(b.getInstallPath(.bin, "devagents-engine-perf.exe"));
    run_perf_budget.addArg(b.getInstallPath(.bin, "devagents_core_perf.dll"));
    run_perf_budget.addArg("40");
    run_perf_budget.addArg("800");
    run_perf_budget.has_side_effects = true;
    run_perf_budget.step.dependOn(&install_engine_perf.step);
    run_perf_budget.step.dependOn(&install_core_perf.step);

    const perf_budget_step = b.step(
        "test-perf-budget",
        "H-G1: engine ReleaseSafe / DLL ReleaseFast <= 40 MB and headless startup median <= 800 ms",
    );
    perf_budget_step.dependOn(&run_perf_budget.step);

    // ── Executable Host C++ (Shell WebView2) ────────────
    const shell_host_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    // Distribution has its own mandatory mode; development and tests retain -Doptimize.
    const shell_distribution_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .link_libcpp = true,
    });
    const shell_services_sources = [_][]const u8{
        "shell/host/window.cpp",
        "shell/host/webview_host.cpp",
        "shell/host/bridge.cpp",
        "shell/host/core_client.cpp",
        "shell/host/engine_supervisor.cpp",
        "shell/host/document_manager.cpp",
        "shell/host/file_watcher.cpp",
        "shell/host/project_search.cpp",
        "shell/host/pty_manager.cpp",
        "shell/host/hunk_manager.cpp",
        "shell/host/lsp_client.cpp",
        // E5.21 — multiventana: registro de AppWindow + parser de
        // window.open. Ver docs/MULTIVENTANA.md.
        "shell/host/app_windows.cpp",
        "shell/host/browser_panel.cpp",
        "shell/host/browser_dispatch.cpp",
        // Tanda 5 (F0.4): aplicar la actualización al cerrar.
        "shell/host/update_apply.cpp",
    };
    const shell_cpp_flags = shellCppFlags(optimize);
    for ([_]*std.Build.Module{ shell_host_mod, shell_distribution_mod }) |host_mod| {
        host_mod.addIncludePath(version_files.getDirectory());
        host_mod.addIncludePath(b.path("shell/host/include"));
        host_mod.addIncludePath(b.path("shell/host"));
        host_mod.addIncludePath(b.path("shell/host/sdk/build/native/include"));
        host_mod.addLibraryPath(b.path("shell/host/sdk/build/native/x64"));
        // The C++ preprocessor must agree with Zig optimization: release
        // excludes remote debugging code even when environment flags are set.
        host_mod.addCSourceFiles(.{
            .files = &([_][]const u8{"shell/host/main.cpp"} ++ shell_services_sources),
            .flags = shellCppFlags(host_mod.optimize.?),
        });
        host_mod.linkSystemLibrary("user32", .{});
        host_mod.linkSystemLibrary("gdi32", .{});
        host_mod.linkSystemLibrary("ole32", .{});
        host_mod.linkSystemLibrary("oleaut32", .{});
        host_mod.linkSystemLibrary("urlmon", .{});
        host_mod.linkSystemLibrary("shell32", .{});
        host_mod.linkSystemLibrary("advapi32", .{});
        host_mod.linkSystemLibrary("crypt32", .{});
        // T12 M3: update_apply.cpp recalcula la huella con BCrypt.
        host_mod.linkSystemLibrary("bcrypt", .{});
        host_mod.linkSystemLibrary("version", .{});
        host_mod.linkSystemLibrary("dwmapi", .{});
        host_mod.linkSystemLibrary("WebView2Loader.dll", .{});
        // Icono embebido en el .exe (Explorador, accesos directos, barra anclada).
        host_mod.addWin32ResourceFile(.{ .file = b.path("shell/host/devagents.rc") });
    }

    const shell_host_exe = b.addExecutable(.{
        .name = "devagents-host",
        .root_module = shell_host_mod,
        .win32_manifest = b.path("shell/host/devagents.manifest"),
    });
    shell_host_exe.subsystem = .Windows;
    if (target.result.os.tag == .windows) shell_host_exe.root_module.addWin32ResourceFile(.{ .file = version_rc });
    const shell_distribution_exe = b.addExecutable(.{
        .name = "devagents-host",
        .root_module = shell_distribution_mod,
        .win32_manifest = b.path("shell/host/devagents.manifest"),
    });
    shell_distribution_exe.subsystem = .Windows;
    if (target.result.os.tag == .windows) shell_distribution_mod.addWin32ResourceFile(.{ .file = version_rc });
    const install_dev_host = b.addInstallArtifact(shell_host_exe, .{});
    const host_step = b.step("shell-host-only", "Build and install the C++ WebView2 host only");
    host_step.dependOn(&install_dev_host.step);
    const install_distribution_host = b.addInstallArtifact(shell_distribution_exe, .{});
    // P2-1: a bare `zig build` installs the development host in
    // the mode of -Doptimize because cabina-aislada-cab031.ps1 and
    // vista-previa.ps1 run it and then open CDP via BEATS_DEVTOOLS_PORT,
    // which the ReleaseSafe host does not provide. The ReleaseSafe
    // distribution host reaches the packager only through the distribution
    // steps below (runtime-binaries / shell-distribution-only), which also
    // install the devagents-host.distribution marker checked by
    // tools/package_installer.ps1 (P2-2).
    b.getInstallStep().dependOn(&install_dev_host.step);

    // Isolated CDP driver: exactly the host services, no DLL or owner database.
    const test_webview_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_webview_mod.addIncludePath(version_files.getDirectory());
    test_webview_mod.addIncludePath(b.path("shell/host/include"));
    test_webview_mod.addIncludePath(b.path("shell/host"));
    test_webview_mod.addIncludePath(b.path("shell/host/sdk/build/native/include"));
    test_webview_mod.addLibraryPath(b.path("shell/host/sdk/build/native/x64"));
    test_webview_mod.addCSourceFiles(.{
        .files = &([_][]const u8{"shell/host/test_webview_security.cpp"} ++ shell_services_sources),
        .flags = shell_cpp_flags,
    });
    for ([_][]const u8{ "user32", "gdi32", "ole32", "oleaut32", "urlmon", "shell32", "advapi32", "crypt32", "bcrypt", "version", "dwmapi", "WebView2Loader.dll" }) |library|
        test_webview_mod.linkSystemLibrary(library, .{});
    test_webview_mod.addWin32ResourceFile(.{ .file = b.path("shell/host/devagents.rc") });
    const test_webview_exe = b.addExecutable(.{
        .name = "test-webview-security",
        .root_module = test_webview_mod,
        .win32_manifest = b.path("shell/host/devagents.manifest"),
    });
    const test_webview_step = b.step("webview-security-driver", "Build the isolated real-WebView CDP driver");
    test_webview_step.dependOn(&b.addInstallArtifact(test_webview_exe, .{}).step);

    // real-WebView driver; live CDP execution is explicit.
    const activity_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    activity_mod.addIncludePath(version_files.getDirectory());
    activity_mod.addIncludePath(b.path("shell/host/include"));
    activity_mod.addIncludePath(b.path("shell/host"));
    activity_mod.addIncludePath(b.path("shell/host/sdk/build/native/include"));
    activity_mod.addLibraryPath(b.path("shell/host/sdk/build/native/x64"));
    activity_mod.addCSourceFiles(.{
        .files = &([_][]const u8{"shell/host/test_activity_popout.cpp"} ++ shell_services_sources),
        .flags = shell_cpp_flags,
    });
    for ([_][]const u8{ "user32", "gdi32", "ole32", "oleaut32", "urlmon", "shell32", "advapi32", "crypt32", "bcrypt", "version", "dwmapi", "WebView2Loader.dll" }) |library|
        activity_mod.linkSystemLibrary(library, .{});
    activity_mod.addWin32ResourceFile(.{ .file = b.path("shell/host/devagents.rc") });
    const activity_exe = b.addExecutable(.{
        .name = "test-activity-popout",
        .root_module = activity_mod,
        .win32_manifest = b.path("shell/host/devagents.manifest"),
    });
    const activity_step = b.step("activity-popout-driver", "Build isolated activity popout lifecycle driver");
    activity_step.dependOn(&b.addInstallArtifact(activity_exe, .{}).step);
    const run_activity_native = b.addRunArtifact(activity_exe);
    run_activity_native.addArg("--native-only");
    run_activity_native.addPathDir(b.pathFromRoot("shell/host/sdk/build/native/x64"));
    const activity_native_step = b.step("test-activity-popout", "Run native activity popout lifecycle regression (no WebViews)");
    activity_native_step.dependOn(&run_activity_native.step);
    const monitor_popout_test = b.addSystemCommand(&.{ "node", "shell/webui/tests/monitor_popout.test.cjs" });
    monitor_popout_test.has_side_effects = true;
    const monitor_popout_step = b.step("test-monitor-popout", "Run Monitor push/render regression");
    monitor_popout_step.dependOn(&monitor_popout_test.step);

    const browser_driver_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    browser_driver_mod.addIncludePath(version_files.getDirectory());
    browser_driver_mod.addIncludePath(b.path("shell/host/include"));
    browser_driver_mod.addIncludePath(b.path("shell/host"));
    browser_driver_mod.addIncludePath(b.path("shell/host/sdk/build/native/include"));
    browser_driver_mod.addLibraryPath(b.path("shell/host/sdk/build/native/x64"));
    browser_driver_mod.addCSourceFiles(.{
        .files = &([_][]const u8{"shell/host/test_browser_panel.cpp"} ++ shell_services_sources),
        .flags = shell_cpp_flags,
    });
    for ([_][]const u8{ "user32", "gdi32", "ole32", "oleaut32", "urlmon", "shell32", "advapi32", "crypt32", "bcrypt", "version", "dwmapi", "WebView2Loader.dll" }) |library|
        browser_driver_mod.linkSystemLibrary(library, .{});
    browser_driver_mod.addWin32ResourceFile(.{ .file = b.path("shell/host/devagents.rc") });
    browser_driver_mod.linkSystemLibrary("windowscodecs", .{});
    const browser_driver = b.addExecutable(.{
        .name = "test-browser-panel",
        .root_module = browser_driver_mod,
        .win32_manifest = b.path("shell/host/devagents.manifest"),
    });
    const browser_driver_step = b.step("browser-panel-driver", "Build the isolated native browser panel E2E driver");
    browser_driver_step.dependOn(&b.addInstallArtifact(browser_driver, .{}).step);

    const browser_dispatch_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    browser_dispatch_test_mod.addIncludePath(b.path("shell/host"));
    browser_dispatch_test_mod.addIncludePath(b.path("shell/host/include"));
    browser_dispatch_test_mod.addIncludePath(b.path("shell/host/sdk/build/native/include"));
    browser_dispatch_test_mod.addLibraryPath(b.path("shell/host/sdk/build/native/x64"));
    browser_dispatch_test_mod.addCSourceFiles(.{
        .files = &.{ "shell/host/test_browser_dispatch.cpp", "shell/host/browser_dispatch.cpp", "shell/host/browser_panel.cpp" },
        .flags = shell_cpp_flags,
    });
    for ([_][]const u8{ "user32", "gdi32", "ole32", "oleaut32", "urlmon", "shell32", "advapi32", "crypt32", "version", "WebView2Loader.dll", "comctl32" }) |library|
        browser_dispatch_test_mod.linkSystemLibrary(library, .{});
    const browser_dispatch_test = b.addExecutable(.{ .name = "test-browser-dispatch", .root_module = browser_dispatch_test_mod });
    const run_browser_dispatch_test = b.addRunArtifact(browser_dispatch_test);
    const browser_dispatch_test_step = b.step("test-browser-dispatch", "Run browser.v1 transport C++ tests");
    browser_dispatch_test_step.dependOn(&run_browser_dispatch_test.step);
    b.installArtifact(browser_dispatch_test);

    const browser_agent_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    browser_agent_test_mod.addIncludePath(b.path("shell/host"));
    browser_agent_test_mod.addIncludePath(b.path("shell/host/include"));
    browser_agent_test_mod.addIncludePath(b.path("shell/host/sdk/build/native/include"));
    browser_agent_test_mod.addLibraryPath(b.path("shell/host/sdk/build/native/x64"));
    browser_agent_test_mod.addCSourceFiles(.{
        .files = &.{ "shell/host/test_browser_panel_agent.cpp", "shell/host/browser_panel.cpp" },
        .flags = shell_cpp_flags,
    });
    for ([_][]const u8{ "user32", "gdi32", "ole32", "oleaut32", "urlmon", "shell32", "advapi32", "crypt32", "version", "WebView2Loader.dll", "comctl32" }) |library|
        browser_agent_test_mod.linkSystemLibrary(library, .{});
    const browser_agent_test = b.addExecutable(.{ .name = "test-browser-panel-agent", .root_module = browser_agent_test_mod });
    const run_browser_agent_test = b.addRunArtifact(browser_agent_test);
    const browser_agent_test_step = b.step("test-browser-panel-agent", "Run browser.v1 panel lifecycle C++ tests");
    browser_agent_test_step.dependOn(&run_browser_agent_test.step);
    b.installArtifact(browser_agent_test);

    const test_origin_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_origin_mod.addIncludePath(b.path("shell/host"));
    test_origin_mod.addCSourceFiles(.{
        .files = &.{"shell/host/test_origin_policy.cpp"},
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE" },
    });
    test_origin_mod.linkSystemLibrary("urlmon", .{});
    test_origin_mod.linkSystemLibrary("ole32", .{});
    test_origin_mod.linkSystemLibrary("oleaut32", .{});
    test_origin_mod.linkSystemLibrary("crypt32", .{});
    const test_origin_exe = b.addExecutable(.{
        .name = "test-origin-policy",
        .root_module = test_origin_mod,
    });
    const test_origin_step = b.step("test-origin-policy", "Run exact WebView origin policy tests");
    test_origin_step.dependOn(&b.addRunArtifact(test_origin_exe).step);

    const test_bridge_policy_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_bridge_policy_mod.addIncludePath(b.path("shell/host"));
    test_bridge_policy_mod.addCSourceFiles(.{
        .files = &.{"shell/host/test_bridge_policy.cpp"},
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE" },
    });
    test_bridge_policy_mod.linkSystemLibrary("user32", .{});
    test_bridge_policy_mod.linkSystemLibrary("shell32", .{});
    test_bridge_policy_mod.linkSystemLibrary("urlmon", .{});
    test_bridge_policy_mod.linkSystemLibrary("ole32", .{});
    test_bridge_policy_mod.linkSystemLibrary("oleaut32", .{});
    const test_bridge_policy_exe = b.addExecutable(.{
        .name = "test-bridge-policy",
        .root_module = test_bridge_policy_mod,
    });
    const test_bridge_policy_step = b.step("test-bridge-policy", "Run host-owned bridge policy tests");
    test_bridge_policy_step.dependOn(&b.addRunArtifact(test_bridge_policy_exe).step);

    // ── Test LSP Client C++ ────────────────────────────────────────────────
    const test_lsp_client_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_lsp_client_mod.addIncludePath(b.path("shell/host"));
    test_lsp_client_mod.addCSourceFiles(.{
        .files = &.{
            "shell/host/test_lsp_client.cpp",
            "shell/host/lsp_client.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });

    const test_lsp_client_exe = b.addExecutable(.{
        .name = "test-lsp-client",
        .root_module = test_lsp_client_mod,
    });
    b.installArtifact(test_lsp_client_exe);

    const run_test_lsp_client = b.addRunArtifact(test_lsp_client_exe);
    const test_lsp_client_step = b.step("test-lsp-client", "Run C++ LSP client unit tests");
    test_lsp_client_step.dependOn(&run_test_lsp_client.step);

    // ── Test Hunk Manager C++ ──────────────────────────────────────────────
    const test_hunk_mgr_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_hunk_mgr_mod.addIncludePath(b.path("shell/host"));
    test_hunk_mgr_mod.addCSourceFiles(.{
        .files = &.{
            "shell/host/test_hunk_manager.cpp",
            "shell/host/hunk_manager.cpp",
            "shell/host/document_manager.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });

    const test_hunk_mgr_exe = b.addExecutable(.{
        .name = "test-hunk-mgr",
        .root_module = test_hunk_mgr_mod,
    });
    b.installArtifact(test_hunk_mgr_exe);

    const run_test_hunk_mgr = b.addRunArtifact(test_hunk_mgr_exe);
    const test_hunk_mgr_step = b.step("test-hunk-mgr", "Run C++ hunk manager unit tests");
    test_hunk_mgr_step.dependOn(&run_test_hunk_mgr.step);

    // ── Test PTY Manager C++ ──────────────────────────────────────────────
    const test_pty_mgr_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_pty_mgr_mod.addIncludePath(b.path("shell/host"));
    test_pty_mgr_mod.addCSourceFiles(.{
        .files = &.{
            "shell/host/test_pty_manager.cpp",
            "shell/host/pty_manager.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });

    const test_pty_mgr_exe = b.addExecutable(.{
        .name = "test-pty-mgr",
        .root_module = test_pty_mgr_mod,
    });
    b.installArtifact(test_pty_mgr_exe);

    const run_test_pty_mgr = b.addRunArtifact(test_pty_mgr_exe);
    const test_pty_mgr_step = b.step("test-pty-mgr", "Run C++ PTY manager unit tests");
    test_pty_mgr_step.dependOn(&run_test_pty_mgr.step);

    // ── Test Document Manager C++ ────────────────────────────────────────
    const test_doc_mgr_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_doc_mgr_mod.addIncludePath(b.path("shell/host"));
    test_doc_mgr_mod.addCSourceFiles(.{
        .files = &.{
            "shell/host/test_document_manager.cpp",
            "shell/host/document_manager.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });

    const test_doc_mgr_exe = b.addExecutable(.{
        .name = "test-doc-mgr",
        .root_module = test_doc_mgr_mod,
    });
    b.installArtifact(test_doc_mgr_exe);

    const run_test_doc_mgr = b.addRunArtifact(test_doc_mgr_exe);
    const test_doc_mgr_step = b.step("test-doc-mgr", "Run C++ document manager unit tests");
    test_doc_mgr_step.dependOn(&run_test_doc_mgr.step);

    // ── Test Project Search C++ ───────────────────────────
    const test_project_search_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_project_search_mod.addIncludePath(b.path("shell/host"));
    test_project_search_mod.addCSourceFiles(.{
        .files = &.{
            "shell/host/test_project_search.cpp",
            "shell/host/project_search.cpp",
            "shell/host/document_manager.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });

    const test_project_search_exe = b.addExecutable(.{
        .name = "test-project-search",
        .root_module = test_project_search_mod,
    });
    b.installArtifact(test_project_search_exe);

    const run_test_project_search = b.addRunArtifact(test_project_search_exe);
    const test_project_search_step = b.step("test-project-search", "Run C++ global search budget tests (5000 files <= 2s)");
    test_project_search_step.dependOn(&run_test_project_search.step);

    // ── Test Bridge C++ ────────────────────────────────────────────────
    const test_bridge_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_bridge_mod.addIncludePath(version_files.getDirectory());
    test_bridge_mod.addIncludePath(b.path("shell/host"));
    test_bridge_mod.addCSourceFiles(.{
        .files = &.{
            "shell/host/test_bridge.cpp",
            "shell/host/update_apply.cpp",
            "shell/host/bridge.cpp",
            "shell/host/core_client.cpp",
            "shell/host/engine_supervisor.cpp",
            "shell/host/document_manager.cpp",
            "shell/host/file_watcher.cpp",
            "shell/host/project_search.cpp",
            "shell/host/hunk_manager.cpp",
            "shell/host/pty_manager.cpp",
            "shell/host/lsp_client.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });
    test_bridge_mod.linkSystemLibrary("user32", .{});
    test_bridge_mod.linkSystemLibrary("gdi32", .{});
    test_bridge_mod.linkSystemLibrary("ole32", .{});
    test_bridge_mod.linkSystemLibrary("oleaut32", .{});
    test_bridge_mod.linkSystemLibrary("urlmon", .{});
    test_bridge_mod.linkSystemLibrary("shell32", .{});
    test_bridge_mod.linkSystemLibrary("version", .{});
    test_bridge_mod.linkSystemLibrary("bcrypt", .{});
    test_bridge_mod.linkSystemLibrary("dwmapi", .{});

    const test_bridge_exe = b.addExecutable(.{
        .name = "test-bridge",
        .root_module = test_bridge_mod,
    });
    b.installArtifact(test_bridge_exe);

    const run_test_bridge = b.addRunArtifact(test_bridge_exe);
    const test_bridge_step = b.step("test-bridge", "Run C++ bridge IPC unit tests");
    test_bridge_step.dependOn(&run_test_bridge.step);

    const version_test_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    version_test_mod.addIncludePath(version_files.getDirectory());
    version_test_mod.addIncludePath(b.path("shell/host"));
    version_test_mod.addCSourceFiles(.{ .files = &.{"shell/host/test_version.cpp"}, .flags = &.{"-std=c++17"} });
    const version_test = b.addExecutable(.{ .name = "test-version", .root_module = version_test_mod });
    version_test_mod.addCSourceFiles(.{ .files = &.{"shell/host/version_report.c"}, .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    version_test_mod.linkSystemLibrary("version", .{});
    version_test_mod.addWin32ResourceFile(.{ .file = version_rc });
    const run_version_test = b.addRunArtifact(version_test);
    b.step("test-version", "CK-COMP-004 native mismatch tests without product or network").dependOn(&run_version_test.step);
    test_bridge_step.dependOn(&run_version_test.step);

    const version_fixture = b.addLibrary(.{
        .name = "comp004-mismatch",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/version/mismatch_dll.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("version-mismatch-fixture", "Build only the deliberately incompatible DLL double").dependOn(&b.addInstallArtifact(version_fixture, .{}).step);

    // ── Test App Windows C++ (E5.21) ───────────────────────────────────────
    const test_appwin_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_appwin_mod.addIncludePath(version_files.getDirectory());
    test_appwin_mod.addIncludePath(b.path("shell/host/include"));
    test_appwin_mod.addIncludePath(b.path("shell/host"));
    test_appwin_mod.addIncludePath(b.path("shell/host/sdk/build/native/include"));
    test_appwin_mod.addLibraryPath(b.path("shell/host/sdk/build/native/x64"));
    test_appwin_mod.addCSourceFiles(.{
        .files = &.{
            "shell/host/test_app_windows.cpp",
            "shell/host/app_windows.cpp",
            "shell/host/bridge.cpp",
            "shell/host/window.cpp",
            "shell/host/webview_host.cpp",
            "shell/host/browser_panel.cpp",
            "shell/host/core_client.cpp",
            "shell/host/engine_supervisor.cpp",
            "shell/host/document_manager.cpp",
            "shell/host/file_watcher.cpp",
            "shell/host/project_search.cpp",
            "shell/host/hunk_manager.cpp",
            "shell/host/pty_manager.cpp",
            "shell/host/lsp_client.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });
    test_appwin_mod.linkSystemLibrary("user32", .{});
    test_appwin_mod.linkSystemLibrary("advapi32", .{});
    test_appwin_mod.linkSystemLibrary("crypt32", .{});
    test_appwin_mod.linkSystemLibrary("gdi32", .{});
    test_appwin_mod.linkSystemLibrary("ole32", .{});
    test_appwin_mod.linkSystemLibrary("oleaut32", .{});
    test_appwin_mod.linkSystemLibrary("urlmon", .{});
    test_appwin_mod.linkSystemLibrary("shell32", .{});
    test_appwin_mod.linkSystemLibrary("version", .{});
    test_appwin_mod.linkSystemLibrary("dwmapi", .{});
    test_appwin_mod.linkSystemLibrary("WebView2Loader.dll", .{});

    const test_appwin_exe = b.addExecutable(.{
        .name = "test-app-windows",
        .root_module = test_appwin_mod,
    });
    b.installArtifact(test_appwin_exe);

    const run_test_appwin = b.addRunArtifact(test_appwin_exe);
    const test_appwin_step = b.step("test-app-windows", "Run C++ multi-window unit tests (E5.21)");
    test_appwin_step.dependOn(&run_test_appwin.step);

    // UX: recurso PE real + clase/WM_SETICON/AppUserModelID, sin motor/WebView.
    const test_window_brand_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_window_brand_mod.addIncludePath(b.path("shell/host"));
    test_window_brand_mod.addCSourceFiles(.{
        .files = &.{ "shell/host/test_window_brand.cpp", "shell/host/window.cpp" },
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-Wall", "-Wextra", "-Werror", "-Wno-missing-field-initializers" },
    });
    test_window_brand_mod.addWin32ResourceFile(.{ .file = b.path("shell/host/devagents.rc") });
    for ([_][]const u8{ "user32", "gdi32", "dwmapi", "shell32", "ole32" }) |library| {
        test_window_brand_mod.linkSystemLibrary(library, .{});
    }
    const test_window_brand_exe = b.addExecutable(.{
        .name = "test-window-brand",
        .root_module = test_window_brand_mod,
    });
    b.installArtifact(test_window_brand_exe);
    const run_test_window_brand = b.addRunArtifact(test_window_brand_exe);
    run_test_window_brand.addArtifactArg(shell_host_exe);
    run_test_window_brand.has_side_effects = true;
    const test_window_brand_step = b.step("test-window-brand", "Verify embedded host icon and native window brand without core/user data");
    test_window_brand_step.dependOn(&run_test_window_brand.step);
    test_window_brand_step.dependOn(&b.addInstallArtifact(test_window_brand_exe, .{}).step);
    test_window_brand_step.dependOn(&b.addInstallArtifact(shell_host_exe, .{}).step);

    // ── Tests ────────────────────────────────────────────────────────────
    const test_filter = b.option([]const u8, "test-filter", "Filter test names");
    const test_filters: ?[]const []const u8 = if (test_filter) |f| &.{f} else null;

    // runner silencioso para TODOS los addTest del proyecto. Es el de la
    // std con `unexpected_error_tracing = false` — ver el doc del archivo.
    // Sin esto, la traza del CONNECTION_RESET del huérfano de H5 contamina el
    // stderr compartido y el build runner la cuelga del test que esté
    // corriendo cuando llega (la suite «fallaba al azar»). El std_options del
    // root del módulo NO sirve: el runner por defecto lo pisa con el suyo.
    const quiet_test_runner: std.Build.Step.Compile.TestRunner = .{
        .path = b.path("tools/quiet_test_runner.zig"),
        .mode = .server,
    };

    // isolated filtered core run; no engine/fixture processes.
    const prv004_tests = b.addTest(.{
        .root_module = core_test_mod,
        .filters = if (test_filters) |f| f else &.{"CK-PRV-004"},
        .test_runner = quiet_test_runner,
    });
    const prv004_run = b.addRunArtifact(prv004_tests);
    prv004_run.has_side_effects = true;
    const prv004_step = b.step("test-prv004-core", "Run filtered CK-PRV-004 core tests without live fixtures");
    prv004_step.dependOn(&prv004_run.step);

    const prv004_compile_ui = b.addSystemCommand(&.{ "node", "build_prv004_test.mjs" });
    prv004_compile_ui.setCwd(b.path("shell/webui"));
    prv004_compile_ui.has_side_effects = true;
    const prv004_run_ui = b.addSystemCommand(&.{ "node", "--test", "tests/CK-PRV-004-models.test.cjs" });
    prv004_run_ui.has_side_effects = true;
    prv004_run_ui.step.dependOn(&prv004_compile_ui.step);
    const prv004_ui_step = b.step("test-prv004-ui", "Run CK-PRV-004 WebUI tests");
    prv004_ui_step.dependOn(&prv004_run_ui.step);
    const prv004_all_step = b.step("test-prv004", "Run CK-PRV-004 core and WebUI checks");
    prv004_all_step.dependOn(&prv004_run.step);
    prv004_all_step.dependOn(&prv004_run_ui.step);
    const prv004_regression_tests = b.addTest(.{
        .root_module = core_test_mod,
        .filters = &.{ "model_catalog", "model_router", "model_selection", "order_preflight", "external_agent_catalog", "external_registry", "GOBERNANZA-FILTRO-PARIDAD", "ENJAMBRE", "CK-PRV-004" },
        .test_runner = quiet_test_runner,
    });
    const prv004_regression_run = b.addRunArtifact(prv004_regression_tests);
    prv004_regression_run.has_side_effects = true;
    const prv004_regression_step = b.step("test-prv004-regression", "Regress model selection, catalogs, external registry and swarms");
    prv004_regression_step.dependOn(&prv004_regression_run.step);
    const prv004_dll_step = b.step("prv004-dll", "Build the C ABI DLL with CK-PRV-004 exports");
    prv004_dll_step.dependOn(&b.addInstallArtifact(core_dll, .{}).step);

    const core_tests = b.addTest(.{
        .root_module = core_test_mod,
        .filters = if (test_filters) |f| f else &.{},
        .test_runner = quiet_test_runner,
    });

    const providers_tests = b.addTest(.{
        .root_module = providers_mod,
        .filters = if (test_filters) |f| f else &.{},
        .test_runner = quiet_test_runner,
    });

    const abi_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/abi/abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_tests_mod.addIncludePath(b.path("plugins-abi/include"));
    abi_tests_mod.linkLibrary(plugins_abi);
    const abi_tests = b.addTest(.{
        .root_module = abi_tests_mod,
        .test_runner = quiet_test_runner,
    });

    const mock_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/mock_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mock_tests = b.addTest(.{
        .root_module = mock_tests_mod,
        .test_runner = quiet_test_runner,
    });

    // / H-G4-ESCALATION: camino POSITIVO del hibrido (plan de pago
    // + build gratis) sobre el ledger real, con MockPlanner y sin red.
    const hybrid_escalation_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/hybrid_escalation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    hybrid_escalation_tests_mod.addImport("core", core_mod);
    const hybrid_escalation_tests = b.addTest(.{
        .root_module = hybrid_escalation_tests_mod,
        .test_runner = quiet_test_runner,
    });

    // E3.15–E3.26: batería de estrés del cierre V1. Maquinaria REAL: recordEvent
    // sobre runtime.db, HttpClient contra sockets hostiles, SQLite con dos
    // procesos escritores, filesystem unicode/profundo, SQLITE_FULL.
    const stress_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/stress_e3.zig"),
        .target = target,
        .optimize = optimize,
    });
    stress_tests_mod.addImport("core", core_mod);
    stress_tests_mod.addImport("providers", providers_mod);
    // H-G3: la prueba cruza la BD real de runtime.db con la API de
    // eventos; necesita una ruta anclada al worktree (el cwd del runner vive
    // en un temporal fuera del repo).
    const stress_options = b.addOptions();
    stress_options.addOption([]const u8, "worktree_root", b.pathFromRoot("."));
    stress_tests_mod.addOptions("build_options", stress_options);
    const stress_tests = b.addTest(.{
        .root_module = stress_tests_mod,
        .test_runner = quiet_test_runner,
    });

    // MCP server module + tests
    const mcp_server_mod = b.createModule(.{
        .root_source_file = b.path("tools/mcp_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_server_mod.addImport("core", core_mod);
    mcp_server_mod.linkSystemLibrary("user32", .{});
    mcp_server_mod.linkSystemLibrary("gdi32", .{});
    const mcp_server_tests = b.addTest(.{
        .root_module = mcp_server_mod,
        // SEC2 R7/N4: test-mcp respeta -Dtest-filter (antes corria siempre las 44).
        .filters = if (test_filters) |f| f else &.{},
        .test_runner = quiet_test_runner,
    });

    // Fuzzer tests
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tools/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("core", core_mod);
    fuzz_mod.addImport("providers", providers_mod);
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
        .test_runner = quiet_test_runner,
    });

    // ── Pruebas de la WebUI (Node) ─────────────────────────────────────
    //
    // El banco existia desde el 12-08 (`build_*_test.mjs` + `tests/*.cjs`) y
    // NADIE lo ejecutaba: ni `zig build test`, ni el hook, ni un script. Cuatro
    // archivos de pruebas escritas y cero corridas — que a efectos practicos es
    // no tener pruebas, con el coste de creer que se tienen.
    //
    // Cada entrada compila su modulo a CJS y corre su comprobador. Si `node` no
    // esta, el paso falla y se ve: es preferible a un salto silencioso (R14).
    const WebuiTest = struct { modulo: []const u8, comprobador: []const u8 };
    const webui_tests = [_]WebuiTest{
        .{ .modulo = "tests/terminal_build.mjs", .comprobador = "shell/webui/tests/terminal_reconnect.test.cjs" },
        .{ .modulo = "tests/terminal_build.mjs", .comprobador = "shell/webui/tests/editor_label.test.cjs" },
        .{ .modulo = "tests/terminal_build.mjs", .comprobador = "shell/webui/tests/cab005a_editor.test.cjs" },
        .{ .modulo = "tests/terminal_build.mjs", .comprobador = "shell/webui/tests/cab005b_editor.test.cjs" },
        .{ .modulo = "tests/terminal_build.mjs", .comprobador = "shell/webui/tests/cab031_build_failure.test.cjs" },
        .{ .modulo = "tests/terminal_build.mjs", .comprobador = "shell/webui/tests/terminal_dom.test.cjs" },
        .{ .modulo = "build_plan_mode_test.mjs", .comprobador = "tests/plan_mode_ui_test.cjs" },
        .{ .modulo = "tests/cli_quota_build.mjs", .comprobador = "tests/CK-COMP-007-ui.cjs" },
        .{ .modulo = "build_version_test.mjs", .comprobador = "tests/version_ui_test.cjs" },
        .{ .modulo = "build_version_test.mjs", .comprobador = "tests/version_browser_test.cjs" },
        .{ .modulo = "build_version_test.mjs", .comprobador = "shell/webui/tests/version_check.test.cjs" },
        .{ .modulo = "build_diag_test.mjs", .comprobador = "tests/diag_ui_test.cjs" },
        .{ .modulo = "build_sessions_test.mjs", .comprobador = "tests/sessions_ui_test.cjs" },
        .{ .modulo = "build_sessions_test.mjs", .comprobador = "tests/session_archive_ui_test.cjs" },
        .{ .modulo = "build_ui_repair_test.mjs", .comprobador = "tests/ui_repair_test.cjs" },
        // D6 — el umbral de compactacion automatica, que no tenia prueba.
        .{ .modulo = "build_autocompact_test.mjs", .comprobador = "tests/auto_compact_test.cjs" },
        // D5 — el parser ANSI SGR, que tampoco la tenia.
        .{ .modulo = "build_ansi_test.mjs", .comprobador = "tests/ansi_test.cjs" },
        // CHAT-PD-1 — divulgacion progresiva del turno agentico: canales,
        // correlacion de operaciones y estados terminales honestos.
        .{ .modulo = "build_activity_test.mjs", .comprobador = "tests/chat_activity_test.cjs" },
        // Plazo de BridgeClient.send: un host mudo ya no deja la promesa
        // pendiente para siempre (cabina: monitor clavado en "Consultando...").
        .{ .modulo = "build_client_test.mjs", .comprobador = "tests/bridge_client_test.cjs" },
        // UI-ACTION: allowlist del dispatcher de la cabina — segunda puerta
        // tras la validación del motor; acciones hostiles se rechazan con ack.
        .{ .modulo = "build_ui_actions_test.mjs", .comprobador = "tests/ui_actions_test.cjs" },
        // 22-09: binarios fuera del editor (catalog.db se abría y se podía
        // guardar como texto), pestañas que traen el editor y rojo de Monaco.
        .{ .modulo = "build_binary_test.mjs", .comprobador = "tests/editor_binary_test.cjs" },
        // H5 (12-nov-2026): el instalador copia shell/webui/vendor/monaco tal
        // cual, así que el DOMPurify incrustado debe ser >= 3.4.17 (el 3.4.8
        // traía una crítica y una moderada en npm audit).
        .{ .modulo = "build_binary_test.mjs", .comprobador = "shell/webui/tests/monaco_dompurify.test.cjs" },
        // E5.22: parser de ?ventana=/vista= y montaje aislado del panel —
        // una vista corrupta nunca debe dejar una ventana en blanco muda.
        .{ .modulo = "build_windowmode_test.mjs", .comprobador = "tests/window_mode_test.cjs" },
        .{ .modulo = "build_attachments_test.mjs", .comprobador = "tests/image_attachments.test.cjs" },
        .{ .modulo = "build_vision_test.mjs", .comprobador = "tests/vision_probe_ui_test.cjs" },
        .{ .modulo = "build_preview_test.mjs", .comprobador = "tests/preview_elements_ui_test.cjs" },
        .{ .modulo = "build_externalmodels_test.mjs", .comprobador = "tests/external_models_test.cjs" },
        .{ .modulo = "build_ux_test.mjs", .comprobador = "tests/cabina_ux.test.cjs" },
        // 11-nov: campana/toasts/alertas de esquina (Chromium por CDP) y la
        // configuración de la orden (presupuesto y conflictos en alertas). Estaban
        // fuera del gate y ordenes.test.cjs llegó a quedarse atrás sin que nadie
        // lo viera.
        .{ .modulo = "build_ux_test.mjs", .comprobador = "tests/attention.test.cjs" },
        .{ .modulo = "build_ux_test.mjs", .comprobador = "tests/ordenes.test.cjs" },
        .{ .modulo = "build_ux_test.mjs", .comprobador = "tests/i18n.test.cjs" },
        // Navegador integrado: modelo puro de la barra (dirección, estados,
        // textos) y contrato de puntos de ruptura por data-bp de la hoja.
        .{ .modulo = "build_browser_bar_test.mjs", .comprobador = "tests/browser_bar.test.cjs" },
        // DS-UI2 (16-oct-2026): estados en español, concordancia de tareas,
        // modelo de planificación legible y 4ª pestaña inferior sin cortar.
        .{ .modulo = "build_dsui2_test.mjs", .comprobador = "tests/dsui2_ui_test.cjs" },
        // E1/E2 (18-oct-2026): tarjetas del panel derecho —
        // herramientas de la columna, Entorno (rama por core.git.branch),
        // Resultados (7 -> 5 + Mostrar más) y plegado persistente. DOM real
        // en Chromium por CDP (mismo arnés que activity_panel.test.cjs).
        .{ .modulo = "build_rightcards_test.mjs", .comprobador = "tests/right_cards_ui_test.cjs" },
        // resolvedor único de navegador de las pruebas de UI (orden de
        // preferencia y error con la lista de rutas), probado con rutas falsas.
        // El módulo es un compilador cualquiera: el comprobador no lo usa.
        .{ .modulo = "build_autocompact_test.mjs", .comprobador = "tests/browser_resolver_test.cjs" },
        // datos hostiles en los sitios migrados a los helpers de
        // html.ts (catálogo/sesiones, verificación, timeline, paleta, barra del
        // navegador): se pintan como texto, en DOM real por CDP.
        .{ .modulo = "build_seg017_test.mjs", .comprobador = "tests/seg017_html_ui_test.cjs" },
        // tramo 1 (19-oct-2026): conversacion continua. Los bloques de
        // las ordenes anteriores sobreviven al envio, loadSession carga todo el
        // hilo con cota de eventos y los botones de un bloque anterior no tocan la
        // orden en curso. DOM real en Chromium por CDP.
        .{ .modulo = "build_cab003_test.mjs", .comprobador = "tests/CK-CAB-003-conversation_ui_test.cjs" },
        .{ .modulo = "build_cab003_test.mjs", .comprobador = "shell/webui/tests/mcp004_credencial.test.cjs" },
        // Tanda 5 (F0.4): actualizador en la cabina — interruptor, aviso,
        // «Lista…» con la firma, estados visibles y texto de GitHub como texto.
        .{ .modulo = "build_update_test.mjs", .comprobador = "tests/update_ui_test.cjs" },
    };
    var webui_test_steps: [webui_tests.len]*std.Build.Step = undefined;
    for (webui_tests, 0..) |wt, i| {
        const compilar = b.addSystemCommand(&.{ "node", wt.modulo });
        compilar.setCwd(b.path("shell/webui"));
        compilar.has_side_effects = true;
        const correr = b.addSystemCommand(&.{ "node", wt.comprobador });
        if (std.mem.eql(u8, wt.modulo, "build_ux_test.mjs") or
            std.mem.eql(u8, wt.modulo, "build_browser_bar_test.mjs"))
            correr.setCwd(b.path("shell/webui"));
        correr.has_side_effects = true;
        correr.step.dependOn(&compilar.step);
        webui_test_steps[i] = &correr.step;
    }
    const webui_test_step = b.step("test-webui", "Run the WebUI (Node) tests only");
    for (webui_test_steps) |s| webui_test_step.dependOn(s);
    // (c): `npm run test:security` (escape de la salida del modelo e
    // inventario de manejadores del puente) estaba fuera de la puerta y llegó a
    // quedarse en rojo 3 de 20 sin que nadie lo viera. Misma orden que package.json.
    const webui_security = b.addSystemCommand(&.{ "node", "--test", "tests/security.test.mjs", "tests/bridge_inventory.test.mjs" });
    webui_security.setCwd(b.path("shell/webui"));
    webui_security.has_side_effects = true;
    webui_test_step.dependOn(&webui_security.step);
    // T6 (13-nov-2026,): prueba determinista del script de página
    // del agente del navegador (shell/host/browser_agent_script.hpp) en
    // Chromium real por CDP contra tests/browser_agent_script_fixture.html.
    const browser_agent_script_test = b.addSystemCommand(&.{ "node", "tests/browser_agent_script_test.cjs" });
    browser_agent_script_test.has_side_effects = true;
    webui_test_step.dependOn(&browser_agent_script_test.step);

    // typecheck de la WebUI dentro del gate. El bundle compila con
    // esbuild, que NO typechequea: seis errores de tipos convivieron con
    // verdes durante semanas porque nadie corría tsc. `tsc` no está en la
    // tabla del Principio IX como dependencia NUEVA: es el mismo `npx`
    // node/esbuild que ya usan los pasos de la WebUI (tsc viene de la misma
    // instalación de node_modules del proyecto).
    const tsc_typecheck = b.addSystemCommand(&.{ "npx", "tsc", "--noEmit" });
    tsc_typecheck.setCwd(b.path("shell/webui"));
    tsc_typecheck.has_side_effects = true;
    const typecheck_step = b.step("typecheck", "TypeScript --noEmit de la WebUI (E-39)");
    typecheck_step.dependOn(&tsc_typecheck.step);

    const run_core_tests = b.addRunArtifact(core_tests);
    run_core_tests.has_side_effects = true;
    // los dobles TUI no usan sockets ni temporales del sistema.
    const tui_only = if (test_filter) |f| (std.mem.eql(u8, f, "CK-MOT-027") or std.mem.eql(u8, f, "CK-COMP-004")) else false;
    // estas pruebas usan relojes/trabajadores simulados, sin HTTP.
    const mot013_unit_only = if (test_filter) |f| blk: {
        for ([_][]const u8{ "CK-MOT-013", "resolveWaves", "H3:", "H4:", "D2:", "D2-XFILE", "registry keeps per-order timeout", "dispatch timeout scales", "approveAndDispatch reports concurrency peak > 1 for independent tasks" }) |name| {
            if (std.mem.eql(u8, f, name)) break :blk true;
        }
        break :blk false;
    } else false;
    // Preserve Zig's test-runner protocol while the wrapper owns the loopback
    // fixture and gives the test executable its ephemeral URL. Failure also
    // closes the server: it lives in the wrapper, not in a detached process.
    if (!tui_only and !mot013_unit_only) run_core_tests.argv.insertSlice(b.allocator, 0, &.{
        .{ .bytes = b.dupe("python") },
        .{ .bytes = b.pathFromRoot("tools/suite_native_fixture.py") },
        .{ .bytes = b.dupe("--native") },
    }) catch @panic("OOM");
    run_core_tests.addFileInput(b.path("tools/suite_native_fixture.py"));
    run_core_tests.addFileInput(b.path("tools/ordenes_fixture.py"));
    run_core_tests.addFileInput(b.path("tests/fixtures/native-http-server.py"));
    const run_b9_cabina_checks = b.addSystemCommand(&.{ "node", "tools/e5_b9_cabina_checks.mjs" });
    // E5.20/los tests C-ABI:memory: deben elegir un proyecto propio,
    // no el cwd del repositorio del propietario. Antes ocultaban las colisiones de
    // beats/orden-1 degradando a carpeta. Un cwd generado en la caché permite
    // mantener todas sus aserciones y probar la vía no-git sin mutar el repo.
    const core_test_cwd = b.addWriteFiles();
    _ = core_test_cwd.add("fixture.marker", "E5.20 isolated core test cwd\n");
    // Conserva los fixtures relativos que consume la suite; no se copia el
    // repo, su .git ni sus bases. El proyecto efectivo continúa siendo propio.
    _ = core_test_cwd.addCopyDirectory(b.path("tests/fixtures/discovery"), "tests/fixtures/discovery", .{});
    _ = core_test_cwd.addCopyDirectory(b.path("tests/fixtures/linked"), "tests/fixtures/linked", .{});
    _ = core_test_cwd.addCopyFile(b.path("tests/fixtures/checklist.txt"), "CHECKLIST.md");
    _ = core_test_cwd.addCopyFile(b.path("tests/fixtures/E5.20-falsas-alarmas-eventos-20261002.json"), "gov-recorded.json");
    // The suite wrapper changes cwd again; this synthetic fixture stays explicit.
    run_core_tests.setEnvironmentVariable("BEATS_GOV_RECORDED", b.pathFromRoot("tests/fixtures/E5.20-falsas-alarmas-eventos-20261002.json"));
    run_core_tests.setCwd(core_test_cwd.getDirectory());
    // D4 must exercise this build's engine, including custom --prefix builds.
    run_core_tests.setEnvironmentVariable("BEATS_TEST_BIN_DIR", b.getInstallPath(.bin, ""));
    run_core_tests.step.dependOn(&b.addInstallArtifact(engine_exe, .{}).step);
    // la prueba de lanzamiento de la CLI ejecuta devagents-core.exe
    // recién construido dentro de este prefijo (mismo criterio que el motor).
    run_core_tests.step.dependOn(&b.addInstallArtifact(core_exe, .{}).step);
    const run_providers_tests = b.addRunArtifact(providers_tests);
    const run_abi_tests = b.addRunArtifact(abi_tests);
    const run_mock_tests = b.addRunArtifact(mock_tests);
    const run_mcp_server_tests = b.addRunArtifact(mcp_server_tests);
    const focused_mcp = b.step("test-mcp", "Run MCP server contract tests");
    focused_mcp.dependOn(&run_mcp_server_tests.step);
    const focused_core = b.step("test-core", "Run core tests without WebUI or host steps");
    focused_core.dependOn(&run_core_tests.step);
    // unit tests without the network fixture or installed host.
    const prv003_native_tests = b.addTest(.{
        .root_module = core_test_mod,
        .test_runner = quiet_test_runner,
        .filters = &.{"CK-PRV-003"},
    });
    const run_prv003 = b.addRunArtifact(prv003_native_tests);
    run_prv003.has_side_effects = true;
    run_prv003.setCwd(core_test_cwd.getDirectory());
    const prv003_native = b.step("test-prv003-native", "Run filtered composer model tests without network");
    prv003_native.dependOn(&run_prv003.step);
    const compile_prv003_ui = b.addSystemCommand(&.{ "node", "build_prv003_test.mjs" });
    compile_prv003_ui.setCwd(b.path("shell/webui"));
    const run_prv003_ui = b.addSystemCommand(&.{ "node", "tests/CK-PRV-003-models.test.cjs" });
    run_prv003_ui.has_side_effects = true;
    run_prv003_ui.step.dependOn(&compile_prv003_ui.step);
    const prv003_ui = b.step("test-prv003-ui", "Run composer model and role tests");
    prv003_ui.dependOn(&run_prv003_ui.step);
    webui_test_step.dependOn(&run_prv003_ui.step);
    const prv003_browser = b.addSystemCommand(&.{ "node", "shell/webui/tests/prv003_browser.cjs" });
    prv003_browser.has_side_effects = true;
    prv003_browser.step.dependOn(&compile_prv003_ui.step);
    prv003_ui.dependOn(&prv003_browser.step);
    webui_test_step.dependOn(&prv003_browser.step);
    const prv003_safety = b.addSystemCommand(&.{ "node", "--test", "tests/CK-PRV-003-safety.test.cjs" });
    prv003_safety.has_side_effects = true;
    prv003_ui.dependOn(&prv003_safety.step);
    webui_test_step.dependOn(&prv003_safety.step);
    const prv003_regression_tests = b.addTest(.{
        .root_module = core_test_mod,
        .test_runner = quiet_test_runner,
        .filters = &.{ "CK-PRV-003", "ENJAMBRE:", "ROLES-MODELO:", "deriveStatus", "deriveAllSubjects", "FREE-PIN:", "MODO-DETERMINISTA:", "pipeline:" },
    });
    const run_prv003_regression = b.addRunArtifact(prv003_regression_tests);
    run_prv003_regression.has_side_effects = true;
    run_prv003_regression.setCwd(core_test_cwd.getDirectory());
    const prv003_regression = b.step("test-prv003-regression", "Regress roles, swarms, audit labels and free pins without network");
    prv003_regression.dependOn(&run_prv003_regression.step);
    const prv003_dll = b.step("prv003-dll", "Build the C ABI DLL with composer role exports");
    prv003_dll.dependOn(&b.addInstallArtifact(core_dll, .{}).step);
    const focused_providers = b.step("test-providers", "Run provider contract tests");
    focused_providers.dependOn(&run_providers_tests.step);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const run_stress_tests = b.addRunArtifact(stress_tests);
    const run_hybrid_escalation_tests = b.addRunArtifact(hybrid_escalation_tests);
    run_hybrid_escalation_tests.has_side_effects = true;
    const hybrid_escalation_step = b.step(
        "test-escalation",
        "H-G4: hybrid paid-plan/free-build leaves one justified ESCALATION row",
    );
    hybrid_escalation_step.dependOn(&run_hybrid_escalation_tests.step);
    // H-G8: soak aparte. El criterio del gate son 20 min; la
    // ventana se fija con -Dsoak-seconds (por defecto 1200 s) y el resto de
    // pruebas de estrés no consumen esa ventana (la variable sólo la lee H-G8).
    const soak_seconds = b.option(u32, "soak-seconds", "Ventana del soak H-G8 en segundos (por defecto 1200)") orelse 1200;
    const run_soak_tests = b.addRunArtifact(stress_tests);
    run_soak_tests.setEnvironmentVariable("BEATS_E3_SOAK_SECONDS", b.fmt("{d}", .{soak_seconds}));
    for ([_]*std.Build.Step.Run{
        run_providers_tests, run_abi_tests,       run_mock_tests,    run_mcp_server_tests,
        run_fuzz_tests,      run_stress_tests,    run_soak_tests,    run_test_bridge,
        run_test_doc_mgr,    run_test_pty_mgr,    run_test_hunk_mgr, run_test_lsp_client,
        run_test_appwin,     run_activity_native,
    }) |run| {
        run.has_side_effects = true;
        run.argv.insertSlice(b.allocator, 0, &.{
            .{ .bytes = b.dupe("python") },
            .{ .bytes = b.pathFromRoot("tools/suite_native_fixture.py") },
        }) catch @panic("OOM");
        run.addFileInput(b.path("tools/suite_native_fixture.py"));
    }
    run_core_tests.setEnvironmentVariable("BEATS_TEST_BIN_DIR", b.getInstallPath(.bin, ""));
    // SEC-RED también corre en la suite normal: dos orígenes aislados, sin claves.
    run_providers_tests.argv.insertSlice(b.allocator, 0, &.{
        .{ .bytes = b.dupe("python") },
        .{ .bytes = b.pathFromRoot("tools/sec_red_http_fixture.py") },
        .{ .bytes = b.dupe("--allow-unused") },
    }) catch @panic("OOM");
    run_providers_tests.addFileInput(b.path("tools/sec_red_http_fixture.py"));
    // test-app-windows inspecciona fuentes del host (E5.23/E5.25) y ya no corre
    // con el cwd del repositorio: la raíz del código le llega por entorno.
    run_test_appwin.setEnvironmentVariable("BEATS_SOURCE_ROOT", b.pathFromRoot("."));
    run_test_appwin.addFileInput(b.path("shell/host/app_windows.cpp"));
    run_test_appwin.addFileInput(b.path("shell/host/main.cpp"));

    // Solo la batería de estrés E3 — para iterar sin pagar la suite entera.
    const stress_test_step = b.step("test-stress", "Run the E3 stress battery only");
    stress_test_step.dependOn(&run_stress_tests.step);

    // H-G8: `zig build test-soak -Dsoak-seconds=1200` (20 min por
    // defecto). Es un paso aparte: la suite normal no paga la ventana larga.
    const soak_test_step = b.step("test-soak", "Run the H-G8 sustained soak (see -Dsoak-seconds)");
    soak_test_step.dependOn(&run_soak_tests.step);

    const test_step = b.step("test", "Run all unit tests");
    if (test_filter) |tf| {
        if (std.mem.startsWith(u8, tf, "E5.26") or std.mem.startsWith(u8, tf, "E5.27") or std.mem.startsWith(u8, tf, "E5.B8")) {
            test_step.dependOn(&run_core_tests.step);
            test_step.dependOn(&run_providers_tests.step);
            test_step.dependOn(&run_mcp_server_tests.step);
        } else if (std.mem.indexOf(u8, tf, "gemini") != null or
            std.mem.indexOf(u8, tf, "connector") != null or
            std.mem.indexOf(u8, tf, "providers") != null)
        {
            test_step.dependOn(&run_providers_tests.step);
        } else {
            test_step.dependOn(&run_core_tests.step);
        }
    } else {
        test_step.dependOn(&run_b9_cabina_checks.step);
        test_step.dependOn(&run_browser_dispatch_test.step);
        test_step.dependOn(&run_browser_agent_test.step);
        test_step.dependOn(&run_core_tests.step);
        test_step.dependOn(&run_providers_tests.step);
        test_step.dependOn(&run_abi_tests.step);
        test_step.dependOn(&run_mock_tests.step);
        test_step.dependOn(&run_mcp_server_tests.step);
        test_step.dependOn(&run_fuzz_tests.step);
        test_step.dependOn(&run_stress_tests.step);
        test_step.dependOn(&run_test_bridge.step);
        test_step.dependOn(&run_version_test.step);
        test_step.dependOn(&run_test_appwin.step);
        test_step.dependOn(&run_activity_native.step);
        test_step.dependOn(&monitor_popout_test.step);
        test_step.dependOn(&run_test_window_brand.step);
        test_step.dependOn(&run_test_doc_mgr.step);
        test_step.dependOn(&run_test_pty_mgr.step);
        test_step.dependOn(&run_test_hunk_mgr.step);
        test_step.dependOn(&run_test_project_search.step);
        test_step.dependOn(&run_hybrid_escalation_tests.step);
        test_step.dependOn(&run_test_lsp_client.step);
        for (webui_test_steps) |s| test_step.dependOn(s);
        test_step.dependOn(&webui_security.step);
        test_step.dependOn(&browser_agent_script_test.step);
        // E3.31: auditoría estática de los drivers vivos — un test que no
        // puede fallar es una mentira esperando turno (R14 sobre tests/**).
        const run_harness_audit = b.addSystemCommand(&.{ "node", "tests/live_harness_audit_test.cjs" });
        run_harness_audit.has_side_effects = true;
        test_step.dependOn(&run_harness_audit.step);
        // el typecheck corre con la suite, no aparte. Un chequeo que no
        // está en el gate es un chequeo que se olvida.
        test_step.dependOn(&tsc_typecheck.step);
    }

    // ── GATE G2a ───────────────────────────────────────────────────────
    const gate_g2a_mod = b.createModule(.{
        .root_source_file = b.path("tools/gate_g2a.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_g2a_mod.addImport("core", core_mod);
    gate_g2a_mod.addImport("providers", providers_mod);
    const gate_g2a_exe = b.addExecutable(.{
        .name = "gate-g2a",
        .root_module = gate_g2a_mod,
    });
    b.installArtifact(gate_g2a_exe);

    const run_gate_g2a = b.addRunArtifact(gate_g2a_exe);
    const gate_g2a_step = b.step("gate-g2a", "Run GATE G2a verification");
    gate_g2a_step.dependOn(&run_gate_g2a.step);

    // ── GATE F4 ────────────────────────────────────────────────────────
    const gate_f4_mod = b.createModule(.{
        .root_source_file = b.path("tools/gate_f4.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_f4_mod.addImport("core", core_mod);
    const gate_f4_exe = b.addExecutable(.{
        .name = "gate-f4",
        .root_module = gate_f4_mod,
    });
    b.installArtifact(gate_f4_exe);

    const run_gate_f4 = b.addRunArtifact(gate_f4_exe);
    const gate_f4_step = b.step("gate-f4", "Run GATE F4");
    gate_f4_step.dependOn(&run_gate_f4.step);

    // ── GATE F1 ────────────────────────────────────────────────────────
    const gate_f1_mod = b.createModule(.{
        .root_source_file = b.path("tools/gate_f1.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_f1_mod.addImport("core", core_mod);
    const gate_f1_exe = b.addExecutable(.{
        .name = "gate-f1",
        .root_module = gate_f1_mod,
    });
    b.installArtifact(gate_f1_exe);

    const run_gate_f1 = b.addRunArtifact(gate_f1_exe);
    const gate_f1_step = b.step("gate-f1", "Run GATE F1");
    gate_f1_step.dependOn(&run_gate_f1.step);

    // ── Servidor MCP mock ────────────────────────────────────────────────
    const mcp_mock_mod = b.createModule(.{
        .root_source_file = b.path("tests/mcp_mock_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mcp_mock_exe = b.addExecutable(.{
        .name = "mcp-mock-server",
        .root_module = mcp_mock_mod,
    });
    b.installArtifact(mcp_mock_exe);
    run_core_tests.step.dependOn(&b.addInstallArtifact(mcp_mock_exe, .{}).step);

    // ── Servidor MCP real (devagents-mcp) ──────────────────────────────────
    const mcp_server_exe = b.addExecutable(.{
        .name = "devagents-mcp",
        .root_module = mcp_server_mod,
    });
    if (target.result.os.tag == .windows) mcp_server_exe.root_module.addWin32ResourceFile(.{ .file = version_rc });
    b.installArtifact(mcp_server_exe);
    run_core_tests.step.dependOn(&b.addInstallArtifact(mcp_server_exe, .{}).step);

    // ── Superficie WebUI (TS → bundle estático) ─────────────────────────
    // Sin este paso el bundle que sirve la cabina se quedaba congelado: nada
    // en el build ejecutaba esbuild ni copiaba dist/ junto al ejecutable, así
    // que la ventana mostraba una UI vieja por muchos cambios que hubiera en
    // shell/webui/src. El host busca el bundle en <exe>/shell/webui/dist.
    const webui_build = b.addSystemCommand(&.{ "node", "esbuild.config.mjs" });
    webui_build.setCwd(b.path("shell/webui"));
    webui_build.setEnvironmentVariable("DEVAGENTS_BUILD_IDENTITY", identity);
    webui_build.has_side_effects = true;

    const webui_install = b.addInstallDirectory(.{
        .source_dir = b.path("shell/webui/dist"),
        .install_dir = .bin,
        .install_subdir = "shell/webui/dist",
    });
    webui_install.step.dependOn(&webui_build.step);

    const webui_step = b.step("webui", "Bundle the WebUI surface and install it next to the host");
    webui_step.dependOn(&webui_install.step);

    // El paso era OPT-IN y la cabina servia el bundle de hace dias: `zig build`
    // solo recompilaba el host y la UI quedaba congelada en el tiempo. Una
    // cabina que no refleja el source es un espejismo de "funciona". El build
    // por defecto SIEMPRE recompila e instala el bundle actual.
    b.getInstallStep().dependOn(&webui_install.step);

    // El instalador y sus accesos directos reutilizan la marca canonica.
    // La ventana usa exclusivamente el recurso PE embebido.
    const icon_install = b.addInstallBinFile(b.path("shell/host/devagents.ico"), "devagents.ico");

    // WebView2Loader.dll se enlaza DINAMICAMENTE (linkSystemLibrary mas arriba):
    // el enlazador solo consume la .lib de importacion, asi que el DLL tiene que
    // acabar AL LADO del .exe o Windows no arranca el proceso siquiera.
    //
    // Sin esto, `devagents-host.exe` arranca solo en maquinas que tengan una
    // copia suelta del DLL en el PATH. Medido el 2026-08-07: en el equipo de
    // desarrollo resolvia por casualidad desde
    // "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\",
    // que esta en el PATH por tener el SDK de Windows instalado. En un equipo
    // limpio el sintoma es un cuadro de dialogo del sistema:
    //   "The code execution cannot proceed because WebView2Loader.dll was not
    //    found. Reinstalling the program may fix this problem."
    // Ojo: NO basta con tener el runtime Evergreen de WebView2 instalado (ese
    // equipo lo tenia, 151.0.4129.59). El loader es un shim aparte que la
    // aplicacion debe distribuir ella misma.
    const webview_loader_install = b.addInstallBinFile(
        b.path("shell/host/sdk/build/native/x64/WebView2Loader.dll"),
        "WebView2Loader.dll",
    );
    // Tambien en el paso `install` por defecto: el .exe no arranca sin el, asi
    // que no puede depender de que se pida `runtime-binaries`.
    b.getInstallStep().dependOn(&webview_loader_install.step);

    const runtime_binaries_step = b.step("runtime-binaries", "Build and install DevAgents host, core, C API DLL, and MCP server");
    runtime_binaries_step.dependOn(&webui_install.step);
    runtime_binaries_step.dependOn(&icon_install.step);
    runtime_binaries_step.dependOn(&webview_loader_install.step);
    const distribution_host_step = b.step("shell-distribution-only", "Build and install the mandatory ReleaseSafe distribution host only");
    // Wire before generating the header: stepReaches reads the graph as it
    // stands when b.fmt runs.
    distribution_host_step.dependOn(&install_distribution_host.step);
    runtime_binaries_step.dependOn(&install_distribution_host.step);
    // H8/P2-2/P3: the generated header reflects the real
    // distribution host module and the real wiring of the steps that
    // install it; the same content is installed next to the host as the
    // devagents-host.distribution marker that package_installer.ps1
    // verifies before packaging (P2-2).
    const distribution_check = b.addWriteFiles();
    const distribution_header = b.fmt(
        "#pragma once\n#define DA_DISTRIBUTION_RELEASE_SAFE {d}\n#define DA_DISTRIBUTION_NDEBUG {d}\n#define DA_DISTRIBUTION_RUNTIME_BINARIES_WIRED {d}\n#define DA_DISTRIBUTION_SHELL_STEP_WIRED {d}\n#define DA_DEFAULT_INSTALL_DEV_HOST {d}\n#define DA_DISTRIBUTION_ENGINE_OPTIMIZED {d}\n",
        .{
            @intFromBool(shell_distribution_exe.root_module.optimize.? == .ReleaseSafe),
            @intFromBool(for (shellCppFlags(shell_distribution_exe.root_module.optimize.?)) |flag| {
                if (std.mem.eql(u8, flag, "-DNDEBUG")) break true;
            } else false),
            @intFromBool(stepReaches(b, runtime_binaries_step, &install_distribution_host.step)),
            @intFromBool(stepReaches(b, distribution_host_step, &install_distribution_host.step)),
            @intFromBool(stepReaches(b, b.getInstallStep(), &install_dev_host.step) and
                !stepReaches(b, b.getInstallStep(), &install_distribution_host.step)),
            // Tanda 4: el paquete del 13-nov llevaba el motor, la CLI,
            // el MCP y la DLL en Debug con el host en ReleaseSafe. El marcador
            // certifica tambien que ninguno de los cuatro va en Debug.
            @intFromBool(for ([_]*std.Build.Step.Compile{ core_exe, engine_exe, core_dll, mcp_server_exe }) |artifact| {
                if ((artifact.root_module.optimize orelse .Debug) == .Debug) break false;
            } else true),
        },
    );
    _ = distribution_check.add("distribution_build.h", distribution_header);
    test_appwin_mod.addIncludePath(distribution_check.getDirectory());
    const install_distribution_marker = b.addInstallBinFile(
        distribution_check.add("devagents-host.distribution", distribution_header),
        "devagents-host.distribution",
    );
    install_distribution_marker.step.dependOn(&install_distribution_host.step);
    distribution_host_step.dependOn(&install_distribution_marker.step);
    runtime_binaries_step.dependOn(&install_distribution_marker.step);
    runtime_binaries_step.dependOn(&b.addInstallArtifact(core_exe, .{}).step);
    runtime_binaries_step.dependOn(&cli_alias_install.step);
    // P1-7 (11-nov): el host lanza devagents-engine.exe (engine_supervisor.cpp)
    // y el instalador lo exige; runtime-binaries no lo instalaba.
    runtime_binaries_step.dependOn(&b.addInstallArtifact(engine_exe, .{}).step);
    runtime_binaries_step.dependOn(&b.addInstallArtifact(core_dll, .{}).step);
    runtime_binaries_step.dependOn(&b.addInstallArtifact(mcp_server_exe, .{}).step);
    const engine_binaries_step = b.step("engine-binaries", "Build core, C API and MCP without host or WebUI");
    const native_host_binaries_step = b.step("native-host-binaries", "Compile native host without running or bundling it");
    native_host_binaries_step.dependOn(&b.addInstallArtifact(shell_host_exe, .{}).step);
    engine_binaries_step.dependOn(&b.addInstallArtifact(core_exe, .{}).step);
    engine_binaries_step.dependOn(&cli_alias_install.step);
    engine_binaries_step.dependOn(&b.addInstallArtifact(core_dll, .{}).step);
    engine_binaries_step.dependOn(&b.addInstallArtifact(mcp_server_exe, .{}).step);

    // ── Administración de claves (key-admin) ────────────────────────────
    const key_admin_mod = b.createModule(.{
        .root_source_file = b.path("tools/key_admin.zig"),
        .target = target,
        .optimize = optimize,
    });
    key_admin_mod.addImport("core", core_mod);
    key_admin_mod.addImport("providers", providers_mod);
    const key_admin_exe = b.addExecutable(.{
        .name = "key-admin",
        .root_module = key_admin_mod,
    });
    b.installArtifact(key_admin_exe);
    runtime_binaries_step.dependOn(&b.addInstallArtifact(key_admin_exe, .{}).step);

    // ── Verificador de worker CLI ──────────────────────────────────────
    const cli_worker_mock_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli_worker_mock.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .windows) cli_worker_mock_mod.linkSystemLibrary("advapi32", .{});
    const cli_worker_mock_exe = b.addExecutable(.{
        .name = "cli-worker-mock",
        .root_module = cli_worker_mock_mod,
    });
    b.installArtifact(cli_worker_mock_exe);
    run_core_tests.step.dependOn(&b.addInstallArtifact(cli_worker_mock_exe, .{}).step);

    // ── Agente ACP mock (E5.06): agente externo versionado y determinista ──
    const acp_mock_mod = b.createModule(.{
        .root_source_file = b.path("tools/acp_mock_agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    const acp_mock_exe = b.addExecutable(.{
        .name = "acp-mock-agent",
        .root_module = acp_mock_mod,
    });
    b.installArtifact(acp_mock_exe);
    // These tests execute real synthetic helpers, so a plain `build test`
    // must build its own helpers instead of depending on another checkout.
    for ([_]*std.Build.Step.Compile{ acp_mock_exe, cli_worker_mock_exe, mcp_mock_exe, mcp_server_exe, engine_exe }) |fixture| {
        run_core_tests.step.dependOn(&b.addInstallArtifact(fixture, .{}).step);
    }

    // ── Verificador de API C ───────────────────────────────────────────
    const c_api_check_mod = b.createModule(.{
        .root_source_file = b.path("tests/c_api_check_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_check_mod.addIncludePath(b.path("shell/host/include"));
    c_api_check_mod.addCSourceFiles(.{ .files = &.{"tests/c_api_consumer.c"} });
    c_api_check_mod.addImport("core", core_mod);
    const c_api_check_exe = b.addExecutable(.{
        .name = "c-api-check",
        .root_module = c_api_check_mod,
    });
    b.installArtifact(c_api_check_exe);
    const run_c_api_check = b.addRunArtifact(c_api_check_exe);
    const c_api_check_step = b.step("c-api-check", "Verify C API consumer");
    c_api_check_step.dependOn(&run_c_api_check.step);

    // ── GATE G3 ────────────────────────────────────────────────────────
    const gate_g3_mod = b.createModule(.{
        .root_source_file = b.path("tools/gate_g3.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_g3_mod.addImport("core", core_mod);
    const gate_g3_exe = b.addExecutable(.{
        .name = "gate-g3",
        .root_module = gate_g3_mod,
    });
    b.installArtifact(gate_g3_exe);

    const run_gate_g3 = b.addRunArtifact(gate_g3_exe);
    const gate_g3_step = b.step("gate-g3", "Run GATE G3");
    gate_g3_step.dependOn(&run_gate_g3.step);

    // ── GATE F6 ────────────────────────────────────────────────────────
    const gate_f6_mod = b.createModule(.{
        .root_source_file = b.path("tools/gate_f6.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_f6_mod.addImport("core", core_mod);
    const gate_f6_exe = b.addExecutable(.{
        .name = "gate-f6",
        .root_module = gate_f6_mod,
    });
    b.installArtifact(gate_f6_exe);

    const run_gate_f6 = b.addRunArtifact(gate_f6_exe);
    const gate_f6_step = b.step("gate-f6", "Run GATE F6");
    gate_f6_step.dependOn(&run_gate_f6.step);

    // ── GATE F6 LIVE ───────────────────────────────────────────────────
    const gate_f6_live_mod = b.createModule(.{
        .root_source_file = b.path("tools/gate_f6_live.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_f6_live_mod.addImport("core", core_mod);
    const gate_f6_live_exe = b.addExecutable(.{
        .name = "gate-f6-live",
        .root_module = gate_f6_live_mod,
    });
    b.installArtifact(gate_f6_live_exe);

    const run_gate_f6_live = b.addRunArtifact(gate_f6_live_exe);
    if (b.args) |args| run_gate_f6_live.addArgs(args);
    const gate_f6_live_step = b.step("gate-f6-live", "Run GATE F6 LIVE");
    gate_f6_live_step.dependOn(&run_gate_f6_live.step);

    // ── Ejemplo de plugin C (DLL) ──────────────────────────────────────
    const example_plugin_mod = b.createModule(.{
        .root_source_file = b.path("plugins/example-provider/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_plugin_mod.addIncludePath(b.path("plugins-abi/include"));
    const example_plugin_dll = b.addLibrary(.{
        .name = "example_provider",
        .root_module = example_plugin_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(example_plugin_dll);

    // ── GATE F8 ────────────────────────────────────────────────────────
    const gate_f8_mod = b.createModule(.{
        .root_source_file = b.path("tools/gate_f8.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_f8_mod.addImport("core", core_mod);
    const gate_f8_exe = b.addExecutable(.{
        .name = "gate-f8",
        .root_module = gate_f8_mod,
    });
    b.installArtifact(gate_f8_exe);

    const run_gate_f8 = b.addRunArtifact(gate_f8_exe);
    const gate_f8_step = b.step("gate-f8", "Run GATE F8");
    gate_f8_step.dependOn(&run_gate_f8.step);

    // ── Fuzzer de parsers ──────────────────────────────────────────────
    const fuzz_exe = b.addExecutable(.{
        .name = "devagents-fuzz",
        .root_module = fuzz_mod,
    });
    b.installArtifact(fuzz_exe);

    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.addArg("100000");
    const fuzz_step = b.step("fuzz", "Run parser fuzzer");
    fuzz_step.dependOn(&run_fuzz.step);

    // ── Secrets check ──────────────────────────────────────────────────
    const secrets_check_cmd = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File", "tools/secrets_check.ps1" });
    const secrets_step = b.step("secrets-check", "Grep gate artifacts for key patterns");
    secrets_step.dependOn(&secrets_check_cmd.step);

    const secrets_selftest_cmd = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File", "tools/secrets_check_selftest.ps1" });
    const secrets_selftest_step = b.step("secrets-check-selftest", "Self-test the secrets gate");
    secrets_selftest_step.dependOn(&secrets_selftest_cmd.step);

    // ── E2E suite umbrella ─────────────────────────────────────────────
    const e2e_step = b.step("e2e", "Run full E2E suite");
    e2e_step.dependOn(&run_core_tests.step);
    e2e_step.dependOn(&run_providers_tests.step);
    e2e_step.dependOn(&run_abi_tests.step);
    e2e_step.dependOn(&run_mock_tests.step);
    e2e_step.dependOn(&run_demo.step);
    e2e_step.dependOn(&run_gate_f1.step);
    e2e_step.dependOn(&run_gate_f4.step);
    e2e_step.dependOn(&run_gate_g3.step);
    e2e_step.dependOn(&run_gate_f6.step);
    e2e_step.dependOn(&run_gate_f8.step);
    e2e_step.dependOn(&run_c_api_check.step);
    e2e_step.dependOn(&secrets_check_cmd.step);
    e2e_step.dependOn(&secrets_selftest_cmd.step);

    // ── Bench scheduler ────────────────────────────────────────────────
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_scheduler.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("core", core_mod);
    const bench_exe = b.addExecutable(.{
        .name = "devagents-bench-scheduler",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench-scheduler", "Benchmark scheduler");
    bench_step.dependOn(&run_bench.step);

    // ── Bench recuperación (E5.16) ─────────────────────────────────────
    // recall@5/MRR de grep literal, BM25, repo-map e híbrida sobre las 30
    // consultas con verdad commiteada, + efecto del repo-map en el planner.
    const bench_ret_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_retrieval.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_ret_mod.addImport("core", core_mod);
    const bench_ret_exe = b.addExecutable(.{
        .name = "devagents-bench-retrieval",
        .root_module = bench_ret_mod,
    });
    b.installArtifact(bench_ret_exe);
    // El paso compila y lanza con los defaults (truth commiteado, catálogo y
    // runtime resueltos por el propio binario); overrides por argv al exe.
    const run_bench_ret = b.addRunArtifact(bench_ret_exe);
    if (b.args) |bargs| run_bench_ret.addArgs(bargs);
    const bench_ret_step = b.step("bench-retrieval", "E5.16: recall@5/MRR de recuperación");
    bench_ret_step.dependOn(&run_bench_ret.step);

    // ── Carga SQLite (DS-TANDA2) ───────────────────────────────────────
    // Estudio de limites de SQLite: N escritores + 2 lectores sobre runtime.db
    // con la configuracion real del motor. Solo lectura del producto.
    const carga_mod = b.createModule(.{
        .root_source_file = b.path("tools/sqlite_carga.zig"),
        .target = target,
        .optimize = optimize,
    });
    carga_mod.addImport("core", core_mod);
    const carga_exe = b.addExecutable(.{
        .name = "devagents-sqlite-carga",
        .root_module = carga_mod,
    });
    const run_carga = b.addRunArtifact(carga_exe);
    if (b.args) |bargs| run_carga.addArgs(bargs);
    const carga_step = b.step("sqlite-carga", "DS-TANDA2: estudio de carga de SQLite");
    carga_step.dependOn(&run_carga.step);

    // ── Formato ────────────────────────────────────────────────────────
    const fmt_step = b.step("fmt", "Format all Zig source files");
    const fmt = b.addFmt(.{ .paths = &.{
        "build.zig",
        "core",
        "providers",
        "tests",
        "tools",
    } });
    fmt_step.dependOn(&fmt.step);
}

/// Fuente C de seguridad de agentes externos y sus bibliotecas del sistema.
/// `test_seams` añade los puntos de prueba (instantáneas, resolvedor sintético)
/// que no deben existir en el binario de producción.
fn addCoreNative(mod: *std.Build.Module, test_seams: bool) void {
    mod.addCSourceFiles(.{
        .files = &.{"core/src/external_cli_security.c"},
        .flags = if (test_seams) &.{ "-Wall", "-Wextra", "-Werror", "-DDA_TEST_SEAMS" } else &.{ "-Wall", "-Wextra", "-Werror" },
    });
    mod.linkSystemLibrary("advapi32", .{});
    mod.linkSystemLibrary("netapi32", .{});
    mod.linkSystemLibrary("wintrust", .{});
}

fn shellCppFlags(optimize: std.builtin.OptimizeMode) []const []const u8 {
    return if (optimize == .Debug) &.{
        "-std=c++17",
        "-DUNICODE",
        "-D_UNICODE",
    } else &.{
        "-std=c++17",
        "-DUNICODE",
        "-D_UNICODE",
        "-DNDEBUG",
    };
}

// H8/P3: transitive reachability over the build graph, so the
// generated distribution header reflects the real wiring of the steps
// instead of a comment that can silently go stale. R3-3: the visited set is
// an unbounded list on b.allocator — the old fixed [4096] array returned
// false silently on overflow, which would fake a true for the negative
// check !stepReaches(install, dist); OOM aborts the build instead.
fn stepReaches(b: *std.Build, origin: *std.Build.Step, needle: *std.Build.Step) bool {
    var visited: std.ArrayListUnmanaged(*std.Build.Step) = .empty;
    defer visited.deinit(b.allocator);
    return stepReachesInner(b.allocator, origin, needle, &visited);
}

fn stepReachesInner(
    gpa: std.mem.Allocator,
    current: *std.Build.Step,
    needle: *std.Build.Step,
    visited: *std.ArrayListUnmanaged(*std.Build.Step),
) bool {
    if (current == needle) return true;
    for (visited.items) |seen| {
        if (seen == current) return false;
    }
    visited.append(gpa, current) catch @panic("stepReaches: out of memory");
    for (current.dependencies.items) |dep| {
        if (stepReachesInner(gpa, dep, needle, visited)) return true;
    }
    return false;
}

/// T9: pasos sin cabina para destinos que no son Windows (ver la llamada en
/// `build`). Repite la forma de los pasos de Windows (MCP, key-admin, dobles de
/// prueba, envoltorio de la suite) sin las bibliotecas Win32.
const HeadlessInputs = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    core_test_mod: *std.Build.Module,
    providers_mod: *std.Build.Module,
    core_exe: *std.Build.Step.Compile,
    engine_exe: *std.Build.Step.Compile,
    cli_alias_install: *std.Build.Step.InstallFile,
};

fn addHeadlessSteps(b: *std.Build, in: HeadlessInputs) void {
    const target = in.target;
    const optimize = in.optimize;
    const test_filter = b.option([]const u8, "test-filter", "Filter test names");
    const filters: []const []const u8 = if (test_filter) |f| b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM") else &.{};
    const quiet_test_runner: std.Build.Step.Compile.TestRunner = .{
        .path = b.path("tools/quiet_test_runner.zig"),
        .mode = .server,
    };

    const mcp_server_mod = b.createModule(.{
        .root_source_file = b.path("tools/mcp_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mcp_server_mod.addImport("core", in.core_mod);
    const mcp_server_exe = b.addExecutable(.{ .name = "devagents-mcp", .root_module = mcp_server_mod });
    b.installArtifact(mcp_server_exe);

    const key_admin_mod = b.createModule(.{
        .root_source_file = b.path("tools/key_admin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    key_admin_mod.addImport("core", in.core_mod);
    key_admin_mod.addImport("providers", in.providers_mod);
    const key_admin_exe = b.addExecutable(.{ .name = "key-admin", .root_module = key_admin_mod });
    b.installArtifact(key_admin_exe);

    // Dobles de protocolo que la suite lanza desde el prefijo instalado.
    const mock_sources = [_][2][]const u8{
        .{ "mcp-mock-server", "tests/mcp_mock_server.zig" },
        .{ "cli-worker-mock", "tests/cli_worker_mock.zig" },
        .{ "acp-mock-agent", "tools/acp_mock_agent.zig" },
    };
    var mocks: [mock_sources.len]*std.Build.Step.Compile = undefined;
    for (mock_sources, 0..) |src, i| {
        const mod = b.createModule(.{ .root_source_file = b.path(src[1]), .target = target, .optimize = optimize, .link_libc = true });
        mocks[i] = b.addExecutable(.{ .name = src[0], .root_module = mod });
    }

    const core_tests = b.addTest(.{ .root_module = in.core_test_mod, .filters = filters, .test_runner = quiet_test_runner });
    const providers_tests = b.addTest(.{ .root_module = in.providers_mod, .filters = filters, .test_runner = quiet_test_runner });
    const mcp_tests = b.addTest(.{ .root_module = mcp_server_mod, .filters = filters, .test_runner = quiet_test_runner });

    const headless = b.step("headless", "Build CLI, engine, MCP and key-admin without the Windows shell");
    for ([_]*std.Build.Step.Compile{ in.core_exe, in.engine_exe, mcp_server_exe, key_admin_exe }) |exe|
        headless.dependOn(&b.addInstallArtifact(exe, .{}).step);
    headless.dependOn(&in.cli_alias_install.step);

    // Compila (y enlaza) sin ejecutar: es la verificacion en cruzado desde Windows.
    const check = b.step("check-headless", "Compile CLI, engine, MCP, key-admin, mocks and their tests without running them");
    for ([_]*std.Build.Step.Compile{ in.core_exe, in.engine_exe, mcp_server_exe, key_admin_exe, core_tests, providers_tests, mcp_tests }) |artifact|
        check.dependOn(&artifact.step);
    for (mocks) |mock| check.dependOn(&mock.step);
    const check_bins = b.step("check-headless-bin", "Compile CLI, engine, MCP and key-admin only (no tests)");
    for ([_]*std.Build.Step.Compile{ in.core_exe, in.engine_exe, mcp_server_exe, key_admin_exe }) |exe|
        check_bins.dependOn(&exe.step);

    // Ejecucion: mismo envoltorio que en Windows (servidor de fixtures en
    // 127.0.0.1 y cwd sintetico), con python3.
    const run_core = b.addRunArtifact(core_tests);
    run_core.has_side_effects = true;
    run_core.argv.insertSlice(b.allocator, 0, &.{
        .{ .bytes = b.dupe("python3") },
        .{ .bytes = b.pathFromRoot("tools/suite_native_fixture.py") },
        .{ .bytes = b.dupe("--native") },
    }) catch @panic("OOM");
    run_core.addFileInput(b.path("tools/suite_native_fixture.py"));
    run_core.addFileInput(b.path("tools/ordenes_fixture.py"));
    run_core.addFileInput(b.path("tests/fixtures/native-http-server.py"));
    const core_test_cwd = b.addWriteFiles();
    _ = core_test_cwd.add("fixture.marker", "T9 isolated POSIX core test cwd\n");
    _ = core_test_cwd.addCopyDirectory(b.path("tests/fixtures/discovery"), "tests/fixtures/discovery", .{});
    _ = core_test_cwd.addCopyDirectory(b.path("tests/fixtures/linked"), "tests/fixtures/linked", .{});
    _ = core_test_cwd.addCopyFile(b.path("tests/fixtures/checklist.txt"), "CHECKLIST.md");
    _ = core_test_cwd.addCopyFile(b.path("tests/fixtures/E5.20-falsas-alarmas-eventos-20261002.json"), "gov-recorded.json");
    run_core.setEnvironmentVariable("BEATS_GOV_RECORDED", b.pathFromRoot("tests/fixtures/E5.20-falsas-alarmas-eventos-20261002.json"));
    run_core.setCwd(core_test_cwd.getDirectory());
    run_core.setEnvironmentVariable("BEATS_TEST_BIN_DIR", b.getInstallPath(.bin, ""));
    for ([_]*std.Build.Step.Compile{ in.core_exe, in.engine_exe, mcp_server_exe } ++ mocks) |fixture|
        run_core.step.dependOn(&b.addInstallArtifact(fixture, .{}).step);

    const run_providers = b.addRunArtifact(providers_tests);
    run_providers.has_side_effects = true;
    run_providers.argv.insertSlice(b.allocator, 0, &.{
        .{ .bytes = b.dupe("python3") },
        .{ .bytes = b.pathFromRoot("tools/sec_red_http_fixture.py") },
        .{ .bytes = b.dupe("--allow-unused") },
    }) catch @panic("OOM");
    run_providers.addFileInput(b.path("tools/sec_red_http_fixture.py"));
    const run_mcp = b.addRunArtifact(mcp_tests);
    run_mcp.has_side_effects = true;
    // T9 fase B: como en la suite de Windows, el MCP corre con cwd, TEMP y
    // datos en una carpeta temporal propia (el repo puede estar de solo lectura).
    run_mcp.argv.insertSlice(b.allocator, 0, &.{
        .{ .bytes = b.dupe("python3") },
        .{ .bytes = b.pathFromRoot("tools/suite_native_fixture.py") },
    }) catch @panic("OOM");
    run_mcp.addFileInput(b.path("tools/suite_native_fixture.py"));

    const test_headless = b.step("test-headless", "Run core, provider and MCP tests without the Windows shell");
    test_headless.dependOn(&run_core.step);
    test_headless.dependOn(&run_providers.step);
    test_headless.dependOn(&run_mcp.step);
    const test_core = b.step("test-core", "Run core tests without the Windows shell");
    test_core.dependOn(&run_core.step);
    const test_mcp = b.step("test-mcp", "Run MCP server contract tests");
    test_mcp.dependOn(&run_mcp.step);
    // `zig build test` fuera de Windows es la suite sin cabina.
    b.step("test", "Run headless tests (Windows shell excluded)").dependOn(test_headless);
}

/// T9: contencion POSIX (grupo de procesos, setrlimit, cgroup v2 delegado) en C.
fn addCorePosix(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addCSourceFiles(.{
        .files = &.{"core/src/governed_posix.c"},
        .flags = &.{ "-Wall", "-Wextra", "-Werror" },
    });
}
