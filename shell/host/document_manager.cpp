#include "document_manager.hpp"
#include <iostream>
#include <sstream>

namespace beats {

DocumentManager::DocumentManager() {}

DocumentManager::~DocumentManager() {}

uint64_t DocumentManager::GetFileModifiedTime(const std::wstring &path) const {
  WIN32_FILE_ATTRIBUTE_DATA fileInfo;
  if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fileInfo)) {
    ULARGE_INTEGER uli;
    uli.LowPart = fileInfo.ftLastWriteTime.dwLowDateTime;
    uli.HighPart = fileInfo.ftLastWriteTime.dwHighDateTime;
    return uli.QuadPart;
  }
  return 0;
}

bool DocumentManager::OpenDocument(const std::wstring &path,
                                   DocumentState &outDoc) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  std::string buffer;
  if (!ReadWorkspaceFile(path, buffer))
    return false;

  outDoc.path = path;
  outDoc.content = buffer;
  outDoc.lastModifiedTime = GetFileModifiedTime(path);
  outDoc.isDirty = false;

  // Detect CRLF vs LF
  if (buffer.find("\r\n") != std::string::npos) {
    outDoc.lineEnding = "\r\n";
  } else {
    outDoc.lineEnding = "\n";
  }

  // Detect UTF-8 BOM
  if (buffer.size() >= 3 && static_cast<unsigned char>(buffer[0]) == 0xEF &&
      static_cast<unsigned char>(buffer[1]) == 0xBB &&
      static_cast<unsigned char>(buffer[2]) == 0xBF) {
    outDoc.encoding = "UTF-8-BOM";
    outDoc.content = buffer.substr(3);
  } else {
    outDoc.encoding = "UTF-8";
    outDoc.content = buffer;
  }

  KeepTrack(outDoc);
  return true;
}

bool DocumentManager::ReadWorkspaceFile(const std::wstring &path,
                                        std::string &content) const {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  content.clear();
  std::wstring canonical;
  if (!confined::Absolute(path, canonical))
    return false;
  bool allowed = IsWorkspacePath(path);
  for (const auto &root : m_readRoots)
    allowed = allowed || confined::Inside(root->path, canonical);
  if (!allowed)
    return false;
  confined::LockedPath locked;
  if (!confined::LockParents(canonical, locked, false,
                             confined::kMutationDirectoryShare))
    return false;
  HANDLE h = confined::OpenForRead(locked);
  if (h == INVALID_HANDLE_VALUE)
    return false;
  LARGE_INTEGER size{};
  // The bridge transport is bounded to 28 MiB; larger documents cannot be
  // delivered. Never use INVALID_FILE_SIZE as an allocation size.
  bool ok = GetFileSizeEx(h, &size) && size.QuadPart >= 0 &&
            size.QuadPart <= 24 * 1024 * 1024;
  if (ok) {
    content.resize(static_cast<size_t>(size.QuadPart));
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
  }
  CloseHandle(h);
  if (!ok)
    content.clear();
  return ok;
}

bool DocumentManager::LockReadDirectory(const std::wstring &path,
                                        confined::LockedPath &locked) const {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  std::wstring canonical;
  if (!confined::Absolute(path, canonical))
    return false;
  bool allowed = IsAuthorizedWorkspaceRoot(path) || IsWorkspacePath(path);
  for (const auto &root : m_readRoots)
    allowed = allowed || confined::Equal(root->path, canonical) ||
              confined::Inside(root->path, canonical);
  return allowed && confined::LockParents(canonical, locked, true,
                                          confined::kMutationDirectoryShare);
}

bool DocumentManager::AuthorizeReadRoot(const std::wstring &root,
                                        std::string &error) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  auto locked = std::make_unique<confined::LockedPath>();
  if (!confined::LockParents(root, *locked, true)) {
    error = "E_ROOT_UNSAFE: La carpeta de lectura contiene un componente "
            "inseguro o un "
            "punto de reanálisis";
    return false;
  }
  m_readRoots.push_back(std::move(locked));
  return true;
}

bool DocumentManager::CreateWorkspaceEntry(const std::wstring &parent,
                                           const std::wstring &name,
                                           bool directory,
                                           const std::string &content,
                                           std::string &error) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  const auto path = parent + L"\\" + name;
  std::wstring canonical;
  if (name.empty() || name.find_first_of(L"\\/") != std::wstring::npos ||
      !IsWritableWorkspacePath(path) || !confined::Absolute(path, canonical)) {
    error = "E_CREATE_NOT_AUTHORIZED: La ruta de creación no está autorizada";
    return false;
  }
  confined::LockedPath locked;
  if (!confined::LockParents(directory ? parent : path, locked, directory,
                             confined::kMutationDirectoryShare)) {
    error = "E_CREATE_UNSAFE: Creación denegada: ruta insegura o punto de "
            "reanálisis";
    return false;
  }
  HANDLE h = directory ? confined::CreateDirectory(locked, name)
                       : confined::OpenForWrite(locked, true);
  if (h == INVALID_HANDLE_VALUE) {
    error = "E_CREATE_EXISTS: No se puede crear: ya existe o el destino no es "
            "seguro";
    return false;
  }
  const bool ok = directory || confined::WriteComplete(h, content);
  CloseHandle(h);
  if (!ok)
    error = "E_WRITE_INCOMPLETE: No se escribió el archivo completo";
  return ok;
}

bool DocumentManager::CheckConflict(const std::wstring &path,
                                    uint64_t lastReadTime) const {
  uint64_t currentMod = GetFileModifiedTime(path);
  return (currentMod > 0 && lastReadTime > 0 && currentMod > lastReadTime);
}

bool DocumentManager::SaveDocument(const std::wstring &path,
                                   const std::string &newContent, bool force,
                                   std::string &outError,
                                   const std::string &saveToken) {
  return WriteAuthorizedFile(path, newContent, force, outError, saveToken);
}

bool DocumentManager::WriteWorkspaceFile(const std::wstring &path,
                                         const std::string &content,
                                         std::string &error) {
  return WriteAuthorizedFile(path, content, true, error, "");
}

bool DocumentManager::WriteAuthorizedFile(const std::wstring &path,
                                          const std::string &newContent,
                                          bool force, std::string &outError,
                                          const std::string &saveToken) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  outError.clear();
  std::unique_ptr<confined::LockedPath> target;
  if (!saveToken.empty()) {
    const auto token = m_saveTokens.find(saveToken);
    if (token != m_saveTokens.end()) {
      target = std::move(token->second);
      m_saveTokens.erase(token); // Consume on every attempt, even a failed one.
    }
    std::wstring canonical;
    if (!target || !confined::Absolute(path, canonical) ||
        !confined::Equal(canonical, target->path)) {
      outError = "E_SAVE_TOKEN_INVALID: El permiso de «Guardar como» no es "
                 "válido o ya se "
                 "usó";
      return false;
    }
  } else {
    if (!IsWritableWorkspacePath(path)) {
      outError =
          "E_SAVE_NOT_AUTHORIZED: La ruta de guardado no está autorizada";
      return false;
    }
    target = std::make_unique<confined::LockedPath>();
    // Compartición de sesión (READ|WRITE, sin DELETE): el renombrado atómico
    // del archivo hermano modifica el directorio padre y chocaría con un
    // handle de sólo lectura, incluso con el nuestro. Sin FILE_SHARE_DELETE
    // ningún componente puede renombrarse ni borrarse, y la hoja se valida y
    // se reemplaza por nombre, nunca se escribe a través de ella.
    if (!confined::LockParents(path, *target, false,
                               confined::kSessionDirectoryShare)) {
      outError = "E_SAVE_UNSAFE: Guardado denegado: ruta insegura o punto de "
                 "reanálisis";
      return false;
    }
  }
  auto it = m_documents.find(path);
  if (it != m_documents.end()) {
    if (!force && CheckConflict(path, it->second.lastModifiedTime)) {
      outError = "E_SAVE_CONFLICT: El archivo cambió en disco";
      return false;
    }
  }

  // Escritura atómica por handle: un fallo previo al reemplazo conserva el
  // contenido anterior. Un fallo de verificación posterior se informa aparte.
  // Mantiene el rechazo de reparse points, hardlinks y destinos de solo
  // lectura.
  FILETIME modified{};
  switch (confined::AtomicWrite(*target, newContent, modified)) {
  case confined::AtomicStatus::Ok:
    break;
  case confined::AtomicStatus::OpenFailed:
    outError = "E_SAVE_OPEN_FAILED: No se pudo abrir el archivo para escribir";
    return false;
  case confined::AtomicStatus::WriteFailed:
    outError = "E_WRITE_INCOMPLETE: No se escribió el documento completo";
    return false;
  case confined::AtomicStatus::ReplacedUnverified:
    outError =
        "E_SAVE_REPLACED_UNVERIFIED: El archivo fue reemplazado, pero no "
        "se pudo verificar. Debe revisar o recargar el archivo antes de "
        "volver a guardar";
    return false;
  }

  DocumentState doc;
  doc.path = path;
  doc.content = newContent;
  doc.lastModifiedTime =
      (static_cast<uint64_t>(modified.dwHighDateTime) << 32) |
      modified.dwLowDateTime;
  doc.isDirty = false;
  KeepTrack(doc);

  return true;
}

bool DocumentManager::IsInstallationDirectory(const std::wstring &root) {
  std::wstring absolute;
  if (!confined::Absolute(root, absolute))
    return false;
  wchar_t executable[32768];
  const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
  if (length && length < 32768) {
    const std::wstring path(executable, length);
    std::wstring directory;
    if (confined::Absolute(path.substr(0, path.find_last_of(L"\\/")),
                           directory) &&
        confined::Equal(absolute, directory))
      return true;
  }
  const DWORD engine = GetFileAttributesW(
      confined::Extended(absolute + L"\\devagents-engine.exe").c_str());
  return engine != INVALID_FILE_ATTRIBUTES &&
         !(engine & FILE_ATTRIBUTE_DIRECTORY);
}

bool DocumentManager::ActivateWorkspaceRoot(
    const std::wstring &root, std::string &error,
    const WorkspaceActivation &activate) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  if (!IsAuthorizedWorkspaceRoot(root) || IsInstallationDirectory(root)) {
    error = "E_WORKSPACE_REQUIRED: Elige una carpeta de proyecto autorizada.";
    return false;
  }
  if (!activate(root, error))
    return false;
  m_activeWorkspaceRoot = root;
  return true;
}

std::wstring DocumentManager::ActiveWorkspaceRoot() const {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  return m_activeWorkspaceRoot;
}

bool DocumentManager::AuthorizeWorkspaceRoot(
    const std::wstring &root, std::string &error,
    const WorkspaceActivation &activate) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  if (IsInstallationDirectory(root)) {
    error = "E_WORKSPACE_INSTALLATION: Elige una carpeta de proyecto fuera de "
            "la instalación de DevAgents.";
    return false;
  }
  auto locked = std::make_unique<confined::LockedPath>();
  if (!confined::LockParents(root, *locked, true)) {
    error = "E_ROOT_UNSAFE: La carpeta de trabajo contiene un componente "
            "inseguro o "
            "un punto de reanálisis";
    return false;
  }
  for (const auto &existing : m_workspaceRoots)
    if (confined::Equal(existing->path, locked->path))
      return !activate ||
             ActivateWorkspaceRoot(existing->path, error, activate);
  m_workspaceRoots.push_back(std::move(locked));
  if (activate &&
      !ActivateWorkspaceRoot(m_workspaceRoots.back()->path, error, activate)) {
    m_workspaceRoots.pop_back();
    return false;
  }
  return true;
}

bool DocumentManager::IsWorkspacePath(const std::wstring &path) const {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  std::wstring canonical;
  if (!confined::Absolute(path, canonical))
    return false;
  for (const auto &root : m_workspaceRoots)
    if (confined::Inside(root->path, canonical))
      return true;
  return false;
}

static bool IsGitMetadataPath(const std::wstring &canonical) {
  // Cualquier componente `.git` (carpeta o archivo de worktree) y el archivo
  // .gitattributes: configuran filtros/hooks que Git ejecuta después.
  size_t start = 0;
  while (start < canonical.size()) {
    size_t end = canonical.find(L'\\', start);
    const std::wstring part = canonical.substr(
        start, end == std::wstring::npos ? std::wstring::npos : end - start);
    if (confined::Equal(part, L".git") ||
        (end == std::wstring::npos && confined::Equal(part, L".gitattributes")))
      return true;
    if (end == std::wstring::npos)
      break;
    start = end + 1;
  }
  return false;
}

bool DocumentManager::IsWritableWorkspacePath(const std::wstring &path) const {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  std::wstring canonical;
  if (!IsWorkspacePath(path) || !confined::Absolute(path, canonical))
    return false;
  for (const auto &denied : m_writeDenied)
    if (confined::Equal(denied, canonical) ||
        confined::Inside(denied, canonical))
      return false;
  return !IsGitMetadataPath(canonical);
}

void DocumentManager::DenyWritesBelow(const std::wstring &directory) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  std::wstring canonical;
  if (confined::Absolute(directory, canonical))
    m_writeDenied.push_back(std::move(canonical));
}

static std::wstring EnvironmentValue(const wchar_t *name) {
  wchar_t value[32768];
  const DWORD length = GetEnvironmentVariableW(name, value, 32768);
  return length && length < 32768 ? std::wstring(value, length)
                                  : std::wstring();
}

bool DocumentManager::IsBroadStartupRoot(const std::wstring &path) {
  std::wstring canonical;
  if (!confined::Absolute(path, canonical))
    return true;
  // Unidad completa (o recurso UNC completo): nunca como raíz por defecto.
  if (canonical.size() <= confined::VolumePrefixLength(canonical))
    return true;
  wchar_t windows[MAX_PATH];
  const UINT windowsLength = GetWindowsDirectoryW(windows, MAX_PATH);
  std::vector<std::wstring> protectedTrees;   // la raíz no puede estar dentro
  std::vector<std::wstring> protectedAnchors; // ni ser ancestro de ellos
  if (windowsLength && windowsLength < MAX_PATH)
    protectedTrees.emplace_back(windows, windowsLength);
  for (const wchar_t *name :
       {L"ProgramFiles", L"ProgramFiles(x86)", L"ProgramW6432"})
    if (const auto value = EnvironmentValue(name); !value.empty())
      protectedTrees.push_back(value);
  protectedAnchors = protectedTrees;
  for (const wchar_t *name : {L"USERPROFILE", L"ProgramData"})
    if (const auto value = EnvironmentValue(name); !value.empty())
      protectedAnchors.push_back(value);
  for (const auto &tree : protectedTrees) {
    std::wstring checked;
    if (confined::Absolute(tree, checked) &&
        (confined::Equal(checked, canonical) ||
         confined::Inside(checked, canonical)))
      return true;
  }
  for (const auto &anchor : protectedAnchors) {
    std::wstring checked;
    if (confined::Absolute(anchor, checked) &&
        (confined::Equal(checked, canonical) ||
         confined::Inside(canonical, checked)))
      return true;
  }
  return false;
}

bool DocumentManager::IsAuthorizedWorkspaceRoot(
    const std::wstring &root) const {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  std::wstring canonical;
  if (!confined::Absolute(root, canonical))
    return false;
  for (const auto &authorized : m_workspaceRoots)
    if (confined::Equal(authorized->path, canonical))
      return true;
  return false;
}

bool DocumentManager::AuthorizeSaveAs(const std::wstring &path,
                                      std::string &token, std::string &error) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  token.clear();
  auto locked = std::make_unique<confined::LockedPath>();
  if (!confined::LockParents(path, *locked, false)) {
    error = "E_SAVE_UNSAFE: La ruta de «Guardar como» contiene un componente "
            "inseguro o un punto de reanálisis";
    return false;
  }
  // OS CSPRNG, loaded from System32 so no third-party runtime/dependency.
  HMODULE bcrypt =
      LoadLibraryExW(L"bcrypt.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  using Generate = LONG(WINAPI *)(void *, unsigned char *, ULONG, ULONG);
  auto generate = bcrypt ? reinterpret_cast<Generate>(
                               GetProcAddress(bcrypt, "BCryptGenRandom"))
                         : nullptr;
  unsigned char random[32];
  const bool generated =
      generate && generate(nullptr, random, sizeof(random), 2) >= 0;
  if (bcrypt)
    FreeLibrary(bcrypt);
  if (!generated) {
    error =
        "E_SAVE_TOKEN_FAILED: No se pudo generar el permiso de «Guardar como»";
    return false;
  }
  constexpr char hex[] = "0123456789abcdef";
  for (unsigned char byte : random) {
    token += hex[byte >> 4];
    token += hex[byte & 15];
  }
  // The session retains only one unused dialog authorization, with locked
  // parents.
  m_saveTokens.clear();
  m_saveTokens.emplace(token, std::move(locked));
  return true;
}

void DocumentManager::KeepTrack(const DocumentState &doc) {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  m_documents[doc.path] = doc;
}

bool DocumentManager::GetTracked(const std::wstring &path,
                                 DocumentState &outDoc) const {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  auto it = m_documents.find(path);
  if (it != m_documents.end()) {
    outDoc = it->second;
    return true;
  }
  return false;
}

std::vector<std::wstring> DocumentManager::DirtyPaths() const {
  std::lock_guard<std::recursive_mutex> guard(m_mutex);
  std::vector<std::wstring> out;
  for (const auto &kv : m_documents) {
    if (kv.second.isDirty)
      out.push_back(kv.first);
  }
  return out;
}

} // namespace beats
