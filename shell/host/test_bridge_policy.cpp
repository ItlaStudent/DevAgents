// Estas pruebas se apoyan en DA_CHECK(): ningún modo de optimización (NDEBUG)
// las puede compilar fuera. Debe ir antes de cualquier #include.
#include "shell_policy.hpp"
#include "test_check.hpp"
#include <iostream>

int main(int argc, char **argv) {
  using namespace beats::security;
  std::wstring path;
  if (argc == 2 && std::string(argv[1]) == "--workspace-lsp") {
    DA_CHECK(!ResolveLsp(L"cpp", path));
    std::cout << "[PASS] un binario LSP en PATH del workspace no se registra\n";
    return 0;
  }
  DA_CHECK(ResolveShell(L"cmd.exe", path));
  DA_CHECK(path.size() > 3 && path[1] == L':');
  const std::wstring cmd = path;
  DA_CHECK(ResolveShell(cmd, path) && path == cmd);
  wchar_t temp[32768];
  DA_CHECK(GetTempPathW(32768, temp) > 0);
  const std::wstring fixture = std::wstring(temp) + L"beats-lsp-policy-" +
                               std::to_wstring(GetCurrentProcessId());
  struct Cleanup {
    std::wstring root;
    ~Cleanup() {
      DA_CHECK(DeleteFileW((root + L"\\clangd.exe").c_str()));
      DA_CHECK(RemoveDirectoryW(root.c_str()));
    }
  };
  // Se construye antes del registro estático: éste libera sus pins primero.
  static Cleanup cleanup{fixture};
  DA_CHECK(CreateDirectoryW(fixture.c_str(), nullptr));
  const auto lspExe = fixture + L"\\clangd.exe";
  DA_CHECK(CopyFileW(cmd.c_str(), lspExe.c_str(), TRUE));
  const auto oldPath = HostEnvironment(L"PATH");
  DA_CHECK(SetEnvironmentVariableW(L"PATH", fixture.c_str()));
  wchar_t self[32768];
  DA_CHECK(GetModuleFileNameW(nullptr, self, 32768) > 0);
  std::wstring childCommand =
      L"\"" + std::wstring(self) + L"\" --workspace-lsp";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION child{};
  DA_CHECK(CreateProcessW(self, childCommand.data(), nullptr, nullptr, FALSE, 0,
                          nullptr, fixture.c_str(), &startup, &child));
  DA_CHECK(WaitForSingleObject(child.hProcess, 10000) == WAIT_OBJECT_0);
  DWORD childExit = 1;
  DA_CHECK(GetExitCodeProcess(child.hProcess, &childExit) && childExit == 0);
  CloseHandle(child.hThread);
  CloseHandle(child.hProcess);
  DA_CHECK(ResolveLsp(L"cpp", path) && EqualPath(path, lspExe));
  DA_CHECK(ResolveLsp(L"clangd.exe", path) && EqualPath(path, lspExe));
  DA_CHECK(ResolveLsp(lspExe, path) && EqualPath(path, lspExe));
  DA_CHECK(SetEnvironmentVariableW(L"PATH", oldPath.c_str()));
  // La copia sólo prueba resolución; jamás se ejecuta como servidor.
  DA_CHECK(!DeleteFileW(lspExe.c_str()) &&
           GetLastError() == ERROR_SHARING_VIOLATION);
  HANDLE overwrite =
      CreateFileW(lspExe.c_str(), GENERIC_WRITE,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_EXISTING, 0, nullptr);
  DA_CHECK(overwrite == INVALID_HANDLE_VALUE &&
           GetLastError() == ERROR_SHARING_VIOLATION);
  for (const auto *value :
       {L"cmd.exe /c calc.exe", L"C:\\evil.exe", L"..\\cmd.exe",
        L"\\\\server\\cmd.exe", L"powershell -Command calc", L"bash -c calc"})
    DA_CHECK(!ResolveShell(value, path));
  for (const auto *value : {L"cmd.exe", L"clangd.exe --evil", L"C:\\evil.exe",
                            L"node -e evil", L"\\\\server\\zls.exe"})
    DA_CHECK(!ResolveLsp(value, path));
  DA_CHECK(IsKnownLsp(L"cpp"));
  DA_CHECK(IsKnownLsp(L"zls.exe"));
  DA_CHECK(!IsKnownLsp(L"cmd.exe"));
  DA_CHECK(ClassifyOpenTarget(L"https://example.com/a") == OpenTarget::Browser);
  DA_CHECK(ClassifyOpenTarget(L"http://localhost:3000/") ==
           OpenTarget::Browser);
  DA_CHECK(ClassifyOpenTarget(L"http://127.0.0.1:3000/") ==
           OpenTarget::Browser);
  for (const auto *url :
       {L"http://example.com/", L"http://localhost.evil/", L"http://127.0.0.2/",
        L"http://2130706433/", L"http://127.1/", L"http://%6cocalhost/",
        L"http://user@localhost/", L"http://localhost:0/"})
    DA_CHECK(ClassifyOpenTarget(url) == OpenTarget::Reject);
  std::vector<std::wstring> args;
  DA_CHECK(OpenDesignArguments(L"Ubuntu-24.04", L"/home/user/open design",
                               false, args));
  DA_CHECK(args == (std::vector<std::wstring>{L"-d", L"Ubuntu-24.04", L"--cd",
                                              L"/home/user/open design", L"--",
                                              L"/usr/bin/env", L"pnpm",
                                              L"tools-dev", L"status"}));
  DA_CHECK(OpenDesignArguments(L"Ubuntu", L"/root/open-design", true, args));
  DA_CHECK(args.back() == L"web");
  for (const auto *distro :
       {L"Ubuntu\" -e calc", L"-Ubuntu", L"Ubuntu;evil", L"Ubuntu$(evil)",
        L"Ubuntu\nother", L"Ubuntu&evil", L"Ubuntu/evil", L"Ubuntu`evil`"})
    DA_CHECK(!OpenDesignArguments(distro, L"/root/open-design", false, args) &&
             args.empty());
  for (const auto *dir :
       {L"~/open-design", L"relative/path", L"/tmp/$(evil)", L"/tmp/`evil`",
        L"/tmp/x;evil", L"/tmp/x&evil", L"/tmp/\"evil", L"/tmp/x\nevil",
        L"/tmp/../evil", L"/tmp//evil", L"/tmp/evil|cat", L"/tmp/'evil",
        L"/tmp/evil>file", L"/tmp/evil\\file"})
    DA_CHECK(!OpenDesignArguments(L"Ubuntu", dir, false, args) && args.empty());
  for (const auto &arg :
       {std::wstring(L""), std::wstring(L"space in path"),
        std::wstring(L"C:\\path\\"), std::wstring(L"embedded\"quote")}) {
    int count = 0;
    const auto line = L"program " + QuoteArgument(arg);
    auto parsed = CommandLineToArgvW(line.c_str(), &count);
    DA_CHECK(parsed && count == 2 && parsed[1] == arg);
    LocalFree(parsed);
  }
  std::cout << "[PASS] Open Design structured argv/22 hostile env values/CRT "
               "quoting; HTTP loopback only\n";
  DA_CHECK(ClassifyOpenTarget(L"C:\\test.exe") == OpenTarget::Reveal);
  for (const auto *value :
       {L"file:///C:/test.exe", L"file:///C:/test.bat", L"file:///C:/test.lnk",
        L"javascript:alert(1)", L"data:text/html,evil", L"C:\\a\" /evil",
        L"\\\\server\\file.exe", L"C:\\a:stream",
        L"https://example.com\r\nevil"})
    DA_CHECK(ClassifyOpenTarget(value) == OpenTarget::Reject);
  // Lote 1 (SEC-WEBVIEW): revelar también exige la gramática estricta de rutas
  // del puente. Dispositivos Win32, traversal, flujos y espacios de nombres
  // de dispositivo/extendidos/UNC no llegan a explorer.exe.
  for (const auto *value : {L"C:\\NUL",
                            L"C:\\dir\\CON",
                            L"C:\\dir\\con.txt",
                            L"C:\\dir\\COM1",
                            L"C:\\dir\\LPT9.log",
                            L"C:\\dir\\AUX",
                            L"C:\\dir\\PRN.x",
                            L"C:\\a\\..\\b",
                            L"C:\\a\\.\\b",
                            L"C:\\a\\..",
                            L"C:\\a\\b.",
                            L"C:\\a\\b ",
                            L"C:\\a\\\\b",
                            L"\\\\.\\NUL",
                            L"\\\\.\\CON",
                            L"\\\\?\\C:\\a\\b.txt",
                            L"\\\\?\\UNC\\server\\share\\b.txt",
                            L"\\\\localhost\\c$\\x",
                            L"C:",
                            L"C:\\",
                            L"C:a\\b",
                            L"1:\\a",
                            L"C:\\a\\b*.txt",
                            L"C:\\a\\b?.txt",
                            L"C:\\a\\b|c",
                            L"C:\\a\\b<c",
                            L"C:\\a\\b:ads"})
    DA_CHECK(ClassifyOpenTarget(value) == OpenTarget::Reject);
  std::wstring revealed;
  DA_CHECK(CanonicalRevealPath(L"C:/Workspace/x/captura 1.png", revealed) &&
           revealed == L"C:\\Workspace\\x\\captura 1.png");
  DA_CHECK(CanonicalRevealPath(L"c:\\carpeta\\sub\\", revealed) &&
           revealed == L"c:\\carpeta\\sub");
  DA_CHECK(ClassifyOpenTarget(L"C:\\Workspace\\x\\captura 1.png") ==
           OpenTarget::Reveal);
  DA_CHECK(!RevealLocalPath(L"C:\\NUL") && !RevealLocalPath(L"C:\\a\\..\\b") &&
           !RevealLocalPath(L"\\\\.\\CON"));
  std::cout << "[PASS] shell.open: revelar rechaza dispositivos Win32, "
               "traversal, flujos y espacios de nombres\n";
  std::cout << "[PASS] shells/LSP: registro del host y comandos rechazados\n"
               "[PASS] shell.open: http(s), revelar y protocolos rechazados\n";
}
