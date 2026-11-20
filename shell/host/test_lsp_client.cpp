// Estas pruebas se apoyan en DA_CHECK(): ningún modo de optimización (NDEBUG)
// las puede compilar fuera. Debe ir antes de cualquier #include.
#include "lsp_client.hpp"
#include "test_check.hpp"
#include <iostream>

void test_lsp_client_lifecycle() {
  beats::LspClient lsp;
  bool started = lsp.Start(
      L"cmd.exe /c echo Content-Length: "
      L"42\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}",
      [](const std::string &jsonRpcMsg) {
        // std::cout << "[LSP RECV] " << jsonRpcMsg << "\n";
      });
  // Un comando de shell no es un servidor registrado, ni siquiera desde el
  // arranque directo del cliente. No llega a CreateProcessW.
  DA_CHECK(!started);
  DA_CHECK(!lsp.IsRunning());
  std::cout << "[PASS] LSP rechaza comandos arbitrarios\n";

  bool sent = lsp.SendRequest(1, "initialize", "{\"rootUri\":null}");
  DA_CHECK(!sent);
  std::cout << "[PASS] LSP sin servidor no envia solicitudes\n";

  lsp.Stop();
  DA_CHECK(!lsp.IsRunning());
  std::cout << "[PASS] LSP client stop test\n";
}

int main() {
  test_lsp_client_lifecycle();
  std::cout << "ALL LSP CLIENT TESTS PASSED!\n";
  return 0;
}
