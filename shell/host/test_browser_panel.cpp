// Native E2E driver, no DLL/engine/owner data. Test commands exist only here.
#include "app_windows.hpp"
#include "browser_bridge.hpp"
#include "document_manager.hpp"
#include "preview_policy.hpp"
#include <cstdio>
#include <fstream>
#include <wincodec.h>

static bool Capture(HWND hwnd, const std::wstring &filename) {
  RECT r{};
  if (!GetWindowRect(hwnd, &r))
    return false;
  const int width = r.right - r.left, height = r.bottom - r.top;
  if (width <= 0 || height <= 0)
    return false;
  HDC window = GetWindowDC(hwnd), memory = CreateCompatibleDC(window);
  HBITMAP bitmap =
      window ? CreateCompatibleBitmap(window, width, height) : nullptr;
  if (!window || !memory || !bitmap) {
    if (bitmap)
      DeleteObject(bitmap);
    if (memory)
      DeleteDC(memory);
    if (window)
      ReleaseDC(hwnd, window);
    return false;
  }
  auto old = SelectObject(memory, bitmap);
  // Render this HWND, including the native controls and both WebViews,
  // without requiring permission to steal the user's foreground window.
  const bool rendered = PrintWindow(hwnd, memory, PW_RENDERFULLCONTENT);
  std::printf("CAPTURE PrintWindow=%d width=%d height=%d panelVisible=%d\n",
              rendered, width, height,
              IsWindowVisible(FindWindowExW(
                  hwnd, nullptr, L"DevAgentsBrowserPanel", nullptr)));
  HRESULT hr = rendered ? S_OK : E_FAIL;
  IWICImagingFactory *factory = nullptr;
  IWICBitmap *source = nullptr;
  IWICStream *stream = nullptr;
  IWICBitmapEncoder *encoder = nullptr;
  IWICBitmapFrameEncode *frame = nullptr;
  if (SUCCEEDED(hr))
    hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                          CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (SUCCEEDED(hr))
    hr = factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha,
                                          &source);
  if (SUCCEEDED(hr))
    hr = factory->CreateStream(&stream);
  if (SUCCEEDED(hr))
    hr = stream->InitializeFromFilename(filename.c_str(), GENERIC_WRITE);
  if (SUCCEEDED(hr))
    hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (SUCCEEDED(hr))
    hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
  if (SUCCEEDED(hr))
    hr = encoder->CreateNewFrame(&frame, nullptr);
  if (SUCCEEDED(hr))
    hr = frame->Initialize(nullptr);
  if (SUCCEEDED(hr))
    hr = frame->SetSize(width, height);
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(hr))
    hr = frame->SetPixelFormat(&format);
  if (SUCCEEDED(hr))
    hr = frame->WriteSource(source, nullptr);
  if (SUCCEEDED(hr))
    hr = frame->Commit();
  if (SUCCEEDED(hr))
    hr = encoder->Commit();
  if (frame)
    frame->Release();
  if (encoder)
    encoder->Release();
  if (stream)
    stream->Release();
  if (source)
    source->Release();
  if (factory)
    factory->Release();
  SelectObject(memory, old);
  DeleteObject(bitmap);
  DeleteDC(memory);
  ReleaseDC(hwnd, window);
  return SUCCEEDED(hr);
}

static std::wstring Env(const wchar_t *name) {
  DWORD n = GetEnvironmentVariableW(name, nullptr, 0);
  if (!n)
    return {};
  std::wstring s(n, L'\0');
  DWORD copied = GetEnvironmentVariableW(name, s.data(), n);
  if (!copied || copied >= n)
    return {};
  s.resize(copied);
  return s;
}
static bool Geometry(beats::AppWindow &aw, const std::wstring &filename) {
  RECT client{}, ui{}, panel{};
  HWND browser =
      FindWindowExW(aw.hwnd, nullptr, L"DevAgentsBrowserPanel", nullptr);
  if (!GetClientRect(aw.hwnd, &client) || !aw.webview.GetBounds(ui) ||
      !browser || !GetWindowRect(browser, &panel))
    return false;
  MapWindowPoints(nullptr, aw.hwnd, reinterpret_cast<POINT *>(&panel), 2);
  std::ofstream file(filename.c_str());
  auto rect = [&](const RECT &r) {
    file << "{\"left\":" << r.left << ",\"top\":" << r.top
         << ",\"right\":" << r.right << ",\"bottom\":" << r.bottom << "}";
  };
  MINMAXINFO limits{};
  SendMessageW(aw.hwnd, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&limits));
  file << "{\"dpi\":" << GetDpiForWindow(aw.hwnd)
       << ",\"minTrackWidth\":" << limits.ptMinTrackSize.x << ",\"client\":";
  rect(client);
  file << ",\"uiController\":";
  rect(ui);
  file << ",\"panelHWND\":";
  rect(panel);
  const UINT dpi = GetDpiForWindow(aw.hwnd);
  file << ",\"panelVisible\":" << (IsWindowVisible(browser) ? "true" : "false")
       << ",\"panelOpen\":" << (aw.browser.Visible() ? "true" : "false")
       << ",\"titlebarPx\":"
       << MulDiv(beats::BrowserPanel::TitlebarCssHeight, dpi, 96)
       << ",\"barPx\":" << MulDiv(beats::BrowserPanel::BarCssHeight, dpi, 96)
       << ",\"children\":[";
  bool first = true;
  for (HWND child = GetWindow(aw.hwnd, GW_CHILD); child;
       child = GetWindow(child, GW_HWNDNEXT)) {
    char className[128]{};
    RECT r{};
    if (!GetClassNameA(child, className, sizeof(className)) ||
        !GetWindowRect(child, &r))
      return false;
    MapWindowPoints(nullptr, aw.hwnd, reinterpret_cast<POINT *>(&r), 2);
    if (!first)
      file << ',';
    first = false;
    file << "{\"class\":\"" << className << "\",\"rect\":";
    rect(r);
    file << '}';
  }
  // Classic Win32 controls (BUTTON, EDIT, COMBOBOX, STATIC) must not live in
  // the cabina panel any more: only page WebViews may be its children.
  file << "],\"panelChildren\":[";
  first = true;
  for (HWND child = GetWindow(browser, GW_CHILD); child;
       child = GetWindow(child, GW_HWNDNEXT)) {
    char className[128]{};
    if (!GetClassNameA(child, className, sizeof(className)))
      return false;
    if (!first)
      file << ',';
    first = false;
    file << "\"" << className << "\"";
  }
  file << "]}\n";
  file.close();
  return !file.fail();
}
int main() {
  const auto fixture = Env(L"BEATS_BROWSER_FIXTURE_DIR"),
             bundle = Env(L"BEATS_WEBUI_DIR");
  const auto app = Env(L"BEATS_BROWSER_APP_URL");
  if (fixture.empty() || bundle.empty() || app.empty() ||
      GetFileAttributesW(fixture.c_str()) == INVALID_FILE_ATTRIBUTES ||
      GetFileAttributesW(bundle.c_str()) == INVALID_FILE_ATTRIBUTES) {
    std::fputs("FAIL: existing isolated fixture, bundle and app URL required\n",
               stderr);
    return 1;
  }
  if (FAILED(OleInitialize(nullptr)))
    return 1;
  int code = 0;
  {
    beats::DocumentManager documents;
    std::string documentError;
    if (!documents.AuthorizeWorkspaceRoot(fixture, documentError)) {
      std::fprintf(stderr, "FAIL: isolated document root: %s\n",
                   documentError.c_str());
      OleUninitialize();
      return 1;
    }
    beats::WindowSupervisor windows;
    windows.SetCreateWebView([&](beats::AppWindow &aw) {
      aw.window.SetResizeCallback([&aw](int w, int h) {
        aw.webview.Resize(w, h);
        aw.browser.Resize(w, h);
      });
      aw.window.SetDestroyCallback([&](beats::Window &w) {
        if (auto *a = windows.ByHwnd(w.GetHandle()))
          if (windows.OnWindowDestroyed(*a))
            PostQuitMessage(0);
      });
      if (aw.vista == "browser") {
        aw.window.SetTitlebarHeight(0);
        return aw.browser.Open(aw.hwnd, fixture, true);
      }
      aw.webview.SetStartTime(aw.window.GetStartTime());
      aw.bridge->BindServices(&documents, nullptr, nullptr, nullptr, nullptr,
                              nullptr, nullptr);
      beats::RegisterBrowserBridge(*aw.bridge, aw.browser);
      aw.bridge->RegisterHandler(
          "browser.panel.toggle",
          [&aw, &fixture](const beats::BridgeMessage &m) {
            if (aw.browser.Visible())
              aw.browser.Hide();
            else if (!aw.browser.Open(aw.hwnd, fixture))
              return "{\"id\":" + std::to_string(m.id) +
                     ",\"error\":\"panel creation failed\"}";
            return "{\"id\":" + std::to_string(m.id) +
                   ",\"status\":\"ok\",\"payload\":{}}";
          });
      aw.webview.SetMessageCallback([&aw](const std::wstring &m) {
        aw.webview.PostMessageJson(beats::preview::Wide(
            aw.bridge->HandleMessage(beats::preview::Narrow(m))));
      });
      return aw.webview.Initialize(aw.hwnd, fixture + L"\\UI-profile", bundle,
                                   true);
    });
    auto *primary =
        windows.Create(GetModuleHandleW(nullptr), L"DevAgents — navegador E2E",
                       1280, 800, nullptr, fixture);
    if (!primary || !primary->browser.SetFixtureRoot(fixture + L"\\site"))
      code = 1;
    else {
      primary->window.Show(SW_SHOWNORMAL);
      unsigned commandId = 0;
      const auto started = GetTickCount64();
      const std::wstring commandPath = fixture + L"\\command.txt";
      SetTimer(primary->hwnd, 3001, 100, nullptr);
      std::puts("READY isolated browser driver; UI and browser have different "
                "environments");
      std::fflush(stdout);
      MSG m{};
      while (GetMessageW(&m, nullptr, 0, 0) > 0) {
        if (m.message == WM_TIMER && m.wParam == 3001) {
          std::ifstream file(commandPath.c_str());
          unsigned id = 0;
          std::string action, url;
          file >> id >> action;
          std::getline(file, url);
          if (!url.empty() && url[0] == ' ')
            url.erase(0, 1);
          if (id > commandId) {
            commandId = id;
            bool ok = true;
            if (action == "capture")
              ok = Capture(primary->hwnd, fixture + L"\\cabina.png");
            else if (action == "geometry")
              ok = Geometry(*primary, fixture + L"\\geometry.json");
            else if (action == "state") {
              std::ofstream state((fixture + L"\\state.json").c_str());
              state << primary->browser.StateJson() << "\n";
              ok = !state.fail();
            } else if (action == "resize")
              ok = SetWindowPos(primary->hwnd, nullptr, 0, 0, 1500, 850,
                                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            else if (action == "narrow" || action == "width") {
              const int requested = action == "narrow" ? 440 : std::stoi(url);
              ok = requested > 0 && requested <= 1920 &&
                   SetWindowPos(primary->hwnd, nullptr, 0, 0, requested, 800,
                                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            } else if (action == "open")
              ok = primary->browser.Open(primary->hwnd, fixture);
            else if (action == "fixture")
              ok = primary->browser.Navigate(
                  L"https://preview.local/index.html");
            else if (action == "app")
              ok = primary->browser.Navigate(app);
            else if (action == "isolation-settings")
              ok = primary->browser.CheckIsolationSettings();
            else if (action == "navigate")
              ok = primary->browser.Navigate(beats::preview::Wide(url));
            else if (action == "hide")
              primary->browser.Hide();
            else if (action == "secondary") {
              beats::OpenWindowRequest r;
              r.valid = true;
              r.vista = "browser";
              ok = windows.Create(GetModuleHandleW(nullptr),
                                  L"DevAgents — navegador secundario", 900, 700,
                                  &r, fixture) != nullptr;
            } else if (action == "quit") {
              DestroyWindow(primary->hwnd);
              break;
            } else
              ok = false;
            std::ofstream ack((fixture + L"\\ack.txt").c_str());
            ack << id << " " << (ok ? "ok" : "failed") << "\n";
            std::printf("TEST command=%u action=%s result=%s\n", id,
                        action.c_str(), ok ? "ok" : "failed");
            std::fflush(stdout);
          }
          if (GetTickCount64() - started > 180000) {
            std::fputs("FAIL: E2E timeout\n", stderr);
            code = 1;
            DestroyWindow(primary->hwnd);
            break;
          }
          continue;
        }
        if (m.message == WM_APP + 42) {
          primary->webview.DumpDomToCdpFile();
          continue;
        }
        TranslateMessage(&m);
        DispatchMessageW(&m);
      }
      if (IsWindow(primary->hwnd))
        DestroyWindow(primary->hwnd);
    }
  }
  OleUninitialize();
  return code;
}
