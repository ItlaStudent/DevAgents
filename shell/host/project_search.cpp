#include "project_search.hpp"
#include "document_manager.hpp"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <sstream>
#include <windows.h>

namespace beats {

ProjectSearch::ProjectSearch(DocumentManager &documents)
    : m_documents(documents) {}

ProjectSearch::~ProjectSearch() {}

namespace {

constexpr size_t kDefaultMaxResults = 5000;
constexpr size_t kMaxResultsCap = 5000;
constexpr uint64_t kMaxCachedBytes = 64ull * 1024ull * 1024ull;
constexpr size_t kMaxCachedRoots = 8;
constexpr uint64_t kMaxFileBytes = 24ull * 1024ull * 1024ull;

struct ScannedFile {
  std::wstring path;
  uint64_t modified = 0;
  uint64_t size = 0;
};

uint64_t FileTimeValue(const FILETIME &time) {
  ULARGE_INTEGER value;
  value.LowPart = time.dwLowDateTime;
  value.HighPart = time.dwHighDateTime;
  return value.QuadPart;
}

// Carpetas pesadas o generadas que nunca aportan resultados utiles. La
// comparacion es insensible a mayusculas porque NTFS tambien lo es.
bool IgnoredName(const wchar_t *name) {
  for (const wchar_t *ignored :
       {L".git", L"node_modules", L"zig-out", L".zig-cache"})
    if (_wcsicmp(name, ignored) == 0)
      return true;
  return false;
}

void FastScanDir(DocumentManager &documents, const std::wstring &dir,
                 std::vector<ScannedFile> &files) {
  confined::LockedPath locked;
  if (!documents.LockReadDirectory(dir, locked))
    return;
  std::wstring searchPath = confined::Extended(locked.path) + L"\\*";
  WIN32_FIND_DATAW findData;
  HANDLE hFind = FindFirstFileW(searchPath.c_str(), &findData);
  if (hFind == INVALID_HANDLE_VALUE)
    return;

  do {
    if (wcscmp(findData.cFileName, L".") == 0 ||
        wcscmp(findData.cFileName, L"..") == 0)
      continue;
    if (IgnoredName(findData.cFileName) ||
        confined::IsSaveTemporaryName(findData.cFileName))
      continue;

    std::wstring fullPath = dir + L"\\" + findData.cFileName;
    // Never follow junctions/symlinks while enumerating replacement targets.
    if (findData.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
      continue;
    if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      FastScanDir(documents, fullPath, files);
    } else {
      ScannedFile file;
      file.path = std::move(fullPath);
      file.modified = FileTimeValue(findData.ftLastWriteTime);
      file.size = (static_cast<uint64_t>(findData.nFileSizeHigh) << 32) |
                  findData.nFileSizeLow;
      files.push_back(std::move(file));
    }
  } while (FindNextFileW(hFind, &findData));

  FindClose(hFind);
}

// Lee un archivo cuya ruta ya salio de un directorio autorizado y bloqueado.
// confined::Validate comprueba por handle que sigue siendo el mismo archivo
// regular, sin reparse point, sin hardlink y con la ruta canonica esperada
// (mismo rechazo que DocumentManager::ReadWorkspaceFile), pero sin bloquear
// cada ancestro por archivo ni revalidar la ruta por componentes: ese era el
// coste que hacia que una consulta en frio tardase mas de 4 s.
enum class ReadResult { Ok, TooLarge, Denied };

ReadResult ReadFileDirect(const std::wstring &path, std::string &content,
                          uint64_t &modified, uint64_t &size) {
  content.clear();
  HANDLE h = CreateFileW(
      confined::Extended(path).c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return ReadResult::Denied;
  BY_HANDLE_FILE_INFORMATION info{};
  bool ok = confined::Validate(h, path, false) &&
            GetFileInformationByHandle(h, &info);
  modified = FileTimeValue(info.ftLastWriteTime);
  size = (static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
  // Oversized regular files are omitted, not treated as authorization errors.
  // Validate first so the size exception never bypasses confinement checks.
  if (ok && size > kMaxFileBytes) {
    CloseHandle(h);
    return ReadResult::TooLarge;
  }
  if (ok) {
    content.resize(static_cast<size_t>(size));
    size_t offset = 0;
    while (offset < content.size()) {
      DWORD read = 0;
      const DWORD chunk = static_cast<DWORD>(
          std::min<size_t>(content.size() - offset, 1024 * 1024));
      if (!ReadFile(h, content.data() + offset, chunk, &read, nullptr) ||
          !read || read > chunk) {
        ok = false;
        break;
      }
      offset += read;
    }
  } else {
    ok = false;
  }
  CloseHandle(h);
  if (!ok)
    content.clear();
  return ok ? ReadResult::Ok : ReadResult::Denied;
}

} // namespace

std::vector<SearchMatch> ProjectSearch::ExecuteSearch(const SearchOptions &opts,
                                                      std::string *error) {
  std::vector<SearchMatch> results;
  if (error)
    error->clear();
  confined::LockedPath locked;
  if (!m_documents.LockReadDirectory(opts.rootDir, locked)) {
    if (error)
      *error = "E_SEARCH_ROOT_NOT_AUTHORIZED: La carpeta de búsqueda no está "
               "autorizada "
               "o no es segura";
    return results;
  }
  if (opts.query.empty() || opts.rootDir.empty())
    return results;

  // El recorrido y la cache se anclan a la ruta canonica ya autorizada.
  const std::wstring canonicalRoot = locked.path;
  const size_t limit = opts.maxResults == 0
                           ? kDefaultMaxResults
                           : std::min<size_t>(opts.maxResults, kMaxResultsCap);
  bool scannedAll = true;
  std::vector<ScannedFile> files;
  std::lock_guard<std::mutex> cacheGuard(m_cacheMutex);
  if (m_cache.find(canonicalRoot) == m_cache.end() &&
      m_cache.size() >= kMaxCachedRoots) {
    const auto oldest = std::min_element(
        m_cache.begin(), m_cache.end(), [](const auto &a, const auto &b) {
          return a.second.lastUsed < b.second.lastUsed;
        });
    m_cache.erase(oldest);
  }
  RootCache &cache = m_cache[canonicalRoot];
  cache.lastUsed = ++m_cacheUse;
  ++cache.generation;
  FastScanDir(m_documents, canonicalRoot, files);

  std::regex reg;
  if (opts.isRegex) {
    auto flags = std::regex::ECMAScript;
    if (!opts.caseSensitive)
      flags |= std::regex::icase;
    try {
      reg = std::regex(opts.query, flags);
    } catch (...) {
      return results;
    }
  }

  std::string lowerQuery = opts.query;
  if (!opts.caseSensitive) {
    for (auto &c : lowerQuery)
      c = tolower(static_cast<unsigned char>(c));
  }

  // Reemplaza (o inserta) la entrada de cache de un archivo. Si el contenido
  // supera el presupuesto de memoria de la raiz, el archivo se busca igual
  // pero no se retiene.
  auto remember = [&](const std::wstring &path, uint64_t modified,
                      uint64_t size, const std::string &body) {
    auto found = cache.files.find(path);
    if (found != cache.files.end()) {
      cache.bytes -= std::min(cache.bytes, found->second.content.size());
      found->second.modified = modified;
      found->second.size = size;
      found->second.generation = cache.generation;
      found->second.content = body;
      cache.bytes += body.size();
      if (cache.bytes > kMaxCachedBytes) {
        cache.bytes -= found->second.content.size();
        cache.files.erase(found);
      }
      return;
    }
    if (cache.bytes + body.size() > kMaxCachedBytes)
      return;
    CachedFile entry;
    entry.modified = modified;
    entry.size = size;
    entry.generation = cache.generation;
    entry.content = body;
    cache.bytes += body.size();
    cache.files.emplace(path, std::move(entry));
  };

  for (const auto &file : files) {
    std::string content;
    auto cached = cache.files.find(file.path);
    if (cached != cache.files.end() &&
        cached->second.modified == file.modified &&
        cached->second.size == file.size) {
      // Sin cambios segun FindFirstFile: no se vuelve a abrir ni a leer.
      content = cached->second.content;
      cached->second.generation = cache.generation;
    } else {
      uint64_t modified = 0;
      uint64_t size = 0;
      const auto read = ReadFileDirect(file.path, content, modified, size);
      if (read == ReadResult::TooLarge)
        continue;
      if (read != ReadResult::Ok) {
        if (error)
          *error =
              "E_SEARCH_FILE_DENIED: Archivo de búsqueda denegado o incompleto";
        return {};
      }
      remember(file.path, modified, size, content);
    }
    if (content.substr(0, 1024).find('\0') != std::string::npos)
      continue;
    std::istringstream in(content);

    std::string line;
    int lineNum = 1;
    while (std::getline(in, line)) {
      if (!line.empty() && line.back() == '\r')
        line.pop_back();

      if (opts.isRegex) {
        std::smatch m;
        if (std::regex_search(line, m, reg)) {
          SearchMatch match;
          match.filePath = file.path;
          match.lineNumber = lineNum;
          match.lineContent = line;
          match.matchOffset = m.position();
          match.matchLength = m.length();
          results.push_back(match);
          if (results.size() >= limit) {
            scannedAll = false;
            break;
          }
        }
      } else {
        std::string checkLine = line;
        if (!opts.caseSensitive) {
          for (auto &c : checkLine)
            c = tolower(static_cast<unsigned char>(c));
        }
        size_t pos = checkLine.find(lowerQuery);
        if (pos != std::string::npos) {
          SearchMatch match;
          match.filePath = file.path;
          match.lineNumber = lineNum;
          match.lineContent = line;
          match.matchOffset = pos;
          match.matchLength = opts.query.length();
          results.push_back(match);
          if (results.size() >= limit) {
            scannedAll = false;
            break;
          }
        }
      }
      lineNum++;
    }
    if (results.size() >= limit) {
      scannedAll = false;
      break;
    }
  }

  // Un recorrido completo es la unica ocasion en la que se puede afirmar que
  // las entradas no visitadas ya no existen: se descartan (archivos borrados).
  if (scannedAll) {
    for (auto it = cache.files.begin(); it != cache.files.end();) {
      if (it->second.generation != cache.generation) {
        cache.bytes -= std::min(cache.bytes, it->second.content.size());
        it = cache.files.erase(it);
      } else {
        ++it;
      }
    }
  }

  return results;
}

int ProjectSearch::ReplaceInFiles(const SearchOptions &opts,
                                  const std::string &replacement,
                                  std::string &error) {
  error.clear();
  // A message selects an already native-authorized root; it cannot grant one.
  if (!m_documents.IsAuthorizedWorkspaceRoot(opts.rootDir)) {
    error = "E_REPLACE_ROOT_NOT_AUTHORIZED: La carpeta del reemplazo no está "
            "autorizada";
    return -1;
  }
  auto matches = ExecuteSearch(opts, &error);
  if (!error.empty())
    return -1;
  int replacedCount = 0;

  std::unordered_map<std::wstring, std::vector<SearchMatch>> fileMatches;
  for (const auto &m : matches) {
    fileMatches[m.filePath].push_back(m);
  }

  for (const auto &pair : fileMatches) {
    int fileReplacements = 0;
    std::string content;
    if (!m_documents.ReadWorkspaceFile(pair.first, content)) {
      error = "E_REPLACE_READ_FAILED: No se pudo leer el archivo a reemplazar";
      return -1;
    }
    std::istringstream in(content);

    std::ostringstream ss;
    std::string line;
    int lineNum = 1;
    while (std::getline(in, line)) {
      bool hasCR = (!line.empty() && line.back() == '\r');
      if (hasCR)
        line.pop_back();

      bool lineMatched = false;
      for (const auto &m : pair.second) {
        if (m.lineNumber == lineNum) {
          lineMatched = true;
          break;
        }
      }

      if (lineMatched) {
        size_t pos = 0;
        if (opts.caseSensitive) {
          while ((pos = line.find(opts.query, pos)) != std::string::npos) {
            line.replace(pos, opts.query.length(), replacement);
            pos += replacement.length();
            fileReplacements++;
          }
        } else {
          // Simple replace for demo
          line.replace(0, line.length(), replacement);
          fileReplacements++;
        }
      }

      ss << line << (hasCR ? "\r\n" : "\n");
      lineNum++;
    }
    if (in.bad()) {
      error = "E_REPLACE_READ_FAILED: No se pudo leer completo el archivo a "
              "reemplazar";
      return -1;
    }

    // Keep the write and invalidation atomic with respect to ExecuteSearch.
    // The same canonical file may be cached under overlapping roots.
    std::lock_guard<std::mutex> cacheGuard(m_cacheMutex);
    if (!m_documents.WriteWorkspaceFile(pair.first, ss.str(), error))
      return -1;
    for (auto &root : m_cache) {
      auto cached = root.second.files.find(pair.first);
      if (cached != root.second.files.end()) {
        root.second.bytes -=
            std::min(root.second.bytes, cached->second.content.size());
        root.second.files.erase(cached);
      }
    }
    replacedCount += fileReplacements;
  }

  return replacedCount;
}

} // namespace beats
