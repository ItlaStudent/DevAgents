#pragma once
// T6 (13-nov-2026,): piezas puras de las herramientas del agente
// en el navegador integrado que no necesitan WebView2 y se prueban aparte
// (test_browser_panel_agent.cpp):
// - registro acotado de consola y de red de cada pestaña (browser_console,
//   browser_network), con cursor y sin cuerpos ni cabeceras;
// - redacción de direcciones (credenciales y parámetros con token, key,
//   secret...), igual para la red que para cualquier URL que vea el modelo;
// - parámetros CDP de browser_viewport y browser_color_scheme;
// - lectura de la captura PNG (base64 y dimensiones) de browser_screenshot.
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <set>
#include <string>

namespace beats {
namespace browser_agent {

// JSON de un texto ya en UTF-8. Los caracteres de control se escapan.
inline std::string Quote(const std::string &s) {
  std::string out = "\"";
  for (const unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else if (c == '\t') {
      out += "\\t";
    } else if (c < 0x20 || c == 0x7f) {
      char hex[8];
      std::snprintf(hex, sizeof hex, "\\u%04x", c);
      out += hex;
    } else {
      out += static_cast<char>(c);
    }
  }
  return out + "\"";
}

// Recorta a `cap` bytes sin partir un carácter UTF-8.
inline std::string Clip(const std::string &s, size_t cap) {
  if (s.size() <= cap)
    return s;
  size_t end = cap;
  while (end > 0 && (static_cast<unsigned char>(s[end]) & 0xC0) == 0x80)
    --end;
  return s.substr(0, end) + "\xE2\x80\xA6";
}

// Nombre de parámetro que suele llevar un secreto.
inline bool SecretName(const std::string &name) {
  std::string lower;
  for (const unsigned char c : name)
    lower += static_cast<char>(std::tolower(c));
  for (const char *word : {"token", "key", "secret", "password", "passwd",
                           "auth", "credential", "signature", "session"})
    if (lower.find(word) != std::string::npos)
      return true;
  return false;
}

// Pares nombre=valor separados por '&'; el valor de un nombre secreto pasa a
// ser REDACTED.
inline std::string RedactPairs(const std::string &pairs) {
  std::string out;
  size_t start = 0;
  while (start <= pairs.size()) {
    size_t end = pairs.find('&', start);
    if (end == std::string::npos)
      end = pairs.size();
    const std::string pair = pairs.substr(start, end - start);
    const size_t eq = pair.find('=');
    if (!out.empty() || start > 0)
      out += '&';
    if (eq != std::string::npos && eq + 1 < pair.size() &&
        SecretName(pair.substr(0, eq)))
      out += pair.substr(0, eq + 1) + "REDACTED";
    else
      out += pair;
    if (end == pairs.size())
      break;
    start = end + 1;
  }
  return out;
}

// Dirección que puede ver el modelo: sin usuario ni contraseña en la
// autoridad, sin valores de parámetros secretos (consulta y fragmento) y
// recortada a 2048 bytes.
inline std::string RedactUrl(const std::string &url) {
  std::string out = url;
  const size_t scheme = out.find("://");
  if (scheme != std::string::npos) {
    const size_t authority = scheme + 3;
    size_t end = out.find_first_of("/?#", authority);
    if (end == std::string::npos)
      end = out.size();
    const size_t at = out.rfind('@', end - 1);
    if (end > authority && at != std::string::npos && at >= authority)
      out = out.substr(0, authority) + "REDACTED" + out.substr(at);
  }
  const size_t hash = out.find('#');
  std::string fragment;
  if (hash != std::string::npos) {
    fragment = out.substr(hash + 1);
    out = out.substr(0, hash);
  }
  const size_t question = out.find('?');
  if (question != std::string::npos)
    out = out.substr(0, question + 1) + RedactPairs(out.substr(question + 1));
  if (hash != std::string::npos)
    out +=
        "#" + (fragment.find('=') != std::string::npos ? RedactPairs(fragment)
                                                       : fragment);
  return Clip(out, 2048);
}

struct ConsoleEntry {
  uint64_t seq = 0;
  std::string level, text, url;
  int line = 0;
};
struct NetworkEntry {
  uint64_t seq = 0;
  std::string requestId, method, url, type, failure;
  int status = 0;
};

// Registro acotado de una pestaña: lo más antiguo se descarta y se cuenta.
template <class T> struct Ring {
  static constexpr size_t Capacity = 200;
  std::deque<T> items;
  uint64_t next = 1, dropped = 0;
  T &Push(T entry) {
    entry.seq = next++;
    if (items.size() >= Capacity) {
      items.pop_front();
      ++dropped;
    }
    items.push_back(std::move(entry));
    return items.back();
  }
};

// Nivel de browser_console para un `type` de Runtime.consoleAPICalled.
inline const char *ConsoleLevel(const std::string &type) {
  if (type == "error" || type == "assert")
    return "error";
  if (type == "warning")
    return "warning";
  if (type == "debug")
    return "debug";
  if (type == "info")
    return "info";
  return "log";
}

// Bytes de entradas por respuesta de browser_console / browser_network.
constexpr size_t Budget = 96 * 1024;

// Cursor: número de secuencia ya leído ("" = desde el principio).
inline bool ParseCursor(const std::string &cursor, uint64_t &after) {
  after = 0;
  if (cursor.empty())
    return true;
  if (cursor.size() > 19)
    return false;
  for (const char c : cursor) {
    if (c < '0' || c > '9')
      return false;
    after = after * 10 + static_cast<uint64_t>(c - '0');
  }
  return true;
}

// Resultado de browser_console. `levels` vacío = todos.
inline std::string ConsoleJson(const Ring<ConsoleEntry> &ring, uint64_t after,
                               const std::set<std::string> &levels,
                               size_t limit) {
  std::string entries;
  size_t count = 0;
  uint64_t last = after;
  bool more = false;
  for (const auto &e : ring.items) {
    if (e.seq <= after)
      continue;
    if (!levels.empty() && !levels.count(e.level)) {
      last = e.seq;
      continue;
    }
    // El resultado viaja al motor (128 KiB por respuesta): tope de 96 KiB.
    if (count == limit || entries.size() > Budget) {
      more = true;
      break;
    }
    if (count)
      entries += ',';
    entries += "{\"seq\":" + std::to_string(e.seq) +
               ",\"level\":" + Quote(e.level) + ",\"text\":" + Quote(e.text);
    if (!e.url.empty())
      entries +=
          ",\"url\":" + Quote(e.url) + ",\"line\":" + std::to_string(e.line);
    entries += '}';
    ++count;
    last = e.seq;
  }
  return "{\"entries\":[" + entries +
         "],\"next_cursor\":" + Quote(std::to_string(last)) +
         ",\"more\":" + (more ? "true" : "false") +
         ",\"dropped\":" + std::to_string(ring.dropped) + "}";
}

// Resultado de browser_network. `filter` vacío = todas; se compara con la
// dirección ya redactada.
inline std::string NetworkJson(const Ring<NetworkEntry> &ring, uint64_t after,
                               const std::string &filter, size_t limit) {
  std::string entries;
  size_t count = 0;
  uint64_t last = after;
  bool more = false;
  for (const auto &e : ring.items) {
    if (e.seq <= after)
      continue;
    if (!filter.empty() && e.url.find(filter) == std::string::npos) {
      last = e.seq;
      continue;
    }
    // El resultado viaja al motor (128 KiB por respuesta): tope de 96 KiB.
    if (count == limit || entries.size() > Budget) {
      more = true;
      break;
    }
    if (count)
      entries += ',';
    entries += "{\"seq\":" + std::to_string(e.seq) +
               ",\"method\":" + Quote(e.method) + ",\"url\":" + Quote(e.url) +
               ",\"type\":" + Quote(e.type) +
               ",\"status\":" + std::to_string(e.status);
    if (!e.failure.empty())
      entries += ",\"failure\":" + Quote(e.failure);
    entries += '}';
    ++count;
    last = e.seq;
  }
  return "{\"entries\":[" + entries +
         "],\"next_cursor\":" + Quote(std::to_string(last)) +
         ",\"more\":" + (more ? "true" : "false") +
         ",\"dropped\":" + std::to_string(ring.dropped) + "}";
}

// browser_viewport: método y parámetros CDP. preset desktop quita la
// emulación. Devuelve false ante una combinación no válida.
struct Viewport {
  bool clear = false;
  int width = 0, height = 0;
  double dpr = 1;
  bool mobile = false, landscape = false;
};
inline bool ViewportFor(const std::string &preset, bool custom, int width,
                        int height, double dpr, bool mobile,
                        const std::string &orientation, Viewport &out) {
  out = Viewport{};
  if (!orientation.empty() && orientation != "portrait" &&
      orientation != "landscape")
    return false;
  out.landscape = orientation == "landscape";
  if (custom == !preset.empty())
    return false;
  if (preset == "desktop") {
    out.clear = true;
    return orientation.empty();
  }
  if (preset == "mobile")
    out = Viewport{false, 390, 844, 3, true, out.landscape};
  else if (preset == "tablet")
    out = Viewport{false, 820, 1180, 2, true, out.landscape};
  else if (custom) {
    if (width < 240 || width > 2560 || height < 240 || height > 2560 ||
        !(dpr >= 1 && dpr <= 3))
      return false;
    out = Viewport{false, width, height, dpr, mobile, out.landscape};
  } else
    return false;
  if (!orientation.empty() && out.landscape != (out.width > out.height))
    std::swap(out.width, out.height);
  return true;
}
inline std::string ViewportParams(const Viewport &v) {
  if (v.clear)
    return "{}";
  char dpr[32];
  std::snprintf(dpr, sizeof dpr, "%.2f", v.dpr);
  return "{\"width\":" + std::to_string(v.width) +
         ",\"height\":" + std::to_string(v.height) +
         ",\"deviceScaleFactor\":" + dpr +
         ",\"mobile\":" + (v.mobile ? "true" : "false") +
         ",\"screenOrientation\":{\"type\":" +
         (v.landscape ? "\"landscapePrimary\",\"angle\":90"
                      : "\"portraitPrimary\",\"angle\":0") +
         "}}";
}

// browser_color_scheme: parámetros de Emulation.setEmulatedMedia. system
// quita la emulación (valor vacío).
inline bool ColorSchemeParams(const std::string &mode, std::string &out) {
  if (mode != "light" && mode != "dark" && mode != "system")
    return false;
  out = "{\"features\":[{\"name\":\"prefers-color-scheme\",\"value\":" +
        Quote(mode == "system" ? "" : mode) + "}]}";
  return true;
}

// Base64 estricto (con relleno) de Page.captureScreenshot.
inline bool Base64Decode(const std::string &in, std::string &out) {
  out.clear();
  if (in.size() % 4)
    return false;
  const auto value = [](char c) -> int {
    if (c >= 'A' && c <= 'Z')
      return c - 'A';
    if (c >= 'a' && c <= 'z')
      return c - 'a' + 26;
    if (c >= '0' && c <= '9')
      return c - '0' + 52;
    if (c == '+')
      return 62;
    if (c == '/')
      return 63;
    return -1;
  };
  out.reserve(in.size() / 4 * 3);
  for (size_t i = 0; i < in.size(); i += 4) {
    int v[4];
    int pad = 0;
    for (int k = 0; k < 4; ++k) {
      const char c = in[i + k];
      if (c == '=' && i + 4 == in.size() && k >= 2) {
        v[k] = 0;
        ++pad;
        continue;
      }
      if (pad)
        return false;
      v[k] = value(c);
      if (v[k] < 0)
        return false;
    }
    const uint32_t n = (static_cast<uint32_t>(v[0]) << 18) |
                       (static_cast<uint32_t>(v[1]) << 12) |
                       (static_cast<uint32_t>(v[2]) << 6) |
                       static_cast<uint32_t>(v[3]);
    out += static_cast<char>((n >> 16) & 0xFF);
    if (pad < 2)
      out += static_cast<char>((n >> 8) & 0xFF);
    if (pad < 1)
      out += static_cast<char>(n & 0xFF);
  }
  return true;
}

// Dimensiones de un PNG (cabecera IHDR). false si no es un PNG.
inline bool PngSize(const std::string &png, uint32_t &width, uint32_t &height) {
  static const unsigned char magic[8] = {0x89, 'P',  'N',  'G',
                                         '\r', '\n', 0x1a, '\n'};
  if (png.size() < 24 ||
      !std::equal(magic, magic + 8,
                  reinterpret_cast<const unsigned char *>(png.data())) ||
      png.compare(12, 4, "IHDR") != 0)
    return false;
  const auto be = [&](size_t at) {
    const auto *b = reinterpret_cast<const unsigned char *>(png.data()) + at;
    return (static_cast<uint32_t>(b[0]) << 24) |
           (static_cast<uint32_t>(b[1]) << 16) |
           (static_cast<uint32_t>(b[2]) << 8) | static_cast<uint32_t>(b[3]);
  };
  width = be(16);
  height = be(20);
  return width > 0 && height > 0;
}

} // namespace browser_agent
} // namespace beats
