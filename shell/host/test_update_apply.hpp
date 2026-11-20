#pragma once
// Tanda 5 (F0.4): aplicar la actualización al cerrar. Pruebas de las piezas
// del host que deciden: la respuesta del motor, los procesos que bloquean y
// la línea de órdenes del instalador. El lanzamiento real no se prueba aquí:
// ejecutaría un instalador.
#include "test_check.hpp"
#include "update_apply.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

static void test_update_apply() {
  using beats::update::BlockingProcesses;
  using beats::update::InstallerCommandLine;
  using beats::update::ParsePendingApply;
  using beats::update::ProcessEntry;

  // Respuesta del motor.
  auto ok = ParsePendingApply(
      "{\"apply\":true,\"path\":\"C:\\\\Datos\\\\updates\\\\0.2.0\\\\"
      "DevAgents-Setup-v0.2.0.exe\",\"sha256\":"
      "\"BA7816BF8F01CFEA414140DE5DAE2223B"
      "00361A396177A9CB410FF61F20015AD\",\"reason\":\"lista para instalar al "
      "cerrar\"}");
  DA_CHECK(ok.valid && ok.apply);
  DA_CHECK(ok.sha256 ==
           "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  // T12 M3: sin huella (o mal formada) no hay con qué recomprobar: no vale.
  DA_CHECK(!ParsePendingApply("{\"apply\":true,\"path\":\"C:\\\\Datos\\\\"
                              "updates\\\\s.exe\",\"reason\":\"x\"}")
                .valid);
  DA_CHECK(!ParsePendingApply("{\"apply\":true,\"path\":\"C:\\\\Datos\\\\"
                              "updates\\\\s.exe\",\"sha256\":\"abc\","
                              "\"reason\":\"x\"}")
                .valid);
  DA_CHECK(ok.path == L"C:\\Datos\\updates\\0.2.0\\DevAgents-Setup-v0.2.0.exe");
  auto no = ParsePendingApply("{\"apply\":false,\"path\":null,\"reason\":\"hay "
                              "órdenes en curso: se instalará en el próximo "
                              "cierre\"}");
  DA_CHECK(no.valid && !no.apply && no.path.empty());
  DA_CHECK(no.reason.find("órdenes en curso") != std::string::npos);
  // apply sin ruta, ruta relativa o de red, o JSON roto: no se lanza nada.
  DA_CHECK(!ParsePendingApply("{\"apply\":true,\"path\":null,\"reason\":\"x\"}")
                .valid);
  DA_CHECK(!ParsePendingApply(
                "{\"apply\":true,\"path\":\"setup.exe\",\"reason\":\"x\"}")
                .valid);
  DA_CHECK(!ParsePendingApply("{\"apply\":true,\"path\":\"\\\\\\\\srv\\\\s\\\\"
                              "setup.exe\",\"reason\":\"x\"}")
                .valid);
  DA_CHECK(!ParsePendingApply("{\"apply\":\"true\"}").valid);
  DA_CHECK(!ParsePendingApply("no es json").valid);
  std::cout << "[PASS] T5 actualizador: respuesta de pending_apply\n";

  // Procesos que impiden aplicar.
  const std::wstring dir =
      L"C:\\Workspace\\u\\AppData\\Local\\Programs\\DevAgents";
  auto entry = [](DWORD pid, DWORD parent, const wchar_t *name,
                  const std::wstring &path, bool known = true) {
    ProcessEntry p;
    p.pid = pid;
    p.parent = parent;
    p.exeName = name;
    p.imagePath = path;
    p.pathKnown = known;
    return p;
  };
  std::vector<ProcessEntry> all = {
      entry(100, 4, L"devagents-host.exe", dir + L"\\devagents-host.exe"),
      // Hijo del host (motor en su job) y nieto: mueren con él.
      entry(101, 100, L"devagents-engine.exe", dir + L"\\devagents-engine.exe"),
      entry(102, 101, L"devagents-core.exe", dir + L"\\devagents-core.exe"),
      // De otra carpeta (copia de desarrollo): no impide.
      entry(200, 4, L"devagents-host.exe",
            L"E:\\dev\\zig-out\\bin\\devagents-host.exe"),
      entry(300, 4, L"notepad.exe", L"C:\\Windows\\notepad.exe"),
  };
  DA_CHECK(BlockingProcesses(all, 100, dir).empty());
  // Un devagents-mcp.exe que lanzó otra IDE, desde la carpeta instalada.
  all.push_back(
      entry(400, 77, L"DevAgents-MCP.exe", dir + L"\\devagents-mcp.exe"));
  auto blocking = BlockingProcesses(all, 100, dir + L"\\");
  DA_CHECK(blocking.size() == 1 && blocking[0].pid == 400);
  // Ruta ilegible: no se puede descartar, bloquea.
  all.back() = entry(400, 77, L"devagents-mcp.exe", L"", false);
  blocking = BlockingProcesses(all, 100, dir);
  DA_CHECK(blocking.size() == 1 && blocking[0].pid == 400);
  std::cout << "[PASS] T5 actualizador: procesos que impiden aplicar\n";

  // Línea de órdenes: ruta entre comillas y modo silencioso de actualización.
  DA_CHECK(InstallerCommandLine(L"C:\\Mis datos\\updates\\0.2.0\\Setup.exe",
                                L"C:\\Mis datos\\updates\\install.log") ==
           L"\"C:\\Mis datos\\updates\\0.2.0\\Setup.exe\" /VERYSILENT "
           L"/SUPPRESSMSGBOXES /NORESTART /UPDATE \"/LOG=C:\\Mis "
           L"datos\\updates\\install.log\"");
  // La foto real de procesos funciona y este proceso está en ella.
  bool snapOk = false;
  const auto snap = beats::update::SnapshotProcesses(snapOk);
  DA_CHECK(snapOk);
  bool self = false;
  for (const auto &p : snap)
    self = self || p.pid == GetCurrentProcessId();
  DA_CHECK(self);
  std::cout << "[PASS] T5 actualizador: línea del instalador y foto real\n";

  // T12 M3: justo antes de lanzar, ruta confinada en <datos>\updates\ y
  // huella releída con el archivo bloqueado (sin escritura ni borrado).
  {
    using beats::update::OpenVerifiedInstaller;
    namespace fs = std::filesystem;
    wchar_t tmpBuf[MAX_PATH];
    DA_CHECK(GetTempPathW(MAX_PATH, tmpBuf) > 0);
    const fs::path data =
        fs::path(tmpBuf) /
        (L"devagents-t12-m3-" + std::to_wstring(GetCurrentProcessId()));
    fs::remove_all(data);
    fs::create_directories(data / L"updates" / L"0.2.0");
    fs::create_directories(data / L"otra");
    const fs::path inside = data / L"updates" / L"0.2.0" / L"setup.exe";
    const fs::path outside = data / L"otra" / L"setup.exe";
    for (const auto &target : {inside, outside}) {
      std::ofstream f(target, std::ios::binary);
      f << "abc";
    }
    const std::string abc =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    std::string why;
    HANDLE held =
        OpenVerifiedInstaller(inside.wstring(), data.wstring(), abc, why);
    DA_CHECK(held != INVALID_HANDLE_VALUE);
    // Mientras está abierto, nadie lo cambia ni lo borra.
    HANDLE writer =
        CreateFileW(inside.c_str(), GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    nullptr, OPEN_EXISTING, 0, nullptr);
    DA_CHECK(writer == INVALID_HANDLE_VALUE &&
             GetLastError() == ERROR_SHARING_VIOLATION);
    DA_CHECK(!DeleteFileW(inside.c_str()));
    CloseHandle(held);
    // Otra huella: no.
    why.clear();
    DA_CHECK(OpenVerifiedInstaller(inside.wstring(), data.wstring(),
                                   std::string(64, 'a'),
                                   why) == INVALID_HANDLE_VALUE);
    DA_CHECK(why.find("no coincide") != std::string::npos);
    // Fuera de updates\ (aunque la huella coincida), también con ..: no.
    for (const auto &bad :
         {outside.wstring(),
          (data / L"updates" / L".." / L"otra" / L"setup.exe").wstring()}) {
      why.clear();
      DA_CHECK(OpenVerifiedInstaller(bad, data.wstring(), abc, why) ==
               INVALID_HANDLE_VALUE);
      DA_CHECK(why.find("fuera de la carpeta de descargas") !=
               std::string::npos);
    }
    // Sin carpeta de datos o sin huella válida: no.
    DA_CHECK(OpenVerifiedInstaller(inside.wstring(), L"", abc, why) ==
             INVALID_HANDLE_VALUE);
    DA_CHECK(OpenVerifiedInstaller(inside.wstring(), data.wstring(), "xyz",
                                   why) == INVALID_HANDLE_VALUE);
    fs::remove_all(data);
    std::cout << "[PASS] T12 M3 actualizador: ruta confinada y huella "
                 "releída con el archivo bloqueado\n";
  }
}
