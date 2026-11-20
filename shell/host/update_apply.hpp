#ifndef BEATS_UPDATE_APPLY_HPP
#define BEATS_UPDATE_APPLY_HPP
// Tanda 5 (F0.4,): aplicar una actualización AL CERRAR.
//
// El motor decide si hay algo que aplicar (da_update_pending_apply_json: algo
// preparado, aceptado por el usuario, más nuevo, con la misma huella y sin
// órdenes en curso). El host, ya fuera del bucle de mensajes, comprueba que no
// queda vivo ningún otro proceso devagents-*.exe de la carpeta de instalación
// (un devagents-mcp.exe que haya lanzado otra IDE, otra cabina, un
// devagents-core.exe de consola) y solo entonces lanza el instalador en
// silencio. El instalador espera al mutex del host (tools/installer.iss) para
// no tocar archivos en uso. DevAgents nunca se relanza solo.
#include <string>
#include <vector>
#include <windows.h>

namespace beats {
namespace update {

// Mutex con nombre del host vivo. tools/installer.iss espera a que
// desaparezca cuando se ejecuta con /UPDATE. Mismo texto en los dos sitios.
constexpr const wchar_t *kHostMutexName = L"DevAgentsHostRunning";

struct PendingApply {
  bool apply = false;
  std::wstring path;
  std::string sha256; // T12 M3: huella que el host vuelve a calcular
  std::string reason;
  bool valid = false; // el JSON tenía la forma esperada
};

// {"apply":bool,"path":str|null,"sha256":str|null,"reason":str}. Si apply es
// true, path es obligatorio y absoluto (X:\...) y sha256 son 64 hex; si no,
// el resultado no es válido.
PendingApply ParsePendingApply(const std::string &json);

// T12 M3: abre el instalador sin permitir que nadie lo escriba, lo renombre ni
// lo borre mientras el handle siga abierto, y comprueba con ESE handle que su
// ruta final (sin enlaces ni uniones) está dentro de `<dataDir>\updates\` y
// que su SHA-256 es `expectedSha256`. Devuelve el handle (hay que mantenerlo
// abierto hasta lanzar el instalador y cerrarlo después) o
// INVALID_HANDLE_VALUE con el motivo en `why`.
HANDLE OpenVerifiedInstaller(const std::wstring &installer,
                             const std::wstring &dataDir,
                             const std::string &expectedSha256,
                             std::string &why);

// SHA-256 en hex minúsculas del contenido de `file` desde el principio;
// vacío si no se pudo leer (con el motivo en `why`).
std::string Sha256HexOfHandle(HANDLE file, std::string &why);

struct ProcessEntry {
  DWORD pid = 0;
  DWORD parent = 0;
  std::wstring exeName;   // nombre del ejecutable (PROCESSENTRY32W)
  std::wstring imagePath; // ruta completa, si se pudo leer
  bool pathKnown = false;
};

// Procesos que impiden aplicar: devagents*.exe distintos de este proceso y de
// sus descendientes (que mueren con él), cuya imagen está en `installDir`.
// Uno cuya ruta no se pudo leer también bloquea: no se puede descartar.
std::vector<ProcessEntry>
BlockingProcesses(const std::vector<ProcessEntry> &all, DWORD selfPid,
                  const std::wstring &installDir);

// Lista real de procesos (CreateToolhelp32Snapshot +
// QueryFullProcessImageNameW). `ok` = false si no se pudo tomar la foto:
// entonces no se aplica.
std::vector<ProcessEntry> SnapshotProcesses(bool &ok);

// Línea de órdenes del instalador: ruta entre comillas y modo silencioso de
// actualización, con su registro en `logPath` si no está vacío.
std::wstring InstallerCommandLine(const std::wstring &installer,
                                  const std::wstring &logPath);

// Comprueba los procesos y, si nada lo impide, vuelve a comprobar ruta y
// huella (OpenVerifiedInstaller, T12 M3) y lanza el instalador (CreateProcessW,
// sin shell, sin heredar handles) con el archivo aún bloqueado. Devuelve una
// línea para el registro que describe lo que pasó.
std::string ApplyOnExit(const std::wstring &installer,
                        const std::wstring &installDir,
                        const std::wstring &logPath,
                        const std::wstring &dataDir,
                        const std::string &expectedSha256);

// Añade una línea con fecha a `<dataDir>\update.log` (fuera de updates\, que
// el motor borra tras aplicar la actualización).
void AppendLog(const std::wstring &dataDir, const std::string &line);

} // namespace update
} // namespace beats

#endif
