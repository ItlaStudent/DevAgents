#ifndef DA_PRIVATE_DATA_SECURITY_H
#define DA_PRIVATE_DATA_SECURITY_H
#include <aclapi.h>
#include <stdio.h>
#include <wchar.h>
#include <windows.h>
/* Default workspaces must not inherit a writable-by-others parent DACL.
 *
 * Build a protected, inheritable user-only ACL before CreateDirectoryW. */
typedef struct {
  TOKEN_USER *user;
  PACL acl;
  SECURITY_DESCRIPTOR descriptor;
} PrivateDirectoryDescriptor;

static inline void
private_directory_descriptor_free(PrivateDirectoryDescriptor *value) {
  if (value->acl)
    LocalFree(value->acl);
  if (value->user)
    LocalFree(value->user);
}

/* Creation and explicit workspace repair must use this same constructor. */
static inline DWORD
private_directory_descriptor(PrivateDirectoryDescriptor *value) {
  HANDLE token = NULL;
  DWORD size = 0;
  DWORD result = ERROR_INVALID_SECURITY_DESCR;
  EXPLICIT_ACCESSW access = {0};
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    result = GetLastError();
    goto done;
  }
  GetTokenInformation(token, TokenUser, NULL, 0, &size);
  if (!size) {
    result = GetLastError();
    goto done;
  }
  value->user = (TOKEN_USER *)LocalAlloc(LPTR, size);
  if (!value->user) {
    result = ERROR_NOT_ENOUGH_MEMORY;
    goto done;
  }
  if (!GetTokenInformation(token, TokenUser, value->user, size, &size)) {
    result = GetLastError();
    goto done;
  }
  access.grfAccessPermissions = FILE_ALL_ACCESS;
  access.grfAccessMode = SET_ACCESS;
  access.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
  access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
  access.Trustee.TrusteeType = TRUSTEE_IS_USER;
  access.Trustee.ptstrName = (LPWSTR)value->user->User.Sid;
  result = SetEntriesInAclW(1, &access, NULL, &value->acl);
  if (result != ERROR_SUCCESS)
    goto done;
  if (!InitializeSecurityDescriptor(&value->descriptor,
                                    SECURITY_DESCRIPTOR_REVISION) ||
      !SetSecurityDescriptorOwner(&value->descriptor, value->user->User.Sid,
                                  FALSE) ||
      !SetSecurityDescriptorDacl(&value->descriptor, TRUE, value->acl, FALSE) ||
      !SetSecurityDescriptorControl(&value->descriptor, SE_DACL_PROTECTED,
                                    SE_DACL_PROTECTED)) {
    result = GetLastError();
    goto done;
  }
  result = ERROR_SUCCESS;
done:
  if (token)
    CloseHandle(token);
  return result;
}

/* Use the retained object, never propagate through data-directory links.
 * SetSecurityInfo may synthesize inheritance or walk children; the native file
 * setter applies exactly the protected descriptor, as workspace restore does.
 */
static inline DWORD
private_data_set_descriptor(HANDLE handle, PSECURITY_DESCRIPTOR descriptor) {
  typedef LONG(NTAPI * SetSecurityFn)(HANDLE, SECURITY_INFORMATION,
                                      PSECURITY_DESCRIPTOR);
  typedef ULONG(NTAPI * StatusErrorFn)(LONG);
  HMODULE module = GetModuleHandleW(L"ntdll.dll");
  if (!module)
    return GetLastError();
  SetSecurityFn setter =
      (SetSecurityFn)GetProcAddress(module, "NtSetSecurityObject");
  StatusErrorFn convert =
      (StatusErrorFn)GetProcAddress(module, "RtlNtStatusToDosError");
  if (!setter || !convert)
    return ERROR_PROC_NOT_FOUND;
  LONG status = setter(
      handle, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
      descriptor);
  return status < 0 ? convert(status) : ERROR_SUCCESS;
}

static inline DWORD private_data_protect(const WCHAR *path,
                                         PSECURITY_DESCRIPTOR descriptor,
                                         BOOL directory) {
  HANDLE handle = CreateFileW(
      path, READ_CONTROL | WRITE_DAC | FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (handle == INVALID_HANDLE_VALUE)
    return GetLastError();
  BY_HANDLE_FILE_INFORMATION info;
  DWORD result = ERROR_SUCCESS;
  if (!GetFileInformationByHandle(handle, &info))
    result = GetLastError();
  else if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
           !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) !=
               !!directory ||
           (!directory && info.nNumberOfLinks != 1))
    result = ERROR_ACCESS_DENIED;
  else
    result = private_data_set_descriptor(handle, descriptor);
  CloseHandle(handle);
  return result;
}

static inline DWORD private_data_directory(const WCHAR *path) {
  PrivateDirectoryDescriptor value = {0};
  DWORD result = private_directory_descriptor(&value);
  if (result == ERROR_SUCCESS) {
    SECURITY_ATTRIBUTES attributes = {sizeof(attributes), &value.descriptor,
                                      FALSE};
    if (!CreateDirectoryW(path, &attributes)) {
      result = GetLastError();
      if (result == ERROR_ALREADY_EXISTS)
        result = private_data_protect(path, &value.descriptor, TRUE);
    }
  }
  /* Existing sensitive siblings may carry explicit grants, so fix each known
   * file as well. Keys are DPAPI ciphertext in catalog.db, never read here. */
  const WCHAR *files[] = {L"mcp_token",      L"catalog.db", L"catalog.db-wal",
                          L"catalog.db-shm", L"runtime.db", L"runtime.db-wal",
                          L"runtime.db-shm", L"ledger.db",  L"ledger.db-wal",
                          L"ledger.db-shm"};
  for (size_t i = 0; result == ERROR_SUCCESS && i < ARRAYSIZE(files); ++i) {
    WCHAR child[32768];
    if (swprintf_s(child, ARRAYSIZE(child), L"%ls\\%ls", path, files[i]) < 0) {
      result = ERROR_FILENAME_EXCED_RANGE;
      break;
    }
    result = private_data_protect(child, &value.descriptor, FALSE);
    if (result == ERROR_FILE_NOT_FOUND)
      result = ERROR_SUCCESS;
  }
  private_directory_descriptor_free(&value);
  if (result != ERROR_SUCCESS)
    fprintf(stderr, "devagents: private data directory Win32=%lu\n",
            (unsigned long)result);
  SetLastError(result);
  return result;
}
#endif
