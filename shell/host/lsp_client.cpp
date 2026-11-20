#include "lsp_client.hpp"
#include "shell_policy.hpp"
#include <iostream>
#include <sstream>

namespace beats {

LspClient::LspClient() {}

LspClient::~LspClient() { Stop(); }

bool LspClient::Start(const std::wstring &serverCmd,
                      LspResponseCallback callback) {
  std::wstring executable;
  if (!security::ResolveLsp(serverCmd, executable))
    return false;
  Stop();

  m_serverCmd = serverCmd;
  m_callback = callback;

  HANDLE hPipeInRead = nullptr, hPipeOutWrite = nullptr;
  SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};

  if (!CreatePipe(&hPipeInRead, &hPipeInWrite, &sa, 0) ||
      !CreatePipe(&hPipeOutRead, &hPipeOutWrite, &sa, 0)) {
    return false;
  }

  SetHandleInformation(hPipeInWrite, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(hPipeOutRead, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW si = {sizeof(STARTUPINFOW)};
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = hPipeInRead;
  si.hStdOutput = hPipeOutWrite;
  si.hStdError = GetStdHandle(STD_ERROR_HANDLE);

  PROCESS_INFORMATION pi = {};
  const std::wstring command = L"\"" + executable + L"\"";
  std::vector<wchar_t> cmdBuf(command.begin(), command.end());
  cmdBuf.push_back(L'\0');

  BOOL success =
      CreateProcessW(executable.c_str(), cmdBuf.data(), nullptr, nullptr, TRUE,
                     CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);

  CloseHandle(hPipeInRead);
  CloseHandle(hPipeOutWrite);

  if (!success) {
    CloseHandle(hPipeInWrite);
    CloseHandle(hPipeOutRead);
    return false;
  }

  m_hProcess = pi.hProcess;
  CloseHandle(pi.hThread);

  m_running = true;
  m_readThread = std::thread(&LspClient::ReadThreadFunc, this);
  return true;
}

void LspClient::Stop() {
  m_running = false;
  if (m_hProcess) {
    TerminateProcess(m_hProcess, 0);
    CloseHandle(m_hProcess);
    m_hProcess = nullptr;
  }
  if (hPipeInWrite) {
    CloseHandle(hPipeInWrite);
    hPipeInWrite = nullptr;
  }
  if (hPipeOutRead) {
    CloseHandle(hPipeOutRead);
    hPipeOutRead = nullptr;
  }
  if (m_readThread.joinable()) {
    m_readThread.join();
  }
}

bool LspClient::SendRequest(int id, const std::string &method,
                            const std::string &paramsJson) {
  if (!m_running || !hPipeInWrite)
    return false;

  std::ostringstream ss;
  std::string body = "{\"jsonrpc\":\"2.0\",\"id\":" + std::to_string(id) +
                     ",\"method\":\"" + method + "\",\"params\":" + paramsJson +
                     "}";
  ss << "Content-Length: " << body.length() << "\r\n\r\n" << body;

  std::string fullMsg = ss.str();
  DWORD bytesWritten = 0;
  return WriteFile(hPipeInWrite, fullMsg.c_str(),
                   static_cast<DWORD>(fullMsg.size()), &bytesWritten, nullptr);
}

bool LspClient::SendNotification(const std::string &method,
                                 const std::string &paramsJson) {
  if (!m_running || !hPipeInWrite)
    return false;

  std::ostringstream ss;
  std::string body = "{\"jsonrpc\":\"2.0\",\"method\":\"" + method +
                     "\",\"params\":" + paramsJson + "}";
  ss << "Content-Length: " << body.length() << "\r\n\r\n" << body;

  std::string fullMsg = ss.str();
  DWORD bytesWritten = 0;
  return WriteFile(hPipeInWrite, fullMsg.c_str(),
                   static_cast<DWORD>(fullMsg.size()), &bytesWritten, nullptr);
}

void LspClient::ReadThreadFunc() {
  std::string headerBuf;
  char ch;
  DWORD bytesRead = 0;

  while (m_running) {
    if (ReadFile(hPipeOutRead, &ch, 1, &bytesRead, nullptr) && bytesRead == 1) {
      headerBuf += ch;
      size_t headerEnd = headerBuf.find("\r\n\r\n");
      if (headerEnd != std::string::npos) {
        size_t clPos = headerBuf.find("Content-Length:");
        size_t contentLength = 0;
        if (clPos != std::string::npos) {
          contentLength = std::stoul(headerBuf.substr(clPos + 15));
        }

        headerBuf.clear();

        if (contentLength > 0) {
          std::string body(contentLength, '\0');
          DWORD bodyReadTotal = 0;
          while (bodyReadTotal < contentLength && m_running) {
            DWORD chunkRead = 0;
            if (ReadFile(hPipeOutRead, &body[bodyReadTotal],
                         static_cast<DWORD>(contentLength - bodyReadTotal),
                         &chunkRead, nullptr) &&
                chunkRead > 0) {
              bodyReadTotal += chunkRead;
            } else {
              break;
            }
          }
          if (m_callback && bodyReadTotal == contentLength) {
            m_callback(body);
          }
        }
      }
    } else {
      break;
    }
  }
}

} // namespace beats
