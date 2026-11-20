#pragma once
#include "bridge.hpp"
#include "version_policy.hpp"
#include <filesystem>
#include <fstream>
#include <iterator>

namespace beats::versions {
inline std::string WebUiIdentity(const std::wstring &directory) {
  std::ifstream file(std::filesystem::path(directory) / L"version.json",
                     std::ios::binary);
  if (!file)
    return {};
  std::string json;
  char c;
  while (json.size() <= 4096 && file.get(c))
    json += c;
  if (json.size() > 4096 || file.bad())
    return {};
  const auto identity = GetStringProp(json, "identity");
  std::ifstream bundle(std::filesystem::path(directory) / L"bundle.js",
                       std::ios::binary);
  std::string banner;
  while (banner.size() <= 512 && bundle.get(c) && c != '\n')
    banner += c;
  if (!banner.empty() && banner.back() == '\r')
    banner.pop_back();
  if (banner != "/* DevAgents build: " + identity + " */")
    return "manifiesto " + identity + "; bundle " +
           (banner.empty() ? "sin version" : banner);
  return identity;
}
} // namespace beats::versions
