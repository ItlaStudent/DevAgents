#ifndef BEATS_SHELL_POLICY_HPP
#define BEATS_SHELL_POLICY_HPP

#include "confined_write.hpp"
#include "origin_policy.hpp"
#include <cstdio>
#include <memory>
#include <shellapi.h>
#include <string>
#include <vector>
#include <windows.h>

namespace beats::security {

inline bool EqualPath(const std::wstring &a, const std::wstring &b) {
  return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}

// GetFullPathNameW conserva nombres cortos 8.3 (p. ej. RUNNER~1) mientras que
// GetFinalPathNameByHandleW los resuelve a su forma larga; sin normalizar,
// EqualPath rechaza el mismo archivo. GetLongPathNameW unifica ambas formas.
inline std::wstring CanonicalLongPath(const std::wstring &in) {
  if (in.size() >= 32767)
    return in;
  std::wstring out(32768, L'\0');
  const DWORD n =
      GetLongPathNameW(in.c_str(), out.data(), static_cast<DWORD>(out.size()));
  if (!n || n >= out.size())
    return in;
  out.resize(n);
  return out;
}

inline std::wstring HostEnvironment(const wchar_t *name) {
  const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  if (!size)
    return {};
  std::wstring value(size, L'\0');
  const DWORD read = GetEnvironmentVariableW(name, value.data(), size);
  if (!read || read >= size)
    return {};
  value.resize(read);
  return value;
}

// No se busca en cwd ni se aceptan shims: un nombre conocido no debe acabar
// ejecutando un binario del workspace o comandos a través de cmd.exe.
inline bool VerifiedExecutable(const std::wstring &candidate,
                               std::wstring &path,
                               std::shared_ptr<confined::LockedPath> &pin) {
  const bool dbg = GetEnvironmentVariableW(L"DA_LSP_DEBUG", nullptr, 0) > 0;
  if (candidate.size() < 3 || candidate[1] != L':' || candidate[2] != L'\\' ||
      candidate.find_first_of(L"\"\r\n") != std::wstring::npos) {
    if (dbg)
      std::fwprintf(stderr, L"[verified] candidato invalido: %s\n",
                    candidate.c_str());
    return false;
  }
  const DWORD count = GetFullPathNameW(candidate.c_str(), 0, nullptr, nullptr);
  if (!count)
    return false;
  std::wstring full(count, L'\0');
  const DWORD read =
      GetFullPathNameW(candidate.c_str(), count, full.data(), nullptr);
  if (!read || read >= count)
    return false;
  full.resize(read);
  full = CanonicalLongPath(full);
  if (dbg)
    std::fwprintf(stderr, L"[verified] full=%s\n", full.c_str());
  auto locked = std::make_shared<confined::LockedPath>();
  if (!confined::LockParents(full, *locked, false)) {
    if (dbg)
      std::fwprintf(stderr, L"[verified] LockParents rechaza %s\n",
                    full.c_str());
    return false;
  }
  HANDLE file = CreateFileW(full.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES,
                            FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return false;
  locked->handles.push_back(file);
  BY_HANDLE_FILE_INFORMATION info{};
  std::wstring finalPath(32768, L'\0');
  const DWORD finalSize = GetFinalPathNameByHandleW(
      file, finalPath.data(), static_cast<DWORD>(finalPath.size()),
      FILE_NAME_NORMALIZED);
  const bool regular =
      GetFileInformationByHandle(file, &info) &&
      !(info.dwFileAttributes &
        (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
  if (!regular || !finalSize || finalSize >= finalPath.size())
    return false;
  finalPath.resize(finalSize);
  if (finalPath.rfind(L"\\\\?\\", 0) == 0)
    finalPath.erase(0, 4);
  finalPath = CanonicalLongPath(finalPath);
  if (dbg)
    std::fwprintf(stderr, L"[verified] full=%s final=%s equal=%d regular=%d\n",
                  full.c_str(), finalPath.c_str(),
                  EqualPath(full, finalPath) ? 1 : 0, regular ? 1 : 0);
  if (!EqualPath(full, finalPath))
    return false;
  path = std::move(finalPath);
  // Retener archivo y ancestros impide sustituir o reescribir la entrada
  // entre el registro, una petición JS y CreateProcessW, también por hardlink.
  pin = std::move(locked);
  return true;
}

struct HostProgram {
  std::wstring key;
  std::wstring executable;
  std::shared_ptr<confined::LockedPath> pin;
};

inline const std::vector<HostProgram> &ShellRegistry() {
  static const std::vector<HostProgram> registry = [] {
    std::vector<HostProgram> result;
    wchar_t system[32768];
    const UINT size = GetSystemDirectoryW(system, 32768);
    if (!size || size >= 32768)
      return result;
    const std::wstring systemDir(system, size);
    const std::wstring programFiles = HostEnvironment(L"ProgramFiles");
    const std::wstring local = HostEnvironment(L"LOCALAPPDATA");
    const auto add = [&](const wchar_t *key, const std::wstring &candidate) {
      std::wstring executable;
      std::shared_ptr<confined::LockedPath> pin;
      if (VerifiedExecutable(candidate, executable, pin))
        result.push_back({key, executable, std::move(pin)});
    };
    add(L"cmd", systemDir + L"\\cmd.exe");
    add(L"powershell",
        systemDir + L"\\WindowsPowerShell\\v1.0\\powershell.exe");
    if (!programFiles.empty()) {
      add(L"pwsh", programFiles + L"\\PowerShell\\7\\pwsh.exe");
      add(L"bash", programFiles + L"\\Git\\bin\\bash.exe");
    }
    if (!local.empty())
      add(L"bash", local + L"\\Programs\\Git\\bin\\bash.exe");
    return result;
  }();
  return registry;
}

inline bool ResolveShell(const std::wstring &selector, std::wstring &path) {
  const std::wstring key = selector.empty() ? L"cmd" : selector;
  for (const auto &program : ShellRegistry()) {
    if (EqualPath(key, program.key) || EqualPath(key, program.key + L".exe") ||
        EqualPath(key, program.executable)) {
      path = program.executable;
      return true;
    }
  }
  path.clear();
  return false;
}

inline const wchar_t *LspExecutable(const std::wstring &selector) {
  // El registro define lenguajes y ejecutables; nunca argumentos del emisor.
  if (selector == L"c" || selector == L"cpp" || selector == L"clangd.exe")
    return L"clangd.exe";
  if (selector == L"zig" || selector == L"zls.exe")
    return L"zls.exe";
  if (selector == L"rust" || selector == L"rust-analyzer.exe")
    return L"rust-analyzer.exe";
  if (selector == L"python" || selector == L"pylsp.exe")
    return L"pylsp.exe";
  return nullptr;
}

inline bool IsKnownLsp(const std::wstring &selector) {
  return LspExecutable(selector) != nullptr;
}

inline const std::vector<HostProgram> &LspRegistry() {
  static const std::vector<HostProgram> registry = [] {
    std::vector<HostProgram> result;
    const auto searchPath = HostEnvironment(L"PATH");
    wchar_t cwdBuffer[32768];
    const DWORD cwdSize = GetCurrentDirectoryW(32768, cwdBuffer);
    if (!cwdSize || cwdSize >= 32768)
      return result;
    const std::wstring workspace(cwdBuffer, cwdSize);
    for (const auto *key : {L"cpp", L"zig", L"rust", L"python"}) {
      size_t start = 0;
      while (start < searchPath.size()) {
        const size_t end = searchPath.find(L';', start);
        auto dir = searchPath.substr(start, end - start);
        if (dir.size() > 1 && dir.front() == L'"' && dir.back() == L'"')
          dir = dir.substr(1, dir.size() - 2);
        std::wstring executable;
        std::shared_ptr<confined::LockedPath> pin;
        // PATH viene del proceso nativo; se excluye el workspace aunque se
        // haya añadido a PATH. Un proyecto no es una instalación de LSP.
        if (!EqualPath(dir, workspace) && !confined::Inside(workspace, dir) &&
            VerifiedExecutable(dir + L"\\" + LspExecutable(key), executable,
                               pin) &&
            !confined::Inside(workspace, executable)) {
          result.push_back({key, executable, std::move(pin)});
          break;
        }
        if (end == std::wstring::npos)
          break;
        start = end + 1;
      }
    }
    return result;
  }();
  return registry;
}

inline bool ResolveLsp(const std::wstring &selector, std::wstring &path) {
  const auto *name = LspExecutable(selector);
  for (const auto &program : LspRegistry()) {
    if ((name && std::wstring(name) == LspExecutable(program.key)) ||
        EqualPath(selector, program.executable)) {
      path = program.executable;
      return true;
    }
  }
  path.clear();
  return false;
}

enum class OpenTarget { Reject, Browser, Reveal };

inline bool IsCabinBrowserUrl(const std::wstring &url) {
  HttpOrigin origin;
  if (!ParseHttpUrl(url, origin))
    return false;
  if (origin.scheme == L"https")
    return true;
  // Open Design returns this loopback URL. Do not accept numeric aliases,
  // encoded hosts, LAN services or a prefix such as localhost.attacker.
  const size_t begin = url.find(L"://") + 3;
  const size_t end = url.find_first_of(L"/?#", begin);
  const auto authority = url.substr(begin, end - begin);
  const auto host = authority.substr(0, authority.find(L':'));
  return (host == L"localhost" || host == L"127.0.0.1") &&
         (origin.host == L"localhost" || origin.host == L"127.0.0.1");
}

inline bool OpenDesignArguments(const std::wstring &distro,
                                const std::wstring &directory, bool start,
                                std::vector<std::wstring> &args) {
  args.clear();
  const auto alphaNum = [](wchar_t c) {
    return (c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z') ||
           (c >= L'0' && c <= L'9');
  };
  if (distro.empty() || distro.size() > 128 || !alphaNum(distro.front()) ||
      directory.empty() || directory.size() > 4096 || directory.front() != L'/')
    return false;
  for (wchar_t c : distro)
    if (!alphaNum(c) && c != L'-' && c != L'_' && c != L'.')
      return false;
  for (wchar_t c : directory)
    if (!alphaNum(c) && c != L'/' && c != L'-' && c != L'_' && c != L'.' &&
        c != L' ')
      return false;
  size_t pos = 1;
  while (pos < directory.size()) {
    const size_t end = directory.find(L'/', pos);
    const auto segment = directory.substr(pos, end - pos);
    if (segment.empty() || segment == L"." || segment == L"..")
      return false;
    if (end == std::wstring::npos)
      break;
    pos = end + 1;
  }
  args = {L"-d",     distro,       L"--cd",
          directory, L"--",        L"/usr/bin/env",
          L"pnpm",   L"tools-dev", start ? L"start" : L"status"};
  if (start)
    args.push_back(L"web");
  return true;
}

// CommandLineToArgvW/CRT quoting, including quotes and trailing backslashes.
inline std::wstring QuoteArgument(const std::wstring &arg) {
  std::wstring out = L"\"";
  size_t slashes = 0;
  for (wchar_t c : arg) {
    if (c == L'\\') {
      ++slashes;
      continue;
    }
    out.append(c == L'"' ? slashes * 2 + 1 : slashes, L'\\');
    slashes = 0;
    out += c;
  }
  out.append(slashes * 2, L'\\');
  return out + L'"';
}

inline const HostProgram &GitProgram() {
  static const HostProgram program = [] {
    HostProgram result;
    // Native installations only. Never resolve git from cwd or a project's
    // PATH.
    for (const auto &candidate :
         {HostEnvironment(L"ProgramFiles") + L"\\Git\\cmd\\git.exe",
          HostEnvironment(L"LOCALAPPDATA") +
              L"\\Programs\\Git\\cmd\\git.exe"}) {
      if (VerifiedExecutable(candidate, result.executable, result.pin))
        break;
    }
    return result;
  }();
  return program;
}

// Ruta local a revelar: unidad + ruta con la gramática estricta de
// confined::Absolute (sin "." ni "..", sin nombres de dispositivo Win32 como
// NUL/CON/COM1, sin flujos alternos, sin UNC ni espacios de nombres de
// dispositivo o extendidos). Una barra final de carpeta se tolera y se
// descarta.
inline bool CanonicalRevealPath(const std::wstring &target,
                                std::wstring &canonical) {
  canonical.clear();
  std::wstring trimmed = target;
  if (trimmed.size() > 3 && (trimmed.back() == L'\\' || trimmed.back() == L'/'))
    trimmed.pop_back();
  return trimmed.size() > 3 &&
         ((trimmed[0] >= L'A' && trimmed[0] <= L'Z') ||
          (trimmed[0] >= L'a' && trimmed[0] <= L'z')) &&
         trimmed[1] == L':' && (trimmed[2] == L'\\' || trimmed[2] == L'/') &&
         trimmed.find(L':', 2) == std::wstring::npos &&
         confined::Absolute(trimmed, canonical);
}

inline OpenTarget ClassifyOpenTarget(const std::wstring &target) {
  if (target.find_first_of(L"\"\r\n\t") != std::wstring::npos ||
      target.find(L'\0') != std::wstring::npos)
    return OpenTarget::Reject;
  if (IsCabinBrowserUrl(target))
    return OpenTarget::Browser;
  std::wstring canonical;
  if (CanonicalRevealPath(target, canonical))
    return OpenTarget::Reveal;
  return OpenTarget::Reject;
}

inline bool OpenBrowserUrl(const std::wstring &url, bool httpsOnly = false) {
  if (ClassifyOpenTarget(url) != OpenTarget::Browser ||
      !IsBrowserUrl(url, httpsOnly))
    return false;
  return reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", url.c_str(),
                                                 nullptr, nullptr,
                                                 SW_SHOWNORMAL)) > 32;
}

inline bool RevealLocalPath(const std::wstring &path) {
  std::wstring canonical;
  if (ClassifyOpenTarget(path) != OpenTarget::Reveal ||
      !CanonicalRevealPath(path, canonical))
    return false;
  wchar_t windows[32768];
  const UINT size = GetWindowsDirectoryW(windows, 32768);
  if (!size || size >= 32768)
    return false;
  // Nunca ShellExecute del archivo: incluso .exe/.bat/.lnk solo se seleccionan.
  const std::wstring explorer = std::wstring(windows, size) + L"\\explorer.exe";
  const std::wstring command =
      L"\"" + explorer + L"\" /select,\"" + canonical + L"\"";
  std::vector<wchar_t> buffer(command.begin(), command.end());
  buffer.push_back(0);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(explorer.c_str(), buffer.data(), nullptr, nullptr, FALSE,
                      0, nullptr, nullptr, &startup, &process))
    return false;
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return true;
}
} // namespace beats::security
#endif
