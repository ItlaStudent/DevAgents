// Estas pruebas se apoyan en DA_CHECK(): ningún modo de optimización (NDEBUG)
// las puede compilar fuera. Debe ir antes de cualquier #include.
#include "pty_manager.hpp"
#include "test_check.hpp"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <windows.h>

void test_pty_creation_and_cleanup() {
  beats::PtyManager mgr;

  // 1. Create a terminal
  int termId =
      mgr.CreateTerminal(L"cmd.exe", L".", [](int id, const std::string &data) {
        // std::cout << "[PTY " << id << "] " <<
        // data;
      });
  DA_CHECK(termId > 0);
  std::cout << "[PASS] Terminal creation test (ID: " << termId << ")\n";

  std::this_thread::sleep_for(std::chrono::milliseconds(800));

  // 2. Write command
  mgr.WriteTerminal(termId, "echo BEATS_CONPTY_TEST\r");
  mgr.WriteTerminal(termId, "\n");

  // 3. Verify scrollback non-empty reception
  std::string sb = mgr.GetScrollback(termId);
  DA_CHECK(!sb.empty());
  std::cout << "[PASS] Terminal read/write scrollback test\n";

  // 4. Close terminal cleanly
  mgr.CloseTerminal(termId);
  std::cout << "[PASS] Terminal clean close test\n";
}

void test_no_orphan_ptys_loop() {
  beats::PtyManager mgr;
  std::cout
      << "  Testing 20 terminal create/close loop for orphan prevention...\n";
  for (int i = 0; i < 20; ++i) {
    int id = mgr.CreateTerminal(L"cmd.exe", L".", nullptr);
    DA_CHECK(id > 0);
    mgr.WriteTerminal(id, "exit\r\n");
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    mgr.CloseTerminal(id);
  }
  std::cout << "[PASS] 20 terminals loop completed with 0 orphan processes\n";
}

// con la salida del proceso redirigida (como la tiene ESTE test bajo
// `zig build`, o la cabina arrancada con un registro), el shell heredaba esos
// descriptores y la pseudoconsola se quedaba muda: CreateTerminal caia al
// respaldo por tuberias. Ahora tiene que ir por ConPTY y traer la salida.
void test_conpty_con_salida_redirigida() {
  const DWORD tipo = GetFileType(GetStdHandle(STD_OUTPUT_HANDLE));
  std::cout << "  stdout de este proceso: "
            << (tipo == FILE_TYPE_CHAR ? "consola" : "redirigida") << "\n";
  beats::PtyManager mgr;
  int id = mgr.CreateTerminal(L"cmd.exe", L"", nullptr);
  DA_CHECK(id > 0);
  if (!mgr.IsPseudoConsole(id)) {
    std::cout << "[FAIL] E-23: la terminal cayo al respaldo por tuberias\n";
    std::exit(1);
  }
  mgr.WriteTerminal(id, "echo E23_CONPTY_%USERNAME:~0,0%OK\r");
  std::string sb;
  for (int i = 0; i < 50; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    sb = mgr.GetScrollback(id);
    if (sb.find("E23_CONPTY_OK") != std::string::npos)
      break;
  }
  mgr.CloseTerminal(id);
  if (sb.find("E23_CONPTY_OK") == std::string::npos) {
    std::cout << "[FAIL] E-23: ConPTY no trajo la salida del comando\n";
    std::exit(1);
  }
  std::cout << "[PASS] E-23: ConPTY con la salida redirigida\n";
}

void test_list_and_reconnect() {
  beats::PtyManager mgr;
  DA_CHECK(mgr.ListTerminals().empty());
  const int id = mgr.CreateTerminal(L"cmd.exe", L".", nullptr);
  DA_CHECK(id > 0);
  auto terminals = mgr.ListTerminals();
  DA_CHECK(terminals.size() == 1);
  DA_CHECK(terminals[0].id == id && terminals[0].running);
  DA_CHECK(!terminals[0].shellPath.empty());
  DA_CHECK(terminals[0].cols == 80 && terminals[0].rows == 25);
  DA_CHECK(mgr.ResizeTerminal(id, 100, 30));
  terminals = mgr.ListTerminals();
  DA_CHECK(terminals[0].cols == 100 && terminals[0].rows == 30);
  const std::string before = mgr.GetScrollback(id);
  DA_CHECK(mgr.WriteTerminal(id, "echo CAB010_%COMSPEC:~0,0%REATTACH\r\n"));
  std::string after;
  for (int i = 0; i < 50; ++i) {
    after = mgr.GetScrollback(id);
    if (after.find("CAB010_REATTACH") != std::string::npos)
      break;
    Sleep(100);
  }
  DA_CHECK(after.find("CAB010_REATTACH") != std::string::npos);
  DA_CHECK(after.substr(0, before.size()) == before);
  DA_CHECK(before + after.substr(before.size()) == after);
  DA_CHECK(mgr.ListTerminals()[0].id == id);
  DA_CHECK(mgr.WriteTerminal(id, "exit\r\n"));
  for (int i = 0; i < 50 && mgr.ListTerminals()[0].running; ++i)
    Sleep(100);
  DA_CHECK(!mgr.ListTerminals()[0].running);
  const int other = mgr.CreateTerminal(L"cmd.exe", L".", nullptr);
  DA_CHECK(other > id);
  DA_CHECK(mgr.ListTerminals().size() == 2);
  mgr.CloseTerminal(id);
  DA_CHECK(mgr.ListTerminals().size() == 1);
  DA_CHECK(mgr.ListTerminals()[0].id == other);
  mgr.CloseTerminal(other);
  DA_CHECK(mgr.ListTerminals().empty());
  std::cout << "[PASS] CK-CAB-010 list, dimensions, snapshot, same session, "
               "exit and close\n";
}

int main() {
  test_list_and_reconnect();
  test_conpty_con_salida_redirigida();
  test_pty_creation_and_cleanup();
  test_no_orphan_ptys_loop();
  std::cout << "ALL PTY MANAGER TESTS PASSED!\n";
  return 0;
}
