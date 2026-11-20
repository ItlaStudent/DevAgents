// Real primary/popout WebViews with the product bridge and no engine/user data.
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

int main() {
  const std::wstring fixture = Env(L"BEATS_SECURITY_FIXTURE_DIR");
  const std::wstring bundle = Env(L"BEATS_WEBUI_DIR");
  const std::wstring logs = Env(L"BEATS_WEBVIEW_LOG_DIR");
  if (fixture.empty() || bundle.empty() || logs.empty() ||
      GetFileAttributesW(fixture.c_str()) == INVALID_FILE_ATTRIBUTES ||
      GetFileAttributesW(bundle.c_str()) == INVALID_FILE_ATTRIBUTES ||
      GetFileAttributesW(logs.c_str()) == INVALID_FILE_ATTRIBUTES) {
    std::fputs("FAIL: set existing fixture, bundle and logs directories\n",
               stderr);
    return 1;
  }
  if (FAILED(OleInitialize(nullptr))) {
    std::fputs("FAIL: OleInitialize\n", stderr);
    return 1;
  }
  int result = 0;
  {
    beats::CoreClient core(beats::CoreClient::InitMode::isolated_empty);
    beats::DocumentManager docs;
    beats::FileWatcher watcher;
    beats::ProjectSearch search(docs);
    beats::HunkManager hunks(docs);
    beats::PtyManager pty;
    beats::LspClient lsp;
    beats::WindowSupervisor windows;
    std::string error;
    const auto writerRoot = fixture + L"\\workspace";
    const auto checkpointRoot = fixture + L"\\checkpoints";
    const auto otherCheckpointRoot = fixture + L"\\checkpoints-other";
    const bool writerDirectory =
        CreateDirectoryW(writerRoot.c_str(), nullptr) ||
        GetLastError() == ERROR_ALREADY_EXISTS;
    if (!writerDirectory || !docs.AuthorizeWorkspaceRoot(fixture, error) ||
        !docs.AuthorizeWorkspaceRoot(writerRoot, error) ||
        !docs.AuthorizeWorkspaceRoot(checkpointRoot, error) ||
        !docs.AuthorizeWorkspaceRoot(otherCheckpointRoot, error)) {
      std::fprintf(stderr, "FAIL: fixture root: %s\n", error.c_str());
      result = 1;
    } else {
      const HINSTANCE instance = GetModuleHandleW(nullptr);
      windows.SetCreateWebView([&](beats::AppWindow &aw) {
        aw.webview.SetStartTime(aw.window.GetStartTime());
        aw.window.SetResizeCallback(
            [&aw](int w, int h) { aw.webview.Resize(w, h); });
        aw.window.SetDestroyCallback([&](beats::Window &window) {
          if (auto *entry = windows.ByHwnd(window.GetHandle()))
            if (windows.OnWindowDestroyed(*entry))
              PostQuitMessage(0);
        });
        aw.bridge->BindServices(&docs, &watcher, &search, &hunks, &pty, &lsp,
                                &core);
        aw.bridge->SetDialogOwner(aw.hwnd);
        aw.bridge->SetEventSink([&](const std::string &event) {
          windows.Broadcast(beats::preview::Wide(event));
        });
        aw.bridge->RegisterHandler(
            "window.open", [&](const beats::BridgeMessage &msg) {
              const beats::OpenWindowRequest request =
                  beats::ParseOpenWindow(msg.payloadJson);
              if (!request.valid || request.vista == "preview")
                return "{\"id\":" + std::to_string(msg.id) +
                       ",\"error\":\"invalid fixture popout\"}";
              auto *created = windows.Create(instance, L"SEC WebView popout",
                                             840, 620, &request, fixture);
              if (!created)
                return "{\"id\":" + std::to_string(msg.id) +
                       ",\"error\":\"popout creation failed\"}";
              return "{\"id\":" + std::to_string(msg.id) +
                     ",\"status\":\"ok\",\"payload\":{\"window_id\":" +
                     std::to_string(created->id) + "}}";
            });
        aw.webview.SetMessageCallback([&aw](const std::wstring &message) {
          aw.webview.PostMessageJson(beats::preview::Wide(
              aw.bridge->HandleMessage(beats::preview::Narrow(message))));
        });
        return aw.webview.Initialize(aw.hwnd, fixture + L"\\WebView2Data",
                                     bundle, true);
      });
      auto *primary = windows.Create(instance, L"SEC WebView primary", 1100,
                                     800, nullptr, fixture);
      if (!primary) {
        std::fputs("FAIL: primary creation\n", stderr);
        result = 1;
      } else {
        beats::OpenWindowRequest popout;
        popout.vista = "monitor";
        popout.valid = true;
        if (!windows.Create(instance, L"SEC WebView popout", 840, 620, &popout,
                            fixture)) {
          std::fputs("FAIL: popout creation\n", stderr);
          result = 1;
        } else {
          std::puts("READY: product bridge, primary and popout; isolated_empty "
                    "engine");
          std::fflush(stdout);
          MSG message;
          while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            if (message.message == WM_APP + 42) {
              if (auto *entry = windows.ByHwnd(message.hwnd))
                entry->webview.DumpDomToCdpFile();
              continue;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
          }
        }
      }
      // Close while the supervisor registry and service callbacks still live.
      if (auto *entry = windows.Primary())
        if (IsWindow(entry->hwnd))
          DestroyWindow(entry->hwnd);
    }
  }
  OleUninitialize();
  return result;
}
