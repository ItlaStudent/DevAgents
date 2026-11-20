#ifndef BEATS_REMOTE_CONTROLLER_HPP
#define BEATS_REMOTE_CONTROLLER_HPP
#include "bridge.hpp"
#include "core_client.hpp"
#include "preview_policy.hpp"
#include <atomic>
#include <functional>
#include <mutex>
#include <objbase.h>
#include <sddl.h>
#include <thread>
#include <vector>
namespace beats {
// The child owns HTTP. This broker invokes the same C-ABI on the running
// core handle; it never initializes a second core against the owner's DB.
class RemoteController {
  CoreClient &m_core;
  std::function<CoreResult(const std::string &, HANDLE)> m_dispatch;
  std::mutex m_mutex;
  HANDLE m_process = nullptr, m_job = nullptr, m_stop = nullptr;
  HANDLE m_pipe = INVALID_HANDLE_VALUE;
  std::thread m_broker;
  std::atomic<DWORD> m_pid{0};
  std::string m_url;
  std::wstring m_hashPath;
  static bool Io(HANDLE pipe, HANDLE stop, void *buffer, DWORD size,
                 bool writing, DWORD &count) {
    OVERLAPPED ov = {};
    ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!ov.hEvent)
      return false;
    BOOL ok = writing ? WriteFile(pipe, buffer, size, &count, &ov)
                      : ReadFile(pipe, buffer, size, &count, &ov);
    if (!ok && GetLastError() == ERROR_IO_PENDING) {
      HANDLE events[] = {ov.hEvent, stop};
      if (WaitForMultipleObjects(2, events, FALSE, 5000) == WAIT_OBJECT_0)
        ok = GetOverlappedResult(pipe, &ov, &count, FALSE);
      else {
        CancelIoEx(pipe, &ov);
        GetOverlappedResult(pipe, &ov, &count, TRUE);
        ok = FALSE;
      }
    }
    CloseHandle(ov.hEvent);
    return ok == TRUE;
  }
  void Broker() {
    while (WaitForSingleObject(m_stop, 0) == WAIT_TIMEOUT) {
      OVERLAPPED ov = {};
      ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      if (!ov.hEvent)
        return;
      bool connected = ConnectNamedPipe(m_pipe, &ov) != FALSE;
      const DWORD error = connected ? ERROR_SUCCESS : GetLastError();
      if (error == ERROR_PIPE_CONNECTED)
        connected = true;
      else if (error == ERROR_IO_PENDING) {
        HANDLE events[] = {ov.hEvent, m_stop};
        if (WaitForMultipleObjects(2, events, FALSE, INFINITE) ==
            WAIT_OBJECT_0) {
          DWORD count = 0;
          connected = GetOverlappedResult(m_pipe, &ov, &count, FALSE) != FALSE;
        } else {
          CancelIoEx(m_pipe, &ov);
          DWORD count = 0;
          GetOverlappedResult(m_pipe, &ov, &count, TRUE);
        }
      }
      CloseHandle(ov.hEvent);
      if (!connected) {
        if (WaitForSingleObject(m_stop, 0) != WAIT_TIMEOUT)
          return;
        OutputDebugStringW(L"DevAgents: remote broker connect failed\n");
        return;
      }
      ULONG client = 0;
      if (GetNamedPipeClientProcessId(m_pipe, &client) &&
          client == m_pid.load() && client != 0) {
        std::string request;
        char block[4096];
        DWORD count = 0;
        bool valid = true;
        while (request.find('\n') == std::string::npos) {
          if (!Io(m_pipe, m_stop, block, sizeof(block), false, count) ||
              !count || request.size() + count > 65536) {
            valid = false;
            break;
          }
          request.append(block, count);
        }
        if (valid && request.find('\n') == request.size() - 1) {
          request.pop_back();
          CoreResult result = m_dispatch(request, m_stop);
          std::string response =
              result.ok() ? result.json
                          : "{\"status\":503,\"body\":\"{\\\"error\\\":"
                            "\\\"motor no disponible\\\"}\"}";
          response += '\n';
          if (response.size() > 4 * 1024 * 1024)
            response = "{\"status\":500,\"body\":\"{\\\"error\\\":"
                       "\\\"respuesta demasiado grande\\\"}\"}\n";
          size_t pos = 0;
          while (pos < response.size()) {
            if (!Io(m_pipe, m_stop, &response[pos],
                    static_cast<DWORD>(response.size() - pos), true, count) ||
                !count) {
              OutputDebugStringW(L"DevAgents: remote broker response failed\n");
              break;
            }
            pos += count;
          }
          char ack = 0;
          if (pos == response.size() &&
              (!Io(m_pipe, m_stop, &ack, 1, false, count) || count != 1 ||
               ack != '\n'))
            OutputDebugStringW(
                L"DevAgents: remote broker acknowledgment failed\n");
        }
      }
      DisconnectNamedPipe(m_pipe);
    }
  }
  void StopLocked() {
    if (m_stop)
      SetEvent(m_stop);
    if (m_pipe != INVALID_HANDLE_VALUE)
      CancelIoEx(m_pipe, nullptr);
    if (m_broker.joinable())
      m_broker.join();
    if (m_job) {
      CloseHandle(m_job);
      m_job = nullptr;
    }
    if (m_process) {
      if (WaitForSingleObject(m_process, 2000) == WAIT_TIMEOUT) {
        if (!TerminateProcess(m_process, 0))
          OutputDebugStringW(L"DevAgents: remote child stop failed\n");
        WaitForSingleObject(m_process, 2000);
      }
      CloseHandle(m_process);
      m_process = nullptr;
    }
    if (m_pipe != INVALID_HANDLE_VALUE) {
      CloseHandle(m_pipe);
      m_pipe = INVALID_HANDLE_VALUE;
    }
    if (m_stop) {
      CloseHandle(m_stop);
      m_stop = nullptr;
    }
    m_pid = 0;
    m_url.clear();
    if (!m_hashPath.empty()) {
      if (!DeleteFileW(m_hashPath.c_str()) &&
          GetLastError() != ERROR_FILE_NOT_FOUND)
        OutputDebugStringW(L"DevAgents: remote hash cleanup failed\n");
      m_hashPath.clear();
    }
  }

public:
  explicit RemoteController(
      CoreClient &core,
      std::function<CoreResult(const std::string &, HANDLE)> dispatch = nullptr)
      : m_core(core), m_dispatch(std::move(dispatch)) {
    m_core.SetRemoteStopHook([this] { Stop(); });
  }
  ~RemoteController() {
    m_core.SetRemoteStopHook(nullptr);
    Stop();
  }
  static bool Options(const std::string &raw, unsigned &port,
                      std::string &origin) {
    preview::Value v;
    if (!preview::Parser(raw).Parse(v) || v.type != preview::Value::Object)
      return false;
    port = 0;
    origin.clear();
    for (const auto &field : v.object) {
      if (field.first == "port") {
        if (field.second.type != preview::Value::Number ||
            field.second.number < 0 || field.second.number > 65535 ||
            std::floor(field.second.number) != field.second.number)
          return false;
        port = static_cast<unsigned>(field.second.number);
      } else if (field.first == "origin") {
        if (field.second.type != preview::Value::String)
          return false;
        origin = field.second.string;
        if (origin.size() > 2048 || origin.find('\0') != std::string::npos ||
            origin.find_first_of("\"\\\r\n \t") != std::string::npos ||
            (!origin.empty() && origin.rfind("https://", 0) != 0 &&
             origin.rfind("http://", 0) != 0))
          return false;
      } else
        return false;
    }
    return true;
  }
  static bool Startup(const std::string &raw, std::string &url) {
    preview::Value info;
    if (!preview::Parser(raw).Parse(info) ||
        !preview::Keys(info, {"url", "token"}) ||
        !preview::Text(info, "url", 128) || !preview::Text(info, "token", 64))
      return false;
    const std::string &token = info.object.at("token").string;
    if (token.size() != 64 ||
        !std::all_of(token.begin(), token.end(), [](unsigned char c) {
          return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        }))
      return false;
    const std::string &candidate = info.object.at("url").string;
    const std::string prefix = "http://127.0.0.1:";
    if (candidate.rfind(prefix, 0) != 0)
      return false;
    const std::string digits = candidate.substr(prefix.size());
    if (digits.empty() || digits.size() > 5 ||
        !std::all_of(digits.begin(), digits.end(),
                     [](unsigned char c) { return c >= '0' && c <= '9'; }))
      return false;
    const unsigned port =
        static_cast<unsigned>(std::strtoul(digits.c_str(), nullptr, 10));
    if (port == 0 || port > 65535)
      return false;
    url = candidate;
    return true;
  }
  CoreResult Start(const std::string &raw) {
    std::lock_guard<std::mutex> lock(m_mutex);
    unsigned port = 0;
    std::string origin;
    if (!Options(raw, port, origin))
      return {-1, "", "Puerto u origen inválido"};
    if (!m_core.EngineReady() || !m_core.Api().remote_request_json)
      return {-1, "", "El motor no admite acceso remoto"};
    if (!m_dispatch)
      return {-1, "", "El carril remoto del motor no está conectado"};
    if (m_process && WaitForSingleObject(m_process, 0) == WAIT_TIMEOUT)
      return {
          -1, "",
          "El acceso remoto ya está encendido; apágalo para emitir otro token"};
    StopLocked();
    wchar_t exe[MAX_PATH];
    const DWORD length = GetModuleFileNameW(nullptr, exe, MAX_PATH);
    if (!length || length >= MAX_PATH)
      return {-1, "", "Ruta del motor no disponible"};
    std::wstring path(exe, length);
    path = path.substr(0, path.find_last_of(L'\\') + 1) + L"devagents-core.exe";
    GUID guid;
    if (FAILED(CoCreateGuid(&guid)))
      return {-1, "", "No se pudo crear identificador privado"};
    wchar_t guidText[40];
    if (!StringFromGUID2(guid, guidText, 40))
      return {-1, "", "Identificador privado inválido"};
    wchar_t temp[MAX_PATH];
    const DWORD tempLength = GetTempPathW(MAX_PATH, temp);
    if (!tempLength || tempLength >= MAX_PATH)
      return {-1, "", "Directorio temporal no disponible"};
    m_hashPath = std::wstring(temp, tempLength) + L"beats-remote-" + guidText +
                 L".sha256";
    const std::wstring name = L"\\\\.\\pipe\\beats-remote-" +
                              std::to_wstring(GetCurrentProcessId()) + guidText;
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;GA;;;OW)", SDDL_REVISION_1, &sd, nullptr))
      return {-1, "", "No se pudo proteger la tubería privada"};
    SECURITY_ATTRIBUTES security = {sizeof(security), sd, FALSE};
    m_pipe = CreateNamedPipeW(name.c_str(),
                              PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
                                  FILE_FLAG_FIRST_PIPE_INSTANCE,
                              PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
                                  PIPE_REJECT_REMOTE_CLIENTS,
                              1, 65536, 65536, 5000, &security);
    LocalFree(sd);
    m_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    m_job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION job = {};
    job.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (m_pipe == INVALID_HANDLE_VALUE || !m_stop || !m_job ||
        !SetInformationJobObject(m_job, JobObjectExtendedLimitInformation, &job,
                                 sizeof(job))) {
      StopLocked();
      return {-1, "", "No se pudo preparar el proceso remoto"};
    }
    SECURITY_ATTRIBUTES inherit = {sizeof(inherit), nullptr, TRUE};
    HANDLE reader = nullptr, writer = nullptr;
    if (!CreatePipe(&reader, &writer, &inherit, 0)) {
      StopLocked();
      return {-1, "", "No se pudo crear canal de inicio"};
    }
    if (!SetHandleInformation(reader, HANDLE_FLAG_INHERIT, 0)) {
      CloseHandle(reader);
      CloseHandle(writer);
      StopLocked();
      return {-1, "", "No se pudo aislar canal de inicio"};
    }
    HANDLE nullHandle =
        CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
    std::vector<unsigned char> attrs(bytes);
    STARTUPINFOEXW startup = {};
    startup.StartupInfo.cb = sizeof(startup);
    startup.lpAttributeList =
        reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attrs.data());
    HANDLE allowed[] = {writer, nullHandle};
    const bool initialized =
        InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0,
                                          &bytes) != FALSE;
    if (!initialized || nullHandle == INVALID_HANDLE_VALUE ||
        !UpdateProcThreadAttribute(startup.lpAttributeList, 0,
                                   PROC_THREAD_ATTRIBUTE_HANDLE_LIST, allowed,
                                   sizeof(allowed), nullptr, nullptr)) {
      if (initialized)
        DeleteProcThreadAttributeList(startup.lpAttributeList);
      if (nullHandle != INVALID_HANDLE_VALUE)
        CloseHandle(nullHandle);
      CloseHandle(reader);
      CloseHandle(writer);
      StopLocked();
      return {-1, "", "No se pudo restringir la herencia del proceso"};
    }
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdOutput = writer;
    startup.StartupInfo.hStdError = nullHandle;
    startup.StartupInfo.hStdInput = nullHandle;
    std::wstring command = L"\"" + path + L"\" remote serve --port " +
                           std::to_wstring(port) + L" --parent-pipe \"" + name +
                           L"\" --hash-file \"" + m_hashPath + L"\"";
    if (!origin.empty())
      command += L" --origin \"" + preview::Wide(origin) + L"\"";
    std::vector<wchar_t> cmd(command.begin(), command.end());
    cmd.push_back(0);
    PROCESS_INFORMATION process = {};
    const bool created =
        CreateProcessW(
            path.c_str(), cmd.data(), nullptr, nullptr, TRUE,
            CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
            nullptr, nullptr, &startup.StartupInfo, &process) != FALSE;
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    CloseHandle(writer);
    CloseHandle(nullHandle);
    if (!created) {
      CloseHandle(reader);
      StopLocked();
      return {-1, "", "No se pudo iniciar devagents-core remote serve"};
    }
    m_process = process.hProcess;
    m_pid = process.dwProcessId;
    if (!AssignProcessToJobObject(m_job, m_process) ||
        ResumeThread(process.hThread) == static_cast<DWORD>(-1)) {
      CloseHandle(process.hThread);
      CloseHandle(reader);
      StopLocked();
      return {-1, "", "No se pudo confinar el proceso remoto"};
    }
    CloseHandle(process.hThread);
    try {
      m_broker = std::thread([this] { Broker(); });
    } catch (const std::exception &) {
      CloseHandle(reader);
      StopLocked();
      return {-1, "", "No se pudo iniciar el puente remoto"};
    }
    std::string line;
    const ULONGLONG deadline = GetTickCount64() + 10000;
    while (GetTickCount64() < deadline &&
           line.find('\n') == std::string::npos && line.size() < 4096) {
      DWORD available = 0;
      if (!PeekNamedPipe(reader, nullptr, 0, nullptr, &available, nullptr))
        break;
      if (available) {
        char block[512];
        DWORD count = 0;
        if (!ReadFile(reader, block, sizeof(block), &count, nullptr) || !count)
          break;
        line.append(block, count);
      } else {
        if (WaitForSingleObject(m_process, 20) != WAIT_TIMEOUT)
          break;
      }
    }
    CloseHandle(reader);
    if (!Startup(line, m_url)) {
      StopLocked();
      return {-1, "", "El motor remoto no confirmó inicio seguro"};
    }
    return {0, line, ""}; // token is returned once, never cached or logged.
  }
  CoreResult Status() {
    std::lock_guard<std::mutex> lock(m_mutex);
    const bool running =
        m_process && WaitForSingleObject(m_process, 0) == WAIT_TIMEOUT;
    if (!running)
      StopLocked();
    return {0,
            "{\"running\":" + std::string(running ? "true" : "false") +
                ",\"url\":\"" + JsonEscapePublic(m_url) +
                "\",\"pid\":" + std::to_string(m_pid.load()) + "}",
            ""};
  }
  void Stop() {
    std::lock_guard<std::mutex> lock(m_mutex);
    StopLocked();
  }
};
} // namespace beats
#endif
