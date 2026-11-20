// QA-A H17: estas pruebas se apoyan en DA_CHECK() con la llamada dentro; en una
// compilación con NDEBUG (shellCppFlags fuera de Debug) se borraban enteras y
// el ejecutable salía con 0 sin probar nada. Igual que el resto de pruebas del
// host: NDEBUG fuera antes de cualquier #include.
#include "browser_agent_tools.hpp"
#include "browser_panel.hpp"
#include "preview_policy.hpp"
#include "test_check.hpp"
#include <cstdio>

// API/lifecycle unit driver. Real WebView/title/input coverage belongs to the
// isolated native E2E driver, not to a fabricated browser backend here.
int main() {
  using PhysicalInput = beats::BrowserPanel::PhysicalInput;
  const auto physical = beats::BrowserPanel::IsPhysicalPageInput;
  DA_CHECK(physical(PhysicalInput{WM_LBUTTONDOWN, 0, false, true, false}));
  // 12-nov: pasar el ratón por encima de la página no quita el control.
  DA_CHECK(!physical(PhysicalInput{WM_MOUSEMOVE, 0, false, true, false}));
  DA_CHECK(physical(PhysicalInput{WM_MOUSEWHEEL, 0, false, true, false}));
  DA_CHECK(!physical(
      PhysicalInput{WM_LBUTTONDOWN, LLMHF_INJECTED, false, true, false}));
  DA_CHECK(!physical(PhysicalInput{WM_LBUTTONDOWN, 0, false, false, true}));
  DA_CHECK(physical(PhysicalInput{WM_KEYDOWN, 0, true, true, true}));
  DA_CHECK(
      !physical(PhysicalInput{WM_KEYDOWN, LLKHF_INJECTED, true, true, true}));
  DA_CHECK(!physical(PhysicalInput{WM_KEYDOWN, 0, true, true, false}));
  DA_CHECK(!physical(PhysicalInput{WM_KEYDOWN, 0, true, false, true}));
  DA_CHECK(!physical(PhysicalInput{WM_CHAR, 0, true, true, true}));
  std::puts("E2P2 physical hook metadata filter "
            "injected/foreign/focus/mouse/key PASS");
  beats::BrowserPanel panel;
  panel.SetSessionIdentity("session-test", "tab-test");
  panel.SetAgentState("agent_control", 1);
  panel.SetControlSink([](const std::string &, const std::string &) {});
  unsigned completions = 0;
  panel.ExecuteAgent(
      R"({"request_id":"request-test","tool":"browser_tabs","args":{"action":"list"},"control_epoch":1})",
      [&](std::string result) {
        ++completions;
        beats::preview::Value value;
        DA_CHECK(beats::preview::Parser(result, true, true).Parse(value));
        DA_CHECK(value.object.at("request_id").string == "request-test");
        DA_CHECK(value.object.at("error").object.at("code").string ==
                 "session_closed");
        DA_CHECK(value.object.at("error").object.at("effect_status").string ==
                 "not_started");
      });
  DA_CHECK(completions == 1);
  panel.Hide();
  DA_CHECK(completions == 1);
  std::puts("E2P2 panel closed-session terminal exactly once PASS");
  panel.CancelAgent("request-test");
  panel.CancelAgent("request-never-started", "timeout");
  DA_CHECK(completions == 1);
  std::puts(
      "E2P2 panel cancellation after terminal never completes twice PASS");
  auto state = [&]() {
    beats::preview::Value value;
    const auto json = panel.StateJson();
    DA_CHECK(beats::preview::Parser(json, true, true).Parse(value));
    return value;
  };
  panel.SetAgentState("user_control", 3);
  DA_CHECK(state().object.at("control_state").string == "user_control");
  panel.SetAgentState("agent_control", 2);
  DA_CHECK(state().object.at("control_state").string == "user_control");
  panel.SetAgentState("invalid", 4);
  DA_CHECK(state().object.at("control_state").string == "user_control");
  panel.SetAgentState("agent_control", 4);
  DA_CHECK(state().object.at("control_state").string == "agent_control");
  DA_CHECK(state().object.at("control_epoch").number == 4);
  std::puts("E2P2 panel stale control state cannot resume the agent PASS");
  panel.SetSessionIdentity("session-other", "tab-other");
  DA_CHECK(state().object.at("control_state").string == "session_closed");
  DA_CHECK(state().object.at("control_epoch").number == 0);
  DA_CHECK(state().object.at("session_id").string == "session-other");
  std::puts("E2P2 panel new session resets control before execution PASS");
  panel.ExecuteAgent("{", [&](std::string result) {
    ++completions;
    beats::preview::Value value;
    DA_CHECK(beats::preview::Parser(result, true, true).Parse(value));
    DA_CHECK(value.object.at("error").object.at("code").string ==
             "invalid_arguments");
  });
  DA_CHECK(completions == 2);
  std::puts("E2P2 panel malformed request has an explicit terminal PASS");

  // T6: piezas puras de browser_console, browser_network, browser_viewport,
  // browser_color_scheme y browser_screenshot.
  namespace ba = beats::browser_agent;
  DA_CHECK(
      ba::RedactUrl("https://ana:clave@api.test/v1?q=1&api_key=XYZ&token=abc"
                    "#access_token=qq&x=1") ==
      "https://REDACTED@api.test/v1?q=1&api_key=REDACTED&token=REDACTED"
      "#access_token=REDACTED&x=1");
  DA_CHECK(ba::RedactUrl("http://127.0.0.1:5173/a?Secret=s&page=2") ==
           "http://127.0.0.1:5173/a?Secret=REDACTED&page=2");
  DA_CHECK(ba::RedactUrl("http://h/p?password=&next=/x#frag") ==
           "http://h/p?password=&next=/x#frag");
  DA_CHECK(ba::RedactUrl(std::string(3000, 'a')).size() <= 2048 + 3);
  std::puts("T6 network urls redact credentials and secret parameters PASS");
  ba::Ring<ba::ConsoleEntry> console;
  for (int i = 0; i < 205; ++i)
    console.Push({0, i % 2 ? "error" : "log", "m" + std::to_string(i), "", 0});
  DA_CHECK(console.items.size() == 200 && console.dropped == 5);
  DA_CHECK(console.items.front().seq == 6 && console.items.back().seq == 205);
  const std::string first = ba::ConsoleJson(console, 0, {"error"}, 2);
  DA_CHECK(first.find("\"seq\":6,") != std::string::npos &&
           first.find("\"seq\":8,") != std::string::npos &&
           first.find("\"seq\":10,") == std::string::npos &&
           first.find("\"next_cursor\":\"9\"") != std::string::npos &&
           first.find("\"more\":true") != std::string::npos &&
           first.find("\"dropped\":5") != std::string::npos);
  uint64_t after = 0;
  DA_CHECK(ba::ParseCursor("8", after) && after == 8);
  DA_CHECK(!ba::ParseCursor("8a", after) && !ba::ParseCursor("-1", after));
  const std::string rest = ba::ConsoleJson(console, 204, {}, 100);
  DA_CHECK(rest.find("\"seq\":205") != std::string::npos &&
           rest.find("\"more\":false") != std::string::npos);
  ba::Ring<ba::ConsoleEntry> big;
  for (int i = 0; i < 100; ++i)
    big.Push({0, "log", std::string(2000, 'x'), "", 0});
  const std::string bounded = ba::ConsoleJson(big, 0, {}, 100);
  DA_CHECK(bounded.size() < 100 * 1024 &&
           bounded.find("\"more\":true") != std::string::npos);
  DA_CHECK(ba::Quote("a\"b\\\n\x01") == "\"a\\\"b\\\\\\n\\u0001\"");
  ba::Ring<ba::NetworkEntry> network;
  network.Push({0, "1", "GET", "http://h/api/a", "Fetch", "", 200});
  network.Push(
      {0, "2", "POST", "http://h/img.png", "Image", "net::ERR_FAILED", 0});
  const std::string api = ba::NetworkJson(network, 0, "/api", 10);
  DA_CHECK(api.find("\"seq\":1,\"method\":\"GET\"") != std::string::npos &&
           api.find("img.png") == std::string::npos &&
           api.find("\"next_cursor\":\"2\"") != std::string::npos);
  DA_CHECK(ba::NetworkJson(network, 0, "", 10)
               .find("\"failure\":\"net::ERR_FAILED\"") != std::string::npos);
  std::puts(
      "T6 console and network logs are bounded with cursor and filters PASS");
  ba::Viewport vp;
  DA_CHECK(ba::ViewportFor("mobile", false, 0, 0, 0, false, "", vp) &&
           ba::ViewportParams(vp) ==
               "{\"width\":390,\"height\":844,\"deviceScaleFactor\":3.00,"
               "\"mobile\":true,\"screenOrientation\":{\"type\":"
               "\"portraitPrimary\",\"angle\":0}}");
  DA_CHECK(ba::ViewportFor("tablet", false, 0, 0, 0, false, "landscape", vp) &&
           vp.width == 1180 && vp.height == 820 && vp.landscape);
  DA_CHECK(ba::ViewportFor("desktop", false, 0, 0, 0, false, "", vp) &&
           vp.clear && ba::ViewportParams(vp) == "{}");
  DA_CHECK(ba::ViewportFor("", true, 1280, 800, 1, false, "", vp) &&
           vp.width == 1280 && vp.height == 800 && !vp.mobile);
  DA_CHECK(!ba::ViewportFor("mobile", true, 1280, 800, 1, false, "", vp));
  DA_CHECK(!ba::ViewportFor("", true, 100, 800, 1, false, "", vp));
  DA_CHECK(!ba::ViewportFor("", false, 0, 0, 0, false, "", vp));
  std::string scheme;
  DA_CHECK(ba::ColorSchemeParams("dark", scheme) &&
           scheme == "{\"features\":[{\"name\":\"prefers-color-scheme\","
                     "\"value\":\"dark\"}]}");
  DA_CHECK(ba::ColorSchemeParams("system", scheme) &&
           scheme.find("\"value\":\"\"") != std::string::npos);
  DA_CHECK(!ba::ColorSchemeParams("sepia", scheme));
  std::puts("T6 viewport and color scheme emulation parameters PASS");
  // PNG de 1x1 real.
  std::string png;
  uint32_t width = 0, height = 0;
  DA_CHECK(
      ba::Base64Decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlE"
                       "QVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
                       png) &&
      ba::PngSize(png, width, height) && width == 1 && height == 1);
  DA_CHECK(!ba::Base64Decode("abc", png) && !ba::Base64Decode("ab=c", png));
  DA_CHECK(ba::Base64Decode("aGVsbG8=", png) && png == "hello" &&
           !ba::PngSize(png, width, height));
  std::puts("T6 screenshot png decoding and size PASS");
}
