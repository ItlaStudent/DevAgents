#include "file_watcher.hpp"
#include "confined_write.hpp"
#include <iostream>

namespace beats {

FileWatcher::FileWatcher() {}

FileWatcher::~FileWatcher() { StopWatching(); }

bool FileWatcher::StartWatching(const std::wstring &dirPath,
                                FileChangeCallback callback) {
  StopWatching();

  auto locked = std::make_unique<confined::LockedPath>();
  if (!confined::LockParents(dirPath, *locked, true))
    return false;

  m_watchedDir = dirPath;
  m_callback = callback;

  m_hDir = CreateFileW(m_watchedDir.c_str(), FILE_LIST_DIRECTORY,
                       confined::kSessionDirectoryShare, nullptr, OPEN_EXISTING,
                       FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED |
                           FILE_FLAG_OPEN_REPARSE_POINT,
                       nullptr);

  if (m_hDir == INVALID_HANDLE_VALUE) {
    return false;
  }
  if (!confined::Validate(m_hDir, locked->path, true)) {
    CloseHandle(m_hDir);
    m_hDir = INVALID_HANDLE_VALUE;
    return false;
  }
  m_lockedPath = std::move(locked);

  m_running = true;
  m_thread = std::thread(&FileWatcher::WatchThreadFunc, this);
  return true;
}

void FileWatcher::StopWatching() {
  m_running = false;
  if (m_hDir != INVALID_HANDLE_VALUE) {
    CancelIoEx(m_hDir, nullptr);
    CloseHandle(m_hDir);
    m_hDir = INVALID_HANDLE_VALUE;
  }
  if (m_thread.joinable()) {
    m_thread.join();
  }
  m_lockedPath.reset();
}

void FileWatcher::WatchThreadFunc() {
  BYTE buffer[4096];
  DWORD bytesReturned = 0;
  OVERLAPPED overlapped = {};
  overlapped.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);

  while (m_running) {
    ResetEvent(overlapped.hEvent);
    BOOL success = ReadDirectoryChangesW(
        m_hDir, buffer, sizeof(buffer), TRUE,
        FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
            FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE,
        &bytesReturned, &overlapped, nullptr);

    if (!success) {
      break;
    }

    DWORD waitResult = WaitForSingleObject(overlapped.hEvent, 500);
    if (waitResult == WAIT_OBJECT_0) {
      if (GetOverlappedResult(m_hDir, &overlapped, &bytesReturned, FALSE) &&
          bytesReturned > 0) {
        FILE_NOTIFY_INFORMATION *pNotify =
            reinterpret_cast<FILE_NOTIFY_INFORMATION *>(buffer);
        while (pNotify) {
          std::wstring fileName(pNotify->FileName,
                                pNotify->FileNameLength / sizeof(wchar_t));
          std::wstring fullPath = m_watchedDir + L"\\" + fileName;
          // Sibling of an atomic save: never a user-visible change.
          if (confined::IsSaveTemporaryPath(fileName)) {
            if (pNotify->NextEntryOffset == 0)
              break;
            pNotify = reinterpret_cast<FILE_NOTIFY_INFORMATION *>(
                reinterpret_cast<BYTE *>(pNotify) + pNotify->NextEntryOffset);
            continue;
          }

          FileChangeType type = FileChangeType::Modified;
          if (pNotify->Action == FILE_ACTION_ADDED)
            type = FileChangeType::Created;
          else if (pNotify->Action == FILE_ACTION_REMOVED)
            type = FileChangeType::Deleted;
          else if (pNotify->Action == FILE_ACTION_MODIFIED)
            type = FileChangeType::Modified;
          else if (pNotify->Action == FILE_ACTION_RENAMED_OLD_NAME ||
                   pNotify->Action == FILE_ACTION_RENAMED_NEW_NAME)
            type = FileChangeType::Renamed;

          if (m_callback) {
            m_callback(fullPath, type);
          }

          if (pNotify->NextEntryOffset == 0)
            break;
          pNotify = reinterpret_cast<FILE_NOTIFY_INFORMATION *>(
              reinterpret_cast<BYTE *>(pNotify) + pNotify->NextEntryOffset);
        }
      }
    }
  }

  CloseHandle(overlapped.hEvent);
}

} // namespace beats
