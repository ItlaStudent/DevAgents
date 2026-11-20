// D4 tramo 2 — lado C++ del Supervisor del motor (ver engine_supervisor.cpp).
#ifndef BEATS_ENGINE_SUPERVISOR_HPP_
#define BEATS_ENGINE_SUPERVISOR_HPP_

#include <string>
#include <vector>
#include <windows.h>

namespace beats {

class EngineSupervisor {
public:
  struct StatusResult {
    bool online = false;
    unsigned int pid = 0; // PID del HIJO que respondió: cambia tras un kill.
    std::string version;
    std::string error;
  };

  EngineSupervisor();
  ~EngineSupervisor();

  // Arranca el hijo devagents-engine.exe con la tubería indicada (sin el
  // prefijo \\.\pipe\: se añade aquí, el nombre es el del protocolo Zig).
  bool Start(const std::wstring &engineExePath, const std::string &pipeName);
  void Stop();

  // `da_status` por el bus. Mata y reconecta si hace falta: es la promesa de
  // D4 — un motor caído no se lleva la cabina.
  StatusResult Status();

  bool ChildAlive() const;
  unsigned int Restarts() const;
  unsigned int ChildPid() const { return m_childPid; }

private:
  bool SpawnChild();
  bool ConnectWithDeadline(DWORD deadlineMs);
  void ClosePipe();
  bool Send(unsigned short msgType, const std::string &payload);
  bool Recv(std::string &outPayload, unsigned short &outType);

  HANDLE m_hProcess = nullptr;
  // job con KILL_ON_JOB_CLOSE; su handle muere con el host.
  HANDLE m_hJob = nullptr;
  HANDLE m_hPipe = nullptr;
  unsigned int m_childPid = 0;
  unsigned int m_restarts = 0;
  std::wstring m_engineExePath;
  std::string m_pipeName;
  std::string m_lastError;
};

} // namespace beats

#endif // BEATS_ENGINE_SUPERVISOR_HPP_
