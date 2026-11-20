#ifndef BEATS_PTY_MANAGER_HPP
#define BEATS_PTY_MANAGER_HPP

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <windows.h>

namespace beats {

using TerminalDataCallback =
    std::function<void(int terminalId, const std::string &data)>;

struct TerminalInstance {
  int id = 0;
  std::wstring shellPath;
  std::wstring workingDir;
  HANDLE hProcess = nullptr;
  HANDLE hPipeIn = nullptr;
  HANDLE hPipeOut = nullptr;
  HANDLE hPipeInRead = nullptr;
  HANDLE hPipeOutWrite = nullptr;
  HPCON hPC = nullptr;
  std::thread readThread;
  std::atomic<bool> running{false};
  std::string scrollback;
  mutable std::mutex scrollbackMutex;
  short cols = 80;
  short rows = 25;
  /// true si esta terminal cayo al respaldo por tuberias porque el
  /// ConPTY no entregaba salida. Sin pseudoconsola no hay redimension.
  bool usaTuberias = false;
};

struct TerminalInfo {
  int id;
  std::wstring shellPath;
  short cols;
  short rows;
  bool running;
  bool pseudoConsole;
};

class PtyManager {
public:
  PtyManager();
  ~PtyManager();

  int CreateTerminal(const std::wstring &shellPath,
                     const std::wstring &workingDir,
                     TerminalDataCallback callback);
  bool WriteTerminal(int id, const std::string &data);
  bool ResizeTerminal(int id, short cols, short rows);
  // true si la terminal va por pseudoconsola; false si cayó al
  // respaldo por tuberías (o no existe). La interfaz lo dice tal cual.
  bool IsPseudoConsole(int id) const;
  void CloseTerminal(int id);
  void CloseAllTerminals();

  std::string GetScrollback(int id) const;
  std::vector<TerminalInfo> ListTerminals() const;

private:
  bool SpawnConPty(TerminalInstance *inst);
  bool SpawnTuberias(TerminalInstance *inst);
  void LanzarLector(TerminalInstance *inst, TerminalDataCallback callback);

  int m_nextId = 1;
  std::unordered_map<int, std::unique_ptr<TerminalInstance>> m_terminals;
};

} // namespace beats

#endif // BEATS_PTY_MANAGER_HPP
