#ifndef BEATS_NOTIFICATION_POLICY_HPP
#define BEATS_NOTIFICATION_POLICY_HPP
#include "preview_policy.hpp"
#include <shellapi.h>
namespace beats {
namespace notifications {
constexpr UINT Callback = WM_APP + 47;
inline std::wstring Title(const std::string &state) {
  if (state == "awaiting_approval")
    return L"Aprobación pendiente";
  if (state == "done")
    return L"Orden terminada";
  if (state == "failed")
    return L"Orden fallida";
  if (state == "audit_unavailable")
    return L"Sin auditar: entrega bloqueada";
  if (state == "budget_blocked")
    return L"Orden bloqueada por presupuesto";
  return L"";
}
inline bool ShouldNotify(const std::string &state, bool focused) {
  return !focused && !Title(state).empty();
}
inline NOTIFYICONDATAW Balloon(HWND hwnd, long long order,
                               const std::string &state) {
  NOTIFYICONDATAW n = {};
  n.cbSize = sizeof(n);
  n.hWnd = hwnd;
  n.uID = 1;
  n.uFlags = NIF_INFO;
  n.dwInfoFlags = state == "done" ? NIIF_INFO : NIIF_WARNING;
  const std::wstring title = Title(state);
  const std::wstring body = L"Orden #" + std::to_wstring(order) +
                            L". Pulsa para abrirla en DevAgents.";
  wcsncpy_s(n.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(n.szInfo, body.c_str(), _TRUNCATE);
  return n;
}
} // namespace notifications
} // namespace beats
#endif
