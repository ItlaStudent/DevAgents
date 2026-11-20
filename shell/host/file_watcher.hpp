#ifndef BEATS_FILE_WATCHER_HPP
#define BEATS_FILE_WATCHER_HPP

#include "confined_write.hpp"
#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <windows.h>

namespace beats {

enum class FileChangeType { Created, Modified, Deleted, Renamed };

using FileChangeCallback =
    std::function<void(const std::wstring &path, FileChangeType type)>;

class FileWatcher {
public:
  FileWatcher();
  ~FileWatcher();

  bool StartWatching(const std::wstring &dirPath, FileChangeCallback callback);
  void StopWatching();

private:
  void WatchThreadFunc();

  std::wstring m_watchedDir;
  FileChangeCallback m_callback;
  HANDLE m_hDir = INVALID_HANDLE_VALUE;
  std::unique_ptr<confined::LockedPath> m_lockedPath;
  std::thread m_thread;
  std::atomic<bool> m_running{false};
};

} // namespace beats

#endif // BEATS_FILE_WATCHER_HPP
