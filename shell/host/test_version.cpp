#include "test_check.hpp"
#include "version_policy.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <windows.h>
extern "C" int da_read_component_version(const wchar_t *, char *, unsigned int);
extern "C" void da_write_installed_versions(FILE *, const wchar_t *);
int main() {
  wchar_t executable[32768];
  DA_CHECK(GetModuleFileNameW(nullptr, executable, 32768) > 0);
  char metadata[1024];
  DA_CHECK(da_read_component_version(executable, metadata, sizeof(metadata)));
  DA_CHECK(std::string(metadata) == DA_BUILD_IDENTITY);
  DA_CHECK(!da_read_component_version(L"missing-fixture.exe", metadata,
                                      sizeof(metadata)));
  const auto fixture =
      std::filesystem::current_path() / L"version-test-fixture";
  DA_CHECK(!std::filesystem::exists(fixture));
  DA_CHECK(std::filesystem::create_directory(fixture));
  for (const auto *piece :
       {L"devagents-host.exe", L"devagents_core.dll", L"devagents-mcp.exe"})
    DA_CHECK(std::filesystem::copy_file(executable, fixture / piece));
  DA_CHECK(std::filesystem::create_directories(fixture / L"shell/webui/dist"));
  {
    std::ofstream manifest(fixture / L"shell/webui/dist/version.json");
    manifest << "{\"identity\":\"" << DA_BUILD_IDENTITY << "\"}\n";
  }
  const auto reportPath = fixture / L"report.txt";
  FILE *report = _wfopen(reportPath.c_str(), L"wb");
  DA_CHECK(report);
  da_write_installed_versions(report, (fixture.wstring() + L"\\").c_str());
  DA_CHECK(fclose(report) == 0);
  {
    std::ifstream file(reportPath);
    const std::string text((std::istreambuf_iterator<char>(file)), {});
    for (const char *piece : {"host", "motor DLL", "MCP", "WebUI empaquetada"})
      DA_CHECK(text.find(std::string(piece) + ": " + DA_BUILD_IDENTITY) !=
               std::string::npos);
    std::cout << "CK-COMP-004 --version fixture (PE copies, never executed):\n"
              << text;
  }
  for (const auto *piece : {L"devagents-host.exe", L"devagents_core.dll",
                            L"devagents-mcp.exe", L"report.txt"})
    DA_CHECK(std::filesystem::remove(fixture / piece));
  DA_CHECK(std::filesystem::remove(fixture / L"shell/webui/dist/version.json"));
  DA_CHECK(std::filesystem::remove(fixture / L"shell/webui/dist"));
  DA_CHECK(std::filesystem::remove(fixture / L"shell/webui"));
  DA_CHECK(std::filesystem::remove(fixture / L"shell"));
  DA_CHECK(std::filesystem::remove(fixture));
  using beats::versions::Mismatch;
  for (const char *piece : {"motor DLL", "WebUI"}) {
    const auto warning = Mismatch(piece, "old-build", "host-build");
    DA_CHECK(warning.find(piece) != std::string::npos);
    DA_CHECK(warning.find("host-build") != std::string::npos);
    DA_CHECK(warning.find("old-build") != std::string::npos);
    DA_CHECK(warning.find("Actualiza") != std::string::npos);
  }
  DA_CHECK(Mismatch("motor DLL", DA_BUILD_IDENTITY).empty());
  DA_CHECK(Mismatch("WebUI", DA_BUILD_IDENTITY).empty());
  DA_CHECK(!Mismatch("motor DLL", "").empty());
  // r2: equality alone cannot establish provenance for builds without Git
  // metadata.
  const std::string valid = "0.1.0+0123456789ab/abi1.bus1.ui1";
  for (const char *identity :
       {"0.1.0/abi1.bus1.ui1", "0.1.0+/abi1.bus1.ui1",
        "0.1.0+abc/abi1.bus1.ui1", "0.1.0+not-a-hash/abi1.bus1.ui1",
        "0.1.0+0123456789ab", ""}) {
    for (const char *piece : {"motor DLL", "WebUI"}) {
      for (const auto &pair :
           {std::make_pair(std::string(identity), std::string(identity)),
            std::make_pair(valid, std::string(identity)),
            std::make_pair(std::string(identity), valid)}) {
        const auto warning = Mismatch(piece, pair.second, pair.first);
        DA_CHECK(warning.find("build sin identidad de git") !=
                 std::string::npos);
        DA_CHECK(warning.find(piece) != std::string::npos);
        DA_CHECK(warning.find("host esperaba " + pair.first) !=
                 std::string::npos);
        DA_CHECK(warning.find(pair.second.empty()
                                  ? "ausente (sin version)"
                                  : pair.second) != std::string::npos);
        DA_CHECK(warning.find("Actualiza") != std::string::npos);
      }
    }
  }
  DA_CHECK(Mismatch("motor DLL", valid, valid).empty());
  DA_CHECK(Mismatch("WebUI", valid, valid).empty());
  std::cout << "CK-COMP-004 r2 native: 36 invalid comparisons rejected with "
               "Git warning; 2 valid matches accepted\n";
  const auto html = beats::versions::Html("bad <script>&\"");
  DA_CHECK(html.find("<script>") == std::string::npos);
  DA_CHECK(html.find("&lt;script&gt;&amp;&quot;") != std::string::npos);
  std::cout
      << "CK-COMP-004 native: 9/9 PASS (PE identity, missing PE, installed "
         "report, DLL, WebUI, match x2, missing export, escaped page)\n";
}
