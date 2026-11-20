#pragma once
#include "origin_policy.hpp"
#include <cstdio>
#include <cstring>
#include <set>
#include <vector>
#include <wincrypt.h>

namespace beats::browser {
// User-scoped DPAPI with product entropy authenticates the whole origin set.
// This protects file edits, not code already executing as the same user.
class Policy {
  std::set<std::wstring> m_approved, m_apps;
  static constexpr DWORD MaxLedgerBytes = 131072;
  static constexpr char LedgerMagic[8] = {'B', 'E', 'A', 'T',
                                          'S', 'O', 'A', '1'};
  static DATA_BLOB Entropy() {
    static const char product[] =
        "DevAgents.DevAgents.Browser.OriginApproval.v1";
    return {sizeof(product),
            reinterpret_cast<BYTE *>(const_cast<char *>(product))};
  }
  static bool RejectLedger(const char *reason, DWORD error = 0) {
    char message[256]{};
    std::snprintf(message, sizeof(message),
                  "[BrowserPolicy] ledger rejected: %s (Win32=%lu)\n", reason,
                  static_cast<unsigned long>(error));
    std::fputs(message, stderr);
    OutputDebugStringA(message);
    return false;
  }
  static bool RegularLedger(HANDLE file) {
    BY_HANDLE_FILE_INFORMATION info{};
    return GetFileInformationByHandle(file, &info) &&
           info.nNumberOfLinks == 1 &&
           !(info.dwFileAttributes &
             (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY));
  }

public:
  static bool StaticAssetPath(const std::string &path) {
    if (path.empty() || path.size() > 2048 ||
        path.find('\\') != std::string::npos)
      return false;
    size_t start = 0;
    while (start < path.size()) {
      if (path[start] == '.' || path[start] == '/')
        return false;
      const auto end = path.find('/', start);
      if (end == std::string::npos)
        break;
      start = end + 1;
    }
    const auto dot = path.find_last_of('.');
    if (dot == std::string::npos)
      return false;
    auto ext = path.substr(dot);
    for (auto &c : ext)
      if (c >= 'A' && c <= 'Z')
        c += ('a' - 'A');
    for (const auto allowed :
         {".html", ".htm", ".css", ".js",  ".mjs",  ".png",   ".jpg", ".jpeg",
          ".webp", ".gif", ".svg", ".ico", ".woff", ".woff2", ".ttf", ".otf",
          ".wasm", ".mp3", ".wav", ".ogg", ".mp4",  ".webm"})
      if (ext == allowed)
        return true;
    return false;
  }
  static constexpr size_t MaxOrigins = 256;
  static std::wstring Origin(const std::wstring &url) {
    security::HttpOrigin o;
    if (url.size() > 8192 || !security::ParseHttpUrl(url, o) ||
        o.host == L"devagents.local" || o.host == L"devagents.local.")
      return {};
    // Origins must also be safe in CSP, URL patterns and the approval ledger.
    for (auto c : o.host)
      if (!((c >= L'a' && c <= L'z') || (c >= L'0' && c <= L'9') || c == L'.' ||
            c == L'-' || c == L'[' || c == L']' || c == L':'))
        return {};
    return o.scheme + L"://" + o.host + L":" + std::to_wstring(o.port);
  }
  static bool RuntimeSupportsIsolation(const std::wstring &version) {
    // Connection-Allowlist (including WebRTC) shipped in Chromium 152.
    // Older engines must fail closed; a JS wrapper is not network isolation.
    const size_t dot = version.find(L'.');
    if (dot == std::wstring::npos || dot == 0 || dot > 3)
      return false;
    unsigned major = 0;
    for (size_t i = 0; i < dot; ++i) {
      if (version[i] < L'0' || version[i] > L'9')
        return false;
      major = major * 10 + static_cast<unsigned>(version[i] - L'0');
    }
    return major >= 152;
  }
  bool RegisterApp(const std::wstring &url) {
    security::HttpOrigin o;
    const auto origin = Origin(url);
    if (origin.empty() || !security::ParseHttpUrl(url, o) ||
        (o.host != L"localhost" && o.host != L"127.0.0.1" &&
         o.host != L"[::1]") ||
        m_apps.size() >= MaxOrigins)
      return false;
    m_apps.insert(origin);
    return true;
  }
  // Trust class shown by the trusted UI; neither grants nor widens anything.
  bool IsApp(const std::wstring &url) const {
    const auto origin = Origin(url);
    return !origin.empty() && m_apps.count(origin);
  }
  bool IsApproved(const std::wstring &url) const {
    const auto origin = Origin(url);
    return !origin.empty() && m_approved.count(origin);
  }
  bool Allows(const std::wstring &url) const {
    const auto origin = Origin(url);
    return !origin.empty() &&
           (m_approved.count(origin) || m_apps.count(origin));
  }
  bool Load(const std::wstring &ledger) {
    m_approved.clear(); // Failed reloads must never retain earlier approvals.
    const HANDLE file =
        CreateFileW(ledger.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      const auto error = GetLastError();
      return error == ERROR_FILE_NOT_FOUND ||
             RejectLedger("cannot open", error);
    }
    LARGE_INTEGER size{};
    bool ok = RegularLedger(file) && GetFileSizeEx(file, &size) &&
              size.QuadPart >= 12 && size.QuadPart <= MaxLedgerBytes;
    std::vector<BYTE> envelope;
    DWORD read = 0;
    if (ok) {
      envelope.resize(static_cast<size_t>(size.QuadPart));
      ok = ReadFile(file, envelope.data(), static_cast<DWORD>(size.QuadPart),
                    &read, nullptr) &&
           read == size.QuadPart;
    }
    CloseHandle(file);
    if (!ok)
      return RejectLedger("not a regular bounded readable ledger");
    DWORD blobSize = 0;
    std::memcpy(&blobSize, envelope.data() + sizeof(LedgerMagic),
                sizeof(DWORD));
    if (std::memcmp(envelope.data(), LedgerMagic, sizeof(LedgerMagic)) ||
        blobSize == 0 || blobSize != envelope.size() - 12)
      return RejectLedger("invalid envelope or length");
    DATA_BLOB input{blobSize, envelope.data() + 12}, output{};
    auto entropy = Entropy();
    if (!CryptUnprotectData(&input, nullptr, &entropy, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &output))
      return RejectLedger("authentication/user/product mismatch",
                          GetLastError());
    ok = output.cbData <= 65536 && output.cbData % sizeof(wchar_t) == 0;
    std::vector<wchar_t> data(ok ? output.cbData / sizeof(wchar_t) : 0);
    if (ok && output.cbData)
      std::memcpy(data.data(), output.pbData, output.cbData);
    SecureZeroMemory(output.pbData, output.cbData);
    LocalFree(output.pbData);
    if (!ok)
      return RejectLedger("invalid authenticated payload size");
    std::set<std::wstring> parsed;
    std::wstring line;
    for (auto c : data) {
      if (c == L'\n') {
        if (line.empty() || Origin(line) != line || parsed.size() >= MaxOrigins)
          return RejectLedger("invalid authenticated origin set");
        parsed.insert(line);
        line.clear();
      } else
        line += c;
    }
    if (!line.empty())
      return RejectLedger("incomplete authenticated origin set");
    m_approved = std::move(parsed);
    return true;
  }
  bool Approve(const std::wstring &url, const std::wstring &ledger) {
    const auto origin = Origin(url);
    if (origin.empty() || ledger.empty() || m_approved.size() >= MaxOrigins)
      return false;
    if (m_approved.count(origin))
      return true;
    auto approved = m_approved;
    approved.insert(origin);
    std::wstring payload;
    for (const auto &entry : approved)
      payload += entry + L"\n";
    if (payload.size() * sizeof(wchar_t) > 65536)
      return RejectLedger("approval set exceeds limit");
    DATA_BLOB input{static_cast<DWORD>(payload.size() * sizeof(wchar_t)),
                    reinterpret_cast<BYTE *>(payload.data())},
        output{};
    auto entropy = Entropy();
    if (!CryptProtectData(&input, L"DevAgents browser origin approvals",
                          &entropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                          &output))
      return RejectLedger("cannot protect approvals", GetLastError());
    std::vector<BYTE> envelope(12 + output.cbData);
    std::memcpy(envelope.data(), LedgerMagic, sizeof(LedgerMagic));
    std::memcpy(envelope.data() + 8, &output.cbData, sizeof(DWORD));
    std::memcpy(envelope.data() + 12, output.pbData, output.cbData);
    LocalFree(output.pbData);
    // Keep the previous ledger readable and untouched until the flushed
    // replacement is ready. Reject links/directories before creating a temp.
    const HANDLE previous = CreateFileW(
        ledger.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (previous == INVALID_HANDLE_VALUE &&
        GetLastError() != ERROR_FILE_NOT_FOUND)
      return RejectLedger("cannot open previous approvals", GetLastError());
    if (previous != INVALID_HANDLE_VALUE && !RegularLedger(previous)) {
      CloseHandle(previous);
      return RejectLedger("previous approvals are not a regular ledger");
    }
    GUID guid{};
    wchar_t suffix[40]{};
    if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, suffix, 40)) {
      if (previous != INVALID_HANDLE_VALUE)
        CloseHandle(previous);
      return RejectLedger("cannot name temporary approvals");
    }
    const auto temporary = ledger + L".tmp-" + suffix;
    const HANDLE file =
        CreateFileW(temporary.c_str(), GENERIC_WRITE | FILE_READ_ATTRIBUTES, 0,
                    nullptr, CREATE_NEW, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      if (previous != INVALID_HANDLE_VALUE)
        CloseHandle(previous);
      return RejectLedger("cannot create temporary approvals", GetLastError());
    }
    DWORD written = 0;
    const DWORD size = static_cast<DWORD>(envelope.size());
    bool ok = RegularLedger(file) && size <= MaxLedgerBytes &&
              WriteFile(file, envelope.data(), size, &written, nullptr) &&
              written == size && FlushFileBuffers(file);
    DWORD error = ok ? ERROR_SUCCESS : GetLastError();
    if (!CloseHandle(file)) {
      ok = false;
      error = GetLastError();
    }
    if (previous != INVALID_HANDLE_VALUE)
      CloseHandle(previous);
    if (ok) {
      ok = MoveFileExW(temporary.c_str(), ledger.c_str(),
                       MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
      if (!ok)
        error = GetLastError();
    }
    if (!ok && !DeleteFileW(temporary.c_str()))
      return RejectLedger("cannot remove failed temporary approvals",
                          GetLastError());
    if (ok)
      m_approved = std::move(approved);
    return ok || RejectLedger("approval write/flush/replace failed", error);
  }
  std::wstring ConnectionAllowlist() const {
    std::wstring out = L"(";
    std::set<std::wstring> origins = m_approved;
    origins.insert(m_apps.begin(), m_apps.end());
    for (const auto &o : origins)
      out += L"\"" + o + L"/*\" ";
    return out + L");webrtc=block"; // Explicitly deny all peer connections.
  }
};
} // namespace beats::browser
