#include "pty_manager.hpp"
#include "shell_policy.hpp"
#include <iostream>
#include <vector>

namespace beats {

typedef HRESULT(WINAPI *PFN_CreatePseudoConsole)(COORD size, HANDLE hInput,
                                                 HANDLE hOutput, DWORD dwFlags,
                                                 HPCON *phPC);
typedef HRESULT(WINAPI *PFN_ResizePseudoConsole)(HPCON hPC, COORD size);
typedef void(WINAPI *PFN_ClosePseudoConsole)(HPCON hPC);

static PFN_CreatePseudoConsole pfnCreatePseudoConsole = nullptr;
static PFN_ResizePseudoConsole pfnResizePseudoConsole = nullptr;
static PFN_ClosePseudoConsole pfnClosePseudoConsole = nullptr;

static bool InitConPtyProcs() {
  if (pfnCreatePseudoConsole)
    return true;
  HMODULE hKernel32 = GetModuleHandleW(L"kernel32.dll");
  if (!hKernel32)
    return false;

  pfnCreatePseudoConsole =
      (PFN_CreatePseudoConsole)GetProcAddress(hKernel32, "CreatePseudoConsole");
  pfnResizePseudoConsole =
      (PFN_ResizePseudoConsole)GetProcAddress(hKernel32, "ResizePseudoConsole");
  pfnClosePseudoConsole =
      (PFN_ClosePseudoConsole)GetProcAddress(hKernel32, "ClosePseudoConsole");

  return (pfnCreatePseudoConsole && pfnResizePseudoConsole &&
          pfnClosePseudoConsole);
}

PtyManager::PtyManager() { InitConPtyProcs(); }

PtyManager::~PtyManager() { CloseAllTerminals(); }

/// Arranca el shell enganchado a una pseudoconsola (ConPTY).
///
/// Devuelve false si cualquiera de los pasos falla. Antes NO se comprobaba ni
/// uno: si el atributo de pseudoconsola no llegaba a aplicarse,
/// `CreateProcessW` seguia adelante y la terminal quedaba muda aparentando
/// estar viva.
bool PtyManager::SpawnConPty(TerminalInstance *inst) {
  if (!InitConPtyProcs())
    return false;

  HANDLE hPipeInRead = nullptr, hPipeInWrite = nullptr;
  HANDLE hPipeOutRead = nullptr, hPipeOutWrite = nullptr;
  if (!CreatePipe(&hPipeInRead, &hPipeInWrite, nullptr, 0) ||
      !CreatePipe(&hPipeOutRead, &hPipeOutWrite, nullptr, 0)) {
    return false;
  }

  COORD size = {80, 25};
  HPCON hPC = nullptr;
  HRESULT hr =
      pfnCreatePseudoConsole(size, hPipeInRead, hPipeOutWrite, 0, &hPC);
  CloseHandle(hPipeInRead);
  CloseHandle(hPipeOutWrite);
  if (FAILED(hr)) {
    CloseHandle(hPipeInWrite);
    CloseHandle(hPipeOutRead);
    return false;
  }

  STARTUPINFOEXW siEx = {sizeof(STARTUPINFOEXW)};
  SIZE_T attributeListSize = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeListSize);
  siEx.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
      GetProcessHeap(), 0, attributeListSize);
  bool listo = siEx.lpAttributeList != nullptr;
  if (listo && !InitializeProcThreadAttributeList(siEx.lpAttributeList, 1, 0,
                                                  &attributeListSize)) {
    std::cerr << "[PTY] InitializeProcThreadAttributeList fallo, err="
              << GetLastError() << std::endl;
    listo = false;
  }
  if (listo && !UpdateProcThreadAttribute(
                   siEx.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                   hPC, sizeof(HPCON), nullptr, nullptr)) {
    std::cerr << "[PTY] UpdateProcThreadAttribute(PSEUDOCONSOLE) fallo, err="
              << GetLastError() << std::endl;
    DeleteProcThreadAttributeList(siEx.lpAttributeList);
    listo = false;
  }
  if (!listo) {
    if (siEx.lpAttributeList)
      HeapFree(GetProcessHeap(), 0, siEx.lpAttributeList);
    pfnClosePseudoConsole(hPC);
    CloseHandle(hPipeInWrite);
    CloseHandle(hPipeOutRead);
    return false;
  }

  std::wstring cmd = L"\"" + inst->shellPath + L"\"";
  std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
  cmdBuf.push_back(0);

  // (23-09): sin esto el shell hereda los descriptores estandar de la
  // cabina. Si la cabina arranca con la salida redirigida (a un registro, a
  // una tuberia de un arnes), el saludo y el prompt del shell iban A ESE
  // REGISTRO y la pseudoconsola solo recibia sus 16 bytes: por eso "no
  // enganchaba en esta maquina". Estaba en los registros del 22-09, con el
  // "Microsoft Windows [Version...]" justo antes del aviso de respaldo.
  // Descriptores invalidos explicitos = el hijo usa los de la pseudoconsola.
  siEx.StartupInfo.dwFlags |= STARTF_USESTDHANDLES;
  siEx.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
  siEx.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
  siEx.StartupInfo.hStdError = INVALID_HANDLE_VALUE;

  PROCESS_INFORMATION pi = {};
  BOOL success = CreateProcessW(
      inst->shellPath.c_str(), cmdBuf.data(), nullptr, nullptr, FALSE,
      EXTENDED_STARTUPINFO_PRESENT, nullptr,
      inst->workingDir.empty() ? nullptr : inst->workingDir.c_str(),
      &siEx.StartupInfo, &pi);

  DeleteProcThreadAttributeList(siEx.lpAttributeList);
  HeapFree(GetProcessHeap(), 0, siEx.lpAttributeList);

  if (!success) {
    std::cerr << "[PTY] CreateProcessW (ConPTY) fallo, err=" << GetLastError()
              << std::endl;
    pfnClosePseudoConsole(hPC);
    CloseHandle(hPipeInWrite);
    CloseHandle(hPipeOutRead);
    return false;
  }
  CloseHandle(pi.hThread);

  inst->hProcess = pi.hProcess;
  inst->hPipeIn = hPipeInWrite;
  inst->hPipeOut = hPipeOutRead;
  inst->hPC = hPC;
  inst->usaTuberias = false;
  inst->running = true;
  return true;
}

/// Respaldo sin pseudoconsola: shell con stdin/stdout/stderr redirigidos.
///
/// Por que existe: en esta maquina (Windows 11 build 26200) el ConPTY se monta
/// SIN error --- CreatePseudoConsole devuelve S_OK, el atributo vale 0x20016,
/// la lista de atributos se aplica y CreateProcessW tiene exito --- y aun asi
/// el hijo no queda enganchado: la tuberia solo recibe los 16 bytes del saludo
/// de conhost y la salida del shell acaba en la consola del proceso padre.
/// Reproducido en un programa de 78 lineas aislado, compilado con `zig c++` y
/// con MSVC, con cmd.exe y con powershell.exe: identico en los cuatro casos.
/// CORREGIDO el 23-09: SI era codigo nuestro, y el programa aislado tenia el
/// mismo fallo. Sin STARTF_USESTDHANDLES el hijo hereda los descriptores
/// estandar del padre, y "acaba en la consola del proceso padre" era
/// literalmente eso. Ver SpawnConPty. El respaldo se queda por si una
/// pseudoconsola falla de verdad.
///
/// Que se pierde: fidelidad ANSI y control fino del cursor. Que se gana: que la
/// terminal ENSENE lo que pasa. Una terminal peor es infinitamente mejor que
/// una terminal ciega.
bool PtyManager::SpawnTuberias(TerminalInstance *inst) {
  SECURITY_ATTRIBUTES sa = {sizeof(sa), nullptr, TRUE};
  HANDLE inR = nullptr, inW = nullptr, outR = nullptr, outW = nullptr;
  if (!CreatePipe(&inR, &inW, &sa, 0) || !CreatePipe(&outR, &outW, &sa, 0)) {
    std::cerr << "[PTY] CreatePipe (respaldo) fallo, err=" << GetLastError()
              << std::endl;
    return false;
  }
  // Solo el extremo del hijo se hereda; los nuestros, no.
  SetHandleInformation(inW, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(outR, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW si = {sizeof(si)};
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = inR;
  si.hStdOutput = outW;
  si.hStdError = outW;

  std::wstring cmd = L"\"" + inst->shellPath + L"\"";
  std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
  cmdBuf.push_back(0);

  PROCESS_INFORMATION pi = {};
  BOOL ok = CreateProcessW(
      inst->shellPath.c_str(), cmdBuf.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW, nullptr,
      inst->workingDir.empty() ? nullptr : inst->workingDir.c_str(), &si, &pi);
  CloseHandle(inR);
  CloseHandle(outW);
  if (!ok) {
    std::cerr << "[PTY] CreateProcessW (respaldo) fallo, err=" << GetLastError()
              << std::endl;
    CloseHandle(inW);
    CloseHandle(outR);
    return false;
  }
  CloseHandle(pi.hThread);

  inst->hProcess = pi.hProcess;
  inst->hPipeIn = inW;
  inst->hPipeOut = outR;
  inst->hPC = nullptr;
  inst->usaTuberias = true;
  inst->running = true;
  return true;
}

/// Hilo que vuelca la tuberia al scrollback. Igual para los dos modos.
// Respaldo por tuberías: sin pseudoconsola, cmd.exe escribe y lee en la
// página de códigos OEM (850 en español), no en UTF-8. La cabina mostraba
// «Versi�n» y lo tecleado con tilde llegaba roto. Solo se convierte en ese
// modo: el ConPTY ya entrega UTF-8.
static std::string ConvertirPagina(const std::string &in, UINT de, UINT a) {
  if (in.empty())
    return in;
  const int wn =
      MultiByteToWideChar(de, 0, in.data(), (int)in.size(), nullptr, 0);
  if (wn <= 0)
    return in;
  std::wstring w(wn, L'\0');
  MultiByteToWideChar(de, 0, in.data(), (int)in.size(), &w[0], wn);
  const int n =
      WideCharToMultiByte(a, 0, w.data(), wn, nullptr, 0, nullptr, nullptr);
  if (n <= 0)
    return in;
  std::string out(n, '\0');
  WideCharToMultiByte(a, 0, w.data(), wn, &out[0], n, nullptr, nullptr);
  return out;
}

// En páginas OEM de doble byte (932, 936…) un trozo leído puede acabar a mitad
// de carácter; ese byte de cabecera se guarda para el trozo siguiente.
static size_t CorteSeguroOem(const std::string &s, UINT cp) {
  size_t i = 0;
  while (i < s.size()) {
    if (IsDBCSLeadByteEx(cp, static_cast<BYTE>(s[i]))) {
      if (i + 1 >= s.size())
        return i;
      i += 2;
    } else {
      i += 1;
    }
  }
  return s.size();
}

void PtyManager::LanzarLector(TerminalInstance *inst,
                              TerminalDataCallback callback) {
  inst->readThread = std::thread([inst, callback]() {
    char buf[2048];
    DWORD bytesRead = 0;
    const UINT oem = GetOEMCP();
    std::string pendiente;
    while (inst->running) {
      if (ReadFile(inst->hPipeOut, buf, sizeof(buf) - 1, &bytesRead, nullptr) &&
          bytesRead > 0) {
        std::string chunk(buf, bytesRead);
        if (inst->usaTuberias) {
          chunk = pendiente + chunk;
          const size_t corte = CorteSeguroOem(chunk, oem);
          pendiente = chunk.substr(corte);
          chunk = ConvertirPagina(chunk.substr(0, corte), oem, CP_UTF8);
        }
        {
          std::lock_guard<std::mutex> lock(inst->scrollbackMutex);
          inst->scrollback += chunk;
        }
        if (callback)
          callback(inst->id, chunk);
      } else {
        // Si la lectura muere, la terminal se queda muda para siempre y hasta
        // ahora no lo decia nadie. ERROR_BROKEN_PIPE es el cierre normal.
        const DWORD err = GetLastError();
        if (err != ERROR_BROKEN_PIPE) {
          std::cerr << "[PTY] ReadFile de la tuberia fallo, err=" << err
                    << " (terminal " << inst->id << ")" << std::endl;
        }
        break;
      }
    }
  });
}

int PtyManager::CreateTerminal(const std::wstring &shellPath,
                               const std::wstring &workingDir,
                               TerminalDataCallback callback) {
  std::wstring executable;
  if (!security::ResolveShell(shellPath, executable))
    return -1;
  auto inst = std::make_unique<TerminalInstance>();
  inst->id = m_nextId;
  inst->shellPath = executable;
  inst->workingDir = workingDir;

  if (SpawnConPty(inst.get())) {
    LanzarLector(inst.get(), callback);

    // COMPROBAR QUE DE VERDAD HABLA, no solo que arranco.
    //
    // conhost saluda con 16 bytes aunque el shell no quede enganchado. Ese
    // saludo era justo lo que hacia pasar por buena una terminal muerta: el
    // panel decia "Conectado" y no ensenaba nada. Se espera a que llegue algo
    // MAS que el saludo; si en 2 segundos no llega, se desmonta y se cae al
    // respaldo por tuberias.
    const size_t SALUDO_MAX = 64;
    bool habla = false;
    for (int i = 0; i < 20 && !habla; ++i) {
      Sleep(100);
      {
        std::lock_guard<std::mutex> lock(inst->scrollbackMutex);
        if (inst->scrollback.size() > SALUDO_MAX)
          habla = true;
      }
    }

    if (habla) {
      const int id = m_nextId++;
      m_terminals[id] = std::move(inst);
      return id;
    }

    {
      std::lock_guard<std::mutex> lock(inst->scrollbackMutex);
      std::cerr << "[PTY] La pseudoconsola no entrega salida ("
                << inst->scrollback.size()
                << " bytes en 2 s). Cayendo al respaldo por tuberias."
                << std::endl;
    }
    inst->running = false;
    if (inst->hProcess)
      TerminateProcess(inst->hProcess, 0);
    if (inst->hPC)
      pfnClosePseudoConsole(inst->hPC);
    if (inst->readThread.joinable())
      inst->readThread.join();
    if (inst->hPipeIn)
      CloseHandle(inst->hPipeIn);
    if (inst->hPipeOut)
      CloseHandle(inst->hPipeOut);
    if (inst->hProcess)
      CloseHandle(inst->hProcess);
    inst->hProcess = nullptr;
    inst->hPipeIn = nullptr;
    inst->hPipeOut = nullptr;
    inst->hPC = nullptr;
    inst->scrollback.clear();
  }

  if (!SpawnTuberias(inst.get()))
    return 0;
  LanzarLector(inst.get(), callback);

  const int id = m_nextId++;
  m_terminals[id] = std::move(inst);
  return id;
}

bool PtyManager::WriteTerminal(int id, const std::string &data) {
  auto it = m_terminals.find(id);
  if (it == m_terminals.end() || !it->second->running)
    return false;

  DWORD bytesWritten = 0;
  // Por tuberías, cmd.exe lee en OEM: lo tecleado (UTF-8) se convierte.
  const std::string enviar = it->second->usaTuberias
                                 ? ConvertirPagina(data, CP_UTF8, GetOEMCP())
                                 : data;
  BOOL res =
      WriteFile(it->second->hPipeIn, enviar.c_str(),
                static_cast<DWORD>(enviar.size()), &bytesWritten, nullptr);
  FlushFileBuffers(it->second->hPipeIn);
  return res != FALSE;
}

bool PtyManager::IsPseudoConsole(int id) const {
  auto it = m_terminals.find(id);
  return it != m_terminals.end() && it->second->hPC != nullptr;
}

bool PtyManager::ResizeTerminal(int id, short cols, short rows) {
  auto it = m_terminals.find(id);
  // Sin pseudoconsola no hay que redimensionar: el respaldo por tuberias
  // no tiene concepto de tamano de pantalla.
  if (it == m_terminals.end() || !pfnResizePseudoConsole ||
      it->second->hPC == nullptr)
    return false;

  COORD size = {cols, rows};
  if (FAILED(pfnResizePseudoConsole(it->second->hPC, size)))
    return false;
  it->second->cols = cols;
  it->second->rows = rows;
  return true;
}

void PtyManager::CloseTerminal(int id) {
  auto it = m_terminals.find(id);
  if (it != m_terminals.end()) {
    it->second->running = false;
    if (it->second->hProcess) {
      TerminateProcess(it->second->hProcess, 0);
      CloseHandle(it->second->hProcess);
      it->second->hProcess = nullptr;
    }
    if (it->second->hPC && pfnClosePseudoConsole) {
      pfnClosePseudoConsole(it->second->hPC);
      it->second->hPC = nullptr;
    }
    if (it->second->hPipeIn) {
      CloseHandle(it->second->hPipeIn);
      it->second->hPipeIn = nullptr;
    }
    if (it->second->hPipeOut) {
      CloseHandle(it->second->hPipeOut);
      it->second->hPipeOut = nullptr;
    }
    if (it->second->hPipeInRead) {
      CloseHandle(it->second->hPipeInRead);
      it->second->hPipeInRead = nullptr;
    }
    if (it->second->hPipeOutWrite) {
      CloseHandle(it->second->hPipeOutWrite);
      it->second->hPipeOutWrite = nullptr;
    }

    if (it->second->readThread.joinable()) {
      it->second->readThread.join();
    }
    m_terminals.erase(it);
  }
}

void PtyManager::CloseAllTerminals() {
  std::vector<int> ids;
  for (const auto &pair : m_terminals) {
    ids.push_back(pair.first);
  }
  for (int id : ids) {
    CloseTerminal(id);
  }
}

std::string PtyManager::GetScrollback(int id) const {
  auto it = m_terminals.find(id);
  if (it != m_terminals.end()) {
    std::lock_guard<std::mutex> lock(it->second->scrollbackMutex);
    return it->second->scrollback;
  }
  return "";
}

std::vector<TerminalInfo> PtyManager::ListTerminals() const {
  std::vector<TerminalInfo> terminals;
  for (const auto &entry : m_terminals) {
    const auto &inst = *entry.second;
    terminals.push_back(
        {inst.id, inst.shellPath, inst.cols, inst.rows,
         inst.running && inst.hProcess &&
             WaitForSingleObject(inst.hProcess, 0) == WAIT_TIMEOUT,
         inst.hPC != nullptr});
  }
  return terminals;
}

} // namespace beats
