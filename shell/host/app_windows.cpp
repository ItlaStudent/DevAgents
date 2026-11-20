#include "app_windows.hpp"
#include "preview_policy.hpp"
#include <fstream>
#include <sstream>

// E5.21 — multiventana del host.
//
// Reglas del registro:
//  - Todo muta en el hilo de UI (crear, destruir, difundir). El bucle de
//    mensajes es UNO para todas las ventanas (GetMessage con hwnd=nullptr),
//    asi que un HWND de secundaria recibe sus mensajes por la misma bomba.
//  - Los hilos del motor adquieren su puente con BridgeForHwnd bajo mutex.
//    La respuesta lleva HWND + puente; UI descarta ventanas cerradas o
//    reemplazadas.
//  - Persistencia aditiva en windows.ini; una linea por ventana secundaria.

namespace beats {

static std::string Trim(const std::string &s) {
  size_t a = s.find_first_not_of(" \t\r\n");
  if (a == std::string::npos)
    return "";
  size_t b = s.find_last_not_of(" \t\r\n");
  return s.substr(a, b - a + 1);
}

// Entero del nivel superior: el payload de window.open trae order_id como
// numero JSON (el string de GetStringProp daria "").
static long GetIntProp(const std::string &json, const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos)
    return 0;
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos)
    return 0;
  ++pos;
  while (pos < json.size() &&
         (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '"'))
    ++pos;
  return strtol(json.c_str() + pos, nullptr, 10);
}

static bool VistaValida(const std::string &v) {
  // Las vistas que la WebUI sabe montar en modo secundario (E5.22).
  return v == "editor" || v == "terminal" || v == "conversacion" ||
         v == "monitor" || v == "preview" || v == "browser";
}

OpenWindowRequest ParseOpenWindow(const std::string &payloadJson) {
  OpenWindowRequest r;
  r.vista = GetStringProp(payloadJson, "vista");
  if (r.vista.empty())
    r.vista = GetStringProp(payloadJson, "view"); // alias tolerado
  r.path = GetStringProp(payloadJson, "path");
  r.orderId = GetIntProp(payloadJson, "order_id");
  if (r.orderId == 0)
    r.orderId = GetIntProp(payloadJson, "orderId");

  if (!VistaValida(r.vista)) {
    r.error = "vista no valida: " + (r.vista.empty() ? "(vacia)" : r.vista);
    return r;
  }
  // Los caracteres que romperian el ?query de la URL se rechazan; la ruta
  // (con backslashes y espacios) se %codifica al componer la navegacion.
  // '|' ademas romperia el formato de windows.ini — se excluye tambien.
  if (r.path.find_first_of("\"'<>#%|") != std::string::npos) {
    r.error = "path con caracteres no admitidos";
    return r;
  }
  // Ninguna ruta de Windows puede llevar controles (<0x20): un \b o \t en el
  // payload pasaba la validacion y navegaba a una URL con %08 en medio.
  // Medido en vivo 26-09: path="C:\...\build.zig" llegaba como "%08uild.zig"
  // cuando el llamador escapaba mal — se rechaza aqui, en la frontera.
  for (char c : r.path) {
    if (static_cast<unsigned char>(c) < 0x20) {
      r.error = "path con caracteres de control";
      return r;
    }
  }
  if (r.vista == "editor" && r.path.empty()) {
    r.error = "vista editor requiere path";
    return r;
  }
  // CAB031-r2: el popout de Conversación también abre sin una orden abierta
  // (chat vacío); exigir order_id aquí dejaba el botón real sin ventana.
  // Un id negativo sigue siendo un payload inválido.
  if (r.vista == "conversacion" && r.orderId < 0) {
    r.error = "vista conversacion con order_id invalido";
    return r;
  }
  if (r.vista == "preview") {
    if (r.path.empty())
      r.path = "index.html";
    preview::Value object;
    if (!preview::Parser(payloadJson).Parse(object) ||
        object.type != preview::Value::Object || object.object.size() > 3 ||
        !preview::Text(object, "vista", 16) ||
        object.object.at("vista").string != "preview" ||
        (object.object.find("path") != object.object.end() &&
         !preview::Text(object, "path", 2048, true)) ||
        !preview::Number(object, "order_id", 1, 2147483647) ||
        std::floor(object.object.at("order_id").number) !=
            object.object.at("order_id").number ||
        !preview::HtmlPath(r.path)) {
      r.error = "vista preview requiere order_id entero y path HTML relativo";
      return r;
    }
    for (const auto &entry : object.object) {
      if (entry.first != "vista" && entry.first != "path" &&
          entry.first != "order_id") {
        r.error = "campo preview desconocido";
        return r;
      }
    }
    r.orderId = static_cast<long>(object.object.at("order_id").number);
  }
  r.valid = true;
  return r;
}

AppWindow *WindowSupervisor::Create(HINSTANCE hInstance,
                                    const std::wstring &title, int w, int h,
                                    const OpenWindowRequest *params,
                                    const std::wstring &configDir) {
  auto aw = std::make_unique<AppWindow>();
  aw->id = m_nextId++;
  m_configDir = configDir;
  aw->primary = params == nullptr;
  aw->vista = params ? params->vista : "";
  aw->navPath = params ? params->path : "";
  aw->navOrder = params ? params->orderId : 0;
  if (aw->vista != "preview" && aw->vista != "browser")
    aw->bridge = std::make_shared<Bridge>();

  if (!aw->window.Create(hInstance, title.c_str(), w, h))
    return nullptr;
  aw->hwnd = aw->window.GetHandle();
  // La query se compone tras asignar el id (lleva ?ventana=<id>) y se fija
  // antes de Initialize (m_createWebView): la primera navegacion ya la lleva.
  if (params && params->valid) {
    std::wstring nav = L"?ventana=" + std::to_wstring(aw->id) + L"&vista=" +
                       UrlEncodeComponent(aw->vista);
    if (!aw->navPath.empty())
      nav += L"&path=" + UrlEncodeComponent(aw->navPath);
    if (aw->navOrder > 0)
      nav += L"&order=" + std::to_wstring(aw->navOrder);
    aw->webview.SetNavQuery(nav);
  }

  // En la secundaria la geometria guardada gana al tamano por defecto.
  if (!aw->primary) {
    std::wstring ini = configDir + L"\\windows.ini";
    WindowGeometry geo;
    std::wifstream ifs;
    ifs.open(ini.c_str());
    std::string line;
    std::wstring wline;
    while (ifs.good()) {
      std::getline(ifs, wline);
      if (wline.empty() || wline[0] == L'#')
        continue;
      // formato: id|x|y|w|h|max|vista
      std::wstringstream ss(wline);
      std::wstring tok;
      std::vector<std::wstring> parts;
      while (std::getline(ss, tok, L'|'))
        parts.push_back(tok);
      if (parts.size() >= 7) {
        int vid = _wtoi(parts[0].c_str());
        std::string v(parts[6].begin(), parts[6].end());
        if (v == aw->vista || vid == aw->id) {
          geo.x = _wtoi(parts[1].c_str());
          geo.y = _wtoi(parts[2].c_str());
          geo.width = _wtoi(parts[3].c_str());
          geo.height = _wtoi(parts[4].c_str());
          geo.maximized = parts[5] == L"1";
          RECT saved = {geo.x, geo.y, geo.x + geo.width, geo.y + geo.height};
          if (MonitorFromRect(&saved, MONITOR_DEFAULTTONULL)) {
            SetWindowPos(aw->hwnd, nullptr, geo.x, geo.y, geo.width, geo.height,
                         SWP_NOZORDER | SWP_NOACTIVATE);
            if (geo.maximized)
              ShowWindow(aw->hwnd, SW_SHOWMAXIMIZED);
          }
          break;
        }
      }
    }
  }

  AppWindow *ptr = aw.get();
  m_windows.push_back(std::move(aw));
  {
    std::lock_guard<std::mutex> lock(m_registryMutex);
    m_byHwnd[ptr->hwnd] = ptr;
  }
  // The cabina WebUI of this window paints the bar and learns the panel state
  // through its own WebView; a missing WebUI makes the sink report failure.
  ptr->browser.SetEventSink([ptr](const std::wstring &json) {
    return ptr->webview.PostMessageJson(json);
  });
  if (m_createWebView && !m_createWebView(*ptr)) {
    // main has installed the destroy callback before initialization. Destroy
    // removes the registry entry; never return a dangling or uninitialized
    // view.
    DestroyWindow(ptr->hwnd);
    return nullptr;
  }
  return ptr;
}

bool WindowSupervisor::OnWindowDestroyed(AppWindow &aw) {
  {
    std::lock_guard<std::mutex> lock(m_registryMutex);
    m_byHwnd.erase(aw.hwnd);
  }
  if (m_destroyed)
    m_destroyed(aw);
  for (size_t i = 0; i < m_windows.size(); ++i) {
    if (m_windows[i].get() == &aw) {
      m_destroyedWindows.push_back(std::move(m_windows[i]));
      m_windows.erase(m_windows.begin() + i);
      break;
    }
  }
  // Solo persisten las secundarias que siguen abiertas. La geometria de
  // esas ventanas sigue siendo legible, incluso al cerrar la principal.
  if (!m_configDir.empty() && !SaveLayout(m_configDir))
    OutputDebugStringW(L"DevAgents: no se pudo guardar windows.ini\n");
  return m_windows.empty();
}

AppWindow *WindowSupervisor::ByHwnd(HWND hwnd) const {
  std::lock_guard<std::mutex> lock(m_registryMutex);
  auto it = m_byHwnd.find(hwnd);
  return it == m_byHwnd.end() ? nullptr : it->second;
}

std::shared_ptr<Bridge> WindowSupervisor::BridgeForHwnd(HWND hwnd) const {
  std::lock_guard<std::mutex> lock(m_registryMutex);
  auto it = m_byHwnd.find(hwnd);
  return it == m_byHwnd.end() ? nullptr : it->second->bridge;
}

AppWindow *
WindowSupervisor::ByHwnd(HWND hwnd,
                         const std::shared_ptr<Bridge> &expected) const {
  std::lock_guard<std::mutex> lock(m_registryMutex);
  auto it = m_byHwnd.find(hwnd);
  return expected && it != m_byHwnd.end() && it->second->bridge == expected
             ? it->second
             : nullptr;
}

void WindowSupervisor::CollectDestroyedWindows() { m_destroyedWindows.clear(); }

void WindowSupervisor::DispatchWindowMessage(const MSG &message) {
  TranslateMessage(&message);
  DispatchMessageW(&message);
  CollectDestroyedWindows();
}

AppWindow *WindowSupervisor::Primary() {
  for (const auto &aw : m_windows)
    if (aw->primary)
      return aw.get();
  return nullptr;
}

void WindowSupervisor::CloseSecondaries() {
  // Copia de HWNDs: cada DestroyWindow dispara WM_DESTROY que muta m_windows.
  std::vector<HWND> secundarias;
  for (const auto &aw : m_windows)
    if (!aw->primary)
      secundarias.push_back(aw->hwnd);
  for (HWND h : secundarias) {
    if (IsWindow(h))
      DestroyWindow(h);
  }
}

void WindowSupervisor::Broadcast(const std::wstring &jsonMessage) {
  for (auto &aw : m_windows) {
    if (aw->vista != "preview")
      aw->webview.PostMessageJson(jsonMessage);
  }
}

bool WindowSupervisor::SaveLayout(const std::wstring &configDir) const {
  CreateDirectoryW(configDir.c_str(), nullptr);
  std::wofstream ofs((configDir + L"\\windows.ini").c_str(), std::ios::trunc);
  if (!ofs.is_open())
    return false;
  ofs << L"# id|x|y|w|h|max|vista\n";
  for (const auto &aw : m_windows) {
    if (aw->primary)
      continue;
    WINDOWPLACEMENT wp = {sizeof(WINDOWPLACEMENT)};
    if (!GetWindowPlacement(aw->hwnd, &wp))
      continue;
    const auto &r = wp.rcNormalPosition;
    std::wstring vista(aw->vista.begin(), aw->vista.end());
    std::wstring navPath(aw->navPath.begin(), aw->navPath.end());
    // Columnas 8-9: path/order de la vista (para restaurar la secundaria tal
    // cual). '|' no puede aparecer: ParseOpenWindow lo rechaza en path.
    ofs << aw->id << L"|" << r.left << L"|" << r.top << L"|"
        << (r.right - r.left) << L"|" << (r.bottom - r.top) << L"|"
        << (wp.showCmd == SW_SHOWMAXIMIZED ? 1 : 0) << L"|" << vista << L"|"
        << navPath << L"|" << aw->navOrder << L"\n";
  }
  return true;
}

std::vector<OpenWindowRequest>
WindowSupervisor::LoadSecondaryViews(const std::wstring &configDir) const {
  std::vector<OpenWindowRequest> out;
  std::wifstream ifs((configDir + L"\\windows.ini").c_str());
  std::wstring wline;
  while (ifs.good()) {
    std::getline(ifs, wline);
    if (wline.empty() || wline[0] == L'#')
      continue;
    std::wstringstream ss(wline);
    std::wstring tok;
    std::vector<std::wstring> parts;
    while (std::getline(ss, tok, L'|'))
      parts.push_back(tok);
    if (parts.size() >= 7) {
      OpenWindowRequest r;
      // Columnas 2-6: x|y|w|h|max — la geometria que SaveLayout dejo escrita.
      r.x = _wtol(parts[1].c_str());
      r.y = _wtol(parts[2].c_str());
      r.w = _wtol(parts[3].c_str());
      r.h = _wtol(parts[4].c_str());
      r.maximized = parts[5] == L"1";
      std::string v(parts[6].begin(), parts[6].end());
      r.vista = v;
      // Columnas 8-9 (opcionales): path y order de la vista.
      if (parts.size() >= 8)
        r.path.assign(parts[7].begin(), parts[7].end());
      if (parts.size() >= 9)
        r.orderId = _wtol(parts[8].c_str());
      r.valid =
          VistaValida(v) && (v != "editor" || !r.path.empty()) &&
          (v != "conversacion" || r.orderId > 0) &&
          (v != "preview" || (r.orderId > 0 && preview::HtmlPath(r.path)));
      if (r.valid)
        out.push_back(r);
    }
  }
  return out;
}

std::wstring WindowSupervisor::UrlEncodeComponent(const std::string &utf8) {
  static const char *hex = "0123456789ABCDEF";
  std::wstring out;
  out.reserve(utf8.size());
  for (unsigned char c : utf8) {
    const bool safe = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '-' || c == '_' ||
                      c == '.' || c == '~' || c == '/' || c == '\\' || c == ':';
    if (safe) {
      out += static_cast<wchar_t>(c);
    } else {
      out += L'%';
      out += static_cast<wchar_t>(hex[c >> 4]);
      out += static_cast<wchar_t>(hex[c & 15]);
    }
  }
  return out;
}

} // namespace beats
