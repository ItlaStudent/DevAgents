#ifndef BEATS_HUNK_MANAGER_HPP
#define BEATS_HUNK_MANAGER_HPP

#include <string>
#include <vector>

namespace beats {
class DocumentManager;

struct Hunk {
  int id = 0;
  int startLine = 0;
  int originalLineCount = 0;
  int newLineCount = 0;
  std::string originalContent;
  std::string newContent;
  bool accepted = false;
  bool rejected = false;
};

class HunkManager {
public:
  explicit HunkManager(DocumentManager &documents);
  ~HunkManager();

  bool AcceptHunk(const std::wstring &path, int hunkId,
                  const std::string &originalFileContent,
                  const std::vector<Hunk> &hunks,
                  std::string &outNewFileContent,
                  std::string *outError = nullptr);

  bool RejectHunk(const std::wstring &path, int hunkId,
                  const std::string &originalFileContent,
                  const std::vector<Hunk> &hunks,
                  std::string &outNewFileContent,
                  std::string *outError = nullptr);

private:
  DocumentManager &m_documents;
};

} // namespace beats

#endif // BEATS_HUNK_MANAGER_HPP
