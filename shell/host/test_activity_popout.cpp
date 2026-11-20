// native registry regression and a real-WebView CDP fixture.
// No engine DLL, credentials, network or owner data. See cab016's CDP runner.
#include "app_windows.hpp"
#include "core_client.hpp"
#include "document_manager.hpp"
#include "file_watcher.hpp"
#include "hunk_manager.hpp"
#include "lsp_client.hpp"
#include "preview_policy.hpp"
#include "project_search.hpp"
#include "pty_manager.hpp"
#include <cstdio>
#include <cstring>
#include <thread>

namespace beats {
// Simulate numeric HWND reuse without relying on the OS handle allocator.
struct WindowSupervisorTestAccess {
  static void Replace(WindowSupervisor &windows, HWND hwnd, AppWindow *entry) {
    std::lock_guard<std::mutex> lock(windows.m_registryMutex);
    windows.m_byHwnd[hwnd] = entry;
  }
};
} // namespace beats

// Keep the same regression source runnable against pre-r2 production code.
// The fallback is exactly the old UI delivery/dispatch operation.
template <typename T>
static auto ResponseTarget(T &windows, HWND hwnd,
                           const std::shared_ptr<beats::Bridge> &bridge, int)
    -> decltype(windows.ByHwnd(hwnd, bridge)) {
  return windows.ByHwnd(hwnd, bridge);
}
template <typename T>
static beats::AppWindow *ResponseTarget(T &windows, HWND hwnd,
                                        const std::shared_ptr<beats::Bridge> &,
                                        long) {
  return windows.ByHwnd(hwnd);
}
template <typename T>
static auto DispatchWindow(T &windows, MSG &message, int)
    -> decltype(windows.DispatchWindowMessage(message), void()) {
  windows.DispatchWindowMessage(message);
}
template <typename T> static void DispatchWindow(T &, MSG &message, long) {
  TranslateMessage(&message);
  DispatchMessageW(&message);
}

static std::wstring Env(const wchar_t *name) {
  const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  if (!size)
    return {};
  std::wstring value(size, L'\0');
  const DWORD copied = GetEnvironmentVariableW(name, value.data(), size);
  if (!copied || copied >= size)
    return {};
  value.resize(copied);
  return value;
}

int main(int argc, char **argv) {
  const bool nativeOnly = argc == 2 && !std::strcmp(argv[1], "--native-only");
  const auto fixture =
      nativeOnly ? Env(L"TEMP") : Env(L"BEATS_ACTIVITY_FIXTURE_DIR");
  const auto bundle = Env(L"BEATS_WEBUI_DIR");
  if (fixture.empty() || (!nativeOnly && bundle.empty())) {
    std::fputs("FAIL: BEATS_ACTIVITY_FIXTURE_DIR / BEATS_WEBUI_DIR missing\n",
               stderr);
    return 1;
  }
  if (FAILED(OleInitialize(nullptr)))
    return 1;
  int failures = 0, checks = 0;
  auto expect = [&](bool ok, const char *name) {
    ++checks;
    if (!ok)
      ++failures;
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", name);
    std::fflush(stdout);
  };
  {
    beats::CoreClient core(beats::CoreClient::InitMode::isolated_empty);
    beats::DocumentManager docs;
    beats::FileWatcher watcher;
    beats::ProjectSearch search(docs);
    beats::HunkManager hunks(docs);
    beats::PtyManager pty;
    beats::LspClient lsp;
    beats::WindowSupervisor windows;
    const auto instance = GetModuleHandleW(nullptr);
    const DWORD uiThread = GetCurrentThreadId();
    MSG message{};
    PeekMessageW(&message, nullptr, 0, 0, PM_NOREMOVE);
    bool activity = false;
    int shutdownRequests = 0;
    windows.SetCreateWebView([&](beats::AppWindow &aw) {
      aw.window.SetDestroyCallback([&](beats::Window &window) {
        if (auto *entry = windows.ByHwnd(window.GetHandle())) {
          const bool quit = windows.OnWindowDestroyed(*entry);
          std::printf("DESTROY remaining=%zu quit=%d\n", windows.All().size(),
                      quit);
          std::fflush(stdout);
          if (quit) {
            ++shutdownRequests; // Simulated process-shutdown request, no engine
                                // DLL.
            PostQuitMessage(0);
          }
        }
      });
      if (nativeOnly)
        return true;
      aw.webview.SetStartTime(aw.window.GetStartTime());
      aw.window.SetResizeCallback(
          [&aw](int w, int h) { aw.webview.Resize(w, h); });
      aw.bridge->BindServices(&docs, &watcher, &search, &hunks, &pty, &lsp,
                              &core);
      aw.bridge->SetDialogOwner(aw.hwnd);
      aw.bridge->RegisterHandler(
          "window.open", [&](const beats::BridgeMessage &msg) {
            auto request = beats::ParseOpenWindow(msg.payloadJson);
            if (!request.valid || request.vista != "monitor")
              return "{\"id\":" + std::to_string(msg.id) +
                     ",\"error\":\"monitor required\"}";
            auto *created = windows.Create(instance, L"CAB016 Activity", 960,
                                           800, &request, fixture);
            if (!created)
              return "{\"id\":" + std::to_string(msg.id) +
                     ",\"error\":\"create failed\"}";
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"payload\":{\"window_id\":" +
                   std::to_string(created->id) + "}}";
          });
      // Synthetic engine fixture: this title is read through the product
      // CoreApi and painted by the product MonitorPanel after engine.changed.
      aw.bridge->RegisterHandler(
          "core.sessions.list", [&](const beats::BridgeMessage &msg) {
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"payload\":[{\"id\":16,\"title\":\"" +
                   (activity ? "CAB016_ACTIVITY_AFTER_PRIMARY_CLOSE"
                             : "CAB016_ACTIVITY_BEFORE") +
                   "\",\"status\":\"running\"}]}";
          });
      aw.bridge->RegisterHandler(
          "fixture.closePrimary", [&](const beats::BridgeMessage &msg) {
            auto *primary = windows.Primary();
            const bool posted =
                primary && PostMessageW(primary->hwnd, WM_CLOSE, 0, 0);
            return "{\"id\":" + std::to_string(msg.id) +
                   (posted ? ",\"payload\":{}}" : ",\"error\":\"no primary\"}");
          });
      aw.bridge->RegisterHandler(
          "fixture.activity", [&](const beats::BridgeMessage &msg) {
            if (windows.Primary())
              return "{\"id\":" + std::to_string(msg.id) +
                     ",\"error\":\"primary still alive\"}";
            activity = true;
            // Exactly the process UI-thread push route used by main.cpp.
            const bool posted =
                PostThreadMessageW(uiThread, WM_APP + 44, 0, 0) != FALSE;
            return "{\"id\":" + std::to_string(msg.id) +
                   (posted ? ",\"payload\":{}}"
                           : ",\"error\":\"push failed\"}");
          });
      aw.bridge->RegisterHandler(
          "fixture.closeSelf",
          [hwnd = aw.hwnd](const beats::BridgeMessage &msg) {
            const bool posted = PostMessageW(hwnd, WM_CLOSE, 0, 0) != FALSE;
            return "{\"id\":" + std::to_string(msg.id) +
                   (posted ? ",\"payload\":{}}"
                           : ",\"error\":\"close failed\"}");
          });
      aw.webview.SetMessageCallback([&aw](const std::wstring &message) {
        aw.webview.PostMessageJson(beats::preview::Wide(
            aw.bridge->HandleMessage(beats::preview::Narrow(message))));
      });
      return aw.webview.Initialize(aw.hwnd, fixture + L"\\WebView2Data", bundle,
                                   true);
    });
    auto *primary = windows.Create(instance, L"CAB016 Primary", 1280, 900,
                                   nullptr, fixture);
    expect(primary != nullptr, "primary created");
    if (primary && nativeOnly) {
      beats::OpenWindowRequest monitor;
      monitor.valid = true;
      monitor.vista = "monitor";
      auto *popout = windows.Create(instance, L"CAB016 Native registry", 800,
                                    600, &monitor, fixture);
      expect(popout != nullptr, "monitor created");
      if (popout) {
        const HWND primaryHwnd = primary->hwnd, popoutHwnd = popout->hwnd;
        const auto oldBridge = popout->bridge;
        beats::AppWindow replacement;
        replacement.hwnd = popoutHwnd;
        replacement.bridge = std::make_shared<beats::Bridge>();
        beats::WindowSupervisorTestAccess::Replace(windows, popoutHwnd,
                                                   &replacement);
        expect(ResponseTarget(windows, popoutHwnd, oldBridge, 0) == nullptr,
               "r2-identity stale response rejected for reused HWND");
        expect(ResponseTarget(windows, popoutHwnd, replacement.bridge, 0) ==
                   &replacement,
               "r2-identity current response accepted for reused HWND");
        beats::WindowSupervisorTestAccess::Replace(windows, popoutHwnd, popout);
        expect(ResponseTarget(windows, popoutHwnd, {}, 0) == nullptr,
               "r2-identity missing bridge identity rejected");
        auto inFlight = windows.BridgeForHwnd(primaryHwnd);
        SendMessageW(primaryHwnd, WM_CLOSE, 0, 0);
        expect(IsWindow(popoutHwnd) && windows.ByHwnd(popoutHwnd),
               "popout survives primary WM_CLOSE");
        expect(windows.ByHwnd(primaryHwnd) == nullptr &&
                   windows.Primary() == nullptr,
               "closed primary absent from live registry");
        expect(windows.All().size() == 1, "only popout remains");
        expect(shutdownRequests == 0,
               "r2-exit primary close does not request process shutdown");
        beats::WindowSupervisor restarted;
        const auto restored = restarted.LoadSecondaryViews(fixture);
        WINDOWPLACEMENT placement = {sizeof(WINDOWPLACEMENT)};
        expect(GetWindowPlacement(popoutHwnd, &placement) != FALSE &&
                   restored.size() == 1 && restored[0].vista == "monitor" &&
                   restored[0].w == placement.rcNormalPosition.right -
                                        placement.rcNormalPosition.left &&
                   restored[0].h == placement.rcNormalPosition.bottom -
                                        placement.rcNormalPosition.top,
               "r2-persistence windows.ini retains monitor geometry after "
               "primary close");
        expect(!PeekMessageW(&message, nullptr, WM_QUIT, WM_QUIT, PM_REMOVE),
               "no quit while popout remains");
        windows.CollectDestroyedWindows();
        expect(!windows.BridgeForHwnd(primaryHwnd),
               "new work cannot acquire a closed primary bridge");
        expect(ResponseTarget(windows, primaryHwnd, inFlight, 0) == nullptr,
               "r2-identity response to removed HWND rejected");
        bool workerFinished = false;
        std::thread worker([inFlight, &workerFinished] {
          workerFinished =
              inFlight &&
              inFlight->HandleMessage(
                          "{\"id\":16,\"kind\":\"ping\",\"payload\":{}}")
                      .find("pong") != std::string::npos;
        });
        worker.join();
        expect(workerFinished,
               "in-flight bridge survives window collection on worker");
        auto *another = windows.Create(instance, L"CAB016 Another popout", 800,
                                       600, &monitor, fixture);
        expect(another && !another->primary && !windows.Primary(),
               "new popout does not become a primary after primary close");
        windows.CloseSecondaries();
        expect(windows.LoadSecondaryViews(fixture).empty(),
               "r2-persistence last explicit secondary close removes persisted "
               "view");
        expect(shutdownRequests == 1,
               "r2-exit last popout requests shutdown exactly once");
        expect(!IsWindow(popoutHwnd),
               "explicit secondary shutdown includes first surviving popout");
        if (IsWindow(popoutHwnd))
          SendMessageW(popoutHwnd, WM_CLOSE, 0, 0);
        expect(windows.All().empty(), "last close empties live registry");
        // PostQuitMessage synthesizes WM_QUIT only once higher-priority
        // pending paint/messages are drained, even with a WM_QUIT filter.
        bool quit = false;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
          if (message.message == WM_QUIT) {
            quit = message.wParam == 0;
            break;
          }
          DispatchWindow(windows, message, 0);
        }
        expect(quit, "last close posts normal quit");
        windows.CollectDestroyedWindows();
        auto *single = windows.Create(instance, L"CAB016 Normal exit", 800, 600,
                                      nullptr, fixture);
        auto *secondary =
            windows.Create(instance, L"CAB016 Close secondary first", 800, 600,
                           &monitor, fixture);
        expect(single && secondary, "normal-exit windows created");
        if (single && secondary) {
          std::weak_ptr<beats::Bridge> released = secondary->bridge;
          expect(PostMessageW(secondary->hwnd, WM_CLOSE, 0, 0) != FALSE &&
                     PeekMessageW(&message, secondary->hwnd, WM_CLOSE, WM_CLOSE,
                                  PM_REMOVE),
                 "r2-idle popout close is the dispatched message");
          DispatchWindow(windows, message, 0);
          // No PeekMessage/GetMessage/extra dispatch before this assertion.
          expect(released.expired(),
                 "r2-idle popout resources released before another message");
          expect(shutdownRequests == 1,
                 "r2-exit secondary close does not request shutdown");
          expect(windows.Primary() == single && IsWindow(single->hwnd),
                 "closing secondary preserves primary");
          expect(!PeekMessageW(&message, nullptr, WM_QUIT, WM_QUIT, PM_REMOVE),
                 "closing secondary does not quit");
          windows.CollectDestroyedWindows();
          SendMessageW(single->hwnd, WM_CLOSE, 0, 0);
          quit = false;
          while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
              quit = message.wParam == 0;
              break;
            }
            DispatchWindow(windows, message, 0);
          }
          expect(quit && windows.All().empty(),
                 "primary alone keeps normal exit");
          expect(shutdownRequests == 2,
                 "r2-exit last primary requests shutdown exactly once");
          windows.CollectDestroyedWindows();
        }
      }
    } else if (primary) {
      std::puts("READY CAB016 real WebViews; 90-second watchdog");
      std::fflush(stdout);
      const UINT_PTR watchdog = SetTimer(nullptr, 0, 90000, nullptr);
      if (!watchdog)
        ++failures;
      else {
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
          windows.CollectDestroyedWindows();
          if (message.message == WM_TIMER && message.wParam == watchdog) {
            expect(false, "WebView lifecycle deadline");
            break;
          }
          if (message.message == WM_APP + 44) {
            windows.Broadcast(L"{\"push\":\"engine.changed\",\"payload\":{"
                              L"\"kind\":\"core.session.fixture\"}}");
            std::puts("PUSH engine.changed after primary close");
            std::fflush(stdout);
            continue;
          }
          DispatchWindow(windows, message, 0);
        }
        KillTimer(nullptr, watchdog);
        expect(windows.All().empty(), "process loop exited after last window");
      }
    }
    // Copy handles: each close mutates the live registry.
    std::vector<HWND> remaining;
    for (const auto &aw : windows.All())
      remaining.push_back(aw->hwnd);
    for (HWND hwnd : remaining)
      if (IsWindow(hwnd))
        DestroyWindow(hwnd);
  }
  OleUninitialize();
  std::printf("CAB016 checks=%d failures=%d\n", checks, failures);
  return failures ? 1 : 0;
}
