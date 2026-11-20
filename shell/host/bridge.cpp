#include "bridge.hpp"
#include "consent_prompt.hpp"
#include "core_client.hpp"
#include "document_manager.hpp"
#include "file_watcher.hpp"
#include "hunk_manager.hpp"
#include "lsp_client.hpp"
#include "preview_policy.hpp"
#include "project_search.hpp"
#include "pty_manager.hpp"
#include "shell_policy.hpp"
#include "version_policy.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <shellapi.h>
#include <shobjidl.h>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <unordered_map>
#include <vector>
#include <windows.h>

namespace beats {

/// Quita espacios y saltos de linea de los dos extremos.
static std::string TrimAscii(const std::string &s) {
  size_t b = s.find_first_not_of(" \t\r\n");
  if (b == std::string::npos)
    return "";
  size_t e = s.find_last_not_of(" \t\r\n");
  return s.substr(b, e - b + 1);
}

static std::string CurrentDirectoryUtf8() {
  wchar_t cwd[32768];
  const DWORD length = GetCurrentDirectoryW(32768, cwd);
  return length && length < 32768 ? preview::Narrow(std::wstring(cwd, length))
                                  : "";
}

/// Lanza `git <args>` en `cwd` y devuelve su salida estandar.
///
/// Sin consola (CREATE_NO_WINDOW): igual que con los servidores MCP, cada
/// invocacion abriria si no una ventana negra delante de la cabina.
///
/// stdout y stderr van por tuberias SEPARADAS, y no es un detalle: git escribe
/// avisos por stderr con total normalidad ("LF will be replaced by CRLF..."),
/// asi que mezclarlos convertia el sha devuelto por `stash create` en ocho
/// lineas de aviso seguidas del sha. Se leyo primero stdout y despues stderr;
/// con la salida de git (unos pocos KB) no hay riesgo de llenar el buffer de
/// la tuberia y bloquear al proceso hijo.
/// (Declarada en bridge.hpp: la prueba del host la ejercita directamente.)

static std::string RunGitCapture(const std::string &cwd,
                                 const std::vector<std::wstring> &args,
                                 std::string &err) {
  const auto &program = security::GitProgram();
  if (program.executable.empty()) {
    err = "Git is not installed in a registered native location";
    return "";
  }
  std::vector<std::wstring> options = {L"--no-optional-locks",
                                       L"--literal-pathspecs",
                                       L"-c",
                                       L"core.fsmonitor=false",
                                       L"-c",
                                       L"core.hooksPath=NUL",
                                       L"-c",
                                       L"submodule.recurse=false",
                                       L"-c",
                                       L"core.worktree=" + preview::Wide(cwd)};
  options.insert(options.end(), args.begin(), args.end());
  return RunCapture(cwd, program.executable, options, err, 30000);
}

/// B1 (10-nov): git sobre el indice propio de un punto de control
/// (GIT_INDEX_FILE). La foto y la vuelta son BYTE A BYTE: sin conversion de
/// finales de linea (core.autocrlf=false) y sin atributos del repositorio
/// (GIT_ATTR_SOURCE = arbol vacio, git >= 2.40; uno anterior lo ignora), asi
/// que ni CRLF ni filtros como LFS cambian lo que se restaura.
/// `magicPathspecs` quita --literal-pathspecs solo para la foto, que excluye
/// las carpetas internas del motor con `:(exclude)`; el resto de llamadas
/// reciben rutas de git y siguen siendo literales.
static std::string RunCheckpointGit(const std::string &cwd,
                                    const std::wstring &indexPath,
                                    const std::wstring &emptyTree,
                                    const std::vector<std::wstring> &args,
                                    std::string &err,
                                    bool magicPathspecs = false,
                                    unsigned long timeoutMs = 120000) {
  const auto &program = security::GitProgram();
  if (program.executable.empty()) {
    err = "Git is not installed in a registered native location";
    return "";
  }
  std::vector<std::wstring> options = {L"--no-optional-locks"};
  if (!magicPathspecs)
    options.push_back(L"--literal-pathspecs");
  for (const wchar_t *opt : {L"core.fsmonitor=false", L"core.hooksPath=NUL",
                             L"submodule.recurse=false", L"core.autocrlf=false",
                             L"core.safecrlf=false"}) {
    options.push_back(L"-c");
    options.push_back(opt);
  }
  options.push_back(L"-c");
  options.push_back(L"core.worktree=" + preview::Wide(cwd));
  options.insert(options.end(), args.begin(), args.end());
  std::vector<std::pair<std::wstring, std::wstring>> env = {
      {L"GIT_INDEX_FILE", indexPath}};
  if (!emptyTree.empty())
    env.push_back({L"GIT_ATTR_SOURCE", emptyTree});
  return RunCaptureEnv(cwd, program.executable, options, env, err, timeoutMs);
}

/// T1-D2 (12-nov): lee un archivo entero (el indice real de git y su copia).
/// Devuelve false si no se pudo abrir o leer completo.
static bool ReadWholeFileBytes(const std::wstring &path, std::string &out) {
  out.clear();
  HANDLE h =
      CreateFileW(path.c_str(), GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return false;
  char buf[65536];
  DWORD got = 0;
  bool ok = true;
  while ((ok = ReadFile(h, buf, sizeof(buf), &got, nullptr) != FALSE) &&
         got > 0)
    out.append(buf, got);
  CloseHandle(h);
  return ok;
}

namespace {
// Remate D5 (10-nov): lector de una tuberia en su propio hilo Win32 (se
// necesita su HANDLE para CancelSynchronousIo).
struct PipeDrain {
  HANDLE pipe = nullptr;
  HANDLE thread = nullptr;
  std::string data;
  static DWORD WINAPI Run(LPVOID raw) {
    auto *self = static_cast<PipeDrain *>(raw);
    char buf[4096];
    DWORD read = 0;
    while (ReadFile(self->pipe, buf, sizeof(buf), &read, nullptr) && read > 0)
      self->data.append(buf, read);
    return 0;
  }
};

// Con el hijo ya terminado, todo lo que escribio esta en la tuberia. Si el
// lector sigue bloqueado es porque OTRO proceso conserva una copia del
// extremo de escritura (un nieto del hijo, o un proceso que el motor lanzo
// con bInheritHandles=TRUE justo mientras la tuberia era heredable) y el EOF
// no llegaria hasta que ese proceso muriera: `core.git.status` se quedaba asi
// hasta el plazo de 60 s de la cabina. Se le da un margen para vaciar lo que
// queda y despues se cancela su lectura bloqueada (sobre una tuberia vacia:
// no se pierde nada; mientras haya datos, ReadFile no se bloquea y la
// cancelacion no lo afecta).
void FinishDrain(PipeDrain &d) {
  if (!d.thread)
    return;
  if (WaitForSingleObject(d.thread, 500) == WAIT_TIMEOUT) {
    while (WaitForSingleObject(d.thread, 50) == WAIT_TIMEOUT)
      CancelSynchronousIo(d.thread);
  }
  CloseHandle(d.thread);
  d.thread = nullptr;
}
} // namespace

std::string RunCapture(const std::string &cwd, const std::wstring &executable,
                       const std::vector<std::wstring> &args, std::string &err,
                       unsigned long timeoutMs) {
  return RunCaptureEnv(cwd, executable, args, {}, err, timeoutMs);
}

// B1 (10-nov): el punto de control necesita lanzar git con GIT_INDEX_FILE
// apuntando a su propio indice. El bloque de entorno es el del host con las
// variables pedidas sustituidas (nombre sin distinguir mayusculas, como hace
// Windows); sin variables extra el hijo hereda el entorno tal cual.
static std::vector<wchar_t> EnvironmentWith(
    const std::vector<std::pair<std::wstring, std::wstring>> &extra) {
  std::vector<wchar_t> block;
  LPWCH current = GetEnvironmentStringsW();
  if (current) {
    for (const wchar_t *p = current; *p; p += wcslen(p) + 1) {
      const std::wstring entry(p);
      const size_t eq = entry.find(L'=', 1); // "=C:=C:\\..." empieza con '='
      bool replaced = false;
      if (eq != std::wstring::npos) {
        const std::wstring name = entry.substr(0, eq);
        for (const auto &kv : extra)
          if (confined::Equal(name, kv.first))
            replaced = true;
      }
      if (!replaced) {
        block.insert(block.end(), entry.begin(), entry.end());
        block.push_back(0);
      }
    }
    FreeEnvironmentStringsW(current);
  }
  for (const auto &kv : extra) {
    const std::wstring entry = kv.first + L"=" + kv.second;
    block.insert(block.end(), entry.begin(), entry.end());
    block.push_back(0);
  }
  block.push_back(0);
  return block;
}

std::string RunCaptureEnv(
    const std::string &cwd, const std::wstring &executable,
    const std::vector<std::wstring> &args,
    const std::vector<std::pair<std::wstring, std::wstring>> &extraEnv,
    std::string &err, unsigned long timeoutMs) {
  err.clear();
  SECURITY_ATTRIBUTES sa{};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;

  HANDLE readOut = nullptr, writeOut = nullptr;
  HANDLE readErr = nullptr, writeErr = nullptr;
  if (!CreatePipe(&readOut, &writeOut, &sa, 0)) {
    err = "No se pudo crear la tuberia para git";
    return "";
  }
  if (!CreatePipe(&readErr, &writeErr, &sa, 0)) {
    CloseHandle(readOut);
    CloseHandle(writeOut);
    err = "No se pudo crear la tuberia de errores para git";
    return "";
  }
  SetHandleInformation(readOut, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(readErr, HANDLE_FLAG_INHERIT, 0);
  // Entrada estandar a NUL (heredable: va en la lista de abajo).
  HANDLE nulIn =
      CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  auto closeAll = [&] {
    CloseHandle(readOut);
    CloseHandle(writeOut);
    CloseHandle(readErr);
    CloseHandle(writeErr);
    if (nulIn != INVALID_HANDLE_VALUE)
      CloseHandle(nulIn);
  };
  if (nulIn == INVALID_HANDLE_VALUE) {
    closeAll();
    err = "No se pudo abrir NUL para la entrada del comando";
    return "";
  }

  // Remate D5: el hijo hereda SOLO sus tres extremos (como el controlador
  // remoto, remote_controller.hpp). Antes heredaba todo handle heredable del
  // host en ese instante, incluidos extremos de tuberias de otras capturas
  // concurrentes, y retrasaba sus EOF.
  SIZE_T attrBytes = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attrBytes);
  std::vector<unsigned char> attrs(attrBytes);
  STARTUPINFOEXW si{};
  si.StartupInfo.cb = sizeof(si);
  si.lpAttributeList =
      reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attrs.data());
  HANDLE allowed[] = {writeOut, writeErr, nulIn};
  const bool attrsReady = InitializeProcThreadAttributeList(
                              si.lpAttributeList, 1, 0, &attrBytes) != FALSE;
  if (!attrsReady ||
      !UpdateProcThreadAttribute(si.lpAttributeList, 0,
                                 PROC_THREAD_ATTRIBUTE_HANDLE_LIST, allowed,
                                 sizeof(allowed), nullptr, nullptr)) {
    if (attrsReady)
      DeleteProcThreadAttributeList(si.lpAttributeList);
    closeAll();
    err = "No se pudo restringir la herencia de handles del comando";
    return "";
  }
  si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  si.StartupInfo.hStdOutput = writeOut;
  si.StartupInfo.hStdError = writeErr;
  si.StartupInfo.hStdInput = nulIn;

  std::wstring command = security::QuoteArgument(executable);
  for (const auto &arg : args)
    command += L" " + security::QuoteArgument(arg);
  std::vector<wchar_t> cmdBuf(command.begin(), command.end());
  cmdBuf.push_back(0);

  PROCESS_INFORMATION pi{};
  const auto wideCwd = preview::Wide(cwd);
  std::vector<wchar_t> envBlock;
  if (!extraEnv.empty())
    envBlock = EnvironmentWith(extraEnv);
  BOOL ok = CreateProcessW(
      executable.c_str(), cmdBuf.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT |
          (envBlock.empty() ? 0 : CREATE_UNICODE_ENVIRONMENT),
      envBlock.empty() ? nullptr : envBlock.data(),
      cwd.empty() ? nullptr : wideCwd.c_str(), &si.StartupInfo, &pi);
  DeleteProcThreadAttributeList(si.lpAttributeList);
  CloseHandle(writeOut);
  CloseHandle(writeErr);
  CloseHandle(nulIn);
  if (!ok) {
    CloseHandle(readOut);
    CloseHandle(readErr);
    err = "No se pudo ejecutar el comando (¿esta en el PATH?)";
    return "";
  }

  PipeDrain outDrain, errDrain;
  outDrain.pipe = readOut;
  errDrain.pipe = readErr;
  outDrain.thread =
      CreateThread(nullptr, 0, PipeDrain::Run, &outDrain, 0, nullptr);
  errDrain.thread =
      CreateThread(nullptr, 0, PipeDrain::Run, &errDrain, 0, nullptr);
  if (!outDrain.thread || !errDrain.thread) {
    TerminateProcess(pi.hProcess, 1);
    WaitForSingleObject(pi.hProcess, 5000);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    FinishDrain(outDrain);
    FinishDrain(errDrain);
    CloseHandle(readOut);
    CloseHandle(readErr);
    err = "No se pudo crear el hilo que lee la salida del comando";
    return "";
  }
  const DWORD wait = WaitForSingleObject(pi.hProcess, timeoutMs);
  if (wait != WAIT_OBJECT_0) {
    if (!TerminateProcess(pi.hProcess, 1))
      OutputDebugStringA("[Bridge] process termination failed\n");
    WaitForSingleObject(pi.hProcess, 5000);
  }
  FinishDrain(outDrain);
  FinishDrain(errDrain);
  std::string out = std::move(outDrain.data), errOut = std::move(errDrain.data);
  CloseHandle(readOut);
  CloseHandle(readErr);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);

  if (wait != WAIT_OBJECT_0) {
    err = "Process timed out or wait failed";
    return "";
  }
  if (code != 0) {
    err = TrimAscii(errOut.empty() ? out : errOut);
    if (err.empty())
      err = "Process exited with code " + std::to_string(code);
    return "";
  }
  return out;
}

// These capabilities configure or run arbitrary programs, disclose native
// secrets/screen data, or widen the engine's permissions. JS booleans cannot
// express native consent (HandleMessage asks before running the handler).
// (12-nov): salen de la lista las acciones corrientes de IDE que ni
// amplian capacidades ni sacan datos ni lanzan un programa nuevo:
// core.git.commit y core.git.init (git local con core.hooksPath=NUL, raiz
// autorizada), core.external.options.set (proveedor/modelo/esfuerzo validados
// contra el catalogo) y core.mcp.call (servidor ya autorizado al conectar).
bool RequiresNativeConsent(const std::string &kind) {
  static const std::unordered_set<std::string> nativeConsent = {
      "core.mcp.connect",
      "core.mcp.authToken",
      "core.hooks.set",
      "core.external.paths.set",
      "core.permissions.set",
      "core.plugin.trust",
      "core.screenshot",
      "core.remote.start",
      "core.webhooks.add",
      "core.webhooks.test",
      "core.provider.add",
      "core.git.storeCredential",
      "core.workspace.restorePermissions",
      "core.pr.merge",
      "core.order.ship",
      "lsp.request",
      "core.repo.clone",
      "core.issues.comment"};
  return nativeConsent.count(kind) > 0;
}

const wchar_t kElevatedModesFile[] = L"permisos-modos-habilitados.txt";

bool IsCheckpointKind(const std::string &kind) {
  return kind == "checkpoint.create" || kind == "checkpoint.restore";
}

std::wstring CheckpointIndexDir() {
  wchar_t temp[MAX_PATH + 1];
  const DWORD tempLen = GetTempPathW(MAX_PATH + 1, temp);
  if (!tempLen || tempLen > MAX_PATH)
    return L"";
  return std::wstring(temp, tempLen) + L"devagents-checkpoints";
}

// B1e (11-nov): los indices se llaman `<pid>-<tick>-<n>.index`. Un host que se
// cierra mal (o se mata) no pasa por ~Bridge y su indice se quedaba para
// siempre en %TEMP%. Se borran los de mas de `maxAgeMs`, salvo los de este
// proceso y los de cualquier proceso que siga vivo con ese PID: un punto de
// control de una sesion abierta nunca se pierde.
size_t PruneStaleCheckpointIndexes(const std::wstring &dir,
                                   unsigned long long maxAgeMs,
                                   unsigned long currentPid) {
  if (dir.empty())
    return 0;
  FILETIME nowFt{};
  GetSystemTimeAsFileTime(&nowFt);
  const unsigned long long now =
      (static_cast<unsigned long long>(nowFt.dwHighDateTime) << 32) |
      nowFt.dwLowDateTime;
  const unsigned long long maxAge100ns = maxAgeMs * 10000ULL;
  WIN32_FIND_DATAW fd{};
  HANDLE find = FindFirstFileW((dir + L"\\*").c_str(), &fd);
  if (find == INVALID_HANDLE_VALUE)
    return 0;
  size_t removed = 0;
  do {
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
      continue;
    const std::wstring name = fd.cFileName;
    const auto endsWith = [&](const wchar_t *suffix) {
      const size_t n = wcslen(suffix);
      return name.size() > n && name.compare(name.size() - n, n, suffix) == 0;
    };
    if (!endsWith(L".index") && !endsWith(L".index.lock"))
      continue;
    const size_t dash = name.find(L'-');
    if (dash == 0 || dash == std::wstring::npos ||
        name.find_first_not_of(L"0123456789") != dash)
      continue;
    const unsigned long pid =
        wcstoul(name.substr(0, dash).c_str(), nullptr, 10);
    const unsigned long long written =
        (static_cast<unsigned long long>(fd.ftLastWriteTime.dwHighDateTime)
         << 32) |
        fd.ftLastWriteTime.dwLowDateTime;
    if (pid == currentPid || written > now || now - written < maxAge100ns)
      continue;
    if (HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                  static_cast<DWORD>(pid))) {
      DWORD code = 0;
      const bool alive =
          GetExitCodeProcess(proc, &code) && code == STILL_ACTIVE;
      CloseHandle(proc);
      if (alive)
        continue;
    } else if (GetLastError() == ERROR_ACCESS_DENIED) {
      continue; // existe, pero no es nuestro: no se toca
    }
    if (DeleteFileW((dir + L"\\" + name).c_str()))
      removed++;
  } while (FindNextFileW(find, &fd));
  FindClose(find);
  return removed;
}

/// r2: `devagents-workspace/` es la carpeta INTERNA del motor
/// (espacios de orden, `.devagents/spaces/orden-*`; antes `.beats`), no trabajo
/// del usuario. Ni «Cambios» ni el punto de control la cuentan: decision tomada
/// en el host (y no solo en la WebUI) para que ningun cliente del puente la vea
/// como «sin seguimiento». Las rutas de git llegan relativas y con `/`.
bool IsEngineInternalPath(const std::string &path) {
  std::string normalized = path;
  std::replace(normalized.begin(), normalized.end(), '\\', '/');
  size_t start = 0;
  while (start <= normalized.size()) {
    const size_t end = normalized.find('/', start);
    const std::string part = normalized.substr(start, end - start);
    if (part == "." || part == "..")
      return false;
    if (end == std::string::npos)
      break;
    start = end + 1;
  }
  std::string first = normalized.substr(0, normalized.find('/'));
  // El nombre reservado es ASCII: plegado independiente de locale de Windows.
  for (char &c : first)
    if (c >= 'A' && c <= 'Z')
      c = static_cast<char>(c + ('a' - 'A'));
  return first == "devagents-workspace";
}

static bool IsGitRepo(const std::string &root, std::string &err) {
  std::string inner;
  std::string out =
      RunGitCapture(root, {L"rev-parse", L"--is-inside-work-tree"}, inner);
  if (TrimAscii(out) == "true")
    return true;
  err = inner.empty() ? "No es un repositorio git." : inner;
  return false;
}

/// Rama actual de un `root` YA validado como repositorio git.
///
/// `--abbrev-ref HEAD` es la vista preferida; en una cabeza nonata (sin
/// commits) devuelve HEAD y en detached el nombre del commit, asi que se cae a
/// `branch --show-current` (vacio en detached) y al commit corto para no dejar
/// la fila vacia. Es la misma cascada que usaba core.git.branch.
static std::string ResolveGitBranch(const std::string &root) {
  std::string err;
  std::string branch = TrimAscii(
      RunGitCapture(root, {L"rev-parse", L"--abbrev-ref", L"HEAD"}, err));
  if (branch.empty() || branch == "HEAD") {
    std::string err2;
    branch =
        TrimAscii(RunGitCapture(root, {L"branch", L"--show-current"}, err2));
    if (branch.empty()) {
      std::string err3;
      branch = TrimAscii(
          RunGitCapture(root, {L"rev-parse", L"--short", L"HEAD"}, err3));
    }
  }
  return branch;
}

static std::string JsonEscape(const std::string &s) {
  std::string out;
  out.reserve(s.size() + 10);
  for (char c : s) {
    if (c == '"')
      out += "\\\"";
    else if (c == '\\')
      out += "\\\\";
    else if (c == '\b')
      out += "\\b";
    else if (c == '\f')
      out += "\\f";
    else if (c == '\n')
      out += "\\n";
    else if (c == '\r')
      out += "\\r";
    else if (c == '\t')
      out += "\\t";
    else if (static_cast<unsigned char>(c) < 0x20) {
      // JSON prohibe los caracteres de control en crudo dentro de una cadena.
      // No es un caso teorico: la salida de ConPTY viene sembrada de secuencias
      // ANSI que empiezan por ESC (0x1B), asi que CADA lectura de la terminal
      // producia un documento invalido. PostWebMessageAsJson lo rechazaba y la
      // respuesta no llegaba nunca: la terminal se quedaba muda sin un solo
      // error a la vista.
      char buf[7];
      snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
      out += buf;
    } else
      out += c;
  }
  return out;
}

static std::wstring Utf8ToWide(const std::string &str) {
  if (str.empty())
    return L"";
  int size =
      MultiByteToWideChar(CP_UTF8, 0, str.c_str(), (int)str.size(), NULL, 0);
  std::wstring wstr(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(), (int)str.size(), &wstr[0], size);
  return wstr;
}

static std::string WideToUtf8(const std::wstring &wstr) {
  if (wstr.empty())
    return "";
  int size = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), (int)wstr.size(),
                                 NULL, 0, NULL, NULL);
  std::string str(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), (int)wstr.size(), &str[0], size,
                      NULL, NULL);
  return str;
}

// Envoltorio publico de JsonEscape (declarado en bridge.hpp). Existe para que
// los handlers que main.cpp registra por su cuenta escapen EXACTAMENTE igual
// que los de aqui, en vez de llevar su propia copia que acabaria divergiendo.
std::string JsonEscapePublic(const std::string &s) { return JsonEscape(s); }

/// Ruta relativa de git -> ruta canonica DENTRO de `canonicalRoot`, o false.
///
/// La lista de archivos de core.git.commit la escribe la pagina, asi que no se
/// acepta tal cual: se rechazan rutas absolutas, unidades, UNC, '*', '?' y
/// componentes `.`/`..`/de dispositivo Win32 al pasar por confined::Absolute,
/// y despues se exige que el resultado cuelgue de la raiz ya autorizada. Git
/// entrega rutas con '/'; se normalizan a '\' antes de componer.
// El llamador retiene LockTree durante toda la operacion Git; este helper
// completa la validacion fisica del arbol con los limites lexicos del payload.
static bool ConfinedRepoPath(const std::wstring &canonicalRoot,
                             const std::string &rel, std::wstring &joined) {
  if (rel.empty() || rel.size() > 4096)
    return false;
  std::wstring relW = Utf8ToWide(rel);
  if (relW.find(L'\0') != std::wstring::npos)
    return false;
  std::replace(relW.begin(), relW.end(), L'/', L'\\');
  if (relW.compare(0, 1, L"\\") == 0 || relW.find(L':') != std::wstring::npos)
    return false;
  std::wstring canonical;
  if (!confined::Absolute(canonicalRoot + L"\\" + relW, canonical) ||
      !confined::Inside(canonicalRoot, canonical))
    return false;
  joined = std::move(canonical);
  return true;
}

// ── Búsqueda de claves al nivel superior (E3.39-D) ─────────────────────
//
// Los buscadores anteriores localizaban la clave con `find("\"k\"")`, que da
// igual dónde aparezca: una `"kind"` escrita DENTRO del payload ganaba a la
// del sobre, una `}` dentro de una cadena cerraba el payload antes de tiempo
// y una `"id"` incrustada en un texto se tomaba como identificador del
// mensaje. Estos dos recorridos solo aceptan claves a profundidad 1 del
// objeto raíz y no se dejan engañar por el contenido de las cadenas.

// Devuelve el offset del primer carácter del VALOR asociado a `key` cuando la
// clave aparece al nivel superior del objeto JSON (depth 1), o npos.
// Una cadena cuyo contenido sea `"key"` pero no venga seguida de ':' no
// cuenta — es un valor, no una clave.
static size_t FindTopLevelValuePos(const std::string &json,
                                   const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  int depth = 0;
  bool inString = false;
  for (size_t i = 0; i < json.size(); ++i) {
    const char c = json[i];
    if (inString) {
      if (c == '\\') {
        ++i;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      if (depth == 1 && json.compare(i, needle.size(), needle) == 0) {
        size_t j = i + needle.size();
        while (j < json.size() && (json[j] == ' ' || json[j] == '\t' ||
                                   json[j] == '\r' || json[j] == '\n')) {
          ++j;
        }
        if (j < json.size() && json[j] == ':') {
          size_t v = j + 1;
          while (v < json.size() && (json[v] == ' ' || json[v] == '\t' ||
                                     json[v] == '\r' || json[v] == '\n')) {
            ++v;
          }
          return v;
        }
      }
      inString = true;
      continue;
    }
    if (c == '{' || c == '[') {
      ++depth;
    } else if (c == '}' || c == ']') {
      --depth;
    }
  }
  return std::string::npos;
}

// Devuelve el offset EXCLUSIVO del cierre del contenedor que abre en `start`
// (json[start] es '{' o '['), o npos si nunca cierra. Las llaves/corchetes
// escritos dentro de cadenas no alteran la profundidad.
static size_t MatchContainerEnd(const std::string &json, size_t start) {
  const char openChar = json[start];
  const char closeChar = (openChar == '{') ? '}' : ']';
  int depth = 0;
  bool inString = false;
  for (size_t i = start; i < json.size(); ++i) {
    const char c = json[i];
    if (inString) {
      if (c == '\\') {
        ++i;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == openChar) {
      ++depth;
    } else if (c == closeChar) {
      if (--depth == 0)
        return i + 1;
    }
  }
  return std::string::npos;
}

// Devuelve el offset EXCLUSIVO del cierre de la cadena JSON que abre en
// `start` (json[start] es '"'), respetando los escapes, o npos.
static size_t MatchStringEnd(const std::string &json, size_t start) {
  for (size_t i = start + 1; i < json.size(); ++i) {
    if (json[i] == '\\') {
      ++i;
    } else if (json[i] == '"') {
      return i + 1;
    }
  }
  return std::string::npos;
}

static bool LeeHex4(const std::string &s, size_t pos, unsigned int &out) {
  out = 0;
  for (size_t k = 0; k < 4; ++k) {
    const char c = s[pos + k];
    out <<= 4;
    if (c >= '0' && c <= '9')
      out |= static_cast<unsigned int>(c - '0');
    else if (c >= 'a' && c <= 'f')
      out |= static_cast<unsigned int>(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F')
      out |= static_cast<unsigned int>(c - 'A' + 10);
    else
      return false;
  }
  return true;
}

static void AnadeUtf8(std::string &res, unsigned int cp) {
  if (cp < 0x80) {
    res += static_cast<char>(cp);
  } else if (cp < 0x800) {
    res += static_cast<char>(0xC0 | (cp >> 6));
    res += static_cast<char>(0x80 | (cp & 0x3F));
  } else if (cp < 0x10000) {
    res += static_cast<char>(0xE0 | (cp >> 12));
    res += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    res += static_cast<char>(0x80 | (cp & 0x3F));
  } else {
    res += static_cast<char>(0xF0 | (cp >> 18));
    res += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
    res += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    res += static_cast<char>(0x80 | (cp & 0x3F));
  }
}

// Contenido crudo de una cadena JSON (sin comillas) a texto desescapado.
static std::string UnescapeJsonString(const std::string &raw) {
  std::string res;
  for (size_t i = 0; i < raw.length(); ++i) {
    if (raw[i] == '\\' && i + 1 < raw.length()) {
      if (raw[i + 1] == '"') {
        res += '"';
        i++;
      } else if (raw[i + 1] == '\\') {
        res += '\\';
        i++;
      } else if (raw[i + 1] == 'n') {
        res += '\n';
        i++;
      } else if (raw[i + 1] == 'r') {
        res += '\r';
        i++;
      } else if (raw[i + 1] == 't') {
        res += '\t';
        i++;
      } else if (raw[i + 1] == 'b') {
        res += '\b';
        i++;
      } else if (raw[i + 1] == 'f') {
        res += '\f';
        i++;
      } else if (raw[i + 1] == 'u' && i + 5 < raw.length()) {
        // 23-09: sin esto, \u001b y \u0003 llegaban como TEXTO. Es la via de
        // todo lo que se teclea en la terminal (JSON.stringify escapa asi los
        // controles): flechas, Escape, Ctrl+C y los avisos de foco que pide
        // ConPTY aparecian en el prompt como "u001b[A".
        unsigned int cp = 0;
        if (!LeeHex4(raw, i + 2, cp)) {
          res += raw[i + 1];
          i++;
          continue;
        }
        size_t consumidos = 5;
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 11 < raw.length() &&
            raw[i + 6] == '\\' && raw[i + 7] == 'u') {
          unsigned int bajo = 0;
          if (LeeHex4(raw, i + 8, bajo) && bajo >= 0xDC00 && bajo <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (bajo - 0xDC00);
            consumidos = 11;
          }
        }
        if (cp >= 0xD800 && cp <= 0xDFFF)
          cp = 0xFFFD; // sustituto suelto: no es texto valido
        AnadeUtf8(res, cp);
        i += consumidos;
      } else {
        res += raw[i + 1];
        i++;
      }
    } else {
      res += raw[i];
    }
  }
  return res;
}

std::string GetStringProp(const std::string &json, const std::string &key) {
  size_t quoteStart = FindTopLevelValuePos(json, key);
  if (quoteStart == std::string::npos || json[quoteStart] != '"')
    return "";
  size_t quoteEndEx = MatchStringEnd(json, quoteStart);
  if (quoteEndEx == std::string::npos)
    return "";
  return UnescapeJsonString(
      json.substr(quoteStart + 1, quoteEndEx - quoteStart - 2));
}

// Array JSON de cadenas al nivel superior (p. ej. `files` de core.git.commit).
// Devuelve los elementos ya desescapados; no es un parser general: lo que no
// sea una cadena dentro del array se ignora.
static std::vector<std::string> GetStringArrayProp(const std::string &json,
                                                   const std::string &key) {
  std::vector<std::string> out;
  size_t start = FindTopLevelValuePos(json, key);
  if (start == std::string::npos || json.compare(start, 1, "[") != 0)
    return out;
  const size_t end = MatchContainerEnd(json, start);
  if (end == std::string::npos)
    return out;
  for (size_t i = start + 1; i < end;) {
    if (json[i] != '"') {
      ++i;
      continue;
    }
    const size_t close = MatchStringEnd(json, i);
    if (close == std::string::npos || close > end)
      break;
    out.push_back(UnescapeJsonString(json.substr(i + 1, close - i - 2)));
    i = close;
  }
  return out;
}

static int GetIntProp(const std::string &json, const std::string &key,
                      int defaultVal = 0) {
  size_t numStart = FindTopLevelValuePos(json, key);
  if (numStart == std::string::npos)
    return defaultVal;
  size_t numEnd = numStart;
  while (numEnd < json.length() &&
         (isdigit(static_cast<unsigned char>(json[numEnd])) ||
          json[numEnd] == '-' || json[numEnd] == '+' || json[numEnd] == '.')) {
    numEnd++;
  }
  try {
    return std::stoi(json.substr(numStart, numEnd - numStart));
  } catch (...) {
    return defaultVal;
  }
}

// Igual que GetIntProp pero de 64 bits: los identificadores de orden del motor
// son i64 y se transportan como numero JSON.
static long long GetInt64Prop(const std::string &json, const std::string &key,
                              long long defaultVal = 0) {
  size_t numStart = FindTopLevelValuePos(json, key);
  if (numStart == std::string::npos)
    return defaultVal;
  size_t numEnd = numStart;
  while (numEnd < json.length() &&
         (isdigit(static_cast<unsigned char>(json[numEnd])) ||
          json[numEnd] == '-' || json[numEnd] == '+' || json[numEnd] == '.')) {
    numEnd++;
  }
  try {
    return std::stoll(json.substr(numStart, numEnd - numStart));
  } catch (...) {
    return defaultVal;
  }
}

// El motor representa el handle de una orden como el propio id convertido a
// puntero (ver orderIdToHandle/orderHandleToId en c_api.zig). La cabina hace la
// misma conversion para poder mover ids como numeros JSON hasta el WebUI.
static void *OrderIdToHandle(long long id) {
  return reinterpret_cast<void *>(static_cast<uintptr_t>(id));
}

static long long OrderHandleToId(void *handle) {
  return static_cast<long long>(reinterpret_cast<uintptr_t>(handle));
}

static std::mutex g_sessionOrdersMutex;
static std::unordered_set<long long> g_sessionOrders;

void Bridge::NoteSessionOrder(long long orderId) {
  if (orderId <= 0)
    return;
  std::lock_guard<std::mutex> guard(g_sessionOrdersMutex);
  g_sessionOrders.insert(orderId);
}

bool Bridge::IsSessionOrder(long long orderId) {
  std::lock_guard<std::mutex> guard(g_sessionOrdersMutex);
  return g_sessionOrders.count(orderId) != 0;
}

bool Bridge::AuthorizeOrderWorktree(DocumentManager &documents,
                                    bool sessionOrder, const std::string &path,
                                    std::string &cause) {
  cause.clear();
  const auto wide = Utf8ToWide(path);
  const bool inGrantedRoot = documents.IsAuthorizedWorkspaceRoot(wide) ||
                             documents.IsWorkspacePath(wide);
  if (path.empty() || (!sessionOrder && !inGrantedRoot)) {
    cause = "E_ORDER_ROOT_NOT_GRANTED: La carpeta de esta orden está fuera de "
            "las carpetas concedidas y la orden no se creó en esta sesión. "
            "Elige la carpeta con «Abrir carpeta de trabajo».";
    return false;
  }
  return documents.AuthorizeWorkspaceRoot(wide, cause);
}

static bool GetBoolProp(const std::string &json, const std::string &key,
                        bool defaultVal = false) {
  size_t valStart = FindTopLevelValuePos(json, key);
  if (valStart == std::string::npos)
    return defaultVal;
  if (json.compare(valStart, 4, "true") == 0)
    return true;
  if (json.compare(valStart, 5, "false") == 0)
    return false;
  return defaultVal;
}

// Internal C++ helper, also exercised by the native bridge tests. Preserve
// engine metadata and match objects byte-for-byte while rebuilding the array.
bool FilterSaveTemporaryMatches(std::string &json) {
  const size_t start = FindTopLevelValuePos(json, "matches");
  if (start == std::string::npos || start >= json.size() || json[start] != '[')
    return false;
  const size_t end = MatchContainerEnd(json, start);
  if (end == std::string::npos)
    return false;
  std::string matches = "[";
  size_t pos = start + 1;
  bool first = true;
  while (true) {
    pos = json.find_first_not_of(" \t\r\n", pos);
    if (pos == std::string::npos || pos >= end)
      return false;
    if (json[pos] == ']')
      break;
    if (json[pos] != '{')
      return false;
    const size_t close = MatchContainerEnd(json, pos);
    if (close == std::string::npos || close >= end)
      return false;
    const auto match = json.substr(pos, close - pos);
    const auto path = Utf8ToWide(GetStringProp(match, "path"));
    if (path.empty())
      return false;
    if (!confined::IsSaveTemporaryPath(path)) {
      if (!first)
        matches += ',';
      matches += match;
      first = false;
    }
    pos = json.find_first_not_of(" \t\r\n", close);
    if (pos == std::string::npos || pos >= end)
      return false;
    if (json[pos] == ']')
      break;
    if (json[pos++] != ',')
      return false;
    pos = json.find_first_not_of(" \t\r\n", pos);
    if (pos == std::string::npos || pos >= end || json[pos] != '{')
      return false;
  }
  matches += ']';
  json.replace(start, end - start, matches);
  return true;
}

Bridge::Bridge() {
  // Captura la instalación del host antes de recibir entradas del WebView.
  (void)security::ShellRegistry();
  (void)security::LspRegistry();
  (void)security::GitProgram();
  RegisterHandler("init", [](const BridgeMessage &msg) {
    return "{\"id\":" + std::to_string(msg.id) + ",\"status\":\"ok\"}";
  });
  RegisterHandler("ping", [](const BridgeMessage &msg) {
    return "{\"id\":" + std::to_string(msg.id) + ",\"status\":\"pong\"}";
  });
  // PRUEBA DE USUARIO 31-08: la UI necesita saber dónde vive el ejecutable
  // del host para resolver binarios hermanos (el preset 'DevAgents MCP'
  // mandaba un nombre pelado y el spawn lo buscaba en el CWD de la cabina,
  // que no es el directorio del binario). WebView2 virtualiza el origen,
  // así que la única ruta fiable es la que el propio host reporta.
  RegisterHandler("app.exedir", [](const BridgeMessage &msg) {
    wchar_t exePath[MAX_PATH];
    if (GetModuleFileNameW(nullptr, exePath, MAX_PATH) == 0) {
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"no se pudo determinar la ruta del host\"}";
    }
    wchar_t *lastSlash = wcsrchr(exePath, L'\\');
    if (lastSlash)
      *lastSlash = 0;
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"dir\":\"" +
           JsonEscape(WideToUtf8(std::wstring(exePath))) + "\"}}";
  });
  RegisterHandler("cdp.dump", [](const BridgeMessage &msg) {
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"error\":\"WebView diagnostic file writes are disabled\"}";
  });
}

Bridge::~Bridge() {
  // B1: los indices de los puntos de control solo valen para este host (el
  // puente no restaura lo que no emitio); al cerrarse no sirven a nadie.
  for (const auto &root : m_checkpoints)
    for (const auto &entry : root.second) {
      DeleteFileW(entry.second.indexPath.c_str());
      if (!entry.second.realIndexCopy.empty())
        DeleteFileW(entry.second.realIndexCopy.c_str());
    }
}

void Bridge::RegisterHandler(const std::string &kind, MessageHandler handler) {
  if (!kind.empty() && handler) {
    m_handlers[kind] = handler;
  }
}

std::vector<std::string> Bridge::RegisteredHandlerNames() const {
  std::vector<std::string> names;
  for (const auto &entry : m_handlers)
    names.push_back(entry.first);
  std::sort(names.begin(), names.end());
  return names;
}

void Bridge::EmitEvent(const std::string &topic,
                       const std::string &payloadJson) {
  if (!m_eventSink)
    return;
  m_eventSink("{\"push\":\"" + topic + "\",\"payload\":" + payloadJson + "}");
}

void Bridge::BindServices(DocumentManager *docMgr, FileWatcher *fileWatcher,
                          ProjectSearch *projectSearch, HunkManager *hunkMgr,
                          PtyManager *ptyMgr, LspClient *lspClient,
                          CoreClient *coreClient) {
  m_documents = docMgr;
  m_core = coreClient;
  m_lsp = lspClient;
  // 1. doc.open
  RegisterHandler("doc.open", [docMgr](const BridgeMessage &msg) {
    if (!docMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"DocumentManager unavailable\"}";
    std::string pathStr = GetStringProp(msg.payloadJson, "path");
    if (pathStr.empty())
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"Missing 'path' parameter\"}";
    DocumentState doc;
    if (docMgr->OpenDocument(Utf8ToWide(pathStr), doc)) {
      const DWORD attributes =
          GetFileAttributesW(confined::Extended(doc.path).c_str());
      const bool readOnly = attributes == INVALID_FILE_ATTRIBUTES ||
                            (attributes & FILE_ATTRIBUTE_READONLY) ||
                            !docMgr->IsWritableWorkspacePath(doc.path);
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"path\":\"" +
             JsonEscape(WideToUtf8(doc.path)) + "\",\"content\":\"" +
             JsonEscape(doc.content) + "\",\"encoding\":\"" +
             JsonEscape(doc.encoding) + "\",\"lineEnding\":\"" +
             JsonEscape(doc.lineEnding) +
             "\",\"readOnly\":" + (readOnly ? "true" : "false") +
             ",\"isDirty\":" + (doc.isDirty ? "true" : "false") +
             ",\"lastModifiedTime\":" + std::to_string(doc.lastModifiedTime) +
             "}}";
    }
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"error\":\"E_OPEN_DENIED: No se pudo abrir el documento (no "
           "autorizado, inseguro o incompleto)\"}";
  });

  // 2. doc.save
  RegisterHandler("doc.save", [docMgr, this](const BridgeMessage &msg) {
    if (!docMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"DocumentManager unavailable\"}";
    std::string pathStr = GetStringProp(msg.payloadJson, "path");
    std::string contentStr = GetStringProp(msg.payloadJson, "content");
    bool force = GetBoolProp(msg.payloadJson, "force", false);
    if (pathStr.empty())
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"Missing 'path' parameter\"}";
    std::string err;
    const std::string token = GetStringProp(msg.payloadJson, "saveToken");
    if (docMgr->SaveDocument(Utf8ToWide(pathStr), contentStr, force, err,
                             token)) {
      // E5.21: el guardado se difunde a todas las ventanas — la que tenga el
      // archivo abierto puede refrescarlo (invalidacion, no contenido).
      EmitEvent("doc.saved", "{\"path\":\"" + JsonEscape(pathStr) + "\"}");
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"saved\":true}}";
    }
    return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
           JsonEscape(err.empty() ? "Save failed" : err) + "\"}";
  });

  // Native consent grants exactly one write to the selected path. JS cannot
  // turn an arbitrary path or core.workspace.set into filesystem authority.
  RegisterHandler("dialog.saveAs", [docMgr, this](const BridgeMessage &msg) {
    const std::string id = std::to_string(msg.id);
    const auto failure = [&id](const std::string &error) {
      return "{\"id\":" + id + ",\"error\":\"" + JsonEscape(error) + "\"}";
    };
    if (!docMgr || !m_dialogOwner)
      return failure("Native Save As unavailable");
    IFileSaveDialog *dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr) || !dialog)
      return failure("Cannot create native Save As dialog");
    DWORD options = 0;
    hr = dialog->GetOptions(&options);
    if (SUCCEEDED(hr))
      hr = dialog->SetOptions(options | FOS_FORCEFILESYSTEM |
                              FOS_PATHMUSTEXIST | FOS_OVERWRITEPROMPT);
    if (SUCCEEDED(hr))
      hr = dialog->SetTitle(L"Guardar como");
    if (SUCCEEDED(hr))
      hr = dialog->Show(static_cast<HWND>(m_dialogOwner));
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      dialog->Release();
      return "{\"id\":" + id +
             ",\"status\":\"ok\",\"payload\":{\"cancelled\":true}}";
    }
    IShellItem *item = nullptr;
    PWSTR selected = nullptr;
    if (SUCCEEDED(hr))
      hr = dialog->GetResult(&item);
    if (SUCCEEDED(hr) && item)
      hr = item->GetDisplayName(SIGDN_FILESYSPATH, &selected);
    const std::wstring path = selected ? selected : L"";
    if (selected)
      CoTaskMemFree(selected);
    if (item)
      item->Release();
    dialog->Release();
    if (FAILED(hr) || path.empty())
      return failure("Cannot read native Save As selection");
    std::string token, error;
    if (!docMgr->AuthorizeSaveAs(path, token, error))
      return failure(error);
    return "{\"id\":" + id +
           ",\"status\":\"ok\",\"payload\":{\"cancelled\":false,\"path\":\"" +
           JsonEscape(WideToUtf8(path)) + "\",\"saveToken\":\"" + token +
           "\"}}";
  });

  // 3. fs.watch
  RegisterHandler(
      "fs.watch", [fileWatcher, docMgr, this](const BridgeMessage &msg) {
        if (!fileWatcher)
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"error\":\"FileWatcher unavailable\"}";
        std::string dirStr = GetStringProp(msg.payloadJson, "path");
        if (dirStr.empty())
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"error\":\"Missing 'path' parameter\"}";
        confined::LockedPath locked;
        if (!docMgr || !docMgr->LockReadDirectory(Utf8ToWide(dirStr), locked))
          return CreateErrorResponse(msg.id,
                                     "E_WATCH_ROOT_NOT_AUTHORIZED: La carpeta "
                                     "a vigilar no está autorizada o no "
                                     "es segura");
        // E5.21: los cambios en disco se difunden como fs.changed a TODAS las
        // ventanas (antes el callback era vacio — el aviso no llegaba a
        // ninguna). El callback corre en el hilo del watcher: el sink del host
        // lo reenvia por PostMessage a la cola de UI.
        auto sink = m_eventSink;
        bool ok = fileWatcher->StartWatching(
            Utf8ToWide(dirStr),
            [sink](const std::wstring &path, FileChangeType type) {
              if (!sink)
                return;
              std::string p = WideToUtf8(path);
              const char *t = type == FileChangeType::Created   ? "created"
                              : type == FileChangeType::Deleted ? "deleted"
                              : type == FileChangeType::Renamed ? "renamed"
                                                                : "modified";
              sink("{\"push\":\"fs.changed\",\"payload\":{\"path\":\"" +
                   JsonEscape(p) + "\",\"type\":\"" + t + "\"}}");
            });
        if (ok) {
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"status\":\"ok\",\"payload\":{\"watching\":true}}";
        }
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"error\":\"Failed to start watching directory\"}";
      });

  // 4. fs.unwatch
  RegisterHandler("fs.unwatch", [fileWatcher](const BridgeMessage &msg) {
    if (fileWatcher)
      fileWatcher->StopWatching();
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"watching\":false}}";
  });

  // 5. search.query
  RegisterHandler("search.query", [projectSearch,
                                   coreClient](const BridgeMessage &msg) {
    // E5.14: mode="ranking" delega en el motor (da_repo_search — BM25 sobre
    // git ls-files, lexico, NO semantico). El JSON del motor viaja intacto:
    // {query_mode:"bm25", truncated, files_scanned, matches:[{path,line,
    // snippet,score}]}.
    const std::string mode = GetStringProp(msg.payloadJson, "mode");
    if (mode == "ranking" || mode == "bm25" || mode == "semantic" ||
        mode == "hybrid") {
      if (!coreClient || !coreClient->EngineReady())
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"error\":\"El motor no esta disponible\"}";
      const std::string q = GetStringProp(msg.payloadJson, "query");
      const std::string root = GetStringProp(msg.payloadJson, "rootDir");
      if (q.empty())
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"error\":\"Missing query\"}";
      std::string arg = "{\"query\":\"" + JsonEscape(q) + "\"";
      if (!root.empty())
        arg += ",\"root\":\"" + JsonEscape(root) + "\"";
      // E5.15: mode "semantic"/"hybrid" activa el rerank de embeddings del
      // motor si esta configurado; si no, el JSON sale con query_mode=bm25
      // y semantic_status=<razon> — nunca se disfraza de semantico.
      if (mode == "semantic" || mode == "hybrid")
        arg += ",\"mode\":\"" + JsonEscape(mode) + "\"";
      const int maxResults = GetIntProp(msg.payloadJson, "maxResults", 0);
      if (maxResults > 0)
        arg += ",\"max_results\":" + std::to_string(maxResults);
      arg += "}";
      CoreResult res = coreClient->CallJson(coreClient->Api().repo_search, arg);
      if (!res.ok()) {
        std::string e =
            res.error.empty()
                ? ("El motor devolvio el codigo " + std::to_string(res.rc))
                : res.error;
        return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
               JsonEscape(e) + "\"}";
      }
      if (!FilterSaveTemporaryMatches(res.json))
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"error\":\"E_SEARCH_INVALID_RESPONSE: Respuesta de búsqueda "
               "inválida\"}";
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":" +
             (res.json.empty() ? "{}" : res.json) + "}";
    }
    if (!projectSearch)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"ProjectSearch unavailable\"}";
    SearchOptions opts;
    opts.query = GetStringProp(msg.payloadJson, "query");
    opts.rootDir = Utf8ToWide(GetStringProp(msg.payloadJson, "rootDir"));
    opts.isRegex = GetBoolProp(msg.payloadJson, "isRegex", false);
    opts.caseSensitive = GetBoolProp(msg.payloadJson, "caseSensitive", false);
    const int maxResults = GetIntProp(msg.payloadJson, "maxResults", 0);
    if (maxResults > 0)
      opts.maxResults = static_cast<size_t>(maxResults);
    if (opts.query.empty() || opts.rootDir.empty()) {
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"Missing query or rootDir\"}";
    }
    std::string searchError;
    auto matches = projectSearch->ExecuteSearch(opts, &searchError);
    if (!searchError.empty())
      return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
             JsonEscape(searchError) + "\"}";
    std::string matchesJson = "[";
    for (size_t i = 0; i < matches.size(); ++i) {
      if (i > 0)
        matchesJson += ",";
      matchesJson +=
          "{\"filePath\":\"" + JsonEscape(WideToUtf8(matches[i].filePath)) +
          "\",\"lineNumber\":" + std::to_string(matches[i].lineNumber) +
          ",\"lineContent\":\"" + JsonEscape(matches[i].lineContent) + "\"}";
    }
    matchesJson += "]";
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"matches\":" + matchesJson + "}}";
  });

  // 5b. search.embedIndex — E5.15: construye/actualiza el índice vectorial
  // persistente del repo (incremental; presupuesto + reintento 429 en el
  // motor). Payload {rootDir?}. Devuelve las cuentas reales de la pasada.
  RegisterHandler("search.embedIndex", [coreClient](const BridgeMessage &msg) {
    if (!coreClient || !coreClient->EngineReady())
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"El motor no esta disponible\"}";
    std::string arg = "{}";
    const std::string root = GetStringProp(msg.payloadJson, "rootDir");
    if (!root.empty())
      arg = "{\"root\":\"" + JsonEscape(root) + "\"}";
    CoreResult res =
        coreClient->CallJson(coreClient->Api().repo_embed_index, arg);
    if (!res.ok()) {
      std::string e =
          res.error.empty()
              ? ("El motor devolvio el codigo " + std::to_string(res.rc))
              : res.error;
      return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
             JsonEscape(e) + "\"}";
    }
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":" +
           (res.json.empty() ? "{}" : res.json) + "}";
  });

  // 5c. search.embedStatus — E5.15: estado del índice vectorial del repo
  // (state/chunks/files/model/updated_at). Payload {rootDir?, model?}.
  RegisterHandler("search.embedStatus", [coreClient](const BridgeMessage &msg) {
    if (!coreClient || !coreClient->EngineReady())
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"El motor no esta disponible\"}";
    std::string arg = "{";
    bool first = true;
    const std::string root = GetStringProp(msg.payloadJson, "rootDir");
    const std::string model = GetStringProp(msg.payloadJson, "model");
    if (!root.empty()) {
      arg += "\"root\":\"" + JsonEscape(root) + "\"";
      first = false;
    }
    if (!model.empty())
      arg += std::string(first ? "" : ",") + "\"model\":\"" +
             JsonEscape(model) + "\"";
    arg += "}";
    CoreResult res =
        coreClient->CallJson(coreClient->Api().repo_embed_status, arg);
    if (!res.ok()) {
      std::string e =
          res.error.empty()
              ? ("El motor devolvio el codigo " + std::to_string(res.rc))
              : res.error;
      return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
             JsonEscape(e) + "\"}";
    }
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":" +
           (res.json.empty() ? "{}" : res.json) + "}";
  });

  // 6. search.replace
  RegisterHandler("search.replace", [projectSearch](const BridgeMessage &msg) {
    if (!projectSearch)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"ProjectSearch unavailable\"}";
    SearchOptions opts;
    opts.query = GetStringProp(msg.payloadJson, "query");
    opts.rootDir = Utf8ToWide(GetStringProp(msg.payloadJson, "rootDir"));
    std::string replacement = GetStringProp(msg.payloadJson, "replacement");
    if (opts.query.empty() || opts.rootDir.empty()) {
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"Missing query or rootDir\"}";
    }
    std::string error;
    int count = projectSearch->ReplaceInFiles(opts, replacement, error);
    if (count < 0)
      return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
             JsonEscape(error) + "\"}";
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"replacedCount\":" +
           std::to_string(count) + "}}";
  });

  // 7. hunk.accept
  RegisterHandler("hunk.accept", [hunkMgr](const BridgeMessage &msg) {
    if (!hunkMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"HunkManager unavailable\"}";
    std::string pathStr = GetStringProp(msg.payloadJson, "path");
    int hunkId = GetIntProp(msg.payloadJson, "hunkId", 0);
    std::string origContent = GetStringProp(msg.payloadJson, "originalContent");
    std::string newContentOut;
    std::vector<Hunk> hunks;
    Hunk h;
    h.id = hunkId;
    h.startLine = GetIntProp(msg.payloadJson, "startLine", 0);
    h.originalLineCount = GetIntProp(msg.payloadJson, "originalLineCount", 0);
    h.newLineCount = GetIntProp(msg.payloadJson, "newLineCount", 0);
    h.originalContent = origContent;
    h.newContent = GetStringProp(msg.payloadJson, "newContent");
    hunks.push_back(h);
    std::string error;
    bool ok = hunkMgr->AcceptHunk(Utf8ToWide(pathStr), hunkId, origContent,
                                  hunks, newContentOut, &error);
    if (ok) {
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"newContent\":\"" +
             JsonEscape(newContentOut) + "\"}}";
    }
    return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
           JsonEscape(error.empty() ? "AcceptHunk failed" : error) + "\"}";
  });

  // 8. hunk.reject
  RegisterHandler("hunk.reject", [hunkMgr](const BridgeMessage &msg) {
    if (!hunkMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"HunkManager unavailable\"}";
    std::string pathStr = GetStringProp(msg.payloadJson, "path");
    int hunkId = GetIntProp(msg.payloadJson, "hunkId", 0);
    std::string origContent = GetStringProp(msg.payloadJson, "originalContent");
    // r4: `originalContent` son solo las lineas del hunk. El
    // contexto para verificar la reinsercion de un hunk de solo borrado exige
    // el original completo del diff, que la WebUI envia en `baseFileContent`.
    // Si falta, HunkManager falla sin escribir (nunca reinserta a ciegas).
    std::string baseFileContent =
        GetStringProp(msg.payloadJson, "baseFileContent");
    std::string newContentOut;
    std::vector<Hunk> hunks;
    Hunk h;
    h.id = hunkId;
    h.startLine = GetIntProp(msg.payloadJson, "startLine", 0);
    h.originalLineCount = GetIntProp(msg.payloadJson, "originalLineCount", 0);
    h.newLineCount = GetIntProp(msg.payloadJson, "newLineCount", 0);
    h.originalContent = origContent;
    h.newContent = GetStringProp(msg.payloadJson, "newContent");
    hunks.push_back(h);
    std::string error;
    bool ok = hunkMgr->RejectHunk(Utf8ToWide(pathStr), hunkId, baseFileContent,
                                  hunks, newContentOut, &error);
    if (ok) {
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"newContent\":\"" +
             JsonEscape(newContentOut) + "\"}}";
    }
    return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
           JsonEscape(error.empty() ? "RejectHunk failed" : error) + "\"}";
  });

  // 9. pty.spawn
  RegisterHandler("pty.spawn", [this, ptyMgr](const BridgeMessage &msg) {
    if (!ptyMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"PtyManager unavailable\"}";
    std::string shellPath = GetStringProp(msg.payloadJson, "shellPath");
    std::string workingDir = GetStringProp(msg.payloadJson, "workingDir");
    if (workingDir.empty() && m_documents)
      workingDir = preview::Narrow(m_documents->ActiveWorkspaceRoot());
    std::wstring executable;
    if (!security::ResolveShell(Utf8ToWide(shellPath), executable))
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"Shell fuera del registro del host\"}";
    int termId =
        ptyMgr->CreateTerminal(executable, Utf8ToWide(workingDir), nullptr);
    if (termId > 0) {
      // la vía real viaja con la respuesta. La interfaz anunciaba
      // «ConPTY» también cuando el host había caído a tuberías.
      const char *mode = ptyMgr->IsPseudoConsole(termId) ? "conpty" : "pipes";
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"terminalId\":" +
             std::to_string(termId) + ",\"mode\":\"" + mode + "\"}}";
    }
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"error\":\"Failed to spawn terminal\"}";
  });

  // 10. pty.write
  // Privileged residual capability: commands execute as the user. Requires
  // trusted-origin JavaScript; an XSS there inherits it. Shell allowlisting
  // constrains launch only and does not sandbox terminal input/execution.
  RegisterHandler("pty.write", [ptyMgr](const BridgeMessage &msg) {
    if (!ptyMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"PtyManager unavailable\"}";
    int termId = GetIntProp(msg.payloadJson, "terminalId", 0);
    std::string data = GetStringProp(msg.payloadJson, "data");
    bool ok = ptyMgr->WriteTerminal(termId, data);
    if (ok) {
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"written\":true}}";
    }
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"error\":\"Failed to write to terminal\"}";
  });

  // 10 bis. pty.resize (23-09). Con ConPTY de verdad, la pseudoconsola tiene
  // que saber el tamano del panel: se creaba a 80x25 y el panel mide ~36
  // columnas, asi que su cursor absoluto pisaba filas y la salida de un
  // comando desaparecia. Por tuberias no hace nada y lo dice (resized:false).
  RegisterHandler("pty.resize", [ptyMgr](const BridgeMessage &msg) {
    if (!ptyMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"PtyManager unavailable\"}";
    int termId = GetIntProp(msg.payloadJson, "terminalId", 0);
    int cols = GetIntProp(msg.payloadJson, "cols", 0);
    int rows = GetIntProp(msg.payloadJson, "rows", 0);
    if (cols < 2 || rows < 1 || cols > 1000 || rows > 1000)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"Invalid terminal size\"}";
    bool ok = ptyMgr->ResizeTerminal(termId, static_cast<short>(cols),
                                     static_cast<short>(rows));
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"resized\":" +
           (ok ? "true" : "false") + "}}";
  });

  // 11. pty.kill
  RegisterHandler("pty.kill", [ptyMgr](const BridgeMessage &msg) {
    if (!ptyMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"PtyManager unavailable\"}";
    int termId = GetIntProp(msg.payloadJson, "terminalId", 0);
    ptyMgr->CloseTerminal(termId);
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"killed\":true}}";
  });

  // 12. lsp.request
  RegisterHandler("lsp.request", [lspClient](const BridgeMessage &msg) {
    if (!lspClient)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"LspClient unavailable\"}";
    std::string serverCmd = GetStringProp(msg.payloadJson, "serverCmd");
    const std::string language = GetStringProp(msg.payloadJson, "language");
    if (!language.empty())
      serverCmd = language;
    std::wstring executable;
    if (!serverCmd.empty() &&
        !security::ResolveLsp(Utf8ToWide(serverCmd), executable))
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"LSP fuera del registro del host o no instalado\"}";
    std::string method = GetStringProp(msg.payloadJson, "method");
    std::string params = GetStringProp(msg.payloadJson, "params");
    int reqId = GetIntProp(msg.payloadJson, "requestId", 1);
    if (!lspClient->IsRunning()) {
      if (!serverCmd.empty()) {
        if (!lspClient->Start(executable, nullptr))
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"error\":\"No se pudo arrancar el LSP registrado\"}";
      }
    }
    bool ok =
        lspClient->SendRequest(reqId, method, params.empty() ? "{}" : params);
    if (ok) {
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"sent\":true}}";
    }
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"error\":\"LSP SendRequest failed\"}";
  });

  // 12b. pty.read — scrollback acumulado de una terminal.
  //
  // Faltaba: se podia crear una terminal y escribirle, pero no leer su salida,
  // asi que la terminal era inservible desde el WebUI. PtyManager ya guardaba
  // el scrollback; solo no estaba expuesto. La UI sondea con `sinceOffset`
  // para traerse unicamente lo nuevo.
  RegisterHandler("pty.read", [ptyMgr](const BridgeMessage &msg) {
    if (!ptyMgr)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"PtyManager unavailable\"}";
    // listing is an optional read operation on the existing
    // terminal channel. Instances and liveness come directly from PtyManager.
    if (GetBoolProp(msg.payloadJson, "list", false)) {
      std::string terminals = "[";
      for (const auto &terminal : ptyMgr->ListTerminals()) {
        if (terminals.size() > 1)
          terminals += ",";
        terminals += "{\"terminalId\":" + std::to_string(terminal.id) +
                     ",\"shellPath\":\"" +
                     JsonEscape(WideToUtf8(terminal.shellPath)) +
                     "\",\"cols\":" + std::to_string(terminal.cols) +
                     ",\"rows\":" + std::to_string(terminal.rows) +
                     ",\"running\":" + (terminal.running ? "true" : "false") +
                     ",\"mode\":\"" +
                     (terminal.pseudoConsole ? "conpty" : "pipes") + "\"}";
      }
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"terminals\":" + terminals +
             "]}}";
    }
    int termId = GetIntProp(msg.payloadJson, "terminalId", 0);
    int since = GetIntProp(msg.payloadJson, "sinceOffset", 0);
    std::string all = ptyMgr->GetScrollback(termId);
    if (since < 0 || (size_t)since > all.size())
      since = 0;
    std::string chunk = all.substr((size_t)since);
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"data\":\"" + JsonEscape(chunk) +
           "\",\"offset\":" + std::to_string(all.size()) + "}}";
  });

  // 12c. system.keep_awake — F7: la pantalla no se apaga con una orden en
  // marcha.
  //
  // Una orden puede tardar decenas de minutos con el usuario mirando la traza
  // sin tocar nada: sin ES_DISPLAY_REQUIRED el monitor se apaga a mitad de la
  // ejecución, y con políticas agresivas el equipo entero se suspende y se
  // lleva el trabajo por delante. Mientras haya al menos una orden viva la UI
  // pide `enable:true`; al terminar la última vuelve a ES_CONTINUOUS, que es
  // el estado normal del hilo (no hereda nada).
  RegisterHandler("system.keep_awake", [](const BridgeMessage &msg) {
    const bool enable = GetBoolProp(msg.payloadJson, "enable", false);
    const EXECUTION_STATE prev =
        enable ? SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED |
                                         ES_DISPLAY_REQUIRED)
               : SetThreadExecutionState(ES_CONTINUOUS);
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"active\":" +
           (enable ? "true" : "false") +
           ",\"prev\":" + std::to_string((unsigned long long)prev) + "}}";
  });

  // 13. core.status
  RegisterHandler("core.status", [this, coreClient](const BridgeMessage &msg) {
    // optional version handshake on the existing read-only bus
    // endpoint. Do not initialize/query a child engine for this handshake.
    const auto ui = GetStringProp(msg.payloadJson, "identity");
    if (!ui.empty()) {
      std::string mismatch = versions::Mismatch("WebUI", ui);
      const char *engine = coreClient && coreClient->Api().build_identity_v1
                               ? coreClient->Api().build_identity_v1()
                               : nullptr;
      if (mismatch.empty())
        mismatch = versions::Mismatch("motor DLL", engine ? engine : "");
      if (!mismatch.empty()) {
        std::cerr << "[CK-COMP-004] " << mismatch << std::endl;
        OutputDebugStringA((mismatch + "\n").c_str());
        return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
               JsonEscape(mismatch) + "\"}";
      }
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"status\":\"ok\",\"payload\":{\"host\":\"" +
             JsonEscape(DA_BUILD_IDENTITY) + "\",\"engine\":\"" +
             JsonEscape(engine) + "\"}}";
    }
    if (!coreClient)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"CoreClient unavailable\"}";
    CoreStatus st = coreClient->GetStatus();
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"running\":" +
           (st.running ? "true" : "false") +
           ",\"pid\":" + std::to_string(st.pid) + ",\"version\":\"" +
           JsonEscape(st.version) + "\",\"governanceMode\":\"" +
           JsonEscape(st.governanceMode) + "\",\"activeModel\":\"" +
           JsonEscape(st.activeModel) + "\",\"activeProvider\":\"" +
           JsonEscape(st.activeProvider) + "\",\"keyLabel\":\"" +
           JsonEscape(st.keyLabel) +
           "\",\"keyCount\":" + std::to_string(st.keyCount) +
           ",\"providerCount\":" + std::to_string(st.providerCount) +
           ",\"engineReady\":" + (st.engineReady ? "true" : "false") +
           ",\"initError\":\"" + JsonEscape(st.initError) +
           "\",\"workspaceRoot\":\"" +
           JsonEscape(m_documents
                          ? preview::Narrow(m_documents->ActiveWorkspaceRoot())
                          : "") +
           "\"}}";
  });

  // 14+. Superficie agentica: expone la API C del motor (c_api.zig) al WebUI.
  BindCoreHandlers(coreClient);
  BindFsHandlers(docMgr);
}

// ---------------------------------------------------------------------------
// Superficie agentica (core.*)
//
// Hasta aqui el puente solo cubria edicion/terminal/FS: la UI podia abrir
// archivos pero no hablar con el cerebro del motor. Estos handlers mapean
// 1:1 contra devagents_core.dll para que la cabina pueda registrar
// proveedores y claves, descubrir modelos, planificar ordenes, ejecutarlas y
// leer eventos, ledger y MCP.
//
// Convencion de payload: los valores que a su vez son JSON (planes,
// respuestas de clarificacion, argv de MCP, argumentos de tool) viajan como
// *cadena* en campos con sufijo `Json`, porque el parser de payload de este
// puente es deliberadamente minimo y no reserializa estructuras anidadas.
// ---------------------------------------------------------------------------
void Bridge::BindCoreHandlers(CoreClient *coreClient) {
  // Envuelve un CoreResult en la respuesta del puente. `payloadIsJson` decide
  // si el texto del motor se inserta crudo (arrays/objetos) o se cita.
  auto respond = [](int msgId, const CoreResult &res,
                    bool payloadIsJson = true) -> std::string {
    if (!res.ok()) {
      std::string e =
          res.error.empty()
              ? ("El motor devolvio el codigo " + std::to_string(res.rc))
              : res.error;
      return "{\"id\":" + std::to_string(msgId) + ",\"error\":\"" +
             JsonEscape(e) + "\"}";
    }
    std::string body =
        res.json.empty()
            ? "null"
            : (payloadIsJson ? res.json : ("\"" + JsonEscape(res.json) + "\""));
    return "{\"id\":" + std::to_string(msgId) +
           ",\"status\":\"ok\",\"payload\":" + body + "}";
  };

  auto okPayload = [](int msgId, const std::string &body) {
    return "{\"id\":" + std::to_string(msgId) +
           ",\"status\":\"ok\",\"payload\":" + body + "}";
  };

  auto failure = [](int msgId, const std::string &err) {
    return "{\"id\":" + std::to_string(msgId) + ",\"error\":\"" +
           JsonEscape(err) + "\"}";
  };

  // Guarda comun: motor cargado e inicializado.
  auto ready = [](CoreClient *c) { return c && c->EngineReady(); };

  // Los getters JSON del motor comparten firma `int fn(handle, char** out)`,
  // asi que se registran con una sola plantilla en vez de repetir el cuerpo.
#define BEATS_GETTER(KIND, FIELD)                                              \
  RegisterHandler(                                                             \
      KIND,                                                                    \
      [coreClient, respond, failure,                                           \
       ready](const BridgeMessage &msg) -> std::string {                       \
        if (!ready(coreClient))                                                \
          return failure(msg.id, "El motor no esta disponible");               \
        return respond(msg.id, coreClient->CallJson(coreClient->Api().FIELD)); \
      })

  BEATS_GETTER("core.webhooks.list", webhook_list_json);
  RegisterHandler("core.webhooks.add", [coreClient, ready, failure,
                                        okPayload](const BridgeMessage &msg) {
    if (!ready(coreClient) || !coreClient->Api().webhook_add)
      return failure(msg.id, "El motor no admite webhooks");
    long long id = 0;
    const int result = coreClient->Api().webhook_add(
        coreClient->Handle(), msg.payloadJson.c_str(), &id);
    if (result != 0)
      return failure(msg.id, coreClient->LastEngineError());
    return okPayload(msg.id, "{\"ok\":true,\"id\":" + std::to_string(id) + "}");
  });
  for (const std::string action : {"test", "delete"}) {
    RegisterHandler(
        "core.webhooks." + action, [coreClient, ready, failure, okPayload,
                                    action](const BridgeMessage &msg) {
          if (!ready(coreClient))
            return failure(msg.id, "El motor no está disponible");
          preview::Value value;
          if (!preview::Parser(msg.payloadJson).Parse(value) ||
              !preview::Keys(value, {"id"}) ||
              !preview::Number(value, "id", 1, 9007199254740991.0) ||
              std::floor(value.object.at("id").number) !=
                  value.object.at("id").number)
            return failure(msg.id, "ID de webhook inválido");
          const auto fn = action == "test" ? coreClient->Api().webhook_test
                                           : coreClient->Api().webhook_delete;
          if (!fn)
            return failure(msg.id, "El motor no admite webhooks");
          const int result =
              fn(coreClient->Handle(),
                 static_cast<long long>(value.object.at("id").number));
          if (result != 0)
            return failure(msg.id, coreClient->LastEngineError());
          return okPayload(msg.id, action == "test"
                                       ? "{\"ok\":true,\"queued\":true}"
                                       : "{\"ok\":true}");
        });
  }

  // --- Catalogo: proveedores, claves, modelos ------------------------------
  BEATS_GETTER("core.providers.list", providers_list_json);
  BEATS_GETTER("core.keys.list", keys_json);
  BEATS_GETTER("core.catalog.info", catalog_info_json);
  BEATS_GETTER("core.specialists", specialists_json);
  RegisterHandler(
      "core.sessions.list",
      [coreClient, ready, failure,
       okPayload](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no está disponible");
        // Sin «mode» se pide el historial activo, que es lo que enseña la
        // barra.
        const auto mode = GetStringProp(msg.payloadJson, "mode");
        const int filter = (mode.empty() || mode == "active") ? 0
                           : mode == "archived"               ? 1
                           : mode == "all"                    ? 2
                                                              : -1;
        if (filter < 0)
          return failure(msg.id, "Filtro de sesiones inválido");
        if (!coreClient->Api().sessions_json_filtered)
          return failure(msg.id, "El motor no admite el filtro de sesiones");
        char *json = nullptr;
        const auto result =
            coreClient->Wrap(coreClient->Api().sessions_json_filtered(
                coreClient->Handle(), filter, &json));
        // TakeString toma posesión y libera la cadena del motor, haya o no
        // error.
        const std::string payload =
            json ? coreClient->TakeString(json) : std::string();
        if (!result.ok())
          return failure(msg.id, result.error);
        return okPayload(msg.id, payload.empty() ? "[]" : payload);
      });
  // artefactos de una orden (da_list_artifacts_json). Es la red
  // de recuperacion de la tarjeta Resultados: los eventos file_written siguen
  // siendo la fuente viva, pero al reabrir una sesion el motor puede devolver
  // lo ya escrito en su carpeta de orden. Solo lectura; orderId=0 lista todo.
  RegisterHandler(
      "core.artifacts.list",
      [coreClient, ready, failure,
       okPayload](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no está disponible");
        if (!coreClient->Api().list_artifacts_json)
          return failure(msg.id, "El motor no admite el listado de artefactos");
        const auto orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        char *json = nullptr;
        const auto result =
            coreClient->Wrap(coreClient->Api().list_artifacts_json(
                coreClient->Handle(), orderId, &json));
        // TakeString toma posesion y libera la cadena del motor, haya o no
        // error.
        const std::string payload =
            json ? coreClient->TakeString(json) : std::string();
        if (!result.ok())
          return failure(msg.id, result.error);
        return okPayload(msg.id, payload.empty() ? "[]" : payload);
      });
  RegisterHandler(
      "core.session.archive",
      [coreClient, ready, failure,
       okPayload](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no está disponible");
        const auto orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        const auto archived = GetIntProp(msg.payloadJson, "archived", -1);
        if (orderId <= 0 || (archived != 0 && archived != 1))
          return failure(msg.id, "Faltan orderId o archived (0/1)");
        if (!coreClient->Api().session_archive)
          return failure(msg.id, "da_session_archive no disponible");
        const auto result = coreClient->Wrap(coreClient->Api().session_archive(
            coreClient->Handle(), OrderIdToHandle(orderId), archived));
        if (!result.ok())
          return failure(msg.id, result.error);
        return okPayload(msg.id, archived ? "{\"archived\":true}"
                                          : "{\"archived\":false}");
      });
  RegisterHandler(
      "core.session.archiveBefore.preview",
      [coreClient, ready, failure,
       okPayload](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no está disponible");
        const auto before = GetInt64Prop(msg.payloadJson, "before", 0);
        if (before <= 0)
          return failure(msg.id, "Falta la fecha de corte");
        if (!coreClient->Api().session_archive_before_preview)
          return failure(msg.id,
                         "da_session_archive_before_preview no disponible");
        int count = 0;
        const auto result =
            coreClient->Wrap(coreClient->Api().session_archive_before_preview(
                coreClient->Handle(), before, &count));
        if (!result.ok())
          return failure(msg.id, result.error);
        return okPayload(msg.id, "{\"count\":" + std::to_string(count) + "}");
      });
  RegisterHandler(
      "core.session.archiveBefore",
      [coreClient, ready, failure,
       okPayload](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no está disponible");
        const auto before = GetInt64Prop(msg.payloadJson, "before", 0);
        const auto expected = GetIntProp(msg.payloadJson, "expectedCount", -1);
        if (before <= 0 || expected < 0 ||
            !GetBoolProp(msg.payloadJson, "confirmed", false))
          return failure(
              msg.id,
              "Faltan la fecha, el recuento o la confirmación explícita");
        if (!coreClient->Api().session_archive_before)
          return failure(msg.id, "da_session_archive_before no disponible");
        int count = 0;
        const auto result =
            coreClient->Wrap(coreClient->Api().session_archive_before(
                coreClient->Handle(), before, expected, &count));
        if (!result.ok())
          return failure(msg.id, result.error);
        return okPayload(msg.id, "{\"count\":" + std::to_string(count) + "}");
      });
  BEATS_GETTER("core.ledger", audit_ledger_json);
  BEATS_GETTER("core.auditChecklist", audit_checklist_json);
  BEATS_GETTER("core.escalations", ledger_escalations_json);
  BEATS_GETTER("core.approvals.pending", approval_pending_json);
  BEATS_GETTER("core.health", health_summary_json);
  BEATS_GETTER("core.health.detail", health_detail_json);
  BEATS_GETTER("core.inventory", inventory_json);
  BEATS_GETTER("core.mounts.list", mounts_list_json);
  BEATS_GETTER("core.mcp.tools", mcp_tools_json);
  // Aprendizaje del router: el motor ya ajustaba las puntuaciones de cada
  // modelo tras cada auditoria y las usaba para enrutar, pero nadie las
  // mostraba. Esto es, literalmente, la tierlist de modelos ya calculada.
  BEATS_GETTER("core.model.scores", model_scores_json);
  BEATS_GETTER("core.evolution", evolution_summary_json);
  BEATS_GETTER("core.models.selection.v1", models_selection_v1_json);

  RegisterHandler(
      "core.models.preferences.set.v1",
      [coreClient, failure, respond,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) ||
            !coreClient->Api().model_preferences_set_v1_json)
          return failure(msg.id, "Preferencias de modelos v1 no disponibles");
        char *out = nullptr;
        auto result =
            coreClient->Wrap(coreClient->Api().model_preferences_set_v1_json(
                coreClient->Handle(), msg.payloadJson.c_str(), &out));
        if (out) {
          result.json = out;
          coreClient->Api().string_free(out);
        }
        return respond(msg.id, result);
      });

#undef BEATS_GETTER

  // Pese a su nombre, da_models_list_json devuelve una TABLA de texto
  // (catalog.listModels), no JSON. Se entrega citada para no romper la
  // respuesta del puente; los datos estructurados de modelos vienen dentro de
  // core.providers.list, que sí es JSON.
  RegisterHandler(
      "core.models.list",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        return respond(msg.id,
                       coreClient->CallJson(coreClient->Api().models_list_json),
                       false);
      });

  RegisterHandler(
      "core.provider.add",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().provider_add)
          return failure(msg.id, "da_provider_add no disponible");
        std::string name = GetStringProp(msg.payloadJson, "name");
        std::string apiStyle = GetStringProp(msg.payloadJson, "apiStyle");
        std::string baseUrl = GetStringProp(msg.payloadJson, "baseUrl");
        if (name.empty() || apiStyle.empty() || baseUrl.empty())
          return failure(msg.id, "Faltan name, apiStyle o baseUrl");
        CoreResult r = coreClient->Wrap(
            coreClient->Api().provider_add(coreClient->Handle(), name.c_str(),
                                           apiStyle.c_str(), baseUrl.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"added\":true}");
      });

  RegisterHandler("core.keys.add",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().key_add)
                      return failure(msg.id, "da_key_add no disponible");
                    std::string provider =
                        GetStringProp(msg.payloadJson, "provider");
                    std::string label = GetStringProp(msg.payloadJson, "label");
                    std::string key = GetStringProp(msg.payloadJson, "key");
                    if (provider.empty() || label.empty() || key.empty())
                      return failure(msg.id, "Faltan provider, label o key");
                    CoreResult r = coreClient->Wrap(coreClient->Api().key_add(
                        coreClient->Handle(), provider.c_str(), label.c_str(),
                        key.c_str()));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"added\":true}");
                  });

  RegisterHandler(
      "core.keys.remove",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().key_remove)
          return failure(msg.id, "da_key_remove no disponible");
        std::string provider = GetStringProp(msg.payloadJson, "provider");
        std::string label = GetStringProp(msg.payloadJson, "label");
        if (provider.empty())
          return failure(msg.id, "Falta provider");

        // Una etiqueta vacia significa COMODIN para el motor: borra TODAS las
        // claves del proveedor. Eso convirtio un descuido del arnes de pruebas
        // en la perdida de las tres claves reales de Gemini del usuario.
        //
        // Ahora el comodin exige pedirlo por su nombre. Un `label` ausente,
        // vacio o mal escrito ya no puede vaciar un proveedor por accidente.
        if (label.empty() &&
            msg.payloadJson.find("\"allowAll\":true") == std::string::npos) {
          return failure(
              msg.id, "Falta label. Para borrar TODAS las claves del proveedor "
                      "hay que enviar ademas allowAll:true.");
        }
        CoreResult r = coreClient->Wrap(coreClient->Api().key_remove(
            coreClient->Handle(), provider.c_str(), label.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"removed\":true}");
      });

  // E1.13 multi-cuenta: editar prioridad/cuota/estado de una clave concreta.
  RegisterHandler(
      "core.keys.setMeta",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().key_set_meta)
          return failure(msg.id, "da_key_set_meta no disponible");
        std::string provider = GetStringProp(msg.payloadJson, "provider");
        std::string label = GetStringProp(msg.payloadJson, "label");
        std::string status = GetStringProp(msg.payloadJson, "status");
        if (provider.empty() || label.empty())
          return failure(msg.id, "Faltan provider o label");
        // -1 = no tocar el campo; la UI manda el valor nuevo o lo omite.
        int priority = GetIntProp(msg.payloadJson, "priority", -1);
        int quotaLimit = GetIntProp(msg.payloadJson, "quotaLimit", -1);
        CoreResult r = coreClient->Wrap(coreClient->Api().key_set_meta(
            coreClient->Handle(), provider.c_str(), label.c_str(), priority,
            quotaLimit, status.empty() ? nullptr : status.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"updated\":true}");
      });

  RegisterHandler(
      "core.models.discover",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().models_discover)
          return failure(msg.id, "da_models_discover no disponible");
        int count = 0;
        CoreResult r = coreClient->Wrap(
            coreClient->Api().models_discover(coreClient->Handle(), &count));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"count\":" + std::to_string(count) + "}");
      });

  RegisterHandler("core.model.register",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().model_register)
                      return failure(msg.id, "da_model_register no disponible");
                    std::string provider =
                        GetStringProp(msg.payloadJson, "provider");
                    std::string model = GetStringProp(msg.payloadJson, "model");
                    int context = GetIntProp(msg.payloadJson, "context", 0);
                    bool isFree = GetBoolProp(msg.payloadJson, "isFree", true);
                    if (provider.empty() || model.empty())
                      return failure(msg.id, "Faltan provider o model");
                    CoreResult r =
                        coreClient->Wrap(coreClient->Api().model_register(
                            coreClient->Handle(), provider.c_str(),
                            model.c_str(), context, isFree ? 1 : 0));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"registered\":true}");
                  });

  RegisterHandler(
      "core.health.probe",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().health_probe_all_json)
          return failure(msg.id, "da_health_probe_all_json no disponible");
        // DESBLOQUEADO 2026-08-06, tras atacar las dos causas.
        //
        // Historia, porque importa: esta ruta estuvo cerrada desde el
        // 2026-08-05 porque `da_health_probe_all_json` abortaba el proceso
        // (codigo de salida 3, un abort() limpio, sin excepcion de Windows) y,
        // como el motor vive EN EL PROCESO de la cabina, se llevaba la ventana
        // entera: el usuario pulsaba "Sondear ahora" y DevAgents desaparecia.
        //
        // Las dos causas atacadas, que son los pasos 1 y 2 del plan de
        // CRASH-SONDEO-SALUD.md y llevaban sin ejecutarse:
        //
        //  1. `sqlite3.c` se compilaba SIN -DNDEBUG, o sea con sus assert()
        //     activos en las builds Debug, que son las de diario. Un assert de
        //     la CRT llama a abort() = ExitProcess(3): sin dialogo, sin entrada
        //     en el registro de sucesos y sin pasar por el filtro de
        //     excepciones. Encaja exactamente con el sintoma.
        //  2. `runActiveHealthProbeAll` sondeaba DENTRO del bucle del SELECT,
        //     con un cursor de lectura abierto sobre el catalogo mientras
        //     `probeModel` reabria ese MISMO catalogo por ruta y escribia
        //     salud. Ahora se vuelcan los pares, se finaliza la sentencia, y
        //     solo despues se sondea.
        //
        // Verificado con el arnes `--test-bridge`, que es un binario de consola
        // sin ventana: la llamada devuelve su JSON y el proceso sigue vivo.
        // Si vuelve a aparecer, la salida sera de nuevo un exit 3 silencioso.
        std::string maxModels =
            GetStringProp(msg.payloadJson, "maxModels"); // informativo
        (void)maxModels;
        int limit = GetIntProp(msg.payloadJson, "maxModels", 0);
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().health_probe_all_json(coreClient->Handle(),
                                                       limit, &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.router.candidates",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().router_candidates_json)
          return failure(msg.id, "da_router_candidates_json no disponible");
        std::string taskType = GetStringProp(msg.payloadJson, "taskType");
        if (taskType.empty())
          taskType = "planificar";
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().router_candidates_json(coreClient->Handle(),
                                                        taskType.c_str(), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  // --- Modelo de planificacion --------------------------------------------
  RegisterHandler(
      "core.plan.setModel",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().plan_set_model)
          return failure(msg.id, "da_plan_set_model no disponible");
        std::string provider = GetStringProp(msg.payloadJson, "provider");
        std::string model = GetStringProp(msg.payloadJson, "model");
        // Cadenas vacias = volver a modo automatico (router decide).
        CoreResult r = coreClient->Wrap(coreClient->Api().plan_set_model(
            coreClient->Handle(), provider.empty() ? nullptr : provider.c_str(),
            model.empty() ? nullptr : model.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  // modo Directo, un solo modelo como una CLI (sin planificar).
  RegisterHandler(
      "core.plan.setDirect",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().set_direct_mode)
          return failure(msg.id, "da_set_direct_mode no disponible");
        bool enabled = GetBoolProp(msg.payloadJson, "enabled", false);
        // USUARIO-NUEVO B (10-nov): modo «DevAgents» = Directo que puede
        // delegar subtareas (valor 2 del mismo export; aditivo, R4).
        bool delegate =
            enabled && GetBoolProp(msg.payloadJson, "delegate", false);
        CoreResult r = coreClient->Wrap(coreClient->Api().set_direct_mode(
            coreClient->Handle(), delegate ? 2 : (enabled ? 1 : 0)));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id,
                         delegate  ? "{\"enabled\":true,\"delegate\":true}"
                         : enabled ? "{\"enabled\":true,\"delegate\":false}"
                                   : "{\"enabled\":false,\"delegate\":false}");
      });

  RegisterHandler(
      "core.plan.getDirect",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().get_direct_mode)
          return failure(msg.id, "da_get_direct_mode no disponible");
        int enabled = 0;
        CoreResult r = coreClient->Wrap(
            coreClient->Api().get_direct_mode(coreClient->Handle(), &enabled));
        if (!r.ok())
          return failure(msg.id, r.error);
        std::string payload = "{\"enabled\":false,\"delegate\":false}";
        if (enabled == 2)
          payload = "{\"enabled\":true,\"delegate\":true}";
        else if (enabled)
          payload = "{\"enabled\":true,\"delegate\":false}";
        return okPayload(msg.id, payload);
      });

  // Modo determinista: el modelo fijado hace la orden entera, sin respaldos.
  RegisterHandler(
      "core.plan.setDeterministic",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().set_deterministic_mode)
          return failure(msg.id, "da_set_deterministic_mode no disponible");
        bool enabled = GetBoolProp(msg.payloadJson, "enabled", false);
        CoreResult r =
            coreClient->Wrap(coreClient->Api().set_deterministic_mode(
                coreClient->Handle(), enabled ? 1 : 0));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, enabled ? "{\"enabled\":true}"
                                         : "{\"enabled\":false}");
      });

  // D2(a): tope del loop agéntico observe→re-planifica. 1 = un paso (estable);
  // >=2 permite al motor re-planificar tras terminar una ola, dentro del
  // presupuesto común. El setter ya existía en la C API pero no tenía salida
  // al puente — era inalcanzable desde la cabina.
  RegisterHandler(
      "core.agentic.setIterations",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().set_agentic_max_iterations)
          return failure(msg.id, "da_set_agentic_max_iterations no disponible");
        int n = GetIntProp(msg.payloadJson, "iterations", 1);
        CoreResult r =
            coreClient->Wrap(coreClient->Api().set_agentic_max_iterations(
                coreClient->Handle(), (unsigned int)n));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler(
      "core.agentic.getIterations",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().get_agentic_max_iterations)
          return failure(msg.id, "da_get_agentic_max_iterations no disponible");
        unsigned int n = 1;
        CoreResult r =
            coreClient->Wrap(coreClient->Api().get_agentic_max_iterations(
                coreClient->Handle(), &n));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"iterations\":" + std::to_string(n) + "}");
      });

  RegisterHandler(
      "core.plan.getDeterministic",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().get_deterministic_mode)
          return failure(msg.id, "da_get_deterministic_mode no disponible");
        int enabled = 0;
        CoreResult r =
            coreClient->Wrap(coreClient->Api().get_deterministic_mode(
                coreClient->Handle(), &enabled));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, enabled ? "{\"enabled\":true}"
                                         : "{\"enabled\":false}");
      });

  RegisterHandler(
      "core.plan.getModel",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().plan_get_model)
          return failure(msg.id, "da_plan_get_model no disponible");
        const char *prov = nullptr;
        const char *model = nullptr;
        if (coreClient->Api().plan_get_model(coreClient->Handle(), &prov,
                                             &model) != 0)
          return failure(msg.id, coreClient->LastEngineError());
        std::string p =
            prov ? coreClient->TakeString(const_cast<char *>(prov)) : "";
        std::string m =
            model ? coreClient->TakeString(const_cast<char *>(model)) : "";
        return okPayload(msg.id, "{\"provider\":\"" + JsonEscape(p) +
                                     "\",\"model\":\"" + JsonEscape(m) + "\"}");
      });

  RegisterHandler(
      "core.swarm.setEnabled",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().swarm_set_enabled)
          return failure(msg.id, "Interruptor de enjambre no disponible");
        CoreResult r = coreClient->Wrap(coreClient->Api().swarm_set_enabled(
            coreClient->Handle(),
            GetBoolProp(msg.payloadJson, "enabled") ? 1 : 0));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });
  RegisterHandler(
      "core.swarm.getEnabled",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().swarm_get_enabled)
          return failure(msg.id, "Interruptor de enjambre no disponible");
        int enabled = 0;
        CoreResult r = coreClient->Wrap(coreClient->Api().swarm_get_enabled(
            coreClient->Handle(), &enabled));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, enabled ? "{\"enabled\":true}"
                                         : "{\"enabled\":false}");
      });
  RegisterHandler(
      "core.roles.setModel",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().role_set_model)
          return failure(msg.id,
                         "Pines de especialista no disponibles en este motor");
        const auto role = GetStringProp(msg.payloadJson, "role");
        const auto provider = GetStringProp(msg.payloadJson, "provider");
        const auto model = GetStringProp(msg.payloadJson, "model");
        CoreResult r = coreClient->Wrap(
            coreClient->Api().role_set_model(coreClient->Handle(), role.c_str(),
                                             provider.c_str(), model.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });
  RegisterHandler(
      "core.roles.getModels",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().role_models_json)
          return failure(msg.id,
                         "Pines de especialista no disponibles en este motor");
        char *json = nullptr;
        CoreResult r = coreClient->Wrap(
            coreClient->Api().role_models_json(coreClient->Handle(), &json));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, coreClient->TakeString(json));
      });
  RegisterHandler(
      "core.composer.review",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().composer_review_json)
          return failure(msg.id, "Modo de revisión no disponible");
        char *json = nullptr;
        CoreResult r = coreClient->Wrap(coreClient->Api().composer_review_json(
            coreClient->Handle(), &json));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, coreClient->TakeString(json));
      });

  // ROLES-MODELO: pin por rol. El de la orden (core.plan.setModel) sigue siendo
  // el general: ejecutor y auditor lo heredan si no tienen pin propio.
  RegisterHandler(
      "core.exec.setModel",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().exec_set_model)
          return failure(msg.id, "da_exec_set_model no disponible");
        std::string provider = GetStringProp(msg.payloadJson, "provider");
        std::string model = GetStringProp(msg.payloadJson, "model");
        CoreResult r = coreClient->Wrap(coreClient->Api().exec_set_model(
            coreClient->Handle(), provider.empty() ? nullptr : provider.c_str(),
            model.empty() ? nullptr : model.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler(
      "core.exec.getModel",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().exec_get_model)
          return failure(msg.id, "da_exec_get_model no disponible");
        const char *prov = nullptr;
        const char *model = nullptr;
        if (coreClient->Api().exec_get_model(coreClient->Handle(), &prov,
                                             &model) != 0)
          return failure(msg.id, coreClient->LastEngineError());
        std::string p =
            prov ? coreClient->TakeString(const_cast<char *>(prov)) : "";
        std::string m =
            model ? coreClient->TakeString(const_cast<char *>(model)) : "";
        return okPayload(msg.id, "{\"provider\":\"" + JsonEscape(p) +
                                     "\",\"model\":\"" + JsonEscape(m) + "\"}");
      });

  RegisterHandler(
      "core.audit.setModel",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().audit_set_model)
          return failure(msg.id, "da_audit_set_model no disponible");
        std::string provider = GetStringProp(msg.payloadJson, "provider");
        std::string model = GetStringProp(msg.payloadJson, "model");
        CoreResult r = coreClient->Wrap(coreClient->Api().audit_set_model(
            coreClient->Handle(), provider.empty() ? nullptr : provider.c_str(),
            model.empty() ? nullptr : model.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler(
      "core.audit.getModel",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().audit_get_model)
          return failure(msg.id, "da_audit_get_model no disponible");
        const char *prov = nullptr;
        const char *model = nullptr;
        if (coreClient->Api().audit_get_model(coreClient->Handle(), &prov,
                                              &model) != 0)
          return failure(msg.id, coreClient->LastEngineError());
        std::string p =
            prov ? coreClient->TakeString(const_cast<char *>(prov)) : "";
        std::string m =
            model ? coreClient->TakeString(const_cast<char *>(model)) : "";
        return okPayload(msg.id, "{\"provider\":\"" + JsonEscape(p) +
                                     "\",\"model\":\"" + JsonEscape(m) + "\"}");
      });

  // ENJAMBRE: conjunto cerrado de modelos para las tareas productoras. El
  // payload viaja como cadena JSON en `json` (convención `*Json` del puente):
  // "[]"/"" = Automático. El motor valida la forma y normaliza.
  RegisterHandler(
      "core.swarm.setModels",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().swarm_set_models_json)
          return failure(msg.id, "da_swarm_set_models_json no disponible");
        std::string json = GetStringProp(msg.payloadJson, "json");
        CoreResult r = coreClient->Wrap(coreClient->Api().swarm_set_models_json(
            coreClient->Handle(), json.empty() ? nullptr : json.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler("core.swarm.getModels",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(
                        msg.id, coreClient->CallJson(
                                    coreClient->Api().swarm_get_models_json));
                  });

  // E5.08 — agentes externos (GOBIERNO ENCIMA): detección del registro y
  // límites configurables. El payload de set viaja como cadena JSON en `json`.
  RegisterHandler("core.order.preflight",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(msg.id,
                                   coreClient->CallJson(
                                       coreClient->Api().order_preflight_json));
                  });

  RegisterHandler("core.external.agents",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(msg.id,
                                   coreClient->CallJson(
                                       coreClient->Api().external_agents_json));
                  });

  // Tanda 4 (F0.5): `doctor`, la comprobación antes de la primera orden.
  RegisterHandler("core.doctor",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(msg.id, coreClient->CallJson(
                                               coreClient->Api().doctor_json));
                  });

  // Tanda 5 (F0.4): actualizador «avisar y aplicar al cerrar». Todas
  // devuelven el estado del motor (da_update_state_json); check y download
  // salen a GitHub (carril lento). Ningún payload lleva rutas ni URLs: el
  // motor solo baja lo que su última comprobación guardó del repositorio.
  RegisterHandler(
      "core.update.state",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        return respond(
            msg.id, coreClient->CallJson(coreClient->Api().update_state_json));
      });
  RegisterHandler(
      "core.update.check",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().update_check_json)
          return failure(msg.id, "da_update_check_json no disponible");
        char *raw = nullptr;
        const int rc = coreClient->Api().update_check_json(
            coreClient->Handle(),
            GetBoolProp(msg.payloadJson, "force", false) ? 1 : 0, &raw);
        CoreResult r{rc, coreClient->TakeString(raw), ""};
        if (!r.ok())
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });
  RegisterHandler("core.update.download",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(msg.id,
                                   coreClient->CallJson(
                                       coreClient->Api().update_download_json));
                  });
  RegisterHandler(
      "core.update.setEnabled",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().update_set_enabled)
          return failure(msg.id, "Ajuste de actualizaciones no disponible");
        CoreResult r = coreClient->Wrap(coreClient->Api().update_set_enabled(
            coreClient->Handle(),
            GetBoolProp(msg.payloadJson, "enabled", false) ? 1 : 0));
        if (!r.ok())
          return failure(msg.id, r.error);
        return respond(
            msg.id, coreClient->CallJson(coreClient->Api().update_state_json));
      });
  // T7 (e): «Reglas del proyecto» en Configuración. Se guardan en
  // el motor por carpeta de proyecto y llegan a Directo, Orquestado, Colmena,
  // delegación y CLIs externas (core/src/project_rules.zig).
  RegisterHandler(
      "core.project.rules.get",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().project_rules_get_json)
          return failure(msg.id, "Reglas del proyecto no disponibles");
        return respond(msg.id, coreClient->CallJson(
                                   coreClient->Api().project_rules_get_json));
      });
  RegisterHandler(
      "core.project.rules.set",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().project_rules_set ||
            !coreClient->Api().project_rules_get_json)
          return failure(msg.id, "Reglas del proyecto no disponibles");
        const bool reset = GetBoolProp(msg.payloadJson, "reset", false);
        const std::string rules = GetStringProp(msg.payloadJson, "rules");
        const std::string canonical =
            reset ? std::string("{\"reset\":true}")
                  : "{\"rules\":\"" + JsonEscape(rules) + "\"}";
        CoreResult r = coreClient->Wrap(coreClient->Api().project_rules_set(
            coreClient->Handle(), canonical.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return respond(msg.id, coreClient->CallJson(
                                   coreClient->Api().project_rules_get_json));
      });
  // T7 (f): cuentas por CLI. El host reconstruye JSON canónico;
  // el inicio de sesión lo hace el usuario en la terminal integrada.
  RegisterHandler(
      "core.cliAccounts.list",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().cli_accounts_json)
          return failure(msg.id, "Cuentas de CLI no disponibles");
        return respond(
            msg.id, coreClient->CallJson(coreClient->Api().cli_accounts_json));
      });
  RegisterHandler(
      "core.cliAccounts.add",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().cli_account_add ||
            !coreClient->Api().cli_accounts_json)
          return failure(msg.id, "Cuentas de CLI no disponibles");
        const std::string canonical =
            "{\"cli\":\"" + JsonEscape(GetStringProp(msg.payloadJson, "cli")) +
            "\",\"label\":\"" +
            JsonEscape(GetStringProp(msg.payloadJson, "label")) + "\"}";
        CoreResult r = coreClient->Wrap(coreClient->Api().cli_account_add(
            coreClient->Handle(), canonical.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return respond(
            msg.id, coreClient->CallJson(coreClient->Api().cli_accounts_json));
      });
  RegisterHandler(
      "core.cliAccounts.remove",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().cli_account_remove ||
            !coreClient->Api().cli_accounts_json)
          return failure(msg.id, "Cuentas de CLI no disponibles");
        const std::string id = GetStringProp(msg.payloadJson, "id");
        CoreResult r = coreClient->Wrap(coreClient->Api().cli_account_remove(
            coreClient->Handle(), id.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return respond(
            msg.id, coreClient->CallJson(coreClient->Api().cli_accounts_json));
      });
  RegisterHandler(
      "core.cliAccounts.select",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().cli_account_select ||
            !coreClient->Api().cli_accounts_json)
          return failure(msg.id, "Cuentas de CLI no disponibles");
        const std::string id = GetStringProp(msg.payloadJson, "id");
        const std::string canonical =
            "{\"cli\":\"" + JsonEscape(GetStringProp(msg.payloadJson, "cli")) +
            "\",\"id\":" +
            (id.empty() ? std::string("null") : "\"" + JsonEscape(id) + "\"") +
            "}";
        CoreResult r = coreClient->Wrap(coreClient->Api().cli_account_select(
            coreClient->Handle(), canonical.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return respond(
            msg.id, coreClient->CallJson(coreClient->Api().cli_accounts_json));
      });
  RegisterHandler(
      "core.update.applyOnExit",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().update_set_apply_on_exit)
          return failure(msg.id, "Instalar al cerrar no disponible");
        // T12 M3: "unverified":true es el consentimiento explícito de
        // instalar una actualización sin firma verificable (el motor lo
        // exige aparte del «Instalar»).
        const bool apply = GetBoolProp(msg.payloadJson, "apply", false);
        const bool unverified =
            GetBoolProp(msg.payloadJson, "unverified", false);
        CoreResult r =
            coreClient->Wrap(coreClient->Api().update_set_apply_on_exit(
                coreClient->Handle(), !apply ? 0 : (unverified ? 2 : 1)));
        if (!r.ok())
          return failure(msg.id, r.error);
        return respond(
            msg.id, coreClient->CallJson(coreClient->Api().update_state_json));
      });

  RegisterHandler("core.external.refresh",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(
                        msg.id, coreClient->CallJson(
                                    coreClient->Api().external_agents_refresh));
                  });
  RegisterHandler("core.external.paths.get",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(msg.id,
                                   coreClient->CallJson(
                                       coreClient->Api().external_paths_json));
                  });
  RegisterHandler(
      "core.external.paths.set",
      [coreClient, okPayload, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().external_paths_set)
          return failure(msg.id, "external paths no disponible");
        const std::string json = GetStringProp(msg.payloadJson, "json");
        CoreResult r = coreClient->Wrap(coreClient->Api().external_paths_set(
            coreClient->Handle(), json.empty() ? nullptr : json.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });
  RegisterHandler(
      "core.external.options.set",
      [coreClient, okPayload, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient) || !coreClient->Api().external_model_options_set)
          return failure(msg.id, "external options no disponible");
        const std::string json = GetStringProp(msg.payloadJson, "json");
        CoreResult r =
            coreClient->Wrap(coreClient->Api().external_model_options_set(
                coreClient->Handle(), json.empty() ? nullptr : json.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler("core.external.limits.get",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(msg.id,
                                   coreClient->CallJson(
                                       coreClient->Api().external_limits_json));
                  });

  RegisterHandler(
      "core.external.limits.set",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().external_limits_set)
          return failure(msg.id, "da_external_limits_set no disponible");
        std::string json = GetStringProp(msg.payloadJson, "json");
        CoreResult r = coreClient->Wrap(coreClient->Api().external_limits_set(
            coreClient->Handle(), json.empty() ? nullptr : json.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler("core.vision.probe", [coreClient, failure, okPayload,
                                        ready](const BridgeMessage &msg) {
    if (!ready(coreClient) || !coreClient->Api().vision_probe_json)
      return failure(msg.id, "da_vision_probe_json no disponible");
    const std::string provider = GetStringProp(msg.payloadJson, "provider");
    const std::string model = GetStringProp(msg.payloadJson, "model");
    if (provider.empty() || model.empty())
      return failure(msg.id, "Falta proveedor/modelo");
    char *json = nullptr;
    CoreResult r = coreClient->Wrap(coreClient->Api().vision_probe_json(
        coreClient->Handle(), provider.c_str(), model.c_str(), &json));
    if (!r.ok())
      return failure(msg.id, r.error);
    std::string body = json ? json : "{}";
    if (json)
      coreClient->Api().string_free(json);
    return okPayload(msg.id, body);
  });

  // --- Ciclo de una orden: submit -> plan -> approve -> dispatch -----------
  for (const char *kind : {"core.issues.list", "core.issues.read",
                           "core.issues.prompt", "core.issues.comment"}) {
    RegisterHandler(
        kind,
        [coreClient, respond, failure, ready,
         action = std::string(kind)](const BridgeMessage &msg) -> std::string {
          if (!ready(coreClient))
            return failure(msg.id, "El motor no esta disponible");
          if (msg.payloadJson.size() > 65536)
            return failure(msg.id, "Peticion de incidencia demasiado grande");
          int (*fn)(void *, const char *, char **) = nullptr;
          if (action == "core.issues.list")
            fn = coreClient->Api().issues_list_json;
          else if (action == "core.issues.read")
            fn = coreClient->Api().issue_read_json;
          else if (action == "core.issues.prompt")
            fn = coreClient->Api().issue_prompt_json;
          else {
            if (!GetBoolProp(msg.payloadJson, "explicit", false))
              return failure(msg.id, "Comentar requiere una accion explicita");
            fn = coreClient->Api().issue_comment_json;
          }
          if (!fn)
            return failure(msg.id, "API de incidencias no disponible");
          char *out = nullptr;
          CoreResult result;
          result.rc = fn(coreClient->Handle(), msg.payloadJson.c_str(), &out);
          result.json = coreClient->TakeString(out);
          if (result.rc != 0)
            result.error = coreClient->LastEngineError();
          return respond(msg.id, result);
        });
  }
  RegisterHandler(
      "core.order.fromIssue",
      [this, coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!m_documents || m_documents->ActiveWorkspaceRoot().empty())
          return failure(msg.id,
                         "E_WORKSPACE_REQUIRED: Elige una carpeta de proyecto "
                         "autorizada antes de enviar una orden.");
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_from_issue_images_async)
          return failure(msg.id, "da_order_from_issue_async no disponible");
        const std::string request =
            GetStringProp(msg.payloadJson, "issueRequest");
        const std::string text = GetStringProp(msg.payloadJson, "text");
        std::string project = GetStringProp(msg.payloadJson, "project");
        const std::string conv =
            GetStringProp(msg.payloadJson, "conversationId");
        if (request.empty() || request.size() > 65536 || text.size() > 32768)
          return failure(msg.id,
                         "Peticion de incidencia invalida o demasiado grande");
        if (project.empty())
          project = "default";
        std::string images;
        size_t imageStart =
            FindTopLevelValuePos(msg.payloadJson, "attachments");
        if (imageStart != std::string::npos) {
          if (msg.payloadJson[imageStart] != '[')
            return failure(msg.id, "attachments debe ser un array");
          size_t imageEnd = MatchContainerEnd(msg.payloadJson, imageStart);
          if (imageEnd == std::string::npos)
            return failure(msg.id, "attachments incompleto");
          images = msg.payloadJson.substr(imageStart, imageEnd - imageStart);
        }
        void *order = nullptr;
        const bool waitPlan =
            GetBoolProp(msg.payloadJson, "waitForPlanApproval", false);
        if (waitPlan && !coreClient->Api().order_submit_options_async)
          return failure(msg.id,
                         "El motor no ofrece modo plan; actualiza el motor");
        const std::string options =
            "{\"wait_for_plan_approval\":true,\"issue_request\":\"" +
            JsonEscape(request) + "\"}";
        CoreResult result = coreClient->Wrap(
            waitPlan
                ? coreClient->Api().order_submit_options_async(
                      coreClient->Handle(), text.c_str(), project.c_str(),
                      conv.empty() ? nullptr : conv.c_str(),
                      images.empty() ? nullptr : images.c_str(),
                      options.c_str(), &order)
                : coreClient->Api().order_from_issue_images_async(
                      coreClient->Handle(), request.c_str(), text.c_str(),
                      project.c_str(), conv.empty() ? nullptr : conv.c_str(),
                      images.empty() ? nullptr : images.c_str(), &order));
        if (!result.ok())
          return failure(msg.id, result.error);
        const int bon =
            static_cast<int>(GetInt64Prop(msg.payloadJson, "bestOfN", 0));
        if (bon > 0) {
          if (!coreClient->Api().order_set_best_of_n)
            return failure(msg.id, "da_order_set_best_of_n no disponible");
          const std::string members =
              GetStringProp(msg.payloadJson, "bestOfNMembers");
          CoreResult configured =
              coreClient->Wrap(coreClient->Api().order_set_best_of_n(
                  coreClient->Handle(), order, bon,
                  members.empty() ? nullptr : members.c_str()));
          if (!configured.ok())
            return failure(msg.id, configured.error);
        }
        NoteSessionOrder(OrderHandleToId(order));
        return okPayload(
            msg.id,
            "{\"orderId\":" + std::to_string(OrderHandleToId(order)) + "}");
      });
  RegisterHandler(
      "core.order.submit",
      [this, coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!m_documents || m_documents->ActiveWorkspaceRoot().empty())
          return failure(msg.id,
                         "E_WORKSPACE_REQUIRED: Elige una carpeta de proyecto "
                         "autorizada antes de enviar una orden.");
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_submit_async)
          return failure(msg.id, "da_order_submit_async no disponible");
        std::string text = GetStringProp(msg.payloadJson, "text");
        std::string project = GetStringProp(msg.payloadJson, "project");
        std::string conv = GetStringProp(msg.payloadJson, "conversationId");
        if (text.empty())
          return failure(msg.id, "La orden esta vacia");
        if (project.empty())
          project = "default";
        void *order = nullptr;
        std::string images;
        size_t imageStart =
            FindTopLevelValuePos(msg.payloadJson, "attachments");
        if (imageStart != std::string::npos) {
          if (msg.payloadJson[imageStart] != '[')
            return failure(msg.id, "attachments debe ser un array");
          size_t imageEnd = MatchContainerEnd(msg.payloadJson, imageStart);
          if (imageEnd == std::string::npos)
            return failure(msg.id, "attachments incompleto");
          images = msg.payloadJson.substr(imageStart, imageEnd - imageStart);
        }
        if (!images.empty() && !coreClient->Api().order_submit_images_async)
          return failure(msg.id, "da_order_submit_images_async no disponible");
        const bool waitPlan =
            GetBoolProp(msg.payloadJson, "waitForPlanApproval", false);
        if (waitPlan && !coreClient->Api().order_submit_options_async)
          return failure(msg.id,
                         "El motor no ofrece modo plan; actualiza el motor");
        CoreResult r = coreClient->Wrap(
            waitPlan ? coreClient->Api().order_submit_options_async(
                           coreClient->Handle(), text.c_str(), project.c_str(),
                           conv.empty() ? nullptr : conv.c_str(),
                           images.empty() ? nullptr : images.c_str(),
                           "{\"wait_for_plan_approval\":true}", &order)
            : images.empty()
                ? coreClient->Api().order_submit_async(
                      coreClient->Handle(), text.c_str(), project.c_str(),
                      conv.empty() ? nullptr : conv.c_str(), &order)
                : coreClient->Api().order_submit_images_async(
                      coreClient->Handle(), text.c_str(), project.c_str(),
                      conv.empty() ? nullptr : conv.c_str(), images.c_str(),
                      &order));
        if (!r.ok())
          return failure(msg.id, r.error);
        // E5.18: opcion best-of-N del compositor (0 = apagado; 2..4
        // candidatas).
        int bon = static_cast<int>(GetInt64Prop(msg.payloadJson, "bestOfN", 0));
        if (bon > 0) {
          if (!coreClient->Api().order_set_best_of_n)
            return failure(msg.id, "da_order_set_best_of_n no disponible");
          std::string members =
              GetStringProp(msg.payloadJson, "bestOfNMembers");
          CoreResult rc2 =
              coreClient->Wrap(coreClient->Api().order_set_best_of_n(
                  coreClient->Handle(), order, bon,
                  members.empty() ? nullptr : members.c_str()));
          if (!rc2.ok())
            return failure(msg.id, rc2.error);
        }
        NoteSessionOrder(OrderHandleToId(order));
        return okPayload(
            msg.id,
            "{\"orderId\":" + std::to_string(OrderHandleToId(order)) + "}");
      });

  RegisterHandler("core.order.attachments", [coreClient, failure, okPayload,
                                             ready](const BridgeMessage &msg) {
    if (!ready(coreClient) || !coreClient->Api().order_attachments_json)
      return failure(msg.id, "da_order_attachments_json no disponible");
    const long long oid = GetInt64Prop(msg.payloadJson, "orderId", 0);
    if (oid <= 0)
      return failure(msg.id, "Falta orderId");
    char *json = nullptr;
    CoreResult r = coreClient->Wrap(coreClient->Api().order_attachments_json(
        coreClient->Handle(), OrderIdToHandle(oid), &json));
    if (!r.ok())
      return failure(msg.id, r.error);
    std::string body = json ? json : "[]";
    if (json)
      coreClient->Api().string_free(json);
    return okPayload(msg.id, body);
  });

  // E5.18 (D-C5): tarjeta comparativa — candidatas con métricas y rank.
  RegisterHandler(
      "core.order.bestOfNCandidates",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().best_of_n_candidates_json)
          return failure(msg.id, "da_best_of_n_candidates_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        char *json = nullptr;
        CoreResult r =
            coreClient->Wrap(coreClient->Api().best_of_n_candidates_json(
                coreClient->Handle(), OrderIdToHandle(orderId), &json));
        if (!r.ok())
          return failure(msg.id, r.error);
        std::string out = json ? json : "{}";
        if (json && coreClient->Api().string_free)
          coreClient->Api().string_free(json);
        return okPayload(msg.id, out);
      });

  // E5.18 (D-C5): el usuario elige la ganadora — aplica su worktree sobre el
  // de la orden y archiva las perdedoras (fusion aprobada).
  RegisterHandler(
      "core.order.bestOfNChoose",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().best_of_n_choose)
          return failure(msg.id, "da_best_of_n_choose no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        long long candId = GetInt64Prop(msg.payloadJson, "candidateId", 0);
        if (orderId <= 0 || candId <= 0)
          return failure(msg.id, "Faltan orderId o candidateId");
        CoreResult r = coreClient->Wrap(coreClient->Api().best_of_n_choose(
            coreClient->Handle(), OrderIdToHandle(orderId), candId));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler(
      "core.order.replan",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_replan_async)
          return failure(msg.id, "da_order_replan_async no disponible");
        const long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        const std::string changes = GetStringProp(msg.payloadJson, "changes");
        if (orderId <= 0 || changes.empty() || changes.size() > 16384)
          return failure(msg.id,
                         "Faltan orderId o cambios validos (maximo 16 KiB)");
        CoreResult result =
            coreClient->Wrap(coreClient->Api().order_replan_async(
                coreClient->Handle(), OrderIdToHandle(orderId),
                changes.c_str()));
        if (!result.ok())
          return failure(msg.id, result.error);
        return okPayload(msg.id, "{\"planning\":true}");
      });

  RegisterHandler(
      "core.order.answer",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_answer_async)
          return failure(msg.id, "da_order_answer_async no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        std::string answers = GetStringProp(msg.payloadJson, "answersJson");
        if (orderId <= 0 || answers.empty())
          return failure(msg.id, "Faltan orderId o answersJson");
        CoreResult r = coreClient->Wrap(coreClient->Api().order_answer_async(
            coreClient->Handle(), OrderIdToHandle(orderId), answers.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"accepted\":true}");
      });

  RegisterHandler(
      "core.order.pollPlan",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_plan_poll)
          return failure(msg.id, "da_order_plan_poll no disponible");
        int done = 0;
        int okFlag = 0;
        CoreResult r = coreClient->Wrap(coreClient->Api().order_plan_poll(
            coreClient->Handle(), &done, &okFlag));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id,
                         std::string("{\"done\":") + (done ? "true" : "false") +
                             ",\"ok\":" + (okFlag ? "true" : "false") + "}");
      });

  RegisterHandler("core.order.plan",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().plan_get_json)
                      return failure(msg.id, "da_plan_get_json no disponible");
                    long long orderId =
                        GetInt64Prop(msg.payloadJson, "orderId", 0);
                    if (orderId <= 0)
                      return failure(msg.id, "Falta orderId");
                    char *out = nullptr;
                    CoreResult r;
                    r.rc = coreClient->Api().plan_get_json(
                        coreClient->Handle(), OrderIdToHandle(orderId), &out);
                    r.json = coreClient->TakeString(out);
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    return respond(msg.id, r);
                  });

  RegisterHandler("core.order.approve",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().order_approve)
                      return failure(msg.id, "da_order_approve no disponible");
                    long long orderId =
                        GetInt64Prop(msg.payloadJson, "orderId", 0);
                    if (orderId <= 0)
                      return failure(msg.id, "Falta orderId");
                    CoreResult r =
                        coreClient->Wrap(coreClient->Api().order_approve(
                            coreClient->Handle(), OrderIdToHandle(orderId)));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"approved\":true}");
                  });

  RegisterHandler(
      "core.order.dispatch",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_dispatch_async)
          return failure(
              msg.id, "da_order_dispatch_async no disponible: el DLL del motor "
                      "no exporta la ejecucion de planes");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        CoreResult r = coreClient->Wrap(coreClient->Api().order_dispatch_async(
            coreClient->Handle(), OrderIdToHandle(orderId)));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"dispatching\":true}");
      });

  // CHECKPOINT-T2: reanuda una orden 'interrupted' desde su checkpoint por
  // tarea — no rehace las completadas y re-ejecuta enteras las que quedaron a
  // medias. El progreso se sigue con pollDispatch/status/events igual que un
  // dispatch normal (mismo hilo, mismo registro).
  RegisterHandler(
      "core.order.resume",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_resume_async)
          return failure(
              msg.id, "da_order_resume_async no disponible: el DLL del motor "
                      "no exporta la reanudacion por checkpoint");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        CoreResult r = coreClient->Wrap(coreClient->Api().order_resume_async(
            coreClient->Handle(), OrderIdToHandle(orderId)));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"resuming\":true}");
      });

  // SEMANTIC-GATE-T3: fija el observable declarado de la orden (array JSON de
  // aserciones). El motor lo valida de verdad — JSON inválido o kind
  // desconocido = error explícito, nada se guarda.
  RegisterHandler(
      "core.order.setExpected",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_set_expected)
          return failure(
              msg.id, "da_order_set_expected no disponible: el DLL del motor "
                      "no exporta el observable declarado");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        std::string expected = GetStringProp(msg.payloadJson, "expected");
        if (expected.empty())
          return failure(msg.id, "Falta expected (array JSON de aserciones)");
        CoreResult r = coreClient->Wrap(coreClient->Api().order_set_expected(
            coreClient->Handle(), OrderIdToHandle(orderId), expected.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"set\":true}");
      });

  RegisterHandler(
      "core.order.expected",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_expected_json)
          return failure(msg.id, "da_order_expected_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().order_expected_json(
            coreClient->Handle(), OrderIdToHandle(orderId), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.order.pollDispatch",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_dispatch_poll)
          return failure(msg.id, "da_order_dispatch_poll no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        int done = 0;
        int okFlag = 0;
        CoreResult r = coreClient->Wrap(coreClient->Api().order_dispatch_poll(
            coreClient->Handle(), OrderIdToHandle(orderId), &done, &okFlag));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id,
                         std::string("{\"done\":") + (done ? "true" : "false") +
                             ",\"ok\":" + (okFlag ? "true" : "false") + "}");
      });

  RegisterHandler(
      "core.order.status",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_status)
          return failure(msg.id, "da_order_status no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        int st = 0;
        CoreResult r = coreClient->Wrap(coreClient->Api().order_status(
            coreClient->Handle(), OrderIdToHandle(orderId), &st));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"status\":" + std::to_string(st) + "}");
      });

  RegisterHandler("core.order.cancel",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().order_cancel)
                      return failure(msg.id, "da_order_cancel no disponible");
                    long long orderId =
                        GetInt64Prop(msg.payloadJson, "orderId", 0);
                    if (orderId <= 0)
                      return failure(msg.id, "Falta orderId");
                    CoreResult r =
                        coreClient->Wrap(coreClient->Api().order_cancel(
                            coreClient->Handle(), OrderIdToHandle(orderId)));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"cancelled\":true}");
                  });

  RegisterHandler("core.plan.cancel",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().plan_cancel)
                      return failure(msg.id, "da_plan_cancel no disponible");
                    long long orderId =
                        GetInt64Prop(msg.payloadJson, "orderId", 0);
                    CoreResult r =
                        coreClient->Wrap(coreClient->Api().plan_cancel(
                            coreClient->Handle(),
                            orderId > 0 ? OrderIdToHandle(orderId) : nullptr));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"cancelled\":true}");
                  });

  RegisterHandler(
      "core.order.events",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_events_json)
          return failure(msg.id, "da_order_events_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        long long sinceId = GetInt64Prop(msg.payloadJson, "sinceId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().order_events_json(
            coreClient->Handle(), OrderIdToHandle(orderId), sinceId, &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  // UI-ACTION: polling incremental de acciones cosméticas pedidas por
  // agentes/órdenes (la WebUI las despacha contra el allowlist del cliente).
  RegisterHandler(
      "core.ui.actions",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().ui_actions_poll)
          return failure(msg.id, "da_ui_actions_poll no disponible");
        long long sinceId = GetInt64Prop(msg.payloadJson, "sinceId", 0);
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().ui_actions_poll(coreClient->Handle(), sinceId,
                                                 &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  // UI-ACTION: ack de la cabina tras aplicar (o rechazar) una acción.
  RegisterHandler("core.ui.ack",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().ui_action_ack)
                      return failure(msg.id, "da_ui_action_ack no disponible");
                    long long actionId =
                        GetInt64Prop(msg.payloadJson, "actionId", 0);
                    if (actionId <= 0)
                      return failure(msg.id, "Falta actionId");
                    bool okFlag = GetBoolProp(msg.payloadJson, "ok", false);
                    std::string detail =
                        GetStringProp(msg.payloadJson, "detail");
                    CoreResult r;
                    r.rc = coreClient->Api().ui_action_ack(
                        coreClient->Handle(), actionId, okFlag ? 1 : 0,
                        detail.empty() ? nullptr : detail.c_str());
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    else
                      r.json = "{\"ok\":true}";
                    return respond(msg.id, r);
                  });

  // (b): primer arranque. Lectura del estado ({"done","has_usage"})
  // y marca local de «visto»; ninguno pide diálogo nativo.
  RegisterHandler(
      "core.onboarding.state",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().onboarding_json)
          return failure(msg.id, "da_onboarding_json no disponible");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().onboarding_json(coreClient->Handle(), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.onboarding.done",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().onboarding_done)
          return failure(msg.id, "da_onboarding_done no disponible");
        CoreResult r;
        r.rc = coreClient->Api().onboarding_done(coreClient->Handle());
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        else
          r.json = "{\"ok\":true}";
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.session.messages",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().session_messages_json)
          return failure(msg.id, "da_session_messages_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().session_messages_json(
            coreClient->Handle(), OrderIdToHandle(orderId), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.session.messages.v2",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().session_messages_v2_json)
          return failure(msg.id, "da_session_messages_v2_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().session_messages_v2_json(
            coreClient->Handle(), OrderIdToHandle(orderId), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.session.rename",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().session_rename)
          return failure(msg.id, "da_session_rename no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        std::string title = GetStringProp(msg.payloadJson, "title");
        if (orderId <= 0 || title.empty())
          return failure(msg.id, "Faltan orderId o title");
        CoreResult r = coreClient->Wrap(coreClient->Api().session_rename(
            coreClient->Handle(), OrderIdToHandle(orderId), title.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"renamed\":true}");
      });

  // S8: borrar una sesion del historial. La lista se llenaba y no habia forma
  // de quitar nada de ella sin tocar la base a mano.
  RegisterHandler("core.session.delete",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().session_delete)
                      return failure(msg.id, "da_session_delete no disponible");
                    long long orderId =
                        GetInt64Prop(msg.payloadJson, "orderId", 0);
                    if (orderId <= 0)
                      return failure(msg.id, "Falta orderId");
                    CoreResult r =
                        coreClient->Wrap(coreClient->Api().session_delete(
                            coreClient->Handle(), OrderIdToHandle(orderId)));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"deleted\":true}");
                  });

  // --- Aprobaciones y gobernanza ------------------------------------------
  RegisterHandler(
      "core.approvals.resolve",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().approval_resolve)
          return failure(msg.id, "da_approval_resolve no disponible");
        long long approvalId = GetInt64Prop(msg.payloadJson, "approvalId", 0);
        bool approved = GetBoolProp(msg.payloadJson, "approved", false);
        if (approvalId <= 0)
          return failure(msg.id, "Falta approvalId");
        CoreResult r = coreClient->Wrap(coreClient->Api().approval_resolve(
            coreClient->Handle(), approvalId, approved ? 1 : 0));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"resolved\":true}");
      });

  // Resolucion de aprobacion con alcance: 0 = solo esta vez, 1 = toda la
  // sesion, 2 = siempre. Sin esto, cada comando del agente vuelve a preguntar.
  RegisterHandler(
      "core.approvals.resolveScoped",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().approval_resolve_scoped)
          return failure(msg.id, "da_approval_resolve_scoped no disponible");
        long long approvalId = GetInt64Prop(msg.payloadJson, "approvalId", 0);
        bool approved = GetBoolProp(msg.payloadJson, "approved", false);
        int scope = GetIntProp(msg.payloadJson, "scope", 0);
        if (approvalId <= 0)
          return failure(msg.id, "Falta approvalId");
        if (scope < 0 || scope > 2)
          return failure(msg.id, "scope invalido: 0 una vez, 1 sesion, "
                                 "2 siempre");
        CoreResult r =
            coreClient->Wrap(coreClient->Api().approval_resolve_scoped(
                coreClient->Handle(), approvalId, approved ? 1 : 0, scope));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"resolved\":true}");
      });

  RegisterHandler("core.governance.get",
                  [coreClient, failure,
                   okPayload](const BridgeMessage &msg) -> std::string {
                    if (!coreClient)
                      return failure(msg.id, "CoreClient no disponible");
                    return okPayload(
                        msg.id, "{\"mode\":\"" +
                                    JsonEscape(coreClient->GovernanceMode()) +
                                    "\"}");
                  });

  RegisterHandler(
      "core.governance.set",
      [coreClient, failure,
       okPayload](const BridgeMessage &msg) -> std::string {
        if (!coreClient)
          return failure(msg.id, "CoreClient no disponible");
        std::string mode = GetStringProp(msg.payloadJson, "mode");
        if (!coreClient->SetGovernanceMode(mode))
          return failure(msg.id,
                         "Modo invalido: usa free, paid, hybrid o local");
        return okPayload(msg.id, "{\"mode\":\"" + JsonEscape(mode) + "\"}");
      });

  // 10-nov: lectura sin privilegio de los permisos vigentes del motor (antes
  // la pagina los reaplicaba al abrirse y eso pedia autorizacion del host).
  RegisterHandler(
      "core.permissions.get",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().get_permission_config)
          return failure(msg.id, "da_get_permission_config no disponible");
        char *out = nullptr;
        CoreResult r;
        r.rc =
            coreClient->Api().get_permission_config(coreClient->Handle(), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.permissions.set",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().set_permission_config)
          return failure(msg.id, "da_set_permission_config no disponible");
        std::string cfg = GetStringProp(msg.payloadJson, "configJson");
        if (cfg.empty())
          return failure(msg.id, "Falta configJson");
        CoreResult r = coreClient->Wrap(coreClient->Api().set_permission_config(
            coreClient->Handle(), cfg.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  // «Volver a pedir confirmación para Auto y Omitir». Solo borra
  // el recuerdo del host (endurece), así que no necesita diálogo; el modo
  // vigente del motor no cambia.
  RegisterHandler("core.permissions.forgetElevated",
                  [this, failure, okPayload](const BridgeMessage &msg) {
                    std::string error;
                    if (!ForgetElevatedModes(error))
                      return failure(msg.id, error);
                    return okPayload(msg.id, "{\"forgotten\":true}");
                  });

  // Skills: el motor las descubre escaneando las carpetas enlazadas (mounts).
  // Si no hay ninguna montada devuelve [], y el panel lo explica en vez de
  // quedarse en blanco.
  // Reinyecta un plan editado. El motor exige el plan COMPLETO en JSON y solo
  // lo acepta si la orden esta en estado `planned`: por eso el editor del modo
  // Plan trabaja sobre el JSON y no sobre la version legible del plan.
  RegisterHandler(
      "core.order.plan.set",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().plan_set_json)
          return failure(msg.id, "da_order_plan_set_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId");
        std::string planJson = GetStringProp(msg.payloadJson, "planJson");
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        if (planJson.empty())
          return failure(msg.id, "Falta planJson");
        CoreResult r = coreClient->Wrap(coreClient->Api().plan_set_json(
            coreClient->Handle(), OrderIdToHandle(orderId), planJson.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  // Favorito elegido por el usuario. El router usa el mismo campo como prior,
  // asi que marcar aqui asciende el modelo de verdad.
  RegisterHandler(
      "core.model.setFavorite",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().model_set_favorite)
          return failure(msg.id, "da_model_set_favorite no disponible");
        std::string provider = GetStringProp(msg.payloadJson, "provider");
        std::string model = GetStringProp(msg.payloadJson, "model");
        if (provider.empty() || model.empty())
          return failure(msg.id, "Faltan provider y model");
        bool fav =
            msg.payloadJson.find("\"favorite\":true") != std::string::npos;
        CoreResult r = coreClient->Wrap(coreClient->Api().model_set_favorite(
            coreClient->Handle(), provider.c_str(), model.c_str(),
            fav ? 1 : 0));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  // Montajes: carpetas que el agente puede leer fuera del workspace. Son
  // ademas de donde salen las skills, asi que los dos paneles se alimentan.
  //
  // El listado unico es "core.mounts.list" (BEATS_GETTER, mas arriba). Aqui
  // habia un segundo handler "core.mounts" identico y un primer par
  // core.mount.add/remove que el registro posterior pisaba
  // (m_handlers[kind] = handler sobrescribe), de modo que devolvia
  // {"added":true} que ningun cliente llegaba a ver nunca. Eliminados: el par
  // vivo esta junto a core.workspace.set, mas abajo.

  // Sin la macro BEATS_GETTER: aqui ya esta fuera de alcance (se define y se
  // retira junto al bloque de getters de mas arriba).
  RegisterHandler("core.skills",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    return respond(msg.id,
                                   coreClient->CallJson(
                                       coreClient->Api().skills_discover_json));
                  });

  // Memoria del agente (Engram o el respaldo local). Toma el proyecto porque
  // el contexto se guarda por proyecto; vacio = "default".
  RegisterHandler(
      "core.memory",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().memory_context_json)
          return failure(msg.id, "da_memory_context_json no disponible");
        std::string project = GetStringProp(msg.payloadJson, "project");
        if (project.empty())
          project = "default";
        char *out = nullptr;
        CoreResult r = coreClient->Wrap(coreClient->Api().memory_context_json(
            coreClient->Handle(), project.c_str(), &out));
        if (!r.ok())
          return failure(msg.id, r.error);
        r.json = coreClient->TakeString(out);
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.reasoningEffort.set",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().set_reasoning_effort)
          return failure(msg.id, "da_set_reasoning_effort no disponible");
        // Cadena vacia es valida: devuelve el control al valor del proveedor.
        std::string effort = GetStringProp(msg.payloadJson, "effort");
        CoreResult r = coreClient->Wrap(coreClient->Api().set_reasoning_effort(
            coreClient->Handle(), effort.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler(
      "core.hooks.set",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().set_hooks_config)
          return failure(msg.id, "da_set_hooks_config no disponible");
        std::string cfg = GetStringProp(msg.payloadJson, "configJson");
        if (cfg.empty())
          return failure(msg.id, "Falta configJson");
        CoreResult r = coreClient->Wrap(coreClient->Api().set_hooks_config(
            coreClient->Handle(), cfg.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  // --- Workspace y montajes ------------------------------------------------
  RegisterHandler(
      "core.workspace.restorePermissions",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no está disponible");
        const long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0 || !GetBoolProp(msg.payloadJson, "explicit", false))
          return failure(msg.id, "Restaurar requiere orden y acción explícita");
        const std::string request =
            "{\"method\":\"POST\",\"path\":\"/api/orders/" +
            std::to_string(orderId) +
            "/workspace/"
            "restore_permissions\",\"body\":\"{\\\"explicit\\\":true}\","
            "\"origin\":\"cabina\"}";
        const CoreResult result = coreClient->CallJson(
            coreClient->Api().remote_request_json, request);
        if (!result.ok())
          return failure(msg.id, result.error);
        const int status = GetIntProp(result.json, "status", 500);
        const std::string body = GetStringProp(result.json, "body");
        if (status != 200) {
          // El motor responde {"error","causa","win32"}: se muestra la causa en
          // español (y el código nativo), no el JSON crudo.
          const std::string causa = GetStringProp(body, "causa");
          const int win32 = GetIntProp(body, "win32", 0);
          std::string text =
              "Restauración rechazada: " + (causa.empty() ? body : causa);
          if (win32 != 0)
            text += " (win32=" + std::to_string(win32) + ")";
          return failure(msg.id, text);
        }
        if (body.empty())
          return failure(msg.id, "El motor no confirmó la restauración");
        return okPayload(msg.id, body);
      });
  RegisterHandler("core.process.control", [coreClient, respond, failure,
                                           ready](const BridgeMessage &msg) {
    if (!ready(coreClient) || !coreClient->Api().process_control_v1)
      return failure(msg.id, "El control de procesos no está disponible.");
    return respond(msg.id,
                   coreClient->CallJson(coreClient->Api().process_control_v1,
                                        msg.payloadJson));
  });
  RegisterHandler(
      "core.workspace.set",
      [this, coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().set_workspace_root)
          return failure(msg.id, "da_set_workspace_root no disponible");
        std::string path = GetStringProp(msg.payloadJson, "path");
        if (path.empty())
          return failure(msg.id, "Falta path");
        std::string error;
        if (!m_documents ||
            !m_documents->ActivateWorkspaceRoot(
                Utf8ToWide(path), error,
                [coreClient](const std::wstring &root, std::string &reason) {
                  return coreClient->SetWorkspaceRoot(root, reason);
                }))
          return failure(msg.id, error);
        return okPayload(msg.id, "{\"root\":\"" + JsonEscape(path) + "\"}");
      });

  RegisterHandler("core.mount.add",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().mount_add)
                      return failure(msg.id, "da_mount_add no disponible");
                    std::string path = GetStringProp(msg.payloadJson, "path");
                    if (path.empty())
                      return failure(msg.id, "Falta path");
                    CoreResult r = coreClient->Wrap(coreClient->Api().mount_add(
                        coreClient->Handle(), path.c_str()));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"mounted\":true}");
                  });

  RegisterHandler("core.mount.remove",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().mount_remove)
                      return failure(msg.id, "da_mount_remove no disponible");
                    std::string path = GetStringProp(msg.payloadJson, "path");
                    if (path.empty())
                      return failure(msg.id, "Falta path");
                    CoreResult r =
                        coreClient->Wrap(coreClient->Api().mount_remove(
                            coreClient->Handle(), path.c_str()));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"unmounted\":true}");
                  });

  // --- Cliente MCP nativo ---------------------------------------------------
  RegisterHandler(
      "core.mcp.connect",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().mcp_connect)
          return failure(msg.id, "da_mcp_connect no disponible");
        // argvJson: array JSON serializado, p. ej.
        // "[\"npx\",\"-y\",\"server\"]".
        std::string argv = GetStringProp(msg.payloadJson, "argvJson");
        std::string cwd = GetStringProp(msg.payloadJson, "cwd");
        int timeoutMs = GetIntProp(msg.payloadJson, "timeoutMs", 15000);
        if (argv.empty())
          return failure(msg.id, "Falta argvJson");
        CoreResult r = coreClient->Wrap(coreClient->Api().mcp_connect(
            coreClient->Handle(), argv.c_str(),
            cwd.empty() ? nullptr : cwd.c_str(), timeoutMs));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"connected\":true}");
      });

  RegisterHandler("core.mcp.disconnect",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().mcp_disconnect)
                      return failure(msg.id, "da_mcp_disconnect no disponible");
                    CoreResult r = coreClient->Wrap(
                        coreClient->Api().mcp_disconnect(coreClient->Handle()));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"connected\":false}");
                  });

  RegisterHandler(
      "core.mcp.status",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().mcp_is_connected)
          return failure(msg.id, "da_mcp_is_connected no disponible");
        int connected = 0;
        CoreResult r = coreClient->Wrap(coreClient->Api().mcp_is_connected(
            coreClient->Handle(), &connected));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, std::string("{\"connected\":") +
                                     (connected ? "true" : "false") + "}");
      });

  // MCP-AUTH: expone el token del servidor MCP propio para que el panel lo
  // muestre al usuario al configurar clientes MCP externos (IDEs).
  RegisterHandler(
      "core.mcp.authToken",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().mcp_auth_token)
          return failure(msg.id, "da_mcp_auth_token no disponible");
        CoreResult r = coreClient->CallJson(coreClient->Api().mcp_auth_token);
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"token\":\"" + JsonEscape(r.json) + "\"}");
      });

  RegisterHandler("core.mcp.call",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().mcp_call_tool)
                      return failure(msg.id, "da_mcp_call_tool no disponible");
                    std::string name = GetStringProp(msg.payloadJson, "name");
                    std::string args =
                        GetStringProp(msg.payloadJson, "argsJson");
                    if (name.empty())
                      return failure(msg.id, "Falta name");
                    if (args.empty())
                      args = "{}";
                    char *out = nullptr;
                    CoreResult r;
                    r.rc = coreClient->Api().mcp_call_tool(
                        coreClient->Handle(), name.c_str(), args.c_str(), &out);
                    r.json = coreClient->TakeString(out);
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    // El resultado de una tool MCP es texto libre, no
                    // necesariamente JSON.
                    return respond(msg.id, r, false);
                  });

  // --- Consumo y busqueda web ----------------------------------------------
  RegisterHandler("core.usage",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().usage_summary_json)
                      return failure(msg.id,
                                     "da_usage_summary_json no disponible");
                    int orderId = GetIntProp(msg.payloadJson, "orderId", 0);
                    char *out = nullptr;
                    CoreResult r;
                    r.rc = coreClient->Api().usage_summary_json(
                        coreClient->Handle(), orderId, &out);
                    r.json = coreClient->TakeString(out);
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    return respond(msg.id, r);
                  });

  // E1.16/F4: medidor del plan — ventana movil de 7 dias + claves limitadas.
  RegisterHandler(
      "core.usage.week",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().usage_week_json)
          return failure(msg.id, "da_usage_week_json no disponible");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().usage_week_json(coreClient->Handle(), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  // E1.18/F4: presupuesto de pago, visible y editable desde Ajustes.
  RegisterHandler(
      "core.budget.get",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().budget_state_json)
          return failure(msg.id, "da_budget_state_json no disponible");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().budget_state_json(coreClient->Handle(), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.budget.set",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().budget_set_authorized)
          return failure(msg.id, "da_budget_set_authorized no disponible");
        int authorized = GetIntProp(msg.payloadJson, "authorized", -1);
        if (authorized < 0)
          return failure(msg.id, "authorized debe ser >= 0");
        CoreResult r = coreClient->Wrap(coreClient->Api().budget_set_authorized(
            coreClient->Handle(), authorized));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"applied\":true}");
      });

  RegisterHandler(
      "core.inventory.refresh",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().inventory_refresh)
          return failure(msg.id, "da_inventory_refresh no disponible");
        CoreResult r = coreClient->Wrap(
            coreClient->Api().inventory_refresh(coreClient->Handle()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"refreshed\":true}");
      });

  RegisterHandler("core.websearch",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().web_search)
                      return failure(msg.id, "da_web_search no disponible");
                    std::string query = GetStringProp(msg.payloadJson, "query");
                    int maxResults =
                        GetIntProp(msg.payloadJson, "maxResults", 5);
                    if (query.empty())
                      return failure(msg.id, "Falta query");
                    char *out = nullptr;
                    CoreResult r;
                    r.rc = coreClient->Api().web_search(
                        coreClient->Handle(), query.c_str(), maxResults, &out);
                    r.json = coreClient->TakeString(out);
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    return respond(msg.id, r);
                  });

  // Una llamada al modelo sin planificador ni orden (decision D4).
  //
  // El autocompletado por comentario del editor mandaba su peticion por
  // da_order_submit, o sea por el PLANIFICADOR, que no genera codigo: clasifica
  // y devuelve un plan con una descripcion en prosa. Por eso Ctrl+Enter
  // proponia prosa. No escribe archivos ni ejecuta nada: lo que devuelve pasa
  // por el visor de cambios.
  RegisterHandler("core.complete",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().complete_text)
                      return failure(msg.id, "da_complete_text no disponible");
                    std::string sys = GetStringProp(msg.payloadJson, "system");
                    std::string usr = GetStringProp(msg.payloadJson, "prompt");
                    if (usr.empty())
                      return failure(msg.id, "Falta prompt");
                    char *out = nullptr;
                    CoreResult r;
                    r.rc = coreClient->Api().complete_text(
                        coreClient->Handle(), sys.c_str(), usr.c_str(), &out);
                    r.json = coreClient->TakeString(out);
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    return respond(msg.id, r);
                  });

  // --- Plugins --------------------------------------------------------------
  //
  // plugin_loader.zig verificaba ABI, anclaba hashes SHA-256 en catalog.db y
  // cargaba DLLs de verdad desde hace tiempo. Sin estos handlers no habia forma
  // de llegar hasta ahi: era codigo muerto con tests propios.
  RegisterHandler(
      "core.plugins.list",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().plugins_list_json)
          return failure(msg.id, "da_plugins_list_json no disponible");
        return respond(
            msg.id, coreClient->CallJson(coreClient->Api().plugins_list_json));
      });

  RegisterHandler("core.plugins.dir",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().plugins_dir)
                      return failure(msg.id, "da_plugins_dir no disponible");
                    return respond(msg.id, coreClient->CallJson(
                                               coreClient->Api().plugins_dir));
                  });

  RegisterHandler("core.plugin.trust",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().plugin_trust)
                      return failure(msg.id, "da_plugin_trust no disponible");
                    std::string folder =
                        GetStringProp(msg.payloadJson, "folder");
                    if (folder.empty())
                      return failure(msg.id, "Falta la carpeta del plugin");
                    CoreResult r =
                        coreClient->Wrap(coreClient->Api().plugin_trust(
                            coreClient->Handle(), folder.c_str()));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"trusted\":true}");
                  });

  RegisterHandler("core.plugin.untrust",
                  [coreClient, failure, okPayload,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().plugin_untrust)
                      return failure(msg.id, "da_plugin_untrust no disponible");
                    std::string name = GetStringProp(msg.payloadJson, "name");
                    if (name.empty())
                      return failure(msg.id, "Falta el nombre del plugin");
                    CoreResult r =
                        coreClient->Wrap(coreClient->Api().plugin_untrust(
                            coreClient->Handle(), name.c_str()));
                    if (!r.ok())
                      return failure(msg.id, r.error);
                    return okPayload(msg.id, "{\"untrusted\":true}");
                  });

  // --- Spaces: un git worktree por orden -----------------------------------
  //
  // El motor lo hace desde F5 (core/src/spaces.zig: rama, worktree y fila en
  // runtime.db) y no habia forma de llegar hasta ahi: ni export, ni handler, ni
  // llamador. El panel se limitaba a listar montajes haciendose pasar por
  // spaces.
  RegisterHandler(
      "core.spaces.list",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().spaces_list_json)
          return failure(msg.id, "da_spaces_list_json no disponible");
        std::string project = GetStringProp(msg.payloadJson, "projectId");
        if (project.empty())
          project = "default";
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().spaces_list_json(coreClient->Handle(),
                                                  project.c_str(), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler("core.space.create",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().space_create)
                      return failure(msg.id, "da_space_create no disponible");
                    std::string project =
                        GetStringProp(msg.payloadJson, "projectId");
                    if (project.empty())
                      project = "default";
                    std::string name = GetStringProp(msg.payloadJson, "name");
                    if (name.empty())
                      return failure(msg.id, "Falta el nombre del space");
                    std::string kind = GetStringProp(msg.payloadJson, "kind");
                    if (kind.empty())
                      kind = "order";
                    char *out = nullptr;
                    CoreResult r;
                    r.rc = coreClient->Api().space_create(
                        coreClient->Handle(), project.c_str(), name.c_str(),
                        kind.c_str(), &out);
                    r.json = coreClient->TakeString(out);
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    return respond(msg.id, r);
                  });

  RegisterHandler(
      "core.space.archive",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().space_archive)
          return failure(msg.id, "da_space_archive no disponible");
        long long spaceId = GetInt64Prop(msg.payloadJson, "spaceId", 0);
        if (spaceId <= 0)
          return failure(msg.id, "Falta spaceId");
        CoreResult r = coreClient->Wrap(
            coreClient->Api().space_archive(coreClient->Handle(), spaceId));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"archived\":true}");
      });

  RegisterHandler(
      "core.spaces.prune",
      [coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().spaces_prune)
          return failure(msg.id, "da_spaces_prune no disponible");
        std::string project = GetStringProp(msg.payloadJson, "projectId");
        if (project.empty())
          project = "default";
        unsigned int pruned = 0;
        CoreResult r = coreClient->Wrap(coreClient->Api().spaces_prune(
            coreClient->Handle(), project.c_str(), &pruned));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"pruned\":" + std::to_string(pruned) + "}");
      });

  // E5.05: estado de .devagents/worktree.json — existe, valido, copias,
  // scripts de setup, timeout y sugerencias por lockfiles. Solo inspeccion:
  // el motor no ejecuta nada para responder.
  RegisterHandler(
      "core.worktree.config",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().worktree_config_json)
          return failure(msg.id, "da_worktree_config_json no disponible");
        std::string project = GetStringProp(msg.payloadJson, "projectId");
        if (project.empty())
          project = "default";
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().worktree_config_json(coreClient->Handle(),
                                                      project.c_str(), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  // --- Ship Flow B3 ------------------------------------------------------
  // Empaqueta una orden `done` en un PR real via `gh`. Nunca fabrica estado:
  // el JSON de salida es lo que parseó el motor de la salida real de gh, y el
  // error lleva el stderr real de gh/git en last_error.
  RegisterHandler(
      "core.order.ship",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_ship_json)
          return failure(msg.id, "da_order_ship_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().order_ship_json(
            coreClient->Handle(), OrderIdToHandle(orderId), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  // Guarda la credencial HTTPS de la forge en el administrador de git
  // (credential approve) — el "actualizar credenciales" del aviso de la
  // tarjeta manual. El secreto viaja por stdin en el motor, no por argv.
  RegisterHandler("core.git.storeCredential",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().git_store_credential)
                      return failure(msg.id,
                                     "da_git_store_credential no disponible");
                    char *out = nullptr;
                    CoreResult r;
                    r.rc = coreClient->Api().git_store_credential(
                        coreClient->Handle(), msg.payloadJson.c_str(), &out);
                    r.json = coreClient->TakeString(out);
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    return respond(msg.id, r);
                  });

  RegisterHandler("core.pr.merge",
                  [coreClient, respond, failure,
                   ready](const BridgeMessage &msg) -> std::string {
                    if (!ready(coreClient))
                      return failure(msg.id, "El motor no esta disponible");
                    if (!coreClient->Api().pr_merge)
                      return failure(msg.id, "da_pr_merge no disponible");
                    long long prId = GetInt64Prop(msg.payloadJson, "prId", 0);
                    if (prId <= 0)
                      return failure(msg.id, "Falta prId");
                    char *out = nullptr;
                    CoreResult r;
                    r.rc = coreClient->Api().pr_merge(coreClient->Handle(),
                                                      prId, &out);
                    r.json = coreClient->TakeString(out);
                    if (r.rc != 0)
                      r.error = coreClient->LastEngineError();
                    return respond(msg.id, r);
                  });

  RegisterHandler(
      "core.prs.list",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().prs_json)
          return failure(msg.id, "da_prs_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().prs_json(coreClient->Handle(), orderId, &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });

  RegisterHandler(
      "core.repo.clone",
      [this, coreClient, failure, okPayload,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().repo_clone)
          return failure(msg.id, "da_repo_clone no disponible");
        std::string url = GetStringProp(msg.payloadJson, "url");
        std::string dir = GetStringProp(msg.payloadJson, "targetDir");
        if (url.empty() || dir.empty())
          return failure(msg.id, "Faltan url/targetDir");
        std::wstring target;
        std::string error;
        confined::LockedPath retainedTarget;
        if (!m_documents || !confined::Absolute(Utf8ToWide(dir), target))
          return failure(
              msg.id, "E_CLONE_TARGET_INVALID: Destino de clonado no válido");
        const DWORD attrs =
            GetFileAttributesW(confined::Extended(target).c_str());
        if (attrs == INVALID_FILE_ATTRIBUTES) {
          if (GetLastError() != ERROR_FILE_NOT_FOUND &&
              GetLastError() != ERROR_PATH_NOT_FOUND)
            return failure(msg.id, "E_CLONE_TARGET_UNREADABLE: No se puede "
                                   "inspeccionar el destino del clonado");
          const auto split = target.find_last_of(L'\\');
          if (!m_documents->CreateWorkspaceEntry(target.substr(0, split),
                                                 target.substr(split + 1), true,
                                                 "", error))
            return failure(msg.id, error);
        }
        if (!m_documents->LockReadDirectory(target, retainedTarget))
          return failure(msg.id,
                         "E_CLONE_TARGET_UNSAFE: Destino de clonado inseguro");
        CoreResult r = coreClient->Wrap(coreClient->Api().repo_clone(
            coreClient->Handle(), url.c_str(), dir.c_str()));
        if (!r.ok())
          return failure(msg.id, r.error);
        return okPayload(msg.id, "{\"cloned\":true}");
      });

  // La carpeta REAL donde la orden escribe (worktree de su space o la raíz
  // efectiva). El punto de control la usa para fotografiar el sitio correcto.
  RegisterHandler(
      "core.order.worktree",
      [this, coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().order_worktree_json)
          return failure(msg.id, "da_order_worktree_json no disponible");
        long long orderId = GetInt64Prop(msg.payloadJson, "orderId", 0);
        if (orderId <= 0)
          return failure(msg.id, "Falta orderId");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().order_worktree_json(
            coreClient->Handle(), OrderIdToHandle(orderId), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        if (r.ok()) {
          // Path comes from the native order registry, never the WebView
          // payload.
          const auto path = GetStringProp(r.json, "path");
          std::string error;
          if (!m_documents ||
              !AuthorizeOrderWorktree(*m_documents, IsSessionOrder(orderId),
                                      path, error))
            return failure(
                msg.id, error.empty()
                            ? "E_ORDER_ROOT_INVALID: La carpeta de la orden no "
                              "es válida."
                            : error);
        }
        return respond(msg.id, r);
      });

  // Captura de pantalla. `da_capture_screenshot` llevaba exportada en el .def
  // desde P10-T4 y no la resolvia ni la llamaba nadie: un export huerfano.
  // Devuelve {ok, path, width, height} con la ruta ABSOLUTA del BMP.
  RegisterHandler(
      "core.screenshot",
      [coreClient, respond, failure,
       ready](const BridgeMessage &msg) -> std::string {
        if (!ready(coreClient))
          return failure(msg.id, "El motor no esta disponible");
        if (!coreClient->Api().capture_screenshot)
          return failure(msg.id, "da_capture_screenshot no disponible");
        char *out = nullptr;
        CoreResult r;
        r.rc = coreClient->Api().capture_screenshot(coreClient->Handle(), &out);
        r.json = coreClient->TakeString(out);
        if (r.rc != 0)
          r.error = coreClient->LastEngineError();
        return respond(msg.id, r);
      });
}

// ---------------------------------------------------------------------------
// fs.list — arbol de archivos real
//
// El explorador de la cabina mostraba una lista fija escrita a mano en el
// HTML. Este handler devuelve el contenido real de un directorio para que el
// arbol se construya a partir del disco.
// ---------------------------------------------------------------------------
void Bridge::BindFsHandlers(DocumentManager *docMgr) {
  // shell.open — abre una URL o una ruta con la aplicacion predeterminada del
  // sistema. Lo usa el boton "Open Design" de la barra de estado, heredado de
  // la version con fork, donde Open Design corre fuera de la cabina (WSL,
  // Docker o un servicio web) y solo hay que saltar hacia el.
  RegisterHandler("shell.open", [](const BridgeMessage &msg) -> std::string {
    std::string target = GetStringProp(msg.payloadJson, "target");
    if (target.empty())
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"Falta target\"}";

    const auto wideTarget = Utf8ToWide(target);
    const auto action = security::ClassifyOpenTarget(wideTarget);
    if (action == security::OpenTarget::Reject)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"Solo se admiten HTTPS, HTTP loopback o rutas "
             "locales "
             "absolutas\"}";

    const bool opened = action == security::OpenTarget::Browser
                            ? security::OpenBrowserUrl(wideTarget)
                            : security::RevealLocalPath(wideTarget);
    if (!opened)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"No se pudo abrir " + JsonEscape(target) + "\"}";

    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{\"opened\":true}}";
  });

  // --- Puntos de control ----------------------------------------------------
  //
  // Antes de despachar un plan se guarda una foto del arbol de trabajo para
  // poder volver atras si el agente se equivoca a mitad de camino.
  //
  // El mecanismo es `git stash create`: produce un commit COLGADO que captura
  // el arbol tal y como esta, sin tocar el indice, ni el historial, ni la pila
  // de stash. Restaurar es `git restore --source=<sha>`, que reescribe el
  // contenido de los archivos ya seguidos por git.
  //
  // LIMITACION IMPORTANTE, y por eso se informa al usuario: git no versiona lo
  // que no sigue, asi que un archivo NUEVO creado por el agente no entra en la
  // foto y restaurar NO lo borra. Se devuelve la lista de no seguidos para que
  // la interfaz pueda decirlo en vez de prometer una reversion total.
  // --- Open Design ----------------------------------------------------------
  //
  // Open Design NO corre en Docker sobre Windows: vive dentro de WSL2, en
  // ~/open-design, y se gobierna con `pnpm tools-dev`. Este handler replica
  // exactamente lo que hace el lanzador que ya usaba el usuario
  // ("Open Design.cmd"): consultar el estado, arrancar `web` si hace falta y
  // sacar el puerto real de la salida de `status`, que cambia entre arranques.
  //
  // La version anterior buscaba una carpeta `deploy` con `docker compose` que
  // en este equipo no existe, y por eso el boton decia siempre "no instalado"
  // aunque Open Design estuviera perfectamente instalado.
  RegisterHandler(
      "opendesign.launch", [](const BridgeMessage &msg) -> std::string {
        auto reply = [&msg](const std::string &state, const std::string &url,
                            const std::string &detail) {
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"status\":\"ok\",\"payload\":{\"state\":\"" +
                 JsonEscape(state) + "\",\"url\":\"" + JsonEscape(url) +
                 "\",\"detail\":\"" + JsonEscape(detail) + "\"}}";
        };

        // Distro y ruta configurables: en otro equipo la distro puede no
        // llamarse Ubuntu ni estar el repositorio en el home de root.
        std::string distro = "Ubuntu";
        if (const char *d = std::getenv("DEVAGENTS_OPENDESIGN_WSL_DISTRO"))
          if (*d)
            distro = d;
        std::string odDir;
        if (const char *p = std::getenv("DEVAGENTS_OPENDESIGN_DIR"))
          if (*p)
            odDir = p;

        const std::string cwd = CurrentDirectoryUtf8();
        std::vector<std::wstring> statusArgs, startArgs;
        const auto initialDir = odDir.empty() ? L"/" : Utf8ToWide(odDir);
        if (!security::OpenDesignArguments(Utf8ToWide(distro), initialDir,
                                           false, statusArgs) ||
            !security::OpenDesignArguments(Utf8ToWide(distro), initialDir, true,
                                           startArgs))
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"error\":\"E_OPENDESIGN_INVALID: Distro de WSL o "
                 "directorio "
                 "POSIX absoluto no válidos\"}";
        wchar_t system[32768];
        const UINT length = GetSystemDirectoryW(system, 32768);
        if (!length || length >= 32768)
          return reply("error", "", "Cannot resolve native wsl.exe");
        const std::wstring wsl = std::wstring(system, length) + L"\\wsl.exe";

        if (odDir.empty()) {
          // Preserve ~/open-design for the distro's actual native user without
          // using a shell or assuming that the user is root.
          std::string homeError;
          const auto home =
              TrimAscii(RunCapture(cwd, wsl,
                                   {L"-d", Utf8ToWide(distro), L"--cd", L"/",
                                    L"--", L"/usr/bin/printenv", L"HOME"},
                                   homeError, 30000));
          if (!homeError.empty() || home.empty())
            return reply("not-installed", "",
                         "Cannot resolve native WSL home: " + homeError);
          odDir = home + "/open-design";
          if (!security::OpenDesignArguments(
                  Utf8ToWide(distro), Utf8ToWide(odDir), false, statusArgs) ||
              !security::OpenDesignArguments(
                  Utf8ToWide(distro), Utf8ToWide(odDir), true, startArgs))
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"error\":\"E_OPENDESIGN_INVALID: Directorio HOME nativo "
                   "de WSL no válido\"}";
        }

        // El puerto sale de la linea "web:" de `status`, NO de la primera URL
        // que aparezca: `status` lista tambien el `daemon`, que escucha en otro
        // puerto y responde 404 al navegador. Ese matiz esta en el lanzador que
        // ya usaba el usuario (regex 'web:.*http://127\.0\.0\.1:(\d+)') y
        // saltarselo hace que el boton abra una pestana rota que parece
        // funcionar.
        auto extractUrl = [](const std::string &out) -> std::string {
          size_t line = 0;
          while (line != std::string::npos && line < out.size()) {
            size_t eol = out.find('\n', line);
            std::string l =
                out.substr(line, eol == std::string::npos ? std::string::npos
                                                          : eol - line);
            if (l.find("web:") != std::string::npos) {
              size_t pos = l.find("http://127.0.0.1:");
              if (pos != std::string::npos) {
                size_t start = pos + strlen("http://127.0.0.1:");
                size_t end = start;
                while (end < l.size() &&
                       isdigit(static_cast<unsigned char>(l[end])))
                  end++;
                if (end > start)
                  return "http://localhost:" + l.substr(start, end - start);
              }
            }
            if (eol == std::string::npos)
              break;
            line = eol + 1;
          }
          return "";
        };

        std::string err;
        std::string out = RunCapture(cwd, wsl, statusArgs, err, 60000);
        if (out.find("tools-dev status") == std::string::npos && !err.empty()) {
          return reply("not-installed", "",
                       "No se pudo consultar Open Design en WSL (" + distro +
                           ":" + odDir + "). Detalle: " + err);
        }

        std::string url = extractUrl(out);
        if (!url.empty())
          return reply("running", url, "Ya estaba en marcha.");

        // No esta escuchando: arrancar el servicio web y volver a preguntar.
        err.clear();
        RunCapture(cwd, wsl, startArgs, err, 180000);
        if (!err.empty())
          return reply("error", "", "Open Design start failed: " + err);

        // `start` devuelve antes de que el servidor escuche; se reintenta el
        // status en vez de dormir a ciegas un numero fijo de segundos.
        for (int intento = 0; intento < 10 && url.empty(); ++intento) {
          Sleep(1500);
          std::string e2;
          url = extractUrl(RunCapture(cwd, wsl, statusArgs, e2, 60000));
        }

        if (url.empty()) {
          return reply("error", "",
                       "Open Design arranco pero no publico ningun puerto. "
                       "Comprueba la instalación de pnpm y tools-dev.");
        }
        return reply("running", url,
                     "Arrancado en WSL con pnpm tools-dev start web.");
      });

  auto ckFail = [](int msgId, const std::string &err) {
    return "{\"id\":" + std::to_string(msgId) + ",\"error\":\"" +
           JsonEscape(err) + "\"}";
  };

  // rama actual de la raiz de trabajo, de SOLO LECTURA.
  //
  // La pide la tarjeta Entorno del panel derecho. Se resuelve con el mismo
  // RunGitCapture de los puntos de control (git rev-parse), sin tocar indice
  // ni historial y sin consultar al motor: la rama de un Space o de un ship
  // no es la de la raiz activa que el usuario tiene delante. Si la carpeta no
  // es repositorio se responde isRepo=false para que la tarjeta diga "sin
  // git" en vez de pintar un error.
  RegisterHandler(
      "core.git.branch",
      [ckFail, docMgr](const BridgeMessage &msg) -> std::string {
        std::string root = GetStringProp(msg.payloadJson, "root");
        if (root.empty())
          root = docMgr ? preview::Narrow(docMgr->ActiveWorkspaceRoot()) : "";
        std::wstring canonical;
        if (!docMgr || !docMgr->IsAuthorizedWorkspaceRoot(Utf8ToWide(root)) ||
            !confined::Absolute(Utf8ToWide(root), canonical))
          return ckFail(msg.id, "E_GIT_ROOT_NOT_AUTHORIZED: Carpeta de trabajo "
                                "no autorizada");
        std::string err;
        if (!IsGitRepo(root, err))
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"status\":\"ok\",\"payload\":{\"root\":\"" +
                 JsonEscape(root) + "\",\"isRepo\":false,\"branch\":\"\"}}";
        const std::string branch = ResolveGitBranch(root);
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"status\":\"ok\",\"payload\":{\"root\":\"" +
               JsonEscape(root) + "\",\"isRepo\":true,\"branch\":\"" +
               JsonEscape(branch) + "\"}}";
      });

  // E4: estado del arbol de trabajo para la tarjeta «Cambios».
  //
  // SOLO LECTURA. Reutiliza el mismo git domesticado de los puntos de control
  // (RunGitCapture: --literal-pathspecs, hooks=NUL, sin fsmonitor) y la misma
  // autorizacion de raiz que core.git.branch. Devuelve rama, contadores de
  // `git diff --numstat` (sin renombres y con -z para que las rutas lleguen
  // sin comillas) y los archivos sin seguimiento. No toca el indice.
  RegisterHandler(
      "core.git.status",
      [ckFail, docMgr](const BridgeMessage &msg) -> std::string {
        std::string root = GetStringProp(msg.payloadJson, "root");
        if (root.empty())
          root = docMgr ? preview::Narrow(docMgr->ActiveWorkspaceRoot()) : "";
        std::wstring canonical;
        if (!docMgr || !docMgr->IsAuthorizedWorkspaceRoot(Utf8ToWide(root)) ||
            !confined::Absolute(Utf8ToWide(root), canonical))
          return ckFail(msg.id, "E_GIT_ROOT_NOT_AUTHORIZED: Carpeta de trabajo "
                                "no autorizada");
        // Git recorre rutas por nombre: validar y retener cada componente
        // ANTES de leer el arbol, no solo filtrar el JSON despues. LockTree
        // rechaza reparse/hardlinks y coteja GetFinalPathNameByHandleW; sus
        // handles sin compartir DELETE impiden sustituir directorios en vuelo.
        // (8-nov): «Cambios» sondea cada pocos segundos y la cola
        // del puente es una sola. Con un arbol enorme (p. ej. node_modules o
        // un almacen de 480 000 archivos dentro del proyecto) cada sondeo
        // recorria 100 000 entradas y fallaba, y toda la cabina esperaba
        // detras (medido con muestreo de pila: el hilo del puente al 100 % en
        // LockTree). Solo se recuerda el rechazo POR TAMANO, 30 minutos por
        // raiz: un arbol de mas de 100 000 entradas no encoge en minutos. Una
        // ruta insegura (junction, enlace) falla rapido y se puede corregir
        // en cualquier momento, asi que se vuelve a comprobar siempre.
        static std::mutex tooLargeMutex;
        static std::unordered_map<std::wstring, ULONGLONG> tooLargeRoots;
        {
          std::lock_guard<std::mutex> guard(tooLargeMutex);
          const auto it = tooLargeRoots.find(canonical);
          if (it != tooLargeRoots.end()) {
            if (GetTickCount64() - it->second < 1800000ULL)
              return ckFail(msg.id,
                            "E_GIT_STATUS_TREE_TOO_LARGE: La carpeta tiene "
                            "mas de 100 000 archivos y carpetas; Cambios "
                            "no puede revisarla");
            tooLargeRoots.erase(it);
          }
        }
        confined::LockedPath statusTree;
        bool tooLarge = false;
        if (!confined::LockTree(canonical, statusTree, &tooLarge)) {
          if (tooLarge) {
            std::lock_guard<std::mutex> guard(tooLargeMutex);
            tooLargeRoots[canonical] = GetTickCount64();
          }
          return ckFail(msg.id,
                        tooLarge
                            ? "E_GIT_STATUS_TREE_TOO_LARGE: La carpeta tiene "
                              "mas de 100 000 archivos y carpetas; Cambios "
                              "no puede revisarla"
                            : "E_GIT_STATUS_PATH_UNSAFE: Arbol con rutas "
                              "no confinadas o componentes ilegibles");
        }
        std::string err;
        if (!IsGitRepo(root, err))
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"status\":\"ok\",\"payload\":{\"root\":\"" +
                 JsonEscape(root) +
                 "\",\"isRepo\":false,\"branch\":\"\",\"added\":0,"
                 "\"removed\":0,\"files\":[]}}";
        const std::string branch = ResolveGitBranch(root);
        constexpr size_t kMaxGitFiles = 500;
        bool truncated = false;
        size_t fileCount = 0;
        long long addedTotal = 0, removedTotal = 0;
        std::string filesJson = "[";
        bool first = true;
        const auto appendFile = [&](const std::string &path, long long added,
                                    long long removed, bool untracked) {
          if (!first)
            filesJson += ",";
          first = false;
          filesJson += "{\"path\":\"" + JsonEscape(path) +
                       "\",\"added\":" + std::to_string(added) +
                       ",\"removed\":" + std::to_string(removed) +
                       ",\"untracked\":" + (untracked ? "true" : "false") + "}";
        };
        // numstat -z: "añadidas<TAB>quitadas<TAB>ruta\0" por entrada; con
        // --no-renames la ruta es un solo archivo (sin "old => new").
        const std::string numstat =
            RunGitCapture(root,
                          {L"diff", L"--numstat", L"--no-renames", L"-z",
                           L"--no-ext-diff", L"--no-textconv"},
                          err);
        if (!err.empty())
          return ckFail(msg.id, "E_GIT_STATUS_FAILED: git diff fallo: " + err);
        size_t pos = 0;
        while (pos < numstat.size() && !truncated) {
          size_t end = numstat.find('\0', pos);
          if (end == std::string::npos)
            end = numstat.size();
          const std::string record = numstat.substr(pos, end - pos);
          pos = end + 1;
          if (record.empty())
            continue;
          const size_t tab1 = record.find('\t');
          if (tab1 == std::string::npos)
            continue;
          const size_t tab2 = record.find('\t', tab1 + 1);
          if (tab2 == std::string::npos)
            continue;
          const std::string path = record.substr(tab2 + 1);
          if (path.empty() || IsEngineInternalPath(path))
            continue;
          long long added = 0, removed = 0;
          try {
            if (record.compare(0, tab1, "-") != 0)
              added = std::stoll(record.substr(0, tab1));
            if (tab2 - tab1 - 1 != 1 || record[tab1 + 1] != '-')
              removed = std::stoll(record.substr(tab1 + 1, tab2 - tab1 - 1));
          } catch (...) {
            // Contadores no numericos: se listan como 0, nunca se inventan.
            added = 0;
            removed = 0;
          }
          addedTotal += added;
          removedTotal += removed;
          appendFile(path, added, removed, false);
          if (++fileCount >= kMaxGitFiles)
            truncated = true;
        }
        const std::string untrackedOut = RunGitCapture(
            root, {L"ls-files", L"--others", L"--exclude-standard", L"-z"},
            err);
        if (!err.empty())
          return ckFail(msg.id, "E_GIT_STATUS_FAILED: no se pudieron enumerar "
                                "los archivos sin seguimiento: " +
                                    err);
        pos = 0;
        while (pos < untrackedOut.size() && !truncated) {
          size_t end = untrackedOut.find('\0', pos);
          if (end == std::string::npos)
            end = untrackedOut.size();
          const std::string path = untrackedOut.substr(pos, end - pos);
          pos = end + 1;
          if (path.empty() || IsEngineInternalPath(path))
            continue;
          appendFile(path, 0, 0, true);
          if (++fileCount >= kMaxGitFiles)
            truncated = true;
        }
        filesJson += "]";
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"status\":\"ok\",\"payload\":{\"root\":\"" +
               JsonEscape(root) + "\",\"isRepo\":true,\"branch\":\"" +
               JsonEscape(branch) +
               "\",\"added\":" + std::to_string(addedTotal) +
               ",\"removed\":" + std::to_string(removedTotal) +
               ",\"truncated\":" + (truncated ? "true" : "false") +
               ",\"files\":" + filesJson + "}}";
      });

  // E5: commit LOCAL con aprobacion nativa (decision del propietario:
  // sin push, sin --no-verify, sin --amend). El payload trae la raiz, el
  // mensaje escrito por el usuario y la lista EXACTA de archivos que el modal
  // mostro. Cada ruta se confina a la raiz autorizada antes de tocar git y se
  // pasan rutas canonicas absolutas a `git add`/`git commit --`, de modo que
  // jamas se confirma algo que el usuario no vio. El push sigue siendo el flujo
  // ship, ya existente y consentido.
  // QA primerizo (11-nov): «Sin punto de control» explicaba que hace falta git
  // pero no ofrecía crearlo. `git init` con comando fijo, en una raíz
  // autorizada, con consentimiento nativo y solo si aún no es repositorio.
  RegisterHandler(
      "core.git.init",
      [ckFail, docMgr](const BridgeMessage &msg) -> std::string {
        std::string root = GetStringProp(msg.payloadJson, "root");
        if (root.empty())
          root = docMgr ? preview::Narrow(docMgr->ActiveWorkspaceRoot()) : "";
        std::wstring canonicalRoot;
        if (!docMgr || !docMgr->IsAuthorizedWorkspaceRoot(Utf8ToWide(root)) ||
            !confined::Absolute(Utf8ToWide(root), canonicalRoot))
          return ckFail(msg.id, "E_GIT_ROOT_NOT_AUTHORIZED: Carpeta de trabajo "
                                "no autorizada");
        std::string probe;
        if (IsGitRepo(root, probe))
          return ckFail(msg.id,
                        "E_GIT_ALREADY_REPO: La carpeta ya es un repositorio");
        std::string err;
        RunGitCapture(root, {L"init"}, err);
        std::string again;
        if (!IsGitRepo(root, again))
          return ckFail(
              msg.id, "E_GIT_INIT_FAILED: " +
                          (err.empty() ? std::string("git init falló") : err));
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"status\":\"ok\",\"payload\":{\"root\":\"" +
               JsonEscape(root) + "\",\"isRepo\":true}}";
      });

  RegisterHandler(
      "core.git.commit",
      [ckFail, docMgr](const BridgeMessage &msg) -> std::string {
        std::string root = GetStringProp(msg.payloadJson, "root");
        if (root.empty())
          root = docMgr ? preview::Narrow(docMgr->ActiveWorkspaceRoot()) : "";
        std::wstring canonicalRoot;
        if (!docMgr || !docMgr->IsAuthorizedWorkspaceRoot(Utf8ToWide(root)) ||
            !confined::Absolute(Utf8ToWide(root), canonicalRoot))
          return ckFail(msg.id, "E_GIT_ROOT_NOT_AUTHORIZED: Carpeta de trabajo "
                                "no autorizada");
        const std::string message = GetStringProp(msg.payloadJson, "message");
        if (message.empty() || message.size() > 8192)
          return ckFail(msg.id, "E_GIT_COMMIT_MESSAGE: Falta el mensaje del "
                                "commit o excede 8192 caracteres");
        if (message.find('\0') != std::string::npos)
          return ckFail(msg.id, "E_GIT_COMMIT_MESSAGE: Mensaje no valido");
        const std::vector<std::string> files =
            GetStringArrayProp(msg.payloadJson, "files");
        if (files.empty())
          return ckFail(msg.id,
                        "E_GIT_COMMIT_FILES: No hay archivos que confirmar");
        if (files.size() > 500)
          return ckFail(msg.id, "E_GIT_COMMIT_FILES: Demasiados archivos");
        // Incluye directorios seleccionados y metadatos de git: ninguna
        // ruta que vaya a abrir git puede atravesar un junction. Retener los
        // handles hasta terminar add/commit cierra la sustitucion por nombre.
        confined::LockedPath commitTree;
        if (!confined::LockTree(canonicalRoot, commitTree))
          return ckFail(msg.id, "E_GIT_COMMIT_PATH_OUTSIDE: Arbol con rutas "
                                "no confinadas o componentes ilegibles");
        std::string err;
        if (!IsGitRepo(root, err))
          return ckFail(msg.id, "E_GIT_COMMIT_NOT_REPO: La carpeta no es un "
                                "repositorio git. " +
                                    err);
        std::vector<std::wstring> paths;
        paths.reserve(files.size());
        for (const auto &file : files) {
          std::wstring joined;
          if (!ConfinedRepoPath(canonicalRoot, file, joined))
            return ckFail(msg.id,
                          "E_GIT_COMMIT_PATH_OUTSIDE: La ruta queda fuera de "
                          "la carpeta autorizada o no es valida: " +
                              file.substr(0, 240));
          paths.push_back(std::move(joined));
        }
        std::vector<std::wstring> add = {L"add", L"--"};
        add.insert(add.end(), paths.begin(), paths.end());
        RunGitCapture(root, add, err);
        if (!err.empty())
          return ckFail(msg.id, "E_GIT_COMMIT_FAILED: git add fallo: " + err);
        std::vector<std::wstring> commit = {L"commit", L"-m",
                                            Utf8ToWide(message), L"--"};
        commit.insert(commit.end(), paths.begin(), paths.end());
        RunGitCapture(root, commit, err);
        if (!err.empty())
          return ckFail(msg.id,
                        "E_GIT_COMMIT_FAILED: git commit fallo: " + err);
        const std::string hash =
            TrimAscii(RunGitCapture(root, {L"rev-parse", L"HEAD"}, err));
        if (err.empty() && hash.empty())
          err = "git no devolvio ningun identificador";
        if (!err.empty())
          return ckFail(
              msg.id, "E_GIT_COMMIT_FAILED: no se pudo leer el commit: " + err);
        std::string filesEcho = "[";
        for (size_t i = 0; i < files.size(); ++i) {
          if (i)
            filesEcho += ",";
          filesEcho += "\"" + JsonEscape(files[i]) + "\"";
        }
        filesEcho += "]";
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"status\":\"ok\",\"payload\":{\"root\":\"" +
               JsonEscape(root) + "\",\"hash\":\"" + JsonEscape(hash) +
               "\",\"files\":" + filesEcho + "}}";
      });

  // --- Puntos de control (B1, 10-nov) ---------------------------------------
  //
  // «Revertir los archivos» debe dejar el proyecto EXACTAMENTE como estaba
  // antes de la ejecucion, como el checkpoint de Cursor o Claude Code: se
  // restauran los modificados, se recuperan los borrados y se BORRA lo que la
  // ejecucion creo. Antes la foto era `git stash create` (solo lo seguido) y
  // la vuelta `git restore --worktree`, que no quitaba nada nuevo.
  //
  // La foto es ahora un indice git propio (GIT_INDEX_FILE, fuera del proyecto)
  // sembrado con el indice real y con `git add -A` encima: contiene todo lo no
  // ignorado, seguido y SIN seguimiento. Al revertir, con ese indice:
  //  - `ls-files --others --exclude-standard` = lo que la foto no conocia: lo
  //    creo la ejecucion (o se creo despues). Se borra.
  //  - `diff --name-only` = lo modificado o borrado desde la foto. Se escribe
  //    de nuevo desde la foto (`checkout-index`).
  // Lo ignorado por .gitignore no entra en la foto ni en la lista de
  // creados: nunca se toca. Un archivo sin seguimiento que ya existia esta en
  // la foto: nunca se borra, y si la ejecucion lo cambio o lo borro, vuelve.
  // Las carpetas internas del motor (devagents-workspace, .devagents*) y los
  // temporales de guardado quedan fuera de las dos cosas.
  // Las carpetas que se quedan vacias al borrar se quitan solo si se crearon
  // despues de la foto (fecha de creacion de NTFS): una carpeta vacia que ya
  // existia no la ve git y no se puede distinguir de otro modo.
  // Sin git no hay punto de control (como antes): la cabina ofrece
  // «Iniciar git aqui».
  const auto checkpointExcluded = [](const std::string &rel) {
    if (rel.empty() || rel.back() == '/') // repositorio anidado: nunca
      return true;
    if (IsEngineInternalPath(rel) ||
        confined::IsSaveTemporaryPath(Utf8ToWide(rel)))
      return true;
    std::string first = rel.substr(0, rel.find('/'));
    for (char &c : first)
      if (c >= 'A' && c <= 'Z')
        c = static_cast<char>(c + ('a' - 'A'));
    // Nombres exactos: `.devagents-save-1.tmp.bak` es un archivo del usuario.
    return first == ".devagents" || first == ".devagents-gate" ||
           first == ".git";
  };
  const auto splitNul = [](const std::string &out) {
    std::vector<std::string> items;
    size_t from = 0;
    while (from < out.size()) {
      size_t end = out.find('\0', from);
      if (end == std::string::npos)
        end = out.size();
      if (end > from)
        items.push_back(out.substr(from, end - from));
      from = end + 1;
    }
    return items;
  };
  // Lanza `git <prefix> -- <rutas>` en tandas que caben en una linea de
  // comandos de Windows (32 767 caracteres).
  const auto gitInBatches =
      [](const std::string &root, const std::wstring &index,
         const std::wstring &emptyTree, const std::vector<std::wstring> &prefix,
         const std::vector<std::string> &paths, std::string &err) {
        size_t i = 0;
        while (i < paths.size()) {
          std::vector<std::wstring> args = prefix;
          args.push_back(L"--");
          size_t chars = 0;
          while (i < paths.size() &&
                 (chars < 20000 || args.size() == prefix.size() + 1)) {
            const std::wstring p = Utf8ToWide(paths[i++]);
            chars += p.size() + 3;
            args.push_back(p);
          }
          RunCheckpointGit(root, index, emptyTree, args, err);
          if (!err.empty())
            return false;
        }
        return true;
      };

  RegisterHandler(
      "checkpoint.create",
      [ckFail, this, docMgr, checkpointExcluded, splitNul,
       gitInBatches](const BridgeMessage &msg) -> std::string {
        std::string root = GetStringProp(msg.payloadJson, "root");
        if (root.empty())
          root = docMgr ? preview::Narrow(docMgr->ActiveWorkspaceRoot()) : "";
        std::wstring canonical;
        if (!docMgr || !docMgr->IsAuthorizedWorkspaceRoot(Utf8ToWide(root)) ||
            !confined::Absolute(Utf8ToWide(root), canonical))
          return ckFail(msg.id, "E_CHECKPOINT_ROOT_NOT_AUTHORIZED: Carpeta de "
                                "punto de control no autorizada");
        FILETIME startedAt{};
        GetSystemTimeAsFileTime(&startedAt);
        std::string err;
        confined::LockedPath checkpointTree;
        if (!confined::LockTree(canonical, checkpointTree))
          return ckFail(msg.id, "E_CHECKPOINT_TREE_UNSAFE: Árbol inseguro: "
                                "reanálisis, hardlink o "
                                "componente ilegible");
        if (!IsGitRepo(root, err))
          return ckFail(
              msg.id,
              "El punto de control necesita que la carpeta de trabajo sea "
              "un repositorio git. " +
                  err);

        // Indice propio, fuera del proyecto (no ensucia el arbol ni .git).
        // Los que deja un host cerrado sin pasar por ~Bridge los limpia el
        // arranque (PruneStaleCheckpointIndexes).
        const std::wstring dir = CheckpointIndexDir();
        if (dir.empty())
          return ckFail(msg.id, "E_CHECKPOINT_FAILED: No se encontró la "
                                "carpeta temporal del sistema");
        if (!CreateDirectoryW(dir.c_str(), nullptr) &&
            GetLastError() != ERROR_ALREADY_EXISTS)
          return ckFail(msg.id, "E_CHECKPOINT_FAILED: No se pudo crear la "
                                "carpeta de los puntos de control");
        static unsigned long long sequence = 0;
        const std::wstring indexPath =
            dir + L"\\" + std::to_wstring(GetCurrentProcessId()) + L"-" +
            std::to_wstring(GetTickCount64()) + L"-" +
            std::to_wstring(++sequence) + L".index";
        const auto fail = [&](const std::string &why) {
          DeleteFileW(indexPath.c_str());
          DeleteFileW((indexPath + L".lock").c_str());
          return ckFail(msg.id, "E_CHECKPOINT_FAILED: " + why);
        };

        // Arbol vacio del formato de este repositorio (SHA-1 o SHA-256):
        // `hash-object -t tree --stdin` con la entrada vacia (NUL).
        const std::string emptyTree = TrimAscii(RunGitCapture(
            root, {L"hash-object", L"-t", L"tree", L"--stdin"}, err));
        if (!err.empty() || emptyTree.empty())
          return fail("git no pudo calcular el árbol vacío: " + err);
        const std::wstring emptyTreeW = Utf8ToWide(emptyTree);

        // Indice vacio + `add -A`: cada archivo se lee de nuevo, byte a byte.
        // (Sembrarlo con el indice real conservaria blobs con los finales de
        // linea ya convertidos de los archivos sin tocar.)
        RunCheckpointGit(
            root, indexPath, emptyTreeW,
            {L"add", L"-A", L"--", L".", L":(exclude,icase)devagents-workspace",
             L":(exclude,icase).devagents", L":(exclude,icase).devagents-gate"},
            err, /*magicPathspecs=*/true, 300000);
        if (!err.empty())
          return fail("No se pudo tomar la foto del proyecto: " + err);
        // Lo seguido que .gitignore ignora tambien es del proyecto: entra.
        std::vector<std::string> trackedIgnored;
        for (const auto &rel :
             splitNul(RunGitCapture(root,
                                    {L"ls-files", L"-z", L"--cached",
                                     L"--ignored", L"--exclude-standard"},
                                    err))) {
          std::wstring wrel = Utf8ToWide(rel);
          std::replace(wrel.begin(), wrel.end(), L'/', L'\\');
          if (!checkpointExcluded(rel) &&
              GetFileAttributesW(
                  confined::Extended(canonical + L"\\" + wrel).c_str()) !=
                  INVALID_FILE_ATTRIBUTES)
            trackedIgnored.push_back(rel);
        }
        if (!err.empty())
          return fail("No se pudieron enumerar los archivos seguidos e "
                      "ignorados: " +
                      err);
        if (!trackedIgnored.empty() &&
            !gitInBatches(root, indexPath, emptyTreeW, {L"add", L"-f"},
                          trackedIgnored, err))
          return fail("No se pudo tomar la foto de los archivos seguidos e "
                      "ignorados: " +
                      err);
        // Los temporales de guardado no son trabajo de nadie.
        std::vector<std::string> temporaries;
        for (const auto &rel : splitNul(RunCheckpointGit(
                 root, indexPath, emptyTreeW, {L"ls-files", L"-z"}, err)))
          if (confined::IsSaveTemporaryPath(Utf8ToWide(rel)))
            temporaries.push_back(rel);
        if (!err.empty())
          return fail("No se pudo leer la foto del proyecto: " + err);
        if (!temporaries.empty() &&
            !gitInBatches(root, indexPath, emptyTreeW,
                          {L"rm", L"--cached", L"-q", L"--ignore-unmatch"},
                          temporaries, err))
          return fail("No se pudo limpiar la foto del proyecto: " + err);
        const std::string sha = TrimAscii(RunCheckpointGit(
            root, indexPath, emptyTreeW, {L"write-tree"}, err));
        if (!err.empty())
          return fail("No se pudo guardar la foto del proyecto: " + err);
        if ((sha.size() != 40 && sha.size() != 64) ||
            sha.find_first_not_of("0123456789abcdef") != std::string::npos) {
          DeleteFileW(indexPath.c_str());
          return ckFail(
              msg.id,
              "E_CHECKPOINT_SHA_INVALID: Git devolvió un SHA no válido");
        }
        // Cuantos archivos sin seguimiento entran en la foto (antes quedaban
        // fuera y la cabina avisaba de que revertir no los borraria).
        std::string untracked = RunGitCapture(
            root, {L"ls-files", L"-z", L"--others", L"--exclude-standard"},
            err);
        if (!err.empty())
          return fail("No se pudieron enumerar los archivos sin "
                      "seguimiento: " +
                      err);
        int untrackedCount = 0;
        for (const auto &rel : splitNul(untracked))
          if (!checkpointExcluded(rel))
            untrackedCount++;

        // T1-D2 (12-nov): la foto solo cubre el arbol de trabajo; lo que el
        // usuario tenia preparado vive en el indice real (`git rev-parse
        // --git-path index`, que tambien sigue a las copias de trabajo
        // enlazadas). Se copia byte a byte junto a la foto: conserva
        // conflictos, intent-to-add y la informacion de stat. Los blobs a los
        // que apunta ya estan en el almacen de objetos del repositorio. Si no
        // se puede copiar, el punto de control sigue valiendo para los
        // archivos y restore dira que el indice no se toco.
        std::wstring realIndex, realIndexCopy;
        std::string realIndexNote;
        {
          std::string gitErr;
          const std::string where = TrimAscii(RunGitCapture(
              root, {L"rev-parse", L"--git-path", L"index"}, gitErr));
          if (!gitErr.empty() || where.empty()) {
            realIndexNote = "git no dijo dónde está el índice: " + gitErr;
          } else {
            std::wstring w = Utf8ToWide(where);
            std::replace(w.begin(), w.end(), L'/', L'\\');
            const bool absolute =
                (w.size() >= 2 && w[1] == L':') ||
                (w.size() >= 2 && w[0] == L'\\' && w[1] == L'\\');
            if (!absolute)
              w = Utf8ToWide(root) + L"\\" + w;
            wchar_t full[32768];
            const DWORD len = GetFullPathNameW(w.c_str(), 32768, full, nullptr);
            if (len == 0 || len >= 32768) {
              realIndexNote = "no se pudo resolver la ruta del índice";
            } else {
              realIndex.assign(full, len);
              const std::wstring copy = indexPath + L".real.index";
              if (GetFileAttributesW(realIndex.c_str()) ==
                  INVALID_FILE_ATTRIBUTES)
                realIndexNote = "el repositorio no tenía índice al crear el "
                                "punto de control";
              else if (!CopyFileW(realIndex.c_str(), copy.c_str(), FALSE))
                realIndexNote = "no se pudo copiar el índice (error " +
                                std::to_string(GetLastError()) + ")";
              else
                realIndexCopy = copy;
            }
          }
        }

        auto &issued = m_checkpoints[canonical];
        const auto previous = issued.find(sha);
        if (previous != issued.end() &&
            previous->second.indexPath != indexPath) {
          DeleteFileW(previous->second.indexPath.c_str());
          if (!previous->second.realIndexCopy.empty())
            DeleteFileW(previous->second.realIndexCopy.c_str());
        }
        issued[sha] = {
            indexPath,
            emptyTreeW,
            (static_cast<unsigned long long>(startedAt.dwHighDateTime) << 32) |
                startedAt.dwLowDateTime,
            realIndex,
            realIndexCopy,
            realIndexNote};

        return "{\"id\":" + std::to_string(msg.id) +
               ",\"status\":\"ok\",\"payload\":{\"sha\":\"" + JsonEscape(sha) +
               "\",\"root\":\"" + JsonEscape(root) +
               "\",\"untrackedCount\":" + std::to_string(untrackedCount) + "}}";
      });

  RegisterHandler(
      "checkpoint.restore",
      [ckFail, this, docMgr, checkpointExcluded, splitNul,
       gitInBatches](const BridgeMessage &msg) -> std::string {
        std::string sha = GetStringProp(msg.payloadJson, "sha");
        std::string root = GetStringProp(msg.payloadJson, "root");
        if (sha.empty())
          return ckFail(msg.id, "Falta sha");
        if (root.empty())
          root = docMgr ? preview::Narrow(docMgr->ActiveWorkspaceRoot()) : "";
        std::wstring canonical;
        if (!docMgr || !docMgr->IsAuthorizedWorkspaceRoot(Utf8ToWide(root)) ||
            !confined::Absolute(Utf8ToWide(root), canonical))
          return ckFail(msg.id, "E_CHECKPOINT_ROOT_NOT_AUTHORIZED: Carpeta de "
                                "punto de control no autorizada");
        // Se valida antes de usarlo en una linea de comandos: solo hexadecimal.
        if (sha.size() != 40 && sha.size() != 64)
          return ckFail(msg.id,
                        "E_CHECKPOINT_SHA_INVALID: Longitud de SHA no válida");
        for (char c : sha) {
          if (!isxdigit(static_cast<unsigned char>(c)))
            return ckFail(msg.id,
                          "El identificador del punto de control no es valido");
        }
        std::string err;
        const auto issuedRoot = m_checkpoints.find(canonical);
        if (issuedRoot == m_checkpoints.end() || !issuedRoot->second.count(sha))
          return ckFail(msg.id, "E_CHECKPOINT_NOT_ISSUED: El host no emitió "
                                "ese punto de control para "
                                "esta carpeta");
        const CheckpointRecord record = issuedRoot->second.at(sha);
        if (GetFileAttributesW(record.indexPath.c_str()) ==
            INVALID_FILE_ATTRIBUTES)
          return ckFail(msg.id, "E_CHECKPOINT_INDEX_MISSING: Falta la foto "
                                "de este punto de control en la carpeta "
                                "temporal; no se ha tocado ningún archivo");

        int restoredCount = 0;
        std::vector<std::string> deleted, notDeleted;
        {
          // Do not let an existing junction/symlink turn a tracked directory
          // into a write outside the granted tree. Git metadata may be a
          // native worktree .git file, but never a reparse point.
          confined::LockedPath checkpointTree;
          if (!confined::LockTree(canonical, checkpointTree))
            return ckFail(msg.id, "E_CHECKPOINT_TREE_UNSAFE: Árbol inseguro: "
                                  "reanálisis, hardlink o "
                                  "componente ilegible");
          // Primero se mira todo; si git falla aqui no se ha tocado nada.
          std::vector<std::string> created;
          for (const auto &rel : splitNul(RunCheckpointGit(
                   root, record.indexPath, record.emptyTree,
                   {L"ls-files", L"-z", L"--others", L"--exclude-standard"},
                   err)))
            if (!checkpointExcluded(rel))
              created.push_back(rel);
          if (!err.empty())
            return ckFail(msg.id, "E_CHECKPOINT_FAILED: No se pudo saber qué "
                                  "archivos creó la ejecución: " +
                                      err);
          std::vector<std::string> changed;
          for (const auto &rel : splitNul(
                   RunCheckpointGit(root, record.indexPath, record.emptyTree,
                                    {L"diff", L"--no-color", L"--no-ext-diff",
                                     L"--no-renames", L"--name-only", L"-z"},
                                    err)))
            if (!checkpointExcluded(rel))
              changed.push_back(rel);
          if (!err.empty())
            return ckFail(msg.id, "E_CHECKPOINT_FAILED: No se pudo comparar "
                                  "con el punto de control: " +
                                      err);

          // Lo creado se borra. Las rutas vienen de git (relativas, con '/');
          // se rechaza cualquier componente que salga de la carpeta. El arbol
          // esta bloqueado y sin puntos de reanalisis ni hardlinks
          // (LockTree), asi que el nombre es el archivo que git vio.
          for (const auto &rel : created) {
            std::wstring wrel = Utf8ToWide(rel);
            std::replace(wrel.begin(), wrel.end(), L'/', L'\\');
            std::wstring full;
            if (!confined::Absolute(canonical + L"\\" + wrel, full) ||
                !confined::Inside(canonical, full)) {
              notDeleted.push_back(rel);
              continue;
            }
            const std::wstring ext = confined::Extended(full);
            const DWORD attrs = GetFileAttributesW(ext.c_str());
            if (attrs != INVALID_FILE_ATTRIBUTES &&
                (attrs & FILE_ATTRIBUTE_READONLY))
              SetFileAttributesW(ext.c_str(), attrs & ~FILE_ATTRIBUTE_READONLY);
            if (DeleteFileW(ext.c_str()) ||
                GetLastError() == ERROR_FILE_NOT_FOUND)
              deleted.push_back(rel);
            else
              notDeleted.push_back(rel);
          }
          // Lo modificado o borrado vuelve desde la foto.
          if (!changed.empty() &&
              !gitInBatches(root, record.indexPath, record.emptyTree,
                            {L"checkout-index", L"-f", L"-q"}, changed, err))
            return ckFail(msg.id,
                          "E_CHECKPOINT_FAILED: git no pudo restaurar los "
                          "archivos (" +
                              std::to_string(deleted.size()) +
                              " ya borrados): " + err);
          restoredCount = static_cast<int>(changed.size());
        }

        // Carpetas que se quedaron vacias y que nacieron despues de la foto.
        // Fuera del bloqueo: sus handles no comparten DELETE. Se abre cada
        // carpeta sin seguir reanalisis y solo se marca para borrar si sigue
        // siendo una carpeta normal; el sistema rechaza borrarla si no esta
        // vacia.
        int removedDirs = 0;
        std::vector<std::wstring> parents;
        for (const auto &rel : deleted) {
          std::wstring wrel = Utf8ToWide(rel);
          std::replace(wrel.begin(), wrel.end(), L'/', L'\\');
          for (size_t cut = wrel.find_last_of(L'\\');
               cut != std::wstring::npos && cut > 0;
               cut = wrel.find_last_of(L'\\', cut - 1))
            parents.push_back(wrel.substr(0, cut));
        }
        std::sort(parents.begin(), parents.end(),
                  [](const std::wstring &a, const std::wstring &b) {
                    return a.size() != b.size() ? a.size() > b.size() : a < b;
                  });
        parents.erase(std::unique(parents.begin(), parents.end()),
                      parents.end());
        for (const auto &rel : parents) {
          std::wstring full;
          if (!confined::Absolute(canonical + L"\\" + rel, full) ||
              !confined::Inside(canonical, full))
            continue;
          HANDLE h = CreateFileW(
              confined::Extended(full).c_str(), DELETE | FILE_READ_ATTRIBUTES,
              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
              OPEN_EXISTING,
              FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
              nullptr);
          if (h == INVALID_HANDLE_VALUE)
            continue;
          BY_HANDLE_FILE_INFORMATION info{};
          const bool plainDir =
              GetFileInformationByHandle(h, &info) &&
              (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
              !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
          const unsigned long long born =
              (static_cast<unsigned long long>(
                   info.ftCreationTime.dwHighDateTime)
               << 32) |
              info.ftCreationTime.dwLowDateTime;
          if (plainDir && born > record.createdAt) {
            FILE_DISPOSITION_INFO dispose{};
            dispose.DeleteFile = TRUE;
            if (SetFileInformationByHandle(h, FileDispositionInfo, &dispose,
                                           sizeof(dispose)))
              removedDirs++;
          }
          CloseHandle(h);
        }

        // T1-D2 (12-nov): el indice real vuelve a como estaba al crear el
        // punto de control, como el «rewind» de otras IDE: un `git mv` o
        // `git add` de la ejecucion no se queda preparado. Se escribe como lo
        // hace git (index.lock exclusivo y renombrado); si otro git tiene el
        // candado, no se toca y se dice.
        bool indexRestored = false;
        std::string indexNote = record.realIndexNote;
        if (!record.realIndexCopy.empty()) {
          std::string saved, current;
          if (!ReadWholeFileBytes(record.realIndexCopy, saved)) {
            indexNote = "falta la copia del índice de este punto de control";
          } else if (ReadWholeFileBytes(record.realIndex, current) &&
                     current == saved) {
            indexRestored = true;
          } else if (saved.size() > MAXDWORD) {
            indexNote = "el índice es demasiado grande para restaurarlo";
          } else {
            const std::wstring lock = record.realIndex + L".lock";
            HANDLE h = CreateFileW(lock.c_str(), GENERIC_WRITE, 0, nullptr,
                                   CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (h == INVALID_HANDLE_VALUE) {
              const DWORD code = GetLastError();
              indexNote = code == ERROR_FILE_EXISTS
                              ? "otro proceso de git tiene bloqueado el índice "
                                "(index.lock); sigue como lo dejó la ejecución"
                              : "no se pudo crear index.lock (error " +
                                    std::to_string(code) + ")";
            } else {
              DWORD written = 0;
              const bool wrote =
                  WriteFile(h, saved.data(), static_cast<DWORD>(saved.size()),
                            &written, nullptr) &&
                  written == saved.size() && FlushFileBuffers(h);
              DWORD code = wrote ? 0 : GetLastError();
              CloseHandle(h);
              if (wrote && MoveFileExW(lock.c_str(), record.realIndex.c_str(),
                                       MOVEFILE_REPLACE_EXISTING |
                                           MOVEFILE_WRITE_THROUGH)) {
                indexRestored = true;
              } else {
                if (wrote)
                  code = GetLastError();
                DeleteFileW(lock.c_str());
                indexNote = "no se pudo escribir el índice (error " +
                            std::to_string(code) +
                            "); sigue como lo dejó la ejecución";
              }
            }
          }
        }

        std::string notDeletedJson = "[";
        for (size_t i = 0; i < notDeleted.size(); ++i)
          notDeletedJson +=
              (i ? ",\"" : "\"") + JsonEscape(notDeleted[i]) + "\"";
        notDeletedJson += "]";
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"status\":\"ok\",\"payload\":{\"restored\":" +
               std::to_string(restoredCount) +
               ",\"deleted\":" + std::to_string(deleted.size()) +
               ",\"removedDirs\":" + std::to_string(removedDirs) +
               ",\"notDeleted\":" + notDeletedJson +
               ",\"indexRestored\":" + (indexRestored ? "true" : "false") +
               (indexRestored
                    ? std::string()
                    : ",\"indexNote\":\"" + JsonEscape(indexNote) + "\"") +
               "}}";
      });

  // --- Crear archivos y carpetas desde el explorador ------------------------
  //
  // Hasta ahora la unica forma de crear algo era pedirselo al agente o escribir
  // un comando en la terminal. Para un archivo vacio eso es desproporcionado:
  // gasta una llamada al modelo y un ciclo de aprobacion para hacer `touch`.
  // Un explorador de archivos crea archivos y carpetas; es lo minimo que se
  // espera de uno.
  //
  // Ambos handlers COMPARTEN dos salvaguardas:
  //  - El nombre es un nombre, no una ruta: se rechazan separadores y `..`, de
  //    modo que no se puede escribir fuera de la carpeta sobre la que se hizo
  //    clic derecho.
  //  - No se sobrescribe NADA. Si ya existe, se devuelve error. Crear no es
  //    reemplazar, y un explorador que pisa un archivo por un doble clic es un
  //    destructor de datos.
  auto validarNombre = [](const std::string &name) -> const char * {
    if (name.empty())
      return "Falta el nombre";
    if (name.find('\\') != std::string::npos ||
        name.find('/') != std::string::npos ||
        name.find(':') != std::string::npos)
      return "El nombre no puede llevar separadores de ruta";
    if (name.find("..") != std::string::npos)
      return "El nombre no puede contener '..'";
    // Caracteres que Windows prohibe en un nombre de archivo. Sin esto, el
    // fallo llega como un error opaco de la API en vez de un mensaje util.
    if (name.find_first_of("<>\"|?*") != std::string::npos)
      return "El nombre lleva caracteres no permitidos en Windows";
    return nullptr;
  };

  RegisterHandler(
      "fs.mkdir",
      [validarNombre, docMgr](const BridgeMessage &msg) -> std::string {
        const std::string id = std::to_string(msg.id);
        std::string parent = GetStringProp(msg.payloadJson, "parent");
        std::string name = GetStringProp(msg.payloadJson, "name");
        if (parent.empty())
          return "{\"id\":" + id + ",\"error\":\"Falta la carpeta padre\"}";
        if (const char *bad = validarNombre(name))
          return "{\"id\":" + id + ",\"error\":\"" + bad + "\"}";

        std::string error;
        if (!docMgr ||
            !docMgr->CreateWorkspaceEntry(Utf8ToWide(parent), Utf8ToWide(name),
                                          true, "", error))
          return "{\"id\":" + id + ",\"error\":\"" +
                 JsonEscape(error.empty() ? "DocumentManager unavailable"
                                          : error) +
                 "\"}";
        return "{\"id\":" + id + ",\"status\":\"ok\",\"payload\":{\"path\":\"" +
               JsonEscape(parent + "\\" + name) + "\"}}";
      });

  RegisterHandler(
      "fs.createFile",
      [validarNombre, docMgr](const BridgeMessage &msg) -> std::string {
        const std::string id = std::to_string(msg.id);
        std::string parent = GetStringProp(msg.payloadJson, "parent");
        std::string name = GetStringProp(msg.payloadJson, "name");
        std::string content = GetStringProp(msg.payloadJson, "content");
        if (parent.empty())
          return "{\"id\":" + id + ",\"error\":\"Falta la carpeta padre\"}";
        if (const char *bad = validarNombre(name))
          return "{\"id\":" + id + ",\"error\":\"" + bad + "\"}";

        std::string error;
        if (!docMgr ||
            !docMgr->CreateWorkspaceEntry(Utf8ToWide(parent), Utf8ToWide(name),
                                          false, content, error))
          return "{\"id\":" + id + ",\"error\":\"" +
                 JsonEscape(error.empty() ? "DocumentManager unavailable"
                                          : error) +
                 "\"}";
        return "{\"id\":" + id + ",\"status\":\"ok\",\"payload\":{\"path\":\"" +
               JsonEscape(parent + "\\" + name) + "\"}}";
      });

  RegisterHandler("fs.list", [docMgr](const BridgeMessage &msg) -> std::string {
    std::string pathStr = GetStringProp(msg.payloadJson, "path");
    if (pathStr.empty())
      pathStr = docMgr ? preview::Narrow(docMgr->ActiveWorkspaceRoot()) : "";

    std::wstring wpath = Utf8ToWide(pathStr);

    if (confined::IsSaveTemporaryPath(wpath))
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"E_LIST_SAVE_TEMPORARY: Ruta temporal de guardado "
             "reservada\"}";

    confined::LockedPath locked;
    if (!docMgr || !docMgr->LockReadDirectory(wpath, locked))
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"E_LIST_ROOT_NOT_AUTHORIZED: Carpeta no autorizada o "
             "insegura\"}";
    WIN32_FIND_DATAW fd;
    HANDLE h =
        FindFirstFileW((confined::Extended(locked.path) + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"No se pudo listar " + JsonEscape(pathStr) + "\"}";

    // Carpetas primero y luego archivos, ambos en orden alfabetico, para que
    // el arbol se lea como el de cualquier IDE.
    std::vector<std::string> dirs;
    std::vector<std::string> files;
    do {
      std::wstring name = fd.cFileName;
      if (name == L"." || name == L".." || confined::IsSaveTemporaryName(name))
        continue;
      if (fd.dwFileAttributes &
          (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_REPARSE_POINT))
        continue;
      bool isDir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
      std::string entry = WideToUtf8(name);
      if (isDir)
        dirs.push_back(entry);
      else
        files.push_back(entry);
    } while (FindNextFileW(h, &fd));
    const DWORD listError = GetLastError();
    FindClose(h);
    if (listError != ERROR_NO_MORE_FILES)
      return "{\"id\":" + std::to_string(msg.id) +
             ",\"error\":\"E_LIST_INCOMPLETE: Listado de la carpeta "
             "incompleto\"}";

    std::sort(dirs.begin(), dirs.end());
    std::sort(files.begin(), files.end());

    std::string root = WideToUtf8(wpath);
    std::string out = "{\"root\":\"" + JsonEscape(root) + "\",\"entries\":[";
    bool first = true;
    for (const auto &d : dirs) {
      if (!first)
        out += ",";
      first = false;
      out += "{\"name\":\"" + JsonEscape(d) + "\",\"path\":\"" +
             JsonEscape(root + "\\" + d) + "\",\"isDir\":true}";
    }
    for (const auto &f : files) {
      if (!first)
        out += ",";
      first = false;
      out += "{\"name\":\"" + JsonEscape(f) + "\",\"path\":\"" +
             JsonEscape(root + "\\" + f) + "\",\"isDir\":false}";
    }
    out += "]}";

    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":" + out + "}";
  });
}

bool Bridge::ValidateSchema(const std::string &rawJson, BridgeMessage &outMsg) {
  outMsg.id = 0;
  outMsg.kind.clear();
  outMsg.payloadJson = "{}";

  if (rawJson.empty()) {
    return false;
  }

  // 1. "id" — solo vale la clave del nivel superior. Una `"id"` dentro del
  // payload o dentro de una cadena NO es el identificador del mensaje.
  size_t idPos = FindTopLevelValuePos(rawJson, "id");
  if (idPos == std::string::npos) {
    return false;
  }
  size_t idEnd = idPos;
  while (idEnd < rawJson.length() &&
         (isdigit(static_cast<unsigned char>(rawJson[idEnd])) ||
          rawJson[idEnd] == '-')) {
    idEnd++;
  }
  if (idEnd == idPos) {
    return false;
  }
  try {
    outMsg.id = std::stoi(rawJson.substr(idPos, idEnd - idPos));
  } catch (...) {
    return false;
  }

  // 2. "kind" — idem. Antes una clave `"kind"` anidada en el payload se
  // imponía a la del sobre si aparecía primero en el texto.
  size_t kindPos = FindTopLevelValuePos(rawJson, "kind");
  if (kindPos == std::string::npos || rawJson[kindPos] != '"') {
    return false;
  }
  size_t kindEndEx = MatchStringEnd(rawJson, kindPos);
  if (kindEndEx == std::string::npos) {
    return false;
  }
  outMsg.kind = rawJson.substr(kindPos + 1, kindEndEx - kindPos - 2);
  if (outMsg.kind.empty()) {
    return false;
  }

  // 3. "payload" (opcional) — el emparejado de llaves respeta las cadenas:
  // una `}` dentro de un texto ya no trunca el payload.
  size_t payloadPos = FindTopLevelValuePos(rawJson, "payload");
  if (payloadPos != std::string::npos) {
    const char c = rawJson[payloadPos];
    if (c == '{' || c == '[') {
      size_t endEx = MatchContainerEnd(rawJson, payloadPos);
      if (endEx != std::string::npos) {
        outMsg.payloadJson = rawJson.substr(payloadPos, endEx - payloadPos);
      }
    } else if (c == '"') {
      size_t endEx = MatchStringEnd(rawJson, payloadPos);
      if (endEx != std::string::npos) {
        outMsg.payloadJson = rawJson.substr(payloadPos, endEx - payloadPos);
      }
    }
    // Un payload escalar (numero/bool/null) se deja como "{}".
  }

  return true;
}

// Extrae el `kind` del nivel superior sin validar el mensaje completo. Es la
// ÚNICA lectura de tipo que usa el enrutado de colas de main.cpp: antes se
// hacía por substring (`find("\"kind\":\"core.")`), que fallaba con espacios
// (`"kind": "core.x"`) y confundía una cadena `"kind"` escrita dentro del
// payload con el tipo real del mensaje.
std::string Bridge::ExtractKind(const std::string &rawJson) {
  size_t kindPos = FindTopLevelValuePos(rawJson, "kind");
  if (kindPos == std::string::npos || kindPos >= rawJson.size() ||
      rawJson[kindPos] != '"') {
    return "";
  }
  size_t kindEndEx = MatchStringEnd(rawJson, kindPos);
  if (kindEndEx == std::string::npos) {
    return "";
  }
  return rawJson.substr(kindPos + 1, kindEndEx - kindPos - 2);
}

std::string Bridge::CreateErrorResponse(int id, const std::string &errorMsg) {
  std::ostringstream ss;
  ss << "{\"id\":" << id << ",\"error\":\"" << JsonEscape(errorMsg) << "\"}";
  return ss.str();
}

// ---------------------------------------------------------------------------
// Texto de la autorización nativa (BAJO-1).
// ---------------------------------------------------------------------------

// Dato de la página para mostrarlo en un diálogo: sin controles ni
// marcas/anulaciones bidireccionales (no puede fingir líneas ni invertir el
// texto), acotado y cortado en un límite de carácter UTF-8.
static std::string ConsentValue(const std::string &raw, size_t limit = 240) {
  std::string out;
  for (size_t i = 0; i < raw.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(raw[i]);
    if (c < 0x20 || c == 0x7f) {
      out += ' ';
      continue;
    }
    if (c == 0xE2 && i + 2 < raw.size()) {
      const unsigned char b1 = static_cast<unsigned char>(raw[i + 1]);
      const unsigned char b2 = static_cast<unsigned char>(raw[i + 2]);
      // U+200E/200F, U+202A..202E, U+2066..2069.
      if ((b1 == 0x80 &&
           (b2 == 0x8E || b2 == 0x8F || (b2 >= 0xAA && b2 <= 0xAE))) ||
          (b1 == 0x81 && b2 >= 0xA6 && b2 <= 0xA9)) {
        out += '?';
        i += 2;
        continue;
      }
    }
    out += static_cast<char>(c);
  }
  if (out.size() > limit) {
    size_t cut = limit;
    while (cut > 0 && (static_cast<unsigned char>(out[cut]) & 0xC0) == 0x80)
      --cut;
    out.resize(cut);
    out += "\xE2\x80\xA6";
  }
  return out.empty() ? std::string("(vacío)") : out;
}

// Dirección sin credenciales, consulta ni fragmento (pueden llevar secretos).
static std::string ConsentUrl(std::string url) {
  const size_t tail = url.find_first_of("?#");
  if (tail != std::string::npos)
    url.resize(tail);
  const size_t scheme = url.find("://");
  if (scheme != std::string::npos) {
    const size_t authority = scheme + 3;
    const size_t slash = url.find('/', authority);
    const size_t end = slash == std::string::npos ? url.size() : slash;
    const size_t at = url.rfind('@', end == 0 ? 0 : end - 1);
    if (at != std::string::npos && at >= authority && at < end)
      url.erase(authority, at + 1 - authority);
  }
  return ConsentValue(url);
}

// Primer elemento de un arreglo JSON de cadenas: el programa. Los argumentos
// (que pueden llevar tokens) nunca se muestran.
static std::string ConsentProgram(const std::string &argvJson) {
  size_t open = argvJson.find('[');
  if (open == std::string::npos)
    return "";
  size_t quote = argvJson.find_first_not_of(" \t\r\n", open + 1);
  if (quote == std::string::npos || argvJson[quote] != '"')
    return "";
  const size_t end = MatchStringEnd(argvJson, quote);
  if (end == std::string::npos)
    return "";
  return GetStringProp("{\"a\":" + argvJson.substr(quote, end - quote) + "}",
                       "a");
}

static std::string ConsentNumber(const std::string &payload, const char *key) {
  return "n.º " + std::to_string(GetInt64Prop(payload, key, 0));
}

// Una entrada por capacidad privilegiada: la acción la fija el host y el
// recurso se compone con datos de la página ya neutralizados. Es una tabla
// consultada por `find`, no un despacho por kind: nada se ejecuta aquí.
struct ConsentEntry {
  const char *action;
  std::string (*resource)(const std::string &payload);
};

static std::string ConsentProp(const std::string &payload, const char *key,
                               size_t limit = 240) {
  return ConsentValue(GetStringProp(payload, key), limit);
}

static const std::unordered_map<std::string, ConsentEntry> &ConsentTable() {
  static const std::unordered_map<std::string, ConsentEntry> table = {
      {"core.mcp.connect",
       {"Conectar un servidor MCP: se ejecutará un programa local",
        [](const std::string &p) {
          const std::string program =
              ConsentProgram(GetStringProp(p, "argvJson"));
          const std::string cwd = GetStringProp(p, "cwd");
          return "Programa: " +
                 (program.empty() ? std::string("(no legible)")
                                  : ConsentValue(program)) +
                 (cwd.empty() ? "" : "; carpeta: " + ConsentValue(cwd)) +
                 " (los argumentos no se muestran)";
        }}},
      {"core.mcp.authToken",
       {"Entregar a la página el token de autenticación del servidor MCP "
        "propio",
        [](const std::string &) {
          return std::string("Token local (no se muestra aquí)");
        }}},
      {"core.hooks.set",
       {"Cambiar los hooks del motor: programas que ejecutará ante sus "
        "eventos",
        [](const std::string &) {
          return std::string(
              "Configuración completa de hooks (se aplicará tal cual)");
        }}},
      {"core.external.paths.set",
       {"Cambiar las rutas de los agentes externos que el motor puede lanzar",
        [](const std::string &p) {
          return "Rutas: " + ConsentProp(p, "json", 400);
        }}},
      {"core.permissions.set",
       {"Cambiar el modo y las reglas de permisos del motor",
        [](const std::string &p) {
          return "Configuración: " + ConsentProp(p, "configJson", 400);
        }}},
      {"core.plugin.trust",
       {"Confiar en un plugin: su código podrá ejecutarse en este equipo",
        [](const std::string &p) {
          return "Carpeta: " + ConsentProp(p, "folder");
        }}},
      {"core.screenshot",
       {"Capturar la pantalla y entregar la imagen a la página",
        [](const std::string &) {
          return std::string("Pantalla completa de este equipo");
        }}},
      {"core.remote.start",
       {"Abrir el control remoto de la cabina en un puerto local",
        [](const std::string &p) {
          return "Puerto: " + std::to_string(GetInt64Prop(p, "port", 0)) +
                 "; origen permitido: " + ConsentProp(p, "origin");
        }}},
      {"core.webhooks.add",
       {"Registrar un webhook: el motor enviará eventos a una dirección "
        "externa",
        [](const std::string &p) {
          return "Destino: " + ConsentUrl(GetStringProp(p, "url")) +
                 "; evento: " + ConsentProp(p, "event", 80) +
                 " (el secreto no se muestra)";
        }}},
      {"core.webhooks.test",
       {"Enviar un evento de prueba a un webhook registrado",
        [](const std::string &p) {
          return "Webhook " + ConsentNumber(p, "id");
        }}},
      {"core.provider.add",
       {"Registrar un proveedor de modelos y su dirección base",
        [](const std::string &p) {
          return "Proveedor: " + ConsentProp(p, "name", 80) +
                 "; dirección: " + ConsentUrl(GetStringProp(p, "baseUrl"));
        }}},
      {"core.git.storeCredential",
       {"Guardar una credencial de git en el administrador de credenciales "
        "del sistema",
        [](const std::string &p) {
          return "Servidor: " + ConsentProp(p, "host", 120) +
                 "; usuario: " + ConsentProp(p, "username", 120) +
                 " (la contraseña no se muestra)";
        }}},
      {"core.workspace.restorePermissions",
       {"Restaurar el acceso de escritura a la carpeta de trabajo de una "
        "orden",
        [](const std::string &p) {
          return "Orden " + ConsentNumber(p, "orderId");
        }}},
      {"core.pr.merge",
       {"Fusionar un pull request en el remoto",
        [](const std::string &p) {
          return "Pull request " + ConsentNumber(p, "prId");
        }}},
      {"core.order.ship",
       {"Enviar el trabajo de una orden al remoto",
        [](const std::string &p) {
          return "Orden " + ConsentNumber(p, "orderId");
        }}},
      {"lsp.request",
       {"Enviar una petición a un servidor de lenguaje del host",
        [](const std::string &p) {
          std::string target = GetStringProp(p, "language");
          if (target.empty())
            target = GetStringProp(p, "serverCmd");
          return "Lenguaje: " + ConsentValue(target, 80) +
                 "; método: " + ConsentProp(p, "method", 120);
        }}},
      {"core.repo.clone",
       {"Clonar un repositorio remoto en una carpeta local",
        [](const std::string &p) {
          return "Origen: " + ConsentUrl(GetStringProp(p, "url")) +
                 "; destino: " + ConsentProp(p, "targetDir");
        }}},
      {"core.issues.comment",
       {"Publicar un comentario en una incidencia o pull request",
        [](const std::string &p) {
          return "Proyecto: " + ConsentProp(p, "project", 160) + " (" +
                 ConsentProp(p, "source", 40) +
                 "); id: " + ConsentProp(p, "issue_id", 80) +
                 " (el texto del comentario no se muestra)";
        }}},
  };
  return table;
}

std::wstring Bridge::ConsentText(const std::string &kind,
                                 const std::string &payload,
                                 const std::wstring &closing) {
  std::string action = "Capacidad privilegiada del host";
  std::string resource = ConsentValue(kind, 120);
  const auto entry = ConsentTable().find(kind);
  if (entry != ConsentTable().end()) {
    action = entry->second.action;
    resource = entry->second.resource(payload);
  }
  return L"La cabina pide hacer algo que necesita tu permiso.\n\n"
         L"Acción: " +
         Utf8ToWide(action) + L"\n" + L"Recurso (lo indica la página): " +
         Utf8ToWide(resource) + L"\n\n" + closing;
}

// ---------------------------------------------------------------------------
// (12-nov): permisos como Claude Code, Codex y VS Code. Endurecer
// nunca pregunta; ampliar sí. Auto y Omitir permisos se habilitan UNA vez en
// el diálogo nativo y el host lo recuerda en la carpeta de datos; desde
// entonces cambiar a ese modo es un cambio más.
// ---------------------------------------------------------------------------

// Orden de los modos de executor.zig (PermissionMode) por lo que dejan hacer
// sin preguntar: normal (todo con efectos pregunta) < accept_edits (ediciones
// dentro del espacio de trabajo) < autonomous (shell, exec y red) < bypass
// (todo). En checkPrefix autonomous y bypass auto-aprueban igual; bypass va
// arriba porque su promesa es «no preguntar nada». -1: no es un modo.
static int PermissionModeRank(const std::string &mode) {
  if (mode == "normal")
    return 0;
  if (mode == "accept_edits")
    return 1;
  if (mode == "autonomous")
    return 2;
  if (mode == "bypass")
    return 3;
  return -1;
}

static bool IsElevatedMode(const std::string &mode) {
  return mode == "autonomous" || mode == "bypass";
}

static const char *PermissionModeLabel(const std::string &mode) {
  if (mode == "normal")
    return "Manual";
  if (mode == "accept_edits")
    return "Aceptar ediciones";
  if (mode == "autonomous")
    return "Auto";
  if (mode == "bypass")
    return "Omitir permisos";
  return "(desconocido)";
}

static const char *PermissionModeMeaning(const std::string &mode) {
  if (mode == "accept_edits")
    return "las ediciones de archivos dentro de la carpeta de trabajo se "
           "aplican sin preguntarte; los comandos siguen pidiendo permiso.";
  if (mode == "autonomous")
    return "el agente edita y borra archivos, ejecuta comandos y usa la red "
           "sin preguntarte. No hay aislamiento del sistema; los prefijos "
           "denegados se siguen respetando.";
  if (mode == "bypass")
    return "todo se aprueba solo, sin preguntarte nada. Los prefijos "
           "denegados se siguen respetando y son la única red de seguridad.";
  return "";
}

static std::string JoinConsentList(const std::vector<std::string> &items) {
  std::string out;
  constexpr size_t kVisible = 10;
  for (size_t i = 0; i < std::min(items.size(), kVisible); ++i)
    out += (i ? ", " : "") + ("«" + ConsentValue(items[i], 120) + "»");
  if (items.size() > kVisible)
    out += " y " + std::to_string(items.size() - kVisible) + " más";
  return out;
}

static bool ContainsString(const std::vector<std::string> &items,
                           const std::string &value) {
  return std::find(items.begin(), items.end(), value) != items.end();
}

static std::string JsonStringArray(const std::vector<std::string> &items) {
  std::string out = "[";
  for (size_t i = 0; i < items.size(); ++i)
    out += (i ? ",\"" : "\"") + JsonEscape(items[i]) + "\"";
  return out + "]";
}

bool Bridge::ReadPermissionConfig(std::string &json, std::string &error) {
  if (m_permissionReader)
    return m_permissionReader(json, error);
  if (!m_core || !m_core->EngineReady()) {
    error = "el motor no está disponible";
    return false;
  }
  if (!m_core->Api().get_permission_config) {
    error = "da_get_permission_config no disponible";
    return false;
  }
  char *out = nullptr;
  const int rc = m_core->Api().get_permission_config(m_core->Handle(), &out);
  json = m_core->TakeString(out);
  if (rc != 0) {
    error = m_core->LastEngineError();
    if (error.empty())
      error = "da_get_permission_config devolvió " + std::to_string(rc);
    return false;
  }
  return true;
}

std::wstring Bridge::ConsentMemoryDir() {
  {
    std::lock_guard<std::mutex> lock(m_consentMutex);
    if (!m_consentMemoryDir.empty())
      return m_consentMemoryDir;
  }
  return m_core ? m_core->DataDirectory() : std::wstring();
}

// Lee el recuerdo. Un archivo que no existe es «nada habilitado»; uno que
// existe y no se puede leer devuelve el motivo en `error` y, en la duda, nada
// habilitado: se vuelve a preguntar (nunca se concede por un fallo).
std::unordered_set<std::string> Bridge::RememberedModes(std::string &error) {
  std::unordered_set<std::string> modes;
  const std::wstring dir = ConsentMemoryDir();
  if (dir.empty())
    return modes;
  std::lock_guard<std::mutex> lock(m_consentMutex);
  const std::wstring path = dir + L"\\" + kElevatedModesFile;
  HANDLE file =
      CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    const DWORD code = GetLastError();
    if (code != ERROR_FILE_NOT_FOUND && code != ERROR_PATH_NOT_FOUND)
      error = "no se pudo leer " + WideToUtf8(path) + " (error " +
              std::to_string(code) + ")";
    return modes;
  }
  char buffer[256];
  DWORD read = 0;
  const BOOL ok = ReadFile(file, buffer, sizeof(buffer), &read, nullptr);
  CloseHandle(file);
  if (!ok) {
    error = "no se pudo leer " + WideToUtf8(path);
    return modes;
  }
  std::istringstream lines(std::string(buffer, read));
  std::string line;
  while (std::getline(lines, line)) {
    line = TrimAscii(line);
    if (IsElevatedMode(line))
      modes.insert(line);
  }
  return modes;
}

// Escribe el recuerdo entero en un temporal y lo sustituye de una vez: un
// corte a mitad nunca deja un archivo a medias.
bool Bridge::RememberMode(const std::string &mode, std::string &error) {
  std::string readError;
  auto modes = RememberedModes(readError);
  if (!readError.empty()) {
    error = readError;
    return false;
  }
  modes.insert(mode);
  const std::wstring dir = ConsentMemoryDir();
  if (dir.empty()) {
    error = "no hay carpeta de datos donde recordarlo";
    return false;
  }
  std::string text;
  for (const char *known : {"autonomous", "bypass"})
    if (modes.count(known))
      text += std::string(known) + "\r\n";
  std::lock_guard<std::mutex> lock(m_consentMutex);
  const std::wstring path = dir + L"\\" + kElevatedModesFile;
  const std::wstring temp = path + L".tmp";
  HANDLE file = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    error = "no se pudo escribir " + WideToUtf8(temp) + " (error " +
            std::to_string(GetLastError()) + ")";
    return false;
  }
  DWORD written = 0;
  const BOOL wrote =
      WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written,
                nullptr) &&
      written == text.size() && FlushFileBuffers(file);
  CloseHandle(file);
  if (!wrote ||
      !MoveFileExW(temp.c_str(), path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    error = "no se pudo guardar " + WideToUtf8(path) + " (error " +
            std::to_string(GetLastError()) + ")";
    DeleteFileW(temp.c_str());
    return false;
  }
  return true;
}

bool Bridge::ForgetElevatedModes(std::string &error) {
  const std::wstring dir = ConsentMemoryDir();
  if (dir.empty())
    return true; // sin carpeta de datos nunca se recordó nada
  std::lock_guard<std::mutex> lock(m_consentMutex);
  const std::wstring path = dir + L"\\" + kElevatedModesFile;
  if (DeleteFileW(path.c_str()))
    return true;
  const DWORD code = GetLastError();
  if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND)
    return true;
  error = "No se pudo borrar " + WideToUtf8(path) + " (error " +
          std::to_string(code) + ")";
  return false;
}

// core.permissions.set: el host compara lo pedido con lo vigente y reenvía al
// motor SOLO lo que ha evaluado (JSON canónico rehecho aquí), de modo que una
// diferencia entre este lector y el parser del motor (claves repetidas,
// tipos raros) no puede colar una ampliación que el diálogo no mostró.
Bridge::ConsentDecision
Bridge::DecidePermissionsConsent(const BridgeMessage &msg) {
  ConsentDecision decision;
  const std::string cfg =
      TrimAscii(GetStringProp(msg.payloadJson, "configJson"));
  if (cfg.empty())
    return decision; // el handler responde «Falta configJson»
  if (cfg.front() != '{') {
    decision.error = "E_PERMISSIONS_CONFIG: configJson debe ser un objeto JSON";
    return decision;
  }
  const size_t modeAt = FindTopLevelValuePos(cfg, "mode");
  const size_t allowAt = FindTopLevelValuePos(cfg, "allow");
  const size_t denyAt = FindTopLevelValuePos(cfg, "deny");
  const bool hasMode = modeAt != std::string::npos;
  const bool hasAllow = allowAt != std::string::npos;
  const bool hasDeny = denyAt != std::string::npos;
  const std::string mode = hasMode ? GetStringProp(cfg, "mode") : "";
  if ((hasMode && (cfg[modeAt] != '"' || PermissionModeRank(mode) < 0)) ||
      (hasAllow && cfg[allowAt] != '[') || (hasDeny && cfg[denyAt] != '[')) {
    decision.error = "E_PERMISSIONS_CONFIG: mode debe ser normal, "
                     "accept_edits, autonomous o bypass; allow y deny, listas "
                     "de cadenas";
    return decision;
  }
  const auto allow = GetStringArrayProp(cfg, "allow");
  const auto deny = GetStringArrayProp(cfg, "deny");
  std::string canonical;
  if (hasMode)
    canonical += "\"mode\":\"" + mode + "\"";
  if (hasAllow)
    canonical += (canonical.empty() ? "" : ",") + std::string("\"allow\":") +
                 JsonStringArray(allow);
  if (hasDeny)
    canonical += (canonical.empty() ? "" : ",") + std::string("\"deny\":") +
                 JsonStringArray(deny);
  canonical = "{" + canonical + "}";
  decision.rewrite = true;
  decision.payload = "{\"configJson\":\"" + JsonEscape(canonical) + "\"}";
  if (!hasMode && !hasAllow && !hasDeny)
    return decision; // no cambia nada

  std::string current, readError;
  const bool known = ReadPermissionConfig(current, readError);
  const std::string currentMode = known ? GetStringProp(current, "mode") : "";
  const auto currentAllow =
      known ? GetStringArrayProp(current, "allow") : std::vector<std::string>();
  const auto currentDeny =
      known ? GetStringArrayProp(current, "deny") : std::vector<std::string>();

  std::vector<std::string> newAllow, removedDeny;
  if (hasAllow)
    for (const auto &entry : allow)
      if (!ContainsString(currentAllow, entry) &&
          !ContainsString(newAllow, entry))
        newAllow.push_back(entry);
  if (hasDeny)
    for (const auto &entry : currentDeny)
      if (!ContainsString(deny, entry))
        removedDeny.push_back(entry);
  const bool raisesMode =
      hasMode &&
      PermissionModeRank(mode) > std::max(0, PermissionModeRank(currentMode));

  std::string memoryError;
  const auto remembered = RememberedModes(memoryError);
  // Un modo habilitado una vez deja de preguntar; Aceptar ediciones queda por
  // debajo de cualquiera de los dos, así que tampoco pregunta si alguno lo
  // está.
  const bool modeEnabled =
      IsElevatedMode(mode) ? remembered.count(mode) > 0 : !remembered.empty();
  const bool modeNeedsAsk = raisesMode && (!known || !modeEnabled);
  // Sin lo vigente solo se sabe que no amplía lo que deja todo en lo mínimo
  // (modo Manual, sin permitidos y sin tocar los denegados).
  const bool minimal = (!hasMode || mode == "normal") &&
                       (!hasAllow || allow.empty()) && !hasDeny;
  decision.ask =
      known ? (modeNeedsAsk || !newAllow.empty() || !removedDeny.empty())
            : !minimal;
  if (!decision.ask)
    return decision;

  const bool canRemember = !ConsentMemoryDir().empty();
  if (modeNeedsAsk && IsElevatedMode(mode) && canRemember)
    decision.rememberMode = mode;

  std::string text = "La cabina pide ampliar lo que el agente puede hacer sin "
                     "preguntarte.\n";
  if (!known)
    text += "\nNo se pudo leer la configuración vigente del motor (" +
            ConsentValue(readError, 160) +
            "), así que no se puede saber si esto amplía algo. Configuración "
            "pedida: " +
            ConsentValue(canonical, 400) + "\n";
  if (hasMode && (modeNeedsAsk || !known))
    text += std::string("\nModo: ") +
            (known ? PermissionModeLabel(currentMode) : "(no leído)") + " → " +
            PermissionModeLabel(mode) +
            (std::string(PermissionModeMeaning(mode)).empty()
                 ? std::string(".")
                 : std::string(". ") + PermissionModeMeaning(mode)) +
            "\n";
  if (!newAllow.empty())
    text += "\nComandos que se ejecutarán sin preguntarte (nuevos): " +
            JoinConsentList(newAllow) + "\n";
  if (!removedDeny.empty())
    text += "\nComandos que dejarán de estar bloqueados: " +
            JoinConsentList(removedDeny) + "\n";
  if (!memoryError.empty())
    text += "\nAviso: " + ConsentValue(memoryError, 200) + "\n";
  if (!decision.rememberMode.empty())
    text += std::string("\nSi lo permites, este equipo lo recordará: volver a "
                        "«") +
            PermissionModeLabel(mode) +
            "» no te lo preguntará otra vez. Para revocarlo: Configuración › "
            "Permisos › «Volver a pedir confirmación para Auto y Omitir».";
  else if (modeNeedsAsk && IsElevatedMode(mode))
    text += "\nNo hay carpeta de datos donde recordarlo: se volverá a "
            "preguntar la próxima vez.";
  else
    text += "\nSi lo permites, vale solo para este cambio.";
  decision.body = Utf8ToWide(text);
  return decision;
}

Bridge::ConsentDecision Bridge::DecideConsent(const BridgeMessage &msg) {
  if (msg.kind == "core.permissions.set")
    return DecidePermissionsConsent(msg);

  ConsentDecision decision;
  decision.ask = true;
  // Servidor MCP: aprobado una vez por programa, argumentos y carpeta exactos
  // hasta cerrar DevAgents. Otros argumentos (pueden cambiar lo que hace) o
  // otra carpeta vuelven a preguntar.
  if (msg.kind == "core.mcp.connect") {
    decision.sessionGrant = "mcp\n" +
                            GetStringProp(msg.payloadJson, "argvJson") + "\n" +
                            GetStringProp(msg.payloadJson, "cwd");
    decision.body = ConsentText(
        msg.kind, msg.payloadJson,
        L"Si lo permites, no se volverá a preguntar por este mismo programa "
        L"con los mismos argumentos y la misma carpeta hasta cerrar "
        L"DevAgents.");
  }
  // Servidor de lenguaje: lsp.request solo lanza un programa cuando no hay
  // ninguno arrancado (y es uno del registro del host). Una petición a uno ya
  // arrancado no lanza nada y no pregunta; arrancar se aprueba una vez por
  // ejecutable hasta cerrar DevAgents.
  if (msg.kind == "lsp.request") {
    std::string selector = GetStringProp(msg.payloadJson, "language");
    if (selector.empty())
      selector = GetStringProp(msg.payloadJson, "serverCmd");
    std::wstring executable;
    if (!m_lsp || m_lsp->IsRunning() || selector.empty() ||
        !security::ResolveLsp(Utf8ToWide(selector), executable)) {
      decision.ask = false;
      return decision;
    }
    decision.sessionGrant = "lsp\n" + WideToUtf8(executable);
    decision.body = ConsentText(
        msg.kind, msg.payloadJson,
        L"Arrancará el servidor de lenguaje " + executable +
            L". Si lo permites, no se volverá a preguntar por este programa "
            L"hasta cerrar DevAgents.");
  }
  if (!decision.sessionGrant.empty()) {
    std::lock_guard<std::mutex> lock(m_consentMutex);
    if (m_sessionGrants.count(decision.sessionGrant))
      decision.ask = false;
  }
  return decision;
}

std::string Bridge::HandleMessage(const std::string &rawJson) {
  if (rawJson.size() > 28u * 1024u * 1024u)
    return CreateErrorResponse(0, "mensaje excede 28 MiB");
  BridgeMessage parsed;
  if (!ValidateSchema(rawJson, parsed)) {
    return CreateErrorResponse(
        0, "Invalid JSON schema or missing required fields");
  }

  // El dialogo y el handler reciben la MISMA instantanea inmutable. No se
  // guarda un permiso reutilizable: cada peticion vuelve a pedir aprobacion,
  // incluso si solo cambian los archivos o el mensaje de core.git.commit.
  const BridgeMessage msg = std::move(parsed);
  auto it = m_handlers.find(msg.kind);
  if (it == m_handlers.end()) {
    return CreateErrorResponse(
        msg.id, "E_UNKNOWN_KIND: Tipo de mensaje desconocido: " + msg.kind);
  }

  try {
    if (msg.kind == "pty.spawn") {
      std::wstring executable;
      if (!security::ResolveShell(
              Utf8ToWide(GetStringProp(msg.payloadJson, "shellPath")),
              executable))
        return CreateErrorResponse(msg.id, "Shell fuera del registro del host");
    }
    if (msg.kind == "lsp.request") {
      auto selector = GetStringProp(msg.payloadJson, "language");
      if (selector.empty())
        selector = GetStringProp(msg.payloadJson, "serverCmd");
      std::wstring executable;
      if (!selector.empty() &&
          !security::ResolveLsp(Utf8ToWide(selector), executable))
        return CreateErrorResponse(
            msg.id, "LSP fuera del registro del host o no instalado");
    }
    // Guard path-bearing engine calls at the host boundary, before an unloaded
    // engine, a forwarded payload or a different search mode can bypass grants.
    confined::LockedPath operationRoot;
    std::string field;
    bool exactRoot = false, creating = false;
    if (msg.kind == "core.workspace.set") {
      field = "path";
      exactRoot = true;
    } else if (msg.kind == "core.mount.add") {
      field = "path";
    } else if (msg.kind == "core.repo.clone") {
      field = "targetDir";
      creating = true;
    } else if (msg.kind == "search.query" || msg.kind == "search.embedIndex" ||
               msg.kind == "search.embedStatus") {
      field = "rootDir";
      exactRoot = true;
    } else if (msg.kind == "pty.spawn") {
      field = "workingDir";
    }
    if (!field.empty()) {
      std::string selected = GetStringProp(msg.payloadJson, field);
      // These engine APIs otherwise fall back to mutable engine workspace
      // state. Validate the exact root they receive, not an unrelated cwd.
      if (selected.empty() && field == "rootDir")
        return CreateErrorResponse(
            msg.id,
            "E_SEARCH_ROOT_REQUIRED: La búsqueda exige una carpeta concedida");
      if (selected.empty())
        selected = m_documents
                       ? preview::Narrow(m_documents->ActiveWorkspaceRoot())
                       : "";
      const auto path = Utf8ToWide(selected);
      if (!m_documents ||
          (exactRoot && !m_documents->IsAuthorizedWorkspaceRoot(path)) ||
          (creating
               ? (!m_documents->IsWritableWorkspacePath(path) ||
                  !confined::LockParents(path, operationRoot, false,
                                         confined::kMutationDirectoryShare))
               : !m_documents->LockReadDirectory(path, operationRoot)))
        return CreateErrorResponse(msg.id,
                                   "E_OPERATION_ROOT_NOT_AUTHORIZED: Carpeta "
                                   "de la operación no autorizada o "
                                   "insegura");
      if (creating &&
          GetFileAttributesW(confined::Extended(operationRoot.path).c_str()) !=
              INVALID_FILE_ATTRIBUTES &&
          !m_documents->LockReadDirectory(path, operationRoot))
        return CreateErrorResponse(msg.id, "E_CLONE_TARGET_UNSAFE: El destino "
                                           "de clonado existente es inseguro");
    }

    if (msg.kind == "core.repo.clone" &&
        !security::IsBrowserUrl(
            Utf8ToWide(GetStringProp(msg.payloadJson, "url")), true))
      return CreateErrorResponse(msg.id,
                                 "E_REPO_URL_INVALID: La URL del repositorio "
                                 "debe ser HTTPS sin credenciales");

    // These capabilities configure or run arbitrary programs, disclose native
    // secrets/screen data, or widen the engine's permissions. JS booleans
    // cannot express native consent. Show no payload here (it may contain
    // credentials).
    if (!RequiresNativeConsent(msg.kind))
      return it->second(msg);
    // endurecer los permisos, un modo ya habilitado o un servidor
    // ya aprobado en esta sesión siguen sin diálogo.
    const ConsentDecision decision = DecideConsent(msg);
    if (!decision.error.empty())
      return CreateErrorResponse(msg.id, decision.error);
    BridgeMessage forwarded = msg;
    if (decision.rewrite)
      forwarded.payloadJson = decision.payload;
    if (decision.ask) {
      // Este hilo suele ser un worker: el diálogo se abre en el hilo de la
      // ventana propietaria. Sin propietario no hay diálogo seguro posible
      // (salvo un presentador inyectado por las pruebas del host).
      const std::wstring title = L"Autorizar una acción de la cabina";
      const std::wstring body = decision.body.empty()
                                    ? ConsentText(msg.kind, msg.payloadJson)
                                    : decision.body;
      bool approved = false;
      if (m_consentPresenter && !m_dialogOwner) {
        approved = m_consentPresenter(nullptr, title, body);
      } else if (m_dialogOwner) {
        consent::Presenter presenter;
        if (m_consentPresenter)
          presenter = [this](HWND owner, const std::wstring &t,
                             const std::wstring &b) {
            return m_consentPresenter(owner, t, b);
          };
        approved = consent::Ask(static_cast<HWND>(m_dialogOwner), title, body,
                                presenter);
      }
      if (!approved)
        return CreateErrorResponse(msg.id,
                                   "E_NATIVE_CONSENT_REQUIRED: Hace falta la "
                                   "autorización nativa del host");
    }

    std::string reply = it->second(forwarded);
    if (!decision.ask || reply.find("\"status\":\"ok\"") == std::string::npos)
      return reply;
    // Aprobado y aplicado: se recuerda lo que el diálogo dijo que se
    // recordaría. Si no se puede guardar, la respuesta lo dice (el cambio sí
    // se aplicó) y la próxima vez se vuelve a preguntar.
    if (!decision.sessionGrant.empty()) {
      std::lock_guard<std::mutex> lock(m_consentMutex);
      m_sessionGrants.insert(decision.sessionGrant);
    }
    std::string memoryError;
    if (!decision.rememberMode.empty() &&
        !RememberMode(decision.rememberMode, memoryError)) {
      const size_t payloadAt = reply.find("\"payload\":{");
      if (payloadAt != std::string::npos)
        reply.insert(payloadAt + 11,
                     "\"notRemembered\":\"" + JsonEscape(memoryError) + "\",");
    }
    return reply;
  } catch (const std::exception &e) {
    return CreateErrorResponse(msg.id,
                               std::string("Handler exception: ") + e.what());
  } catch (...) {
    return CreateErrorResponse(msg.id, "Unknown handler exception");
  }
}

} // namespace beats
