#ifndef BEATS_ORIGIN_POLICY_HPP
#define BEATS_ORIGIN_POLICY_HPP

#include <string>
#include <string_view>
#include <urlmon.h>
#include <windows.h>

namespace beats::security {
struct HttpOrigin {
  std::wstring scheme;
  std::wstring host;
  DWORD port = 0;
};

// Parse components with the platform URI parser; prefixes cannot establish an
// origin. Reject controls/backslashes/credentials before handing URLs to the
// OS.
inline bool ParseHttpUrl(std::wstring_view value, HttpOrigin &origin) {
  if (value.empty())
    return false;
  for (const wchar_t c : value)
    if (c <= 0x20 || c == 0x7f || c == L'\\')
      return false;
  // CreateUri returns empty user info for https://@host. An empty credential
  // still carries the forbidden authority delimiter; inspect that syntax too.
  const size_t authority = value.find(L"://");
  if (authority != std::wstring_view::npos) {
    const size_t end = value.find_first_of(L"/?#", authority + 3);
    if (value
            .substr(authority + 3,
                    end == std::wstring_view::npos ? end : end - authority - 3)
            .find(L'@') != std::wstring_view::npos)
      return false;
  }
  IUri *uri = nullptr;
  const std::wstring input(value);
  if (FAILED(CreateUri(input.c_str(), Uri_CREATE_CANONICALIZE, 0, &uri)) ||
      !uri)
    return false;
  BSTR scheme = nullptr, host = nullptr, user = nullptr;
  DWORD port = 0;
  const bool valid =
      SUCCEEDED(uri->GetSchemeName(&scheme)) && scheme &&
      (wcscmp(scheme, L"https") == 0 || wcscmp(scheme, L"http") == 0) &&
      SUCCEEDED(uri->GetHost(&host)) && host && *host &&
      SUCCEEDED(uri->GetPort(&port)) && port > 0 && port <= 65535 &&
      SUCCEEDED(uri->GetUserInfo(&user)) && (!user || !*user);
  if (valid)
    origin = {scheme, host, port};
  SysFreeString(scheme);
  SysFreeString(host);
  SysFreeString(user);
  uri->Release();
  return valid;
}

inline bool IsAppOrigin(std::wstring_view value) {
  HttpOrigin origin;
  return ParseHttpUrl(value, origin) && origin.scheme == L"https" &&
         origin.host == L"devagents.local" && origin.port == 443;
}

inline bool IsBrowserUrl(std::wstring_view value, bool httpsOnly = false) {
  HttpOrigin origin;
  return ParseHttpUrl(value, origin) &&
         (!httpsOnly || origin.scheme == L"https");
}
} // namespace beats::security

#endif
