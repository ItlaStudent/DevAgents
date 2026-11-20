#ifndef BEATS_DOCUMENT_MANAGER_HPP
#define BEATS_DOCUMENT_MANAGER_HPP

#include "confined_write.hpp"
#include <chrono>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <windows.h>

namespace beats {

struct DocumentState {
  std::wstring path;
  std::string content;
  std::string encoding = "UTF-8";
  std::string lineEnding = "\r\n"; // CRLF vs LF
  bool isDirty = false;
  uint64_t lastModifiedTime = 0;
};

class DocumentManager {
public:
  DocumentManager();
  ~DocumentManager();

  bool OpenDocument(const std::wstring &path, DocumentState &outDoc);
  bool ReadWorkspaceFile(const std::wstring &path, std::string &content) const;
  bool LockReadDirectory(const std::wstring &path,
                         confined::LockedPath &locked) const;
  bool AuthorizeReadRoot(const std::wstring &root, std::string &error);
  bool CreateWorkspaceEntry(const std::wstring &parent,
                            const std::wstring &name, bool directory,
                            const std::string &content, std::string &error);
  bool SaveDocument(const std::wstring &path, const std::string &newContent,
                    bool force, std::string &outError,
                    const std::string &saveToken = "");
  // Only native workspace selection / Save As may grant write authority.
  using WorkspaceActivation =
      std::function<bool(const std::wstring &, std::string &)>;
  bool AuthorizeWorkspaceRoot(const std::wstring &root, std::string &error,
                              const WorkspaceActivation &activate = {});
  bool ActivateWorkspaceRoot(const std::wstring &root, std::string &error,
                             const WorkspaceActivation &activate);
  static bool IsInstallationDirectory(const std::wstring &root);
  std::wstring ActiveWorkspaceRoot() const;
  bool AuthorizeSaveAs(const std::wstring &path, std::string &token,
                       std::string &error);
  bool IsWorkspacePath(const std::wstring &path) const;
  // Escritura: dentro de una raíz concedida Y fuera de las zonas protegidas
  // (bundle servido, directorio del ejecutable, metadatos de Git). Las lecturas
  // y el explorador siguen usando IsWorkspacePath.
  bool IsWritableWorkspacePath(const std::wstring &path) const;
  void DenyWritesBelow(const std::wstring &directory);
  // Perfil, Windows, Program Files, ProgramData y sus ancestros (incluida la
  // unidad) no se conceden por defecto como raíz inicial: hay que elegirlos con
  // dialog.pickWorkspace.
  static bool IsBroadStartupRoot(const std::wstring &path);
  bool IsAuthorizedWorkspaceRoot(const std::wstring &root) const;
  // Search/hunks have workspace authority only, never a Save As token.
  bool WriteWorkspaceFile(const std::wstring &path, const std::string &content,
                          std::string &error);
  bool CheckConflict(const std::wstring &path, uint64_t lastReadTime) const;
  uint64_t GetFileModifiedTime(const std::wstring &path) const;

  void KeepTrack(const DocumentState &doc);
  bool GetTracked(const std::wstring &path, DocumentState &outDoc) const;

  // E5.21: documentos rastreados con cambios sin guardar — el cierre de la
  // ventana principal lo comprueba antes de arrastrar a las secundarias.
  // Las llamadas llegan del hilo de UI; m_documents se toca solo ahi.
  std::vector<std::wstring> DirtyPaths() const;

private:
  mutable std::recursive_mutex m_mutex;
  // Single authorization + handle-confined writer for every host editor write.
  bool WriteAuthorizedFile(const std::wstring &path, const std::string &content,
                           bool force, std::string &error,
                           const std::string &saveToken);
  std::unordered_map<std::wstring, DocumentState> m_documents;
  std::vector<std::unique_ptr<confined::LockedPath>> m_workspaceRoots;
  std::wstring m_activeWorkspaceRoot;
  std::vector<std::unique_ptr<confined::LockedPath>> m_readRoots;
  std::vector<std::wstring> m_writeDenied;
  std::unordered_map<std::string, std::unique_ptr<confined::LockedPath>>
      m_saveTokens;
};

} // namespace beats

#endif // BEATS_DOCUMENT_MANAGER_HPP
