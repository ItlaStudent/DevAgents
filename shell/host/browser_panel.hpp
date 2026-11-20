#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <windows.h>

namespace beats {
// The untrusted page WebViews, nothing else. The tab strip, address bar and
// approval dialog are painted by the trusted cabina WebUI, which learns the
// state through the event sink and acts only through the host's bridge
// handlers (browser_bridge.hpp). The page itself never gets a Bridge. The
// secondary `vista=browser` window has no WebUI and keeps native controls.
class BrowserPanel {
public:
  // CSS pixels the WebUI reserves above the page and for the cabina titlebar.
  // The host multiplies both by the window DPI to place the page rectangle.
  static constexpr int BarCssHeight = 76;
  static constexpr int TitlebarCssHeight = 36;
  // Delivers one JSON event line to the trusted WebUI; false means it is gone.
  using EventSink = std::function<bool(const std::wstring &)>;
  using AgentCompletion = std::function<void(std::string)>;
  using ControlSink =
      std::function<void(const std::string &, const std::string &)>;
  // Native hook metadata only: never key codes, characters or page content.
  struct PhysicalInput {
    UINT message = 0;
    DWORD flags = 0;
    bool keyboard = false;
    bool targetInPage = false;
    bool foregroundInHost = false;
  };
  static bool IsPhysicalPageInput(const PhysicalInput &input) noexcept;

  BrowserPanel();
  ~BrowserPanel();
  BrowserPanel(const BrowserPanel &) = delete;
  BrowserPanel &operator=(const BrowserPanel &) = delete;
  bool Open(HWND parent, const std::wstring &dataRoot, bool fullWindow = false);
  void Hide();
  void Resize(int width, int height);
  void SetEventSink(EventSink sink);
  // STA-only agent entry points. Completion never exposes host capabilities.
  void ExecuteAgent(const std::string &requestJson, AgentCompletion done);
  void CancelAgent(const std::string &requestId,
                   const std::string &code = "cancelled");
  void SetControlSink(ControlSink sink);
  void HumanControl();
  void SetAgentState(const std::string &state, uint64_t epoch);
  void SetSessionIdentity(const std::string &sessionId,
                          const std::string &tabId);
  // True while the panel is open, even when the page area is covered by a
  // WebUI state card (blank tab, load error, blocked destination).
  bool Visible() const;
  // Called only by the host after resolving a governed order's worktree.
  bool SetFixtureRoot(const std::wstring &root);

  // Commands for the trusted UI. Each returns false with Reason() set when the
  // policy or the arguments refuse it; none approves anything by itself.
  std::string StateJson() const;
  std::string Reason() const;
  bool Navigate(const std::wstring &url);
  bool Back();
  bool Forward();
  bool Reload();
  bool Stop();
  bool NewTab();
  bool CloseTab(unsigned id);
  bool SelectTab(unsigned id);
  // Registers a localhost origin as an app and opens it in the active tab.
  bool RegisterApp(const std::wstring &url);
  // A layer of the trusted cabina (tray, menu, palette, modal) overlaps the
  // page rectangle: the native page window is hidden behind a still image of
  // itself, delivered to the WebUI as a `browser.cover` push, until the layer
  // goes away. Never changes navigation, approvals or the agent's control.
  bool SetCover(bool on);
  // The user asks again for the destination blocked in the active tab (the
  // «Aprobar este origen…» card). Never takes the control from the agent.
  bool RetryBlocked();
  // Answers a pending approval; the id is unguessable and single-use.
  bool ResolveApproval(const std::string &id, bool allow);
  // The WebUI (re)started: approvals it could have shown are answered "No".
  void UiRestarted();
#ifndef NDEBUG
  bool CheckIsolationSettings() const;
#endif
  struct Impl;

private:
  std::shared_ptr<Impl> m_impl;
};
} // namespace beats
