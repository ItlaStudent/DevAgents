/* Instance classification shared by SEC5 enumeration and its read-only control.
 */
#ifndef SEC5_IDENTITY_H
#define SEC5_IDENTITY_H
#include <stdint.h>
#include <stdlib.h>
#include <windows.h>
#include <winternl.h>

typedef struct sec5_process_entry {
  DWORD pid, parent;
  FILETIME birth;
} sec5_process_entry;
typedef struct sec5_process_table {
  sec5_process_entry *entries;
  unsigned count;
} sec5_process_table;
static inline FILETIME sec5_filetime(ULONGLONG value) {
  FILETIME result = {(DWORD)value, (DWORD)(value >> 32)};
  return result;
}
static inline BOOL sec5_birth_known(FILETIME birth) {
  return birth.dwLowDateTime || birth.dwHighDateTime;
}
static inline BOOL sec5_same_instance(DWORD pid, FILETIME birth,
                                      DWORD expected_pid, FILETIME expected) {
  return pid == expected_pid && sec5_birth_known(birth) &&
         sec5_birth_known(expected) && CompareFileTime(&birth, &expected) == 0;
}
/* -1: cannot attribute safely; 0: not a descendant; 1: temporal attribution.
   A retained exited parent also bounds the latest possible child creation. */
static inline int sec5_descendant_classify(DWORD observed_parent,
                                           FILETIME child_birth, DWORD parent,
                                           FILETIME parent_birth,
                                           FILETIME parent_exit,
                                           BOOL parent_identity) {
  if (observed_parent != parent)
    return 0;
  if (!sec5_birth_known(child_birth) || !sec5_birth_known(parent_birth))
    return -1;
  if (CompareFileTime(&child_birth, &parent_birth) < 0 ||
      (sec5_birth_known(parent_exit) &&
       CompareFileTime(&child_birth, &parent_exit) > 0))
    return 0;
  return parent_identity ? 1 : -1;
}
/* SystemProcessInformation carries creation times even for inaccessible
   processes (e.g. csrss). Never open candidates merely to discard old PIDs. */
static inline BOOL sec5_process_snapshot(sec5_process_table *table) {
  table->entries = NULL;
  table->count = 0;
  ULONG capacity = 65536;
  for (;;) {
    BYTE *buffer = malloc(capacity);
    if (!buffer) {
      SetLastError(ERROR_NOT_ENOUGH_MEMORY);
      return FALSE;
    }
    ULONG length = 0;
    NTSTATUS status = NtQuerySystemInformation(SystemProcessInformation, buffer,
                                               capacity, &length);
    if (status == (NTSTATUS)0xc0000004L) {
      free(buffer);
      if (capacity >= 16 * 1024 * 1024 || length > 16 * 1024 * 1024) {
        SetLastError(ERROR_INSUFFICIENT_BUFFER);
        return FALSE;
      }
      capacity = length > capacity * 2 ? length : capacity * 2;
      continue;
    }
    if (status < 0 || length > capacity ||
        length < sizeof(SYSTEM_PROCESS_INFORMATION)) {
      free(buffer);
      SetLastError(status < 0 ? RtlNtStatusToDosError(status)
                              : ERROR_BAD_LENGTH);
      return FALSE;
    }
    unsigned maximum = length / sizeof(SYSTEM_PROCESS_INFORMATION);
    table->entries = calloc(maximum, sizeof(*table->entries));
    if (!table->entries) {
      free(buffer);
      SetLastError(ERROR_NOT_ENOUGH_MEMORY);
      return FALSE;
    }
    ULONG offset = 0;
    BOOL good = TRUE;
    for (;;) {
      if (offset > length - sizeof(SYSTEM_PROCESS_INFORMATION) ||
          table->count == maximum) {
        good = FALSE;
        break;
      }
      const SYSTEM_PROCESS_INFORMATION *info = (const void *)(buffer + offset);
      if ((uintptr_t)info->UniqueProcessId > MAXDWORD ||
          (uintptr_t)info->InheritedFromUniqueProcessId > MAXDWORD) {
        good = FALSE;
        break;
      }
      sec5_process_entry *entry = &table->entries[table->count++];
      entry->pid = (DWORD)(uintptr_t)info->UniqueProcessId;
      entry->parent = (DWORD)(uintptr_t)info->InheritedFromUniqueProcessId;
      entry->birth = sec5_filetime((ULONGLONG)info->CreateTime.QuadPart);
      if (!info->NextEntryOffset)
        break;
      if (info->NextEntryOffset < sizeof(*info) ||
          info->NextEntryOffset > length - offset ||
          info->NextEntryOffset % sizeof(void *)) {
        good = FALSE;
        break;
      }
      offset += info->NextEntryOffset;
    }
    free(buffer);
    if (!good) {
      free(table->entries);
      table->entries = NULL;
      table->count = 0;
      SetLastError(ERROR_BAD_LENGTH);
    }
    return good;
  }
}
#endif
