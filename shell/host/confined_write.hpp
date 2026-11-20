#ifndef BEATS_CONFINED_WRITE_HPP
#define BEATS_CONFINED_WRITE_HPP

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>
#include <windows.h>
#include <winternl.h>

namespace beats {
namespace confined {
// Same invariant as core/confined_fs.zig: retain each ancestor without
// FILE_SHARE_DELETE, reject reparse points, and write through the checked
// handle.
struct LockedPath {
  std::wstring path;
  std::vector<HANDLE> handles;
  LockedPath() = default;
  LockedPath(const LockedPath &) = delete;
  LockedPath &operator=(const LockedPath &) = delete;
  ~LockedPath() {
    for (HANDLE h : handles)
      CloseHandle(h);
  }
};

inline bool Equal(const std::wstring &a, const std::wstring &b) {
  return a.size() == b.size() &&
         CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(),
                              static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}

inline bool Absolute(const std::wstring &input, std::wstring &path) {
  path = input;
  std::replace(path.begin(), path.end(), L'/', L'\\');
  // A normal UNC name is only syntax, not authorization: DocumentManager
  // checks a native root/token before this name can cause filesystem IO.
  // Device namespaces, drive-relative paths, ADS and Win32 aliases are denied.
  if (path.size() < 4 || path.size() >= 32760)
    return false;
  const bool unc = path.compare(0, 2, L"\\\\") == 0;
  if (unc) {
    if (path.compare(0, 4, L"\\\\?\\") == 0 ||
        path.compare(0, 4, L"\\\\.\\") == 0)
      return false;
    const size_t serverEnd = path.find(L'\\', 2);
    if (serverEnd == std::wstring::npos || serverEnd == 2 ||
        serverEnd + 1 == path.size())
      return false;
    const size_t shareEnd = path.find(L'\\', serverEnd + 1);
    if (shareEnd == path.size() - 1)
      path.pop_back(); // Native share roots / handle names may end in '\\'.
  } else if (!((path[0] >= L'A' && path[0] <= L'Z') ||
               (path[0] >= L'a' && path[0] <= L'z')) ||
             path[1] != L':' || path[2] != L'\\') {
    return false;
  }
  size_t start = unc ? 2 : 3;
  while (start < path.size()) {
    const size_t end = path.find(L'\\', start);
    const std::wstring part = path.substr(start, end - start);
    if (part.empty() || part == L"." || part == L".." || part.back() == L'.' ||
        part.back() == L' ')
      return false;
    for (wchar_t c : part)
      if (c < 32 || c == 127 ||
          std::wstring(L":\"<>|*?").find(c) != std::wstring::npos)
        return false;
    const auto stem = part.substr(0, part.find(L'.'));
    if (Equal(stem, L"CON") || Equal(stem, L"PRN") || Equal(stem, L"AUX") ||
        Equal(stem, L"NUL") ||
        (stem.size() == 4 &&
         (Equal(stem.substr(0, 3), L"COM") ||
          Equal(stem.substr(0, 3), L"LPT")) &&
         stem[3] >= L'0' && stem[3] <= L'9'))
      return false;
    if (end == std::wstring::npos)
      break;
    start = end + 1;
    if (start == path.size())
      return false;
  }
  return true;
}

inline size_t VolumePrefixLength(const std::wstring &path) {
  if (path.compare(0, 2, L"\\\\") != 0)
    return 3;
  const size_t serverEnd = path.find(L'\\', 2);
  const size_t shareEnd = path.find(L'\\', serverEnd + 1);
  return shareEnd == std::wstring::npos ? path.size() : shareEnd;
}

inline std::wstring Extended(const std::wstring &path) {
  return path.compare(0, 2, L"\\\\") == 0 ? L"\\\\?\\UNC\\" + path.substr(2)
                                          : L"\\\\?\\" + path;
}

inline bool HandleName(const std::wstring &name, std::wstring &path) {
  if (name.size() > 8 && Equal(name.substr(0, 8), L"\\\\?\\UNC\\"))
    path = L"\\\\" + name.substr(8);
  else if (name.size() > 4 && name.compare(0, 4, L"\\\\?\\") == 0)
    path = name.substr(4);
  else
    return false;
  std::wstring checked;
  if (!Absolute(path, checked))
    return false;
  path = std::move(checked);
  return true;
}

inline bool Inside(const std::wstring &root, const std::wstring &path) {
  return path.size() > root.size() && path[root.size()] == L'\\' &&
         Equal(root, path.substr(0, root.size()));
}

inline bool Validate(HANDLE handle, const std::wstring &expected,
                     bool directory) {
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(handle, &info) ||
      (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != directory ||
      (!directory && info.nNumberOfLinks != 1))
    return false;
  wchar_t name[32768];
  const DWORD len = GetFinalPathNameByHandleW(handle, name, 32768, 0);
  if (len < 5 || len >= 32768)
    return false;
  std::wstring canonical;
  // Drive-volume handles have a trailing separator; user roots still require
  // a directory below the volume, while retained ancestors may be the volume.
  if (len == 7 && std::wstring(name, 4) == L"\\\\?\\" && name[5] == L':' &&
      name[6] == L'\\')
    canonical.assign(name + 4, 3);
  else if (!HandleName(std::wstring(name, len), canonical))
    return false;
  return Equal(expected, canonical);
}

// Sharing of retained DIRECTORY handles. Neither mode shares DELETE: without
// it nobody can rename, move or delete a retained component, which is what
// keeps an authorized path pointing at the directory that was validated.
//  - kSessionDirectoryShare: handles kept for the whole session (granted
//    roots, their ancestors, pinned binaries, watchers, Save As targets). They
//    also share WRITE so that other processes can keep renaming/creating
//    entries inside the retained directories (atomic saves, `git config`,
//    Explorer). Entries are never trusted by name: Validate rejects reparse
//    points and hardlinks on every open.
//  - kMutationDirectoryShare: READ only, for the short window of one
//    mutation/read/Git run, where nobody may add or change entries.
inline constexpr DWORD kSessionDirectoryShare =
    FILE_SHARE_READ | FILE_SHARE_WRITE;
inline constexpr DWORD kMutationDirectoryShare = FILE_SHARE_READ;

inline bool LockParents(const std::wstring &input, LockedPath &locked,
                        bool includeLeaf,
                        DWORD share = kSessionDirectoryShare) {
  const bool dbg = GetEnvironmentVariableW(L"DA_LSP_DEBUG", nullptr, 0) > 0;
  if (!Absolute(input, locked.path)) {
    if (dbg)
      std::fwprintf(stderr, L"[lockparents] Absolute rechaza: %s\n",
                    input.c_str());
    return false;
  }
  const size_t prefix = VolumePrefixLength(locked.path);
  const size_t leafSeparator = locked.path.find_last_of(L'\\');
  // A UNC share itself is a root, never a Save As filename.
  if (!includeLeaf && locked.path.size() <= prefix)
    return false;
  const size_t last =
      includeLeaf ? locked.path.size() : std::max(prefix, leafSeparator);
  size_t end = prefix;
  while (true) {
    const std::wstring current = locked.path.substr(0, end);
    const std::wstring extended = Extended(current);
    HANDLE h = CreateFileW(
        // FILE_LIST_DIRECTORY participates in share-access checks;
        // metadata-only handles do not pin a directory against MoveFile on
        // Windows.
        extended.c_str(), FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, share,
        nullptr, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
      if (dbg)
        std::fwprintf(stderr, L"[lockparents] CreateFileW falla %s err=%lu\n",
                      current.c_str(), GetLastError());
      return false;
    }
    locked.handles.push_back(h);
    if (!Validate(h, current, true)) {
      if (dbg)
        std::fwprintf(stderr, L"[lockparents] Validate falla %s\n",
                      current.c_str());
      return false;
    }
    if (end == last)
      return true;
    const size_t start = locked.path[end] == L'\\' ? end + 1 : end;
    end = locked.path.find(L'\\', start);
    if (end == std::wstring::npos || end > last)
      end = last;
  }
}

// Git uses path-based IO: pin every directory for the entire operation and
// reject reparse points/hardlinks before giving it the granted tree.
// `tooLarge` (opcional) dice si el rechazo fue por superar el
// tope de entradas y no por una ruta insegura; el llamador puede decirlo y no
// repetir un recorrido de 100 000 entradas en cada sondeo.
inline bool LockTree(const std::wstring &root, LockedPath &locked,
                     bool *tooLarge = nullptr) {
  if (tooLarge)
    *tooLarge = false;
  if (!LockParents(root, locked, true, kMutationDirectoryShare))
    return false;
  struct Entry {
    std::wstring path;
    unsigned depth;
    bool gitMetadata;
  };
  std::vector<Entry> pending{{locked.path, 0, false}};
  size_t count = 0;
  while (!pending.empty()) {
    const Entry current = std::move(pending.back());
    pending.pop_back();
    if (current.depth > 64)
      return false;
    WIN32_FIND_DATAW data{};
    const HANDLE find =
        FindFirstFileW(Extended(current.path + L"\\*").c_str(), &data);
    if (find == INVALID_HANDLE_VALUE)
      return false;
    bool ok = true;
    do {
      if (wcscmp(data.cFileName, L".") == 0 ||
          wcscmp(data.cFileName, L"..") == 0)
        continue;
      if (++count > 100000) {
        if (tooLarge)
          *tooLarge = true;
        ok = false;
        break;
      }
      if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        ok = false;
        break;
      }
      const auto path = current.path + L"\\" + data.cFileName;
      const bool directory =
          (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
      const bool gitMetadata =
          current.gitMetadata || Equal(data.cFileName, L".git");
      // Git opens its metadata directories for index updates. Allow that
      // write sharing, keep no-share-delete, and retain strict read-only
      // sharing on every worktree directory.
      HANDLE h = CreateFileW(
          Extended(path).c_str(),
          FILE_READ_ATTRIBUTES | (directory ? FILE_LIST_DIRECTORY : 0),
          directory && !gitMetadata ? FILE_SHARE_READ
                                    : FILE_SHARE_READ | FILE_SHARE_WRITE,
          nullptr, OPEN_EXISTING,
          FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
      if (h == INVALID_HANDLE_VALUE) {
        ok = false;
        break;
      }
      if (!Validate(h, path, directory)) {
        CloseHandle(h);
        ok = false;
        break;
      }
      if (directory) {
        locked.handles.push_back(h);
        pending.push_back({path, current.depth + 1, gitMetadata});
      } else {
        CloseHandle(h); // Git must be able to replace its own index/lock files.
      }
    } while (FindNextFileW(find, &data));
    const DWORD error = GetLastError();
    FindClose(find);
    if (!ok || error != ERROR_NO_MORE_FILES)
      return false;
  }
  return true;
}

inline HANDLE OpenForWrite(const LockedPath &locked, bool createNew = false) {
  const std::wstring extended = Extended(locked.path);
  // OPEN_ALWAYS never truncates before identity/reparse/hardlink checks.
  HANDLE h = CreateFileW(extended.c_str(), GENERIC_WRITE | FILE_READ_ATTRIBUTES,
                         0, nullptr, createNew ? CREATE_NEW : OPEN_ALWAYS,
                         FILE_FLAG_OPEN_REPARSE_POINT | FILE_ATTRIBUTE_NORMAL,
                         nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return h;
  if (!Validate(h, locked.path, false)) {
    CloseHandle(h);
    return INVALID_HANDLE_VALUE;
  }
  return h;
}

inline HANDLE OpenForRead(const LockedPath &locked) {
  HANDLE h = CreateFileW(Extended(locked.path).c_str(), GENERIC_READ,
                         FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                         FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (h != INVALID_HANDLE_VALUE && !Validate(h, locked.path, false)) {
    CloseHandle(h);
    return INVALID_HANDLE_VALUE;
  }
  return h;
}

inline bool WriteComplete(HANDLE h, const std::string &content) {
  size_t offset = 0;
  while (offset < content.size()) {
    const DWORD chunk = static_cast<DWORD>(
        std::min<size_t>(content.size() - offset, 1024 * 1024));
    DWORD written = 0;
    if (!WriteFile(h, content.data() + offset, chunk, &written, nullptr) ||
        !written || written > chunk)
      return false;
    offset += written;
  }
  return SetEndOfFile(h) && FlushFileBuffers(h);
}

// Name of the sibling file used by AtomicWrite. It is not derived from the
// destination (any leaf length fits) and the file watcher hides it.
inline constexpr wchar_t kSaveTemporaryPrefix[] = L".devagents-save-";
inline constexpr wchar_t kSaveTemporarySuffix[] = L".tmp";

inline bool IsSaveTemporaryName(const std::wstring &leaf) {
  const size_t prefix = (sizeof(kSaveTemporaryPrefix) / sizeof(wchar_t)) - 1;
  const size_t suffix = (sizeof(kSaveTemporarySuffix) / sizeof(wchar_t)) - 1;
  return leaf.size() > prefix + suffix &&
         Equal(leaf.substr(0, prefix), kSaveTemporaryPrefix) &&
         Equal(leaf.substr(leaf.size() - suffix), kSaveTemporarySuffix);
}

inline bool IsSaveTemporaryPath(const std::wstring &path) {
  size_t start = 0;
  while (start < path.size()) {
    const size_t end = path.find_first_of(L"\\/", start);
    if (IsSaveTemporaryName(path.substr(start, end - start)))
      return true;
    if (end == std::wstring::npos)
      break;
    start = end + 1;
  }
  return false;
}

// Renames the object behind `h` (opened with DELETE access) over `target`
// with POSIX semantics (FileRenameInfoEx, Windows 10 1809+): the name is
// replaced even while other handles that share DELETE keep reading the old
// file, which the classic MoveFileExW refuses (ERROR_ACCESS_DENIED). Acting on
// the handle means the file that is moved is the one that was written and
// validated, never whatever the temporary name points to by then.
inline DWORD RenameOverByHandle(HANDLE h, const std::wstring &target) {
  struct RenameInfoEx { // FILE_RENAME_INFO with the Flags member of 1809+.
    DWORD Flags;
    HANDLE RootDirectory;
    DWORD FileNameLength;
    WCHAR FileName[1];
  };
  constexpr DWORD kReplaceIfExists = 0x1, kPosixSemantics = 0x2;
  constexpr int kFileRenameInfoEx = 22;
  const std::wstring name = Extended(target);
  const size_t bytes =
      offsetof(RenameInfoEx, FileName) + (name.size() + 1) * sizeof(WCHAR);
  std::vector<unsigned long long> storage((bytes + 7) / 8, 0);
  auto *info = reinterpret_cast<RenameInfoEx *>(storage.data());
  info->Flags = kReplaceIfExists | kPosixSemantics;
  info->RootDirectory = nullptr;
  info->FileNameLength = static_cast<DWORD>(name.size() * sizeof(WCHAR));
  std::memcpy(info->FileName, name.c_str(), (name.size() + 1) * sizeof(WCHAR));
  return SetFileInformationByHandle(
             h, static_cast<FILE_INFO_BY_HANDLE_CLASS>(kFileRenameInfoEx), info,
             static_cast<DWORD>(bytes))
             ? ERROR_SUCCESS
             : GetLastError();
}

enum class AtomicStatus {
  Ok,
  // The destination exists but is unsafe (reparse point, hardlink, directory,
  // read-only, not openable) or the temporary file could not be created.
  OpenFailed,
  // Writing, flushing or moving the temporary file failed. The destination
  // keeps its previous content and the temporary file is removed.
  WriteFailed,
  // Replacement succeeded, but reopening or validating the new file failed.
  // Callers must not claim the previous destination is still intact.
  ReplacedUnverified,
};

// Thread-local seams for deterministic filesystem failure tests. No bridge or
// environment input can set these; null callbacks use the native operations.
struct AtomicWriteHooks {
  DWORD (*rename)(HANDLE, const std::wstring &) = nullptr;
  void (*afterTemporaryClosed)(const std::wstring &) = nullptr;
  bool (*verify)(HANDLE, const std::wstring &, FILETIME &) = nullptr;
};
inline thread_local AtomicWriteHooks atomicWriteHooks;

// Atomic replacement of `locked.path` (parents retained by `locked`).
//
// 1. The current leaf, if any, is opened WITHOUT following reparse points and
//    must pass Validate (one link, regular file, exact canonical name) and not
//    be read-only: the same rejections the in-place writer had.
// 2. The content goes to a brand-new sibling (CREATE_NEW never opens an
//    existing name or follows a link), validated through its handle, written,
//    flushed and kept open until the rename.
// 3. The still-open handle of that sibling is renamed over the destination in
//    a single NTFS operation (RenameOverByHandle). If the filesystem cannot
//    rename by handle, saving fails closed; there is no path-based fallback:
//    readers see the old or the new content, never a truncated one, and a
//    pre-replacement failure leaves the previous file intact. Content and
//    metadata were flushed (FlushFileBuffers) before the rename, which NTFS
//    journals.
//
// The rename acts on the NAME, never writes through the old object. If the
// leaf was swapped for a hardlink or reparse point after step 1, the swap only
// unlinks that name: the hardlink victim or link target is not modified.
// Consequences, by design: the new file takes the directory's inherited ACL
// (hidden/system/archive attributes are carried over), and a hardlink that an
// in-place writer would have written through is severed instead.
inline AtomicStatus AtomicWrite(const LockedPath &locked,
                                const std::string &content,
                                FILETIME &modified) {
  const size_t separator = locked.path.find_last_of(L'\\');
  if (separator == std::wstring::npos || separator + 1 >= locked.path.size())
    return AtomicStatus::OpenFailed;
  const std::wstring directory = locked.path.substr(0, separator);
  const DWORD preserved = FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM |
                          FILE_ATTRIBUTE_ARCHIVE |
                          FILE_ATTRIBUTE_NOT_CONTENT_INDEXED;
  DWORD attributes = 0;
  HANDLE existing = CreateFileW(
      Extended(locked.path).c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (existing != INVALID_HANDLE_VALUE) {
    BY_HANDLE_FILE_INFORMATION info{};
    const bool usable = Validate(existing, locked.path, false) &&
                        GetFileInformationByHandle(existing, &info) &&
                        !(info.dwFileAttributes & FILE_ATTRIBUTE_READONLY);
    CloseHandle(existing);
    if (!usable)
      return AtomicStatus::OpenFailed;
    attributes = info.dwFileAttributes & preserved;
  } else if (GetLastError() != ERROR_FILE_NOT_FOUND) {
    return AtomicStatus::OpenFailed;
  }

  static volatile LONG counter = 0;
  std::wstring temporary;
  HANDLE h = INVALID_HANDLE_VALUE;
  for (int attempt = 0; attempt < 16 && h == INVALID_HANDLE_VALUE; ++attempt) {
    wchar_t unique[64];
    LARGE_INTEGER tick{};
    QueryPerformanceCounter(&tick);
    swprintf(unique, 64, L"%08lx%08lx%08lx%08lx",
             static_cast<unsigned long>(GetCurrentProcessId()),
             static_cast<unsigned long>(InterlockedIncrement(&counter)),
             static_cast<unsigned long>(tick.HighPart),
             static_cast<unsigned long>(tick.LowPart));
    temporary = directory + L"\\" + kSaveTemporaryPrefix + unique +
                kSaveTemporarySuffix;
    h = CreateFileW(Extended(temporary).c_str(),
                    GENERIC_WRITE | FILE_READ_ATTRIBUTES | DELETE, 0, nullptr,
                    CREATE_NEW,
                    FILE_FLAG_OPEN_REPARSE_POINT |
                        (attributes ? attributes : FILE_ATTRIBUTE_NORMAL),
                    nullptr);
    if (h == INVALID_HANDLE_VALUE && GetLastError() != ERROR_FILE_EXISTS &&
        GetLastError() != ERROR_ALREADY_EXISTS)
      return AtomicStatus::OpenFailed;
  }
  if (h == INVALID_HANDLE_VALUE)
    return AtomicStatus::OpenFailed;
  if (!Validate(h, temporary, false)) {
    CloseHandle(h);
    DeleteFileW(Extended(temporary).c_str());
    return AtomicStatus::OpenFailed;
  }
  const bool written = WriteComplete(h, content);
  bool ok = false;
  for (int attempt = 0; written && attempt < 5; ++attempt) {
    const DWORD error = atomicWriteHooks.rename
                            ? atomicWriteHooks.rename(h, locked.path)
                            : RenameOverByHandle(h, locked.path);
    ok = error == ERROR_SUCCESS;
    if (ok || (error != ERROR_SHARING_VIOLATION &&
               error != ERROR_LOCK_VIOLATION && error != ERROR_ACCESS_DENIED))
      break;
    if (attempt < 4)
      Sleep(20); // Indexers/antivirus may still hold the destination.
  }
  CloseHandle(h);
  if (atomicWriteHooks.afterTemporaryClosed)
    atomicWriteHooks.afterTemporaryClosed(temporary);
  if (!ok) {
    DeleteFileW(Extended(temporary).c_str());
    return AtomicStatus::WriteFailed;
  }
  // The replaced name must now be a regular single-link file; its timestamp
  // is what conflict detection compares against.
  HANDLE result = CreateFileW(
      Extended(locked.path).c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (result == INVALID_HANDLE_VALUE)
    return AtomicStatus::ReplacedUnverified;
  const bool verified =
      atomicWriteHooks.verify
          ? atomicWriteHooks.verify(result, locked.path, modified)
          : Validate(result, locked.path, false) &&
                GetFileTime(result, nullptr, nullptr, &modified);
  CloseHandle(result);
  return verified ? AtomicStatus::Ok : AtomicStatus::ReplacedUnverified;
}

// NT supports directory creation relative to the retained parent handle.
// FILE_CREATE is atomic and never opens/replaces an existing directory.
inline HANDLE CreateDirectory(const LockedPath &parent,
                              const std::wstring &name) {
  if (parent.handles.empty() || name.empty() || name.size() > 255)
    return INVALID_HANDLE_VALUE;
  using Create = NTSTATUS(NTAPI *)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES,
                                   PIO_STATUS_BLOCK, PLARGE_INTEGER, ULONG,
                                   ULONG, ULONG, ULONG, PVOID, ULONG);
  const auto create = reinterpret_cast<Create>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtCreateFile"));
  if (!create)
    return INVALID_HANDLE_VALUE;
  UNICODE_STRING leaf{};
  leaf.Buffer = const_cast<wchar_t *>(name.data());
  leaf.Length = static_cast<USHORT>(name.size() * sizeof(wchar_t));
  leaf.MaximumLength = leaf.Length;
  OBJECT_ATTRIBUTES attributes{};
  attributes.Length = sizeof(attributes);
  attributes.RootDirectory = parent.handles.back();
  attributes.ObjectName = &leaf;
  attributes.Attributes = 0x40; // OBJ_CASE_INSENSITIVE
  IO_STATUS_BLOCK io{};
  HANDLE h = INVALID_HANDLE_VALUE;
  const NTSTATUS result = create(
      &h, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE, &attributes,
      &io, nullptr, FILE_ATTRIBUTE_DIRECTORY, FILE_SHARE_READ,
      2,                     // FILE_CREATE
      0x1 | 0x20 | 0x200000, // DIRECTORY | SYNCHRONOUS | OPEN_REPARSE_POINT
      nullptr, 0);
  if (result < 0)
    return INVALID_HANDLE_VALUE;
  if (!Validate(h, parent.path + L"\\" + name, true)) {
    CloseHandle(h);
    return INVALID_HANDLE_VALUE;
  }
  return h;
}
} // namespace confined
} // namespace beats
#endif
