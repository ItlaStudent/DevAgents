#pragma once
#include "core_client.hpp"
#include <functional>
#include <memory>
#include <string>
#include <windows.h>

namespace beats {
class BrowserPanel;
// One transport lane, independent of both engine request lanes and the STA.
class BrowserDispatch {
public:
  static constexpr UINT Message = WM_APP + 49;
  struct Backend {
    std::function<CoreResult(const std::string &)> attach, poll, control;
    std::function<CoreResult(long long)> resolveRoot;
    std::function<CoreResult(const std::string &, const std::string &)>
        complete;
  };
  using EventSink = std::function<void(const std::string &)>;
  explicit BrowserDispatch(Backend backend);
  ~BrowserDispatch();
  BrowserDispatch(const BrowserDispatch &) = delete;
  BrowserDispatch &operator=(const BrowserDispatch &) = delete;
  bool Attach(HWND hwnd, long long order, const std::string &worktree);
  bool Control(HWND hwnd, const std::string &action,
               const std::string &tab = "");
  void Detach(HWND hwnd);
  // Order the panel of `hwnd` is attached to (0 if none or no longer valid).
  long long AttachedOrder(HWND hwnd) const;
  // Takes ownership even if the window was destroyed before delivery.
  void Deliver(LPARAM packet, BrowserPanel *panel, EventSink sink = {});
  // Only outside WebView callbacks, before unloading the engine DLL.
  void Stop();

private:
  struct Impl;
  std::shared_ptr<Impl> m_impl;
};
} // namespace beats
