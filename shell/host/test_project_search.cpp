// Presupuesto de busqueda global: 5.000 archivos en <= 2 s.
// Estas pruebas se apoyan en DA_CHECK(): ningun modo de optimizacion (NDEBUG)
// las puede compilar fuera. Debe ir antes de cualquier #include.
#include "document_manager.hpp"
#include "project_search.hpp"
#include "test_check.hpp"
#include <chrono>
#include <cstdio>
#include <string>
#include <vector>
#include <windows.h>

static const char *kNeedle = "CK012NEEDLE";

static std::wstring CurrentRoot() {
  wchar_t cwd[32768];
  const DWORD size = GetCurrentDirectoryW(32768, cwd);
  DA_CHECK(size && size < 32768);
  return std::wstring(cwd, size);
}

static void EnsureDir(const std::wstring &path) {
  if (!CreateDirectoryW(path.c_str(), nullptr))
    DA_CHECK(GetLastError() == ERROR_ALREADY_EXISTS);
}

static void WriteFileBytes(const std::wstring &path, const std::string &text) {
  HANDLE handle = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  DA_CHECK(handle != INVALID_HANDLE_VALUE);
  DWORD written = 0;
  if (!text.empty()) {
    const bool ok =
        WriteFile(handle, text.data(), static_cast<DWORD>(text.size()),
                  &written, nullptr) &&
        written == text.size();
    DA_CHECK(ok);
  }
  CloseHandle(handle);
}

static void RemoveTree(const std::wstring &dir) {
  WIN32_FIND_DATAW data;
  HANDLE find = FindFirstFileW((dir + L"\\*").c_str(), &data);
  if (find != INVALID_HANDLE_VALUE) {
    do {
      if (wcscmp(data.cFileName, L".") == 0 ||
          wcscmp(data.cFileName, L"..") == 0)
        continue;
      const std::wstring child = dir + L"\\" + data.cFileName;
      if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        RemoveTree(child);
      } else {
        SetFileAttributesW(child.c_str(), FILE_ATTRIBUTE_NORMAL);
        for (int attempt = 0; attempt < 25 && !DeleteFileW(child.c_str());
             ++attempt)
          Sleep(20);
      }
    } while (FindNextFileW(find, &data));
    FindClose(find);
  }
  // Un indexador o el antivirus pueden retener la carpeta unos ms.
  for (int attempt = 0; attempt < 25 && !RemoveDirectoryW(dir.c_str());
       ++attempt)
    Sleep(20);
}

static std::string Body(int fileIndex, bool withNeedle) {
  std::string body;
  for (int line = 0; line < 20; ++line) {
    body += "line " + std::to_string(line) + " of file " +
            std::to_string(fileIndex) + " lorem ipsum dolor sit amet\n";
  }
  if (withNeedle)
    body += std::string("prefix ") + kNeedle + " suffix\n";
  return body;
}

static const int kFiles = 5000;
static const int kDirs = 50;

static std::wstring BuildFixture() {
  // / H-G2: el arbol del presupuesto vive bajo la cache del build,
  // dentro del worktree, y se borra al terminar. No se usa el directorio
  // temporal del sistema (regla del encargo).
  const std::wstring root =
      CurrentRoot() + L"\\.zig-cache\\prb003a-search-budget";
  RemoveTree(root);
  EnsureDir(CurrentRoot() + L"\\.zig-cache");
  EnsureDir(root);
  int made = 0;
  for (int d = 0; d < kDirs; ++d) {
    wchar_t name[32];
    swprintf(name, 32, L"\\dir%02d", d);
    const std::wstring dir = root + name;
    EnsureDir(dir);
    for (int f = 0; f < kFiles / kDirs; ++f, ++made) {
      const bool needle = (made % 100) == 0;
      swprintf(name, 32, L"\\file%04d.txt", made);
      WriteFileBytes(dir + name, Body(made, needle));
    }
  }
  // Carpetas pesadas que deben ignorarse aunque contengan la aguja.
  const wchar_t *ignored[] = {L".git", L"node_modules", L"zig-out",
                              L".zig-cache"};
  for (const wchar_t *folder : ignored) {
    const std::wstring dir = root + L"\\" + folder;
    EnsureDir(dir);
    for (int f = 0; f < 40; ++f) {
      WriteFileBytes(dir + L"\\junk" + std::to_wstring(f) + L".log",
                     Body(0, true));
    }
  }
  return root;
}

static long long ElapsedMs(const std::chrono::steady_clock::time_point &start,
                           const std::chrono::steady_clock::time_point &end) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(end - start)
      .count();
}

static bool UnderIgnored(const std::wstring &path,
                         const std::wstring &fixtureRoot) {
  // Solo se inspecciona lo que cuelga DEL fixture: el fixture vive bajo
  // .zig-cache (ruta del encargo) y mirar la ruta completa lo confundiria con
  // una carpeta ignorada.
  const std::wstring relative =
      path.size() > fixtureRoot.size() ? path.substr(fixtureRoot.size()) : path;
  return relative.find(L"\\.git\\") != std::wstring::npos ||
         relative.find(L"\\node_modules\\") != std::wstring::npos ||
         relative.find(L"\\zig-out\\") != std::wstring::npos ||
         relative.find(L"\\.zig-cache\\") != std::wstring::npos;
}

static void TestLargeFile() {
  const auto root = CurrentRoot() + L"\\.tmp-orq\\search-large";
  RemoveTree(root);
  EnsureDir(CurrentRoot() + L"\\.tmp-orq");
  EnsureDir(root);
  WriteFileBytes(root + L"\\small.txt", std::string(kNeedle) + "\n");
  std::string large(25 * 1024 * 1024, 'x');
  large.replace(0, strlen(kNeedle), kNeedle);
  WriteFileBytes(root + L"\\large.txt", large);
  {
    beats::DocumentManager documents;
    std::string error;
    DA_CHECK(documents.AuthorizeWorkspaceRoot(root, error));
    beats::ProjectSearch search(documents);
    beats::SearchOptions opts;
    opts.rootDir = root;
    opts.query = kNeedle;
    const auto matches = search.ExecuteSearch(opts, &error);
    std::printf("[LARGE] 25 MiB: %zu matches, error='%s'\n", matches.size(),
                error.c_str());
    std::fflush(stdout);
    DA_CHECK(error.empty());
    bool sawSmall = false;
    for (const auto &match : matches)
      sawSmall = sawSmall || match.filePath == root + L"\\small.txt";
    DA_CHECK(sawSmall);
  }
  RemoveTree(root);
  std::printf("[PASS] 25 MiB does not abort search; small file found\n");
}

static void TestRootLru() {
  const auto base = CurrentRoot() + L"\\.tmp-orq\\search-lru";
  RemoveTree(base);
  EnsureDir(CurrentRoot() + L"\\.tmp-orq");
  EnsureDir(base);
  // Nine roots exceed the production cap of eight. File sharing exposes real
  // eviction: retained contents need no read; evicted contents must be
  // reopened.
  std::vector<std::wstring> roots;
  for (int i = 0; i < 9; ++i) {
    roots.push_back(base + L"\\root" + std::to_wstring(i));
    EnsureDir(roots.back());
    WriteFileBytes(roots.back() + L"\\item.txt", std::string(kNeedle) + "\n");
  }
  {
    beats::DocumentManager documents;
    std::string error;
    for (const auto &root : roots)
      DA_CHECK(documents.AuthorizeWorkspaceRoot(root, error));
    beats::ProjectSearch search(documents);
    beats::SearchOptions opts;
    opts.query = kNeedle;
    const auto query = [&](int i) {
      opts.rootDir = roots[i];
      const auto matches = search.ExecuteSearch(opts, &error);
      if (error.empty()) {
        DA_CHECK(matches.size() == 1);
        DA_CHECK(matches[0].filePath == roots[i] + L"\\item.txt");
      }
    };
    for (int i = 0; i < 8; ++i) {
      query(i);
      DA_CHECK(error.empty());
    }
    query(0); // Promote root0; root1 is now the least recently used.
    DA_CHECK(error.empty());
    query(8);
    DA_CHECK(error.empty());
    HANDLE retained =
        CreateFileW((roots[0] + L"\\item.txt").c_str(), GENERIC_READ, 0,
                    nullptr, OPEN_EXISTING, 0, nullptr);
    HANDLE evicted =
        CreateFileW((roots[1] + L"\\item.txt").c_str(), GENERIC_READ, 0,
                    nullptr, OPEN_EXISTING, 0, nullptr);
    DA_CHECK(retained != INVALID_HANDLE_VALUE &&
             evicted != INVALID_HANDLE_VALUE);
    query(0);
    DA_CHECK(error.empty()); // Root0 stayed cached despite the ninth root.
    query(1);
    std::printf("[LRU] ninth root evicts root1: error='%s'\n", error.c_str());
    std::fflush(stdout);
    DA_CHECK(error.find("E_SEARCH_FILE_DENIED") != std::string::npos);
    CloseHandle(retained);
    CloseHandle(evicted);
    query(1);
    DA_CHECK(error.empty()); // Evicted roots remain searchable after reopening.
  }
  RemoveTree(base);
  std::printf(
      "[PASS] eight-root cap, LRU promotion/eviction and root isolation\n");
}

static void TestDeletedRenamedAndReplaced() {
  const auto root = CurrentRoot() + L"\\.tmp-orq\\search-invalidation";
  RemoveTree(root);
  EnsureDir(root);
  const auto original = root + L"\\a.txt";
  const auto deleted = root + L"\\z.txt";
  const auto renamed = root + L"\\renamed.txt";
  WriteFileBytes(original, std::string(kNeedle) + "\r\n");
  WriteFileBytes(deleted, std::string(kNeedle) + "\n");
  {
    beats::DocumentManager documents;
    std::string error;
    DA_CHECK(documents.AuthorizeWorkspaceRoot(root, error));
    beats::ProjectSearch search(documents);
    beats::SearchOptions opts;
    opts.rootDir = root;
    opts.query = kNeedle;
    opts.caseSensitive = true;
    DA_CHECK(search.ExecuteSearch(opts, &error).size() == 2);
    DA_CHECK(error.empty());
    opts.maxResults = 1;
    DA_CHECK(search.ExecuteSearch(opts, &error).size() == 1);
    DA_CHECK(error.empty());
    DA_CHECK(DeleteFileW(deleted.c_str()));
    DA_CHECK(MoveFileW(original.c_str(), renamed.c_str()));
    // A capped scan must not serve the retained deleted/old pathname entries.
    const auto capped = search.ExecuteSearch(opts, &error);
    DA_CHECK(error.empty() && capped.size() == 1);
    DA_CHECK(capped[0].filePath == renamed);
    opts.maxResults = 5000;
    const auto all = search.ExecuteSearch(opts, &error);
    DA_CHECK(error.empty() && all.size() == 1);
    DA_CHECK(all[0].filePath == renamed);
    std::printf("[PASS] deleted file absent; renamed file only at new path, "
                "after capped and complete queries\n");

    const std::string replacement = "CK012CHANGE"; // Same size as the needle.
    DA_CHECK(replacement.size() == strlen(kNeedle));
    DA_CHECK(search.ReplaceInFiles(opts, replacement, error) == 1);
    DA_CHECK(error.empty());
    DA_CHECK(search.ExecuteSearch(opts, &error).empty());
    DA_CHECK(error.empty());
    opts.query = replacement;
    const auto replaced = search.ExecuteSearch(opts, &error);
    DA_CHECK(error.empty() && replaced.size() == 1);
    DA_CHECK(replaced[0].filePath == renamed);
    DA_CHECK(replaced[0].lineNumber == 1);
    DA_CHECK(replaced[0].lineContent == replacement);
    std::printf("[PASS] search replacement invalidates cached content "
                "(same size, CRLF preserved)\n");
  }
  RemoveTree(root);
}

static void TestReplacementWithPreservedMtime() {
  const auto root = CurrentRoot() + L"\\.tmp-orq\\search-replace-mtime";
  const auto child = root + L"\\child";
  const auto path = child + L"\\item.txt";
  RemoveTree(root);
  EnsureDir(CurrentRoot() + L"\\.tmp-orq");
  EnsureDir(root);
  EnsureDir(child);
  const std::string replacement = "CK012CHANGE";
  DA_CHECK(replacement.size() == strlen(kNeedle));
  WriteFileBytes(path, std::string(kNeedle) + "\r\n");
  WIN32_FILE_ATTRIBUTE_DATA before{};
  DA_CHECK(GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &before));
  {
    beats::DocumentManager documents;
    std::string error;
    DA_CHECK(documents.AuthorizeWorkspaceRoot(root, error));
    DA_CHECK(documents.AuthorizeWorkspaceRoot(child, error));
    beats::ProjectSearch search(documents);
    beats::SearchOptions opts;
    opts.query = kNeedle;
    opts.caseSensitive = true;
    // The same file can be retained under overlapping authorized roots.
    for (const auto &cachedRoot : {root, child}) {
      opts.rootDir = cachedRoot;
      DA_CHECK(search.ExecuteSearch(opts, &error).size() == 1);
      DA_CHECK(error.empty());
    }
    DA_CHECK(search.ReplaceInFiles(opts, replacement, error) == 1);
    DA_CHECK(error.empty());
    HANDLE handle = CreateFileW(path.c_str(), FILE_WRITE_ATTRIBUTES,
                                FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    DA_CHECK(handle != INVALID_HANDLE_VALUE);
    DA_CHECK(SetFileTime(handle, nullptr, nullptr, &before.ftLastWriteTime));
    DA_CHECK(CloseHandle(handle));
    WIN32_FILE_ATTRIBUTE_DATA after{};
    DA_CHECK(GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &after));
    DA_CHECK(CompareFileTime(&before.ftLastWriteTime, &after.ftLastWriteTime) ==
             0);
    DA_CHECK(before.nFileSizeHigh == after.nFileSizeHigh);
    DA_CHECK(before.nFileSizeLow == after.nFileSizeLow);
    std::string body;
    DA_CHECK(documents.ReadWorkspaceFile(path, body));
    DA_CHECK(body == replacement + "\r\n");
    for (const auto &cachedRoot : {root, child}) {
      opts.rootDir = cachedRoot;
      opts.query = kNeedle;
      const auto stale = search.ExecuteSearch(opts, &error);
      std::printf("[COLLISION] restored mtime, same size: old matches=%zu\n",
                  stale.size());
      std::fflush(stdout);
      DA_CHECK(error.empty() && stale.empty());
      opts.query = replacement;
      const auto fresh = search.ExecuteSearch(opts, &error);
      DA_CHECK(error.empty() && fresh.size() == 1);
      DA_CHECK(fresh[0].filePath == path);
      DA_CHECK(fresh[0].lineNumber == 1);
      DA_CHECK(fresh[0].lineContent == replacement);
    }
  }
  RemoveTree(root);
  std::printf("[PASS] replacement invalidates overlapping root caches even "
              "with identical mtime and size\n");
}

int main() {
  TestReplacementWithPreservedMtime();
  TestLargeFile();
  TestRootLru();
  TestDeletedRenamedAndReplaced();
  const std::wstring root = BuildFixture();
  long long coldMs = 0;
  long long warmMs = 0;
  // AuthorizeWorkspaceRoot retiene la raiz durante toda la vida del
  // DocumentManager: el fixture solo se puede borrar cuando ya no existe.
  {
    beats::DocumentManager documents;
    std::string error;
    DA_CHECK(documents.AuthorizeWorkspaceRoot(root, error));

    beats::ProjectSearch search(documents);
    beats::SearchOptions opts;
    opts.query = kNeedle;
    opts.rootDir = root;

    // Primera consulta: incluye indexado/lectura en frio.
    const auto coldStart = std::chrono::steady_clock::now();
    const auto cold = search.ExecuteSearch(opts, &error);
    const auto coldEnd = std::chrono::steady_clock::now();
    coldMs = ElapsedMs(coldStart, coldEnd);
    std::printf("[MEASURE] cold: %lld ms, %zu matches, %d files, error='%s'\n",
                coldMs, cold.size(), kFiles, error.c_str());
    std::fflush(stdout);

    // Segunda consulta: mismo arbol, debe servirse del indice/cache.
    const auto warmStart = std::chrono::steady_clock::now();
    const auto warm = search.ExecuteSearch(opts, &error);
    const auto warmEnd = std::chrono::steady_clock::now();
    warmMs = ElapsedMs(warmStart, warmEnd);
    std::printf("[MEASURE] warm: %lld ms, %zu matches\n", warmMs, warm.size());
    std::fflush(stdout);

    const long long budgetMs = 2000;
    std::printf("[BUDGET] cold=%lld ms warm=%lld ms limit=%lld ms\n", coldMs,
                warmMs, budgetMs);
    std::fflush(stdout);

    DA_CHECK(error.empty());
    DA_CHECK(cold.size() == static_cast<size_t>(kFiles / 100));
    for (const auto &match : cold)
      DA_CHECK(!UnderIgnored(match.filePath, root));
    DA_CHECK(warm.size() == cold.size());
    DA_CHECK(coldMs <= budgetMs);
    DA_CHECK(warmMs <= budgetMs);

    // maxResults corta el recorrido: no se devuelven mas coincidencias.
    beats::SearchOptions capped = opts;
    capped.maxResults = 7;
    const auto cappedMatches = search.ExecuteSearch(capped, &error);
    std::printf("[MEASURE] maxResults=7 -> %zu matches\n",
                cappedMatches.size());
    std::fflush(stdout);
    DA_CHECK(cappedMatches.size() == 7);

    // Invalidacion: archivo nuevo aparece en la siguiente consulta.
    const std::wstring fresh = root + L"\\dir00\\brand_new.txt";
    WriteFileBytes(fresh, Body(1, true));
    const auto added = search.ExecuteSearch(opts, &error);
    DA_CHECK(error.empty());
    bool sawNew = false;
    for (const auto &match : added)
      sawNew = sawNew || match.filePath == fresh;
    DA_CHECK(sawNew);

    // Invalidacion: archivo existente modificado aparece en la siguiente.
    const std::wstring changed = root + L"\\dir01\\file0100.txt";
    {
      HANDLE h = CreateFileW(changed.c_str(), FILE_APPEND_DATA, 0, nullptr,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      DA_CHECK(h != INVALID_HANDLE_VALUE);
      const std::string extra = std::string("\n") + kNeedle + "\n";
      DWORD written = 0;
      DA_CHECK(WriteFile(h, extra.data(), static_cast<DWORD>(extra.size()),
                         &written, nullptr) &&
               written == extra.size());
      CloseHandle(h);
    }
    const auto modified = search.ExecuteSearch(opts, &error);
    DA_CHECK(error.empty());
    size_t changedMatches = 0;
    for (const auto &match : modified)
      if (match.filePath == changed)
        ++changedMatches;
    DA_CHECK(changedMatches == 2);
  }

  std::printf("[PASS] presupuesto 5000 archivos (frio %lld ms, caliente %lld "
              "ms), exclusion de .git/node_modules/zig-out/.zig-cache e "
              "invalidacion por mtime/tamano\n",
              coldMs, warmMs);

  RemoveTree(root);
  RemoveDirectoryW((CurrentRoot() + L"\\.tmp-orq").c_str());
  std::printf("ALL PROJECT SEARCH TESTS PASSED!\n");
  return 0;
}
