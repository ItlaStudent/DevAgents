#ifndef BEATS_PREVIEW_POLICY_HPP
#define BEATS_PREVIEW_POLICY_HPP
// E5.25: the preview page is an untrusted document, never a bridge client.
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>
#include <windows.h>

namespace beats {
namespace preview {
constexpr size_t MessageLimit = 65536;
constexpr size_t CaptureLimit = 5 * 1024 * 1024;
// The template keeps the actual COM calls injectable without creating a
// WebView or touching a browser profile in the unit test.
template <class Settings>
inline HRESULT ApplySettings(Settings *settings, bool devTools) {
  if (!settings)
    return E_POINTER;
  HRESULT result = settings->put_AreHostObjectsAllowed(FALSE);
  if (FAILED(result))
    return result;
  result = settings->put_IsWebMessageEnabled(TRUE);
  if (FAILED(result))
    return result;
  result = settings->put_AreDefaultScriptDialogsEnabled(FALSE);
  if (FAILED(result))
    return result;
  result = settings->put_AreDefaultContextMenusEnabled(FALSE);
  if (FAILED(result))
    return result;
  result = settings->put_IsStatusBarEnabled(FALSE);
  if (FAILED(result))
    return result;
  return settings->put_AreDevToolsEnabled(devTools ? TRUE : FALSE);
}

inline bool Utf8(const std::string &s, size_t limit = MessageLimit) {
  return s.empty() ||
         (s.size() <= limit &&
          MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              static_cast<int>(s.size()), nullptr, 0) > 0);
}
inline std::wstring Wide(const std::string &s) {
  if (s.empty() || s.size() > CaptureLimit * 2 + MessageLimit)
    return L"";
  const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                                    static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0)
    return L"";
  std::wstring w(static_cast<size_t>(n), 0);
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                           static_cast<int>(s.size()), w.data(), n))
    return L"";
  return w;
}
inline std::string Narrow(const std::wstring &w, size_t limit = MessageLimit) {
  if (w.size() > limit)
    return "";
  const int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, w.data(),
                                    static_cast<int>(w.size()), nullptr, 0,
                                    nullptr, nullptr);
  if (n <= 0)
    return "";
  std::string s(static_cast<size_t>(n), 0);
  if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, w.data(),
                           static_cast<int>(w.size()), s.data(), n, nullptr,
                           nullptr))
    return "";
  return s;
}
inline bool Relative(const std::string &path) {
  if (path.empty() || path.size() > 2048 || !Utf8(path) ||
      path.front() == '/' || path.back() == '/')
    return false;
  if (path.find_first_of("\\:%?#\"<>|*") != std::string::npos)
    return false;
  for (unsigned char c : path)
    if (c < 32 || c == 127)
      return false;
  size_t start = 0;
  while (start < path.size()) {
    const size_t end = path.find('/', start);
    const std::string part =
        path.substr(start, end == std::string::npos ? end : end - start);
    if (part.empty() || part == "." || part == ".." || part.back() == '.' ||
        part.back() == ' ')
      return false;
    if (end == std::string::npos)
      break;
    start = end + 1;
  }
  return true;
}
inline bool HtmlPath(const std::string &path) {
  if (!Relative(path))
    return false;
  std::string lower = path;
  std::transform(
      lower.begin(), lower.end(), lower.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return (lower.size() >= 5 &&
          lower.compare(lower.size() - 5, 5, ".html") == 0) ||
         (lower.size() >= 4 && lower.compare(lower.size() - 4, 4, ".htm") == 0);
}

struct Value {
  enum Type { Object, String, Number, Array, Boolean, Null } type = Object;
  std::map<std::string, Value> object;
  std::string string;
  double number = 0;
  std::vector<Value> array;
};
class Parser {
  const std::string &m_text;
  size_t m_pos = 0;
  bool m_allowArrays = false;
  bool m_protocolJson = false;
  size_t m_limit = MessageLimit;
  unsigned m_depthLimit = 4;
  // Page-reachable JSON stays tightly bounded (16 keys, 128 items). Events
  // the WebView2 runtime itself emits (Fetch.requestPaused) can carry many
  // request headers: Chromium sends 20+ client hints once a site asks for
  // them (Accept-CH), and rejecting that event closed every such tab.
  size_t m_keyLimit = 16;
  size_t m_arrayLimit = 128;
  void Space() {
    while (m_pos < m_text.size() &&
           (m_text[m_pos] == ' ' || m_text[m_pos] == '\n' ||
            m_text[m_pos] == '\r' || m_text[m_pos] == '\t'))
      ++m_pos;
  }
  bool Hex(unsigned &v) {
    v = 0;
    if (m_pos + 4 > m_text.size())
      return false;
    for (int i = 0; i < 4; ++i) {
      const char c = m_text[m_pos++];
      const int digit = c >= '0' && c <= '9'   ? c - '0'
                        : c >= 'a' && c <= 'f' ? c - 'a' + 10
                        : c >= 'A' && c <= 'F' ? c - 'A' + 10
                                               : -1;
      if (digit < 0)
        return false;
      v = (v << 4) | static_cast<unsigned>(digit);
    }
    return true;
  }
  static void CodePoint(std::string &s, unsigned c) {
    if (c < 128)
      s += static_cast<char>(c);
    else if (c < 2048) {
      s += static_cast<char>(192 | (c >> 6));
      s += static_cast<char>(128 | (c & 63));
    } else if (c < 65536) {
      s += static_cast<char>(224 | (c >> 12));
      s += static_cast<char>(128 | ((c >> 6) & 63));
      s += static_cast<char>(128 | (c & 63));
    } else {
      s += static_cast<char>(240 | (c >> 18));
      s += static_cast<char>(128 | ((c >> 12) & 63));
      s += static_cast<char>(128 | ((c >> 6) & 63));
      s += static_cast<char>(128 | (c & 63));
    }
  }
  bool String(std::string &s) {
    if (m_pos >= m_text.size() || m_text[m_pos++] != '"')
      return false;
    while (m_pos < m_text.size()) {
      const unsigned char c = static_cast<unsigned char>(m_text[m_pos++]);
      if (c == '"')
        return Utf8(s, m_limit);
      if (c < 32)
        return false;
      if (c != '\\') {
        s += static_cast<char>(c);
        continue;
      }
      if (m_pos >= m_text.size())
        return false;
      const char esc = m_text[m_pos++];
      switch (esc) {
      case '"':
      case '\\':
      case '/':
        s += esc;
        break;
      case 'b':
        s += '\b';
        break;
      case 'f':
        s += '\f';
        break;
      case 'n':
        s += '\n';
        break;
      case 'r':
        s += '\r';
        break;
      case 't':
        s += '\t';
        break;
      case 'u': {
        unsigned cp;
        if (!Hex(cp))
          return false;
        if (cp >= 0xd800 && cp <= 0xdbff) {
          if (m_pos + 2 > m_text.size() || m_text.substr(m_pos, 2) != "\\u")
            return false;
          m_pos += 2;
          unsigned low;
          if (!Hex(low) || low < 0xdc00 || low > 0xdfff)
            return false;
          cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00;
        } else if (cp >= 0xdc00 && cp <= 0xdfff)
          return false;
        CodePoint(s, cp);
        break;
      }
      default:
        return false;
      }
    }
    return false;
  }
  bool Read(Value &v, unsigned depth) {
    Space();
    if (depth > m_depthLimit || m_pos >= m_text.size())
      return false;
    if (m_protocolJson) {
      for (const auto token : {"true", "false", "null"}) {
        const size_t length = std::char_traits<char>::length(token);
        if (m_text.compare(m_pos, length, token) == 0) {
          m_pos += length;
          v.type = token[0] == 'n' ? Value::Null : Value::Boolean;
          v.number = token[0] == 't' ? 1 : 0;
          return true;
        }
      }
    }
    if (m_allowArrays && m_text[m_pos] == '[') {
      v.type = Value::Array;
      ++m_pos;
      Space();
      if (m_pos < m_text.size() && m_text[m_pos] == ']') {
        ++m_pos;
        return true;
      }
      while (m_pos < m_text.size()) {
        if (v.array.size() >= m_arrayLimit)
          return false;
        Value child;
        if (!Read(child, depth + 1))
          return false;
        v.array.push_back(std::move(child));
        Space();
        if (m_pos >= m_text.size())
          return false;
        const char separator = m_text[m_pos++];
        if (separator == ']')
          return true;
        if (separator != ',')
          return false;
        Space();
      }
      return false;
    }
    if (m_text[m_pos] == '{') {
      ++m_pos;
      Space();
      if (m_pos < m_text.size() && m_text[m_pos] == '}') {
        ++m_pos;
        return true;
      }
      while (m_pos < m_text.size()) {
        std::string key;
        if (!String(key) || key.size() > 64 || v.object.size() >= m_keyLimit)
          return false;
        Space();
        if (m_pos >= m_text.size() || m_text[m_pos++] != ':')
          return false;
        Value child;
        if (!Read(child, depth + 1) ||
            !v.object.emplace(key, std::move(child)).second)
          return false;
        Space();
        if (m_pos >= m_text.size())
          return false;
        const char separator = m_text[m_pos++];
        if (separator == '}')
          return true;
        if (separator != ',')
          return false;
        Space();
      }
      return false;
    }
    if (m_text[m_pos] == '"') {
      v.type = Value::String;
      return String(v.string);
    }
    const size_t start = m_pos;
    if (m_text[m_pos] == '-')
      ++m_pos;
    if (m_pos >= m_text.size())
      return false;
    if (m_text[m_pos] == '0')
      ++m_pos;
    else {
      if (m_text[m_pos] < '1' || m_text[m_pos] > '9')
        return false;
      while (m_pos < m_text.size() && m_text[m_pos] >= '0' &&
             m_text[m_pos] <= '9')
        ++m_pos;
    }
    if (m_pos < m_text.size() && m_text[m_pos] == '.') {
      ++m_pos;
      const size_t digits = m_pos;
      while (m_pos < m_text.size() && m_text[m_pos] >= '0' &&
             m_text[m_pos] <= '9')
        ++m_pos;
      if (digits == m_pos)
        return false;
    }
    if (m_pos < m_text.size() &&
        (m_text[m_pos] == 'e' || m_text[m_pos] == 'E')) {
      ++m_pos;
      if (m_pos < m_text.size() &&
          (m_text[m_pos] == '+' || m_text[m_pos] == '-'))
        ++m_pos;
      const size_t digits = m_pos;
      while (m_pos < m_text.size() && m_text[m_pos] >= '0' &&
             m_text[m_pos] <= '9')
        ++m_pos;
      if (digits == m_pos)
        return false;
    }
    if (m_pos - start > 32)
      return false;
    const std::string raw = m_text.substr(start, m_pos - start);
    char *end = nullptr;
    errno = 0;
    v.number = std::strtod(raw.c_str(), &end);
    v.type = Value::Number;
    return end == raw.c_str() + raw.size() && errno != ERANGE &&
           std::isfinite(v.number);
  }

public:
  explicit Parser(const std::string &text, bool allowArrays = false,
                  bool protocolJson = false, size_t limit = MessageLimit,
                  unsigned depthLimit = 4, size_t keyLimit = 16,
                  size_t arrayLimit = 128)
      : m_text(text), m_allowArrays(allowArrays), m_protocolJson(protocolJson),
        m_limit(limit), m_depthLimit(std::min(depthLimit, 32u)),
        m_keyLimit(std::min<size_t>(keyLimit, 512)),
        m_arrayLimit(std::min<size_t>(arrayLimit, 1024)) {}
  bool Parse(Value &v) {
    if (m_text.size() > m_limit || !Utf8(m_text, m_limit) || !Read(v, 0))
      return false;
    Space();
    return m_pos == m_text.size();
  }
};
inline bool Keys(const Value &v, std::initializer_list<const char *> keys) {
  if (v.type != Value::Object || v.object.size() != keys.size())
    return false;
  for (const char *key : keys)
    if (v.object.find(key) == v.object.end())
      return false;
  return true;
}
inline bool Text(const Value &v, const char *key, size_t cap,
                 bool empty = false) {
  const auto it = v.object.find(key);
  return it != v.object.end() && it->second.type == Value::String &&
         it->second.string.size() <= cap &&
         (empty || !it->second.string.empty()) &&
         it->second.string.find('\0') == std::string::npos;
}
inline bool Number(const Value &v, const char *key, double low, double high) {
  const auto it = v.object.find(key);
  return it != v.object.end() && it->second.type == Value::Number &&
         std::isfinite(it->second.number) && it->second.number >= low &&
         it->second.number <= high;
}
inline bool Picked(const std::string &raw, Value &v, std::string &reason) {
  if (!Parser(raw).Parse(v)) {
    reason = "invalid_json_or_message_limit";
    return false;
  }
  if (!Keys(v, {"kind", "selector", "outerHTML", "box", "styles", "path",
                "viewport"}) ||
      !Text(v, "kind", 32) || v.object.at("kind").string != "element_picked") {
    reason = "unsupported_message";
    return false;
  }
  if (!Text(v, "selector", 1024) || !Text(v, "outerHTML", 8192) ||
      !Text(v, "path", 2048) || !Relative(v.object.at("path").string)) {
    reason = "element_text_bounds";
    return false;
  }
  const auto &viewport = v.object.at("viewport");
  const auto &box = v.object.at("box");
  if (!Keys(viewport, {"width", "height", "devicePixelRatio"}) ||
      !Number(viewport, "width", 1, 8192) ||
      !Number(viewport, "height", 1, 8192) ||
      !Number(viewport, "devicePixelRatio", 0.25, 8) ||
      viewport.object.at("width").number * viewport.object.at("height").number >
          33554432 ||
      !Keys(box, {"x", "y", "width", "height"}) || !Number(box, "x", 0, 8192) ||
      !Number(box, "y", 0, 8192) || !Number(box, "width", 0.001, 8192) ||
      !Number(box, "height", 0.001, 8192) ||
      box.object.at("x").number + box.object.at("width").number >
          viewport.object.at("width").number + 0.01 ||
      box.object.at("y").number + box.object.at("height").number >
          viewport.object.at("height").number + 0.01) {
    reason = "geometry_bounds";
    return false;
  }
  const auto &styles = v.object.at("styles");
  if (!Keys(styles, {"color", "backgroundColor", "fontSize", "fontFamily",
                     "fontWeight", "display", "position", "borderRadius"})) {
    reason = "style_schema";
    return false;
  }
  for (const auto &style : styles.object)
    if (style.second.type != Value::String ||
        style.second.string.size() > 256 ||
        style.second.string.find('\0') != std::string::npos) {
      reason = "style_bounds";
      return false;
    }
  return true;
}
inline int HexByte(wchar_t c) {
  return c >= L'0' && c <= L'9'   ? c - L'0'
         : c >= L'a' && c <= L'f' ? c - L'a' + 10
         : c >= L'A' && c <= L'F' ? c - L'A' + 10
                                  : -1;
}
inline bool UrlPath(const std::wstring &url, std::string &path) {
  const std::wstring prefix = L"https://preview.local/";
  if (url.size() > 8192 || url.compare(0, prefix.size(), prefix) != 0)
    return false;
  const std::wstring suffix = url.substr(
      prefix.size(), url.find_first_of(L"?#", prefix.size()) - prefix.size());
  const std::string encoded = Narrow(suffix);
  for (size_t i = 0; i < encoded.size(); ++i) {
    if (encoded[i] != '%') {
      path += encoded[i];
      continue;
    }
    if (i + 2 >= encoded.size())
      return false;
    const int a = HexByte(encoded[i + 1]), b = HexByte(encoded[i + 2]);
    if (a < 0 || b < 0)
      return false;
    path += static_cast<char>((a << 4) | b);
    i += 2;
  }
  return Relative(path);
}
inline bool Provenance(const std::wstring &source, const std::wstring &current,
                       const Value &picked) {
  std::string path;
  const auto field = picked.object.find("path");
  return field != picked.object.end() && field->second.type == Value::String &&
         source == current && UrlPath(source, path) &&
         path == field->second.string;
}
inline bool SafeTree(const std::wstring &root, std::string &reason) {
  const DWORD attrs = GetFileAttributesW(root.c_str());
  if (root.empty() || root.size() >= MAX_PATH ||
      attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY) ||
      (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
    reason = "preview root missing, too long, or reparse point";
    return false;
  }
  struct Entry {
    std::wstring path;
    unsigned depth;
  };
  std::vector<Entry> stack{{root, 0}};
  size_t entries = 0;
  while (!stack.empty()) {
    const Entry current = std::move(stack.back());
    stack.pop_back();
    if (current.depth > 64) {
      reason = "preview tree exceeds 64 levels";
      return false;
    }
    WIN32_FIND_DATAW data{};
    const HANDLE find = FindFirstFileW((current.path + L"\\*").c_str(), &data);
    if (find == INVALID_HANDLE_VALUE) {
      reason = "preview tree enumeration failed";
      return false;
    }
    bool ok = true;
    do {
      if (wcscmp(data.cFileName, L".") == 0 ||
          wcscmp(data.cFileName, L"..") == 0)
        continue;
      if (++entries > 100000) {
        reason = "preview tree exceeds 100000 entries";
        ok = false;
        break;
      }
      if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        reason = "preview tree contains symlink or junction";
        ok = false;
        break;
      }
      if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
        stack.push_back(
            {current.path + L"\\" + data.cFileName, current.depth + 1});
    } while (FindNextFileW(find, &data));
    const DWORD last = GetLastError();
    FindClose(find);
    if (!ok)
      return false;
    if (last != ERROR_NO_MORE_FILES) {
      reason = "preview tree enumeration interrupted";
      return false;
    }
  }
  return true;
}
// All components stay pinned while resolving. Bytes are read from the verified
// leaf handle, never by reopening its pathname in WebView2.
constexpr DWORD ResourceShare = /* B7_PIN_SHARE */ FILE_SHARE_READ;
constexpr LONGLONG ResourceLimit = 64 * 1024 * 1024;
using ResolutionHook = void (*)(const std::wstring &, void *);
struct ResourceHandles {
  HANDLE values[65]{};
  size_t count = 0;
  ResourceHandles() = default;
  ResourceHandles(const ResourceHandles &) = delete;
  ResourceHandles &operator=(const ResourceHandles &) = delete;
  ~ResourceHandles() {
    while (count)
      CloseHandle(values[--count]);
  }
};
inline std::wstring FinalPath(HANDLE handle) {
  if (!handle || handle == INVALID_HANDLE_VALUE)
    return L"";
  const DWORD size = GetFinalPathNameByHandleW(
      handle, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!size || size > 32768)
    return L"";
  std::wstring path(size, 0);
  const DWORD n = GetFinalPathNameByHandleW(
      handle, path.data(), size, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!n || n >= size)
    return L"";
  path.resize(n);
  while (path.size() > 7 && path.back() == L'\\')
    path.pop_back();
  return path;
}
inline bool Within(const std::wstring &root, const std::wstring &file) {
  /* B7_FINAL_CONFINEMENT */ return !root.empty() && root.size() < 32768 &&
      file.size() > root.size() && file.size() < 32768 &&
      CompareStringOrdinal(root.data(), static_cast<int>(root.size()),
                           file.data(), static_cast<int>(root.size()),
                           TRUE) == CSTR_EQUAL &&
      (root.back() == L'\\' || file[root.size()] == L'\\');
}
inline std::wstring CanonicalRoot(const std::wstring &root) {
  if (root.empty() || root.size() > 4096)
    return L"";
  const HANDLE h = CreateFileW(
      root.c_str(), FILE_READ_ATTRIBUTES, ResourceShare, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return L"";
  FILE_ATTRIBUTE_TAG_INFO attrs{};
  const bool regular = GetFileInformationByHandleEx(h, FileAttributeTagInfo,
                                                    &attrs, sizeof(attrs)) &&
                       (attrs.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
                       !(attrs.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
  const std::wstring path = regular ? FinalPath(h) : L"";
  CloseHandle(h);
  return path;
}
inline HANDLE OpenResource(const std::wstring &root, const std::wstring &url,
                           ResolutionHook hook = nullptr,
                           void *context = nullptr,
                           ResourceHandles *pinned = nullptr) {
  std::string relative;
  if (root.empty() || root.size() > 4096 || !UrlPath(url, relative))
    return INVALID_HANDLE_VALUE;
  // Normal callers already have the canonical root captured at configuration.
  // Normalize raw drive/UNC test paths without resolving them through links.
  std::wstring expected = root;
  if (expected.compare(0, 4, L"\\\\?\\") != 0) {
    wchar_t full[4096];
    const DWORD n = GetFullPathNameW(root.c_str(), 4096, full, nullptr);
    if (!n || n >= 4096)
      return INVALID_HANDLE_VALUE;
    expected = full;
    expected = expected.compare(0, 2, L"\\\\") == 0
                   ? L"\\\\?\\UNC\\" + expected.substr(2)
                   : L"\\\\?\\" + expected;
  }
  std::replace(expected.begin(), expected.end(), L'/', L'\\');
  while (expected.size() > 7 && expected.back() == L'\\')
    expected.pop_back();
  std::wstring path = root;
  while (path.size() > 3 && (path.back() == L'\\' || path.back() == L'/'))
    path.pop_back();
  ResourceHandles held;
  std::wstring canonical;
  size_t start = 0;
  while (true) {
    if (held.count == 65)
      return INVALID_HANDLE_VALUE;
    const bool leaf = start >= relative.size();
    const HANDLE h = CreateFileW(
        path.c_str(), GENERIC_READ, ResourceShare, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (h == INVALID_HANDLE_VALUE)
      return INVALID_HANDLE_VALUE;
    held.values[held.count++] = h;
    FILE_ATTRIBUTE_TAG_INFO attrs{};
    if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &attrs,
                                      sizeof(attrs)) ||
        (attrs.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
      return INVALID_HANDLE_VALUE;
    if (held.count == 1) {
      canonical = FinalPath(h);
      if (canonical.empty() ||
          CompareStringOrdinal(
              canonical.data(), static_cast<int>(canonical.size()),
              expected.data(), static_cast<int>(expected.size()),
              TRUE) != CSTR_EQUAL)
        return INVALID_HANDLE_VALUE;
    }
    if (leaf) {
      if ((attrs.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
          !Within(canonical, FinalPath(h)))
        return INVALID_HANDLE_VALUE;
      if (pinned) {
        if (pinned->count != 0)
          return INVALID_HANDLE_VALUE;
        for (size_t i = 0; i < held.count; ++i)
          pinned->values[i] = held.values[i];
        pinned->count = held.count;
        held.count = 0;
      } else
        --held.count; // The caller owns this checked file.
      return h;
    }
    if (!(attrs.FileAttributes & FILE_ATTRIBUTE_DIRECTORY))
      return INVALID_HANDLE_VALUE;
    if (hook)
      hook(path, context);
    const size_t end = relative.find('/', start);
    if (path.back() != L'\\')
      path += L'\\';
    path += Wide(
        relative.substr(start, end == std::string::npos ? end : end - start));
    start = end == std::string::npos ? relative.size() : end + 1;
  }
}
inline bool Resource(const std::wstring &root, const std::wstring &url,
                     ResolutionHook hook = nullptr, void *context = nullptr) {
  const HANDLE h = OpenResource(root, url, hook, context);
  if (h == INVALID_HANDLE_VALUE)
    return false;
  CloseHandle(h);
  return true;
}
inline bool ReadResource(const std::wstring &root, const std::wstring &url,
                         std::vector<unsigned char> &bytes,
                         ResolutionHook hook = nullptr,
                         void *context = nullptr) {
  bytes.clear();
  ResourceHandles held;
  const HANDLE h = OpenResource(root, url, hook, context, &held);
  if (h == INVALID_HANDLE_VALUE)
    return false;
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(h, &size) || size.QuadPart < 0 ||
      size.QuadPart > ResourceLimit)
    return false;
  bytes.resize(static_cast<size_t>(size.QuadPart));
  size_t offset = 0;
  while (offset < bytes.size()) {
    DWORD read = 0;
    const DWORD remaining = static_cast<DWORD>(bytes.size() - offset);
    if (!ReadFile(h, bytes.data() + offset, remaining, &read, nullptr) ||
        !read) {
      bytes.clear();
      return false;
    }
    offset += read;
  }
  return true;
}
inline const wchar_t *ResourceType(const std::wstring &url) {
  std::string path;
  if (!UrlPath(url, path))
    return L"application/octet-stream";
  const size_t dot = path.find_last_of('.');
  std::string ext = dot == std::string::npos ? "" : path.substr(dot);
  std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  static const std::pair<const char *, const wchar_t *> types[] = {
      {".html", L"text/html; charset=utf-8"},
      {".htm", L"text/html; charset=utf-8"},
      {".css", L"text/css; charset=utf-8"},
      {".js", L"text/javascript; charset=utf-8"},
      {".mjs", L"text/javascript; charset=utf-8"},
      {".json", L"application/json"},
      {".map", L"application/json"},
      {".png", L"image/png"},
      {".jpg", L"image/jpeg"},
      {".jpeg", L"image/jpeg"},
      {".webp", L"image/webp"},
      {".gif", L"image/gif"},
      {".svg", L"image/svg+xml"},
      {".ico", L"image/x-icon"},
      {".woff", L"font/woff"},
      {".woff2", L"font/woff2"},
      {".ttf", L"font/ttf"},
      {".otf", L"font/otf"},
      {".wasm", L"application/wasm"},
      {".txt", L"text/plain; charset=utf-8"},
      {".mp4", L"video/mp4"},
      {".webm", L"video/webm"},
      {".mp3", L"audio/mpeg"},
      {".wav", L"audio/wav"},
      {".ogg", L"application/ogg"}};
  for (const auto &type : types)
    if (ext == type.first)
      return type.second;
  return L"application/octet-stream";
}
inline std::string Base64(const unsigned char *bytes, size_t count) {
  if (!bytes || count == 0 || count > CaptureLimit)
    return "";
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((count + 2) / 3) * 4);
  for (size_t i = 0; i < count; i += 3) {
    const unsigned a = bytes[i], b = i + 1 < count ? bytes[i + 1] : 0,
                   c = i + 2 < count ? bytes[i + 2] : 0;
    out += alphabet[a >> 2];
    out += alphabet[((a & 3) << 4) | (b >> 4)];
    out += i + 1 < count ? alphabet[((b & 15) << 2) | (c >> 6)] : '=';
    out += i + 2 < count ? alphabet[c & 63] : '=';
  }
  return out;
}
} // namespace preview
} // namespace beats
#endif
