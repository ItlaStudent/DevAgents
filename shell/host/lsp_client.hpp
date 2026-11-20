#ifndef BEATS_LSP_CLIENT_HPP
#define BEATS_LSP_CLIENT_HPP

#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <windows.h>

namespace beats {

using LspResponseCallback = std::function<void(const std::string &jsonRpcMsg)>;

class LspClient {
public:
  LspClient();
  ~LspClient();

  bool Start(const std::wstring &serverCmd, LspResponseCallback callback);
  void Stop();

  bool SendRequest(int id, const std::string &method,
                   const std::string &paramsJson);
  bool SendNotification(const std::string &method,
                        const std::string &paramsJson);

  bool IsRunning() const { return m_running; }

private:
  void ReadThreadFunc();

  std::wstring m_serverCmd;
  LspResponseCallback m_callback;
  HANDLE m_hProcess = nullptr;
  HANDLE hPipeInWrite = nullptr;
  HANDLE hPipeOutRead = nullptr;
  std::thread m_readThread;
  std::atomic<bool> m_running{false};
};

} // namespace beats

#endif // BEATS_LSP_CLIENT_HPP
