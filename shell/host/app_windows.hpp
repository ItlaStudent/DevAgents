#ifndef BEATS_APP_WINDOWS_HPP
#define BEATS_APP_WINDOWS_HPP

// E5.21 — multiventana: una AppWindow (ventana + WebViewHost + enrutado propio)
// por ventana; los servicios de proceso (Bridge con DocumentManager,
// FileWatcher, ProjectSearch, HunkManager, PtyManager, LspClient y CoreClient)
// son COMPARTIDOS. La revisión de seguridad entre hilos de cada servicio vive
// en docs/MULTIVENTANA.md.

#include "bridge.hpp"
#include "browser_panel.hpp"
#include "webview_host.hpp"
#include "window.hpp"
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <windows.h>

namespace beats {

// Ventanas secundarias: la WebUI las monta con `?ventana=<id>&vista=<vista>`.
// Las vistas permitidas son las que E5.22 sabe renderizar en modo aislado.
// Se valida aqui (puente) Y en la WebUI — defensa en profundidad como en
// ui_action.
struct OpenWindowRequest {
  std::string vista; // editor|terminal|conversacion|monitor
  std::string path;  // solo 'editor'
  long orderId = 0;  // solo 'conversacion'
  bool valid = false;
  std::string error;
  // Geometria restaurada desde windows.ini (solo la rellena
  // LoadSecondaryViews; en una peticion window.open queda en 0).
  int x = 0;
  int y = 0;
  int w = 0;
  int h = 0;
  bool maximized = false;
};

OpenWindowRequest ParseOpenWindow(const std::string &payloadJson);

struct AppWindow {
  int id = 0;
  bool primary = false;
  Window window;
  WebViewHost webview;
  BrowserPanel browser;
  // Enrutado propio: cada ventana tiene su Bridge (los handlers registran el
  // HWND correcto — window.command cierra/minimiza SU ventana, no la
  // principal). Los servicios que recibe son los mismos objetos de proceso.
  std::shared_ptr<Bridge> bridge;
  std::string vista;   // "" en la principal
  std::string navPath; // path de la vista editor (persistencia E5.21)
  long navOrder = 0;   // order_id de la vista conversacion
  HWND hwnd = nullptr;
};

// Registro de ventanas del proceso. NO es propietario del bucle de mensajes ni
// de los servicios: vive en WinMain junto a ellos. Todo lo que muta el registro
// corre en el hilo de UI; los workers adquieren un puente compartido bajo
// mutex y entregan respuestas por HWND + identidad del puente, sin AppWindow*.
class WindowSupervisor {
public:
  // Callbacks que main.cpp inyecta para no acoplar este registro al resto.
  using CreateWebViewFn = std::function<bool(AppWindow &)>;
  using DestroyedFn = std::function<void(AppWindow &)>;

  void SetCreateWebView(CreateWebViewFn fn) { m_createWebView = std::move(fn); }
  void SetDestroyed(DestroyedFn fn) { m_destroyed = std::move(fn); }

  // %codificacion minima de un componente de query (rutas con '\' y espacios
  // llegan intactas a la WebUI).
  static std::wstring UrlEncodeComponent(const std::string &utf8);

  // Crea una ventana (principal o secundaria). `params` lleva vista/path/order
  // de la secundaria; con ellos se compone ?ventana=<id>&vista=..&path=..
  // &order=.. y se fija en el WebView ANTES de inicializarlo — la primera
  // navegacion ya lleva la vista pedida. En la principal, nullptr.
  AppWindow *Create(HINSTANCE hInstance, const std::wstring &title, int w,
                    int h, const OpenWindowRequest *params,
                    const std::wstring &configDir);
  // WM_DESTROY: solo la ultima ventana viva termina el proceso.
  bool OnWindowDestroyed(AppWindow &aw);
  AppWindow *ByHwnd(HWND hwnd) const;
  // Solo UI: un HWND reutilizado nunca recibe una respuesta del puente viejo.
  AppWindow *ByHwnd(HWND hwnd, const std::shared_ptr<Bridge> &expected) const;
  // El worker conserva el puente mientras termina una peticion, aunque la
  // ventana se cierre en UI. No conserva ni accede a un AppWindow destruido.
  std::shared_ptr<Bridge> BridgeForHwnd(HWND hwnd) const;
  // Llamar tras volver de DispatchMessage, nunca dentro de WM_DESTROY.
  void CollectDestroyedWindows();
  // Recoge inmediatamente al retornar de WndProc, antes del siguiente
  // GetMessage.
  void DispatchWindowMessage(const MSG &message);
  AppWindow *Primary();
  const std::vector<std::unique_ptr<AppWindow>> &All() const {
    return m_windows;
  }
  // Cierre explicito de secundarias; no se encadena al cerrar la principal.
  void CloseSecondaries();

  // Difusion a TODAS las ventanas (documento guardado/cambiado, tema,
  // sesiones, ordenes). Segura solo desde el hilo de UI.
  void Broadcast(const std::wstring &jsonMessage);

  // Persistencia: <configDir>\windows.ini — una linea por ventana:
  //   id|x|y|w|h|max|vista
  bool SaveLayout(const std::wstring &configDir) const;
  // Lee la lista de secundarias guardadas para reabrirlas tras el arranque.
  std::vector<OpenWindowRequest>
  LoadSecondaryViews(const std::wstring &configDir) const;

private:
  friend struct WindowSupervisorTestAccess;
  std::vector<std::unique_ptr<AppWindow>> m_windows;
  std::unordered_map<HWND, AppWindow *> m_byHwnd;
  mutable std::mutex m_registryMutex;
  // Evita destruir Window y su callback mientras ejecutan WM_DESTROY.
  std::vector<std::unique_ptr<AppWindow>> m_destroyedWindows;
  std::wstring m_configDir;
  int m_nextId = 1;
  CreateWebViewFn m_createWebView;
  DestroyedFn m_destroyed;
};

} // namespace beats

#endif // BEATS_APP_WINDOWS_HPP
