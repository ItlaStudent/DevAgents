#include "update_apply.hpp"

#include "preview_policy.hpp"

#include <algorithm>
#include <bcrypt.h>
#include <cctype>
#include <cstdio>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <set>
#include <tlhelp32.h>

namespace beats {
namespace update {

namespace {

std::wstring Lower(std::wstring s) {
  for (auto &c : s)
    c = static_cast<wchar_t>(std::towlower(c));
  return s;
}

std::string Narrow(const std::wstring &w) {
  if (w.empty())
    return {};
  const int n =
      WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                          nullptr, 0, nullptr, nullptr);
  if (n <= 0)
    return "?";
  std::string out(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                      out.data(), n, nullptr, nullptr);
  return out;
}

std::wstring TrimSlash(std::wstring s) {
  while (!s.empty() && (s.back() == L'\\' || s.back() == L'/'))
    s.pop_back();
  return s;
}

std::wstring DirOf(const std::wstring &path) {
  const size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash);
}

// Ruta final de un handle (GetFinalPathNameByHandleW) sin el prefijo \\?\,
// en minúsculas; vacía si falla.
std::wstring FinalPath(HANDLE h) {
  std::wstring buf(1024, L'\0');
  DWORD n =
      GetFinalPathNameByHandleW(h, buf.data(), static_cast<DWORD>(buf.size()),
                                FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (n >= buf.size()) {
    buf.assign(n + 1, L'\0');
    n = GetFinalPathNameByHandleW(h, buf.data(), static_cast<DWORD>(buf.size()),
                                  FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  }
  if (n == 0 || n >= buf.size())
    return {};
  buf.resize(n);
  if (buf.rfind(L"\\\\?\\UNC\\", 0) == 0)
    return {}; // de red: nunca
  if (buf.rfind(L"\\\\?\\", 0) == 0)
    buf.erase(0, 4);
  return Lower(TrimSlash(buf));
}

bool IsHex64(const std::string &s) {
  if (s.size() != 64)
    return false;
  for (char c : s)
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
          (c >= 'A' && c <= 'F')))
      return false;
  return true;
}

bool IsDevAgentsExe(const std::wstring &name) {
  const std::wstring lower = Lower(name);
  return lower.rfind(L"devagents", 0) == 0 && lower.size() > 4 &&
         lower.compare(lower.size() - 4, 4, L".exe") == 0;
}

} // namespace

PendingApply ParsePendingApply(const std::string &json) {
  PendingApply result;
  preview::Value value;
  if (!preview::Parser(json, false, true, 64 * 1024).Parse(value) ||
      value.type != preview::Value::Object)
    return result;
  const auto apply = value.object.find("apply");
  if (apply == value.object.end() ||
      apply->second.type != preview::Value::Boolean)
    return result;
  if (preview::Text(value, "reason", 1024, true))
    result.reason = value.object.at("reason").string;
  result.apply = apply->second.number == 1;
  if (!result.apply) {
    result.valid = true;
    return result;
  }
  if (!preview::Text(value, "path", 4096))
    return result;
  result.path = preview::Wide(value.object.at("path").string);
  // Solo rutas absolutas de unidad (X:\...): el motor guarda la de su carpeta
  // de datos; cualquier otra forma no se lanza.
  if (result.path.size() < 4 || result.path[1] != L':' ||
      (result.path[2] != L'\\' && result.path[2] != L'/'))
    return result;
  // T12 M3: sin la huella no hay con qué volver a comprobar: no se lanza.
  if (!preview::Text(value, "sha256", 64) ||
      !IsHex64(value.object.at("sha256").string))
    return result;
  result.sha256 = value.object.at("sha256").string;
  std::transform(result.sha256.begin(), result.sha256.end(),
                 result.sha256.begin(),
                 [](char c) { return static_cast<char>(std::tolower(c)); });
  result.valid = true;
  return result;
}

std::string Sha256HexOfHandle(HANDLE file, std::string &why) {
  LARGE_INTEGER zero{};
  if (!SetFilePointerEx(file, zero, nullptr, FILE_BEGIN)) {
    why = "no se pudo leer el instalador desde el principio (error " +
          std::to_string(GetLastError()) + ")";
    return {};
  }
  BCRYPT_ALG_HANDLE alg = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) !=
          0 ||
      BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0) != 0) {
    if (alg)
      BCryptCloseAlgorithmProvider(alg, 0);
    why = "no se pudo preparar SHA-256 (BCrypt)";
    return {};
  }
  std::vector<unsigned char> chunk(1 << 16);
  bool ok = true;
  for (;;) {
    DWORD got = 0;
    if (!ReadFile(file, chunk.data(), static_cast<DWORD>(chunk.size()), &got,
                  nullptr)) {
      why = "no se pudo leer el instalador (error " +
            std::to_string(GetLastError()) + ")";
      ok = false;
      break;
    }
    if (got == 0)
      break;
    if (BCryptHashData(hash, chunk.data(), got, 0) != 0) {
      why = "SHA-256 (BCrypt) falló al leer el instalador";
      ok = false;
      break;
    }
  }
  unsigned char digest[32];
  if (ok && BCryptFinishHash(hash, digest, sizeof(digest), 0) != 0) {
    why = "SHA-256 (BCrypt) no pudo cerrar la huella";
    ok = false;
  }
  BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(alg, 0);
  if (!ok)
    return {};
  static const char *hex = "0123456789abcdef";
  std::string out;
  out.reserve(64);
  for (unsigned char b : digest) {
    out.push_back(hex[b >> 4]);
    out.push_back(hex[b & 15]);
  }
  return out;
}

HANDLE OpenVerifiedInstaller(const std::wstring &installer,
                             const std::wstring &dataDir,
                             const std::string &expectedSha256,
                             std::string &why) {
  if (dataDir.empty()) {
    why =
        "no se conoce la carpeta de datos: no se puede confinar el instalador";
    return INVALID_HANDLE_VALUE;
  }
  if (!IsHex64(expectedSha256)) {
    why = "el motor no dio una huella válida del instalador";
    return INVALID_HANDLE_VALUE;
  }
  const std::wstring updates = TrimSlash(dataDir) + L"\\updates";
  HANDLE dir =
      CreateFileW(updates.c_str(), FILE_READ_ATTRIBUTES,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (dir == INVALID_HANDLE_VALUE) {
    why = "no existe la carpeta de descargas del actualizador (error " +
          std::to_string(GetLastError()) + ")";
    return INVALID_HANDLE_VALUE;
  }
  const std::wstring updatesFinal = FinalPath(dir);
  CloseHandle(dir);
  // Solo lectura y sin compartir escritura ni borrado: desde aquí hasta que
  // se cierre, nadie puede cambiar, renombrar ni sustituir el archivo.
  HANDLE file =
      CreateFileW(installer.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    why = "no se pudo abrir el instalador en exclusiva (error " +
          std::to_string(GetLastError()) + ")";
    return INVALID_HANDLE_VALUE;
  }
  BY_HANDLE_FILE_INFORMATION info{};
  const std::wstring fileFinal = FinalPath(file);
  if (!GetFileInformationByHandle(file, &info) ||
      (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
      info.nNumberOfLinks != 1) {
    CloseHandle(file);
    why = "el instalador no es un archivo normal (o tiene más de un nombre)";
    return INVALID_HANDLE_VALUE;
  }
  if (updatesFinal.empty() || fileFinal.empty() ||
      fileFinal.size() <= updatesFinal.size() + 1 ||
      fileFinal.compare(0, updatesFinal.size(), updatesFinal) != 0 ||
      fileFinal[updatesFinal.size()] != L'\\') {
    CloseHandle(file);
    why = "el instalador está fuera de la carpeta de descargas del "
          "actualizador: " +
          Narrow(fileFinal.empty() ? installer : fileFinal);
    return INVALID_HANDLE_VALUE;
  }
  const std::string actual = Sha256HexOfHandle(file, why);
  std::string expected = expectedSha256;
  std::transform(expected.begin(), expected.end(), expected.begin(),
                 [](char c) { return static_cast<char>(std::tolower(c)); });
  if (actual.empty() || actual != expected) {
    CloseHandle(file);
    if (!actual.empty())
      why = "la huella del instalador no coincide con la de la descarga";
    return INVALID_HANDLE_VALUE;
  }
  return file;
}

std::vector<ProcessEntry>
BlockingProcesses(const std::vector<ProcessEntry> &all, DWORD selfPid,
                  const std::wstring &installDir) {
  // Descendientes de este proceso: el motor hijo (job con KILL_ON_JOB_CLOSE)
  // y lo que él lance mueren con el host, no impiden nada.
  std::set<DWORD> ours{selfPid};
  for (bool grew = true; grew;) {
    grew = false;
    for (const auto &p : all)
      if (p.pid != 0 && ours.count(p.parent) && !ours.count(p.pid)) {
        ours.insert(p.pid);
        grew = true;
      }
  }
  const std::wstring dir = Lower(TrimSlash(installDir));
  std::vector<ProcessEntry> blocking;
  for (const auto &p : all) {
    if (ours.count(p.pid) || !IsDevAgentsExe(p.exeName))
      continue;
    if (!p.pathKnown || Lower(TrimSlash(DirOf(p.imagePath))) == dir)
      blocking.push_back(p);
  }
  return blocking;
}

std::vector<ProcessEntry> SnapshotProcesses(bool &ok) {
  std::vector<ProcessEntry> out;
  ok = false;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE)
    return out;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (Process32FirstW(snap, &entry)) {
    do {
      ProcessEntry p;
      p.pid = entry.th32ProcessID;
      p.parent = entry.th32ParentProcessID;
      p.exeName = entry.szExeFile;
      if (IsDevAgentsExe(p.exeName)) {
        if (HANDLE h =
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, p.pid)) {
          wchar_t buf[MAX_PATH * 4];
          DWORD size = static_cast<DWORD>(sizeof(buf) / sizeof(buf[0]));
          if (QueryFullProcessImageNameW(h, 0, buf, &size)) {
            p.imagePath.assign(buf, size);
            p.pathKnown = true;
          }
          CloseHandle(h);
        }
      }
      out.push_back(std::move(p));
    } while (Process32NextW(snap, &entry));
    ok = GetLastError() == ERROR_NO_MORE_FILES;
  }
  CloseHandle(snap);
  return out;
}

std::wstring InstallerCommandLine(const std::wstring &installer,
                                  const std::wstring &logPath) {
  std::wstring cmd = L"\"" + installer +
                     L"\" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /UPDATE";
  if (!logPath.empty())
    cmd += L" \"/LOG=" + logPath + L"\"";
  return cmd;
}

std::string ApplyOnExit(const std::wstring &installer,
                        const std::wstring &installDir,
                        const std::wstring &logPath,
                        const std::wstring &dataDir,
                        const std::string &expectedSha256) {
  bool ok = false;
  const auto processes = SnapshotProcesses(ok);
  if (!ok)
    return "no se aplica: no se pudo listar los procesos (error " +
           std::to_string(GetLastError()) +
           "); queda preparada para el próximo cierre";
  const auto blocking =
      BlockingProcesses(processes, GetCurrentProcessId(), installDir);
  if (!blocking.empty()) {
    std::string who;
    for (const auto &p : blocking)
      who += (who.empty() ? "" : ", ") + Narrow(p.exeName) + " (pid " +
             std::to_string(p.pid) + (p.pathKnown ? "" : ", ruta ilegible") +
             ")";
    return "no se aplica: siguen abiertos " + who +
           "; queda preparada para el próximo cierre";
  }
  // T12 M3: justo antes de lanzarlo, ruta confinada y huella releída con el
  // archivo bloqueado; el bloqueo dura hasta después de CreateProcessW.
  std::string why;
  HANDLE held = OpenVerifiedInstaller(installer, dataDir, expectedSha256, why);
  if (held == INVALID_HANDLE_VALUE)
    return "no se aplica: " + why;
  std::wstring cmd = InstallerCommandLine(installer, logPath);
  std::vector<wchar_t> buffer(cmd.begin(), cmd.end());
  buffer.push_back(L'\0');
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  const std::wstring workDir = DirOf(installer);
  const BOOL launched = CreateProcessW(
      installer.c_str(), buffer.data(), nullptr, nullptr, FALSE, 0, nullptr,
      workDir.empty() ? nullptr : workDir.c_str(), &si, &pi);
  const DWORD launchError = GetLastError();
  CloseHandle(held);
  if (!launched)
    return "no se aplica: CreateProcessW del instalador falló (error " +
           std::to_string(launchError) + ")";
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return "instalador lanzado (pid " + std::to_string(pi.dwProcessId) +
         "): " + Narrow(installer);
}

void AppendLog(const std::wstring &dataDir, const std::string &line) {
  if (dataDir.empty())
    return;
  // Fuera de updates\: el motor borra esa carpeta al arrancar con la versión
  // ya aplicada, y el registro tiene que sobrevivir para poder revisarlo.
  std::ofstream log(std::filesystem::path(dataDir) / L"update.log",
                    std::ios::app | std::ios::binary);
  if (!log) {
    OutputDebugStringW(L"DevAgents: no se pudo abrir update.log\n");
    return;
  }
  SYSTEMTIME t{};
  GetLocalTime(&t);
  char stamp[32];
  snprintf(stamp, sizeof(stamp), "%04u-%02u-%02u %02u:%02u:%02u ", t.wYear,
           t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
  log << stamp << line << "\r\n";
}

} // namespace update
} // namespace beats
