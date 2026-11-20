#include "browser_dispatch.hpp"
#include "browser_panel.hpp"
#include "preview_policy.hpp"
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <thread>

namespace beats {
namespace {
using V = preview::Value;
std::string Quote(const std::string &s) {
  std::string out = "\"";
  static constexpr char hex[] = "0123456789abcdef";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 32) {
      out += "\\u00";
      out += hex[c >> 4];
      out += hex[c & 15];
    } else
      out += static_cast<char>(c);
  }
  return out + '"';
}
std::string Json(const V &v) {
  switch (v.type) {
  case V::String:
    return Quote(v.string);
  case V::Number: {
    std::ostringstream out;
    out.precision(17);
    out << v.number;
    return out.str();
  }
  case V::Boolean:
    return v.number ? "true" : "false";
  case V::Null:
    return "null";
  case V::Array: {
    std::string out = "[";
    for (const auto &x : v.array) {
      if (out.size() > 1)
        out += ',';
      out += Json(x);
    }
    return out + ']';
  }
  case V::Object: {
    std::string out = "{";
    for (const auto &x : v.object) {
      if (out.size() > 1)
        out += ',';
      out += Quote(x.first) + ':' + Json(x.second);
    }
    return out + '}';
  }
  }
  return "null";
}
std::string Text(const V &v, const char *key) {
  auto it = v.object.find(key);
  return it != v.object.end() && it->second.type == V::String
             ? it->second.string
             : "";
}
unsigned long long Number(const V &v, const char *key) {
  auto it = v.object.find(key);
  return it != v.object.end() && it->second.type == V::Number &&
                 it->second.number >= 0 &&
                 it->second.number <= 9007199254740991.0
             ? static_cast<unsigned long long>(it->second.number)
             : 0;
}
bool Parse(const CoreResult &r, V &v) {
  if (!r.ok() ||
      !preview::Parser(r.json, true, true, 1024 * 1024, 16).Parse(v) ||
      v.type != V::Object)
    return false;
  auto ok = v.object.find("ok");
  return ok != v.object.end() && ok->second.type == V::Boolean &&
         ok->second.number == 1;
}
std::string Failure(const std::string &id, const std::string &code) {
  return "{\"request_id\":" + Quote(id) +
         ",\"ok\":false,\"error\":{\"code\":" + Quote(code) +
         ",\"effect_status\":\"not_started\"}}";
}
} // namespace

struct BrowserDispatch::Impl : std::enable_shared_from_this<Impl> {
  struct Session {
    HWND hwnd = nullptr;
    long long order = 0;
    std::string root, instance;
    std::atomic<bool> valid{true};
    // Transport lane only. The capability is never included in a UI packet.
    std::string capability;
    unsigned long long generation = 0;
    std::string lastState;
    struct Claim {
      std::string tool;
      ULONGLONG started = 0;
    };
    std::map<std::string, Claim> claims; // Transport only; sanitized metadata.
    // STA only.
    std::map<std::string, V> running;
    std::set<std::string> eventsSeen;
    std::deque<std::string> eventHistory;
  };
  struct Packet {
    std::shared_ptr<Session> session;
    V body;
    bool attached = false;
  };
  struct Command {
    std::shared_ptr<Session> session;
    std::string action, payload;
  };
  Backend backend;
  std::mutex mutex;
  std::condition_variable cv;
  std::deque<Command> commands;
  std::map<HWND, std::shared_ptr<Session>> sessions;
  std::map<LPARAM, std::unique_ptr<Packet>> packets;
  LPARAM nextPacket = 0;
  bool stopped = false;
  std::thread thread;

  explicit Impl(Backend b) : backend(std::move(b)) {}
  bool Queue(Command c) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (stopped || commands.size() >= 256)
        return false;
      commands.push_back(std::move(c));
    }
    cv.notify_one();
    return true;
  }
  void Post(const std::shared_ptr<Session> &s, V body, bool attached = false) {
    LPARAM token;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (stopped)
        return;
      if (packets.size() >= 256) {
        s->valid = false;
        OutputDebugStringA("browser.v1: STA transport queue full\n");
        return;
      }
      token = ++nextPacket;
      packets.emplace(token, std::make_unique<Packet>(
                                 Packet{s, std::move(body), attached}));
    }
    if (!PostMessageW(s->hwnd, Message, 0, token)) {
      {
        std::lock_guard<std::mutex> lock(mutex);
        packets.erase(token);
      }
      s->valid = false;
      if (!s->capability.empty() && backend.control)
        backend.control("{\"schema\":\"browser.v1\",\"host_capability\":" +
                        Quote(s->capability) + ",\"action\":\"close\"}");
    }
  }
  void TerminalEvent(const std::shared_ptr<Session> &s, const std::string &id,
                     const std::string &code) {
    auto it = s->claims.find(id);
    if (it == s->claims.end())
      return;
    const std::string raw =
        "{\"transport_event\":{\"push\":\"browser.transport.v1\",\"payload\":{"
        "\"request_id\":" +
        Quote(id) + ",\"tool\":" + Quote(it->second.tool) +
        ",\"state\":" + Quote(code == "completed" ? "completed" : "failed") +
        ",\"code\":" + Quote(code == "completed" ? "" : code) +
        ",\"elapsed_ms\":" +
        std::to_string(GetTickCount64() - it->second.started) +
        ",\"order_id\":" + std::to_string(s->order) + "}}}";
    V event;
    if (preview::Parser(raw, true, true).Parse(event))
      Post(s, std::move(event));
    s->claims.erase(it);
  }
  void Run() {
    for (;;) {
      std::deque<Command> todo;
      std::vector<std::shared_ptr<Session>> live;
      bool stop;
      {
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait_for(lock, std::chrono::milliseconds(25),
                    [&] { return stopped || !commands.empty(); });
        todo.swap(commands);
        for (auto &s : sessions)
          live.push_back(s.second);
        stop = stopped;
      }
      for (auto &c : todo) {
        auto &s = c.session;
        if (c.action == "attach") {
          if (!s->valid || !backend.attach)
            continue;
          const auto registerHost = [&] {
            return backend.attach("{\"schema\":\"browser.v1\",\"order_id\":" +
                                  std::to_string(s->order) +
                                  ",\"workspace_root\":" + Quote(s->root) +
                                  ",\"host_instance\":" + Quote(s->instance) +
                                  "}");
          };
          auto raw = registerHost();
          V v;
          bool registered = Parse(raw, v);
          if (!registered && backend.resolveRoot) {
            const auto root = backend.resolveRoot(s->order);
            V location;
            if (root.ok() && preview::Parser(root.json).Parse(location) &&
                !Text(location, "path").empty()) {
              s->root = Text(location, "path");
              raw = registerHost();
              v = V{};
              registered = Parse(raw, v);
            }
          }
          if (registered) {
            s->capability = Text(v, "host_capability");
            s->generation = Number(v, "host_generation");
            v.object.erase("host_capability");
            Post(s, std::move(v), true);
          } else {
            V fail;
            preview::Parser(
                "{\"state\":\"session_closed\",\"control_epoch\":0}", true,
                true)
                .Parse(fail);
            Post(s, std::move(fail));
          }
        } else if (c.action == "complete") {
          if (backend.complete && !s->capability.empty()) {
            const auto result = backend.complete(s->capability, c.payload);
            if (!result.ok()) {
              OutputDebugStringA("browser.v1: completion rejected by motor\n");
            } else {
              V completed;
              if (preview::Parser(c.payload, true, true, 131072, 16, 32, 512)
                      .Parse(completed)) {
                const auto failure = completed.object.find("error");
                TerminalEvent(s, Text(completed, "request_id"),
                              failure == completed.object.end()
                                  ? "completed"
                                  : Text(failure->second, "code"));
              }
            }
          }
        } else if (backend.control && !s->capability.empty()) {
          V v;
          const auto result = backend.control(
              "{\"schema\":\"browser.v1\",\"host_capability\":" +
              Quote(s->capability) + ",\"action\":" + Quote(c.action) +
              (c.payload.empty() ? "" : ",\"tab_id\":" + Quote(c.payload)) +
              "}");
          if (s->valid && Parse(result, v))
            Post(s, std::move(v));
        }
      }
      if (stop) {
        for (auto &s : live)
          if (backend.control && !s->capability.empty())
            backend.control("{\"schema\":\"browser.v1\",\"host_capability\":" +
                            Quote(s->capability) +
                            ",\"action\":\"disconnect\"}");
        return;
      }
      for (auto &s : live) {
        if (s->capability.empty() || !backend.poll)
          continue;
        if (!IsWindow(s->hwnd)) {
          if (backend.control)
            backend.control("{\"schema\":\"browser.v1\",\"host_capability\":" +
                            Quote(s->capability) + ",\"action\":\"close\"}");
          s->capability.clear();
          continue;
        }
        V v;
        if (!Parse(backend.poll(s->capability), v)) {
          std::vector<std::string> ids;
          for (const auto &claim : s->claims)
            ids.push_back(claim.first);
          for (const auto &id : ids)
            TerminalEvent(s, id, "host_unavailable");
          V closed;
          const std::string body = "{\"transport_error\":\"host_unavailable\"}";
          preview::Parser(body).Parse(closed);
          Post(s, std::move(closed));
          s->capability.clear();
          continue;
        }
        const auto requests = v.object.find("requests");
        if (requests != v.object.end() && requests->second.type == V::Array)
          for (const auto &request : requests->second.array)
            if (Number(request, "order_id") ==
                static_cast<unsigned long long>(s->order))
              s->claims.emplace(
                  Text(request, "request_id"),
                  Session::Claim{Text(request, "tool"), GetTickCount64()});
        const auto terminals = v.object.find("terminal_requests");
        if (terminals != v.object.end() && terminals->second.type == V::Array)
          for (const auto &terminal : terminals->second.array)
            TerminalEvent(s, Text(terminal, "request_id"),
                          Text(terminal, "code"));
        // Requests and cancellation snapshots are copied before posting.
        const auto state = Json(v);
        if (state != s->lastState) {
          s->lastState = state;
          const auto events = v.object.find("events");
          if (events != v.object.end() && events->second.type == V::Array &&
              !events->second.array.empty()) {
            V delivery;
            delivery.object.emplace("motor_events", events->second);
            Post(s, std::move(delivery));
            v.object.erase("events");
          }
          if (s->valid)
            Post(s, std::move(v));
        }
      }
    }
  }
  void Finish(const std::shared_ptr<Session> &s, const V &request,
              std::string result) {
    V v;
    if (!preview::Parser(result, true, true, 131072, 16, 32, 512).Parse(v) ||
        v.type != V::Object) {
      result = Failure(Text(request, "request_id"), "protocol_error");
      v = V{};
      if (!preview::Parser(result, true, true, 131072, 16, 32, 512).Parse(v))
        return;
    }
    for (const char *key : {"order_id", "host_generation", "control_epoch"})
      v.object[key] = request.object.at(key);
    V schema;
    schema.type = V::String;
    schema.string = "browser.v1";
    v.object["schema"] = std::move(schema);
    if (!Queue({s, "complete", Json(v)}))
      OutputDebugStringA("browser.v1: completion lane stopped or full\n");
  }
};

BrowserDispatch::BrowserDispatch(Backend b)
    : m_impl(std::make_shared<Impl>(std::move(b))) {
  m_impl->thread = std::thread([impl = m_impl] { impl->Run(); });
}
BrowserDispatch::~BrowserDispatch() { Stop(); }
bool BrowserDispatch::Attach(HWND hwnd, long long order,
                             const std::string &worktree) {
  if (!hwnd || !IsWindow(hwnd) || order <= 0 || worktree.empty())
    return false;
  Detach(hwnd);
  GUID id{};
  if (FAILED(CoCreateGuid(&id)))
    return false;
  wchar_t guid[40]{};
  if (!StringFromGUID2(id, guid, 40))
    return false;
  auto s = std::make_shared<Impl::Session>();
  s->hwnd = hwnd;
  s->order = order;
  s->root = worktree;
  s->instance = preview::Narrow(guid);
  {
    std::lock_guard<std::mutex> lock(m_impl->mutex);
    if (m_impl->stopped)
      return false;
    m_impl->sessions[hwnd] = s;
  }
  return m_impl->Queue({s, "attach", ""});
}
bool BrowserDispatch::Control(HWND hwnd, const std::string &action,
                              const std::string &tab) {
  if (action != "take" && action != "resume" && action != "close" &&
      action != "tab_closed" && action != "renderer_failed")
    return false;
  std::shared_ptr<Impl::Session> s;
  {
    std::lock_guard<std::mutex> lock(m_impl->mutex);
    auto it = m_impl->sessions.find(hwnd);
    if (it == m_impl->sessions.end() || !it->second->valid)
      return false;
    s = it->second;
  }
  return m_impl->Queue({s, action, tab});
}
long long BrowserDispatch::AttachedOrder(HWND hwnd) const {
  std::lock_guard<std::mutex> lock(m_impl->mutex);
  const auto it = m_impl->sessions.find(hwnd);
  return it != m_impl->sessions.end() && it->second->valid ? it->second->order
                                                           : 0;
}

void BrowserDispatch::Detach(HWND hwnd) {
  std::shared_ptr<Impl::Session> s;
  {
    std::lock_guard<std::mutex> lock(m_impl->mutex);
    auto it = m_impl->sessions.find(hwnd);
    if (it == m_impl->sessions.end())
      return;
    s = it->second;
    s->valid = false;
    for (auto queued = m_impl->packets.begin();
         queued != m_impl->packets.end();) {
      if (queued->second->session == s)
        queued = m_impl->packets.erase(queued);
      else
        ++queued;
    }
  }
  m_impl->Queue({s, "close", ""});
}
void BrowserDispatch::Deliver(LPARAM value, BrowserPanel *panel,
                              EventSink sink) {
  std::unique_ptr<Impl::Packet> packet;
  {
    std::lock_guard<std::mutex> lock(m_impl->mutex);
    const auto it = m_impl->packets.find(value);
    if (it == m_impl->packets.end())
      return;
    packet = std::move(it->second);
    m_impl->packets.erase(it);
  }
  if (!packet)
    return;
  const auto s = packet->session;
  const auto &body = packet->body;
  const auto motorEvents = body.object.find("motor_events");
  if (motorEvents != body.object.end() &&
      motorEvents->second.type == V::Array) {
    for (const auto &event : motorEvents->second.array) {
      const auto id = Text(event, "request_id");
      const auto key = id + ':' + std::to_string(Number(event, "sequence"));
      if (id.empty() || !s->eventsSeen.insert(key).second)
        continue;
      s->eventHistory.push_back(key);
      if (s->eventHistory.size() > 256) {
        s->eventsSeen.erase(s->eventHistory.front());
        s->eventHistory.pop_front();
      }
      const auto state = Text(event, "state");
      if (sink && (state == "request" || state == "started" ||
                   state == "completed" || state == "failed"))
        sink("{\"push\":\"browser." + state +
             ".v1\",\"payload\":" + Json(event) + "}");
    }
    return;
  }
  const auto event = body.object.find("transport_event");
  if (event != body.object.end()) {
    if (sink)
      sink(Json(event->second));
    return;
  }
  if (!s->valid)
    return;
  if (!panel) {
    s->valid = false;
    m_impl->Queue({s, "close", ""});
    return;
  }
  const auto transportError = Text(body, "transport_error");
  if (!transportError.empty()) {
    std::vector<std::string> ids;
    for (const auto &pending : s->running)
      ids.push_back(pending.first);
    for (const auto &id : ids)
      panel->CancelAgent(id, transportError);
    panel->HumanControl();
    s->valid = false;
    return;
  }
  const auto canonicalRoot = Text(body, "workspace_root");
  // 12-nov: una carpeta que no pasa la comprobación (más de 100 000 entradas
  // o con enlaces simbólicos, p. ej. node_modules de pnpm) ya no desconecta
  // el navegador de la orden: solo se queda sin archivos locales
  // (SetFixtureRoot deja la raíz vacía) y el agente sigue pudiendo abrir
  // direcciones http(s) y su servidor local.
  if (packet->attached && !canonicalRoot.empty())
    panel->SetFixtureRoot(preview::Wide(canonicalRoot));
  if (packet->attached)
    panel->SetSessionIdentity(Text(body, "session_id"), Text(body, "tab_id"));
  const auto state = Text(body, "state");
  if (!state.empty())
    panel->SetAgentState(state, Number(body, "control_epoch"));
  const auto active = body.object.find("active_request_ids");
  const auto terminal = body.object.find("terminal_requests");
  if (active != body.object.end() && active->second.type == V::Array) {
    std::vector<std::string> cancelled;
    for (const auto &running : s->running) {
      bool found = false;
      for (const auto &id : active->second.array)
        found = found || (id.type == V::String && id.string == running.first);
      if (!found)
        cancelled.push_back(running.first);
    }
    for (const auto &id : cancelled) {
      std::string code = state == "user_control" ? "user_control" : "cancelled";
      if (terminal != body.object.end() && terminal->second.type == V::Array)
        for (const auto &done : terminal->second.array)
          if (Text(done, "request_id") == id &&
              Text(done, "code") != "completed")
            code = Text(done, "code");
      panel->CancelAgent(id, code);
    }
  }
  const auto requests = body.object.find("requests");
  if (requests == body.object.end() || requests->second.type != V::Array)
    return;
  for (const auto &request : requests->second.array) {
    const auto id = Text(request, "request_id");
    if (id.empty() ||
        Number(request, "order_id") !=
            static_cast<unsigned long long>(s->order) ||
        !request.object.count("host_generation") ||
        !request.object.count("control_epoch"))
      continue;
    if (!s->running.emplace(id, request).second)
      continue;
    const std::weak_ptr<Impl> weak = m_impl;
    if (sink)
      sink("{\"push\":\"browser.transport.v1\",\"payload\":{\"request_id\":" +
           Quote(id) + ",\"tool\":" + Quote(Text(request, "tool")) +
           ",\"state\":\"started\",\"order_id\":" + std::to_string(s->order) +
           "}}");
    panel->ExecuteAgent(Json(request),
                        [weak, s, request, id](std::string result) {
                          auto impl = weak.lock();
                          if (!impl || !s->running.erase(id))
                            return;
                          impl->Finish(s, request, result);
                        });
  }
}
void BrowserDispatch::Stop() {
  {
    std::lock_guard<std::mutex> lock(m_impl->mutex);
    m_impl->stopped = true;
    for (auto &session : m_impl->sessions)
      session.second->valid = false;
  }
  m_impl->cv.notify_all();
  if (m_impl->thread.joinable())
    m_impl->thread.join();
  std::lock_guard<std::mutex> lock(m_impl->mutex);
  m_impl->packets.clear();
}
} // namespace beats
