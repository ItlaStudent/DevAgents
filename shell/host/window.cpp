#include "window.hpp"
#include "consent_prompt.hpp"
#include <cwchar>
#include <dwmapi.h>
#include <fstream>
#include <shobjidl.h>
#include <sstream>
#include <windowsx.h>

namespace beats {

Window::Window() {}

Window::~Window() {
  // m_inDestroy: este Window ya esta dentro de su WM_DESTROY — el HWND murio
  // y un segundo DestroyWindow reentraria el mensaje. Pasa cuando el callback
  // destruye el AppWindow que nos contiene (E5.21).
  if (m_hwnd && !m_inDestroy) {
    DestroyWindow(m_hwnd);
  }
  m_hwnd = nullptr;
}

LRESULT CALLBACK Window::WndProc(HWND hwnd, UINT uMsg, WPARAM wParam,
                                 LPARAM lParam) {
  Window *self = nullptr;
  if (uMsg == WM_NCCREATE) {
    CREATESTRUCT *cs = reinterpret_cast<CREATESTRUCT *>(lParam);
    self = reinterpret_cast<Window *>(cs->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    self->m_hwnd = hwnd;
  } else {
    self = reinterpret_cast<Window *>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  }

  if (self) {
    return self->HandleMessage(hwnd, uMsg, wParam, lParam);
  }
  return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

bool Window::Create(HINSTANCE hInstance, const wchar_t *title, int width,
                    int height) {
  if (!hInstance) {
    SetLastError(ERROR_INVALID_PARAMETER);
    OutputDebugStringW(L"DevAgents: instancia de recursos nula.\n");
    return false;
  }
  // LR_SHARED: los recursos pertenecen al modulo y no se destruyen por ventana.
  HICON big = static_cast<HICON>(LoadImageW(
      hInstance, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
      GetSystemMetrics(SM_CYICON), LR_SHARED));
  HICON small = static_cast<HICON>(LoadImageW(
      hInstance, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
      GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  if (!big || !small) {
    OutputDebugStringW(
        L"DevAgents: recurso de icono de marca no disponible.\n");
    return false;
  }
  const HRESULT appId =
      SetCurrentProcessExplicitAppUserModelID(L"AdAstra.DevAgents.DevAgents");
  if (FAILED(appId)) {
    wchar_t message[96];
    std::swprintf(message, sizeof(message) / sizeof(message[0]),
                  L"DevAgents: AppUserModelID fallo (HRESULT 0x%08lx).\n",
                  static_cast<unsigned long>(appId));
    OutputDebugStringW(message);
    return false;
  }
  m_startTime = std::chrono::high_resolution_clock::now();
  m_hInstance = hInstance;

  WNDCLASSEXW wc = {sizeof(WNDCLASSEXW)};
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = Window::WndProc;
  wc.hInstance = hInstance;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  wc.hIcon = big;
  wc.hIconSm = small;
  wc.lpszClassName = L"DevAgentsFramelessWindow";

  if (!RegisterClassExW(&wc)) {
    if (GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      OutputDebugStringW(
          L"DevAgents: no se pudo registrar la clase de ventana.\n");
      return false;
    }
    WNDCLASSEXW registered = {sizeof(WNDCLASSEXW)};
    if (!GetClassInfoExW(hInstance, wc.lpszClassName, &registered) ||
        registered.lpfnWndProc != wc.lpfnWndProc || registered.hIcon != big ||
        registered.hIconSm != small) {
      OutputDebugStringW(
          L"DevAgents: clase de ventana con marca incompatible.\n");
      return false;
    }
  }

  DWORD style = WS_OVERLAPPEDWINDOW | WS_VISIBLE;

  m_hwnd = CreateWindowExW(WS_EX_APPWINDOW, wc.lpszClassName, title, style,
                           CW_USEDEFAULT, CW_USEDEFAULT, width, height, nullptr,
                           nullptr, hInstance, this);

  if (m_hwnd) {
    SetWindowTextW(m_hwnd, title ? title : L"DevAgents");
    if (!ApplyBrandIcon(big, small)) {
      DestroyWindow(m_hwnd);
      return false;
    }
    ApplyModernFrame();
    // Fuerza un recalculo del area no cliente ya con nuestro WM_NCCALCSIZE en
    // vigor, para que el marco desaparezca sin esperar al primer resize.
    SetWindowPos(m_hwnd, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOACTIVATE);
  }

  if (!m_hwnd)
    OutputDebugStringW(L"DevAgents: no se pudo crear la ventana.\n");
  return (m_hwnd != nullptr);
}

// Esquinas redondeadas y sombra de Windows 11.
//
// Al quitar el marco nativo (WM_NCCALCSIZE) la ventana pierde tambien el
// redondeado y la sombra que el gestor de ventanas dibuja por nosotros, y
// queda un rectangulo duro. DWMWA_WINDOW_CORNER_PREFERENCE los devuelve.
// En Windows 10 la llamada falla silenciosamente y la ventana sigue cuadrada,
// que es el comportamiento nativo de ese sistema.
void Window::ApplyModernFrame() {
  if (!m_hwnd)
    return;

  // Valores de dwmapi.h que no estan en SDKs antiguos.
  enum { DWMWA_WINDOW_CORNER_PREFERENCE_ID = 33 };
  enum { DWMWCP_ROUND = 2 };

  UINT preference = DWMWCP_ROUND;
  DwmSetWindowAttribute(m_hwnd, DWMWA_WINDOW_CORNER_PREFERENCE_ID, &preference,
                        sizeof(preference));

  // Sin marco, DWM no dibuja sombra salvo que se extienda el area cliente.
  // Un margen de 1px basta para recuperarla sin reintroducir la barra.
  MARGINS margins = {1, 1, 1, 1};
  DwmExtendFrameIntoClientArea(m_hwnd, &margins);
}

bool Window::ApplyBrandIcon(HICON big, HICON small) {
  if (!m_hwnd || !big || !small)
    return false;
  SendMessageW(m_hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big));
  SendMessageW(m_hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small));
  if (SendMessageW(m_hwnd, WM_GETICON, ICON_BIG, 0) !=
          reinterpret_cast<LRESULT>(big) ||
      SendMessageW(m_hwnd, WM_GETICON, ICON_SMALL, 0) !=
          reinterpret_cast<LRESULT>(small)) {
    OutputDebugStringW(
        L"DevAgents: no se pudo asignar el icono a la ventana.\n");
    return false;
  }
  return true;
}

void Window::Show(int nCmdShow) {
  if (m_hwnd) {
    ShowWindow(m_hwnd, nCmdShow);
    UpdateWindow(m_hwnd);
  }
}

LRESULT Window::HandleMessage(HWND hwnd, UINT uMsg, WPARAM wParam,
                              LPARAM lParam) {
  switch (uMsg) {
  case consent::kMessage:
    // Autorización nativa pedida desde un worker: se muestra en este hilo.
    consent::Handle(lParam);
    return 0;
  case WM_NCHITTEST: {
    POINT pt = {GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
    ScreenToClient(hwnd, &pt);

    RECT rc;
    GetClientRect(hwnd, &rc);

    const int borderWidth = 6;

    if (pt.y < borderWidth) {
      if (pt.x < borderWidth)
        return HTTOPLEFT;
      if (pt.x >= rc.right - borderWidth)
        return HTTOPRIGHT;
      return HTTOP;
    }
    if (pt.y >= rc.bottom - borderWidth) {
      if (pt.x < borderWidth)
        return HTBOTTOMLEFT;
      if (pt.x >= rc.right - borderWidth)
        return HTBOTTOMRIGHT;
      return HTBOTTOM;
    }
    if (pt.x < borderWidth)
      return HTLEFT;
    if (pt.x >= rc.right - borderWidth)
      return HTRIGHT;

    if (pt.y < m_titlebarHeight) {
      return HTCAPTION;
    }
    return HTCLIENT;
  }
  case WM_NCCALCSIZE: {
    // Elimina el marco estandar para que la barra de titulo la dibuje el
    // WebView. Windows envia este mensaje en dos formas y hay que atender las
    // DOS: durante CreateWindowEx llega con wParam=FALSE, y la version previa
    // solo trataba wParam=TRUE, asi que el marco nativo nunca llegaba a
    // quitarse y la ventana mostraba dos barras de titulo superpuestas.
    //
    // Maximizada hace falta recortar el rectangulo cliente al area de trabajo:
    // el gestor de ventanas IGNORA ptMaxSize/ptMaxPosition de WM_GETMINMAXINFO
    // cuando cubren el monitor completo (barra de tareas auto-oculta) y deja
    // la ventana 8px desbordada por lado — la barra de estado terminaba
    // enterrada fuera de pantalla o bajo la barra de tareas. Con el clip, el
    // area visible coincide exactamente con rcWork aunque la ventana siga
    // desbordando el marco invisible fuera del monitor.
    //
    // QA 10-nov (ventana en blanco): el monitor se toma del rectangulo
    // PROPUESTO (rgrc[0]), no de la ventana. Al mover una ventana maximizada a
    // otro monitor (Win+Mayus+flecha), MonitorFromWindow aun devuelve el
    // monitor ANTERIOR: el area cliente quedaba en las coordenadas del viejo,
    // fuera de la ventana nueva, y solo se veia el marco en blanco.
    if (wParam == TRUE && IsZoomed(hwnd)) {
      NCCALCSIZE_PARAMS *params = reinterpret_cast<NCCALCSIZE_PARAMS *>(lParam);
      HMONITOR hMon =
          MonitorFromRect(&params->rgrc[0], MONITOR_DEFAULTTONEAREST);
      MONITORINFO mi = {sizeof(MONITORINFO)};
      if (GetMonitorInfoW(hMon, &mi)) {
        params->rgrc[0] = mi.rcWork;
      }
    }
    return 0;
  }
  case WM_SIZE: {
    if (wParam != SIZE_MINIMIZED) {
      int width = LOWORD(lParam);
      int height = HIWORD(lParam);
      if (m_onResize) {
        m_onResize(width, height);
      }
    }
    return 0;
  }
  case WM_MOVE: {
    if (m_onMove)
      m_onMove();
    return 0;
  }
  case WM_DPICHANGED: {
    RECT *const prcNewWindow = reinterpret_cast<RECT *>(lParam);
    SetWindowPos(hwnd, nullptr, prcNewWindow->left, prcNewWindow->top,
                 prcNewWindow->right - prcNewWindow->left,
                 prcNewWindow->bottom - prcNewWindow->top,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    m_dpi = HIWORD(wParam);
    return 0;
  }
  case WM_GETMINMAXINFO: {
    MINMAXINFO *mmi = reinterpret_cast<MINMAXINFO *>(lParam);
    HMONITOR hMon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {sizeof(MONITORINFO)};
    if (GetMonitorInfoW(hMon, &mi)) {
      RECT rcWork = mi.rcWork;
      RECT rcMon = mi.rcMonitor;
      mmi->ptMaxPosition.x = rcWork.left - rcMon.left;
      mmi->ptMaxPosition.y = rcWork.top - rcMon.top;
      mmi->ptMaxSize.x = rcWork.right - rcWork.left;
      mmi->ptMaxSize.y = rcWork.bottom - rcWork.top;
    }
    return 0;
  }
  case WM_CLOSE: {
    // E5.21: con varias ventanas el cierre lo decide el propietario (la
    // principal comprueba cambios sin guardar y arrastra a las demas). Sin
    // callback se mantiene el comportamiento de siempre.
    if (m_onClose && !m_onClose(*this))
      return 0;
    DestroyWindow(hwnd);
    return 0;
  }
  case WM_DESTROY: {
    // Ultima oportunidad de leer la posicion: SaveGeometry se llama despues de
    // que el bucle de mensajes termine, y para entonces GetWindowPlacement ya
    // falla sobre un HWND destruido. Por eso la geometria NUNCA se guardaba y
    // la ventana volvia siempre al mismo sitio.
    if (GetWindowPlacement(hwnd, &m_lastPlacement)) {
      m_havePlacement = true;
    }
    // E5.21: en multiventana NO se postea quit por cada ventana — cerrar una
    // secundaria tumbaba la app entera. El propietario decide (supervisor);
    // sin callback, una sola ventana cierra el proceso como siempre.
    //
    // El handle se mantiene DURANTE el callback: el supervisor lo necesita
    // para ByHwnd (se anulo una vez antes de llamarlo y el resultado fue un
    // proceso sin ventanas que nunca salia — el quit no se posteaba). El flag
    // m_inDestroy protege la reentrada: si el callback destruye el AppWindow
    // (secundaria cerrada), el ~Window resultante se salta DestroyWindow.
    m_inDestroy = true;
    if (m_onDestroy) {
      m_onDestroy(*this);
    } else {
      PostQuitMessage(0);
    }
    m_hwnd = nullptr;
    return 0;
  }
  }
  return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

bool Window::SaveGeometry(const std::wstring &configPath) {
  WINDOWPLACEMENT wp = {sizeof(WINDOWPLACEMENT)};
  // Se prefiere la ventana viva; si ya no existe, vale la foto tomada en
  // WM_DESTROY. Sin ese respaldo, guardar al cerrar era imposible.
  if (!m_hwnd || !GetWindowPlacement(m_hwnd, &wp)) {
    if (!m_havePlacement)
      return false;
    wp = m_lastPlacement;
  }

  std::wofstream ofs(configPath.c_str());
  if (!ofs.is_open())
    return false;

  ofs << wp.rcNormalPosition.left << L"\n"
      << wp.rcNormalPosition.top << L"\n"
      << wp.rcNormalPosition.right << L"\n"
      << wp.rcNormalPosition.bottom << L"\n"
      << wp.showCmd << L"\n";
  return true;
}

bool Window::LoadGeometry(const std::wstring &configPath,
                          WindowGeometry &outGeo) {
  std::wifstream ifs(configPath.c_str());
  if (!ifs.is_open())
    return false;

  LONG left, top, right, bottom;
  UINT showCmd;
  if (ifs >> left >> top >> right >> bottom >> showCmd) {
    outGeo.x = left;
    outGeo.y = top;
    outGeo.width = right - left;
    outGeo.height = bottom - top;
    outGeo.maximized = (showCmd == SW_SHOWMAXIMIZED);
    return true;
  }
  return false;
}

} // namespace beats
