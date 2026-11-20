// Estas pruebas se apoyan en DA_CHECK(): ningún modo de optimización (NDEBUG)
// las puede compilar fuera. Debe ir antes de cualquier #include.
#include "bridge.hpp"
#include "consent_prompt.hpp"
#include "core_client.hpp"
#include "document_manager.hpp"
#include "engine_supervisor.hpp"
#include "file_watcher.hpp"
#include "hunk_manager.hpp"
#include "lsp_client.hpp"
#include "project_search.hpp"
#include "pty_manager.hpp"
#include "shell_policy.hpp"
#include "version_policy.hpp"
#include "version_runtime.hpp"
#include "webview2_missing.hpp"

#include "test_bridge_inventory.hpp"
#include "test_check.hpp"
#include "test_update_apply.hpp"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>
#include <winioctl.h>

namespace beats {
// Internal implementation helper, not part of the bridge protocol.
bool FilterSaveTemporaryMatches(std::string &json);
} // namespace beats

static void test_seg011_h6_ranking() {
  const std::string prefix =
      "{\"query_mode\":\"hybrid\",\"index\":{\"state\":\"ready\"},\"matches\":";
  const std::string keep = "{\"path\":\"nested/ordinary.tmp\",\"snippet\":\"} "
                           "] \\\"path\\\"\",\"score\":1}";
  const std::string similar = "{\"path\":\".devagents-save-.tmp\"}";
  std::string response =
      prefix + "[{\"path\":\".devagents-save-orphan.tmp\"}," + keep +
      ",{\"path\":\"nested\\\\.DEVAGENTS-SAVE-UPPER.TMP\"}," + similar +
      ",{\"path\":\".devagents-save-dir.tmp/child.txt\"},"
      "{\"path\":\"nested/.devagents-save-1\\u002etmp\"}],\"truncated\":false}";
  DA_CHECK(beats::FilterSaveTemporaryMatches(response));
  const bool passed = response == prefix + "[" + keep + "," + similar +
                                      "],\"truncated\":false}";
  std::cout << "CK-SEG-011 H6 ranking oculta temporales y conserva JSON: "
            << (passed ? "PASS" : "FAIL") << std::endl;
  DA_CHECK(passed);
  response = "{\"matches\":[{\"path\":\".devagents-save-1.tmp\"}]}";
  DA_CHECK(beats::FilterSaveTemporaryMatches(response));
  DA_CHECK(response == "{\"matches\":[]}");
  for (const auto *invalid :
       {"{}", "{\"matches\":null}", "{\"matches\":[1]}", "{\"matches\":[{}]}",
        "{\"matches\":[{\"path\":\"a\"},]}"}) {
    response = invalid;
    DA_CHECK(!beats::FilterSaveTemporaryMatches(response));
  }
}

// Real NTFS junction, same fixture construction as the document tests.
static bool MakeWriterJunction(const std::wstring &path,
                               const std::wstring &target) {
  if (!CreateDirectoryW(path.c_str(), nullptr))
    return false;
  HANDLE handle = CreateFileW(
      path.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (handle == INVALID_HANDLE_VALUE)
    return false;
  const std::wstring substitute = L"\\??\\" + target;
  const WORD substituteBytes = static_cast<WORD>(substitute.size() * 2);
  const WORD targetBytes = static_cast<WORD>(target.size() * 2);
  std::vector<unsigned char> data(16 + substituteBytes + 2 + targetBytes + 2,
                                  0);
  const DWORD tag = IO_REPARSE_TAG_MOUNT_POINT;
  memcpy(data.data(), &tag, sizeof(tag));
  const WORD fields[] = {
      static_cast<WORD>(data.size() - 8),     0,          0, substituteBytes,
      static_cast<WORD>(substituteBytes + 2), targetBytes};
  memcpy(data.data() + 4, fields, sizeof(fields));
  memcpy(data.data() + 16, substitute.data(), substituteBytes);
  memcpy(data.data() + 18 + substituteBytes, target.data(), targetBytes);
  DWORD returned = 0;
  const bool ok = DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, data.data(),
                                  static_cast<DWORD>(data.size()), nullptr, 0,
                                  &returned, nullptr) != FALSE;
  CloseHandle(handle);
  return ok;
}

static bool test_alternate_writers_confined() {
  wchar_t temp[32768];
  DA_CHECK(GetTempPathW(32768, temp) > 0);
  const std::wstring base = std::wstring(temp) + L"beats-writer-" +
                            std::to_wstring(GetCurrentProcessId());
  const auto root = base + L"\\workspace", outside = base + L"\\outside";
  const auto victim = outside + L"\\sentinel.txt",
             local = root + L"\\local.txt";
  const auto junction = root + L"\\escape", hardlink = root + L"\\hardlink.txt";
  DA_CHECK(CreateDirectoryW(base.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(outside.c_str(), nullptr));
  const auto seed = [](const std::wstring &path) {
    std::ofstream out(path.c_str(), std::ios::binary);
    out << "sentinel\n";
    DA_CHECK(out.good());
  };
  seed(victim);
  seed(local);
  DA_CHECK(MakeWriterJunction(junction, outside));
  DA_CHECK(CreateHardLinkW(hardlink.c_str(), victim.c_str(), nullptr));
  const auto jsonPath = [](const std::wstring &path) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                         static_cast<int>(path.size()), nullptr,
                                         0, nullptr, nullptr);
    std::string utf8(size, '\0');
    DA_CHECK(WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                 static_cast<int>(path.size()), utf8.data(),
                                 size, nullptr, nullptr) == size);
    return beats::JsonEscapePublic(utf8);
  };
  bool passed = true;
  unsigned checks = 0;
  {
    beats::DocumentManager docs;
    std::string error;
    DA_CHECK(docs.AuthorizeWorkspaceRoot(root, error));
    beats::ProjectSearch search(docs);
    beats::HunkManager hunks(docs);
    beats::Bridge bridge;
    bridge.BindServices(&docs, nullptr, &search, &hunks, nullptr, nullptr,
                        nullptr);
    const auto intact = [&] {
      std::ifstream in(victim.c_str(), std::ios::binary);
      return std::string(std::istreambuf_iterator<char>(in), {}) ==
             "sentinel\n";
    };
    const auto check = [&](bool ok, const std::string &name) {
      ++checks;
      if (!ok) {
        std::cerr << "FAIL writer: " << name << "\n";
        passed = false;
      }
    };
    for (const auto *kind :
         {"search.query", "search.embedIndex", "search.embedStatus"}) {
      check(bridge.HandleMessage("{\"id\":75,\"kind\":\"" + std::string(kind) +
                                 "\",\"payload\":{\"query\":\"sentinel\","
                                 "\"mode\":\"ranking\"}}")
                    .find("E_SEARCH_ROOT_REQUIRED") != std::string::npos,
            std::string(kind) +
                " cannot fall back to an ungranted engine root");
    }
    for (const auto &dir : {outside, root + L"\\..\\outside", junction,
                            std::wstring(L"\\\\localhost\\beats-no-share")}) {
      for (const auto *kind :
           {"fs.mkdir", "fs.createFile", "fs.list", "fs.watch", "search.query",
            "search.embedIndex", "search.embedStatus", "checkpoint.create",
            "checkpoint.restore", "core.workspace.set", "core.mount.add",
            "core.repo.clone"}) {
        const auto reply = bridge.HandleMessage(
            "{\"id\":75,\"kind\":\"" + std::string(kind) +
            "\",\"payload\":{\"path\":\"" + jsonPath(dir) + "\",\"parent\":\"" +
            jsonPath(dir) + "\",\"root\":\"" + jsonPath(dir) +
            "\",\"rootDir\":\"" + jsonPath(dir) + "\",\"targetDir\":\"" +
            jsonPath(dir + L"\\clone") +
            "\",\"name\":\"blocked\",\"query\":\"sentinel\","
            "\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
            "\"url\":\"https://example.invalid/repo\"}}");
        check(reply.find("\"error\"") != std::string::npos,
              std::string(kind) + " outside root denied");
      }
      // Remove only the attack fixtures that the unprotected implementation
      // creates during the RED run; never recurse through the junction.
      DeleteFileW((dir + L"\\blocked").c_str());
      RemoveDirectoryW((dir + L"\\blocked").c_str());
    }
    for (const auto &path : {victim, junction + L"\\sentinel.txt", hardlink,
                             root + L"\\..\\outside\\sentinel.txt"}) {
      check(bridge.HandleMessage("{\"id\":76,\"kind\":\"doc.open\","
                                 "\"payload\":{\"path\":\"" +
                                 jsonPath(path) + "\"}}")
                    .find("\"error\"") != std::string::npos,
            "doc.open outside/reparse/hardlink denied");
    }
    check(bridge.HandleMessage("{\"id\":77,\"kind\":\"cdp.dump\","
                               "\"payload\":{\"dump\":\"attack\"}}")
                  .find("\"error\"") != std::string::npos,
          "cdp.dump cannot write a fixed external path");
    // Lote 1: nombres de dispositivo Win32 (NUL/CON/COMn/LPTn, hoja o
    // componente, \\.\ y \\?\) y UNC como `path`/`parent`/`root`/`rootDir` de
    // CADA handler confinado: el puente responde error y no crea entradas.
    {
      const auto countEntries = [&]() {
        size_t entries = 0;
        WIN32_FIND_DATAW data{};
        HANDLE find =
            FindFirstFileW((L"\\\\?\\" + root + L"\\*").c_str(), &data);
        DA_CHECK(find != INVALID_HANDLE_VALUE);
        do {
          if (wcscmp(data.cFileName, L".") != 0 &&
              wcscmp(data.cFileName, L"..") != 0)
            ++entries;
        } while (FindNextFileW(find, &data));
        FindClose(find);
        return entries;
      };
      const size_t entriesBefore = countEntries();
      const std::vector<std::wstring> deviceTargets = {
          root + L"\\NUL",
          root + L"\\CON",
          root + L"\\nul.txt",
          root + L"\\COM1",
          root + L"\\LPT1.log",
          root + L"\\NUL\\child.txt",
          root + L"\\sub\\AUX",
          root + L"\\NUL.",
          root + L"\\x.txt:stream",
          L"\\\\.\\NUL",
          L"\\\\.\\CON",
          L"\\\\.\\COM1",
          L"\\\\.\\PhysicalDrive0",
          L"\\\\?\\GLOBALROOT\\Device\\Null",
          L"\\\\?\\" + root,
          L"\\\\?\\UNC\\localhost\\C$\\NUL",
          L"\\\\localhost\\C$\\NUL",
          L"C:\\NUL",
          L"C:NUL",
          L"NUL",
          L"CON"};
      for (const auto &target : deviceTargets) {
        const auto escaped = jsonPath(target);
        for (const auto *kind :
             {"doc.open", "doc.save", "fs.list", "fs.mkdir", "fs.createFile",
              "fs.watch", "search.query", "search.replace", "search.embedIndex",
              "search.embedStatus", "checkpoint.create", "checkpoint.restore",
              "hunk.accept", "hunk.reject", "core.workspace.set",
              "core.mount.add", "core.repo.clone"}) {
          const auto reply = bridge.HandleMessage(
              "{\"id\":86,\"kind\":\"" + std::string(kind) +
              "\",\"payload\":{\"path\":\"" + escaped + "\",\"parent\":\"" +
              escaped + "\",\"root\":\"" + escaped + "\",\"rootDir\":\"" +
              escaped + "\",\"targetDir\":\"" + escaped +
              "\",\"name\":\"blocked\",\"content\":\"attack\","
              "\"query\":\"sentinel\",\"replacement\":\"ATTACK\","
              "\"force\":true,\"hunkId\":1,\"originalContent\":\"A\","
              "\"newContent\":\"B\","
              "\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
              "\"url\":\"https://example.invalid/repo\"}}");
          check(reply.find("\"error\"") != std::string::npos &&
                    reply.find("\"status\":\"ok\"") == std::string::npos,
                std::string(kind) + " denies Win32 device/namespace target");
        }
      }
      for (const auto *leaf : {"NUL", "CON", "PRN", "AUX", "COM1", "LPT1",
                               "nul.txt", "com9.log", "NUL.", "NUL "}) {
        for (const auto *kind : {"fs.mkdir", "fs.createFile"}) {
          const auto reply = bridge.HandleMessage(
              "{\"id\":87,\"kind\":\"" + std::string(kind) +
              "\",\"payload\":{\"parent\":\"" + jsonPath(root) +
              "\",\"name\":\"" + beats::JsonEscapePublic(leaf) +
              "\",\"content\":\"attack\"}}");
          check(reply.find("\"error\"") != std::string::npos &&
                    reply.find("\"status\":\"ok\"") == std::string::npos,
                std::string(kind) + " denies Win32 device leaf name");
        }
      }
      // Sin entradas nuevas: los ataques no crearon nada en la raíz concedida.
      check(countEntries() == entriesBefore,
            "device-name attacks created no entries in the granted root");
    }
    check(bridge.HandleMessage(
                    "{\"id\":78,\"kind\":\"checkpoint.restore\","
                    "\"payload\":{\"root\":\"" +
                    jsonPath(root) +
                    "\",\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}")
                  .find("E_CHECKPOINT_NOT_ISSUED") != std::string::npos,
          "checkpoint.restore SHA must be issued by this host");
    for (const auto *kind :
         {"core.mcp.connect", "core.mcp.authToken", "core.hooks.set",
          "core.external.paths.set", "core.permissions.set",
          "core.plugin.trust", "core.screenshot", "core.webhooks.add",
          "core.webhooks.test", "core.provider.add", "core.git.storeCredential",
          "core.pr.merge", "core.order.ship",
          "core.workspace.restorePermissions"}) {
      // core.permissions.set pide el modo Omitir permisos (amplía;
      // sin motor que leer, el host pregunta). Sin diálogo posible: rechazo.
      check(bridge.HandleMessage(
                      "{\"id\":79,\"kind\":\"" + std::string(kind) +
                      "\",\"payload\":{\"explicit\":true,\"confirmed\":true,"
                      "\"argvJson\":\"[\\\"cmd.exe\\\",\\\"/"
                      "c\\\",\\\"calc\\\"]\","
                      "\"folder\":\"../outside\",\"configJson\":"
                      "\"{\\\"mode\\\":\\\"bypass\\\"}\"}}")
                    .find("E_NATIVE_CONSENT_REQUIRED") != std::string::npos,
            std::string(kind) + " JS flags cannot grant native consent");
    }
    check(
        bridge.HandleMessage("{\"id\":79,\"kind\":\"core.repo.clone\","
                             "\"payload\":{\"targetDir\":\"" +
                             jsonPath(junction) +
                             "\",\"url\":\"https://example.invalid/repo\"}}")
                .find("E_CLONE_TARGET_UNSAFE") != std::string::npos,
        "core.repo.clone rejects a junction at the target leaf before consent");
    check(bridge.HandleMessage("{\"id\":79,\"kind\":\"checkpoint.create\","
                               "\"payload\":{\"root\":\"" +
                               jsonPath(root) + "\"}}")
                  .find("E_CHECKPOINT_TREE_UNSAFE") != std::string::npos,
          "checkpoint.create rejects an escaping tree before git reads it");
    for (const auto *url :
         {"--upload-pack=calc", "ext::cmd /c calc", "file:///C:/outside",
          "ssh://attacker/repo", "http://attacker/repo",
          "https://user@attacker/repo"}) {
      check(bridge.HandleMessage("{\"id\":79,\"kind\":\"core.repo.clone\","
                                 "\"payload\":{\"targetDir\":\"" +
                                 jsonPath(root + L"\\clone") + "\",\"url\":\"" +
                                 beats::JsonEscapePublic(url) + "\"}}")
                    .find("E_REPO_URL_INVALID") != std::string::npos,
            "core.repo.clone rejects remote helpers/options/non-HTTPS before "
            "motor");
    }
    check(bridge.HandleMessage("{\"id\":79,\"kind\":\"core.repo.clone\","
                               "\"payload\":{\"targetDir\":\"" +
                               jsonPath(root + L"\\clone") +
                               "\",\"url\":\"https://example.invalid/"
                               "repo\",\"confirmed\":true}}")
                  .find("E_NATIVE_CONSENT_REQUIRED") != std::string::npos,
          "core.repo.clone requires native consent for an authorized target");
    check(bridge.HandleMessage("{\"id\":79,\"kind\":\"core.issues.comment\","
                               "\"payload\":{\"explicit\":true}}")
                  .find("E_NATIVE_CONSENT_REQUIRED") != std::string::npos,
          "core.issues.comment explicit JS flag cannot grant native consent");
    // Exercise the handler itself with hostile host environment values. It
    // must reject before launching WSL, not just pass a helper's unit test.
    const std::string oldDistro =
        std::getenv("DEVAGENTS_OPENDESIGN_WSL_DISTRO")
            ? std::getenv("DEVAGENTS_OPENDESIGN_WSL_DISTRO")
            : "";
    const std::string oldDir = std::getenv("DEVAGENTS_OPENDESIGN_DIR")
                                   ? std::getenv("DEVAGENTS_OPENDESIGN_DIR")
                                   : "";
    for (const auto *value :
         {"Ubuntu\" -e calc", "Ubuntu;calc", "Ubuntu$(calc)", "-Ubuntu"}) {
      DA_CHECK(_putenv_s("DEVAGENTS_OPENDESIGN_WSL_DISTRO", value) == 0);
      DA_CHECK(_putenv_s("DEVAGENTS_OPENDESIGN_DIR", "/root/open-design") == 0);
      check(
          bridge.HandleMessage(
                    "{\"id\":80,\"kind\":\"opendesign.launch\",\"payload\":{}}")
                  .find("E_OPENDESIGN_INVALID") != std::string::npos,
          "opendesign.launch rejects hostile distro before process creation");
    }
    DA_CHECK(_putenv_s("DEVAGENTS_OPENDESIGN_WSL_DISTRO", "Ubuntu") == 0);
    for (const auto *value :
         {"~/open-design", "/tmp/x;calc", "/tmp/$(calc)", "/tmp/x\" && calc"}) {
      DA_CHECK(_putenv_s("DEVAGENTS_OPENDESIGN_DIR", value) == 0);
      check(
          bridge.HandleMessage(
                    "{\"id\":80,\"kind\":\"opendesign.launch\",\"payload\":{}}")
                  .find("E_OPENDESIGN_INVALID") != std::string::npos,
          "opendesign.launch rejects hostile directory before process "
          "creation");
    }
    DA_CHECK(_putenv_s("DEVAGENTS_OPENDESIGN_WSL_DISTRO", oldDistro.c_str()) ==
             0);
    DA_CHECK(_putenv_s("DEVAGENTS_OPENDESIGN_DIR", oldDir.c_str()) == 0);
    for (const auto *name : {"../evil", "stream:payload", "alias.", "alias ",
                             "evil\nfile", "NUL"}) {
      for (const auto *kind : {"fs.mkdir", "fs.createFile"}) {
        check(bridge.HandleMessage("{\"id\":81,\"kind\":\"" +
                                   std::string(kind) +
                                   "\",\"payload\":{\"parent\":\"" +
                                   jsonPath(root) + "\",\"name\":\"" +
                                   beats::JsonEscapePublic(name) + "\"}}")
                      .find("\"error\"") != std::string::npos,
              std::string(kind) + " rejects hostile leaf name");
        DeleteFileW((root + L"\\NUL").c_str());
        RemoveDirectoryW((root + L"\\NUL").c_str());
      }
    }
    const auto created = root + L"\\created.txt";
    const std::string content(2 * 1024 * 1024 + 71, 'c');
    auto createReply = bridge.HandleMessage(
        "{\"id\":82,\"kind\":\"fs.createFile\",\"payload\":{\"parent\":\"" +
        jsonPath(root) + "\",\"name\":\"created.txt\",\"content\":\"" +
        content + "\"}}");
    beats::DocumentState createdDoc;
    check(createReply.find("\"status\":\"ok\"") != std::string::npos &&
              docs.OpenDocument(created, createdDoc) &&
              createdDoc.content == content,
          "fs.createFile writes complete multichunk file");
    check(bridge.HandleMessage(
                    "{\"id\":83,\"kind\":\"fs.createFile\",\"payload\":{"
                    "\"parent\":\"" +
                    jsonPath(root) +
                    "\",\"name\":\"created.txt\",\"content\":\"attack\"}}")
                      .find("\"error\"") != std::string::npos &&
              docs.OpenDocument(created, createdDoc) &&
              createdDoc.content == content,
          "fs.createFile never overwrites existing entry");
    const auto mkdirPayload =
        "{\"id\":84,\"kind\":\"fs.mkdir\",\"payload\":{\"parent\":\"" +
        jsonPath(root) + "\",\"name\":\"created-dir\"}}";
    check(bridge.HandleMessage(mkdirPayload).find("\"status\":\"ok\"") !=
              std::string::npos,
          "fs.mkdir creates directory relative to confined parent handle");
    check(bridge.HandleMessage(mkdirPayload).find("\"error\"") !=
              std::string::npos,
          "fs.mkdir never opens/replaces existing entry");
    check(bridge.HandleMessage(
                    "{\"id\":85,\"kind\":\"fs.list\",\"payload\":{\"path\":\"" +
                    jsonPath(root) + "\"}}")
                  .find("created-dir") != std::string::npos,
          "fs.list exposes authorized creations");
    DA_CHECK(DeleteFileW(created.c_str()));
    DA_CHECK(RemoveDirectoryW((root + L"\\created-dir").c_str()));
    for (const auto &dir :
         {root + L"\\..\\outside", outside,
          std::wstring(L"\\\\localhost\\beats-security-no-share"), junction}) {
      seed(victim);
      const auto reply = bridge.HandleMessage(
          "{\"id\":70,\"kind\":\"search.replace\",\"payload\":{\"query\":"
          "\"sentinel\",\"replacement\":\"ATTACK\",\"rootDir\":\"" +
          jsonPath(dir) + "\"}}");
      check(reply.find("\"error\"") != std::string::npos && intact(),
            "search.replace root denied and victim intact");
    }
    for (const auto *kind : {"hunk.accept", "hunk.reject"}) {
      for (const auto &path :
           {root + L"\\..\\outside\\sentinel.txt", victim,
            std::wstring(
                L"\\\\localhost\\beats-security-no-share\\sentinel.txt"),
            junction + L"\\sentinel.txt", hardlink,
            std::wstring(L"../outside/sentinel.txt")}) {
        seed(victim);
        const auto reply = bridge.HandleMessage(
            "{\"id\":71,\"kind\":\"" + std::string(kind) +
            "\",\"payload\":{\"path\":\"" + jsonPath(path) +
            "\",\"hunkId\":1,\"originalContent\":\"ATTACK "
            "ORIGINAL\",\"newContent\":\"ATTACK NEW\"}}");
        check(reply.find("\"error\"") != std::string::npos && intact(),
              std::string(kind) + " path denied and victim intact");
      }
    }
    // A registered root with an escaping hardlink must fail the actual writer,
    // not report successful replacement or truncate the outside file.
    seed(victim);
    const auto hardReply = bridge.HandleMessage(
        "{\"id\":72,\"kind\":\"search.replace\",\"payload\":{\"query\":"
        "\"sentinel\",\"replacement\":\"ATTACK\",\"rootDir\":\"" +
        jsonPath(root) + "\"}}");
    check(hardReply.find("\"error\"") != std::string::npos && intact(),
          "search.replace hardlink writer denied");
    {
      beats::confined::LockedPath pinnedTree;
      check(!beats::confined::LockTree(root, pinnedTree),
            "checkpoint tree rejects junction/hardlink");
    }
    {
      beats::confined::LockedPath pinnedTree;
      check(!beats::confined::LockTree(outside, pinnedTree),
            "checkpoint tree rejects a hardlinked leaf without junctions");
    }
    DA_CHECK(DeleteFileW(hardlink.c_str()));
    {
      beats::confined::LockedPath pinnedTree;
      check(beats::confined::LockTree(outside, pinnedTree),
            "checkpoint tree accepts a regular tree");
      const auto moved = outside + L"-moved";
      const bool renamed = MoveFileW(outside.c_str(), moved.c_str()) != FALSE;
      check(!renamed, "checkpoint directories stay pinned during git IO");
      if (renamed)
        DA_CHECK(MoveFileW(moved.c_str(), outside.c_str()));
    }
    seed(victim);
    seed(local);
    const auto safeReply = bridge.HandleMessage(
        "{\"id\":73,\"kind\":\"search.replace\",\"payload\":{\"query\":"
        "\"sentinel\",\"replacement\":\"SAFE\",\"rootDir\":\"" +
        jsonPath(root) + "\"}}");
    check(safeReply.find("\"replacedCount\":1") != std::string::npos &&
              intact(),
          "search.replace skips escaping junction during scan");
    for (const auto *kind : {"hunk.accept", "hunk.reject"}) {
      const auto reply =
          bridge.HandleMessage("{\"id\":74,\"kind\":\"" + std::string(kind) +
                               "\",\"payload\":{\"path\":\"" + jsonPath(local) +
                               "\",\"hunkId\":1,\"originalContent\":"
                               "\"ORIGINAL\",\"newContent\":\"NEW\"}}");
      beats::DocumentState observed;
      check(reply.find("\"status\":\"ok\"") != std::string::npos &&
                docs.OpenDocument(local, observed) &&
                observed.content ==
                    (std::string(kind) == "hunk.accept" ? "NEW" : "ORIGINAL"),
            std::string(kind) + " authorized write and truncation");
    }
    // MEDIO-2: core.order.worktree no convierte cualquier orden histórica en
    // raíz de escritura. Se decide con la misma función que usa el handler.
    {
      const auto utf8 = [](const std::wstring &path) {
        const int size = WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                             static_cast<int>(path.size()),
                                             nullptr, 0, nullptr, nullptr);
        std::string out(size, '\0');
        WideCharToMultiByte(CP_UTF8, 0, path.data(),
                            static_cast<int>(path.size()), out.data(), size,
                            nullptr, nullptr);
        return out;
      };
      const auto orderSpace = root + L"\\orderspace";
      DA_CHECK(CreateDirectoryW(orderSpace.c_str(), nullptr));
      std::string cause;
      check(!beats::Bridge::AuthorizeOrderWorktree(docs, false, utf8(outside),
                                                   cause) &&
                cause.rfind("E_ORDER_ROOT_NOT_GRANTED", 0) == 0 &&
                !docs.IsAuthorizedWorkspaceRoot(outside),
            "historical order outside granted roots is denied with a Spanish "
            "cause");
      check(!beats::Bridge::AuthorizeOrderWorktree(docs, true, "", cause) &&
                !beats::Bridge::AuthorizeOrderWorktree(
                    docs, false, utf8(root + L"\\..\\outside"), cause),
            "empty and traversal order roots are denied");
      check(beats::Bridge::AuthorizeOrderWorktree(docs, false, utf8(orderSpace),
                                                  cause) &&
                docs.IsAuthorizedWorkspaceRoot(orderSpace),
            "order folder inside an already granted root is authorized");
      check(!beats::Bridge::IsSessionOrder(778001),
            "an order id from JS is not a session order");
      beats::Bridge::NoteSessionOrder(778001);
      check(beats::Bridge::IsSessionOrder(778001) &&
                beats::Bridge::AuthorizeOrderWorktree(docs, true, utf8(outside),
                                                      cause) &&
                docs.IsAuthorizedWorkspaceRoot(outside),
            "order created in this session may authorize its engine folder");
    }
  }
  RemoveDirectoryW((root + L"\\orderspace").c_str());
  DA_CHECK(RemoveDirectoryW(junction.c_str()));
  DA_CHECK(DeleteFileW(local.c_str()));
  DA_CHECK(DeleteFileW(victim.c_str()));
  DA_CHECK(RemoveDirectoryW(root.c_str()));
  DA_CHECK(RemoveDirectoryW(outside.c_str()));
  DA_CHECK(RemoveDirectoryW(base.c_str()));
  std::cout << (passed ? "PASS" : "FAIL") << " alternate writers: " << checks
            << " checks\n";
  return passed;
}

// ---------------------------------------------------------------------------
// BAJO-1 (el modelo r1): el consentimiento nativo muestra QUÉ acción y sobre
// QUÉ recurso, no filtra secretos, neutraliza el texto de la página y se abre
// en el hilo de la ventana propietaria aunque lo pida un worker.
// ---------------------------------------------------------------------------
static const char *const kConsentKinds[] = {"core.mcp.connect",
                                            "core.mcp.authToken",
                                            "core.hooks.set",
                                            "core.external.paths.set",
                                            "core.permissions.set",
                                            "core.plugin.trust",
                                            "core.screenshot",
                                            "core.remote.start",
                                            "core.webhooks.add",
                                            "core.webhooks.test",
                                            "core.provider.add",
                                            "core.git.storeCredential",
                                            "core.workspace.restorePermissions",
                                            "core.pr.merge",
                                            "core.order.ship",
                                            "lsp.request",
                                            "core.repo.clone",
                                            "core.issues.comment"};

static std::wstring ToWide(const char *utf8) {
  const int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  std::wstring out(static_cast<size_t>(n > 0 ? n - 1 : 0), L'\0');
  if (n > 1)
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), n);
  return out;
}

static bool Has(const std::wstring &text, const wchar_t *part) {
  return text.find(part) != std::wstring::npos;
}

static LRESULT CALLBACK ConsentTestProc(HWND hwnd, UINT message, WPARAM wParam,
                                        LPARAM lParam) {
  if (message == beats::consent::kMessage) {
    beats::consent::Handle(lParam);
    return 0;
  }
  return DefWindowProcW(hwnd, message, wParam, lParam);
}

static HWND MakeConsentOwner() {
  static const wchar_t *kClass = L"BeatsConsentTestWindow";
  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW wc{sizeof(wc)};
    wc.lpfnWndProc = ConsentTestProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kClass;
    DA_CHECK(RegisterClassExW(&wc));
    registered = true;
  }
  HWND hwnd =
      CreateWindowExW(0, kClass, L"consent owner", WS_OVERLAPPED, 0, 0, 10, 10,
                      nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  DA_CHECK(hwnd);
  return hwnd;
}

static void PumpUntil(const std::atomic<bool> &done, int seconds) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
  while (!done && std::chrono::steady_clock::now() < deadline) {
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
    Sleep(1);
  }
  DA_CHECK(done && "worker must finish while the UI thread pumps");
}

static void test_native_consent_context() {
  // 1. Cada capacidad tiene acción y recurso propios (el texto genérico con el
  // nombre del kind queda sólo para kinds desconocidos).
  for (const char *kind : kConsentKinds) {
    const std::wstring text = beats::Bridge::ConsentText(kind, "{}");
    DA_CHECK(Has(text, L"Acción: ") &&
             Has(text, L"Recurso (lo indica la página): "));
    DA_CHECK(!Has(text, ToWide(kind).c_str()) &&
             "known kinds show a described action, not the raw kind name");
  }
  DA_CHECK(Has(beats::Bridge::ConsentText("x.unknown", "{}"), L"x.unknown"));

  // 2. Recursos concretos por capacidad.
  const auto text = [](const char *kind, const std::string &payload) {
    return beats::Bridge::ConsentText(kind, payload);
  };
  DA_CHECK(Has(text("core.plugin.trust", "{\"folder\":\"C:\\\\plugins\\\\a\"}"),
               L"C:\\plugins\\a"));
  DA_CHECK(Has(text("core.pr.merge", "{\"prId\":42}"), L"n.º 42"));
  DA_CHECK(Has(text("core.order.ship", "{\"orderId\":7}"), L"n.º 7"));
  DA_CHECK(Has(text("core.workspace.restorePermissions", "{\"orderId\":9}"),
               L"n.º 9"));
  DA_CHECK(Has(text("core.remote.start",
                    "{\"port\":8080,\"origin\":\"https://a.example\"}"),
               L"8080") &&
           Has(text("core.remote.start",
                    "{\"port\":8080,\"origin\":\"https://a.example\"}"),
               L"https://a.example"));
  DA_CHECK(
      Has(text(
              "core.repo.clone",
              "{\"url\":\"https://github.com/o/r\",\"targetDir\":\"C:\\\\w\"}"),
          L"https://github.com/o/r") &&
      Has(text(
              "core.repo.clone",
              "{\"url\":\"https://github.com/o/r\",\"targetDir\":\"C:\\\\w\"}"),
          L"C:\\w"));
  DA_CHECK(Has(text("lsp.request",
                    "{\"language\":\"zig\",\"method\":\"textDocument/hover\"}"),
               L"zig") &&
           Has(text("lsp.request",
                    "{\"language\":\"zig\",\"method\":\"textDocument/hover\"}"),
               L"textDocument/hover"));
  DA_CHECK(
      Has(text("core.issues.comment",
               "{\"project\":\"o/r\",\"source\":\"github\",\"issue_id\":\"12\","
               "\"text\":\"CUERPO-PRIVADO\"}"),
          L"o/r") &&
      !Has(text("core.issues.comment",
                "{\"project\":\"o/r\",\"source\":\"github\","
                "\"issue_id\":\"12\",\"text\":\"CUERPO-PRIVADO\"}"),
           L"CUERPO-PRIVADO"));

  // 3. Los secretos del payload nunca se muestran ni se copian.
  const auto credential = text(
      "core.git.storeCredential",
      "{\"host\":\"github.com\",\"username\":\"octo\",\"password\":\"hunter2-"
      "secret\"}");
  DA_CHECK(Has(credential, L"github.com") && Has(credential, L"octo") &&
           !Has(credential, L"hunter2-secret"));
  const auto connect = text(
      "core.mcp.connect",
      "{\"argvJson\":\"[\\\"C:\\\\\\\\tools\\\\\\\\srv.exe\\\",\\\"--token="
      "SECRETVALUE\\\"]\",\"cwd\":\"C:\\\\work\",\"timeoutMs\":5}");
  DA_CHECK(Has(connect, L"C:\\tools\\srv.exe") && Has(connect, L"C:\\work") &&
           !Has(connect, L"SECRETVALUE"));
  const auto hook = text(
      "core.webhooks.add",
      "{\"url\":\"https://user:pw@hooks.example.com/path/x?token=ABC#frag\","
      "\"event\":\"order.done\",\"secret\":\"S3CRETO\"}");
  DA_CHECK(Has(hook, L"hooks.example.com/path/x") && Has(hook, L"order.done") &&
           !Has(hook, L"user:pw") && !Has(hook, L"token=ABC") &&
           !Has(hook, L"frag") && !Has(hook, L"S3CRETO"));
  const auto provider =
      text("core.provider.add", "{\"name\":\"p\",\"baseUrl\":\"https://k:v@api."
                                "example.com/v1?key=Z\",\"apiKey\":\"CLAVE\"}");
  DA_CHECK(Has(provider, L"api.example.com/v1") && !Has(provider, L"k:v@") &&
           !Has(provider, L"key=Z") && !Has(provider, L"CLAVE"));
  DA_CHECK(!Has(text("core.mcp.authToken", "{\"token\":\"TOK-PRIVADO\"}"),
                L"TOK-PRIVADO"));

  // 4. El texto de la página no puede fingir líneas ni invertir el texto, y
  // está acotado.
  const std::wstring plain =
      text("core.plugin.trust", "{\"folder\":\"C:\\\\a\"}");
  const size_t baseLines =
      static_cast<size_t>(std::count(plain.begin(), plain.end(), L'\n'));
  const auto hostile = text(
      "core.plugin.trust",
      "{\"folder\":\"C:\\\\a\\nAcción: Nada importante\\r\\u202Eexe.txt\\u2066"
      "x\"}");
  DA_CHECK(static_cast<size_t>(
               std::count(hostile.begin(), hostile.end(), L'\n')) == baseLines);
  DA_CHECK(hostile.find(L'\r') == std::wstring::npos &&
           hostile.find(L'\u202E') == std::wstring::npos &&
           hostile.find(L'\u2066') == std::wstring::npos);
  const auto huge = text("core.plugin.trust",
                         "{\"folder\":\"" + std::string(5000, 'x') + "\"}");
  DA_CHECK(huge.size() < 700 && Has(huge, L"\u2026"));

  // 5. Con un presentador inyectado y sin propietario se evalúa la respuesta:
  // «no» no ejecuta el handler, «sí» lo deja pasar.
  {
    beats::Bridge bridge;
    bridge.BindServices(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                        nullptr);
    int calls = 0;
    std::wstring title, body;
    bool answer = false;
    bridge.SetConsentPresenter(
        [&](void *owner, const std::wstring &t, const std::wstring &b) {
          DA_CHECK(owner == nullptr);
          ++calls;
          title = t;
          body = b;
          return answer;
        });
    const std::string request =
        "{\"id\":91,\"kind\":\"core.pr.merge\",\"payload\":{\"prId\":42,"
        "\"explicit\":true}}";
    DA_CHECK(bridge.HandleMessage(request).find("E_NATIVE_CONSENT_REQUIRED") !=
             std::string::npos);
    DA_CHECK(calls == 1 && !title.empty() && Has(body, L"Fusionar") &&
             Has(body, L"n.º 42"));
    answer = true;
    DA_CHECK(bridge.HandleMessage(request).find("E_NATIVE_CONSENT_REQUIRED") ==
             std::string::npos);
    DA_CHECK(calls == 2);
    // Un kind que no exige consentimiento no pregunta.
    bridge.HandleMessage("{\"id\":92,\"kind\":\"init\",\"payload\":{}}");
    DA_CHECK(calls == 2);
  }
  // Sin propietario ni presentador: denegado, sin diálogo.
  {
    beats::Bridge bridge;
    bridge.BindServices(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                        nullptr);
    DA_CHECK(bridge
                 .HandleMessage(
                     "{\"id\":93,\"kind\":\"core.screenshot\",\"payload\":{}}")
                 .find("E_NATIVE_CONSENT_REQUIRED") != std::string::npos);
  }
  std::cout << "[PASS] consentimiento nativo: acción + recurso por capacidad "
               "(18 kinds), sin secretos, texto de la página neutralizado\n";

  // 6. Hilo: el worker pide, el diálogo se presenta EN el hilo de UI de la
  // ventana propietaria.
  {
    HWND owner = MakeConsentOwner();
    beats::Bridge bridge;
    bridge.BindServices(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                        nullptr);
    bridge.SetDialogOwner(owner);
    std::atomic<int> calls{0};
    std::thread::id presenterThread;
    HWND presenterOwner = nullptr;
    std::wstring presenterBody;
    std::atomic<bool> answer{false};
    bridge.SetConsentPresenter(
        [&](void *o, const std::wstring &, const std::wstring &b) {
          ++calls;
          presenterThread = std::this_thread::get_id();
          presenterOwner = static_cast<HWND>(o);
          presenterBody = b;
          return answer.load();
        });
    const std::string request =
        "{\"id\":94,\"kind\":\"core.order.ship\",\"payload\":{\"orderId\":7}}";
    const auto onWorker = [&](bool expectConsent) {
      std::string reply;
      std::atomic<bool> done{false};
      std::thread worker([&] {
        reply = bridge.HandleMessage(request);
        done = true;
      });
      PumpUntil(done, 10);
      worker.join();
      DA_CHECK((reply.find("E_NATIVE_CONSENT_REQUIRED") != std::string::npos) ==
               expectConsent);
    };
    answer = false;
    onWorker(true);
    DA_CHECK(calls == 1);
    DA_CHECK(presenterThread == std::this_thread::get_id() &&
             "dialog must open on the UI thread that owns the window");
    DA_CHECK(presenterOwner == owner && Has(presenterBody, L"n.º 7") &&
             Has(presenterBody, L"Enviar el trabajo"));
    answer = true;
    onWorker(false);
    DA_CHECK(calls == 2);
    // Desde el propio hilo de UI no hay salto de hilo.
    answer = false;
    DA_CHECK(bridge.HandleMessage(request).find("E_NATIVE_CONSENT_REQUIRED") !=
             std::string::npos);
    DA_CHECK(calls == 3 && presenterThread == std::this_thread::get_id());

    // La ventana propietaria desaparece antes de que el hilo de UI atienda la
    // solicitud: el worker no se queda colgado y la respuesta es «no».
    {
      std::string reply;
      std::atomic<bool> done{false};
      const int before = calls;
      std::thread worker([&] {
        reply = bridge.HandleMessage(request);
        done = true;
      });
      Sleep(300);
      DestroyWindow(owner);
      const auto start = std::chrono::steady_clock::now();
      while (!done &&
             std::chrono::steady_clock::now() - start < std::chrono::seconds(5))
        Sleep(10);
      DA_CHECK(done && "worker must not hang after the owner window dies");
      worker.join();
      DA_CHECK(reply.find("E_NATIVE_CONSENT_REQUIRED") != std::string::npos);
      DA_CHECK(calls == before && "a dead owner never shows the dialog");
    }
    // Apagado del host con una solicitud todavía sin mostrar.
    {
      HWND second = MakeConsentOwner();
      bridge.SetDialogOwner(second);
      std::string reply;
      std::atomic<bool> done{false};
      const int before = calls;
      std::thread worker([&] {
        reply = bridge.HandleMessage(request);
        done = true;
      });
      Sleep(300);
      beats::consent::Shutdown();
      const auto start = std::chrono::steady_clock::now();
      while (!done &&
             std::chrono::steady_clock::now() - start < std::chrono::seconds(5))
        Sleep(10);
      beats::consent::ShutdownFlag() = false;
      DA_CHECK(done && "worker must be released by host shutdown");
      worker.join();
      DA_CHECK(reply.find("E_NATIVE_CONSENT_REQUIRED") != std::string::npos);
      DA_CHECK(calls == before);
      DestroyWindow(second);
    }
  }
  std::cout << "[PASS] consentimiento nativo: el diálogo se presenta en el "
               "hilo de UI de la ventana propietaria; propietario muerto y "
               "apagado del host liberan al worker con «no»\n";
}

void test_malformed_json() {
  beats::Bridge bridge;
  std::string errResp = bridge.HandleMessage("{ malformed json }");
  DA_CHECK(errResp.find("\"error\"") != std::string::npos);
  std::cout << "[PASS] Malformed JSON test\n";
}

void test_unknown_kind() {
  beats::Bridge bridge;
  std::string errResp =
      bridge.HandleMessage("{\"id\":42, \"kind\":\"invalid_kind_123\"}");
  DA_CHECK(errResp.find("\"id\":42") != std::string::npos);
  DA_CHECK(errResp.find("\"error\"") != std::string::npos);
  DA_CHECK(errResp.find("E_UNKNOWN_KIND") != std::string::npos);
  std::cout << "[PASS] Unknown kind test\n";
}

void test_custom_handler() {
  beats::Bridge bridge;
  bridge.RegisterHandler("custom_action", [](const beats::BridgeMessage &msg) {
    return "{\"id\":" + std::to_string(msg.id) + ",\"result\":\"custom_ok\"}";
  });
  std::string resp =
      bridge.HandleMessage("{\"id\":99, \"kind\":\"custom_action\", "
                           "\"payload\":{\"key\":\"value\"}}");
  DA_CHECK(resp.find("\"id\":99") != std::string::npos);
  DA_CHECK(resp.find("\"result\":\"custom_ok\"") != std::string::npos);
  std::cout << "[PASS] Custom handler test\n";
}

void test_large_payload() {
  beats::Bridge bridge;
  std::string largeData(500000, 'x'); // 500 KB payload string
  std::string req =
      "{\"id\":100, \"kind\":\"init\", \"payload\":\"" + largeData + "\"}";
  std::string resp = bridge.HandleMessage(req);
  DA_CHECK(resp.find("\"id\":100") != std::string::npos);
  DA_CHECK(resp.find("\"status\":\"ok\"") != std::string::npos);
  std::cout << "[PASS] Large payload (500 KB) test\n";
}

void test_high_volume() {
  beats::Bridge bridge;
  auto start = std::chrono::high_resolution_clock::now();
  for (int i = 0; i < 10000; ++i) {
    std::string req =
        "{\"id\":" + std::to_string(i) + ",\"kind\":\"init\",\"payload\":{}}";
    std::string resp = bridge.HandleMessage(req);
    DA_CHECK(!resp.empty());
    DA_CHECK(resp.find("\"status\":\"ok\"") != std::string::npos);
  }
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double, std::milli> ms = end - start;
  std::cout << "[PASS] 10,000 messages test completed in " << ms.count()
            << " ms\n";
}

void test_all_13_kinds() {
  // Las operaciones de escritura/búsqueda usan datos propios, nunca el repo
  // ni las bases del usuario. La raíz se concede desde el lado nativo.
  struct Fixture {
    std::wstring cwd, root;
    Fixture() {
      wchar_t buffer[32768];
      const auto cwdSize = GetCurrentDirectoryW(32768, buffer);
      DA_CHECK(cwdSize > 0 && cwdSize < 32768);
      cwd.assign(buffer, cwdSize);
      const auto tempSize = GetTempPathW(32768, buffer);
      DA_CHECK(tempSize > 0 && tempSize < 32768);
      root = std::wstring(buffer, tempSize) + L"beats-bridge-" +
             std::to_wstring(GetCurrentProcessId());
      DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
      DA_CHECK(SetCurrentDirectoryW(root.c_str()));
    }
    ~Fixture() {
      DA_CHECK(SetCurrentDirectoryW(cwd.c_str()));
      DA_CHECK(DeleteFileW((root + L"\\test_bridge_doc.txt").c_str()));
      // hunk.accept puede crear el archivo; su ausencia es válida.
      if (!DeleteFileW((root + L"\\f.txt").c_str()))
        DA_CHECK(GetLastError() == ERROR_FILE_NOT_FOUND);
      bool removed = false;
      // TerminateProcess retorna antes de que cmd/conhost suelten su cwd.
      // Sólo se espera ese cierre transitorio; cualquier otro error falla.
      for (int attempt = 0; attempt < 40; ++attempt) {
        if (RemoveDirectoryW(root.c_str())) {
          removed = true;
          break;
        }
        if (GetLastError() != ERROR_SHARING_VIOLATION)
          break;
        Sleep(50);
      }
      if (!removed) {
        const auto error = GetLastError();
        std::cerr << "Fixture removal failed, win32=" << error << "\n";
        WIN32_FIND_DATAW entry{};
        HANDLE find = FindFirstFileW((root + L"\\*").c_str(), &entry);
        if (find != INVALID_HANDLE_VALUE) {
          do {
            std::wcerr << L"Fixture entry: " << entry.cFileName << L"\n";
          } while (FindNextFileW(find, &entry));
          FindClose(find);
        }
        DA_CHECK(false);
      }
    }
  } fixture;
  beats::Bridge bridge;
  beats::DocumentManager docMgr;
  std::string authorizationError;
  DA_CHECK(docMgr.AuthorizeWorkspaceRoot(fixture.root, authorizationError));
  beats::FileWatcher fileWatcher;
  beats::ProjectSearch projectSearch(docMgr);
  beats::HunkManager hunkMgr(docMgr);
  beats::PtyManager ptyMgr;
  beats::LspClient lspClient;
  beats::CoreClient coreClient(beats::CoreClient::InitMode::isolated_empty);

  bridge.BindServices(&docMgr, &fileWatcher, &projectSearch, &hunkMgr, &ptyMgr,
                      &lspClient, &coreClient);

  // 1. core.status
  std::string respCore = bridge.HandleMessage(
      "{\"id\":1, \"kind\":\"core.status\", \"payload\":{}}");
  DA_CHECK(respCore.find("\"status\":\"ok\"") != std::string::npos);

  // 2. doc.save
  std::wstring docPath = fixture.root + L"\\test_bridge_doc.txt";
  const int pathSize = WideCharToMultiByte(CP_UTF8, 0, docPath.c_str(), -1,
                                           nullptr, 0, nullptr, nullptr);
  std::string pathUtf8(pathSize, '\0');
  WideCharToMultiByte(CP_UTF8, 0, docPath.c_str(), -1, pathUtf8.data(),
                      pathSize, nullptr, nullptr);
  pathUtf8.pop_back();
  const std::string escapedPath = beats::JsonEscapePublic(pathUtf8);
  std::string respSave =
      bridge.HandleMessage("{\"id\":2, \"kind\":\"doc.save\", "
                           "\"payload\":{\"path\":\"" +
                           escapedPath + "\",\"content\":\"hello world\"}}");
  DA_CHECK(respSave.find("\"status\":\"ok\"") != std::string::npos);

  // 3. doc.open
  std::string respOpen =
      bridge.HandleMessage("{\"id\":3, \"kind\":\"doc.open\", "
                           "\"payload\":{\"path\":\"" +
                           escapedPath + "\"}}");
  DA_CHECK(respOpen.find("\"status\":\"ok\"") != std::string::npos);
  DA_CHECK(respOpen.find("hello world") != std::string::npos);
  DA_CHECK(respOpen.find("\"readOnly\":false") != std::string::npos);
  DA_CHECK(SetFileAttributesW(docPath.c_str(), FILE_ATTRIBUTE_READONLY));
  const auto readOnlyDoc = bridge.HandleMessage(
      "{\"id\":300,\"kind\":\"doc.open\",\"payload\":{\"path\":\"" +
      escapedPath + "\"}}");
  DA_CHECK(readOnlyDoc.find("\"readOnly\":true") != std::string::npos);
  DA_CHECK(SetFileAttributesW(docPath.c_str(), FILE_ATTRIBUTE_NORMAL));

  // 4. fs.watch
  std::string respWatch = bridge.HandleMessage(
      "{\"id\":4, \"kind\":\"fs.watch\", "
      "\"payload\":{\"path\":\"" +
      beats::JsonEscapePublic(pathUtf8.substr(0, pathUtf8.find_last_of("\\"))) +
      "\"}}");
  DA_CHECK(respWatch.find("\"status\":\"ok\"") != std::string::npos);

  // 5. fs.unwatch
  std::string respUnwatch = bridge.HandleMessage(
      "{\"id\":5, \"kind\":\"fs.unwatch\", \"payload\":{}}");
  DA_CHECK(respUnwatch.find("\"status\":\"ok\"") != std::string::npos);

  // 6. search.query
  std::string respSearch = bridge.HandleMessage(
      "{\"id\":6, \"kind\":\"search.query\", \"payload\":{\"query\":\"hello\", "
      "\"rootDir\":\"" +
      beats::JsonEscapePublic(pathUtf8.substr(0, pathUtf8.find_last_of("\\"))) +
      "\"}}");
  DA_CHECK(respSearch.find("\"status\":\"ok\"") != std::string::npos);
  DA_CHECK(respSearch.find("\"lineContent\"") != std::string::npos);

  // 7. search.replace
  std::string respReplace = bridge.HandleMessage(
      "{\"id\":7, \"kind\":\"search.replace\", "
      "\"payload\":{\"query\":\"hello\", \"replacement\":\"hi\", "
      "\"rootDir\":\"" +
      beats::JsonEscapePublic(pathUtf8.substr(0, pathUtf8.find_last_of("\\"))) +
      "\"}}");
  DA_CHECK(respReplace.find("\"status\":\"ok\"") != std::string::npos);

  const std::string searchRoot =
      beats::JsonEscapePublic(pathUtf8.substr(0, pathUtf8.find_last_of("\\")));
  const auto afterOld = bridge.HandleMessage(
      "{\"id\":70,\"kind\":\"search.query\",\"payload\":{\"query\":\"hello\","
      "\"rootDir\":\"" +
      searchRoot + "\"}}");
  DA_CHECK(afterOld.find("\"status\":\"ok\"") != std::string::npos);
  DA_CHECK(afterOld.find("\"matches\":[]") != std::string::npos);
  const auto afterNew = bridge.HandleMessage(
      "{\"id\":71,\"kind\":\"search.query\",\"payload\":{\"query\":\"hi\","
      "\"rootDir\":\"" +
      searchRoot + "\"}}");
  DA_CHECK(afterNew.find("\"status\":\"ok\"") != std::string::npos);
  DA_CHECK(afterNew.find("\"lineContent\":\"hi\"") != std::string::npos);
  std::cout << "[PASS] search.replace -> search.query cache invalidation\n";

  // 8. hunk.accept
  std::string respHunkAcc = bridge.HandleMessage(
      "{\"id\":8, \"kind\":\"hunk.accept\", "
      "\"payload\":{\"path\":\"" +
      beats::JsonEscapePublic(pathUtf8.substr(0, pathUtf8.find_last_of("\\")) +
                              "\\f.txt") +
      "\",\"hunkId\":1,"
      "\"originalContent\":\"a\",\"newContent\":\"b\"}}");
  DA_CHECK(respHunkAcc.find("\"status\":\"ok\"") != std::string::npos);

  // 9. hunk.reject
  std::string respHunkRej = bridge.HandleMessage(
      "{\"id\":9, \"kind\":\"hunk.reject\", "
      "\"payload\":{\"path\":\"" +
      beats::JsonEscapePublic(pathUtf8.substr(0, pathUtf8.find_last_of("\\")) +
                              "\\f.txt") +
      "\",\"hunkId\":1,"
      "\"originalContent\":\"a\",\"newContent\":\"b\"}}");
  DA_CHECK(respHunkRej.find("\"status\":\"ok\"") != std::string::npos);

  // 10. pty.spawn
  std::string respPtySpawn = bridge.HandleMessage(
      "{\"id\":10, \"kind\":\"pty.spawn\", "
      "\"payload\":{\"shellPath\":\"cmd.exe\",\"workingDir\":\"" +
      beats::JsonEscapePublic(pathUtf8.substr(0, pathUtf8.find_last_of("\\"))) +
      "\"}}");
  DA_CHECK(respPtySpawn.find("\"status\":\"ok\"") != std::string::npos);
  // la respuesta dice por qué vía quedó la terminal.
  DA_CHECK(respPtySpawn.find("\"mode\":\"conpty\"") != std::string::npos ||
           respPtySpawn.find("\"mode\":\"pipes\"") != std::string::npos);

  // 11. pty.write
  std::string respPtyWrite = bridge.HandleMessage(
      "{\"id\":11, \"kind\":\"pty.write\", "
      "\"payload\":{\"terminalId\":1,\"data\":\"dir\\r\\n\"}}");
  DA_CHECK(respPtyWrite.find("\"status\":\"ok\"") != std::string::npos);

  // 11 bis. pty.resize (23-09): llega a la pseudoconsola y rechaza tamaños
  // absurdos. Con ConPTY la respuesta es resized:true.
  std::string respPtyResize = bridge.HandleMessage(
      "{\"id\":111, \"kind\":\"pty.resize\", "
      "\"payload\":{\"terminalId\":1,\"cols\":36,\"rows\":4}}");
  DA_CHECK(respPtyResize.find("\"status\":\"ok\"") != std::string::npos);
  if (respPtySpawn.find("\"mode\":\"conpty\"") != std::string::npos)
    DA_CHECK(respPtyResize.find("\"resized\":true") != std::string::npos);
  std::string respPtyResizeMal = bridge.HandleMessage(
      "{\"id\":112, \"kind\":\"pty.resize\", "
      "\"payload\":{\"terminalId\":1,\"cols\":0,\"rows\":4}}");
  DA_CHECK(respPtyResizeMal.find("\"error\"") != std::string::npos);

  // 12. pty.kill
  std::string respPtyKill = bridge.HandleMessage(
      "{\"id\":12, \"kind\":\"pty.kill\", \"payload\":{\"terminalId\":1}}");
  DA_CHECK(respPtyKill.find("\"status\":\"ok\"") != std::string::npos);

  // 13. lsp.request
  std::string respLsp = bridge.HandleMessage(
      "{\"id\":13, \"kind\":\"lsp.request\", "
      "\"payload\":{\"serverCmd\":\"cmd.exe\",\"requestId\":10,\"method\":"
      "\"initialize\",\"params\":\"{}\"}}");
  DA_CHECK(respLsp.find("LSP fuera del registro del host") !=
           std::string::npos);

  std::cout << "[PASS] All 13 module kinds registered and bound test\n";
}

// Regresión del cuelgue del carril rápido (hallazgo de la prueba de usuario
// real del 2026-09-13): un motor que ACEPTA la tubería pero nunca contesta
// dejaba `EngineSupervisor::Status()` dentro de un ReadFile síncrono sin
// plazo. Esa llamada corre en el ÚNICO hilo que atiende los `core.*` rápidos,
// así que la cabina entera quedaba muda con cientos de promesas JS en cola y
// el Monitor pegado en «Consultando el motor…» para siempre.
//
// El test crea una tubería muda de verdad —acepta la conexión y no lee ni
// escribe jamás— y pide `Status()` en otro hilo: sin la I/O acotada no vuelve
// nunca; con ella devuelve error en unos segundos.
void test_mute_engine_does_not_hang() {
  const std::string pipeName =
      "beats-mute-" + std::to_string(GetCurrentProcessId());
  const std::string full = "\\\\.\\pipe\\" + pipeName;
  HANDLE srv = CreateNamedPipeA(full.c_str(), PIPE_ACCESS_DUPLEX,
                                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                1, 4096, 4096, 0, nullptr);
  DA_CHECK(srv != INVALID_HANDLE_VALUE);
  // Acepta y enmudece: nunca se lee ni se escribe sobre la conexión.
  std::thread([srv] {
    ConnectNamedPipe(srv, nullptr);
    Sleep(60000);
  }).detach();

  // El hijo sólo tiene que existir mientras dure el chequeo inicial; la
  // tubería que importa es la muda, que YA está creada y escuchando.
  beats::EngineSupervisor sup;
  DA_CHECK(sup.Start(L"C:\\Windows\\System32\\cmd.exe", pipeName));

  std::atomic<bool> done{false};
  beats::EngineSupervisor::StatusResult res;
  std::thread t([&] {
    res = sup.Status();
    done = true;
  });
  const auto t0 = std::chrono::steady_clock::now();
  while (!done.load() &&
         std::chrono::steady_clock::now() - t0 < std::chrono::seconds(40))
    Sleep(50);
  if (!done.load()) {
    std::cout << "[FAIL] Status() colgado ante un motor mudo: el cuelgue del "
                 "carril rápido sigue vivo\n";
    // El hilo queda bloqueado para siempre en el ReadFile síncrono: no hay
    // forma de despegarlo, así que el test se suicida con el fallo a la vista.
    std::_Exit(1);
  }
  t.join();
  DA_CHECK(!res.online);
  std::cout << "[PASS] Motor mudo: Status() devuelve error en vez de colgar\n";
}

// ── E3.39-D: vectores adversariales contra el parser del bridge ────────
//
// El parser anterior localizaba claves por SUBSTRING, sin saber en qué nivel
// del documento estaba: una `"kind"` escrita dentro del payload ganaba a la
// del sobre si aparecía antes en el texto, una `}` dentro de una cadena
// truncaba el payload, una `"id"` metida en un texto se tomaba como el
// identificador del mensaje y el reparto de colas de main.cpp no veía
// `"kind": "core.x"` cuando llevaba espacios. Estos casos fijan que ya no.

void test_nested_kind_cannot_reach_a_handler() {
  // La clave `"kind"` anidada en el payload no puede invocar un handler.
  beats::Bridge bridge;
  bool called = false;
  bridge.RegisterHandler(
      "evil.nested", [&called](const beats::BridgeMessage &msg) {
        called = true;
        return "{\"id\":" + std::to_string(msg.id) + ",\"status\":\"PWNED\"}";
      });
  std::string resp = bridge.HandleMessage(
      "{\"payload\":{\"kind\":\"evil.nested\"},\"id\":9,\"kind\":\"ping\"}");
  DA_CHECK(!called);
  DA_CHECK(resp.find("pong") != std::string::npos);
  std::cout << "[PASS] kind anidada en el payload no alcanza ningun handler\n";
}

void test_extract_kind_for_queue_routing() {
  // `"kind": "core.x"` con espacios: el reparto de colas lo leía por
  // substring `"kind":"core.` y lo mandaba al hilo equivocado.
  DA_CHECK(beats::Bridge::ExtractKind(
               "{\"id\":1, \"kind\": \"core.status\"}") == "core.status");
  DA_CHECK(beats::Bridge::ExtractKind(
               "{\"id\":1,\"kind\":\"search.query\",\"payload\":{}}") ==
           "search.query");
  // Una `"kind"` DENTRO del payload no es el tipo del mensaje.
  DA_CHECK(beats::Bridge::ExtractKind(
               "{\"payload\":{\"kind\":\"pty.spawn\"},\"id\":1,"
               "\"kind\":\"init\"}") == "init");
  // Sin kind de nivel superior: cadena vacía, no la anidada.
  DA_CHECK(beats::Bridge::ExtractKind("{\"id\":1,\"payload\":{\"kind\":\"x\"}}")
               .empty());
  std::cout << "[PASS] ExtractKind lee el tipo del sobre (E3.39-D)\n";
}

void test_brace_inside_string_does_not_truncate() {
  // Una `}` dentro de una cadena NO cierra el payload: el contador de llaves
  // viejo no veía cadenas y cortaba `"x}y"` a mitad, perdiendo campos.
  beats::Bridge bridge;
  bridge.RegisterHandler("echo", [](const beats::BridgeMessage &msg) {
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"echo\":" + msg.payloadJson + "}";
  });
  std::string resp = bridge.HandleMessage(
      "{\"id\":3,\"kind\":\"echo\",\"payload\":{\"a\":\"x}y\",\"b\":2}}");
  DA_CHECK(resp.find("\"a\":\"x}y\"") != std::string::npos);
  DA_CHECK(resp.find("\"b\":2") != std::string::npos);
  std::cout << "[PASS] llave dentro de cadena no trunca el payload\n";
}

void test_id_inside_string_is_not_the_message_id() {
  // `"id":999` escrito dentro de un texto del payload no es el id del
  // mensaje aunque aparezca antes en el documento.
  beats::Bridge bridge;
  std::string resp = bridge.HandleMessage(
      "{\"kind\":\"ping\",\"payload\":{\"note\":\"lleva \\\"id\\\":999 "
      "dentro\"},\"id\":77}");
  DA_CHECK(resp.find("\"id\":77") != std::string::npos);
  std::cout << "[PASS] id escrita en una cadena no es el id del mensaje\n";
}

void test_getstringprop_reads_top_level_only() {
  // GetStringProp es la lectura que hacen TODOS los handlers: una clave
  // anidada o incrustada en un texto no puede suplantar a la real.
  std::string v = beats::GetStringProp(
      "{\"wrap\":{\"path\":\"ANIDADA\"},\"path\":\"CORRECTA\"}", "path");
  DA_CHECK(v == "CORRECTA");
  std::string w = beats::GetStringProp(
      "{\"note\":\"dice \\\"path\\\":\\\"FAKE\\\"\",\"path\":\"REAL\"}",
      "path");
  DA_CHECK(w == "REAL");
  std::cout << "[PASS] GetStringProp solo lee claves del nivel superior\n";
}

void test_getstringprop_decodes_unicode_escapes() {
  // 23-09: pty.write recibe lo tecleado tal como lo escapa JSON.stringify.
  // Flecha arriba, Ctrl+C y los avisos de foco de ConPTY son \u001b y
  // \u0003; antes llegaban al shell como el texto "u001b[A".
  const std::string teclas = beats::GetStringProp(
      "{\"terminalId\":1,\"data\":\"\\u001b[A\\u0003\\u001B[I\"}", "data");
  DA_CHECK(teclas == std::string("\x1b[A\x03\x1b[I"));
  // Fuera del ASCII: dos y tres bytes, y un par sustituto (emoji).
  const std::string texto = beats::GetStringProp(
      "{\"data\":\"\\u00e9\\u20ac\\ud83d\\ude00\"}", "data");
  DA_CHECK(texto == std::string("\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80"));
  // \b, \f y \/ tambien son escapes de JSON.
  DA_CHECK(beats::GetStringProp("{\"d\":\"a\\bb\\fc\\/d\"}", "d") ==
           std::string("a\bb\fc/d"));
  // Un sustituto suelto no es texto: U+FFFD, no bytes rotos.
  DA_CHECK(beats::GetStringProp("{\"d\":\"\\ud83d!\"}", "d") ==
           std::string("\xef\xbf\xbd!"));
  // Un \u mal formado no se come lo que sigue.
  DA_CHECK(beats::GetStringProp("{\"d\":\"\\uZZZZ\"}", "d") == "uZZZZ");
  std::cout << "[PASS] GetStringProp decodifica los escapes \\u de JSON\n";
}

void test_json_escape_covers_every_control_below_0x20() {
  // un solo caracter de control en crudo dentro de una cadena invalida el
  // documento JSON entero. PostWebMessageAsJson no entrega nada (ni error) y la
  // peticion se queda colgada en silencio — asi murio la terminal, que lleva
  // secuencias ANSI (ESC = 0x1B) en cada lectura de ConPTY. JsonEscape debe
  // cubrir TODO control < 0x20, no solo \n \r \t: si vuelve a dejar uno crudo,
  // esta prueba cae. La comparacion es por SECUENCIA EXACTA, no solo por
  // "empieza por '\'": una salida invalida como `\x01` (que no es JSON) o una
  // mayuscula donde el codigo emite minuscula deben hacer caer la prueba.
  static const char kHex[] = "0123456789abcdef";
  for (int cp = 0x00; cp < 0x20; ++cp) {
    const std::string out =
        beats::JsonEscapePublic(std::string(1, static_cast<char>(cp)));
    std::string expected;
    switch (cp) {
    case '\b':
      expected = "\\b";
      break;
    case '\f':
      expected = "\\f";
      break;
    case '\n':
      expected = "\\n";
      break;
    case '\r':
      expected = "\\r";
      break;
    case '\t':
      expected = "\\t";
      break;
    default:
      // El codigo emite `\u%04x`: prefijo `\u00` y el resto en minusculas.
      expected = "\\u00";
      expected += kHex[(cp >> 4) & 0x0f];
      expected += kHex[cp & 0x0f];
      break;
    }
    DA_CHECK(out == expected);
  }
  // Los cortos de JSON se conservan tal cual.
  DA_CHECK(beats::JsonEscapePublic(std::string("\n\r\t\b\f")) ==
           "\\n\\r\\t\\b\\f");
  // Comillas y barra invertida siguen escapandose.
  DA_CHECK(beats::JsonEscapePublic("\"\\") == "\\\"\\\\");
  std::cout << "[PASS] JsonEscape cubre todo control < 0x20 (E-03)\n";
}

void test_wrong_types_and_extra_fields() {
  beats::Bridge bridge;
  // id como texto: no hay identificador numérico válido.
  std::string r1 = bridge.HandleMessage("{\"id\":\"abc\",\"kind\":\"ping\"}");
  DA_CHECK(r1.find("\"error\"") != std::string::npos);
  // kind como número: no es un tipo válido.
  std::string r2 = bridge.HandleMessage("{\"id\":1,\"kind\":5}");
  DA_CHECK(r2.find("\"error\"") != std::string::npos);
  // Campos extra (incluido un `"id"` anidado) se ignoran sin romper nada.
  std::string r3 = bridge.HandleMessage(
      "{\"id\":2,\"kind\":\"ping\",\"extra\":{\"a\":[1,2,{\"id\":3}]}}");
  DA_CHECK(r3.find("pong") != std::string::npos);
  DA_CHECK(r3.find("\"id\":2") != std::string::npos);
  // Payload escalar: no rompe el parser; el handler ve "{}".
  std::string r4 =
      bridge.HandleMessage("{\"id\":4,\"kind\":\"ping\",\"payload\":5}");
  DA_CHECK(r4.find("pong") != std::string::npos);
  std::cout << "[PASS] tipos incorrectos y campos extra (E3.39-D)\n";
}

// ---------------------------------------------------------------------------
// E4/E5: core.git.status es de SOLO LECTURA y core.git.commit crea
// un commit LOCAL (sin push) con el mensaje y la lista exacta de archivos que
// el usuario aprobo en el dialogo nativo.
// ---------------------------------------------------------------------------
static DWORD RunFixtureProcess(const std::wstring &application,
                               const std::wstring &commandLine,
                               const std::wstring &cwd) {
  std::wstring line = commandLine;
  std::vector<wchar_t> buffer(line.begin(), line.end());
  buffer.push_back(0);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION child{};
  DA_CHECK(CreateProcessW(application.c_str(), buffer.data(), nullptr, nullptr,
                          FALSE, CREATE_NO_WINDOW, nullptr, cwd.c_str(),
                          &startup, &child));
  DA_CHECK(WaitForSingleObject(child.hProcess, 60000) == WAIT_OBJECT_0);
  DWORD code = 1;
  DA_CHECK(GetExitCodeProcess(child.hProcess, &code));
  CloseHandle(child.hThread);
  CloseHandle(child.hProcess);
  return code;
}

static DWORD RunFixtureGit(const std::wstring &cwd,
                           const std::vector<std::wstring> &args) {
  const auto &program = beats::security::GitProgram();
  DA_CHECK(!program.executable.empty());
  std::wstring line = beats::security::QuoteArgument(program.executable);
  for (const auto &arg : args)
    line += L" " + beats::security::QuoteArgument(arg);
  return RunFixtureProcess(program.executable, line, cwd);
}

static void RemoveFixtureTree(const std::wstring &path) {
  wchar_t system[MAX_PATH];
  const UINT length = GetSystemDirectoryW(system, MAX_PATH);
  DA_CHECK(length && length < MAX_PATH);
  const std::wstring cmd = std::wstring(system, length) + L"\\cmd.exe";
  const std::wstring line =
      L"\"" + cmd + L"\" /d /s /c rmdir /s /q \"" + path + L"\"";
  RunFixtureProcess(cmd, line, path);
}

static bool test_seg011_h6_integration() {
  const auto cwd = std::filesystem::current_path();
  const auto root =
      cwd / (L"beats_seg011_h6_" + std::to_wstring(GetCurrentProcessId()));
  DA_CHECK(std::filesystem::create_directory(root));
  const std::vector<std::wstring> visible = {L"tracked.txt",
                                             L"ordinary.tmp",
                                             L".devagents-save-.tmp",
                                             L"x.devagents-save-1.tmp",
                                             L".devagents-save-1.tmp.bak",
                                             L"sub-\u00f1/child.txt"};
  const std::vector<std::wstring> temporary = {
      L".devagents-save-orphan.tmp", L".DEVAGENTS-SAVE-UPPER.TMP",
      L"sub-\u00f1/.devagents-save-child.tmp",
      L".devagents-save-dir.tmp/child.txt",
      L".devagents-save-dir.tmp/nested/child.txt"};
  DA_CHECK(std::filesystem::create_directory(root / L"sub-\u00f1"));
  DA_CHECK(
      std::filesystem::create_directory(root / L".devagents-save-dir.tmp"));
  DA_CHECK(std::filesystem::create_directory(
      root / L".devagents-save-dir.tmp/nested"));
  const auto seed = [&](const std::wstring &relative) {
    std::ofstream out(root / relative, std::ios::binary);
    out << "seg011needle\n";
    DA_CHECK(out.good());
  };
  for (const auto &relative : visible)
    seed(relative);
  for (const auto &relative : temporary)
    seed(relative);
  bool passed = true;
  size_t checks = 0;
  const auto check = [&](bool ok, const char *name) {
    ++checks;
    std::cout << "CK-SEG-011 H6 " << name << ": " << (ok ? "PASS" : "FAIL")
              << std::endl;
    passed = passed && ok;
  };
  {
    beats::DocumentManager docs;
    std::string error;
    const bool authorized = docs.AuthorizeWorkspaceRoot(root.wstring(), error);
    check(authorized, "carpeta de fixture autorizada");
    if (!authorized)
      std::cout << "CK-SEG-011 H6 NO VERIFICADO: " << error << std::endl;
    if (authorized) {
      // Commits only in this disposable fixture, never in the project.
      DA_CHECK(RunFixtureGit(root.wstring(), {L"init", L"-q"}) == 0);
      DA_CHECK(RunFixtureGit(root.wstring(), {L"config", L"user.email",
                                              L"seg011@example.invalid"}) == 0);
      DA_CHECK(RunFixtureGit(root.wstring(), {L"config", L"user.name",
                                              L"DevAgents Test"}) == 0);
      DA_CHECK(RunFixtureGit(root.wstring(),
                             {L"config", L"commit.gpgsign", L"false"}) == 0);
      DA_CHECK(RunFixtureGit(root.wstring(), {L"add", L"--", L"tracked.txt"}) ==
               0);
      DA_CHECK(RunFixtureGit(root.wstring(),
                             {L"-c", L"core.hooksPath=NUL", L"commit", L"-q",
                              L"-m", L"fixture"}) == 0);
      beats::ProjectSearch search(docs);
      beats::Bridge bridge;
      bridge.BindServices(&docs, nullptr, &search, nullptr, nullptr, nullptr,
                          nullptr);
      const auto quotedRoot = beats::JsonEscapePublic(root.u8string());
      const auto request = [&](const std::string &kind,
                               const std::string &payload) {
        return bridge.HandleMessage("{\"id\":611,\"kind\":\"" + kind +
                                    "\",\"payload\":{" + payload + "}}");
      };
      auto response = request("fs.list", "\"path\":\"" + quotedRoot + "\"");
      check(response.find("\"error\"") == std::string::npos &&
                response.find(".devagents-save-orphan.tmp") ==
                    std::string::npos &&
                response.find(".DEVAGENTS-SAVE-UPPER.TMP") ==
                    std::string::npos &&
                response.find(".devagents-save-dir.tmp") == std::string::npos &&
                response.find("ordinary.tmp") != std::string::npos &&
                response.find(".devagents-save-.tmp") != std::string::npos,
            "fs.list excluye solo temporales reservados");
      for (const auto *relative :
           {"/.devagents-save-dir.tmp", "/.DEVAGENTS-SAVE-DIR.TMP/",
            "\\.devagents-save-dir.tmp\\nested"}) {
        const auto path = beats::JsonEscapePublic(root.u8string() + relative);
        response = request("fs.list", "\"path\":\"" + path + "\"");
        check(response.find("\"error\"") != std::string::npos &&
                  response.find("E_LIST_SAVE_TEMPORARY") != std::string::npos &&
                  response.find("\"entries\"") == std::string::npos &&
                  response.find("child.txt") == std::string::npos,
              "fs.list rechaza ruta temporal directa y descendiente");
      }
      const auto options =
          "\"rootDir\":\"" + quotedRoot + "\",\"query\":\"seg011needle\"";
      for (const auto *extra : {"", ",\"isRegex\":true"}) {
        response = request("search.query", options + extra);
        size_t count = 0, pos = 0;
        while ((pos = response.find("\"filePath\":", pos)) !=
               std::string::npos) {
          ++count;
          ++pos;
        }
        check(response.find("\"error\"") == std::string::npos &&
                  count == visible.size() &&
                  response.find(".devagents-save-orphan.tmp") ==
                      std::string::npos &&
                  response.find(".devagents-save-child.tmp") ==
                      std::string::npos,
              *extra ? "search.query regex" : "search.query literal");
      }
      response =
          request("search.replace", options + ",\"replacement\":\"changed\"");
      check(response.find("\"error\"") == std::string::npos &&
                response.find("\"replacedCount\":6") != std::string::npos,
            "search.replace modifica solo seis archivos visibles");
      for (const auto &relative : temporary) {
        std::ifstream in(root / relative, std::ios::binary);
        check(std::string(std::istreambuf_iterator<char>(in), {}) ==
                  "seg011needle\n",
              "temporal intacto despues de reemplazar");
      }
      response =
          request("checkpoint.create", "\"root\":\"" + quotedRoot + "\"");
      check(response.find("\"error\"") == std::string::npos &&
                response.find("\"untrackedCount\":5") != std::string::npos,
            "checkpoint excluye temporales de raiz y subcarpeta Unicode");
    }
  }
  DA_CHECK(root.parent_path() == cwd &&
           root.filename().wstring().find(L"beats_seg011_h6_") == 0);
  for (const auto &entry : std::filesystem::recursive_directory_iterator(root))
    if (entry.is_regular_file())
      std::filesystem::permissions(entry.path(),
                                   std::filesystem::perms::owner_write,
                                   std::filesystem::perm_options::add);
  DA_CHECK(std::filesystem::remove_all(root) > 0);
  std::cout << "CK-SEG-011 H6 integracion: " << checks << " comprobaciones; "
            << (passed ? "PASS" : "FAIL") << std::endl;
  return passed;
}

// Remate D5 (10-nov): `core.git.status` se colgaba hasta el plazo de 60 s de
// la cabina. Causa: la captura esperaba el EOF de la tuberia, y otro proceso
// conservaba una copia del extremo de escritura (heredada). Aqui la copia la
// conserva un nieto deterministico: este mismo ejecutable con `--d5-hijo`
// lanza un nieto (`--d5-nieto`, vive 6 s) que hereda sus handles, escribe
// «hola» y termina en el acto. Antes (lector hasta EOF, como el codigo
// anterior) la lectura seguia bloqueada con el hijo ya muerto; ahora vuelve
// con toda la salida en menos de 4 s.
static int d5_child_main(bool grandchild) {
  if (grandchild) {
    Sleep(6000);
    return 0;
  }
  wchar_t self[MAX_PATH];
  const DWORD len = GetModuleFileNameW(nullptr, self, MAX_PATH);
  wchar_t sys[MAX_PATH];
  const UINT sysLen = GetSystemDirectoryW(sys, MAX_PATH);
  if (len == 0 || len >= MAX_PATH || sysLen == 0 || sysLen >= MAX_PATH)
    return 2;
  std::wstring line = L"\"" + std::wstring(self, len) + L"\" --d5-nieto";
  std::vector<wchar_t> buf(line.begin(), line.end());
  buf.push_back(0);
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  // bInheritHandles=TRUE sin lista: el nieto se queda con la tuberia.
  if (!CreateProcessW(self, buf.data(), nullptr, nullptr, TRUE,
                      CREATE_NO_WINDOW, nullptr, sys, &si, &pi))
    return 3;
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  std::fputs("hola\n", stdout);
  std::fflush(stdout);
  return 0;
}

static void test_run_capture_does_not_wait_for_inherited_pipe_copies() {
  wchar_t selfBuf[MAX_PATH];
  const DWORD selfLen = GetModuleFileNameW(nullptr, selfBuf, MAX_PATH);
  DA_CHECK(selfLen > 0 && selfLen < MAX_PATH);
  wchar_t sys[MAX_PATH];
  const UINT sysLen = GetSystemDirectoryW(sys, MAX_PATH);
  DA_CHECK(sysLen > 0 && sysLen < MAX_PATH);
  const std::wstring cmd(selfBuf, selfLen);
  const std::vector<std::wstring> args = {L"--d5-hijo"};

  // ANTES: el lector hasta EOF del codigo anterior, sobre el mismo caso.
  {
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    HANDLE readOut = nullptr, writeOut = nullptr;
    DA_CHECK(CreatePipe(&readOut, &writeOut, &sa, 0));
    SetHandleInformation(readOut, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = writeOut;
    si.hStdError = writeOut;
    std::wstring line = L"\"" + cmd + L"\" --d5-hijo";
    std::vector<wchar_t> buf(line.begin(), line.end());
    buf.push_back(0);
    PROCESS_INFORMATION pi{};
    DA_CHECK(CreateProcessW(cmd.c_str(), buf.data(), nullptr, nullptr, TRUE,
                            CREATE_NO_WINDOW, nullptr, sys, &si, &pi));
    CloseHandle(writeOut);
    struct NaiveReader {
      static DWORD WINAPI Run(LPVOID raw) {
        char chunk[256];
        DWORD got = 0;
        while (ReadFile(static_cast<HANDLE>(raw), chunk, sizeof(chunk), &got,
                        nullptr) &&
               got > 0) {
        }
        return 0;
      }
    };
    HANDLE reader =
        CreateThread(nullptr, 0, NaiveReader::Run, readOut, 0, nullptr);
    DA_CHECK(reader);
    DA_CHECK(WaitForSingleObject(pi.hProcess, 5000) == WAIT_OBJECT_0);
    const bool blockedAfterExit =
        WaitForSingleObject(reader, 2000) == WAIT_TIMEOUT;
    // Libera al lector de la medicion (el nieto termina solo en ~8 s).
    while (WaitForSingleObject(reader, 50) == WAIT_TIMEOUT)
      CancelSynchronousIo(reader);
    CloseHandle(reader);
    CloseHandle(readOut);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    DA_CHECK(
        blockedAfterExit &&
        "el escenario debe reproducir el cuelgue: EOF retenido por el nieto");
    std::cout
        << "[INFO] D5 antes: lector hasta EOF sigue bloqueado 2 s despues "
           "de que el hijo termino\n";
  }

  // DESPUES: RunCapture vuelve en cuanto el hijo termina, con su salida.
  const auto t0 = std::chrono::steady_clock::now();
  std::string err;
  const std::string out = beats::RunCapture("", cmd, args, err, 30000);
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - t0)
                      .count();
  if (!err.empty() || out.find("hola") == std::string::npos || ms >= 4000)
    std::cerr << "[FAIL] D5 RunCapture: err=" << err << " out=" << out
              << " ms=" << ms << std::endl;
  DA_CHECK(err.empty());
  DA_CHECK(out.find("hola") != std::string::npos);
  DA_CHECK(ms < 4000);
  std::cout << "[PASS] D5 RunCapture no espera copias heredadas de su tuberia ("
            << ms << " ms con un nieto vivo ~6 s)\n";
}

// Remate D7: lo que pide autorizacion nativa va a su propio carril (main.cpp);
// el carril rapido no espera a un dialogo abierto.
static void test_native_consent_kinds_for_queue_routing() {
  DA_CHECK(beats::RequiresNativeConsent("core.permissions.set"));
  DA_CHECK(beats::RequiresNativeConsent("core.mcp.connect"));
  // acciones corrientes de IDE, sin diálogo ni carril D7.
  for (const char *kind :
       {"core.git.init", "core.git.commit", "core.external.options.set",
        "core.mcp.call", "core.permissions.forgetElevated"})
    DA_CHECK(!beats::RequiresNativeConsent(kind));
  DA_CHECK(!beats::RequiresNativeConsent("core.status"));
  DA_CHECK(!beats::RequiresNativeConsent("core.git.status"));
  DA_CHECK(!beats::RequiresNativeConsent("core.order.events"));
  std::cout << "[PASS] D7 kinds con autorizacion nativa identificados para su "
               "carril\n";
}

// (12-nov): permisos como Claude Code, Codex y VS Code. Endurecer
// nunca pregunta; ampliar sí; Auto y Omitir se habilitan una vez y el host lo
// recuerda en la carpeta de datos (aquí, una temporal); la página no puede
// colar una ampliación con un JSON que el host lea distinto que el motor.
static void test_permission_consent_like_other_ides() {
  wchar_t tempBase[MAX_PATH + 1];
  const DWORD tempLen = GetTempPathW(MAX_PATH + 1, tempBase);
  DA_CHECK(tempLen && tempLen <= MAX_PATH);
  const std::wstring dir = std::wstring(tempBase, tempLen) +
                           L"devagents-pub018-" +
                           std::to_wstring(GetCurrentProcessId());
  DA_CHECK(CreateDirectoryW(dir.c_str(), nullptr) ||
           GetLastError() == ERROR_ALREADY_EXISTS);
  const std::wstring memory = dir + L"\\" + beats::kElevatedModesFile;
  if (!DeleteFileW(memory.c_str()))
    DA_CHECK(GetLastError() == ERROR_FILE_NOT_FOUND);
  const auto memoryText = [&] {
    std::ifstream in(memory.c_str(), std::ios::binary);
    return in.good() ? std::string(std::istreambuf_iterator<char>(in), {})
                     : std::string("(no existe)");
  };

  beats::Bridge bridge;
  bridge.BindServices(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                      nullptr);
  bridge.SetConsentMemoryDir(dir);
  // Motor simulado: lo vigente y lo que recibe el handler (ya canónico).
  std::string current = "{\"mode\":\"normal\",\"allow\":[],\"deny\":[\"rm\"]}";
  bool readable = true;
  bridge.SetPermissionReader([&](std::string &json, std::string &error) {
    if (!readable) {
      error = "motor parado (simulado)";
      return false;
    }
    json = current;
    return true;
  });
  std::vector<std::string> applied;
  bridge.RegisterHandler(
      "core.permissions.set", [&](const beats::BridgeMessage &msg) {
        applied.push_back(beats::GetStringProp(msg.payloadJson, "configJson"));
        current = applied.back();
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"status\":\"ok\",\"payload\":{\"applied\":true}}";
      });
  int dialogs = 0;
  bool answer = true;
  std::wstring body;
  bridge.SetConsentPresenter(
      [&](void *, const std::wstring &, const std::wstring &b) {
        ++dialogs;
        body = b;
        return answer;
      });
  const auto set = [&](const std::string &configJson) {
    return bridge.HandleMessage(
        "{\"id\":7,\"kind\":\"core.permissions.set\",\"payload\":{"
        "\"configJson\":\"" +
        beats::JsonEscapePublic(configJson) + "\"}}");
  };
  const auto ok = [](const std::string &reply) {
    return reply.find("\"status\":\"ok\"") != std::string::npos;
  };
  const auto denied = [](const std::string &reply) {
    return reply.find("E_NATIVE_CONSENT_REQUIRED") != std::string::npos;
  };
  const std::string deny2 = ",\"allow\":[],\"deny\":[\"rm\",\"curl\"]}";

  // 1. Endurecer (mismo modo, un denegado más) no pregunta.
  DA_CHECK(ok(set("{\"mode\":\"normal\"" + deny2)) && dialogs == 0 &&
           applied.size() == 1);
  // 2. Subir a Aceptar ediciones sin nada habilitado: una pregunta.
  DA_CHECK(ok(set("{\"mode\":\"accept_edits\"" + deny2)) && dialogs == 1 &&
           Has(body, L"Aceptar ediciones"));
  // 3. Bajar a Manual: nada.
  DA_CHECK(ok(set("{\"mode\":\"normal\"" + deny2)) && dialogs == 1);
  // 4. Auto por primera vez y «No permitir»: no se aplica ni se recuerda.
  answer = false;
  const size_t before = applied.size();
  DA_CHECK(denied(set("{\"mode\":\"autonomous\"" + deny2)) && dialogs == 2 &&
           applied.size() == before &&
           beats::GetStringProp(current, "mode") == "normal" &&
           memoryText() == "(no existe)");
  DA_CHECK(Has(body, L"Auto") && Has(body, L"recordará") &&
           Has(body, L"Volver a pedir confirmación para Auto y Omitir"));
  // 5. Auto, «Permitir»: se aplica y el host lo recuerda en la carpeta.
  answer = true;
  DA_CHECK(ok(set("{\"mode\":\"autonomous\"" + deny2)) && dialogs == 3 &&
           memoryText().find("autonomous") != std::string::npos);
  // 6. Desde entonces Auto es un modo más (y Aceptar ediciones también).
  DA_CHECK(ok(set("{\"mode\":\"normal\"" + deny2)) &&
           ok(set("{\"mode\":\"autonomous\"" + deny2)) &&
           ok(set("{\"mode\":\"accept_edits\"" + deny2)) && dialogs == 3);
  // 7. Omitir permisos se habilita aparte: una pregunta la primera vez.
  DA_CHECK(ok(set("{\"mode\":\"bypass\"" + deny2)) && dialogs == 4 &&
           Has(body, L"Omitir permisos") &&
           memoryText().find("bypass") != std::string::npos);
  DA_CHECK(ok(set("{\"mode\":\"normal\"" + deny2)) &&
           ok(set("{\"mode\":\"bypass\"" + deny2)) && dialogs == 4);
  // 8. Añadir a permitidos pregunta cada vez y enseña la regla nueva.
  DA_CHECK(ok(set("{\"mode\":\"bypass\",\"allow\":[\"git status\"],\"deny\":["
                  "\"rm\",\"curl\"]}")) &&
           dialogs == 5 && Has(body, L"«git status»"));
  // 9. Quitarla endurece: nada. Quitar un denegado amplía: pregunta.
  DA_CHECK(ok(set("{\"mode\":\"bypass\"" + deny2)) && dialogs == 5);
  DA_CHECK(ok(set("{\"mode\":\"bypass\",\"allow\":[],\"deny\":[\"curl\"]}")) &&
           dialogs == 6 && Has(body, L"«rm»"));
  // 10. Revocar el recuerdo no pregunta (endurece) y la siguiente vez Auto
  // vuelve a preguntar.
  const auto forgot = bridge.HandleMessage(
      "{\"id\":8,\"kind\":\"core.permissions.forgetElevated\",\"payload\":{}}");
  DA_CHECK(ok(forgot) && dialogs == 6 && memoryText() == "(no existe)");
  DA_CHECK(ok(set("{\"mode\":\"normal\",\"allow\":[],\"deny\":[\"curl\"]}")) &&
           dialogs == 6);
  DA_CHECK(
      ok(set("{\"mode\":\"autonomous\",\"allow\":[],\"deny\":[\"curl\"]}")) &&
      dialogs == 7);
  // 11. El motor recibe lo que el host evaluó: una clave repetida no cuela
  // Omitir permisos detrás de un «normal».
  DA_CHECK(ok(set("{\"mode\":\"normal\",\"allow\":[],\"deny\":[\"curl\"]}")));
  const int beforeDup = dialogs;
  DA_CHECK(ok(set("{\"mode\":\"normal\",\"mode\":\"bypass\"}")) &&
           dialogs == beforeDup && applied.back() == "{\"mode\":\"normal\"}");
  // 12. Modo desconocido: rechazo sin diálogo y sin llegar al motor.
  const size_t beforeBad = applied.size();
  DA_CHECK(set("{\"mode\":\"root\"}").find("E_PERMISSIONS_CONFIG") !=
               std::string::npos &&
           dialogs == beforeDup && applied.size() == beforeBad);
  // 13. Sin poder leer lo vigente: lo mínimo no pregunta, ampliar sí.
  readable = false;
  DA_CHECK(ok(set("{\"mode\":\"normal\",\"allow\":[]}")) &&
           dialogs == beforeDup);
  DA_CHECK(ok(set("{\"mode\":\"accept_edits\"}")) && dialogs == beforeDup + 1 &&
           Has(body, L"No se pudo leer la configuración vigente"));
  readable = true;

  // 14. Acciones corrientes de IDE: sin diálogo. MCP: una vez por servidor.
  bridge.RegisterHandler("core.mcp.call", [](const beats::BridgeMessage &msg) {
    return "{\"id\":" + std::to_string(msg.id) +
           ",\"status\":\"ok\",\"payload\":{}}";
  });
  bridge.RegisterHandler(
      "core.mcp.connect", [](const beats::BridgeMessage &msg) {
        return "{\"id\":" + std::to_string(msg.id) +
               ",\"status\":\"ok\",\"payload\":{\"connected\":true}}";
      });
  const int beforeIde = dialogs;
  DA_CHECK(ok(bridge.HandleMessage("{\"id\":9,\"kind\":\"core.mcp.call\","
                                   "\"payload\":{\"name\":\"read_file\"}}")) &&
           dialogs == beforeIde);
  const auto connect = [&](const char *program) {
    return bridge.HandleMessage(
        std::string("{\"id\":10,\"kind\":\"core.mcp.connect\",\"payload\":{"
                    "\"argvJson\":\"[\\\"") +
        program + "\\\"]\",\"cwd\":\"C:\\\\w\"}}");
  };
  answer = false;
  DA_CHECK(denied(connect("srv.exe")) && dialogs == beforeIde + 1);
  answer = true;
  DA_CHECK(ok(connect("srv.exe")) && dialogs == beforeIde + 2);
  DA_CHECK(ok(connect("srv.exe")) && dialogs == beforeIde + 2);
  DA_CHECK(ok(connect("otro.exe")) && dialogs == beforeIde + 3);

  DA_CHECK(DeleteFileW(memory.c_str()));
  DA_CHECK(RemoveDirectoryW(dir.c_str()));
  std::cout << "[PASS] CK-PUB-018 permisos: endurecer 0 dialogos, Auto y "
               "Omitir 1 la primera vez y 0 despues, No permitir no aplica, "
               "allow nuevo 1, revocar vuelve a preguntar, JSON canonico, "
               "MCP una vez por servidor, mcp.call 0\n";
}

// B1e (11-nov): los puntos de control van a su propio carril (main.cpp), fuera
// del hilo de la interfaz, y el arranque limpia los indices viejos de %TEMP%
// sin tocar los de la sesion viva ni los de otro host abierto.
static void test_checkpoint_lane_and_stale_index_cleanup() {
  DA_CHECK(beats::IsCheckpointKind("checkpoint.create"));
  DA_CHECK(beats::IsCheckpointKind("checkpoint.restore"));
  DA_CHECK(!beats::IsCheckpointKind("checkpoint"));
  DA_CHECK(!beats::IsCheckpointKind("core.git.status"));
  DA_CHECK(!beats::RequiresNativeConsent("checkpoint.create"));
  DA_CHECK(!beats::CheckpointIndexDir().empty());

  wchar_t temp[MAX_PATH + 1];
  const DWORD len = GetTempPathW(MAX_PATH + 1, temp);
  DA_CHECK(len > 0 && len <= MAX_PATH);
  const std::wstring dir = std::wstring(temp, len) + L"beats-b1e-prune-" +
                           std::to_wstring(GetCurrentProcessId());
  std::error_code ec;
  std::filesystem::remove_all(dir, ec);
  DA_CHECK(CreateDirectoryW(dir.c_str(), nullptr));
  const unsigned long long day100ns = 24ULL * 60 * 60 * 1000 * 10000;
  const auto make = [&](const std::wstring &name, unsigned long long daysOld) {
    const std::wstring path = dir + L"\\" + name;
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    DA_CHECK(h != INVALID_HANDLE_VALUE);
    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    unsigned long long t =
        ((static_cast<unsigned long long>(now.dwHighDateTime) << 32) |
         now.dwLowDateTime) -
        daysOld * day100ns;
    FILETIME ft{static_cast<DWORD>(t & 0xFFFFFFFFULL),
                static_cast<DWORD>(t >> 32)};
    const bool stamped = SetFileTime(h, nullptr, nullptr, &ft) != FALSE;
    CloseHandle(h);
    DA_CHECK(stamped);
  };
  const auto exists = [&](const std::wstring &name) {
    return GetFileAttributesW((dir + L"\\" + name).c_str()) !=
           INVALID_FILE_ATTRIBUTES;
  };
  // PIDs multiplos de 4 en lo alto del rango: Windows no los asigna.
  const std::wstring self = std::to_wstring(GetCurrentProcessId());
  make(L"4294967292-10-1.index", 8);      // viejo, host muerto: se borra
  make(L"4294967292-10-1.index.lock", 8); // su candado: se borra
  make(L"4294967288-10-2.index", 1);      // reciente: se queda
  make(L"4294967284-10-3.index", 30);     // de esta sesion: se queda
  make(self + L"-10-4.index", 30);        // de un host vivo: se queda
  make(L"notas-10.index", 30);            // no es nuestro: se queda
  make(L"4294967292.txt", 30);            // no es un indice: se queda
  const size_t removed = beats::PruneStaleCheckpointIndexes(
      dir, 7ULL * 24 * 60 * 60 * 1000, 4294967284UL);
  DA_CHECK(removed == 2);
  DA_CHECK(!exists(L"4294967292-10-1.index"));
  DA_CHECK(!exists(L"4294967292-10-1.index.lock"));
  DA_CHECK(exists(L"4294967288-10-2.index"));
  DA_CHECK(exists(L"4294967284-10-3.index"));
  DA_CHECK(exists(self + L"-10-4.index"));
  DA_CHECK(exists(L"notas-10.index"));
  DA_CHECK(exists(L"4294967292.txt"));
  // Una carpeta que no existe no es un error ni borra nada.
  DA_CHECK(beats::PruneStaleCheckpointIndexes(dir + L"\\no-existe", 0, 0) == 0);
  std::filesystem::remove_all(dir, ec);
  std::cout << "[PASS] B1e puntos de control: carril propio y limpieza de "
               "indices viejos (2 borrados, 5 conservados)\n";
}

// B1 (10-nov): «Revertir los archivos» deja el proyecto exactamente como
// estaba antes de la ejecucion: restaura lo modificado y lo borrado (seguido
// o no), borra lo creado (y las carpetas nuevas que quedan vacias) y no toca
// lo ignorado ni un archivo sin seguimiento que ya existia.
static bool test_checkpoint_restores_exact_state() {
  const auto &git = beats::security::GitProgram();
  if (git.executable.empty()) {
    std::cout << "[SKIP] B1 checkpoint: git no esta en una ubicacion nativa\n";
    return true;
  }
  wchar_t temp[32768];
  if (!GetTempPathW(32768, temp))
    return false;
  const std::wstring repo = std::wstring(temp) + L"beats-b1-checkpoint-" +
                            std::to_wstring(GetCurrentProcessId());
  if (!CreateDirectoryW(repo.c_str(), nullptr))
    return false;
  const auto writeFile = [](const std::wstring &path,
                            const std::string &content) {
    std::ofstream out(path.c_str(), std::ios::binary);
    out << content;
    return out.good();
  };
  const auto readFile = [](const std::wstring &path) {
    std::ifstream in(path.c_str(), std::ios::binary);
    if (!in)
      return std::string("<ausente>");
    return std::string(std::istreambuf_iterator<char>(in), {});
  };
  const auto exists = [](const std::wstring &path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
  };
  bool passed = true;
  const auto check = [&](bool ok, const char *name) {
    std::cout << (ok ? "[PASS] " : "[FAIL] ") << "B1 checkpoint: " << name
              << "\n";
    passed = passed && ok;
  };
  // Estado previo: seguido, borrable seguido, sin seguimiento previo,
  // ignorado y una carpeta vacia que ya existia.
  bool seeded = writeFile(repo + L"\\a.txt", "original\n") &&
                writeFile(repo + L"\\gone.txt", "seguido\n") &&
                writeFile(repo + L"\\.gitignore", "*.log\n");
  seeded =
      seeded && RunFixtureGit(repo, {L"init", L"-q"}) == 0 &&
      RunFixtureGit(repo, {L"config", L"user.email", L"b1@example.invalid"}) ==
          0 &&
      RunFixtureGit(repo, {L"config", L"user.name", L"DevAgents Test"}) == 0 &&
      RunFixtureGit(repo, {L"config", L"commit.gpgsign", L"false"}) == 0 &&
      RunFixtureGit(
          repo, {L"add", L"--", L"a.txt", L"gone.txt", L".gitignore"}) == 0 &&
      RunFixtureGit(repo, {L"-c", L"core.hooksPath=NUL", L"commit", L"-q",
                           L"-m", L"inicial"}) == 0;
  seeded = seeded && writeFile(repo + L"\\previo.txt", "sin seguimiento\n") &&
           writeFile(repo + L"\\previo-borrado.txt", "tambien previo\n") &&
           writeFile(repo + L"\\build.log", "ignorado\n") &&
           CreateDirectoryW((repo + L"\\vacia-previa").c_str(), nullptr);
  check(seeded, "proyecto de prueba preparado");
  if (!seeded) {
    RemoveFixtureTree(repo);
    return false;
  }
  {
    beats::DocumentManager docs;
    std::string error;
    const bool authorized = docs.AuthorizeWorkspaceRoot(repo, error);
    check(authorized, "carpeta autorizada");
    beats::Bridge bridge;
    bridge.BindServices(&docs, nullptr, nullptr, nullptr, nullptr, nullptr,
                        nullptr);
    const int size = WideCharToMultiByte(CP_UTF8, 0, repo.data(),
                                         static_cast<int>(repo.size()), nullptr,
                                         0, nullptr, nullptr);
    std::string utf8(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, repo.data(), static_cast<int>(repo.size()),
                        utf8.data(), size, nullptr, nullptr);
    const std::string rootJson =
        "\"root\":\"" + beats::JsonEscapePublic(utf8) + "\"";
    const std::string created = bridge.HandleMessage(
        "{\"id\":901,\"kind\":\"checkpoint.create\",\"payload\":{" + rootJson +
        "}}");
    const size_t at = created.find("\"sha\":\"");
    check(authorized &&
              created.find("\"status\":\"ok\"") != std::string::npos &&
              at != std::string::npos &&
              created.find("\"untrackedCount\":2") != std::string::npos,
          "foto con los dos archivos sin seguimiento previos");
    if (at != std::string::npos) {
      const std::string sha =
          created.substr(at + 7, created.find('"', at + 7) - at - 7);
      Sleep(50); // las carpetas nuevas nacen despues de la foto
      // La «ejecucion»: modifica, borra y crea.
      bool ran = writeFile(repo + L"\\a.txt", "cambiado por el agente\n") &&
                 DeleteFileW((repo + L"\\gone.txt").c_str()) &&
                 writeFile(repo + L"\\previo.txt", "pisado\n") &&
                 DeleteFileW((repo + L"\\previo-borrado.txt").c_str()) &&
                 writeFile(repo + L"\\nuevo.txt", "creado\n") &&
                 CreateDirectoryW((repo + L"\\src").c_str(), nullptr) &&
                 CreateDirectoryW((repo + L"\\src\\mod").c_str(), nullptr) &&
                 writeFile(repo + L"\\src\\mod\\x.ts", "creado\n") &&
                 writeFile(repo + L"\\vacia-previa\\y.txt", "creado\n") &&
                 writeFile(repo + L"\\build.log", "ignorado cambiado\n") &&
                 writeFile(repo + L"\\otro.log", "ignorado nuevo\n");
      check(ran, "ejecucion simulada");
      const std::string reply =
          bridge.HandleMessage("{\"id\":902,\"kind\":\"checkpoint.restore\","
                               "\"payload\":{\"sha\":\"" +
                               sha + "\"," + rootJson + "}}");
      std::cout << "B1 checkpoint.restore -> " << reply << "\n";
      check(reply.find("\"restored\":4") != std::string::npos &&
                reply.find("\"deleted\":3") != std::string::npos &&
                reply.find("\"notDeleted\":[]") != std::string::npos,
            "respuesta: 4 restaurados, 3 borrados, ninguno pendiente");
      check(readFile(repo + L"\\a.txt") == "original\n" &&
                readFile(repo + L"\\gone.txt") == "seguido\n",
            "seguidos modificado y borrado restaurados");
      check(readFile(repo + L"\\previo.txt") == "sin seguimiento\n" &&
                readFile(repo + L"\\previo-borrado.txt") == "tambien previo\n",
            "sin seguimiento previos: restaurado y recuperado");
      check(!exists(repo + L"\\nuevo.txt") &&
                !exists(repo + L"\\src\\mod\\x.ts") &&
                !exists(repo + L"\\src") &&
                !exists(repo + L"\\vacia-previa\\y.txt"),
            "creados borrados con sus carpetas nuevas");
      check(exists(repo + L"\\vacia-previa"),
            "carpeta vacia que ya existia conservada");
      check(readFile(repo + L"\\build.log") == "ignorado cambiado\n" &&
                readFile(repo + L"\\otro.log") == "ignorado nuevo\n",
            "lo ignorado por .gitignore no se toca");
      const std::string again =
          bridge.HandleMessage("{\"id\":903,\"kind\":\"checkpoint.restore\","
                               "\"payload\":{\"sha\":\"" +
                               sha + "\"," + rootJson + "}}");
      check(again.find("\"restored\":0") != std::string::npos &&
                again.find("\"deleted\":0") != std::string::npos,
            "revertir otra vez no cambia nada");

      // T1-D2 (12-nov): un `git mv` aprobado cambia el indice REAL; revertir
      // debe dejarlo como estaba (nada preparado), no solo el disco.
      const std::string created2 = bridge.HandleMessage(
          "{\"id\":904,\"kind\":\"checkpoint.create\",\"payload\":{" +
          rootJson + "}}");
      const size_t at2 = created2.find("\"sha\":\"");
      const bool cleanBefore =
          RunFixtureGit(repo, {L"diff", L"--cached", L"--quiet"}) == 0;
      const bool moved =
          at2 != std::string::npos &&
          RunFixtureGit(repo, {L"mv", L"a.txt", L"a2.txt"}) == 0 &&
          RunFixtureGit(repo, {L"diff", L"--cached", L"--quiet"}) == 1;
      check(cleanBefore && moved, "git mv deja un renombrado preparado");
      if (moved) {
        const std::string sha2 =
            created2.substr(at2 + 7, created2.find('"', at2 + 7) - at2 - 7);
        const std::string undo =
            bridge.HandleMessage("{\"id\":905,\"kind\":\"checkpoint.restore\","
                                 "\"payload\":{\"sha\":\"" +
                                 sha2 + "\"," + rootJson + "}}");
        std::cout << "T1-D2 checkpoint.restore -> " << undo << "\n";
        check(undo.find("\"indexRestored\":true") != std::string::npos,
              "respuesta: indice real restaurado");
        check(readFile(repo + L"\\a.txt") == "original\n" &&
                  !exists(repo + L"\\a2.txt"),
              "disco: a.txt de vuelta y a2.txt borrado");
        check(RunFixtureGit(repo, {L"diff", L"--cached", L"--quiet"}) == 0,
              "indice real sin cambios preparados tras revertir");
      }
    }
  }
  RemoveFixtureTree(repo);
  return passed;
}

static void test_git_status_and_local_commit() {
  const auto &git = beats::security::GitProgram();
  if (git.executable.empty()) {
    std::cout << "[SKIP] core.git.*: git no esta en una ubicacion nativa\n";
    return;
  }
  wchar_t temp[32768];
  DA_CHECK(GetTempPathW(32768, temp) > 0);
  const std::wstring base = std::wstring(temp) + L"beats-cab025-git-" +
                            std::to_wstring(GetCurrentProcessId());
  const std::wstring repo = base + L"\\repo", outside = base + L"\\outside";
  DA_CHECK(CreateDirectoryW(base.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(repo.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(outside.c_str(), nullptr));
  const auto writeFile = [](const std::wstring &path,
                            const std::string &content) {
    std::ofstream out(path.c_str(), std::ios::binary);
    out << content;
    DA_CHECK(out.good());
  };
  writeFile(repo + L"\\a.txt", "uno\ndos\ntres\n");
  DA_CHECK(RunFixtureGit(repo, {L"init", L"-q"}) == 0);
  DA_CHECK(RunFixtureGit(repo, {L"config", L"user.email",
                                L"cab025@example.invalid"}) == 0);
  DA_CHECK(RunFixtureGit(repo, {L"config", L"user.name", L"DevAgents Test"}) ==
           0);
  DA_CHECK(RunFixtureGit(repo, {L"config", L"commit.gpgsign", L"false"}) == 0);
  DA_CHECK(
      RunFixtureGit(repo, {L"config", L"core.logAllRefUpdates", L"true"}) == 0);
  DA_CHECK(RunFixtureGit(repo, {L"add", L"--", L"a.txt"}) == 0);
  DA_CHECK(RunFixtureGit(repo, {L"commit", L"-q", L"-m", L"inicial"}) == 0);

  // Cambio rastreado (2 lineas anadidas, 1 quitada) + archivo sin seguimiento.
  writeFile(repo + L"\\a.txt", "uno\nDOS\ntres\ncuatro\n");
  writeFile(repo + L"\\b.txt", "nuevo\n");

  {
    beats::DocumentManager docs;
    std::string error;
    DA_CHECK(docs.AuthorizeWorkspaceRoot(repo, error));
    beats::Bridge bridge;
    bridge.BindServices(&docs, nullptr, nullptr, nullptr, nullptr, nullptr,
                        nullptr);
    int prompts = 0;
    std::wstring consentBody;
    bridge.SetConsentPresenter(
        [&](void *, const std::wstring &, const std::wstring &body) {
          ++prompts;
          consentBody = body;
          return true;
        });
    const auto jsonPath = [](const std::wstring &path) {
      const int size = WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                           static_cast<int>(path.size()),
                                           nullptr, 0, nullptr, nullptr);
      std::string utf8(size, '\0');
      DA_CHECK(WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                   static_cast<int>(path.size()), utf8.data(),
                                   size, nullptr, nullptr) == size);
      return beats::JsonEscapePublic(utf8);
    };
    const auto statusPayload = "\"root\":\"" + jsonPath(repo) + "\"";
    const auto statusReply = bridge.HandleMessage(
        "{\"id\":101,\"kind\":\"core.git.status\",\"payload\":{" +
        statusPayload + "}}");
    DA_CHECK(prompts == 0 && "core.git.status nunca pide consentimiento");
    DA_CHECK(statusReply.find("\"status\":\"ok\"") != std::string::npos);
    DA_CHECK(statusReply.find("\"isRepo\":true") != std::string::npos);
    DA_CHECK(statusReply.find("\"branch\":\"\"") == std::string::npos);
    DA_CHECK(statusReply.find("\"added\":2") != std::string::npos);
    DA_CHECK(statusReply.find("\"removed\":1") != std::string::npos);
    DA_CHECK(statusReply.find("\"path\":\"a.txt\",\"added\":2,\"removed\":1,"
                              "\"untracked\":false") != std::string::npos);
    DA_CHECK(statusReply.find("\"path\":\"b.txt\",\"added\":0,\"removed\":0,"
                              "\"untracked\":true") != std::string::npos);

    // Sin raiz autorizada, sin mensaje, sin archivos y rutas que escapan.
    DA_CHECK(bridge
                 .HandleMessage("{\"id\":102,\"kind\":\"core.git.commit\","
                                "\"payload\":{\"root\":\"" +
                                jsonPath(outside) +
                                "\",\"message\":\"x\","
                                "\"files\":[\"a.txt\"]}}")
                 .find("E_GIT_ROOT_NOT_AUTHORIZED") != std::string::npos);
    DA_CHECK(bridge
                 .HandleMessage("{\"id\":103,\"kind\":\"core.git.commit\","
                                "\"payload\":{" +
                                statusPayload +
                                ",\"message\":\"\","
                                "\"files\":[\"a.txt\"]}}")
                 .find("E_GIT_COMMIT_MESSAGE") != std::string::npos);
    DA_CHECK(bridge
                 .HandleMessage("{\"id\":104,\"kind\":\"core.git.commit\","
                                "\"payload\":{" +
                                statusPayload +
                                ",\"message\":\"x\","
                                "\"files\":[]}}")
                 .find("E_GIT_COMMIT_FILES") != std::string::npos);
    for (const auto *hostile :
         {"../outside/evil.txt", "C:\\\\evil.txt", "a.txt:stream", ""}) {
      DA_CHECK(bridge
                   .HandleMessage("{\"id\":105,\"kind\":\"core.git.commit\","
                                  "\"payload\":{" +
                                  statusPayload +
                                  ",\"message\":\"x\","
                                  "\"files\":[\"" +
                                  std::string(hostile) + "\"]}}")
                   .find("E_GIT_COMMIT_PATH_OUTSIDE") != std::string::npos);
    }

    // R2: un junction bajo la raiz nunca debe llegar a git add ni al listado.
    bool r2Pass = true;
    const auto r2Check = [&](bool ok, const char *name) {
      std::cout << (ok ? "[PASS] R2 " : "[FAIL] R2 ") << name << std::endl;
      r2Pass = r2Pass && ok;
    };
    const auto readIndex = [&] {
      std::ifstream in((repo + L"\\.git\\index").c_str(), std::ios::binary);
      DA_CHECK(in.good());
      return std::string(std::istreambuf_iterator<char>(in), {});
    };
    writeFile(outside + L"\\evil.txt", "outside sentinel\n");
    DA_CHECK(MakeWriterJunction(repo + L"\\escape", outside));
    const auto indexBefore = readIndex();
    const auto unsafeStatus = bridge.HandleMessage(
        "{\"id\":112,\"kind\":\"core.git.status\",\"payload\":{" +
        statusPayload + "}}");
    r2Check(unsafeStatus.find("E_GIT_STATUS_PATH_UNSAFE") != std::string::npos,
            "status rechaza junction antes de leer el arbol con git");
    const auto unsafeCommit = bridge.HandleMessage(
        "{\"id\":113,\"kind\":\"core.git.commit\",\"payload\":{" +
        statusPayload +
        ",\"message\":\"junction denied\","
        "\"files\":[\"escape/evil.txt\"]}}");
    r2Check(unsafeCommit.find("E_GIT_COMMIT_PATH_OUTSIDE") != std::string::npos,
            "commit rechaza junction hacia fuera");
    r2Check(readIndex() == indexBefore,
            "junction rechazado sin git add: indice identico byte a byte");
    DA_CHECK(RemoveDirectoryW((repo + L"\\escape").c_str()));

    // Commit local: solo a.txt. la cabina ya muestra archivos y
    // mensaje en su propio modal; el host no abre diálogo nativo (git local,
    // sin hooks ni push), igual que Claude Code, Codex o VS Code.
    const int beforeCommit = prompts;
    const auto commitReply = bridge.HandleMessage(
        "{\"id\":106,\"kind\":\"core.git.commit\",\"payload\":{" +
        statusPayload +
        ",\"message\":\"cab025 prueba\","
        "\"files\":[\"a.txt\"]}}");
    r2Check(prompts == beforeCommit, "commit local sin dialogo nativo");
    DA_CHECK(commitReply.find("\"status\":\"ok\"") != std::string::npos);
    DA_CHECK(commitReply.find("\"hash\":\"") != std::string::npos);
    DA_CHECK(commitReply.find("\"files\":[\"a.txt\"]") != std::string::npos);
    const auto afterTracked = bridge.HandleMessage(
        "{\"id\":107,\"kind\":\"core.git.status\",\"payload\":{" +
        statusPayload + "}}");
    DA_CHECK(afterTracked.find("\"added\":0") != std::string::npos);
    DA_CHECK(afterTracked.find("\"removed\":0") != std::string::npos);
    DA_CHECK(afterTracked.find("\"path\":\"a.txt\"") == std::string::npos);
    DA_CHECK(afterTracked.find("\"path\":\"b.txt\",\"added\":0,\"removed\":0,"
                               "\"untracked\":true") != std::string::npos);

    DA_CHECK(r2Pass && "CK-CAB-025 R2: confinamiento y consentimiento");

    // Segundo commit: el sin seguimiento. El mensaje queda en el reflog local.
    DA_CHECK(bridge
                 .HandleMessage("{\"id\":108,\"kind\":\"core.git.commit\","
                                "\"payload\":{" +
                                statusPayload +
                                ",\"message\":\"cab025 untracked\","
                                "\"files\":[\"b.txt\"]}}")
                 .find("\"status\":\"ok\"") != std::string::npos);
    const auto clean = bridge.HandleMessage(
        "{\"id\":109,\"kind\":\"core.git.status\",\"payload\":{" +
        statusPayload + "}}");
    DA_CHECK(clean.find("\"isRepo\":true") != std::string::npos);
    DA_CHECK(clean.find("\"files\":[]") != std::string::npos);
    {
      std::ifstream log((repo + L"\\.git\\logs\\HEAD").c_str(),
                        std::ios::binary);
      const std::string reflog((std::istreambuf_iterator<char>(log)),
                               std::istreambuf_iterator<char>());
      DA_CHECK(reflog.find("commit: cab025 prueba") != std::string::npos);
      DA_CHECK(reflog.find("commit: cab025 untracked") != std::string::npos);
    }

    // Sin repositorio: status informa isRepo=false; commit lo rechaza.
    DA_CHECK(docs.AuthorizeWorkspaceRoot(outside, error));
    {
      const auto noRepo =
          bridge.HandleMessage("{\"id\":110,\"kind\":\"core.git.status\","
                               "\"payload\":{\"root\":\"" +
                               jsonPath(outside) + "\"}}");
      DA_CHECK(noRepo.find("\"isRepo\":false") != std::string::npos);
    }
    DA_CHECK(bridge
                 .HandleMessage("{\"id\":111,\"kind\":\"core.git.commit\","
                                "\"payload\":{\"root\":\"" +
                                jsonPath(outside) +
                                "\",\"message\":\"x\","
                                "\"files\":[\"a.txt\"]}}")
                 .find("E_GIT_COMMIT_NOT_REPO") != std::string::npos);
  }

  RemoveFixtureTree(base);
  std::cout << "[PASS] core.git.status solo lectura y core.git.commit local "
               "con consentimiento, rutas confinadas y sin push\n";
}

// r4: rechazo de un hunk de solo borrado (N->0) por el camino REAL.
// Reproduce el payload que envia shell/webui/src/editor/diff_viewer.ts:
// originalContent/newContent son las lineas del hunk, el rango viaja en
// startLine/originalLineCount/newLineCount y baseFileContent es el original
// completo del diff. Antes del arreglo el host pasaba al HunkManager solo las
// lineas del hunk, la comprobacion de contexto caia fuera de rango y la
// reinsercion era a ciegas.
bool test_hunk_reject_real_path() {
  wchar_t cwd[32768];
  const DWORD cwdLength = GetCurrentDirectoryW(32768, cwd);
  DA_CHECK(cwdLength != 0 && cwdLength < 32768);
  const std::wstring root = std::wstring(cwd) + L"\\.tmp-orq";
  CreateDirectoryW(root.c_str(), nullptr);
  LARGE_INTEGER tick{};
  QueryPerformanceCounter(&tick);
  wchar_t name[64];
  swprintf(name, 64, L"beats_bridge_hunk_%08lx_%08lx%08lx",
           static_cast<unsigned long>(GetCurrentProcessId()),
           static_cast<unsigned long>(tick.HighPart),
           static_cast<unsigned long>(tick.LowPart));
  const std::wstring dir = root + L"\\" + name;
  DA_CHECK(CreateDirectoryW(dir.c_str(), nullptr));
  const std::wstring tailFile = dir + L"\\tail.txt";
  const std::wstring changedFile = dir + L"\\changed.txt";

  const std::string original = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\n";
  const std::string changed = "L1\nL2\nL3\nL4\nL5\nL6\nL7 CAMBIADA\n";
  const auto writeFixture = [](const std::wstring &path,
                               const std::string &text) {
    std::ofstream out(path.c_str(), std::ios::binary | std::ios::trunc);
    out.write(text.data(), static_cast<std::streamsize>(text.size()));
    return out.good();
  };
  const auto readFixture = [](const std::wstring &path) {
    std::ifstream in(path.c_str(), std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), {});
  };
  const auto jsonPath = [](const std::wstring &path) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                         static_cast<int>(path.size()), nullptr,
                                         0, nullptr, nullptr);
    std::string utf8(size, '\0');
    DA_CHECK(WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                 static_cast<int>(path.size()), utf8.data(),
                                 size, nullptr, nullptr) == size);
    return beats::JsonEscapePublic(utf8);
  };

  DA_CHECK(writeFixture(tailFile, original));
  DA_CHECK(writeFixture(changedFile, original));

  bool changedRejectFailed = false;
  bool tailRestored = false;
  {
    beats::DocumentManager docs;
    std::string error;
    DA_CHECK(docs.AuthorizeWorkspaceRoot(dir, error));
    beats::HunkManager hunks(docs);
    beats::Bridge bridge;
    bridge.BindServices(&docs, nullptr, nullptr, &hunks, nullptr, nullptr,
                        nullptr);

    const auto send = [&](int id, const char *kind, const std::wstring &path,
                          const std::string &baseContent) {
      return bridge.HandleMessage(
          "{\"id\":" + std::to_string(id) + ",\"kind\":\"" + std::string(kind) +
          "\",\"payload\":{\"path\":\"" + jsonPath(path) +
          "\",\"hunkId\":1,\"originalContent\":\"" +
          beats::JsonEscapePublic("L8\nL9") + "\",\"newContent\":\"\"," +
          "\"startLine\":8,\"originalLineCount\":2,\"newLineCount\":0," +
          "\"baseFileContent\":\"" + beats::JsonEscapePublic(baseContent) +
          "\"}}");
    };

    // Acepta el hunk de solo borrado al final en los dos ficheros por el
    // puente (mismo payload que usa el visor).
    DA_CHECK(send(120, "hunk.accept", tailFile, original)
                 .find("\"status\":\"ok\"") != std::string::npos);
    DA_CHECK(send(121, "hunk.accept", changedFile, original)
                 .find("\"status\":\"ok\"") != std::string::npos);

    // Caso (a): el archivo cambio alrededor (la linea anterior L7). El rechazo
    // N->0 debe fallar sin escribir.
    DA_CHECK(writeFixture(changedFile, changed));
    const std::string changedReply =
        send(122, "hunk.reject", changedFile, original);
    changedRejectFailed = changedReply.find("\"error\"") != std::string::npos &&
                          changedReply.find("alrededor") != std::string::npos;

    // Caso (b): sin cambios alrededor, el rechazo restaura el original exacto
    // (el hunk estaba al final del archivo).
    const std::string tailReply = send(123, "hunk.reject", tailFile, original);
    tailRestored = tailReply.find("\"status\":\"ok\"") != std::string::npos;
  }

  const std::string tailAfter = readFixture(tailFile);
  const std::string changedAfter = readFixture(changedFile);
  DeleteFileW(tailFile.c_str());
  DeleteFileW(changedFile.c_str());
  RemoveDirectoryW(dir.c_str());

  bool ok = true;
  if (changedRejectFailed && changedAfter == changed) {
    std::cout << "[PASS] Reject N->0 through bridge fails without writing when "
                 "the file changed around\n";
  } else {
    std::cout << "[FAIL] Reject N->0 through bridge fails without writing when "
                 "the file changed around (rejected="
              << (changedRejectFailed ? "error" : "no-error")
              << " changed=" << (changedAfter == changed ? "no" : "yes")
              << ")\n";
    ok = false;
  }
  if (tailRestored && tailAfter == original) {
    std::cout << "[PASS] Reject N->0 through bridge at end restores the exact "
                 "original\n";
  } else {
    std::cout << "[FAIL] Reject N->0 through bridge at end restores the exact "
                 "original (restored="
              << (tailRestored ? "yes" : "no") << ")\n";
    ok = false;
  }

  std::cout << std::flush;
  DA_CHECK(ok);
  return ok;
}

// r5: mismo camino REAL (WebUI -> puente -> HunkManager) para un
// hunk de solo borrado (N->0) al INICIO del archivo (startLine=1). Aceptar y
// rechazar restaura el original exacto; si la primera linea que queda tras el
// borrado cambio, el rechazo falla sin escribir.
bool test_hunk_reject_real_path_at_start() {
  wchar_t cwd[32768];
  const DWORD cwdLength = GetCurrentDirectoryW(32768, cwd);
  DA_CHECK(cwdLength != 0 && cwdLength < 32768);
  const std::wstring root = std::wstring(cwd) + L"\\.tmp-orq";
  CreateDirectoryW(root.c_str(), nullptr);
  LARGE_INTEGER tick{};
  QueryPerformanceCounter(&tick);
  wchar_t name[64];
  swprintf(name, 64, L"beats_bridge_hunk_start_%08lx_%08lx%08lx",
           static_cast<unsigned long>(GetCurrentProcessId()),
           static_cast<unsigned long>(tick.HighPart),
           static_cast<unsigned long>(tick.LowPart));
  const std::wstring dir = root + L"\\" + name;
  DA_CHECK(CreateDirectoryW(dir.c_str(), nullptr));
  const std::wstring cleanFile = dir + L"\\start.txt";
  const std::wstring changedFile = dir + L"\\start_changed.txt";

  const std::string original = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\n";
  const std::string accepted = "L3\nL4\nL5\nL6\nL7\nL8\nL9\n";
  const std::string changedAround = "L3 CAMBIADA\nL4\nL5\nL6\nL7\nL8\nL9\n";
  const auto writeFixture = [](const std::wstring &path,
                               const std::string &text) {
    std::ofstream out(path.c_str(), std::ios::binary | std::ios::trunc);
    out.write(text.data(), static_cast<std::streamsize>(text.size()));
    return out.good();
  };
  const auto readFixture = [](const std::wstring &path) {
    std::ifstream in(path.c_str(), std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), {});
  };
  const auto jsonPath = [](const std::wstring &path) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                         static_cast<int>(path.size()), nullptr,
                                         0, nullptr, nullptr);
    std::string utf8(size, '\0');
    DA_CHECK(WideCharToMultiByte(CP_UTF8, 0, path.data(),
                                 static_cast<int>(path.size()), utf8.data(),
                                 size, nullptr, nullptr) == size);
    return beats::JsonEscapePublic(utf8);
  };

  DA_CHECK(writeFixture(cleanFile, original));
  DA_CHECK(writeFixture(changedFile, original));

  bool changedRejectFailed = false;
  bool cleanRestored = false;
  {
    beats::DocumentManager docs;
    std::string error;
    DA_CHECK(docs.AuthorizeWorkspaceRoot(dir, error));
    beats::HunkManager hunks(docs);
    beats::Bridge bridge;
    bridge.BindServices(&docs, nullptr, nullptr, &hunks, nullptr, nullptr,
                        nullptr);

    const auto send = [&](int id, const char *kind, const std::wstring &path,
                          const std::string &baseContent) {
      return bridge.HandleMessage(
          "{\"id\":" + std::to_string(id) + ",\"kind\":\"" + std::string(kind) +
          "\",\"payload\":{\"path\":\"" + jsonPath(path) +
          "\",\"hunkId\":1,\"originalContent\":\"" +
          beats::JsonEscapePublic("L1\nL2") + "\",\"newContent\":\"\"," +
          "\"startLine\":1,\"originalLineCount\":2,\"newLineCount\":0," +
          "\"baseFileContent\":\"" + beats::JsonEscapePublic(baseContent) +
          "\"}}");
    };

    // Acepta el hunk de solo borrado al inicio en los dos ficheros.
    DA_CHECK(send(130, "hunk.accept", cleanFile, original)
                 .find("\"status\":\"ok\"") != std::string::npos);
    DA_CHECK(send(131, "hunk.accept", changedFile, original)
                 .find("\"status\":\"ok\"") != std::string::npos);
    DA_CHECK(readFixture(cleanFile) == accepted);
    DA_CHECK(readFixture(changedFile) == accepted);

    // Caso (a): cambio la primera linea que queda tras el borrado. El rechazo
    // N->0 debe fallar sin escribir.
    DA_CHECK(writeFixture(changedFile, changedAround));
    const std::string changedReply =
        send(132, "hunk.reject", changedFile, original);
    changedRejectFailed = changedReply.find("\"error\"") != std::string::npos &&
                          changedReply.find("alrededor") != std::string::npos;

    // Caso (b): sin cambios alrededor, el rechazo restaura el original exacto.
    const std::string cleanReply =
        send(133, "hunk.reject", cleanFile, original);
    cleanRestored = cleanReply.find("\"status\":\"ok\"") != std::string::npos;
  }

  const std::string cleanAfter = readFixture(cleanFile);
  const std::string changedAfter = readFixture(changedFile);
  DeleteFileW(cleanFile.c_str());
  DeleteFileW(changedFile.c_str());
  RemoveDirectoryW(dir.c_str());

  bool ok = true;
  if (changedRejectFailed && changedAfter == changedAround) {
    std::cout << "[PASS] Reject N->0 at start through bridge fails without "
                 "writing when the first remaining line changed\n";
  } else {
    std::cout << "[FAIL] Reject N->0 at start through bridge fails without "
                 "writing when the first remaining line changed (rejected="
              << (changedRejectFailed ? "error" : "no-error")
              << " changed=" << (changedAfter == changedAround ? "no" : "yes")
              << ")\n";
    ok = false;
  }
  if (cleanRestored && cleanAfter == original) {
    std::cout
        << "[PASS] Reject N->0 at start through bridge restores the exact "
           "original\n";
  } else {
    std::cout
        << "[FAIL] Reject N->0 at start through bridge restores the exact "
           "original (restored="
        << (cleanRestored ? "yes" : "no") << ")\n";
    ok = false;
  }

  std::cout << std::flush;
  DA_CHECK(ok);
  return ok;
}

void test_huge_message_is_handled() {
  // 8 MiB en un solo mensaje: el parser es una pasada lineal, no recursivo.
  beats::Bridge bridge;
  std::string big(8 * 1024 * 1024, 'y');
  std::string resp = bridge.HandleMessage("{\"id\":11,\"kind\":\"init\","
                                          "\"payload\":\"" +
                                          big + "\"}");
  DA_CHECK(resp.find("\"id\":11") != std::string::npos);
  DA_CHECK(resp.find("\"status\":\"ok\"") != std::string::npos);
  std::cout << "[PASS] mensaje de 8 MiB procesado (E3.39-D)\n";
}

static void test_version_handshake() {
  const auto fixture =
      std::filesystem::current_path() / L"version-manifest-fixture";
  DA_CHECK(!std::filesystem::exists(fixture));
  DA_CHECK(std::filesystem::create_directory(fixture));
  DA_CHECK(beats::versions::WebUiIdentity(fixture.wstring()).empty());
  {
    std::ofstream manifest(fixture / L"version.json");
    manifest << "{\"identity\":\"" << DA_BUILD_IDENTITY << "\"}";
  }
  {
    std::ofstream bundle(fixture / L"bundle.js");
    bundle << "/* DevAgents build: old-ui */\n";
  }
  DA_CHECK(!beats::versions::Mismatch(
                "WebUI", beats::versions::WebUiIdentity(fixture.wstring()))
                .empty());
  {
    std::ofstream bundle(fixture / L"bundle.js");
    bundle << "/* DevAgents build: " << DA_BUILD_IDENTITY << " */\n";
  }
  DA_CHECK(beats::versions::WebUiIdentity(fixture.wstring()) ==
           DA_BUILD_IDENTITY);
  {
    std::ofstream bundle(fixture / L"bundle.js", std::ios::binary);
    bundle << "/* DevAgents build: " << DA_BUILD_IDENTITY << " */\n";
  }
  DA_CHECK(beats::versions::WebUiIdentity(fixture.wstring()) ==
           DA_BUILD_IDENTITY);
  {
    std::ofstream manifest(fixture / L"version.json");
    manifest << std::string(5000, 'x');
  }
  DA_CHECK(beats::versions::WebUiIdentity(fixture.wstring()).empty());
  DA_CHECK(std::filesystem::remove(fixture / L"version.json"));
  DA_CHECK(std::filesystem::remove(fixture / L"bundle.js"));
  DA_CHECK(std::filesystem::remove(fixture));
  beats::CoreClient core(beats::CoreClient::InitMode::isolated_empty);
  auto &api = const_cast<beats::CoreApi &>(core.Api());
  api.build_identity_v1 = []() -> const char * { return DA_BUILD_IDENTITY; };
  beats::Bridge bridge;
  bridge.BindServices(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                      &core);
  const std::string request =
      "{\"id\":1,\"kind\":\"core.status\",\"payload\":{\"identity\":\"";
  auto response = bridge.HandleMessage(request + "old-ui\"}}");
  DA_CHECK(response.find("WebUI") != std::string::npos);
  DA_CHECK(response.find("old-ui") != std::string::npos);
  DA_CHECK(response.find(DA_BUILD_IDENTITY) != std::string::npos);
  response = bridge.HandleMessage(request + DA_BUILD_IDENTITY + "\"}}");
  DA_CHECK(response.find("\"error\"") == std::string::npos);
  api.build_identity_v1 = []() -> const char * { return "old-dll"; };
  response = bridge.HandleMessage(request + DA_BUILD_IDENTITY + "\"}}");
  DA_CHECK(response.find("motor DLL") != std::string::npos);
  DA_CHECK(response.find("old-dll") != std::string::npos);
  DA_CHECK(response.find(DA_BUILD_IDENTITY) != std::string::npos);
  api.build_identity_v1 = nullptr;
  response = bridge.HandleMessage(request + DA_BUILD_IDENTITY + "\"}}");
  DA_CHECK(response.find("sin version") != std::string::npos);
  std::cout << "CK-COMP-004 bridge: 9/9 PASS (missing/oversized manifest, "
               "stale/matching CRLF and LF bundle, old UI, match, old DLL, "
               "absent export)\n";
}

static void test_engine_internal_paths() {
  for (const auto *path : {"devagents-workspace", "devagents-workspace/a/b",
                           "DevAgents-Workspace/x", "DEVAGENTS-WORKSPACE\\x"})
    DA_CHECK(beats::IsEngineInternalPath(path));
  for (const auto *path :
       {"devagents-workspace/../x", "devagents-workspace/./x",
        "devagents-workspace/a/../../x", "./devagents-workspace/x",
        "devagents-workspace-old/x", "a/devagents-workspace/x",
        "/devagents-workspace/x", "devagents-workspace\\..\\x", ""})
    DA_CHECK(!beats::IsEngineInternalPath(path));
  std::cout << "[PASS] CK-CAB-025 r3 filtro interno Windows sin traversal\n";
}

// P1-5 (R2 C3): mensaje y código de salida cuando falta WebView2. Solo la
// parte pura: el diálogo y la detección del runtime no se ejercitan aquí.
static void test_webview2_missing_message() {
  using namespace beats::webview2_missing;
  DA_CHECK(kExitCode == 3);
  DA_CHECK(std::wstring(SetupFileName()) == L"MicrosoftEdgeWebview2Setup.exe");
  const std::wstring withSetup =
      Message(L"C:\\Program Files\\DevAgents\\MicrosoftEdgeWebview2Setup.exe");
  DA_CHECK(withSetup.find(L"Microsoft Edge WebView2 Runtime") !=
           std::wstring::npos);
  DA_CHECK(withSetup.find(L"WebView2 Evergreen de Microsoft") !=
           std::wstring::npos);
  DA_CHECK(
      withSetup.find(
          L"C:\\Program Files\\DevAgents\\MicrosoftEdgeWebview2Setup.exe") !=
      std::wstring::npos);
  DA_CHECK(withSetup.find(L"https://") == std::wstring::npos);
  DA_CHECK(withSetup.find(L"código de salida 3") != std::wstring::npos);
  const std::wstring without = Message(L"");
  DA_CHECK(without.find(L"WebView2 Evergreen de Microsoft") !=
           std::wstring::npos);
  DA_CHECK(without.find(
               L"https://developer.microsoft.com/microsoft-edge/webview2/") !=
           std::wstring::npos);
  DA_CHECK(without.find(L"trae ese instalador") == std::wstring::npos);
  DA_CHECK(without.find(L"código de salida 3") != std::wstring::npos);
  DA_CHECK(std::wstring(Title()).find(L"WebView2") != std::wstring::npos);
  std::cout << "[PASS] P1-5 mensaje y código de salida sin WebView2\n";
}

int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--d5-hijo")
    return d5_child_main(false);
  if (argc == 2 && std::string(argv[1]) == "--d5-nieto")
    return d5_child_main(true);
  if (argc == 2 && std::string(argv[1]) == "--seg011-h6-integration")
    return test_seg011_h6_integration() ? 0 : 1;
  if (argc == 2 && std::string(argv[1]) == "--seg011-h6-ranking") {
    test_seg011_h6_ranking();
    return 0;
  }
  test_seg011_h6_ranking();
  if (!test_seg011_h6_integration())
    return 1;
  test_version_handshake();
  test_webview2_missing_message();
  test_engine_internal_paths();
  test_registered_inventory();
  if (!test_alternate_writers_confined())
    return 1;
  test_native_consent_context();
  test_native_consent_kinds_for_queue_routing();
  test_permission_consent_like_other_ides();
  test_checkpoint_lane_and_stale_index_cleanup();
  test_run_capture_does_not_wait_for_inherited_pipe_copies();
  test_git_status_and_local_commit();
  if (!test_checkpoint_restores_exact_state())
    return 1;
  {
    beats::Bridge bridge;
    beats::PtyManager pty;
    beats::LspClient lsp;
    bridge.BindServices(nullptr, nullptr, nullptr, nullptr, &pty, &lsp,
                        nullptr);
    const auto shell =
        bridge.HandleMessage("{\"id\":1,\"kind\":\"pty.spawn\",\"payload\":{"
                             "\"shellPath\":\"cmd.exe /c calc.exe\"}}");
    DA_CHECK(shell.find("Shell fuera del registro") != std::string::npos);
    const auto server =
        bridge.HandleMessage("{\"id\":2,\"kind\":\"lsp.request\",\"payload\":{"
                             "\"serverCmd\":\"cmd.exe /c calc.exe\"}}");
    DA_CHECK(server.find("LSP fuera del registro") != std::string::npos);
    for (const auto *target : {"file:///C:/evil.exe", "file:///C:/evil.bat",
                               "file:///C:/evil.lnk"}) {
      const auto response = bridge.HandleMessage(
          std::string(
              "{\"id\":3,\"kind\":\"shell.open\",\"payload\":{\"target\":\"") +
          target + "\"}}");
      DA_CHECK(response.find("\"error\"") != std::string::npos);
    }
    std::cout << "[PASS] puente rechaza comandos y file:// antes de ejecutar\n";
  }
  {
    beats::Bridge bounded;
    DA_CHECK(bounded.HandleMessage(std::string(28u * 1024u * 1024u + 1u, 'x'))
                 .find("excede 28 MiB") != std::string::npos);
    std::cout << "[PASS] E5.23 cota de transporte\n";
  }
  test_malformed_json();
  test_unknown_kind();
  test_custom_handler();
  test_large_payload();
  test_high_volume();
  test_all_13_kinds();
  test_mute_engine_does_not_hang();
  test_nested_kind_cannot_reach_a_handler();
  test_extract_kind_for_queue_routing();
  test_brace_inside_string_does_not_truncate();
  test_id_inside_string_is_not_the_message_id();
  test_getstringprop_reads_top_level_only();
  test_getstringprop_decodes_unicode_escapes();
  test_json_escape_covers_every_control_below_0x20();
  test_wrong_types_and_extra_fields();
  if (!test_hunk_reject_real_path())
    return 1;
  if (!test_hunk_reject_real_path_at_start())
    return 1;
  test_huge_message_is_handled();
  test_update_apply();
  std::cout << "ALL BRIDGE TESTS PASSED!\n";
  return 0;
}
