#ifndef BEATS_CONSENT_PROMPT_HPP
#define BEATS_CONSENT_PROMPT_HPP
// Autorización nativa del host (BAJO-1 de la auditoría el modelo r1).
//
// Los handlers `core.*` corren en un hilo worker, pero un diálogo modal con
// propietario creado en el hilo de UI debe abrirse EN el hilo de UI: un
// MessageBox del worker con un HWND ajeno engancha las colas de entrada de
// ambos hilos y no se puede cerrar con la ventana propietaria. El worker
// publica la solicitud en la cola de la ventana propietaria (PostMessage a
// su WndProc, que también atiende los bucles modales anidados) y espera la
// respuesta; el diálogo lo muestra el hilo de UI. Si la ventana desaparece o
// el host se apaga antes de mostrarlo, la respuesta es «no».
#include "themed_dialog.hpp"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <windows.h>

namespace beats {
namespace consent {

// Mensaje privado que el WndProc de cada ventana de la cabina entrega a Handle.
// Debe ser distinto de todos los WM_APP que intercepta el bucle de main.cpp
// (allí un static_assert lo comprueba): un valor compartido lo consumiría el
// bucle sin llegar al WndProc y el worker esperaría sin fin.
constexpr UINT kMessage = WM_APP + 48;

using Presenter = std::function<bool(HWND owner, const std::wstring &title,
                                     const std::wstring &body)>;

// Presentador de producción: Permitir/No permitir, «No» por defecto, con
// propietario. 10-nov: diálogo nativo con el tema de DevAgents (antes un
// MessageBox de Windows); sigue fuera de la WebView a propósito.
inline bool MessageBoxPresenter(HWND owner, const std::wstring &title,
                                const std::wstring &body) {
  return themed::Show(owner, title, body, themed::Kind::warning,
                      themed::Buttons::yes_no, true, L"Permitir",
                      L"No permitir") == IDYES;
}

struct Request {
  HWND owner = nullptr;
  std::wstring title, body;
  Presenter presenter;
  std::mutex mutex;
  std::condition_variable changed;
  bool shown = false;     // el hilo de UI ya tomó la solicitud
  bool answered = false;  // el presentador devolvió
  bool abandoned = false; // el solicitante dejó de esperar antes de mostrarla
  bool approved = false;
};

inline std::atomic<bool> &ShutdownFlag() {
  static std::atomic<bool> flag{false};
  return flag;
}
// main.cpp la activa antes de unir los hilos worker: nada que no se haya
// mostrado ya se mostrará después.
inline void Shutdown() { ShutdownFlag() = true; }

// Hilo de UI (WndProc de la ventana propietaria): muestra el diálogo.
inline void Handle(LPARAM lParam) {
  std::unique_ptr<std::shared_ptr<Request>> holder(
      reinterpret_cast<std::shared_ptr<Request> *>(lParam));
  if (!holder || !*holder)
    return;
  Request &request = **holder;
  {
    std::lock_guard<std::mutex> lock(request.mutex);
    if (request.abandoned)
      return;
    request.shown = true;
  }
  const bool yes =
      request.presenter(request.owner, request.title, request.body);
  {
    std::lock_guard<std::mutex> lock(request.mutex);
    request.approved = yes;
    request.answered = true;
  }
  request.changed.notify_all();
}

// Pide la autorización. Devuelve true sólo si la persona respondió «Sí».
// Si el hilo actual ya es el de la ventana propietaria el diálogo se abre
// directamente; si no, se delega en el hilo de UI.
inline bool Ask(HWND owner, const std::wstring &title, const std::wstring &body,
                const Presenter &presenter) {
  const Presenter &show =
      presenter ? presenter : Presenter(MessageBoxPresenter);
  if (!owner || !IsWindow(owner))
    return false;
  if (GetWindowThreadProcessId(owner, nullptr) == GetCurrentThreadId())
    return show(owner, title, body);
  auto request = std::make_shared<Request>();
  request->owner = owner;
  request->title = title;
  request->body = body;
  request->presenter = show;
  auto *posted = new std::shared_ptr<Request>(request);
  if (!PostMessageW(owner, kMessage, 0, reinterpret_cast<LPARAM>(posted))) {
    delete posted;
    return false;
  }
  std::unique_lock<std::mutex> lock(request->mutex);
  for (;;) {
    if (request->answered)
      return request->approved;
    // Mientras el diálogo está en pantalla se espera sin plazo (la persona
    // decide); si aún no se mostró y la ventana murió o el host se apaga, no.
    if (!request->shown && (!IsWindow(owner) || ShutdownFlag())) {
      request->abandoned = true;
      return false;
    }
    request->changed.wait_for(lock, std::chrono::milliseconds(100));
  }
}

} // namespace consent
} // namespace beats
#endif
