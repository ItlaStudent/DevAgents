#pragma once
// Bridge handlers that let the trusted cabina WebUI drive the browser panel.
// They are registered only on an AppWindow's own Bridge, which only the
// devagents.local WebUI can reach; the untrusted page WebViews have no Bridge.
// Every handler validates its payload, then asks the panel, which applies the
// same origin policy as any other caller. None of them can approve a site:
// approval needs `browser.approval.resolve` with an id the host generated for
// a request it showed to the user.
#include "bridge.hpp"
#include "browser_panel.hpp"
#include "preview_policy.hpp"
#include <cmath>

namespace beats {
namespace browser_bridge {
inline std::string Ok(int id, const std::string &payload = "{}") {
  return "{\"id\":" + std::to_string(id) +
         ",\"status\":\"ok\",\"payload\":" + payload + "}";
}
inline std::string Fail(int id, const std::string &error) {
  return "{\"id\":" + std::to_string(id) + ",\"error\":\"" +
         JsonEscapePublic(error) + "\"}";
}
// Payload must be an object whose keys are all among `allowed`.
inline bool Object(const BridgeMessage &m, preview::Value &v,
                   std::initializer_list<const char *> allowed) {
  // Literals (true/false) are only parsed in protocol mode; arrays stay off.
  if (!preview::Parser(m.payloadJson, false, true).Parse(v) ||
      v.type != preview::Value::Object)
    return false;
  for (const auto &entry : v.object) {
    bool known = false;
    for (const char *key : allowed)
      known = known || entry.first == key;
    if (!known)
      return false;
  }
  return true;
}
inline bool Id(const preview::Value &v, unsigned &id) {
  if (!preview::Number(v, "id", 1, 4294967295.0) ||
      std::floor(v.object.at("id").number) != v.object.at("id").number)
    return false;
  id = static_cast<unsigned>(v.object.at("id").number);
  return true;
}
inline std::string Result(int id, BrowserPanel &panel, bool ok) {
  return ok ? Ok(id)
            : Fail(id, panel.Reason().empty() ? "Operación rechazada"
                                              : panel.Reason());
}
} // namespace browser_bridge

inline void RegisterBrowserBridge(Bridge &bridge, BrowserPanel &panel) {
  using namespace browser_bridge;
  bridge.RegisterHandler("browser.state", [&panel](const BridgeMessage &m) {
    preview::Value v;
    if (!Object(m, v, {"init"}))
      return Fail(m.id, "browser.state solo acepta init opcional");
    const auto init = v.object.find("init");
    if (init != v.object.end()) {
      if (init->second.type != preview::Value::Boolean)
        return Fail(m.id, "init debe ser booleano");
      // A restarted WebUI cannot answer what the previous one was shown.
      if (init->second.number == 1)
        panel.UiRestarted();
    }
    return Ok(m.id, panel.StateJson());
  });
  bridge.RegisterHandler("browser.navigate", [&panel](const BridgeMessage &m) {
    preview::Value v;
    if (!Object(m, v, {"url"}) || !preview::Text(v, "url", 8192))
      return Fail(m.id, "browser.navigate requiere url de texto");
    return Result(m.id, panel,
                  panel.Navigate(preview::Wide(v.object.at("url").string)));
  });
  bridge.RegisterHandler("browser.back", [&panel](const BridgeMessage &m) {
    preview::Value v;
    return Object(m, v, {}) ? Result(m.id, panel, panel.Back())
                            : Fail(m.id, "browser.back no admite datos");
  });
  bridge.RegisterHandler("browser.forward", [&panel](const BridgeMessage &m) {
    preview::Value v;
    return Object(m, v, {}) ? Result(m.id, panel, panel.Forward())
                            : Fail(m.id, "browser.forward no admite datos");
  });
  bridge.RegisterHandler("browser.reload", [&panel](const BridgeMessage &m) {
    preview::Value v;
    return Object(m, v, {}) ? Result(m.id, panel, panel.Reload())
                            : Fail(m.id, "browser.reload no admite datos");
  });
  bridge.RegisterHandler("browser.stop", [&panel](const BridgeMessage &m) {
    preview::Value v;
    return Object(m, v, {}) ? Result(m.id, panel, panel.Stop())
                            : Fail(m.id, "browser.stop no admite datos");
  });
  bridge.RegisterHandler("browser.tab.new", [&panel](const BridgeMessage &m) {
    preview::Value v;
    return Object(m, v, {}) ? Result(m.id, panel, panel.NewTab())
                            : Fail(m.id, "browser.tab.new no admite destino");
  });
  bridge.RegisterHandler("browser.tab.close", [&panel](const BridgeMessage &m) {
    preview::Value v;
    unsigned id = 0;
    return Object(m, v, {"id"}) && Id(v, id)
               ? Result(m.id, panel, panel.CloseTab(id))
               : Fail(m.id, "browser.tab.close requiere id de pestaña");
  });
  bridge.RegisterHandler(
      "browser.tab.select", [&panel](const BridgeMessage &m) {
        preview::Value v;
        unsigned id = 0;
        return Object(m, v, {"id"}) && Id(v, id)
                   ? Result(m.id, panel, panel.SelectTab(id))
                   : Fail(m.id, "browser.tab.select requiere id de pestaña");
      });
  bridge.RegisterHandler("browser.app.register", [&panel](
                                                     const BridgeMessage &m) {
    preview::Value v;
    if (!Object(m, v, {"url"}) || !preview::Text(v, "url", 8192))
      return Fail(m.id, "browser.app.register requiere url de texto");
    return Result(m.id, panel,
                  panel.RegisterApp(preview::Wide(v.object.at("url").string)));
  });
  bridge.RegisterHandler("browser.cover", [&panel](const BridgeMessage &m) {
    preview::Value v;
    if (!Object(m, v, {"on"}) || v.object.find("on") == v.object.end() ||
        v.object.at("on").type != preview::Value::Boolean)
      return Fail(m.id, "browser.cover requiere on booleano");
    return Result(m.id, panel, panel.SetCover(v.object.at("on").number == 1));
  });
  bridge.RegisterHandler(
      "browser.blocked.retry", [&panel](const BridgeMessage &m) {
        preview::Value v;
        return Object(m, v, {})
                   ? Result(m.id, panel, panel.RetryBlocked())
                   : Fail(m.id, "browser.blocked.retry no admite datos");
      });
  bridge.RegisterHandler(
      "browser.approval.resolve", [&panel](const BridgeMessage &m) {
        preview::Value v;
        if (!Object(m, v, {"request_id", "allow"}) ||
            !preview::Text(v, "request_id", 64) ||
            v.object.find("allow") == v.object.end() ||
            v.object.at("allow").type != preview::Value::Boolean)
          return Fail(m.id, "browser.approval.resolve requiere request_id y "
                            "allow booleano");
        return Result(m.id, panel,
                      panel.ResolveApproval(v.object.at("request_id").string,
                                            v.object.at("allow").number == 1));
      });
}
} // namespace beats
