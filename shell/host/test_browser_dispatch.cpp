#include "browser_dispatch.hpp"
#include "browser_panel.hpp"
#include "preview_policy.hpp"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <mutex>

static void Check(bool condition, const char *what) {
  if (!condition) {
    std::fprintf(stderr, "E2P2 FAIL %s\n", what);
    std::exit(1);
  }
}

int main() {
  beats::BrowserDispatch::Backend backend;
  beats::BrowserDispatch dispatcher(std::move(backend));
  if (dispatcher.Attach(nullptr, 41, "C:\\fixture") ||
      dispatcher.Control(nullptr, "resume")) {
    std::fputs("E2P2 FAIL invalid HWND accepted\n", stderr);
    return 1;
  }
  dispatcher.Stop();
  dispatcher.Stop();
  std::puts("E2P2 dispatcher invalid window and idempotent shutdown PASS");

  // Real Win32 message queue and real panel lifecycle, with an injectable
  // motor transport. This deliberately does not fake a successful WebView.
  const HWND hwnd = CreateWindowExW(0, L"STATIC", L"browser transport test", 0,
                                    0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                    GetModuleHandleW(nullptr), nullptr);
  Check(hwnd != nullptr, "message-only HWND");
  beats::BrowserPanel panel;
  const DWORD sta = GetCurrentThreadId();
  std::atomic<unsigned> polls{0}, completions{0}, controls{0};
  std::atomic<bool> wrongLane{false}, malformed{false};
  std::mutex resultMutex;
  std::string completed;
  beats::BrowserDispatch::Backend loopback;
  loopback.attach = [&](const std::string &json) {
    if (GetCurrentThreadId() == sta)
      wrongLane = true;
    beats::preview::Value v;
    if (!beats::preview::Parser(json, true, true).Parse(v) ||
        v.object.at("order_id").number != 41 ||
        v.object.at("workspace_root").string != "C:\\fixture")
      malformed = true;
    return beats::CoreResult{
        0,
        R"({"schema":"browser.v1","ok":true,"host_capability":"private-native-capability","host_generation":2,"control_epoch":1,"session_id":"session-A","tab_id":"tab-A","order_id":41,"state":"agent_control"})",
        ""};
  };
  loopback.poll = [&](const std::string &capability) {
    if (GetCurrentThreadId() == sta)
      wrongLane = true;
    if (capability != "private-native-capability")
      malformed = true;
    const auto count = ++polls;
    return beats::CoreResult{
        0,
        count == 1
            ? R"({"schema":"browser.v1","ok":true,"state":"agent_control","control_epoch":1,"active_request_ids":["request-A","foreign-B"],"requests":[{"request_id":"foreign-B","order_id":42,"host_generation":2,"control_epoch":1,"tool":"browser_tabs","args":{"action":"list"}},{"request_id":"request-A","order_id":41,"host_generation":2,"control_epoch":1,"tool":"browser_tabs","args":{"action":"list"}}]})"
            : R"({"schema":"browser.v1","ok":true,"state":"agent_control","control_epoch":1,"active_request_ids":[],"requests":[]})",
        ""};
  };
  loopback.complete = [&](const std::string &capability,
                          const std::string &json) {
    if (GetCurrentThreadId() == sta)
      wrongLane = true;
    if (capability != "private-native-capability")
      malformed = true;
    {
      std::lock_guard<std::mutex> lock(resultMutex);
      completed = json;
    }
    ++completions;
    return beats::CoreResult{0, "", ""};
  };
  loopback.control = [&](const std::string &) {
    if (GetCurrentThreadId() == sta)
      wrongLane = true;
    ++controls;
    return beats::CoreResult{0, R"({"ok":true})", ""};
  };
  beats::BrowserDispatch realQueue(std::move(loopback));
  Check(realQueue.Attach(hwnd, 41, "C:\\fixture"), "attach queues");
  const auto limit = GetTickCount64() + 3000;
  unsigned uiTurns = 0;
  auto pump = [&] {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == beats::BrowserDispatch::Message)
        realQueue.Deliver(message.lParam, &panel,
                          [&](const std::string &event) {
                            Check(GetCurrentThreadId() == sta, "event on STA");
                            Check(event.find("private-native-capability") ==
                                      std::string::npos,
                                  "private capability absent from event");
                          });
      else
        DispatchMessageW(&message);
    }
    ++uiTurns;
  };
  while (GetTickCount64() < limit && !completions.load()) {
    pump();
    Sleep(1);
  }
  std::printf("E2P2 transport polls=%u completions=%u controls=%u "
              "wrong_lane=%d malformed=%d ui_turns=%u\n",
              polls.load(), completions.load(), controls.load(),
              wrongLane.load(), malformed.load(), uiTurns);
  Check(completions == 1, "one completion (foreign order not dispatched)");
  Check(polls > 0 && uiTurns > 0 && !wrongLane && !malformed,
        "transport runs independently from STA");
  beats::preview::Value terminal;
  {
    std::lock_guard<std::mutex> lock(resultMutex);
    Check(beats::preview::Parser(completed, true, true).Parse(terminal),
          "terminal JSON");
  }
  Check(terminal.object.at("request_id").string == "request-A" &&
            terminal.object.at("order_id").number == 41 &&
            terminal.object.at("host_generation").number == 2 &&
            terminal.object.at("control_epoch").number == 1 &&
            terminal.object.at("error").object.at("code").string ==
                "session_closed",
        "explicit session_closed and unchanged correlation");
  Check(realQueue.Control(hwnd, "take"), "trusted control queues");
  realQueue.Detach(hwnd);
  Check(!realQueue.Control(hwnd, "resume"), "detached session cannot resume");
  realQueue.Stop();
  pump();
  Check(controls >= 2, "take and close consumed by transport");
  DestroyWindow(hwnd);
  std::puts("E2P2 dispatcher roundtrip correlated terminal=session_closed "
            "foreign_order=discarded independent_lane=true "
            "capability_private=true PASS");
}
