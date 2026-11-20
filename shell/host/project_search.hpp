#ifndef BEATS_PROJECT_SEARCH_HPP
#define BEATS_PROJECT_SEARCH_HPP

#include <cstdint>
#include <mutex>
#include <regex>
#include <string>
#include <unordered_map>
#include <vector>

namespace beats {
class DocumentManager;

struct SearchMatch {
  std::wstring filePath;
  int lineNumber = 0;
  std::string lineContent;
  size_t matchOffset = 0;
  size_t matchLength = 0;
};

struct SearchOptions {
  std::string query;
  bool isRegex = false;
  bool caseSensitive = false;
  bool matchWholeWord = false;
  std::wstring rootDir;
  std::string includePattern;
  std::string excludePattern;
  // tope de coincidencias devueltas. Corta el recorrido en cuanto
  // se alcanza, para no leer el resto del arbol. El valor historico era 5000.
  size_t maxResults = 5000;
};

class ProjectSearch {
public:
  explicit ProjectSearch(DocumentManager &documents);
  ~ProjectSearch();

  std::vector<SearchMatch> ExecuteSearch(const SearchOptions &opts,
                                         std::string *error = nullptr);
  int ReplaceInFiles(const SearchOptions &opts, const std::string &replacement,
                     std::string &error);

private:
  // cache de contenido por raiz. La clave es la ruta canonica del
  // archivo y la entrada se invalida cuando cambia su mtime o tamano (los da
  // el propio FindFirstFile del recorrido, sin stat extra).
  struct CachedFile {
    uint64_t modified = 0;
    uint64_t size = 0;
    uint64_t generation = 0;
    std::string content;
  };
  struct RootCache {
    std::unordered_map<std::wstring, CachedFile> files;
    size_t bytes = 0;
    uint64_t generation = 0;
    uint64_t lastUsed = 0;
  };

  DocumentManager &m_documents;
  std::mutex m_cacheMutex;
  std::unordered_map<std::wstring, RootCache> m_cache;
  uint64_t m_cacheUse = 0;
};

} // namespace beats

#endif // BEATS_PROJECT_SEARCH_HPP
