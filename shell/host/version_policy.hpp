#pragma once
#include "build_version.h"
#include <string>

namespace beats::versions {
// Git-less source packages may build, but cannot establish component
// compatibility.
inline bool HasGitIdentity(const std::string &identity) {
  const auto plus = identity.find('+');
  if (plus == std::string::npos || plus == 0)
    return false;
  const auto slash = identity.find('/', plus + 1);
  if (slash == std::string::npos || slash + 1 == identity.size())
    return false;
  const auto length = slash - plus - 1;
  if (length < 7 || length > 64)
    return false;
  for (auto i = plus + 1; i < slash; ++i) {
    const char c = identity[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
          (c >= 'A' && c <= 'F')))
      return false;
  }
  return true;
}
inline std::string Mismatch(const std::string &piece, const std::string &found,
                            const std::string &expected = DA_BUILD_IDENTITY) {
  const bool identified = HasGitIdentity(expected) && HasGitIdentity(found);
  if (identified && found == expected)
    return {};
  return "Version incompatible de " + piece + ": host esperaba " + expected +
         "; encontro " + (found.empty() ? "ausente (sin version)" : found) +
         (identified ? ". " : ". build sin identidad de git. ") + "Actualiza " +
         piece + " y el host desde el mismo paquete DevAgents.";
}
inline std::string Html(const std::string &text) {
  std::string result;
  for (char c : text) {
    switch (c) {
    case '&':
      result += "&amp;";
      break;
    case '<':
      result += "&lt;";
      break;
    case '>':
      result += "&gt;";
      break;
    case '"':
      result += "&quot;";
      break;
    default:
      result += c;
    }
  }
  return "<!doctype html><html lang=es><meta charset=utf-8><title>DevAgents: "
         "version incompatible</title><body style=\"background:#151515;color:"
         "#fff;font:20px system-ui;padding:40px\"><h1>Version incompatible</h1>"
         "<p role=alert>" +
         result + "</p></body></html>";
}
} // namespace beats::versions
