#ifndef BEATS_WINDOW_HPP
#define BEATS_WINDOW_HPP

#include <chrono>
#include <functional>
#include <string>
#include <windows.h>

namespace beats {

struct WindowGeometry {
  int x = CW_USEDEFAULT;
  int y = CW_USEDEFAULT;
  int width = 1280;
  int height = 800;
  bool maximized = false;
};

class Window {
public:
  using ResizeCallback = std::function<void(int width, int height)>;

  Window();
  ~Window();

  bool Create(HINSTANCE hInstance, const wchar_t *title, int width, int height);
  void Show(int nCmdShow);
  HWND GetHandle() const { return m_hwnd; }

  void SetTitlebarHeight(int height) { m_titlebarHeight = height; }
  int GetTitlebarHeight() const { return m_titlebarHeight; }

  void SetResizeCallback(ResizeCallback cb) { m_onResize = cb; }
  // QA 10-nov: WM_MOVE (cambio de monitor, arrastre) para que el WebView
  // recalcule su posicion en pantalla aunque el tamano no cambie.
  using MoveCallback = std::function<void()>;
  void SetMoveCallback(MoveCallback cb) { m_onMove = cb; }

  // E5.21: WM_CLOSE/WM_DESTROY los decide el propietario (supervisor de
  // ventanas). Sin callback se conserva el comportamiento historico:
  // WM_DESTROY -> PostQuitMessage(0).
  using DestroyCallback = std::function<void(Window &)>;
  void SetDestroyCallback(DestroyCallback cb) { m_onDestroy = cb; }
  // WM_CLOSE: devolver true = se permite destruir. Sin callback: siempre.
  using CloseCallback = std::function<bool(Window &)>;
  void SetCloseCallback(CloseCallback cb) { m_onClose = cb; }

  std::chrono::high_resolution_clock::time_point GetStartTime() const {
    return m_startTime;
  }

  bool SaveGeometry(const std::wstring &configPath);
  bool LoadGeometry(const std::wstring &configPath, WindowGeometry &outGeo);

private:
  // Asigna los iconos embebidos, compartidos con la clase de cada ventana.
  bool ApplyBrandIcon(HICON big, HICON small);
  // Esquinas redondeadas y sombra de Windows 11 en la ventana sin marco.
  void ApplyModernFrame();

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT uMsg, WPARAM wParam,
                                  LPARAM lParam);
  LRESULT HandleMessage(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam);

  HWND m_hwnd = nullptr;
  // true mientras WM_DESTROY corre: el destructor no debe re-DestroyWindow.
  bool m_inDestroy = false;
  // Foto de la posicion tomada en WM_DESTROY, cuando el HWND todavia responde.
  WINDOWPLACEMENT m_lastPlacement = {sizeof(WINDOWPLACEMENT)};
  bool m_havePlacement = false;
  HINSTANCE m_hInstance = nullptr;
  int m_titlebarHeight = 32;
  int m_dpi = 96;
  ResizeCallback m_onResize;
  MoveCallback m_onMove;
  DestroyCallback m_onDestroy;
  CloseCallback m_onClose;
  std::chrono::high_resolution_clock::time_point m_startTime;
};

} // namespace beats

#endif // BEATS_WINDOW_HPP
