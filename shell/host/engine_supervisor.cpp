// D4 tramo 2 — el Supervisor del motor, lado C++.
//
// El tramo 1 (core/src/engine_process.zig) demostró en banco que un hijo
// devagents-engine.exe atiende `da_status` por una tubería con nombre y que
// matarlo y reconectar funciona. Lo que faltaba era el mismo cable en la
// cabina: `CoreClient::GetStatus()` seguía reportando el PID del host.
//
// Este archivo ES ese cable. Habla el MISMO protocolo binario del bus
// (bus/protocol.zig): header de 16 bytes {magic 0xDA7A6000, version 1,
// msg_type, payload_len, crc32} + payload. El CRC es el polinomio reflejado
// estándar (0xEDB88320), tabla generada en tiempo de construcción.
//
// Lo que NO hace: migrar las ~60 exportadas restantes. Da_status va por el
// hijo; el resto sigue por DLL, como en el tramo 1. Es deliberado (ver
// engine_process.zig): la promesa de D4 se comprueba con una función.

#include "engine_supervisor.hpp"
#include <cstdio>
#include <cstring>
#include <windows.h>

namespace beats {

namespace {

// CRC32 reflejado estándar, idéntico al de bus/protocol.zig.
struct Crc32Table {
  unsigned int t[256];
  constexpr Crc32Table() : t{} {
    for (unsigned int i = 0; i < 256; ++i) {
      unsigned int c = i;
      for (int j = 0; j < 8; ++j)
        c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      t[i] = c;
    }
  }
};
constexpr Crc32Table kCrc32{};

unsigned int Crc32(const unsigned char *data, size_t len) {
  unsigned int c = 0xFFFFFFFFu;
  for (size_t i = 0; i < len; ++i)
    c = kCrc32.t[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  return ~c;
}

#pragma pack(push, 1)
struct MessageHeader {
  unsigned int magic;
  unsigned short version;
  unsigned short msg_type;
  unsigned int payload_len;
  unsigned int checksum;
};
#pragma pack(pop)

constexpr unsigned int kProtocolMagic = 0xDA7A6000u;
constexpr unsigned short kProtocolVersion = 1;
constexpr unsigned short kMsgPing = 9;
constexpr unsigned short kMsgPong = 10;
constexpr unsigned short kMsgStatusRequest = 11;
constexpr unsigned short kMsgStatusResponse = 12;

// Plazo por operación de tubería. Un status que no vuelve en 5 s es un motor
// mudo: hay que devolver error y reconectar, no aparcar el carril rápido del
// puente para siempre — era el cuelgue que dejaba 300+ promesas JS en cola.
constexpr DWORD kIoTimeoutMs = 5000;

// ReadFile/WriteFile con plazo sobre un handle OVERLAPPED. Si el plazo vence se
// cancela la operación y se drena el resultado: el buffer queda íntegro y la
// conexión se cierra arriba (el llamador ya la trata como error).
bool IoWithDeadline(HANDLE h, void *buf, DWORD len, bool escritura,
                    DWORD *hechos) {
  *hechos = 0;
  OVERLAPPED ov = {};
  ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ov.hEvent)
    return false;
  DWORD n = 0;
  BOOL ok = escritura ? WriteFile(h, buf, len, &n, &ov)
                      : ReadFile(h, buf, len, &n, &ov);
  if (!ok && GetLastError() == ERROR_IO_PENDING) {
    if (WaitForSingleObject(ov.hEvent, kIoTimeoutMs) == WAIT_OBJECT_0) {
      ok = GetOverlappedResult(h, &ov, &n, FALSE);
    } else {
      CancelIoEx(h, &ov);
      // Esperar a que la cancelación termine antes de cerrar el evento: sin
      // esto, una llegada tardía escribe sobre un stack ya destruido.
      GetOverlappedResult(h, &ov, &n, TRUE);
      ok = FALSE;
    }
  }
  CloseHandle(ov.hEvent);
  *hechos = n;
  return ok == TRUE;
}

bool WriteAll(HANDLE h, const void *buf, DWORD len) {
  const char *p = static_cast<const char *>(buf);
  while (len > 0) {
    DWORD written = 0;
    if (!IoWithDeadline(h, const_cast<char *>(p), len, true, &written) ||
        written == 0)
      return false;
    p += written;
    len -= written;
  }
  return true;
}

} // namespace

EngineSupervisor::EngineSupervisor() = default;

EngineSupervisor::~EngineSupervisor() { Stop(); }

bool EngineSupervisor::Start(const std::wstring &engineExePath,
                             const std::string &pipeName) {
  m_pipeName = "\\\\.\\pipe\\" + pipeName;
  m_engineExePath = engineExePath;
  return SpawnChild();
}

void EngineSupervisor::Stop() {
  ClosePipe();
  if (m_hProcess) {
    TerminateProcess(m_hProcess, 0);
    WaitForSingleObject(m_hProcess, 2000);
    CloseHandle(m_hProcess);
    m_hProcess = nullptr;
  }
  m_childPid = 0;
}

bool EngineSupervisor::SpawnChild() {
  if (m_hProcess && ChildAlive())
    return true;
  ClosePipe();
  if (m_hProcess) {
    CloseHandle(m_hProcess);
    m_hProcess = nullptr;
  }

  std::wstring cmd = L"\"" + m_engineExePath + L"\" --engine-pipe " +
                     std::wstring(m_pipeName.begin() + 9, m_pipeName.end());
  std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
  cmdBuf.push_back(L'\0');

  // el motor vive dentro de un job con KILL_ON_JOB_CLOSE que solo
  // posee el host. Si el host muere de cualquier forma —cierre normal, cuelgue
  // matado con taskkill /F, crash—, el sistema cierra el handle del job y
  // mata el motor con él (y a los hijos del motor, que ya van en jobs anidados
  // propios; executor.zig no pide BREAKAWAY). Antes sobrevivía invisible
  // reteniendo la tubería y la base, y bloqueaba la reinstalación.
  if (!m_hJob) {
    m_hJob = CreateJobObjectW(nullptr, nullptr);
    if (m_hJob) {
      JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = {};
      li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      SetInformationJobObject(m_hJob, JobObjectExtendedLimitInformation, &li,
                              sizeof(li));
    }
  }

  STARTUPINFOW si = {sizeof(STARTUPINFOW)};
  PROCESS_INFORMATION pi = {};
  // El binario va FIJADO en lpApplicationName (misma invariante que
  // executor.zig): el SO no resuelve la ruta por la línea de comandos.
  // Arranca SUSPENDIDO para entrar en el job antes de ejecutar nada: así
  // ningún hijo que lance el motor queda fuera.
  if (!CreateProcessW(m_engineExePath.c_str(), cmdBuf.data(), nullptr, nullptr,
                      FALSE, CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr,
                      nullptr, &si, &pi)) {
    m_lastError = "CreateProcessW(devagents-engine) fallo";
    return false;
  }
  if (m_hJob)
    AssignProcessToJobObject(m_hJob, pi.hProcess);
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  m_hProcess = pi.hProcess;
  m_childPid = pi.dwProcessId;
  return true;
}

bool EngineSupervisor::ChildAlive() const {
  if (!m_hProcess)
    return false;
  DWORD code = 0;
  if (!GetExitCodeProcess(m_hProcess, &code))
    return false;
  return code == STILL_ACTIVE;
}

bool EngineSupervisor::ConnectWithDeadline(DWORD deadlineMs) {
  DWORD waited = 0;
  while (waited < deadlineMs) {
    // FILE_FLAG_OVERLAPPED: la lectura y la escritura llevan plazo. Sin él no
    // hay ReadFile con timeout y un motor que no contesta aparca al hilo que
    // atiende TODOS los core.* rápidos — la cabina entera parece muerta.
    HANDLE p = CreateFileA(
        m_pipeName.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr);
    if (p != INVALID_HANDLE_VALUE) {
      // Modo mensaje de la tubería, como hace el cliente Zig.
      DWORD mode = PIPE_READMODE_MESSAGE;
      SetNamedPipeHandleState(p, &mode, nullptr, nullptr);
      m_hPipe = p;
      return true;
    }
    if (!ChildAlive()) {
      m_lastError = "el hijo murio antes de crear la tuberia";
      return false;
    }
    Sleep(20);
    waited += 20;
  }
  m_lastError = "timeout conectando a la tuberia del motor";
  return false;
}

void EngineSupervisor::ClosePipe() {
  if (m_hPipe) {
    CloseHandle(m_hPipe);
    m_hPipe = nullptr;
  }
}

bool EngineSupervisor::Send(unsigned short msgType,
                            const std::string &payload) {
  if (!m_hPipe)
    return false;
  MessageHeader h{};
  h.magic = kProtocolMagic;
  h.version = kProtocolVersion;
  h.msg_type = msgType;
  h.payload_len = static_cast<unsigned int>(payload.size());
  h.checksum = Crc32(reinterpret_cast<const unsigned char *>(payload.data()),
                     payload.size());
  if (!WriteAll(m_hPipe, &h, sizeof(h)))
    return false;
  if (!payload.empty() &&
      !WriteAll(m_hPipe, payload.data(), static_cast<DWORD>(payload.size())))
    return false;
  return true;
}

bool EngineSupervisor::Recv(std::string &outPayload, unsigned short &outType) {
  if (!m_hPipe)
    return false;
  MessageHeader h{};
  DWORD read = 0;
  // El header llega en una lectura de tuberia. Con plazo y con tolerancia a
  // lecturas cortas (la tubería es de BYTES: un ReadFile puede devolver menos
  // de lo pedido): antes era un ReadFile síncrono que se quedaba para siempre
  // si el motor no contestaba, y con él moría el carril rápido del puente
  // entero — toda la cabina muda aunque el proceso motor siga vivo.
  DWORD totalHdr = 0;
  while (totalHdr < sizeof(h)) {
    if (!IoWithDeadline(m_hPipe, reinterpret_cast<char *>(&h) + totalHdr,
                        sizeof(h) - totalHdr, false, &read) ||
        read == 0)
      return false;
    totalHdr += read;
  }
  if (h.magic != kProtocolMagic || h.version != kProtocolVersion)
    return false;
  if (h.payload_len > 8 * 1024 * 1024)
    return false;
  std::string payload(h.payload_len, '\0');
  DWORD total = 0;
  while (total < h.payload_len) {
    if (!IoWithDeadline(m_hPipe, &payload[total], h.payload_len - total, false,
                        &read) ||
        read == 0)
      return false;
    total += read;
  }
  if (Crc32(reinterpret_cast<const unsigned char *>(payload.data()),
            payload.size()) != h.checksum)
    return false;
  outPayload = payload;
  outType = h.msg_type;
  return true;
}

EngineSupervisor::StatusResult EngineSupervisor::Status() {
  StatusResult r{};
  if (!ChildAlive() && !SpawnChild())
    return r;

  // Primera idea: reusar la conexión si sigue viva.
  bool fresh = false;
  if (!m_hPipe) {
    if (!ConnectWithDeadline(3000)) {
      // Reconexión completa (levantar hijo nuevo si murió): la promesa de D4
      // es que matar el motor no mate la cabina, y esto es el mecanismo.
      if (!SpawnChild() || !ConnectWithDeadline(3000)) {
        r.error = m_lastError;
        return r;
      }
      m_restarts++;
      fresh = true;
    }
  }

  for (int intento = 0; intento < 2; ++intento) {
    if (!Send(kMsgStatusRequest, "{\"query\":\"da_status\"}")) {
      ClosePipe();
      if (!ChildAlive() && !SpawnChild())
        m_restarts++;
      if (!ConnectWithDeadline(3000)) {
        r.error = m_lastError;
        return r;
      }
      continue;
    }
    std::string payload;
    unsigned short type = 0;
    if (!Recv(payload, type) || type != kMsgStatusResponse) {
      ClosePipe();
      if (!ChildAlive() && !SpawnChild())
        m_restarts++;
      if (!ConnectWithDeadline(3000)) {
        r.error = m_lastError;
        return r;
      }
      continue;
    }
    // Respuesta: {"status":"online","pid":N,"version":"..."}
    r.online = payload.find("\"status\":\"online\"") != std::string::npos;
    size_t at = payload.find("\"pid\":");
    if (at != std::string::npos) {
      unsigned long pid = std::strtoul(payload.c_str() + at + 6, nullptr, 10);
      r.pid = static_cast<unsigned int>(pid);
    }
    size_t vat = payload.find("\"version\":\"");
    if (vat != std::string::npos) {
      size_t vstart = vat + 11;
      size_t vend = payload.find('"', vstart);
      if (vend != std::string::npos)
        r.version = payload.substr(vstart, vend - vstart);
    }
    return r;
  }
  if (fresh)
    m_restarts--;
  r.error = "el motor no respondio tras la reconexion";
  return r;
}

unsigned int EngineSupervisor::Restarts() const { return m_restarts; }

} // namespace beats
