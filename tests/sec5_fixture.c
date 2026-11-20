/* Windows-only P1 adversarial fixtures. No product launch sites are changed. */
#include "sec5_fixture.h"
#include "sec5_identity.h"
#include "sec5_ipv4.h"
#include <bcrypt.h>
#include <shellapi.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tlhelp32.h>
#include <wchar.h>
#include <winsock2.h>
#include <winternl.h>
#include <ws2tcpip.h>

#define CAP 4096
#define WAIT_MS 10000
#define SD_INFO                                                                \
  (OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |                   \
   DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION)
#define MAGIC 0x53454335u
enum operation {
  OP_WRITE,
  OP_READ,
  OP_REG,
  OP_VM,
  OP_TERMINATE,
  OP_EVENT,
  OP_MUTEX,
  OP_PIPE,
  OP_STDIO,
  OP_BREAKAWAY,
  OP_TREE,
  OP_HANDLES,
  OP_EARLY,
  OP_DEFAULT,
  OP_WINSTA,
  OP_INHERIT,
  OP_WIDEN,
  OP_QUERY,
  OP_EVENT_FULL,
  OP_RUNTIME_WRITE,
  OP_PRIVATE_REG,
  OP_REG_READ,
  OP_NETWORK,
  OP_RUNTIME_EXEC
};
typedef struct packet {
  DWORD magic, pid, operation, attempted, error, secondary_error, opened;
  BYTE nonce[16];
  BYTE read_bytes[16];
  DWORD descendant;
  FILETIME descendant_time;
  uintptr_t address, handle, second_handle;
} packet;
typedef struct snapshot {
  HANDLE handle;
  SE_OBJECT_TYPE type;
  PSECURITY_DESCRIPTOR sd;
  DWORD length;
  FILE_ID_INFO identity;
  BOOL file;
} snapshot;
typedef struct process_identity {
  DWORD pid;
  FILETIME birth;
  BOOL known;
} process_identity;
typedef struct console_pin {
  HANDLE process;
  DWORD pid, parent;
  FILETIME birth, parent_birth;
  struct console_pin *next;
} console_pin;
typedef struct run {
  struct suite *owner;
  sec5_result process;
  HANDLE in_write, out_read, err_read;
  HANDLE witness, excluded;
  HANDLE outer_job, before;
  process_identity *before_ids;
  unsigned before_count;
  console_pin *console_pins;
  BYTE nonce[16];
  packet reply;
  BOOL ordinary, complete, exact_stdio, output_exact;
} run;
typedef struct suite {
  WCHAR child[CAP], original_child[CAP], root[CAP], dest[CAP], medium[CAP],
      foreign[CAP], read_file[CAP];
  WCHAR sid_text[256], user_text[256], guid[128], reg_path[512];
  PSID lease, user;
  enum sec5_backend backend;
  WCHAR profile[64];
  LPWSTR profile_path;
  BOOL profile_created, quiet_tokens;
  BOOL reported[39];
  BOOL runtime_matrix, private_environment;
  PSID runtime_capability, active_capability;
  WCHAR private_local[CAP], private_temp[CAP], shared_runtime[2][CAP];
  unsigned unverified;
  enum sec5_stage failure_stage;
  PSECURITY_DESCRIPTOR default_sd;
  PACL default_dacl;
  snapshot root_sd, dest_sd, medium_sd, foreign_sd;
  HKEY key;
  HANDLE child_pin;
  enum sec5_mutation mutation;
  unsigned passed, failed, observed, skipped;
  BOOL blocked, token_ok, labels_restored, root_created, key_created,
      unsafe_cleanup, allow_missing_runtimes, isolated_cleanup_failed;
  BYTE read_nonce[16];
} suite;

static const char *const names[] = {
    "SEC5 ENV parent representative",
    "SEC5 TOKEN effective child",
    "SEC5 MIC medium write denied",
    "SEC5 SID foreign low write denied",
    "SEC5 DEST prepared write allowed",
    "SEC5 READ ordinary readable outside",
    "SEC5 REG HKCU write denied",
    "SEC5 PROCESS VM_WRITE denied",
    "SEC5 PROCESS TERMINATE user process observed",
    "SEC5 SESSION event observed",
    "SEC5 SESSION mutex observed",
    "SEC5 SESSION named pipe observed",
    "SEC5 SESSION authorized objects allowed",
    "SEC5 SESSION child named object cross-lease observed",
    "SEC5 SESSION WinSta0 access observed",
    "SEC5 STDIO anonymous allowed",
    "SEC5 JOB breakaway denied",
    "SEC5 JOB normal grandchild contained",
    "SEC5 JOB nested contained",
    "SEC5 JOB broker close kills tree",
    "SEC5 HANDLE excluded not inherited",
    "SEC5 FAIL before resume no child",
    "SEC5 LABEL standard user roundtrip",
    "SEC5 LABEL missing WRITE_OWNER blocks",
    "SEC5 LABEL inheritance measured",
    "SEC5 SECURITY child cannot widen",
    "SEC5 NODE inline compatible",
    "SEC5 PYTHON inline compatible",
    "SEC5 HANDLE zero handles launch",
    "SEC5 APPCONTAINER process query limited denied",
    "SEC5 APPCONTAINER exterior write denied",
    "SEC5 APPCONTAINER runtime capability allowed",
    "SEC5 APPCONTAINER runtime without capability denied",
    "SEC5 APPCONTAINER runtime immutable",
    "SEC5 APPCONTAINER runtime grant reversible",
    "SEC5 APPCONTAINER other order separate",
    "SEC5 APPCONTAINER private registry allowed",
    "SEC5 APPCONTAINER network without capabilities denied",
    "SEC5 APPCONTAINER system read allowed"};

static BOOL hash_file(HANDLE file, const char *name);
static void child_network(packet *, const WCHAR *, unsigned);
static void child_private_registry(packet *, const WCHAR *, BOOL);
static void child_runtime_exec(packet *, const WCHAR *, BOOL);
static BOOL runtime_prepare_temp(suite *);
static BOOL runtime_other_order(suite *, suite *, run *, run *);
static int cycle_child(int, WCHAR **);

static void result(suite *s, unsigned id, BOOL good, const char *detail) {
  s->reported[id] = TRUE;
  printf("%s | %s | %s\n", names[id], good ? "PASS" : "FAIL", detail);
  if (good)
    ++s->passed;
  else
    ++s->failed;
  fflush(stdout);
}
static void observation(suite *s, unsigned id, BOOL allowed, DWORD error,
                        const char *detail) {
  s->reported[id] = TRUE;
  /* Access measurements never increment PASS or establish isolation. */
  printf("%s | OBSERVED_%s | win32=%lu mask/effect=%s\n", names[id],
         allowed ? "ALLOWED" : "DENIED", (unsigned long)error, detail);
  ++s->observed;
  fflush(stdout);
}
static BOOL cycle_api_fail(const char *api, const char *parameter, DWORD error);
static BOOL checked_api(BOOL good, const char *api, const char *parameter) {
  return good || cycle_api_fail(api, parameter, GetLastError());
}
static BOOL bounded_text(DWORD length, DWORD capacity, const char *api) {
  return (length && length < capacity) ||
         cycle_api_fail(api, "WCHAR capacity",
                        length ? ERROR_INSUFFICIENT_BUFFER : GetLastError());
}
static void api_error(const char *api, DWORD error) {
  WCHAR message[1024] = L"";
  FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                 NULL, error, 0, message, 1024, NULL);
  printf("API=%s WIN32=%lu HEX=0x%08lx MESSAGE=%ls\n", api,
         (unsigned long)error, (unsigned long)error, message);
  fflush(stdout);
  SetLastError(error);
}
static BOOL fmt(WCHAR *buffer, size_t count, const WCHAR *format, ...) {
  va_list args;
  va_start(args, format);
  int size = _vsnwprintf(buffer, count, format, args);
  va_end(args);
  if (size < 0 || (size_t)size >= count) {
    SetLastError(ERROR_BUFFER_OVERFLOW);
    return FALSE;
  }
  return TRUE;
}
static BOOL random_bytes(void *buffer, ULONG size) {
  return BCryptGenRandom(NULL, buffer, size, BCRYPT_USE_SYSTEM_PREFERRED_RNG) ==
         0;
}
static void close_handle(HANDLE *handle) {
  if (*handle && *handle != INVALID_HANDLE_VALUE) {
    if (!CloseHandle(*handle))
      api_error("CloseHandle", GetLastError());
  }
  *handle = NULL;
}
static void *token_info(HANDLE token, TOKEN_INFORMATION_CLASS cls) {
  DWORD bytes = 0;
  BOOL queried = GetTokenInformation(token, cls, NULL, 0, &bytes);
  DWORD error = GetLastError();
  if (queried || error != ERROR_INSUFFICIENT_BUFFER || !bytes) {
    cycle_api_fail("GetTokenInformation", "size query",
                   queried || (error == ERROR_INSUFFICIENT_BUFFER && !bytes)
                       ? ERROR_INVALID_DATA
                       : error);
    return NULL;
  }
  for (DWORD attempt = 0; attempt < 8 && bytes <= 16 * 1024 * 1024; ++attempt) {
    DWORD capacity = bytes;
    void *memory = calloc(1, capacity);
    if (!memory) {
      cycle_api_fail("calloc", "GetTokenInformation buffer",
                     ERROR_NOT_ENOUGH_MEMORY);
      return NULL;
    }
    if (GetTokenInformation(token, cls, memory, capacity, &bytes)) {
      if (bytes <= capacity) {
        SetLastError(ERROR_SUCCESS);
        return memory;
      }
      error = ERROR_INVALID_DATA;
    } else
      error = GetLastError();
    free(memory);
    if (error != ERROR_INSUFFICIENT_BUFFER || bytes <= capacity) {
      cycle_api_fail("GetTokenInformation", "read buffer", error);
      return NULL;
    }
  }
  cycle_api_fail("GetTokenInformation", "growth limit",
                 ERROR_INSUFFICIENT_BUFFER);
  return NULL;
}
static BOOL token_scalar(HANDLE token, TOKEN_INFORMATION_CLASS cls,
                         DWORD *value) {
  DWORD size = 0;
  return checked_api(
      GetTokenInformation(token, cls, value, sizeof(*value), &size),
      "GetTokenInformation", "DWORD scalar");
}
static BOOL privilege_dump(HANDLE token, BOOL limited, BOOL verbose) {
  TOKEN_PRIVILEGES *privileges = token_info(token, TokenPrivileges);
  LUID traverse;
  if (!privileges ||
      !LookupPrivilegeValueW(NULL, SE_CHANGE_NOTIFY_NAME, &traverse)) {
    free(privileges);
    return FALSE;
  }
  BOOL good = TRUE;
  for (DWORD i = 0; i < privileges->PrivilegeCount; ++i) {
    WCHAR name[256];
    DWORD size = 256;
    if (!LookupPrivilegeNameW(NULL, &privileges->Privileges[i].Luid, name,
                              &size)) {
      good = FALSE;
      if (verbose)
        api_error("LookupPrivilegeNameW", GetLastError());
      continue;
    }
    DWORD flags = privileges->Privileges[i].Attributes;
    if (verbose)
      printf("TOKEN privilege=%ls attributes=0x%08lx\n", name,
             (unsigned long)flags);
    if (limited && (flags & SE_PRIVILEGE_ENABLED) &&
        (privileges->Privileges[i].Luid.LowPart != traverse.LowPart ||
         privileges->Privileges[i].Luid.HighPart != traverse.HighPart))
      good = FALSE;
  }
  free(privileges);
  return good;
}
static BOOL parent_representative(suite *s) {
  HANDLE token = NULL;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    api_error("OpenProcessToken(parent)", GetLastError());
    return FALSE;
  }
  TOKEN_MANDATORY_LABEL *label = token_info(token, TokenIntegrityLevel);
  TOKEN_GROUPS *restricted = token_info(token, TokenRestrictedSids);
  TOKEN_USER *user = token_info(token, TokenUser);
  DWORD elevated = 0, ui = 0, virtualization = 0, session = 0;
  BOOL scalar =
      token_scalar(token, TokenElevation, &elevated) &&
      token_scalar(token, TokenUIAccess, &ui) &&
      token_scalar(token, TokenVirtualizationEnabled, &virtualization) &&
      token_scalar(token, TokenSessionId, &session);
  DWORD il =
      label
          ? *GetSidSubAuthority(label->Label.Sid,
                                *GetSidSubAuthorityCount(label->Label.Sid) - 1)
          : 0;
  BOOL restricted_flag = IsTokenRestricted(token);
  BOOL in_job = FALSE;
  BOOL job_query = IsProcessInJob(GetCurrentProcess(), NULL, &in_job);
  printf("PARENT pid=%lu IL=%lu restricted=%d restricting_sids=%lu "
         "elevated=%lu UIAccess=%lu virtualization=%lu session=%lu in_job=%d\n",
         (unsigned long)GetCurrentProcessId(), (unsigned long)il,
         restricted_flag,
         restricted ? (unsigned long)restricted->GroupCount : 0,
         (unsigned long)elevated, (unsigned long)ui,
         (unsigned long)virtualization, (unsigned long)session, in_job);
  BOOL good = scalar && job_query && label && restricted && user &&
              il == SECURITY_MANDATORY_MEDIUM_RID && !restricted_flag &&
              !restricted->GroupCount && !elevated && !ui;
  if (user) {
    LPWSTR text = NULL;
    if (ConvertSidToStringSidW(user->User.Sid, &text)) {
      good = good && fmt(s->user_text, 256, L"%ls", text);
      LocalFree(text);
    } else
      good = FALSE;
  }
  if (!privilege_dump(token, FALSE, TRUE))
    good = FALSE;
  free(user);
  free(label);
  free(restricted);
  CloseHandle(token);
  if (!good) {
    printf("%s | ENVIRONMENT_NOT_REPRESENTATIVE | entorno no representativo; "
           "no security verdict, counts=null\n",
           names[0]);
    for (unsigned i = 1; i < sizeof(names) / sizeof(names[0]); ++i)
      printf("%s | ENVIRONMENT_NOT_REPRESENTATIVE | no ejecutada\n", names[i]);
    return FALSE;
  }
  result(
      s, 0, TRUE,
      "token propio medio, no restringido ni elevado; no se cambia de usuario");
  return TRUE;
}
static BOOL make_sd(suite *s, BOOL lease, int il, BOOL directory,
                    PSECURITY_DESCRIPTOR *sd) {
  WCHAR text[2048];
  const WCHAR *inherit = directory ? L"OICI" : L"";
  WCHAR extra[512] = L"", label[128] = L"";
  /* Lease grants data/execute, not WRITE_DAC/WRITE_OWNER. OWNER RIGHTS removes
     the owner's implicit WRITE_DAC; explicit ordinary user GA still works. */
  if (lease &&
      !fmt(extra, 512, L"(A;%ls;0x001201ff;;;%ls)", inherit, s->sid_text))
    return FALSE;
  /* Label-only SACL, NOT protected: a protected SACL (S:P) needs
     SeSecurityPrivilege and fails with 1314 for a standard user (measured
     10-oct, sddl_probe). Only LABEL_SECURITY_INFORMATION is snapshotted. */
  if (il >= 0 && !fmt(label, 128, L"S:(ML;%ls;NW;;;%ls)", inherit,
                      il == 0 ? L"LW" : L"ME"))
    return FALSE;
  if (!fmt(text, 2048,
           L"O:%lsG:%lsD:P(A;%ls;GA;;;%ls)(A;%ls;GA;;;SY)(A;%ls;RC;;;OW)%ls%ls",
           s->user_text, s->user_text, inherit, s->user_text, inherit, inherit,
           extra, label))
    return FALSE;
  return ConvertStringSecurityDescriptorToSecurityDescriptorW(
      text, SDDL_REVISION_1, sd, NULL);
}
static BOOL kernel_sd(HANDLE handle, SECURITY_INFORMATION info,
                      PSECURITY_DESCRIPTOR *sd) {
  DWORD size = 0;
  *sd = NULL;
  BOOL queried = GetKernelObjectSecurity(handle, info, NULL, 0, &size);
  DWORD error = GetLastError();
  if (queried || error != ERROR_INSUFFICIENT_BUFFER || !size)
    return cycle_api_fail("GetKernelObjectSecurity", "size query",
                          queried ||
                                  (error == ERROR_INSUFFICIENT_BUFFER && !size)
                              ? ERROR_INVALID_DATA
                              : error);
  for (DWORD attempt = 0; attempt < 8 && size <= 16 * 1024 * 1024; ++attempt) {
    DWORD capacity = size;
    PSECURITY_DESCRIPTOR buffer = LocalAlloc(LMEM_FIXED, capacity);
    if (!buffer)
      return cycle_api_fail("LocalAlloc", "GetKernelObjectSecurity buffer",
                            ERROR_NOT_ENOUGH_MEMORY);
    if (GetKernelObjectSecurity(handle, info, buffer, capacity, &size)) {
      if (size <= capacity && IsValidSecurityDescriptor(buffer) &&
          GetSecurityDescriptorLength(buffer) <= capacity) {
        *sd = buffer;
        SetLastError(ERROR_SUCCESS);
        return TRUE;
      }
      error = ERROR_INVALID_SECURITY_DESCR;
    } else
      error = GetLastError();
    LocalFree(buffer);
    if (error != ERROR_INSUFFICIENT_BUFFER || size <= capacity)
      return cycle_api_fail("GetKernelObjectSecurity", "read buffer", error);
  }
  return cycle_api_fail("GetKernelObjectSecurity", "growth limit",
                        ERROR_INSUFFICIENT_BUFFER);
}
/* DACL por defecto del token aislado: el proceso hijo protege sus propios
   objetos (proceso, hilos, sincronizacion) con ella. Con WRITE_RESTRICTED el
   hijo necesita que la lease y RESTRICTED (S-1-5-12) figuren con acceso
   completo, o falla al iniciar user32 (0xC0000142, medido el 10-oct en
   orq-matriz-aislamiento-20261010.txt). */
static BOOL make_default_sd(suite *s, PSECURITY_DESCRIPTOR *sd) {
  WCHAR text[1024];
  if (s->backend == SEC5_APPCONTAINER) {
    if (!fmt(text, 1024,
             L"D:(A;;GA;;;%ls)(A;;GA;;;SY)(A;;GA;;;%ls)(A;;RC;;;OW)",
             s->user_text, s->sid_text))
      return FALSE;
    return ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text, SDDL_REVISION_1, sd, NULL);
  }
  if (!fmt(text, 1024,
           L"D:(A;;GA;;;%ls)(A;;GA;;;SY)(A;;GA;;;%ls)(A;;GA;;;S-1-5-12)",
           s->user_text, s->sid_text))
    return FALSE;
  return ConvertStringSecurityDescriptorToSecurityDescriptorW(
      text, SDDL_REVISION_1, sd, NULL);
}
static BOOL snapshot_take(snapshot *snap, HANDLE handle, SE_OBJECT_TYPE type,
                          BOOL file) {
  memset(snap, 0, sizeof(*snap));
  snap->handle = handle;
  snap->type = type;
  snap->file = file;
  if (!kernel_sd(handle, SD_INFO, &snap->sd)) {
    return FALSE;
  }
  snap->length = GetSecurityDescriptorLength(snap->sd);
  if (file && !GetFileInformationByHandleEx(handle, FileIdInfo, &snap->identity,
                                            sizeof(snap->identity))) {
    api_error("GetFileInformationByHandleEx", GetLastError());
    LocalFree(snap->sd);
    snap->sd = NULL;
    return FALSE;
  }
  LPWSTR text = NULL;
  if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(
          snap->sd, SDDL_REVISION_1, SD_INFO, &text, NULL))
    return FALSE;
  printf("SNAPSHOT handle=%p length=%lu SDDL=%ls\n", handle,
         (unsigned long)snap->length, text);
  LocalFree(text);
  return TRUE;
}
static BOOL sid_equal(PSID a, PSID b) {
  return (!a || !b) ? a == b : IsValidSid(a) && IsValidSid(b) && EqualSid(a, b);
}
static BOOL dacl_equal(PACL a, PACL b) {
  if (!a || !b)
    return a == b;
  if (!IsValidAcl(a) || !IsValidAcl(b) || a->AclRevision != b->AclRevision ||
      a->AceCount != b->AceCount)
    return FALSE;
  for (DWORD i = 0; i < a->AceCount; ++i) {
    ACE_HEADER *left = NULL, *right = NULL;
    if (!GetAce(a, i, (void **)&left) || !GetAce(b, i, (void **)&right) ||
        left->AceSize != right->AceSize || memcmp(left, right, left->AceSize))
      return FALSE;
  }
  return TRUE;
}
/* Compare ML fields, ignoring ACL storage/padding and absence vs null/empty.
   Any unexpected non-ML ACE must still agree byte for byte. */
static BOOL next_sacl_ace(PACL acl, DWORD *index, BOOL mandatory,
                          ACE_HEADER **out) {
  *out = NULL;
  if (!acl)
    return TRUE;
  if (!IsValidAcl(acl))
    return FALSE;
  while (*index < acl->AceCount) {
    ACE_HEADER *ace = NULL;
    if (!GetAce(acl, (*index)++, (void **)&ace))
      return FALSE;
    if ((ace->AceType == SYSTEM_MANDATORY_LABEL_ACE_TYPE) == mandatory) {
      *out = ace;
      return TRUE;
    }
  }
  return TRUE;
}
static BOOL sacl_aces_equal(PACL a, PACL b, BOOL mandatory) {
  DWORD ai = 0, bi = 0;
  for (;;) {
    ACE_HEADER *left = NULL, *right = NULL;
    if (!next_sacl_ace(a, &ai, mandatory, &left) ||
        !next_sacl_ace(b, &bi, mandatory, &right))
      return FALSE;
    if (!left || !right)
      return left == right;
    if (!mandatory) {
      if (left->AceSize != right->AceSize || memcmp(left, right, left->AceSize))
        return FALSE;
    } else {
      SYSTEM_MANDATORY_LABEL_ACE *l = (SYSTEM_MANDATORY_LABEL_ACE *)left;
      SYSTEM_MANDATORY_LABEL_ACE *r = (SYSTEM_MANDATORY_LABEL_ACE *)right;
      size_t prefix = offsetof(SYSTEM_MANDATORY_LABEL_ACE, SidStart);
      if (left->AceSize < prefix + sizeof(SID) ||
          right->AceSize < prefix + sizeof(SID))
        return FALSE;
      PSID ls = &l->SidStart, rs = &r->SidStart;
      if (GetSidLengthRequired(((SID *)ls)->SubAuthorityCount) >
              left->AceSize - prefix ||
          GetSidLengthRequired(((SID *)rs)->SubAuthorityCount) >
              right->AceSize - prefix ||
          !IsValidSid(ls) || !IsValidSid(rs) ||
          GetLengthSid(ls) > left->AceSize - prefix ||
          GetLengthSid(rs) > right->AceSize - prefix ||
          left->AceType != right->AceType ||
          left->AceFlags != right->AceFlags || l->Mask != r->Mask ||
          !sid_equal(ls, rs))
        return FALSE;
    }
  }
}
static BOOL descriptor_compare(PSECURITY_DESCRIPTOR original,
                               PSECURITY_DESCRIPTOR current, BOOL report) {
  PSID owner[2] = {NULL}, group[2] = {NULL};
  PACL dacl[2] = {NULL}, sacl[2] = {NULL};
  BOOL dp[2], sp[2], def;
  SECURITY_DESCRIPTOR_CONTROL control[2];
  DWORD revision[2];
  PSECURITY_DESCRIPTOR descriptors[] = {original, current};
  for (unsigned i = 0; i < 2; ++i) {
    if (!GetSecurityDescriptorOwner(descriptors[i], &owner[i], &def) ||
        !GetSecurityDescriptorGroup(descriptors[i], &group[i], &def) ||
        !GetSecurityDescriptorDacl(descriptors[i], &dp[i], &dacl[i], &def) ||
        !GetSecurityDescriptorSacl(descriptors[i], &sp[i], &sacl[i], &def) ||
        !GetSecurityDescriptorControl(descriptors[i], &control[i],
                                      &revision[i]))
      return FALSE;
    /* Absent ACL accessors need not initialize their ACL output pointer. */
    if (!dp[i])
      dacl[i] = NULL;
    if (!sp[i])
      sacl[i] = NULL;
  }
  unsigned diff = control[0] ^ control[1];
  unsigned sacl_diff = diff & (SE_SACL_PRESENT | SE_SACL_AUTO_INHERITED);
  unsigned dacl_diff = diff & (SE_DACL_PROTECTED | SE_DACL_AUTO_INHERITED);
  BOOL owners = sid_equal(owner[0], owner[1]);
  BOOL groups = sid_equal(group[0], group[1]);
  BOOL dacls = dp[0] == dp[1] && !dacl_diff && dacl_equal(dacl[0], dacl[1]);
  BOOL labels = sacl_aces_equal(sacl[0], sacl[1], TRUE);
  BOOL other = revision[0] == revision[1] &&
               !(diff & ~(SE_SACL_PRESENT | SE_SACL_AUTO_INHERITED)) &&
               sacl_aces_equal(sacl[0], sacl[1], FALSE);
  if (report) {
    printf("SACL_CONTROL_DIFF=0x%04x original=0x%04x final=0x%04x "
           "SE_SACL_PRESENT_DIFF=%d SE_SACL_AUTO_INHERITED_DIFF=%d\n",
           sacl_diff, control[0], control[1], !!(sacl_diff & SE_SACL_PRESENT),
           !!(sacl_diff & SE_SACL_AUTO_INHERITED));
    printf("SD_SEMANTIC owner_equal=%d group_equal=%d dacl_equal=%d "
           "DACL_CONTROL_DIFF=0x%04x effective_label_equal=%d other_equal=%d\n",
           owners, groups, dacls, dacl_diff, labels, other);
  }
  BOOL equal = owners && groups && dacls && labels && other;
  if (!equal)
    SetLastError(ERROR_INVALID_SECURITY_DESCR);
  return equal;
}
static BOOL descriptor_equal(PSECURITY_DESCRIPTOR original,
                             PSECURITY_DESCRIPTOR current) {
  return descriptor_compare(original, current, TRUE);
}
static BOOL snapshot_equal(const snapshot *snap) {
  PSECURITY_DESCRIPTOR current = NULL;
  FILE_ID_INFO identity;
  if (snap->file &&
      (!GetFileInformationByHandleEx(snap->handle, FileIdInfo, &identity,
                                     sizeof(identity)) ||
       identity.VolumeSerialNumber != snap->identity.VolumeSerialNumber ||
       memcmp(&identity.FileId, &snap->identity.FileId,
              sizeof(identity.FileId)))) {
    SetLastError(ERROR_FILE_INVALID);
    return FALSE;
  }
  if (!kernel_sd(snap->handle, SD_INFO, &current)) {
    return FALSE;
  }
  DWORD size = GetSecurityDescriptorLength(current);
  BOOL equal = descriptor_equal(snap->sd, current);
  DWORD error = equal ? ERROR_SUCCESS : GetLastError();
  printf("SD_COMPARE same_identity=%d original_bytes=%lu final_bytes=%lu "
         "byte_identical=%d semantic_exact=%d\n",
         snap->file, (unsigned long)snap->length, (unsigned long)size,
         size == snap->length && !memcmp(current, snap->sd, size), equal);
  LocalFree(current);
  SetLastError(error);
  return equal;
}
static BOOL set_sd(HANDLE handle, SE_OBJECT_TYPE type, PSECURITY_DESCRIPTOR sd,
                   BOOL all) {
  (void)type; /* Kernel API operates on the retained handle, not a named object.
               */
  if (!SetKernelObjectSecurity(
          handle, all ? SD_INFO : LABEL_SECURITY_INFORMATION, sd)) {
    DWORD error = GetLastError();
    printf("SD_SET_FAILED handle=%p type=%u info=0x%08lx\n", handle,
           (unsigned)type,
           (unsigned long)(all ? SD_INFO : LABEL_SECURITY_INFORMATION));
    api_error("SetKernelObjectSecurity", error);
    SetLastError(error);
    return FALSE;
  }
  return TRUE;
}
static BOOL restore(const snapshot *snap) {
  if (!snap->sd)
    return FALSE;
  if (!set_sd(snap->handle, snap->type, snap->sd, TRUE))
    return FALSE;
  return snapshot_equal(snap);
}
static void snapshot_dispose(snapshot *snap) {
  if (snap->sd)
    LocalFree(snap->sd);
  snap->sd = NULL;
  close_handle(&snap->handle);
}
static HANDLE open_dir(const WCHAR *path, DWORD access) {
  return CreateFileW(
      path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
}
static BOOL create_dir(suite *s, const WCHAR *path, BOOL lease, int il,
                       snapshot *snap) {
  PSECURITY_DESCRIPTOR sd = NULL;
  if (!make_sd(s, lease, il, TRUE, &sd))
    return FALSE;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), sd, FALSE};
  BOOL made = CreateDirectoryW(path, &sa);
  DWORD error = GetLastError();
  LocalFree(sd);
  if (!made) {
    api_error("CreateDirectoryW(fixture)", error);
    return FALSE;
  }
  if (snap == &s->root_sd)
    s->root_created = TRUE;
  BOOL root = snap == &s->root_sd;
  HANDLE handle = CreateFileW(
      path,
      READ_CONTROL | WRITE_DAC | WRITE_OWNER | FILE_READ_ATTRIBUTES |
          (root ? DELETE | FILE_LIST_DIRECTORY : 0),
      root ? FILE_SHARE_READ : FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      NULL);
  if (handle == INVALID_HANDLE_VALUE) {
    api_error("CreateFileW(directory rights)", GetLastError());
    return FALSE;
  }
  if (!snapshot_take(snap, handle, SE_FILE_OBJECT, TRUE)) {
    CloseHandle(handle);
    snap->handle = NULL;
    return FALSE;
  }
  return TRUE;
}
static BOOL label_is(HANDLE handle, SE_OBJECT_TYPE type, DWORD rid) {
  PACL sacl = NULL;
  PSECURITY_DESCRIPTOR sd = NULL;
  (void)type;
  BOOL present, def;
  if (!kernel_sd(handle, LABEL_SECURITY_INFORMATION, &sd))
    return FALSE;
  if (!GetSecurityDescriptorSacl(sd, &present, &sacl, &def)) {
    LocalFree(sd);
    return FALSE;
  }
  BOOL found = FALSE;
  if (sacl)
    for (DWORD i = 0; i < sacl->AceCount; ++i) {
      SYSTEM_MANDATORY_LABEL_ACE *ace = NULL;
      if (!GetAce(sacl, i, (void **)&ace))
        break;
      if (ace->Header.AceType == SYSTEM_MANDATORY_LABEL_ACE_TYPE) {
        PSID sid = &ace->SidStart;
        DWORD actual =
            *GetSidSubAuthority(sid, *GetSidSubAuthorityCount(sid) - 1);
        printf("LABEL rid=%lu mask=0x%lx flags=0x%x\n", (unsigned long)actual,
               (unsigned long)ace->Mask, ace->Header.AceFlags);
        found =
            actual == rid && (ace->Mask & SYSTEM_MANDATORY_LABEL_NO_WRITE_UP);
      }
    }
  LocalFree(sd);
  if (!found)
    SetLastError(ERROR_INVALID_SECURITY_DESCR);
  return found;
}
static BOOL label_absent(HANDLE handle) {
  PACL sacl = NULL;
  PSECURITY_DESCRIPTOR sd = NULL;
  BOOL present, def;
  if (!kernel_sd(handle, LABEL_SECURITY_INFORMATION, &sd))
    return FALSE;
  if (!GetSecurityDescriptorSacl(sd, &present, &sacl, &def)) {
    LocalFree(sd);
    return FALSE;
  }
  BOOL absent = TRUE;
  if (sacl)
    for (DWORD i = 0; i < sacl->AceCount; ++i) {
      ACE_HEADER *ace = NULL;
      if (!GetAce(sacl, i, (void **)&ace)) {
        absent = FALSE;
        break;
      }
      if (ace->AceType == SYSTEM_MANDATORY_LABEL_ACE_TYPE)
        absent = FALSE;
    }
  LocalFree(sd);
  printf("LABEL absent=%d\n", absent);
  if (!absent)
    SetLastError(ERROR_INVALID_SECURITY_DESCR);
  return absent;
}
static BOOL file_bytes(const WCHAR *path, const void *bytes, DWORD count,
                       BOOL write) {
  HANDLE file =
      CreateFileW(path, write ? GENERIC_WRITE : GENERIC_READ, FILE_SHARE_READ,
                  NULL, write ? CREATE_ALWAYS : OPEN_EXISTING,
                  FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (file == INVALID_HANDLE_VALUE)
    return FALSE;
  DWORD transferred = 0;
  BYTE buffer[64];
  BOOL good;
  if (write)
    good = WriteFile(file, bytes, count, &transferred, NULL) &&
           transferred == count;
  else
    good = count <= sizeof(buffer) &&
           ReadFile(file, buffer, count, &transferred, NULL) &&
           transferred == count && !memcmp(buffer, bytes, count);
  CloseHandle(file);
  return good;
}
static BOOL write_all(HANDLE pipe, const void *bytes, DWORD count) {
  DWORD done = 0;
  return WriteFile(pipe, bytes, count, &done, NULL) && done == count;
}
static BOOL read_deadline(HANDLE pipe, void *bytes, DWORD count) {
  DWORD done = 0;
  ULONGLONG deadline = GetTickCount64() + WAIT_MS;
  while (done < count && GetTickCount64() < deadline) {
    DWORD available = 0, got = 0;
    if (!PeekNamedPipe(pipe, NULL, 0, NULL, &available, NULL))
      return FALSE;
    if (!available) {
      Sleep(5);
      continue;
    }
    DWORD wanted = count - done;
    if (wanted > available)
      wanted = available;
    if (!ReadFile(pipe, (BYTE *)bytes + done, wanted, &got, NULL) || !got)
      return FALSE;
    done += got;
  }
  if (done != count)
    SetLastError(ERROR_TIMEOUT);
  return done == count;
}
static BOOL make_pipe(HANDLE *read, HANDLE *write, BOOL parent_reads) {
  SECURITY_ATTRIBUTES sa = {sizeof(sa), NULL, TRUE};
  if (!CreatePipe(read, write, &sa, 0))
    return FALSE;
  return SetHandleInformation(parent_reads ? *read : *write,
                              HANDLE_FLAG_INHERIT, 0);
}
static WCHAR *environment(const WCHAR *temp, BOOL appcontainer,
                          BOOL private_local, const WCHAR *local_base) {
  WCHAR windows[CAP], system[CAP], local[CAP];
  if (!bounded_text(GetWindowsDirectoryW(windows, CAP), CAP,
                    "GetWindowsDirectoryW") ||
      !bounded_text(GetSystemDirectoryW(system, CAP), CAP,
                    "GetSystemDirectoryW"))
    return NULL;
  if (private_local) {
    if (!fmt(local, CAP, L"%ls", local_base))
      return NULL;
  } else if (appcontainer) {
    /* Required to prepare the AppContainer profile (203 without it), as in
       orq-appcontainer_capability_probe-20261010.c. Never dump its value. */
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", local, CAP);
    if (!length || length >= CAP) {
      DWORD error = length >= CAP ? ERROR_INSUFFICIENT_BUFFER : GetLastError();
      fprintf(stderr, "API=GetEnvironmentVariableW(LOCALAPPDATA) WIN32=%lu\n",
              (unsigned long)error);
      SetLastError(error);
      return NULL;
    }
  }
  size_t capacity = CAP * 10 + 256;
  WCHAR *block = calloc(capacity, sizeof(WCHAR));
  if (!block)
    return NULL;
  /* Sorted, explicit, private temp/cache. No inherited credentials or full
     environment dump. Runtime installation paths remain read-only. */
  WCHAR *cursor = block;
  size_t remaining = capacity;
  if (private_local) {
    const WCHAR *private_formats[] = {
        L"APPDATA=%ls",          L"HOME=%ls", L"LOCALAPPDATA=%ls",
        L"npm_config_cache=%ls", L"PATH=%ls", L"PYTHONPYCACHEPREFIX=%ls",
        L"SystemRoot=%ls",       L"TEMP=%ls", L"TMP=%ls",
        L"USERPROFILE=%ls"};
    const WCHAR *private_values[] = {temp, temp,    local, temp, system,
                                     temp, windows, temp,  temp, temp};
    for (unsigned i = 0; i < 10; ++i) {
      if (!fmt(cursor, remaining - 1, private_formats[i], private_values[i])) {
        free(block);
        return NULL;
      }
      size_t size = wcslen(cursor) + 1;
      cursor += size;
      remaining -= size;
    }
    *cursor = 0;
    return block;
  }
  const WCHAR *formats[] = {L"LOCALAPPDATA=%ls", L"npm_config_cache=%ls",
                            L"PATH=%ls",         L"SystemRoot=%ls",
                            L"TEMP=%ls",         L"TMP=%ls"};
  const WCHAR *values[] = {local, temp, system, windows, temp, temp};
  for (unsigned i = appcontainer || private_local ? 0 : 1; i < 6; ++i) {
    if (!fmt(cursor, remaining - 1, formats[i], values[i])) {
      free(block);
      return NULL;
    }
    size_t size = wcslen(cursor) + 1;
    cursor += size;
    remaining -= size;
  }
  *cursor = 0;
  return block;
}
static void launch_error(const sec5_request *request,
                         const sec5_result *launch) {
  static const char *const stages[] = {
      "UNKNOWN", "INPUT",      "TOKEN",  "INTEGRITY", "POLICY",
      "JOB",     "ATTRIBUTES", "CREATE", "ASSIGN",    "OBSERVE",
      "SEEDED",  "RESUME",     "READY"};
  const char *api = request->backend == SEC5_APPCONTAINER
                        ? "CreateProcessW"
                        : "CreateProcessAsUserW";
  api_error(launch->stage == SEC5_CREATE ? api : "governed_process",
            launch->error);
  printf("LAUNCH_DIAGNOSTIC create_api=%s stage=%u stage_name=%s "
         "environment_encoding=UTF-16LE CREATE_UNICODE_ENVIRONMENT=1 "
         "environment_names=",
         api, launch->stage,
         (unsigned)launch->stage < sizeof(stages) / sizeof(stages[0])
             ? stages[launch->stage]
             : "UNKNOWN");
  const WCHAR *entry = request->environment, *previous = NULL;
  BOOL sorted = TRUE;
  while (entry && *entry) {
    const WCHAR *equal = wcschr(entry, L'=');
    printf("%s%.*ls", previous ? "," : "", (int)(equal ? equal - entry : 0),
           entry);
    if (previous && _wcsicmp(previous, entry) > 0)
      sorted = FALSE;
    previous = entry;
    entry += wcslen(entry) + 1;
  }
  printf(" environment_sorted=%d environment_double_nul=%d\n", sorted,
         entry && previous && entry[-1] == 0 && *entry == 0);
  fflush(stdout);
}
static BOOL appcontainer_token_cap(HANDLE process, PSID expected,
                                   PSID capability, BOOL verbose) {
  HANDLE token = NULL;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token))
    return FALSE;
  DWORD ac = 0, ui = 1, virtualized = 1, type = 0;
  TOKEN_APPCONTAINER_INFORMATION *package =
      token_info(token, TokenAppContainerSid);
  TOKEN_GROUPS *caps = token_info(token, TokenCapabilities);
  TOKEN_MANDATORY_LABEL *label = token_info(token, TokenIntegrityLevel);
  DWORD il =
      label
          ? *GetSidSubAuthority(label->Label.Sid,
                                *GetSidSubAuthorityCount(label->Label.Sid) - 1)
          : 0;
  BOOL good =
      token_scalar(token, TokenIsAppContainer, &ac) && ac == 1 && package &&
      package->TokenAppContainer &&
      EqualSid(package->TokenAppContainer, expected) && caps &&
      caps->GroupCount == (capability ? 1u : 0u) &&
      (!capability || (EqualSid(caps->Groups[0].Sid, capability) &&
                       (caps->Groups[0].Attributes & SE_GROUP_ENABLED) &&
                       !(caps->Groups[0].Attributes &
                         ~(SE_GROUP_ENABLED | SE_GROUP_ENABLED_BY_DEFAULT |
                           SE_GROUP_MANDATORY)))) &&
      label && il == SECURITY_MANDATORY_LOW_RID &&
      token_scalar(token, TokenUIAccess, &ui) && ui == 0 &&
      token_scalar(token, TokenVirtualizationEnabled, &virtualized) &&
      virtualized == 0 && token_scalar(token, TokenType, &type) &&
      type == TokenPrimary && privilege_dump(token, TRUE, verbose);
  LPWSTR text = NULL;
  if (verbose && package && package->TokenAppContainer &&
      ConvertSidToStringSidW(package->TokenAppContainer, &text)) {
    printf("APPCONTAINER_TOKEN pid=%lu IsAppContainer=%lu SID=%ls "
           "capabilities=%lu IL=%lu UIAccess=%lu virtualized=%lu match=%d\n",
           (unsigned long)GetProcessId(process), (unsigned long)ac, text,
           caps ? (unsigned long)caps->GroupCount : 0, (unsigned long)il,
           (unsigned long)ui, (unsigned long)virtualized, good);
    LocalFree(text);
  } else if (verbose)
    printf("APPCONTAINER_TOKEN pid=%lu IsAppContainer=%lu match=0\n",
           (unsigned long)GetProcessId(process), (unsigned long)ac);
  free(package);
  free(caps);
  free(label);
  CloseHandle(token);
  return good;
}
static BOOL appcontainer_token(HANDLE process, PSID expected, BOOL verbose) {
  return appcontainer_token_cap(process, expected, NULL, verbose);
}
static int observe_token(HANDLE process, HANDLE job, void *context) {
  suite *s = context;
  if (s->backend == SEC5_APPCONTAINER) {
    BOOL member = FALSE;
    PSID expected =
        s->mutation == SEC5_NO_RUNTIME_CAPABILITY ? NULL : s->active_capability;
    s->token_ok =
        appcontainer_token_cap(process, s->lease, expected, !s->quiet_tokens) &&
        IsProcessInJob(process, job, &member) && member;
    /* Mutations measure effects without weakening the assertions below. */
    return s->mutation == SEC5_BASELINE ? s->token_ok : TRUE;
  }
  HANDLE token = NULL;
  BOOL member = FALSE;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token))
    return 0;
  if (!IsProcessInJob(process, job, &member)) {
    CloseHandle(token);
    return 0;
  }
  TOKEN_GROUPS *restricted = token_info(token, TokenRestrictedSids);
  TOKEN_MANDATORY_LABEL *label = token_info(token, TokenIntegrityLevel);
  DWORD type = 0, policy = 0, ui = 0, virtualized = 0;
  BOOL good = restricted && label && token_scalar(token, TokenType, &type) &&
              token_scalar(token, TokenMandatoryPolicy, &policy) &&
              token_scalar(token, TokenUIAccess, &ui) &&
              token_scalar(token, TokenVirtualizationEnabled, &virtualized);
  DWORD il =
      label
          ? *GetSidSubAuthority(label->Label.Sid,
                                *GetSidSubAuthorityCount(label->Label.Sid) - 1)
          : 0;
  /* Conjunto exacto de SIDs restrictivos del diseño medido el 10-oct: lease +
     Everyone + Users + Authenticated Users + RESTRICTED + logon. Ni uno mas
     (en particular, nunca el SID del usuario) ni uno menos. */
  BOOL lease = FALSE;
  if (restricted && restricted->GroupCount == 6) {
    static const WCHAR *const generic_text[] = {L"S-1-1-0", L"S-1-5-32-545",
                                                L"S-1-5-11", L"S-1-5-12"};
    unsigned found_lease = 0, found_generic = 0, found_logon = 0,
             found_user = 0;
    PSID generic[4] = {NULL, NULL, NULL, NULL};
    BOOL converted = TRUE;
    for (unsigned g = 0; g < 4; ++g)
      converted =
          converted && ConvertStringSidToSidW(generic_text[g], &generic[g]);
    for (DWORD i = 0; converted && i < restricted->GroupCount; ++i) {
      PSID sid = restricted->Groups[i].Sid;
      if (EqualSid(sid, s->lease))
        ++found_lease;
      else if (EqualSid(sid, s->user))
        ++found_user;
      else {
        BOOL known = FALSE;
        for (unsigned g = 0; g < 4; ++g)
          if (EqualSid(sid, generic[g])) {
            ++found_generic;
            known = TRUE;
          }
        if (!known && GetSidSubAuthorityCount(sid) &&
            *GetSidIdentifierAuthority(sid)->Value == 0 &&
            GetSidIdentifierAuthority(sid)->Value[5] == 5 &&
            *GetSidSubAuthority(sid, 0) == SECURITY_LOGON_IDS_RID)
          ++found_logon;
      }
    }
    for (unsigned g = 0; g < 4; ++g)
      if (generic[g])
        LocalFree(generic[g]);
    lease = converted && found_lease == 1 && found_generic == 4 &&
            found_logon == 1 && found_user == 0;
  }
  if (!s->quiet_tokens)
    printf("CHILD_TOKEN pid=%lu suspended=true IL=%lu restrict_count=%lu "
           "lease_match=%d type=%lu policy=%lu UIAccess=%lu virtualized=%lu "
           "Job=%d\n",
           (unsigned long)GetProcessId(process), (unsigned long)il,
           restricted ? (unsigned long)restricted->GroupCount : 0, lease,
           (unsigned long)type, (unsigned long)policy, (unsigned long)ui,
           (unsigned long)virtualized, member);
  BOOL privileges = privilege_dump(token, TRUE, !s->quiet_tokens);
  s->token_ok = good && lease && il == SECURITY_MANDATORY_LOW_RID &&
                type == TokenPrimary &&
                policy == (TOKEN_MANDATORY_POLICY_NO_WRITE_UP |
                           TOKEN_MANDATORY_POLICY_NEW_PROCESS_MIN) &&
                !ui && !virtualized && member && privileges;
  free(restricted);
  free(label);
  CloseHandle(token);
  /* Gather a mutation's bad token without preempting its discriminating OS
     operations. Baseline tests below retain their original assertions. */
  return s->mutation == SEC5_BASELINE ? s->token_ok : good && privileges;
}
static HANDLE harness_job(BOOL breakaway) {
  HANDLE job = CreateJobObjectW(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (breakaway)
    limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_BREAKAWAY_OK;
  if (job && !SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                      &limits, sizeof(limits))) {
    CloseHandle(job);
    job = NULL;
  }
  return job;
}
static BOOL snapshot_before(run *r) {
  sec5_process_table table;
  if (!sec5_process_snapshot(&table))
    return FALSE;
  r->before_ids = calloc(table.count, sizeof(*r->before_ids));
  if (!r->before_ids) {
    free(table.entries);
    return FALSE;
  }
  for (unsigned i = 0; i < table.count; ++i) {
    process_identity *identity = &r->before_ids[r->before_count++];
    identity->pid = table.entries[i].pid;
    identity->birth = table.entries[i].birth;
    identity->known = sec5_birth_known(identity->birth);
  }
  free(table.entries);
  return TRUE;
}
static void pin_run_consoles(run *r);
static BOOL launch_run(suite *s, run *r, BOOL ordinary, const WCHAR *exe,
                       const WCHAR *arguments, BOOL seeded) {
  memset(r, 0, sizeof(*r));
  r->ordinary = ordinary;
  r->owner = s;
  if (!snapshot_before(r))
    return FALSE;
  HANDLE in_read = NULL, out_write = NULL, err_write = NULL;
  WCHAR command[CAP * 2];
  WCHAR *env = NULL;
  if (!random_bytes(r->nonce, sizeof(r->nonce)) ||
      !make_pipe(&in_read, &r->in_write, FALSE) ||
      !make_pipe(&r->out_read, &out_write, TRUE) ||
      !make_pipe(&r->err_read, &err_write, TRUE))
    goto fail;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), NULL, TRUE};
  r->witness = CreateEventW(&sa, TRUE, FALSE, NULL);
  r->excluded = CreateEventW(&sa, TRUE, FALSE, NULL);
  if (!r->witness || !r->excluded)
    goto fail;
  if (!fmt(command, CAP * 2, L"\"%ls\" %ls %llu %llu", exe, arguments,
           (unsigned long long)(uintptr_t)r->witness,
           (unsigned long long)(uintptr_t)r->excluded))
    goto fail;
  /* Ordinary brokers also create AppContainer children. Their explicit
     environment replaces the parent's; keep the profile prerequisite. */
  env = environment(
      s->private_environment && *s->private_temp ? s->private_temp : s->dest,
      s->backend == SEC5_APPCONTAINER && s->mutation != SEC5_NO_APPCONTAINER,
      s->private_environment, *s->private_temp ? s->private_local : s->dest);
  if (!env)
    goto fail;
  if (ordinary || s->mutation == SEC5_RESUME_FIRST) {
    r->outer_job = harness_job(ordinary);
    if (!r->outer_job)
      goto fail;
  }
  if (ordinary) {
    STARTUPINFOW si = {0};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_read;
    si.hStdOutput = out_write;
    si.hStdError = err_write;
    if (!CreateProcessW(exe, command, NULL, NULL, TRUE,
                        CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW |
                            CREATE_SUSPENDED,
                        env, s->dest, &si, &r->process.pi))
      goto fail;
    if (!AssignProcessToJobObject(r->outer_job, r->process.pi.hProcess) ||
        ResumeThread(r->process.pi.hThread) != 1)
      goto fail;
    r->process.resumed = TRUE;
    FILETIME a, b, c;
    if (!GetProcessTimes(r->process.pi.hProcess, &r->process.creation_time, &a,
                         &b, &c))
      goto fail;
  } else {
    HANDLE handles[] = {in_read, out_write, err_write, r->witness};
    sec5_request request = {0};
    request.executable = exe;
    request.command_line = command;
    request.cwd = s->dest;
    request.environment = env;
    request.executable_pin =
        !wcscmp(exe, s->child)
            ? s->child_pin
            : CreateFileW(exe, GENERIC_READ, FILE_SHARE_READ, NULL,
                          OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    request.backend = s->backend;
    request.lease_sid = s->lease;
    request.runtime_capability = s->active_capability;
    request.default_dacl = s->default_dacl;
    request.handles = handles;
    request.handle_count = 4;
    request.stdin_handle = in_read;
    request.stdout_handle = out_write;
    request.stderr_handle =
        s->mutation == SEC5_MERGE_STDERR ? out_write : err_write;
    request.mutation = s->mutation;
    request.fail_before_resume = seeded;
    request.fail_stage = s->failure_stage;
    request.harness_job = r->outer_job;
    request.early_event = r->witness;
    request.observe_suspended = observe_token;
    request.observer_context = s;
    BOOL hashed = request.executable_pin != INVALID_HANDLE_VALUE &&
                  request.executable_pin &&
                  (request.executable_pin == s->child_pin ||
                   hash_file(request.executable_pin, "retained interpreter"));
    BOOL launched = hashed && sec5_launch_fixture(&request, &r->process);
    if (!hashed) {
      r->process.error = GetLastError();
      if (!r->process.error)
        r->process.error = ERROR_GEN_FAILURE;
      r->process.stage = SEC5_INPUT;
    }
    if (request.executable_pin != s->child_pin &&
        request.executable_pin != INVALID_HANDLE_VALUE)
      CloseHandle(request.executable_pin);
    printf("LAUNCH ordinary=false stage=%u error=%lu cleanup_error=%lu pid=%lu "
           "resumed=%d\n",
           r->process.stage, (unsigned long)r->process.error,
           (unsigned long)r->process.cleanup_error,
           (unsigned long)r->process.pi.dwProcessId, r->process.resumed);
    if (!launched) {
      launch_error(&request, &r->process);
      if (r->process.stage == SEC5_CREATE) {
        s->blocked = TRUE;
        printf("P1 BLOCKED %s stage=CREATE; no fallback, elevation, "
               "credentials or developer mode\n",
               s->backend == SEC5_APPCONTAINER ? "CreateProcessW"
                                               : "CreateProcessAsUserW");
      }
      free(env);
      close_handle(&in_read);
      close_handle(&out_write);
      close_handle(&err_write);
      return FALSE;
    }
  }
  free(env);
  close_handle(&in_read);
  close_handle(&out_write);
  close_handle(&err_write);
  pin_run_consoles(r);
  return TRUE;
fail:
  api_error("fixture launch/setup", GetLastError());
  free(env);
  close_handle(&in_read);
  close_handle(&out_write);
  close_handle(&err_write);
  return FALSE;
}
static BOOL exchange(run *r, DWORD operation) {
  if (!write_all(r->in_write, r->nonce, sizeof(r->nonce)) ||
      !read_deadline(r->out_read, &r->reply, sizeof(r->reply)))
    return FALSE;
  r->complete = r->reply.magic == MAGIC &&
                r->reply.pid == r->process.pi.dwProcessId &&
                r->reply.operation == operation && r->reply.attempted == 1 &&
                !memcmp(r->reply.nonce, r->nonce, sizeof(r->nonce));
  printf("ATTEMPT pid=%lu operation=%lu barrier=%d error=%lu "
         "secondary_error=%lu opened=%lu\n",
         (unsigned long)r->reply.pid, (unsigned long)operation, r->complete,
         (unsigned long)r->reply.error, (unsigned long)r->reply.secondary_error,
         (unsigned long)r->reply.opened);
  return r->complete;
}
static BOOL release_run(run *r) {
  pin_run_consoles(
      r); /* Certify while the parent is still behind its barrier. */
  BYTE release = 1;
  if (!write_all(r->in_write, &release, 1))
    return FALSE;
  DWORD code = STILL_ACTIVE;
  if (r->reply.operation == OP_STDIO)
    close_handle(&r->in_write);
  BOOL exited =
      WaitForSingleObject(r->process.pi.hProcess, WAIT_MS) == WAIT_OBJECT_0 &&
      GetExitCodeProcess(r->process.pi.hProcess, &code);
  printf("CHILD_EXIT pid=%lu code=%lu\n",
         (unsigned long)r->process.pi.dwProcessId, (unsigned long)code);
  return exited && code == 0;
}
static BOOL capture_remaining(HANDLE pipe, const char *channel, DWORD pid,
                              BOOL exact) {
  if (!pipe)
    return TRUE;
  BYTE buffer[2048];
  DWORD total = 0;
  ULONGLONG deadline = GetTickCount64() + WAIT_MS;
  for (;;) {
    DWORD available = 0, got = 0;
    if (!PeekNamedPipe(pipe, NULL, 0, NULL, &available, NULL)) {
      DWORD error = GetLastError();
      if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED)
        return !exact || total == 0;
      api_error("PeekNamedPipe(capture)", error);
      return FALSE;
    }
    if (!available) {
      if (!exact)
        return TRUE;
      if (total || GetTickCount64() >= deadline)
        return FALSE;
      Sleep(5);
      continue;
    }
    DWORD count = available < sizeof(buffer) ? available : sizeof(buffer);
    if (!ReadFile(pipe, buffer, count, &got, NULL) || !got) {
      api_error("ReadFile(capture)", GetLastError());
      return FALSE;
    }
    printf("PIPE_CAPTURE pid=%lu channel=%s bytes=%lu HEX=", (unsigned long)pid,
           channel, (unsigned long)got);
    for (DWORD i = 0; i < got; ++i)
      printf("%02x", buffer[i]);
    printf("\n");
    total += got;
    if (total > 1024 * 1024) {
      printf("PIPE_CAPTURE BLOCKED excessive fixture output\n");
      return FALSE;
    }
  }
}
/* Parent PID and birth time are observation only, never termination authority.
 */
static BOOL job_owns(HANDLE job, HANDLE process) {
  if (!job || !process)
    return FALSE;
  DWORD capacity = 64;
  BOOL owned = FALSE;
  while (capacity <= 65536) {
    DWORD bytes = (DWORD)(sizeof(JOBOBJECT_BASIC_PROCESS_ID_LIST) +
                          capacity * sizeof(ULONG_PTR));
    JOBOBJECT_BASIC_PROCESS_ID_LIST *list = calloc(1, bytes);
    if (!list)
      return cycle_api_fail("calloc", "Job process list",
                            ERROR_NOT_ENOUGH_MEMORY);
    BOOL queried = QueryInformationJobObject(job, JobObjectBasicProcessIdList,
                                             list, bytes, NULL);
    DWORD error = GetLastError();
    if (queried && list->NumberOfProcessIdsInList > capacity) {
      free(list);
      return cycle_api_fail("QueryInformationJobObject", "process list count",
                            ERROR_INVALID_DATA);
    }
    if (queried) {
      DWORD pid = GetProcessId(process);
      for (DWORD i = 0; i < list->NumberOfProcessIdsInList; ++i)
        if (list->ProcessIdList[i] == pid)
          owned = TRUE;
      BOOL member = FALSE;
      owned = owned && IsProcessInJob(process, job, &member) && member;
    }
    free(list);
    if (queried)
      return owned;
    if (error != ERROR_MORE_DATA && error != ERROR_INSUFFICIENT_BUFFER)
      return cycle_api_fail("QueryInformationJobObject", "process list", error);
    capacity *= 2;
  }
  return cycle_api_fail("QueryInformationJobObject",
                        "process list growth limit", ERROR_INSUFFICIENT_BUFFER);
}
static BOOL in_before(const run *r, DWORD pid, HANDLE process, BOOL *found) {
  FILETIME birth, exit, kernel, user;
  *found = FALSE;
  if (!r->before_ids ||
      !GetProcessTimes(process, &birth, &exit, &kernel, &user))
    return FALSE;
  for (unsigned i = 0; i < r->before_count; ++i) {
    const process_identity *identity = &r->before_ids[i];
    if (identity->pid == pid && identity->known &&
        !memcmp(&identity->birth, &birth, sizeof(birth)))
      *found = TRUE;
  }
  return TRUE;
}
typedef struct descendant_measurement {
  unsigned count, outside, consoles, others;
  BOOL others_identified;
} descendant_measurement;
static BOOL normalized_path(const WCHAR *path, WCHAR *normalized) {
  DWORD length = GetFullPathNameW(path, CAP, normalized, NULL);
  if (!length || length >= CAP)
    return FALSE;
  for (DWORD i = 0; i < length; ++i)
    if (normalized[i] == L'/')
      normalized[i] = L'\\';
  return CharLowerBuffW(normalized, length) == length;
}
static BOOL measure_descendants(run *r, HANDLE job,
                                descendant_measurement *measurement,
                                BOOL settling) {
  DWORD parents[4096] = {r->process.pi.dwProcessId};
  HANDLE pinned[4096] = {r->process.pi.hProcess};
  FILETIME births[4096] = {r->process.creation_time};
  BOOL members[4096] = {FALSE}, consoles[4096] = {FALSE};
  members[0] = job && (r->process.resumed || job_owns(job, pinned[0]));
  unsigned parent_count = 1;
  ULONGLONG deadline = GetTickCount64() + WAIT_MS;
  memset(measurement, 0, sizeof(*measurement));
  measurement->others_identified = TRUE;
  WCHAR system_root[CAP], console_path[CAP], expected_console[CAP];
  DWORD length = GetWindowsDirectoryW(system_root, CAP);
  if (!length || length >= CAP ||
      !fmt(console_path, CAP, L"%ls\\System32\\conhost.exe", system_root) ||
      !normalized_path(console_path, expected_console))
    return FALSE;
  sec5_process_table after;
  if (!sec5_process_snapshot(&after))
    return FALSE;
  BOOL good = TRUE;
  for (unsigned index = 0; good && index < parent_count; ++index) {
    FILETIME parent_birth, parent_exit, kernel, user;
    BOOL parent_identity = GetProcessId(pinned[index]) == parents[index] &&
                           GetProcessTimes(pinned[index], &parent_birth,
                                           &parent_exit, &kernel, &user) &&
                           sec5_same_instance(parents[index], parent_birth,
                                              parents[index], births[index]);
    if (!parent_identity) {
      printf("DESCENDANT_PARENT_IDENTITY parent=%lu certified=0\n",
             (unsigned long)parents[index]);
      good = FALSE;
      break;
    }
    for (unsigned row = 0; good && row < after.count; ++row) {
      const sec5_process_entry *observed = &after.entries[row];
      PROCESSENTRY32W entry = {0};
      entry.th32ProcessID = observed->pid;
      entry.th32ParentProcessID = observed->parent;
      if (entry.th32ParentProcessID != parents[index])
        continue;
      int classification = sec5_descendant_classify(
          observed->parent, observed->birth, parents[index], parent_birth,
          parent_exit, parent_identity);
      if (classification == 0) {
        printf("DESCENDANT_DISCARD pid=%lu parent=%lu "
               "reason=outside_parent_lifetime opened=0\n",
               (unsigned long)observed->pid, (unsigned long)observed->parent);
        continue;
      }
      if (classification < 0) {
        printf("DESCENDANT_IDENTITY pid=%lu parent=%lu certified=0\n",
               (unsigned long)observed->pid, (unsigned long)observed->parent);
        good = FALSE;
        break;
      }
      BOOL prior = FALSE, seen = FALSE;
      for (unsigned i = 0; i < parent_count; ++i)
        if (sec5_same_instance(entry.th32ProcessID, observed->birth, parents[i],
                               births[i]))
          seen = TRUE;
      if (seen)
        continue;
      console_pin *known_console = NULL;
      for (console_pin *pin = r->console_pins; pin; pin = pin->next)
        if (sec5_same_instance(entry.th32ProcessID, observed->birth, pin->pid,
                               pin->birth) &&
            sec5_same_instance(entry.th32ParentProcessID, parent_birth,
                               pin->parent, pin->parent_birth))
          known_console = pin;
      HANDLE process = NULL;
      if (known_console) {
        if (!DuplicateHandle(GetCurrentProcess(), known_console->process,
                             GetCurrentProcess(), &process, 0, FALSE,
                             DUPLICATE_SAME_ACCESS))
          process = NULL;
      } else
        process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                              FALSE, entry.th32ProcessID);
      if (!process) {
        DWORD error = GetLastError();
        printf("DESCENDANT_OPEN pid=%lu parent=%lu error=%lu retained=%d\n",
               (unsigned long)entry.th32ProcessID,
               (unsigned long)entry.th32ParentProcessID, (unsigned long)error,
               known_console != NULL);
        good = FALSE;
        break;
      }
      FILETIME opened_birth, opened_exit, opened_kernel, opened_user;
      if (GetProcessId(process) != observed->pid ||
          !GetProcessTimes(process, &opened_birth, &opened_exit, &opened_kernel,
                           &opened_user) ||
          !sec5_same_instance(observed->pid, opened_birth, observed->pid,
                              observed->birth)) {
        printf("DESCENDANT_IDENTITY pid=%lu parent=%lu "
               "reason=snapshot_handle_mismatch certified=0\n",
               (unsigned long)observed->pid, (unsigned long)observed->parent);
        CloseHandle(process);
        good = FALSE;
        break;
      }
      if (!in_before(r, entry.th32ProcessID, process, &prior) ||
          parent_count == 4096) {
        CloseHandle(process);
        good = FALSE;
        break;
      }
      if (prior) {
        CloseHandle(process);
        continue;
      }
      parents[parent_count] = entry.th32ProcessID;
      pinned[parent_count] = process;
      births[parent_count] = opened_birth;
      ++measurement->count;
      DWORD state = WaitForSingleObject(process, 0);
      BOOL live = state == WAIT_TIMEOUT;
      BOOL retained_member = FALSE;
      BOOL member = live && job_owns(job, process);
      if (!member) {
        state = WaitForSingleObject(process, 0);
        live = state == WAIT_TIMEOUT;
        member = !live && job &&
                 IsProcessInJob(process, job, &retained_member) &&
                 retained_member;
      }
      if (state != WAIT_TIMEOUT && state != WAIT_OBJECT_0)
        good = FALSE;
      if (live && !member)
        ++measurement->outside;
      WCHAR image[CAP], normalized[CAP];
      DWORD image_length = CAP;
      BOOL image_known =
          QueryFullProcessImageNameW(process, 0, image, &image_length);
      DWORD image_error = image_known ? 0 : GetLastError();
      BOOL normalized_known = image_known && normalized_path(image, normalized);
      BOOL console = normalized_known && !wcscmp(normalized, expected_console);
      FILETIME birth = opened_birth;
      BOOL certified = console && member && members[index] &&
                       !consoles[index] &&
                       CompareFileTime(&birth, &parent_birth) >= 0;
      console_pin *retained_console = NULL;
      for (console_pin *pin = r->console_pins; pin; pin = pin->next) {
        if (sec5_same_instance(entry.th32ProcessID, birth, pin->pid,
                               pin->birth) &&
            sec5_same_instance(entry.th32ParentProcessID, parent_birth,
                               pin->parent, pin->parent_birth))
          retained_console = pin;
        else if (certified && pin->parent == entry.th32ParentProcessID &&
                 !memcmp(&parent_birth, &pin->parent_birth,
                         sizeof(parent_birth)))
          certified = FALSE; /* At most one console for this parent identity. */
      }
      certified = certified || (console && member && members[index] &&
                                retained_console && !consoles[index]);
      if (certified && !retained_console) {
        console_pin *pin = calloc(1, sizeof(*pin));
        if (!pin ||
            !DuplicateHandle(GetCurrentProcess(), process, GetCurrentProcess(),
                             &pin->process, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
          free(pin);
          certified = FALSE;
          good = FALSE;
        } else {
          pin->pid = entry.th32ProcessID;
          pin->parent = entry.th32ParentProcessID;
          pin->birth = birth;
          pin->parent_birth = parent_birth;
          pin->next = r->console_pins;
          r->console_pins = pin;
        }
      }
      members[parent_count++] = member;
      if (!normalized_known) {
        good = FALSE;
        api_error("descendant full image path",
                  image_known ? GetLastError() : image_error);
      }
      if (console) {
        ++measurement->consoles;
        consoles[index] = TRUE;
        if (live && !certified)
          good = FALSE;
        /* An exited parent's certified console settles naturally. The retained
           handle pins its identity; there is no PID-only wait or termination.
         */
        if (settling && live && certified &&
            WaitForSingleObject(pinned[index], 0) == WAIT_OBJECT_0) {
          ULONGLONG now = GetTickCount64();
          DWORD remaining = now < deadline ? (DWORD)(deadline - now) : 0;
          DWORD waited = WaitForSingleObject(process, remaining);
          printf(
              "CLEANUP_CONSOLE_WAIT pid=%lu parent=%lu certified=1 "
              "limit_ms=%u wait=%lu exited=%d termination_authority=job_only\n",
              (unsigned long)entry.th32ProcessID,
              (unsigned long)entry.th32ParentProcessID, WAIT_MS,
              (unsigned long)waited, waited == WAIT_OBJECT_0);
          if (waited != WAIT_OBJECT_0)
            good = FALSE;
        }
      } else {
        ++measurement->others;
        FILETIME birth, exit, kernel, user;
        BOOL identified =
            entry.th32ProcessID == r->reply.descendant &&
            GetProcessTimes(process, &birth, &exit, &kernel, &user) &&
            !memcmp(&birth, &r->reply.descendant_time, sizeof(birth));
        measurement->others_identified =
            measurement->others_identified && identified;
      }
      printf("PARENT_DESCENDANT pid=%lu member=%d live=%d image=%ls "
             "image_error=%lu console=%d termination_authority=job_only\n",
             (unsigned long)entry.th32ProcessID, member, live,
             image_known ? image : L"UNKNOWN", (unsigned long)image_error,
             console);
      if (!good)
        break;
    }
  }
  free(after.entries);
  for (unsigned i = 1; i < parent_count; ++i)
    CloseHandle(pinned[i]);
  return good;
}
static void pin_run_consoles(run *r) {
  if (!r->process.pi.hProcess)
    return;
  descendant_measurement measurement;
  HANDLE job = r->outer_job ? r->outer_job : r->process.job;
  BOOL certified = measure_descendants(r, job, &measurement, FALSE);
  printf("CLEANUP_PREFLIGHT parent=%lu snapshot_certified=%d consoles=%u "
         "outside=%u\n",
         (unsigned long)r->process.pi.dwProcessId, certified,
         measurement.consoles, measurement.outside);
  /* This does not certify emptiness or suppress the definitive cleanup check.
     Always release the fixture barrier, even on a failed preflight. */
}
static BOOL dispose_run(run *r) {
  BOOL good = TRUE;
  if (r->process.pi.hProcess) {
    descendant_measurement descendants = {0};
    HANDLE containment = r->outer_job ? r->outer_job : r->process.job;
    if (!measure_descendants(r, containment, &descendants, TRUE) ||
        descendants.outside) {
      printf("CLEANUP FAIL: unattributed live descendant; NOT terminated; "
             "manual review required\n");
      good = FALSE;
    }
    if (r->outer_job && !TerminateJobObject(r->outer_job, 124)) {
      api_error("TerminateJobObject(harness outer)", GetLastError());
      good = FALSE;
    }
    if (r->process.job && !TerminateJobObject(r->process.job, 124)) {
      api_error("TerminateJobObject(cleanup)", GetLastError());
      good = FALSE;
    }
    /* Tras TerminateJobObject el proceso ya esta saliendo: TerminateProcess
       sobre un proceso en terminacion devuelve ERROR_ACCESS_DENIED (medido el
       10-oct). Se espera a que salga antes de recurrir a TerminateProcess. */
    DWORD settle = (r->outer_job || r->process.job) ? WAIT_MS : 0;
    if (WaitForSingleObject(r->process.pi.hProcess, settle) != WAIT_OBJECT_0) {
      if (!TerminateProcess(r->process.pi.hProcess, 124)) {
        api_error("TerminateProcess(own fixture)", GetLastError());
        good = FALSE;
      }
    }
    if (WaitForSingleObject(r->process.pi.hProcess, WAIT_MS) != WAIT_OBJECT_0)
      good = FALSE;
    HANDLE jobs[] = {r->process.job, r->outer_job};
    for (unsigned i = 0; i < 2; ++i) {
      if (!jobs[i])
        continue;
      ULONGLONG deadline = GetTickCount64() + WAIT_MS;
      JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {0};
      do {
        if (!QueryInformationJobObject(jobs[i],
                                       JobObjectBasicAccountingInformation,
                                       &info, sizeof(info), NULL)) {
          good = FALSE;
          break;
        }
        if (!info.ActiveProcesses)
          break;
        Sleep(5);
      } while (GetTickCount64() < deadline);
      if (info.ActiveProcesses)
        good = FALSE;
    }
    ULONGLONG console_deadline = GetTickCount64() + WAIT_MS;
    for (console_pin *pin = r->console_pins; pin; pin = pin->next) {
      ULONGLONG now = GetTickCount64();
      DWORD remaining =
          now < console_deadline ? (DWORD)(console_deadline - now) : 0;
      DWORD waited = WaitForSingleObject(pin->process, remaining);
      printf("CLEANUP_CONSOLE_FINAL pid=%lu parent=%lu wait=%lu exited=%d\n",
             (unsigned long)pin->pid, (unsigned long)pin->parent,
             (unsigned long)waited, waited == WAIT_OBJECT_0);
      if (waited != WAIT_OBJECT_0)
        good = FALSE;
    }
  }
  BOOL stdout_valid = capture_remaining(
      r->out_read, "stdout", r->process.pi.dwProcessId, r->exact_stdio);
  BOOL stderr_valid = capture_remaining(
      r->err_read, "stderr", r->process.pi.dwProcessId, r->exact_stdio);
  r->output_exact = stdout_valid && stderr_valid;
  /* An exact-output mismatch is a test failure, not a live-tree proof failure.
     The dedicated stdio assertion consumes this result after cleanup. */
  if (!r->exact_stdio && !r->output_exact)
    good = FALSE;
  close_handle(&r->process.pi.hThread);
  close_handle(&r->process.pi.hProcess);
  close_handle(&r->process.job);
  close_handle(&r->outer_job);
  close_handle(&r->before);
  while (r->console_pins) {
    console_pin *pin = r->console_pins;
    r->console_pins = pin->next;
    close_handle(&pin->process);
    free(pin);
  }
  free(r->before_ids);
  r->before_ids = NULL;
  close_handle(&r->in_write);
  close_handle(&r->out_read);
  close_handle(&r->err_read);
  close_handle(&r->witness);
  close_handle(&r->excluded);
  good = good && !r->process.cleanup_error;
  if (!good && r->owner) {
    r->owner->blocked = TRUE;
    r->owner->unsafe_cleanup = TRUE;
    printf("CLEANUP BLOCKED: process/tree not certified empty; fixture "
           "descriptors will not be restored\n");
  }
  return good;
}
static BOOL probe(suite *s, run *r, BOOL ordinary, unsigned op,
                  const WCHAR *object, uintptr_t a, uintptr_t b) {
  WCHAR arguments[CAP * 2];
  if (!fmt(arguments, CAP * 2, L"act %u \"%ls\" %llu %llu", op, object,
           (unsigned long long)a, (unsigned long long)b))
    return FALSE;
  BOOL good = launch_run(s, r, ordinary, s->child, arguments, FALSE);
  return good && exchange(r, op);
}

/* Child data are diagnostics/barriers. The parent checks file, registry,
   memory, kernel state and Job membership before assigning a case result. */
static BOOL child_read(HANDLE pipe, void *bytes, DWORD count) {
  DWORD size = 0;
  return ReadFile(pipe, bytes, count, &size, NULL) && size == count;
}
static void child_wait(void) {
  BYTE release;
  if (!child_read(GetStdHandle(STD_INPUT_HANDLE), &release, 1))
    ExitProcess(121);
}
static int child_act(int argc, WCHAR **argv) {
  if (argc != 8)
    return 120;
  unsigned op = (unsigned)wcstoul(argv[2], NULL, 10);
  const WCHAR *object = argv[3];
  uintptr_t a = (uintptr_t)_wcstoui64(argv[4], NULL, 10),
            b = (uintptr_t)_wcstoui64(argv[5], NULL, 10);
  HANDLE witness = (HANDLE)(uintptr_t)_wcstoui64(argv[6], NULL, 10);
  HANDLE excluded = (HANDLE)(uintptr_t)_wcstoui64(argv[7], NULL, 10);
  packet reply = {0};
  reply.magic = MAGIC;
  reply.pid = GetCurrentProcessId();
  reply.operation = op;
  reply.attempted = 1;
  WCHAR self[CAP], path[CAP];
  GetModuleFileNameW(NULL, self, CAP);
  HANDLE held = NULL, second = NULL;
  if (op == OP_EARLY) {
    static const BYTE marker[] = "FIRST_ACT";
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    si.cb = sizeof(si);
    if (!fmt(path, CAP, L"\"%ls\" linger", self) ||
        !CreateProcessW(self, path, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL,
                        NULL, &si, &pi))
      return 119;
    FILETIME x, y, z;
    reply.descendant = pi.dwProcessId;
    if (!GetProcessTimes(pi.hProcess, &reply.descendant_time, &x, &y, &z))
      return 119;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (!file_bytes(object, marker, sizeof(marker), TRUE) ||
        !write_all(GetStdHandle(STD_OUTPUT_HANDLE), &reply, sizeof(reply)) ||
        !SetEvent(witness))
      return 119;
    Sleep(INFINITE);
  }
  if (!child_read(GetStdHandle(STD_INPUT_HANDLE), reply.nonce,
                  sizeof(reply.nonce)))
    return 118;
  SetLastError(ERROR_SUCCESS);
  switch (op) {
  case OP_WRITE:
    reply.opened = file_bytes(object, reply.nonce, sizeof(reply.nonce), TRUE);
    reply.error = reply.opened ? 0 : GetLastError();
    break;
  case OP_READ: {
    BYTE buffer[16];
    DWORD done = 0;
    HANDLE file =
        CreateFileW(object, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE)
      reply.error = GetLastError();
    else {
      reply.opened = ReadFile(file, buffer, sizeof(buffer), &done, NULL) &&
                     done == sizeof(buffer);
      if (reply.opened)
        memcpy(reply.read_bytes, buffer, sizeof(buffer));
      else
        reply.error = GetLastError();
      CloseHandle(file);
    }
    break;
  }
  case OP_RUNTIME_WRITE: {
    HANDLE file =
        CreateFileW(object, FILE_READ_DATA | FILE_WRITE_DATA,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    reply.opened = file != INVALID_HANDLE_VALUE;
    reply.error = reply.opened ? 0 : GetLastError();
    if (reply.opened) {
      BYTE byte;
      DWORD done = 0;
      LARGE_INTEGER zero = {0};
      /* Same byte: a successful write proves the defect without corrupting
         the private interpreter used by subsequent measurements. */
      if (!ReadFile(file, &byte, 1, &done, NULL) || done != 1 ||
          !SetFilePointerEx(file, zero, NULL, FILE_BEGIN) ||
          !WriteFile(file, &byte, 1, &done, NULL) || done != 1)
        reply.secondary_error = GetLastError();
      CloseHandle(file);
    }
    break;
  }
  case OP_PRIVATE_REG:
  case OP_REG_READ:
    child_private_registry(&reply, object, op == OP_REG_READ);
    break;
  case OP_NETWORK:
    child_network(&reply, object, (unsigned)b);
    break;
  case OP_RUNTIME_EXEC:
    child_runtime_exec(&reply, object, a != 0);
    break;
  case OP_REG: {
    HKEY key = NULL;
    LSTATUS error =
        RegOpenKeyExW(HKEY_CURRENT_USER, object, 0, KEY_SET_VALUE, &key);
    reply.error = error;
    if (!error) {
      reply.opened = 1;
      reply.error = RegSetValueExW(key, L"marker", 0, REG_BINARY, reply.nonce,
                                   sizeof(reply.nonce));
      RegCloseKey(key);
    }
    break;
  }
  case OP_VM: {
    HANDLE process = OpenProcess(PROCESS_VM_WRITE, FALSE, (DWORD)a);
    reply.opened = process != NULL;
    reply.error = process ? 0 : GetLastError();
    if (process)
      CloseHandle(process);
    process =
        OpenProcess(PROCESS_VM_WRITE | PROCESS_VM_OPERATION, FALSE, (DWORD)a);
    if (process) {
      SIZE_T bytes = 0;
      if (!WriteProcessMemory(process, (void *)b, reply.nonce,
                              sizeof(reply.nonce), &bytes) ||
          bytes != sizeof(reply.nonce))
        reply.secondary_error = GetLastError();
      CloseHandle(process);
    } else
      reply.secondary_error = GetLastError();
    break;
  }
  case OP_QUERY: {
    HANDLE process =
        OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)a);
    reply.opened = process != NULL;
    reply.error = process ? 0 : GetLastError();
    if (process)
      CloseHandle(process);
    break;
  }
  case OP_EVENT_FULL: {
    UNICODE_STRING name;
    name.Buffer = (PWSTR)object;
    name.Length = (USHORT)(wcslen(object) * sizeof(WCHAR));
    name.MaximumLength = name.Length;
    OBJECT_ATTRIBUTES attributes;
    InitializeObjectAttributes(&attributes, &name, OBJ_CASE_INSENSITIVE, NULL,
                               NULL);
    typedef NTSTATUS(NTAPI * open_event_fn)(PHANDLE, ACCESS_MASK,
                                            POBJECT_ATTRIBUTES);
    open_event_fn open_event = (open_event_fn)GetProcAddress(
        GetModuleHandleW(L"ntdll.dll"), "NtOpenEvent");
    if (!open_event) {
      reply.error = ERROR_PROC_NOT_FOUND;
      break;
    }
    NTSTATUS status = open_event(&held, EVENT_MODIFY_STATE, &attributes);
    reply.opened = status >= 0;
    reply.error = status >= 0 ? 0 : RtlNtStatusToDosError(status);
    if (held && !SetEvent(held))
      reply.secondary_error = GetLastError();
    break;
  }
  case OP_TERMINATE: {
    HANDLE process = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)a);
    reply.opened = process != NULL;
    reply.error = process ? 0 : GetLastError();
    if (process) {
      if (!TerminateProcess(process, 37))
        reply.secondary_error = GetLastError();
      CloseHandle(process);
    }
    break;
  }
  case OP_EVENT:
    held = OpenEventW(EVENT_MODIFY_STATE, FALSE, object);
    reply.opened = held != NULL;
    reply.error = held ? 0 : GetLastError();
    if (held && !SetEvent(held))
      reply.secondary_error = GetLastError();
    break;
  case OP_MUTEX: {
    held = OpenMutexW(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, object);
    reply.opened = held != NULL;
    reply.error = held ? 0 : GetLastError();
    if (held) {
      DWORD wait = WaitForSingleObject(held, 0);
      if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED)
        reply.handle = (uintptr_t)held;
      else
        reply.secondary_error = wait;
    }
    break;
  }
  case OP_PIPE:
    held = CreateFileW(object, GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                       SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, NULL);
    if (held == INVALID_HANDLE_VALUE) {
      held = NULL;
      reply.error = GetLastError();
    } else {
      reply.opened = 1;
      if (!write_all(held, reply.nonce, sizeof(reply.nonce)))
        reply.secondary_error = GetLastError();
    }
    break;
  case OP_STDIO:
    reply.opened = write_all(GetStdHandle(STD_ERROR_HANDLE), reply.nonce,
                             sizeof(reply.nonce));
    reply.error = reply.opened ? 0 : GetLastError();
    break;
  case OP_BREAKAWAY:
  case OP_TREE: {
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    si.cb = sizeof(si);
    if (!fmt(path, CAP, L"\"%ls\" linger", self))
      return 117;
    DWORD flags =
        CREATE_NO_WINDOW | (op == OP_BREAKAWAY ? CREATE_BREAKAWAY_FROM_JOB : 0);
    BOOL spawned = CreateProcessW(self, path, NULL, NULL, FALSE, flags, NULL,
                                  NULL, &si, &pi);
    reply.opened = spawned;
    reply.error = spawned ? 0 : GetLastError();
    if (spawned) {
      FILETIME x, y, z;
      reply.descendant = pi.dwProcessId;
      if (!GetProcessTimes(pi.hProcess, &reply.descendant_time, &x, &y, &z))
        reply.secondary_error = GetLastError();
      CloseHandle(pi.hThread);
      held = pi.hProcess;
    }
    break;
  }
  case OP_HANDLES:
    reply.opened = SetEvent(excluded);
    reply.error = reply.opened ? 0 : GetLastError();
    if (!SetEvent(witness))
      reply.secondary_error = GetLastError();
    break;
  case OP_DEFAULT:
    held = CreateEventW(NULL, TRUE, FALSE, object);
    reply.error = held ? 0 : GetLastError();
    reply.opened = held != NULL;
    reply.handle = (uintptr_t)held;
    if (held && GetLastError() == ERROR_ALREADY_EXISTS) {
      CloseHandle(held);
      held = NULL;
      reply.opened = 0;
      reply.handle = 0;
      reply.error = ERROR_ALREADY_EXISTS;
    }
    break;
  case OP_WINSTA:
    held = (HANDLE)OpenWindowStationW(L"WinSta0", FALSE, WINSTA_READATTRIBUTES);
    reply.error = held ? 0 : GetLastError();
    reply.opened = held != NULL;
    reply.handle = (uintptr_t)held;
    second =
        (HANDLE)OpenWindowStationW(L"WinSta0", FALSE, WINSTA_ACCESSCLIPBOARD);
    reply.secondary_error = second ? 0 : GetLastError();
    reply.second_handle = (uintptr_t)second;
    break;
  case OP_INHERIT:
    if (!fmt(path, CAP, L"%ls\\inherited.bin", object))
      return 116;
    reply.opened = file_bytes(path, reply.nonce, sizeof(reply.nonce), TRUE);
    if (!reply.opened)
      reply.error = GetLastError();
    if (!fmt(path, CAP, L"%ls\\inherited-dir", object))
      return 116;
    if (!CreateDirectoryW(path, NULL))
      reply.secondary_error = GetLastError();
    break;
  case OP_WIDEN: {
    held = open_dir(object, WRITE_DAC | WRITE_OWNER | READ_CONTROL);
    if (held == INVALID_HANDLE_VALUE) {
      reply.error = GetLastError();
      held = NULL;
    } else {
      PSECURITY_DESCRIPTOR sd = NULL;
      reply.opened = 1;
      if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
              L"D:P(A;;GA;;;WD)S:(ML;;NW;;;ME)", SDDL_REVISION_1, &sd, NULL)) {
        if (!SetKernelObjectSecurity(
                held, DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION,
                sd))
          reply.secondary_error = GetLastError();
        LocalFree(sd);
      } else
        reply.secondary_error = GetLastError();
    }
    break;
  }
  default:
    return 115;
  }
  if (!write_all(GetStdHandle(STD_OUTPUT_HANDLE), &reply, sizeof(reply)))
    return 114;
  child_wait();
  if (op == OP_STDIO) {
    BYTE extra;
    DWORD got = 0;
    BOOL read = ReadFile(GetStdHandle(STD_INPUT_HANDLE), &extra, 1, &got, NULL);
    if ((read && got != 0) || (!read && GetLastError() != ERROR_BROKEN_PIPE))
      return 111;
  }
  if ((op == OP_TREE || op == OP_BREAKAWAY) && held) {
    /* This is the exact handle returned by this fixture's CreateProcessW. */
    if (!TerminateProcess(held, 123) ||
        WaitForSingleObject(held, WAIT_MS) != WAIT_OBJECT_0)
      return 113;
  }
  if (op == OP_MUTEX && reply.handle && !ReleaseMutex(held))
    return 113;
  if (op == OP_WINSTA) {
    if (held && !CloseWindowStation((HWINSTA)held))
      return 112;
    if (second && !CloseWindowStation((HWINSTA)second))
      return 112;
  } else if (held)
    CloseHandle(held);
  return 0;
}

static BOOL identity_matches(HANDLE handle, const FILE_ID_INFO *expected,
                             DWORD *attributes) {
  FILE_ID_INFO actual;
  BY_HANDLE_FILE_INFORMATION info;
  FILE_STANDARD_INFO standard;
  BOOL good =
      GetFileInformationByHandle(handle, &info) &&
      GetFileInformationByHandleEx(handle, FileStandardInfo, &standard,
                                   sizeof(standard)) &&
      standard.NumberOfLinks == 1 &&
      GetFileInformationByHandleEx(handle, FileIdInfo, &actual,
                                   sizeof(actual)) &&
      actual.VolumeSerialNumber == expected->VolumeSerialNumber &&
      !memcmp(&actual.FileId, &expected->FileId, sizeof(actual.FileId)) &&
      !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
  if (good && attributes)
    *attributes = info.dwFileAttributes;
  if (!good)
    SetLastError(ERROR_FILE_INVALID);
  return good;
}
static BOOL dispose_file(HANDLE handle, const FILE_ID_INFO *expected) {
  if (!identity_matches(handle, expected, NULL))
    return FALSE;
  FILE_DISPOSITION_INFO_EX deletion = {FILE_DISPOSITION_FLAG_DELETE |
                                       FILE_DISPOSITION_FLAG_POSIX_SEMANTICS};
  if (SetFileInformationByHandle(handle, FileDispositionInfoEx, &deletion,
                                 sizeof(deletion)))
    return TRUE;
  DWORD error = GetLastError();
  if (error != ERROR_INVALID_PARAMETER && error != ERROR_INVALID_FUNCTION &&
      error != ERROR_NOT_SUPPORTED && error != ERROR_CALL_NOT_IMPLEMENTED)
    return FALSE;
  FILE_DISPOSITION_INFO legacy = {TRUE};
  return identity_matches(handle, expected, NULL) &&
         SetFileInformationByHandle(handle, FileDispositionInfo, &legacy,
                                    sizeof(legacy));
}
static HANDLE open_cleanup_child(HANDLE parent,
                                 const FILE_ID_BOTH_DIR_INFO *entry,
                                 DWORD extra_access) {
  typedef NTSTATUS(NTAPI * open_file_fn)(
      PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK, ULONG, ULONG);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  open_file_fn open_file =
      ntdll ? (open_file_fn)GetProcAddress(ntdll, "NtOpenFile") : NULL;
  if (!open_file) {
    SetLastError(ERROR_PROC_NOT_FOUND);
    return INVALID_HANDLE_VALUE;
  }
  UNICODE_STRING name = {0};
  name.Length = (USHORT)entry->FileNameLength;
  name.MaximumLength = name.Length;
  name.Buffer = (WCHAR *)entry->FileName;
  OBJECT_ATTRIBUTES object = {0};
  object.Length = sizeof(object);
  object.RootDirectory = parent;
  object.ObjectName = &name;
  IO_STATUS_BLOCK io = {0};
  HANDLE child = NULL;
  BOOL directory = (entry->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  NTSTATUS status = open_file(
      &child,
      DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE |
          (directory ? FILE_LIST_DIRECTORY : 0) | extra_access,
      &object, &io, FILE_SHARE_READ,
      FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT |
          (directory ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE));
  if (status < 0) {
    printf("CLEANUP NtOpenFile(relative child) NTSTATUS=0x%08lx\n",
           (unsigned long)status);
    SetLastError(RtlNtStatusToDosError(status));
    return INVALID_HANDLE_VALUE;
  }
  return child;
}
static BOOL cleanup_tree(HANDLE retained, const FILE_ID_INFO *expected,
                         unsigned depth) {
  DWORD attributes = 0;
  if (depth > 64 || !identity_matches(retained, expected, &attributes) ||
      !(attributes & FILE_ATTRIBUTE_DIRECTORY))
    return FALSE;
  /* Enumeration, single-component opens and deletion stay anchored to pinned
     parent/child handles; renaming an ancestor cannot redirect this traversal.
   */
  union {
    ULONGLONG alignment;
    BYTE bytes[4096];
  } buffer;
  FILE_INFO_BY_HANDLE_CLASS query = FileIdBothDirectoryRestartInfo;
  for (;;) {
    if (!identity_matches(retained, expected, NULL))
      return FALSE;
    if (!GetFileInformationByHandleEx(retained, query, buffer.bytes,
                                      sizeof(buffer.bytes))) {
      if (GetLastError() != ERROR_NO_MORE_FILES)
        return FALSE;
      break;
    }
    BOOL removed = FALSE;
    for (size_t offset = 0;;) {
      size_t header = offsetof(FILE_ID_BOTH_DIR_INFO, FileName);
      size_t available = sizeof(buffer.bytes) - offset;
      if (available < header)
        return FALSE;
      const FILE_ID_BOTH_DIR_INFO *entry =
          (const FILE_ID_BOTH_DIR_INFO *)(buffer.bytes + offset);
      DWORD length = entry->FileNameLength;
      if (!length || length > available - header || length > 65534 ||
          length % sizeof(WCHAR))
        return FALSE;
      size_t chars = length / sizeof(WCHAR);
      BOOL dot = entry->FileName[0] == L'.' &&
                 (chars == 1 || (chars == 2 && entry->FileName[1] == L'.'));
      for (size_t i = 0; i < chars; ++i)
        if (!entry->FileName[i] || entry->FileName[i] == L'\\' ||
            entry->FileName[i] == L'/' || entry->FileName[i] == L':')
          return FALSE;
      if (entry->NextEntryOffset &&
          (entry->NextEntryOffset < header + length ||
           entry->NextEntryOffset > available - header ||
           entry->NextEntryOffset % sizeof(ULONGLONG)))
        return FALSE;
      if (!dot) {
        if (!identity_matches(retained, expected, NULL) ||
            (entry->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
          return FALSE;
        HANDLE child = open_cleanup_child(retained, entry, 0);
        FILE_ID_INFO identity;
        BY_HANDLE_FILE_INFORMATION info;
        DWORD child_attributes = 0;
        BOOL good =
            child != INVALID_HANDLE_VALUE &&
            GetFileInformationByHandle(child, &info) &&
            (((ULONGLONG)info.nFileIndexHigh << 32) | info.nFileIndexLow) ==
                (ULONGLONG)entry->FileId.QuadPart &&
            GetFileInformationByHandleEx(child, FileIdInfo, &identity,
                                         sizeof(identity)) &&
            identity.VolumeSerialNumber == expected->VolumeSerialNumber &&
            identity_matches(child, &identity, &child_attributes) &&
            ((child_attributes ^ entry->FileAttributes) &
             (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0;
        if (good && (child_attributes & FILE_ATTRIBUTE_DIRECTORY))
          good = cleanup_tree(child, &identity, depth + 1);
        else if (good)
          good = identity_matches(retained, expected, NULL) &&
                 dispose_file(child, &identity);
        if (child != INVALID_HANDLE_VALUE && !CloseHandle(child))
          good = FALSE;
        if (!good)
          return FALSE;
        removed = TRUE;
      }
      if (!entry->NextEntryOffset)
        break;
      offset += entry->NextEntryOffset;
    }
    /* Restart after deletion so changes to NTFS enumeration order skip nothing.
     */
    query = removed ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo;
  }
  return dispose_file(retained, expected);
}
static BOOL hash_file_digest(HANDLE file, const char *name, BYTE *output) {
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_HASH_HANDLE hash = NULL;
  DWORD length = 0, got = 0;
  BYTE digest[32], buffer[65536];
  BOOL good = FALSE;
  BYTE *object = NULL;
  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) !=
          0 ||
      BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH, (BYTE *)&length,
                        sizeof(length), &got, 0) != 0)
    goto done;
  object = calloc(1, length);
  if (!object || BCryptCreateHash(alg, &hash, object, length, NULL, 0, 0) != 0)
    goto done;
  LARGE_INTEGER zero;
  zero.QuadPart = 0;
  if (!SetFilePointerEx(file, zero, NULL, FILE_BEGIN))
    goto done;
  for (;;) {
    if (!ReadFile(file, buffer, sizeof(buffer), &got, NULL))
      goto done;
    if (!got)
      break;
    if (BCryptHashData(hash, buffer, got, 0) != 0)
      goto done;
  }
  if (BCryptFinishHash(hash, digest, sizeof(digest), 0) != 0)
    goto done;
  printf("BINARY name=%s SHA256=", name);
  for (unsigned i = 0; i < sizeof(digest); ++i)
    printf("%02x", digest[i]);
  printf("\n");
  if (output)
    memcpy(output, digest, sizeof(digest));
  good = TRUE;
done:
  if (hash)
    BCryptDestroyHash(hash);
  if (alg)
    BCryptCloseAlgorithmProvider(alg, 0);
  free(object);
  return good;
}
static BOOL hash_file(HANDLE file, const char *name) {
  return hash_file_digest(file, name, NULL);
}
/* Deliberately wrong restoration, selected only by the label mutation.
   All cleanup and every other restoration continue to use the kernel API. */
static BOOL restore_auto_inherit(const snapshot *snap) {
  PSID owner = NULL, group = NULL;
  PACL dacl = NULL, sacl = NULL;
  BOOL present, def;
  SECURITY_DESCRIPTOR_CONTROL control;
  DWORD revision;
  ACL empty;
  if (!GetSecurityDescriptorOwner(snap->sd, &owner, &def) ||
      !GetSecurityDescriptorGroup(snap->sd, &group, &def) ||
      !GetSecurityDescriptorDacl(snap->sd, &present, &dacl, &def) ||
      !GetSecurityDescriptorSacl(snap->sd, &present, &sacl, &def) ||
      !GetSecurityDescriptorControl(snap->sd, &control, &revision) ||
      !InitializeAcl(&empty, sizeof(empty), ACL_REVISION))
    return FALSE;
  DWORD code =
      SetSecurityInfo(snap->handle, snap->type,
                      SD_INFO | ((control & SE_DACL_PROTECTED)
                                     ? PROTECTED_DACL_SECURITY_INFORMATION
                                     : UNPROTECTED_DACL_SECURITY_INFORMATION),
                      owner, group, dacl, sacl ? sacl : &empty);
  if (code != ERROR_SUCCESS) {
    api_error("SetSecurityInfo(label mutation only)", code);
    SetLastError(code);
    return FALSE;
  }
  return snapshot_equal(snap);
}
static BOOL label_roundtrip(suite *s) {
  BOOL all = TRUE;
  DWORD error = ERROR_SUCCESS;
  for (int initial = -1; initial <= 1; initial += 2) {
    WCHAR path[CAP];
    snapshot snap = {0};
    PSECURITY_DESCRIPTOR low = NULL;
    if (!fmt(path, CAP, L"%ls\\roundtrip-%d", s->root, initial) ||
        !create_dir(s, path, FALSE, initial, &snap)) {
      error = GetLastError();
      snapshot_dispose(&snap);
      all = FALSE;
      break;
    }
    BOOL initial_verified = initial < 0
                                ? label_absent(snap.handle)
                                : label_is(snap.handle, SE_FILE_OBJECT,
                                           SECURITY_MANDATORY_MEDIUM_RID);
    BOOL good =
        initial_verified && make_sd(s, FALSE, 0, TRUE, &low) &&
        set_sd(snap.handle, SE_FILE_OBJECT, low, FALSE) &&
        label_is(snap.handle, SE_FILE_OBJECT, SECURITY_MANDATORY_LOW_RID);
    DWORD lower_error = good ? ERROR_SUCCESS : GetLastError();
    BOOL restored = s->mutation == SEC5_RESTORE_AUTO_INHERIT
                        ? restore_auto_inherit(&snap)
                        : restore(&snap);
    DWORD restore_error = restored ? ERROR_SUCCESS : GetLastError();
    printf("ROUNDTRIP initial=%s lowered=%d restored_semantic_exact=%d\n",
           initial < 0 ? "ABSENT" : "EXPLICIT_MEDIUM", good, restored);
    all = all && good && restored;
    if (!good || !restored)
      error = !good ? lower_error : restore_error;
    /* Repair the deliberately changed descriptor before disposing our fixture.
       The measured mutation verdict remains red. */
    BOOL repaired = TRUE;
    if (s->mutation == SEC5_RESTORE_AUTO_INHERIT && !restored) {
      repaired = restore(&snap);
      printf("LABEL_MUTATION kernel_cleanup_semantic_exact=%d\n", repaired);
      if (!repaired)
        error = GetLastError();
    }
    if (low)
      LocalFree(low);
    snapshot_dispose(&snap);
    if (!RemoveDirectoryW(path)) {
      api_error("RemoveDirectoryW(roundtrip)", GetLastError());
      error = GetLastError();
      all = FALSE;
    }
    if (!repaired)
      all = FALSE;
    if (!restored) {
      s->blocked = TRUE;
      printf("P1 BLOCKED exact standard-user label restoration; no elevation "
             "or other credentials\n");
      break;
    }
  }
  result(s, 22, all,
         "ABSENT and EXPLICIT_MEDIUM -> LOW -> exact "
         "OWNER/GROUP/DACL/effective LABEL; SACL_CONTROL_DIFF recorded; "
         "retained FileId");
  if (!all)
    SetLastError(error ? error : ERROR_INVALID_SECURITY_DESCR);
  return all;
}
static BOOL make_private_child_sd(suite *s, PSECURITY_DESCRIPTOR *sd) {
  WCHAR text[2048];
  return fmt(text, 2048,
             L"O:%lsG:%lsD:P(A;;GA;;;%ls)(A;;GA;;;SY)(A;;RC;;;OW)(A;;"
             L"0x001200a9;;"
             L";%ls)",
             s->user_text, s->user_text, s->user_text, s->sid_text) &&
         ConvertStringSecurityDescriptorToSecurityDescriptorW(
             text, SDDL_REVISION_1, sd, NULL);
}
static BOOL copy_private_child(suite *s, const WCHAR *source) {
  PSECURITY_DESCRIPTOR sd = NULL;
  if (!make_private_child_sd(s, &sd))
    return FALSE;
  /* Sin etiqueta LW: un ejecutable etiquetado bajo arranca en integridad baja
     por NEW_PROCESS_MIN incluso con token ordinario, y el control positivo
     dejaria de ser medio (medido el 10-oct: ORDINARY_CHILD_TOKEN IL=4096).
     Leer y ejecutar un objeto medio desde baja integridad ya esta permitido. */
  /* Copy only bytes, never source security properties/unknown auditing ACEs. */
  HANDLE input = CreateFileW(source, GENERIC_READ, FILE_SHARE_READ, NULL,
                             OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  SECURITY_ATTRIBUTES sa = {sizeof(sa), sd, FALSE};
  HANDLE output = input == INVALID_HANDLE_VALUE
                      ? INVALID_HANDLE_VALUE
                      : CreateFileW(s->child, GENERIC_WRITE, 0, &sa, CREATE_NEW,
                                    FILE_ATTRIBUTE_NORMAL, NULL);
  LocalFree(sd);
  BOOL good = input != INVALID_HANDLE_VALUE && output != INVALID_HANDLE_VALUE;
  BYTE bytes[65536];
  DWORD count = 0, written = 0;
  while (good) {
    if (!ReadFile(input, bytes, sizeof(bytes), &count, NULL)) {
      good = FALSE;
      break;
    }
    if (!count)
      break;
    if (!WriteFile(output, bytes, count, &written, NULL) || written != count)
      good = FALSE;
  }
  if (good && !FlushFileBuffers(output))
    good = FALSE;
  if (input != INVALID_HANDLE_VALUE && !CloseHandle(input))
    good = FALSE;
  if (output != INVALID_HANDLE_VALUE && !CloseHandle(output))
    good = FALSE;
  return good;
}
static BOOL registry_owner(HKEY key) {
  WCHAR owner[32] = L"";
  DWORD type = 0, size = sizeof(owner);
  return RegQueryValueExW(key, L"owner", NULL, &type, (BYTE *)owner, &size) ==
             ERROR_SUCCESS &&
         type == REG_SZ && size == sizeof(L"sec5-fixture") &&
         !memcmp(owner, L"sec5-fixture", sizeof(L"sec5-fixture"));
}
/* NtDeleteKey borra la clave del handle ya comprobado (abierto con DELETE),
   no un nombre que pueda haberse sustituido entre la comprobacion y el borrado
 (el segundo auditor, auditoria estatica R3). */
static LSTATUS delete_key_by_handle(HKEY key) {
  typedef LONG(NTAPI * delete_key_fn)(HANDLE);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  delete_key_fn delete_key =
      ntdll ? (delete_key_fn)GetProcAddress(ntdll, "NtDeleteKey") : NULL;
  if (!delete_key)
    return ERROR_PROC_NOT_FOUND;
  LONG nt = delete_key((HANDLE)key);
  if (nt < 0) {
    printf("NtDeleteKey NTSTATUS=0x%08lx\n", (unsigned long)nt);
    return ERROR_GEN_FAILURE;
  }
  return ERROR_SUCCESS;
}
static BOOL cleanup_registry_fixture(suite *s) {
  HKEY software = NULL, named = NULL;
  WCHAR name[128];
  LSTATUS status = ERROR_SUCCESS;
  if (!registry_owner(s->key)) {
    printf("HKCU CLEANUP STOP: retained key lacks owner=sec5-fixture; "
           "nothing deleted; MANUAL REVIEW=%ls\n",
           s->reg_path);
    return FALSE;
  }
  if (!fmt(name, 128, L"DevAgents-SEC5-%ls", s->guid))
    return FALSE;
  status = RegOpenKeyExW(HKEY_CURRENT_USER, L"Software", 0,
                         KEY_ENUMERATE_SUB_KEYS | DELETE, &software);
  if (status)
    goto done;
  status = RegOpenKeyExW(software, name, 0, KEY_QUERY_VALUE, &named);
  if (status)
    goto done;
  if (!registry_owner(named) || !registry_owner(s->key)) {
    status = ERROR_INVALID_DATA;
    goto done;
  }
  status = RegCloseKey(named);
  named = NULL;
  if (status)
    goto done;
  status = RegDeleteTreeW(s->key, NULL);
  if (status)
    goto done;
  /* La marca ya se comprobo sobre este mismo handle: se borra el objeto, no
     el nombre. */
  status = delete_key_by_handle(s->key);
  {
    LSTATUS closed = RegCloseKey(s->key);
    s->key = NULL;
    if (!status)
      status = closed;
  }
done:
  if (status) {
    api_error("HKCU handle-anchored fixture cleanup", (DWORD)status);
    printf("HKCU CLEANUP STOP: name/owner/API discrepancy; no further "
           "deletion; MANUAL REVIEW=%ls\n",
           s->reg_path);
  }
  if (named) {
    LSTATUS closed = RegCloseKey(named);
    if (!status)
      status = closed;
  }
  if (software) {
    LSTATUS closed = RegCloseKey(software);
    if (!status)
      status = closed;
  }
  return status == ERROR_SUCCESS;
}
static BOOL recover_registry_fixtures(void) {
  HKEY software = NULL;
  LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, L"Software", 0,
                                 KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE |
                                     KEY_CREATE_SUB_KEY | DELETE,
                                 &software);
  if (status)
    return FALSE;
  BOOL good = TRUE;
  for (DWORD index = 0; good;) {
    WCHAR name[512];
    DWORD length = 512;
    status =
        RegEnumKeyExW(software, index, name, &length, NULL, NULL, NULL, NULL);
    if (status == ERROR_NO_MORE_ITEMS)
      break;
    if (status) {
      good = FALSE;
      break;
    }
    ++index;
    if (wcsncmp(name, L"DevAgents-SEC5-", wcslen(L"DevAgents-SEC5-")))
      continue;
    HKEY key = NULL;
    status = RegOpenKeyExW(software, name, 0,
                           KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS |
                               KEY_SET_VALUE | DELETE,
                           &key);
    if (status) {
      good = FALSE;
      break;
    }
    BOOL marked = registry_owner(key);
    /* Preserve another running fixture. A dead/missing recorded owner is an
       orphan; a reused live PID only postpones recovery, never authorizes it.
     */
    DWORD pid = 0, type = 0, size = sizeof(pid);
    BOOL live = FALSE;
    if (marked &&
        RegQueryValueExW(key, L"owner_pid", NULL, &type, (BYTE *)&pid, &size) ==
            ERROR_SUCCESS &&
        type == REG_DWORD && size == sizeof(pid) && pid) {
      HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
      if (process) {
        live = WaitForSingleObject(process, 0) != WAIT_OBJECT_0;
        CloseHandle(process);
      } else if (GetLastError() != ERROR_INVALID_PARAMETER)
        live = TRUE; /* Unknown ownership lifetime: leave it for review. */
    }
    if (marked && !live) {
      printf("HKCU_RECOVERY orphan=%ls owner=sec5-fixture\n", name);
      status = RegDeleteTreeW(key, NULL);
      if (!status)
        status = delete_key_by_handle(key);
      RegCloseKey(key);
      key = NULL;
      if (status) {
        api_error("HKCU marked orphan cleanup", (DWORD)status);
        good = FALSE;
      } else
        --index;
    }
    if (key)
      RegCloseKey(key);
  }
  RegCloseKey(software);
  return good;
}
/* These profiles belong only to this ephemeral fixture, not production leases.
   Durable recovery is deliberately reserved for round 3. */
static BOOL create_profile(suite *s) {
  DWORD random[4];
  if (!random_bytes(random, sizeof(random)) ||
      !fmt(s->profile, 64, L"DevAgents.Sec5.%08lx%08lx%08lx%08lx",
           (unsigned long)random[0], (unsigned long)random[1],
           (unsigned long)random[2], (unsigned long)random[3]))
    return FALSE;
  HRESULT hr = CreateAppContainerProfile(
      s->profile, s->profile, L"SEC5 round 1 fixture", NULL, 0, &s->lease);
  printf("PROFILE_CREATE moniker=%ls HRESULT=0x%08lx\n", s->profile,
         (unsigned long)hr);
  if (FAILED(hr)) {
    SetLastError(HRESULT_CODE(hr));
    return FALSE;
  }
  s->profile_created = TRUE;
  LPWSTR text = NULL;
  if (!ConvertSidToStringSidW(s->lease, &text))
    return FALSE;
  BOOL good = fmt(s->sid_text, 256, L"%ls", text);
  hr = GetAppContainerFolderPath(text, &s->profile_path);
  LocalFree(text);
  printf("PROFILE_STORAGE HRESULT=0x%08lx SID=%ls path=%ls\n",
         (unsigned long)hr, s->sid_text,
         s->profile_path ? s->profile_path : L"unavailable");
  if (FAILED(hr))
    SetLastError(HRESULT_CODE(hr));
  return good && SUCCEEDED(hr);
}
static BOOL set_dacl(HANDLE object, PACL acl, BOOL defaulted,
                     SECURITY_DESCRIPTOR_CONTROL control) {
  SECURITY_DESCRIPTOR descriptor;
  const SECURITY_DESCRIPTOR_CONTROL mask =
      SE_DACL_PROTECTED | SE_DACL_AUTO_INHERITED | SE_DACL_AUTO_INHERIT_REQ;
  SECURITY_DESCRIPTOR_CONTROL requested = control & mask;
  /* The kernel consumes AUTO_INHERIT_REQ. AUTO_INHERITED alone converts the
     supplied inherited ACEs to explicit ACEs and drops AI (0x0400). */
  if (control & SE_DACL_AUTO_INHERITED)
    requested |= SE_DACL_AUTO_INHERIT_REQ;
  return checked_api(InitializeSecurityDescriptor(&descriptor,
                                                  SECURITY_DESCRIPTOR_REVISION),
                     "InitializeSecurityDescriptor", "DACL descriptor") &&
         checked_api(
             SetSecurityDescriptorDacl(&descriptor, TRUE, acl, defaulted),
             "SetSecurityDescriptorDacl", "DACL descriptor") &&
         checked_api(SetSecurityDescriptorControl(&descriptor, mask, requested),
                     "SetSecurityDescriptorControl", "DACL control") &&
         checked_api(SetKernelObjectSecurity(object, DACL_SECURITY_INFORMATION,
                                             &descriptor),
                     "SetKernelObjectSecurity", "DACL grant");
}
static BOOL grant_package(HANDLE object, PSID package, DWORD rights,
                          BOOL inherit) {
  PSECURITY_DESCRIPTOR original = NULL;
  PACL acl = NULL, updated = NULL;
  BOOL present, def;
  if (!kernel_sd(object, DACL_SECURITY_INFORMATION, &original))
    return FALSE;
  BOOL good =
      checked_api(GetSecurityDescriptorDacl(original, &present, &acl, &def),
                  "GetSecurityDescriptorDacl", "grant original");
  if (good && (!present || !acl))
    good = cycle_api_fail("GetSecurityDescriptorDacl", "missing grant DACL",
                          ERROR_INVALID_SECURITY_DESCR);
  EXPLICIT_ACCESSW entry = {0};
  entry.grfAccessPermissions = rights;
  entry.grfAccessMode = GRANT_ACCESS;
  entry.grfInheritance =
      inherit ? SUB_CONTAINERS_AND_OBJECTS_INHERIT : NO_INHERITANCE;
  entry.Trustee.TrusteeForm = TRUSTEE_IS_SID;
  entry.Trustee.ptstrName = (LPWSTR)package;
  DWORD error =
      good ? SetEntriesInAclW(1, &entry, acl, &updated) : GetLastError();
  if (good && error != ERROR_SUCCESS)
    good = cycle_api_fail("SetEntriesInAclW", "package grant", error);
  SECURITY_DESCRIPTOR_CONTROL control;
  DWORD revision;
  good =
      good &&
      checked_api(GetSecurityDescriptorControl(original, &control, &revision),
                  "GetSecurityDescriptorControl", "grant original") &&
      set_dacl(object, updated, def, control);
  PSECURITY_DESCRIPTOR actual = NULL;
  PACL readback = NULL;
  SECURITY_DESCRIPTOR_CONTROL actual_control;
  if (good)
    good = kernel_sd(object, DACL_SECURITY_INFORMATION, &actual) &&
           checked_api(
               GetSecurityDescriptorControl(actual, &actual_control, &revision),
               "GetSecurityDescriptorControl", "grant readback") &&
           checked_api(
               GetSecurityDescriptorDacl(actual, &present, &readback, &def),
               "GetSecurityDescriptorDacl", "grant readback");
  if (good &&
      (actual_control != control || !present || !dacl_equal(updated, readback)))
    good = cycle_api_fail("grant_package.readback", "exact DACL/control",
                          ERROR_INVALID_SECURITY_DESCR);
  error = good ? ERROR_SUCCESS : GetLastError();
  if (actual)
    LocalFree(actual);
  if (updated)
    LocalFree(updated);
  LocalFree(original);
  SetLastError(error);
  return good;
}
static BOOL setup(suite *s, const WCHAR *child) {
  DWORD random[4], volume_flags = 0, serial = 0;
  WCHAR base[CAP], volume[CAP], filesystem[256], volume_guid[256],
      system_volume[CAP], system_path[CAP];
  if (!recover_registry_fixtures() || !random_bytes(random, sizeof(random)) ||
      !GetCurrentDirectoryW(CAP, base))
    return FALSE;
  DWORD env_length = GetEnvironmentVariableW(L"SEC5_FIXTURE_BASE", base, CAP);
  if (env_length >= CAP)
    return FALSE;
  if (!env_length && !GetCurrentDirectoryW(CAP, base))
    return FALSE;
  if (!GetWindowsDirectoryW(system_path, CAP) ||
      !GetVolumePathNameW(system_path, system_volume, CAP) ||
      !GetVolumePathNameW(base, volume, CAP) ||
      _wcsicmp(volume, system_volume) || GetDriveTypeW(volume) != DRIVE_FIXED ||
      !GetVolumeInformationW(volume, NULL, 0, &serial, NULL, &volume_flags,
                             filesystem, 256) ||
      _wcsicmp(filesystem, L"NTFS") || !(volume_flags & FILE_PERSISTENT_ACLS) ||
      !GetVolumeNameForVolumeMountPointW(volume, volume_guid, 256)) {
    printf(
        "P1 BLOCKED volume must be local fixed NTFS; no ACL/label changes\n");
    s->blocked = TRUE;
    return FALSE;
  }
  printf("VOLUME path=%ls guid=%ls serial=%lu fs=%ls flags=0x%lx "
         "type=DRIVE_FIXED\n",
         volume, volume_guid, (unsigned long)serial, filesystem,
         (unsigned long)volume_flags);
  random[1] = (random[1] & 0xffff0fffu) | 0x00004000u;
  random[2] = (random[2] & 0x3fffffffu) | 0x80000000u;
  if (!fmt(s->guid, 128, L"%08lx-%04lx-%04lx-%04lx-%04lx%08lx",
           (unsigned long)random[0], (unsigned long)(random[1] >> 16),
           (unsigned long)(random[1] & 0xffffu),
           (unsigned long)(random[2] >> 16),
           (unsigned long)(random[2] & 0xffffu), (unsigned long)random[3]) ||
      !fmt(s->sid_text, 256, L"S-1-5-21-%lu-%lu-%lu-%lu",
           (unsigned long)random[0], (unsigned long)random[1],
           (unsigned long)random[2], (unsigned long)random[3]) ||
      !(s->backend == SEC5_APPCONTAINER
            ? create_profile(s)
            : ConvertStringSidToSidW(s->sid_text, &s->lease)) ||
      !ConvertStringSidToSidW(s->user_text, &s->user) ||
      !fmt(s->root, CAP, L"%ls\\.sec5-fixture-%ls", base, s->guid) ||
      !create_dir(s, s->root, FALSE, -1, &s->root_sd))
    return FALSE;
  printf("FIXTURE_ROOT path=%ls LEASE_SID=%ls\n", s->root, s->sid_text);
  /* Read-only volume handle, used solely to reopen the newly created root
     by its 128-bit FileId. No volume ACL/label or real directory is changed. */
  size_t guid_length = wcslen(volume_guid);
  if (!guid_length || volume_guid[guid_length - 1] != L'\\')
    return FALSE;
  volume_guid[guid_length - 1] = 0;
  HANDLE volume_handle =
      CreateFileW(volume_guid, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                  OPEN_EXISTING, 0, NULL);
  if (volume_handle == INVALID_HANDLE_VALUE)
    return FALSE;
  FILE_ID_DESCRIPTOR file_id = {0};
  file_id.dwSize = sizeof(file_id);
  file_id.Type = ExtendedFileIdType;
  file_id.ExtendedFileId = s->root_sd.identity.FileId;
  HANDLE reopened =
      OpenFileById(volume_handle, &file_id, READ_CONTROL | FILE_READ_ATTRIBUTES,
                   FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                   FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
  CloseHandle(volume_handle);
  FILE_ID_INFO reopened_id;
  BOOL id_matches =
      reopened != INVALID_HANDLE_VALUE &&
      GetFileInformationByHandleEx(reopened, FileIdInfo, &reopened_id,
                                   sizeof(reopened_id)) &&
      reopened_id.VolumeSerialNumber ==
          s->root_sd.identity.VolumeSerialNumber &&
      !memcmp(&reopened_id.FileId, &s->root_sd.identity.FileId,
              sizeof(reopened_id.FileId));
  if (reopened != INVALID_HANDLE_VALUE)
    CloseHandle(reopened);
  printf("FILE_ID reopen_by_id=%d\n", id_matches);
  if (!id_matches)
    return FALSE;
  if (s->backend == SEC5_RESTRICTED_DIAGNOSTIC && !label_roundtrip(s)) {
    s->blocked = TRUE;
    return FALSE;
  }
  if (!fmt(s->dest, CAP, L"%ls\\prepared", s->root) ||
      !fmt(s->medium, CAP, L"%ls\\medium", s->root) ||
      !fmt(s->foreign, CAP, L"%ls\\foreign-low", s->root) ||
      !fmt(s->read_file, CAP, L"%ls\\readable.bin", s->root) ||
      !fmt(s->child, CAP, L"%ls\\sec5-child.exe", s->root) ||
      !fmt(s->original_child, CAP, L"%ls", child))
    return FALSE;
  if (!create_dir(s, s->dest, FALSE, s->backend == SEC5_APPCONTAINER ? -1 : 1,
                  &s->dest_sd) ||
      !create_dir(s, s->medium, FALSE, 1, &s->medium_sd) ||
      !create_dir(s, s->foreign, FALSE, s->backend == SEC5_APPCONTAINER ? 0 : 1,
                  &s->foreign_sd))
    return FALSE;
  if (s->backend == SEC5_APPCONTAINER) {
    if (!grant_package(s->root_sd.handle, s->lease,
                       FILE_GENERIC_READ | FILE_GENERIC_EXECUTE, FALSE) ||
        !grant_package(s->dest_sd.handle, s->lease,
                       s->mutation == SEC5_DEST_RX_ONLY
                           ? FILE_GENERIC_READ | FILE_GENERIC_EXECUTE
                           : 0x001201ff,
                       TRUE) ||
        !copy_private_child(s, child))
      return FALSE;
    s->child_pin =
        CreateFileW(s->child, GENERIC_READ, FILE_SHARE_READ, NULL,
                    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (s->child_pin == INVALID_HANDLE_VALUE ||
        !hash_file(s->child_pin, "AppContainer private fixture executable") ||
        !random_bytes(s->read_nonce, sizeof(s->read_nonce)) ||
        !file_bytes(s->read_file, s->read_nonce, sizeof(s->read_nonce), TRUE))
      return FALSE;
    if (s->mutation == SEC5_EXTERIOR_GRANT) {
      HANDLE file =
          CreateFileW(s->read_file, READ_CONTROL | WRITE_DAC, FILE_SHARE_READ,
                      NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
      BOOL widened =
          file != INVALID_HANDLE_VALUE &&
          grant_package(file, s->lease, FILE_GENERIC_READ, FALSE) &&
          grant_package(s->medium_sd.handle, s->lease, 0x001201ff, TRUE);
      if (file != INVALID_HANDLE_VALUE)
        CloseHandle(file);
      if (!widened)
        return FALSE;
    }
    if (!s->runtime_matrix)
      return TRUE;
    BOOL present = FALSE, def = FALSE;
    if (!make_default_sd(s, &s->default_sd) ||
        !GetSecurityDescriptorDacl(s->default_sd, &present, &s->default_dacl,
                                   &def) ||
        !present || !s->default_dacl)
      return FALSE;
    goto registry_setup;
  }
  PSECURITY_DESCRIPTOR low = NULL, medium = NULL, foreign = NULL;
  BOOL good = make_sd(s, TRUE, 0, TRUE, &low) &&
              make_sd(s, TRUE, 1, TRUE, &medium) &&
              make_sd(s, FALSE, 0, TRUE, &foreign);
  if (good) {
    HANDLE reduced = open_dir(s->dest, READ_CONTROL | FILE_READ_ATTRIBUTES);
    BOOL denied = reduced != INVALID_HANDLE_VALUE &&
                  !set_sd(reduced, SE_FILE_OBJECT, low, FALSE) &&
                  GetLastError() == ERROR_ACCESS_DENIED &&
                  snapshot_equal(&s->dest_sd);
    if (reduced != INVALID_HANDLE_VALUE)
      CloseHandle(reduced);
    result(
        s, 23, denied,
        "SetKernelObjectSecurity LABEL on handle without WRITE_OWNER denied; "
        "original descriptor unchanged");
    good = denied && set_sd(s->dest_sd.handle, SE_FILE_OBJECT, low, TRUE) &&
           set_sd(s->medium_sd.handle, SE_FILE_OBJECT, medium, TRUE) &&
           set_sd(s->foreign_sd.handle, SE_FILE_OBJECT, foreign, TRUE) &&
           label_is(s->dest_sd.handle, SE_FILE_OBJECT,
                    SECURITY_MANDATORY_LOW_RID) &&
           label_is(s->medium_sd.handle, SE_FILE_OBJECT,
                    SECURITY_MANDATORY_MEDIUM_RID) &&
           label_is(s->foreign_sd.handle, SE_FILE_OBJECT,
                    SECURITY_MANDATORY_LOW_RID);
  }
  if (low)
    LocalFree(low);
  if (medium)
    LocalFree(medium);
  if (foreign)
    LocalFree(foreign);
  if (!good || !make_default_sd(s, &s->default_sd))
    return FALSE;
  BOOL present, def;
  if (!GetSecurityDescriptorDacl(s->default_sd, &present, &s->default_dacl,
                                 &def) ||
      !present || !s->default_dacl || !copy_private_child(s, child))
    return FALSE;
  s->child_pin = CreateFileW(s->child, GENERIC_READ, FILE_SHARE_READ, NULL,
                             OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (s->child_pin == INVALID_HANDLE_VALUE ||
      !hash_file(s->child_pin, "sec5-child retained private copy"))
    return FALSE;
  if (!random_bytes(s->read_nonce, sizeof(s->read_nonce)) ||
      !file_bytes(s->read_file, s->read_nonce, sizeof(s->read_nonce), TRUE))
    return FALSE;
registry_setup:;
  PSECURITY_DESCRIPTOR reg_sd = NULL;
  if (!fmt(s->reg_path, 512, L"Software\\DevAgents-SEC5-%ls", s->guid) ||
      !make_sd(s, !s->runtime_matrix, 1, FALSE, &reg_sd))
    return FALSE;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), reg_sd, FALSE};
  DWORD disposition = 0;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, s->reg_path, 0, NULL,
                                   REG_OPTION_VOLATILE, KEY_ALL_ACCESS, &sa,
                                   &s->key, &disposition);
  LocalFree(reg_sd);
  if (status || disposition != REG_CREATED_NEW_KEY) {
    api_error("RegCreateKeyExW(new fixture)",
              status ? (DWORD)status : ERROR_ALREADY_EXISTS);
    if (s->key) {
      RegCloseKey(s->key);
      s->key = NULL;
    }
    return FALSE;
  }
  s->key_created = TRUE;
  DWORD owner_pid = GetCurrentProcessId();
  status = RegSetValueExW(s->key, L"owner_pid", 0, REG_DWORD,
                          (const BYTE *)&owner_pid, sizeof(owner_pid));
  if (!status)
    status =
        RegSetValueExW(s->key, L"owner", 0, REG_SZ,
                       (const BYTE *)L"sec5-fixture", sizeof(L"sec5-fixture"));
  if (status) {
    api_error("HKCU fixture ownership marker", (DWORD)status);
    return FALSE;
  }
  return label_is((HANDLE)s->key, SE_REGISTRY_KEY,
                  SECURITY_MANDATORY_MEDIUM_RID);
}
static BOOL storage_absent(const WCHAR *path) {
  if (!path || GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES)
    return FALSE;
  DWORD error = GetLastError();
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}
static BOOL finish(suite *s) {
  BOOL good = !s->unsafe_cleanup;
  BOOL root_identity_known = s->root_sd.sd != NULL;
  close_handle(&s->child_pin);
  if (s->key && s->key_created) {
    if (!cleanup_registry_fixture(s))
      good = FALSE;
    if (s->key) {
      LSTATUS code = RegCloseKey(s->key);
      if (code) {
        good = FALSE;
        api_error("RegCloseKey(own fixture)", (DWORD)code);
      }
      s->key = NULL;
    }
  }
  snapshot *snapshots[] = {&s->dest_sd, &s->medium_sd, &s->foreign_sd,
                           &s->root_sd};
  if (s->unsafe_cleanup)
    printf("RESTORE BLOCKED: tree may still be live; fixture retained=%ls\n",
           s->root);
  for (unsigned i = 0; !s->unsafe_cleanup && i < 4; ++i)
    if (snapshots[i]->sd) {
      if (!restore(snapshots[i])) {
        good = FALSE;
        s->blocked = TRUE;
        printf("P1 BLOCKED final descriptor restoration index=%u; fixture "
               "retained for diagnosis\n",
               i);
      }
    }
  s->labels_restored = good;
  /* Close subordinate snapshots, but keep the original root DELETE handle
     pinned without WRITE/DELETE sharing through traversal and disposition. */
  for (unsigned i = 0; i < 3; ++i)
    snapshot_dispose(snapshots[i]);
  if (s->root_created && !root_identity_known)
    good = FALSE;
  if (good && s->root_created)
    good = cleanup_tree(s->root_sd.handle, &s->root_sd.identity, 0);
  if (!good && s->root_created) {
    s->blocked = TRUE;
    printf("CLEANUP STOP: identity/reparse/link-count/restoration discrepancy; "
           "root left "
           "for MANUAL REVIEW=%ls\n",
           s->root);
  }
  snapshot_dispose(&s->root_sd);
  if (s->default_sd)
    LocalFree(s->default_sd);
  if (s->profile_created && good) {
    HRESULT hr = DeleteAppContainerProfile(s->profile);
    BOOL absent = storage_absent(s->profile_path);
    printf("PROFILE_DELETE moniker=%ls HRESULT=0x%08lx storage_absent=%d\n",
           s->profile, (unsigned long)hr, absent);
    if (FAILED(hr) || !absent)
      good = FALSE;
  } else if (s->profile_created)
    printf("PROFILE_DELETE BLOCKED tree/ACL cleanup incomplete moniker=%ls\n",
           s->profile);
  if (s->profile_path)
    CoTaskMemFree(s->profile_path);
  if (s->lease) {
    if (s->backend == SEC5_APPCONTAINER)
      FreeSid(s->lease);
    else
      LocalFree(s->lease);
  }
  if (s->user)
    LocalFree(s->user);
  printf("CLEANUP success=%d exact_descriptors=%d fixture=%ls\n", good,
         s->labels_restored, s->root);
  return good;
}
static BOOL file_case(suite *s, unsigned id, const WCHAR *directory,
                      BOOL expected) {
  WCHAR path[CAP];
  snapshot boundary = {0};
  BOOL boundary_taken =
      snapshot_take(&boundary, s->root_sd.handle, SE_FILE_OBJECT, TRUE);
  if (!fmt(path, CAP, L"%ls\\marker-%u.bin", directory, id)) {
    if (boundary.sd)
      LocalFree(boundary.sd);
    return FALSE;
  }
  run control = {0}, sandbox = {0};
  BOOL positive = probe(s, &control, TRUE, OP_WRITE, path, 0, 0) &&
                  file_bytes(path, control.nonce, sizeof(control.nonce), FALSE);
  BOOL control_done = release_run(&control);
  BOOL cleaned = dispose_run(&control);
  BOOL removed = DeleteFileW(path);
  BOOL attempted = positive && control_done && cleaned && removed &&
                   probe(s, &sandbox, FALSE, OP_WRITE, path, 0, 0);
  BOOL exists = GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
  BOOL effect = expected ? (exists && file_bytes(path, sandbox.nonce,
                                                 sizeof(sandbox.nonce), FALSE))
                         : !exists;
  BOOL denied = expected || (sandbox.reply.error == ERROR_ACCESS_DENIED &&
                             !sandbox.reply.opened);
  BOOL ended = sandbox.complete && release_run(&sandbox);
  BOOL clean_s = dispose_run(&sandbox);
  if (exists && !DeleteFileW(path))
    clean_s = FALSE;
  BOOL boundary_intact =
      boundary_taken && snapshot_equal(&boundary) &&
      file_bytes(s->read_file, s->read_nonce, sizeof(s->read_nonce), FALSE);
  printf("FILE_BOUNDARY id=%u root_SD_unchanged=%d "
         "private_input_nonce_unchanged=%d\n",
         id, boundary_taken && snapshot_equal(&boundary),
         file_bytes(s->read_file, s->read_nonce, sizeof(s->read_nonce), FALSE));
  if (boundary.sd)
    LocalFree(boundary.sd); /* Borrowed root handle remains pinned. */
  result(s, id,
         positive && attempted && effect && denied && ended && clean_s &&
             boundary_intact,
         "ordinary control same fixture; parent checks marker bytes/absence; "
         "child attempt barrier required");
  return !s->blocked;
}
static void stdio_and_token(suite *s) {
  run ordinary = {0}, sandbox = {0};
  BYTE bytes[16];
  BOOL control = probe(s, &ordinary, TRUE, OP_STDIO, L"-", 0, 0) &&
                 read_deadline(ordinary.err_read, bytes, sizeof(bytes)) &&
                 !memcmp(bytes, ordinary.nonce, sizeof(bytes));
  HANDLE ordinary_token = NULL;
  BOOL ordinary_effective =
      control && OpenProcessToken(ordinary.process.pi.hProcess, TOKEN_QUERY,
                                  &ordinary_token);
  TOKEN_MANDATORY_LABEL *label =
      ordinary_effective ? token_info(ordinary_token, TokenIntegrityLevel)
                         : NULL;
  TOKEN_GROUPS *restricted =
      ordinary_effective ? token_info(ordinary_token, TokenRestrictedSids)
                         : NULL;
  DWORD il =
      label
          ? *GetSidSubAuthority(label->Label.Sid,
                                *GetSidSubAuthorityCount(label->Label.Sid) - 1)
          : 0;
  ordinary_effective = ordinary_effective && label && restricted &&
                       il == SECURITY_MANDATORY_MEDIUM_RID &&
                       !restricted->GroupCount &&
                       !IsTokenRestricted(ordinary_token);
  printf("ORDINARY_CHILD_TOKEN pid=%lu IL=%lu restricting_sids=%lu "
         "effective_control=%d\n",
         (unsigned long)ordinary.process.pi.dwProcessId, (unsigned long)il,
         restricted ? (unsigned long)restricted->GroupCount : 0,
         ordinary_effective);
  free(label);
  free(restricted);
  close_handle(&ordinary_token);
  BOOL control_end = release_run(&ordinary);
  ordinary.exact_stdio = TRUE;
  BOOL control_clean = dispose_run(&ordinary);
  BOOL sandbox_ok = probe(s, &sandbox, FALSE, OP_STDIO, L"-", 0, 0);
  BOOL token = sandbox_ok && s->token_ok;
  result(s, 1,
         control && ordinary_effective && control_end && control_clean && token,
         "parent queries suspended child's effective token/privileges/Job; "
         "ordinary control is medium");
  BOOL stderr_ok = sandbox_ok &&
                   read_deadline(sandbox.err_read, bytes, sizeof(bytes)) &&
                   !memcmp(bytes, sandbox.nonce, sizeof(bytes));
  BOOL sandbox_end = sandbox.complete && release_run(&sandbox);
  sandbox.exact_stdio = TRUE;
  BOOL sandbox_clean = dispose_run(&sandbox);
  result(s, 15,
         control && control_end && control_clean && ordinary.output_exact &&
             stderr_ok && sandbox_end && sandbox_clean && sandbox.output_exact,
         "stdin nonce -> exact stdout packet and separate stderr nonce; "
         "EOF/exit; MCP/LSP/ConPTY not measured");
}
static void read_case(suite *s) {
  BOOL good[2] = {FALSE, FALSE};
  for (unsigned i = 0; i < 2; ++i) {
    run r = {0};
    WCHAR arguments[CAP * 2];
    if (!fmt(arguments, CAP * 2, L"act %u \"%ls\" 0 0", OP_READ, s->read_file))
      break;
    BOOL launched = launch_run(s, &r, i == 0, s->child, arguments, FALSE);
    BOOL reply =
        launched && exchange(&r, OP_READ) &&
        ((s->backend == SEC5_APPCONTAINER && i == 1)
             ? (!r.reply.opened && r.reply.error == ERROR_ACCESS_DENIED &&
                !memcmp(r.reply.read_bytes, (BYTE[16]){0}, 16))
             : (r.reply.opened && !memcmp(r.reply.read_bytes, s->read_nonce,
                                          sizeof(s->read_nonce))));
    BOOL ended = r.complete && release_run(&r);
    BOOL cleaned = dispose_run(&r);
    good[i] = reply && ended && cleaned;
    if (s->blocked)
      break;
  }
  result(s, 5, good[0] && good[1],
         "same medium read-only nonce fixture without lease ACE; parent "
         "compares bytes from stdout");
}
static void registry_case(suite *s) {
  BOOL good = TRUE;
  for (unsigned i = 0; i < 2; ++i) {
    run r = {0};
    BYTE bytes[16];
    DWORD size = sizeof(bytes), type = 0;
    BOOL attempted = probe(s, &r, i == 0, OP_REG, s->reg_path, 0, 0);
    LSTATUS status =
        RegQueryValueExW(s->key, L"marker", NULL, &type, bytes, &size);
    BOOL observed =
        i == 0
            ? (!status && type == REG_BINARY && size == sizeof(bytes) &&
               !memcmp(bytes, r.nonce, size))
            : (status == ERROR_FILE_NOT_FOUND &&
               (r.reply.error == ERROR_ACCESS_DENIED ||
                (s->runtime_matrix && r.reply.error == ERROR_FILE_NOT_FOUND)) &&
               !r.reply.opened);
    BOOL ended = r.complete && release_run(&r);
    BOOL cleaned = dispose_run(&r);
    good = good && attempted && observed && ended && cleaned;
    if (i == 0 && RegDeleteValueW(s->key, L"marker"))
      good = FALSE;
    if (s->blocked)
      break;
  }
  result(s, 6, good,
         "parent RegQueryValueEx on own volatile GUID key; medium LABEL + "
         "ordinary/lease DACL; virtualization disabled");
}
static BOOL observed_descendant(const packet *reply, HANDLE parent,
                                FILETIME expected_parent, HANDLE *handle) {
  *handle = NULL;
  if (!reply->descendant)
    return FALSE;
  FILETIME parent_birth, parent_exit, kernel, user;
  if (!reply->pid || GetProcessId(parent) != reply->pid ||
      !GetProcessTimes(parent, &parent_birth, &parent_exit, &kernel, &user) ||
      !sec5_same_instance(reply->pid, parent_birth, reply->pid,
                          expected_parent))
    return FALSE;
  sec5_process_table table;
  if (!sec5_process_snapshot(&table))
    return FALSE;
  BOOL parent_match = FALSE;
  for (unsigned i = 0; i < table.count; ++i) {
    const sec5_process_entry *entry = &table.entries[i];
    if (sec5_same_instance(entry->pid, entry->birth, reply->descendant,
                           reply->descendant_time)) {
      int classification =
          sec5_descendant_classify(entry->parent, entry->birth, reply->pid,
                                   parent_birth, parent_exit, TRUE);
      parent_match = classification == 1;
      if (classification == 0)
        printf("DESCENDANT_DISCARD pid=%lu parent=%lu "
               "reason=outside_parent_lifetime_or_parent_mismatch opened=0\n",
               (unsigned long)entry->pid, (unsigned long)entry->parent);
      break;
    }
  }
  free(table.entries);
  if (!parent_match)
    return FALSE;
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                               FALSE, reply->descendant);
  FILETIME time, a, b, c;
  if (!process)
    return FALSE;
  if (!GetProcessTimes(process, &time, &a, &b, &c) ||
      memcmp(&time, &reply->descendant_time, sizeof(time))) {
    CloseHandle(process);
    return FALSE;
  }
  *handle = process;
  return TRUE;
}
static BOOL wait_observed(HANDLE process) {
  if (!process)
    return TRUE;
  BOOL good = WaitForSingleObject(process, WAIT_MS) == WAIT_OBJECT_0;
  if (!good)
    printf("CLEANUP FAIL: observed process still live; no ownership proof, NOT "
           "terminated\n");
  CloseHandle(process);
  return good;
}
static void process_cases(suite *s) {
  for (unsigned kind = 0; kind < (s->backend == SEC5_APPCONTAINER ? 3u : 2u);
       ++kind) {
    BOOL good = TRUE, actual_allowed = FALSE;
    DWORD sandbox_error = ERROR_GEN_FAILURE;
    for (unsigned i = 0; i < 2; ++i) {
      run target = {0}, attacker = {0};
      packet target_packet;
      BOOL created = launch_run(s, &target, TRUE, s->child, L"target", FALSE) &&
                     read_deadline(target.out_read, &target_packet,
                                   sizeof(target_packet)) &&
                     target_packet.magic == MAGIC &&
                     target_packet.pid == target.process.pi.dwProcessId;
      PSECURITY_DESCRIPTOR sd = NULL;
      if (created && kind == 0 && s->backend == SEC5_RESTRICTED_DIAGNOSTIC)
        created =
            make_sd(s, TRUE, 1, FALSE, &sd) &&
            set_sd(target.process.pi.hProcess, SE_KERNEL_OBJECT, sd, TRUE);
      if (sd)
        LocalFree(sd);
      BYTE before[16] = {0}, after[16] = {0};
      SIZE_T bytes = 0;
      if (created && kind == 0)
        created = ReadProcessMemory(target.process.pi.hProcess,
                                    (void *)target_packet.address, before,
                                    sizeof(before), &bytes) &&
                  bytes == sizeof(before) &&
                  !memcmp(before, target_packet.nonce, sizeof(before));
      unsigned op = kind == 0 ? OP_VM : kind == 1 ? OP_TERMINATE : OP_QUERY;
      BOOL attempted = created && probe(s, &attacker, i == 0, op, L"-",
                                        target.process.pi.dwProcessId,
                                        target_packet.address);
      BOOL effect = FALSE;
      if (attempted && kind == 0) {
        effect = ReadProcessMemory(target.process.pi.hProcess,
                                   (void *)target_packet.address, after,
                                   sizeof(after), &bytes) &&
                 bytes == sizeof(after);
        effect =
            effect &&
            (i == 0
                 ? (attacker.reply.opened && !attacker.reply.secondary_error &&
                    !memcmp(after, attacker.nonce, sizeof(after)))
                 : (!attacker.reply.opened &&
                    attacker.reply.error == ERROR_ACCESS_DENIED &&
                    attacker.reply.secondary_error == ERROR_ACCESS_DENIED &&
                    !memcmp(after, before, sizeof(after))));
      } else if (attempted && kind == 2) {
        effect = WaitForSingleObject(target.process.pi.hProcess, 0) ==
                     WAIT_TIMEOUT &&
                 (i == 0 ? attacker.reply.opened && !attacker.reply.error
                         : !attacker.reply.opened &&
                               attacker.reply.error == ERROR_ACCESS_DENIED);
      } else if (attempted) {
        DWORD wait = WaitForSingleObject(target.process.pi.hProcess,
                                         attacker.reply.opened ? WAIT_MS : 0);
        DWORD exit_code = STILL_ACTIVE;
        BOOL queried =
            GetExitCodeProcess(target.process.pi.hProcess, &exit_code);
        BOOL terminated = queried && wait == WAIT_OBJECT_0 && exit_code == 37 &&
                          attacker.reply.opened && !attacker.reply.error &&
                          !attacker.reply.secondary_error;
        BOOL denied = queried && wait == WAIT_TIMEOUT &&
                      exit_code == STILL_ACTIVE && !attacker.reply.opened &&
                      attacker.reply.error == ERROR_ACCESS_DENIED &&
                      !attacker.reply.secondary_error;
        effect = i == 0
                     ? terminated
                     : (s->backend == SEC5_APPCONTAINER ? denied
                                                        : terminated || denied);
        if (i == 1) {
          actual_allowed = terminated;
          sandbox_error = attacker.reply.error;
        }
        printf("PROCESS_TERMINATE ordinary=%d default_dacl=1 wait=%lu "
               "exit_code=%lu queried=%d opened=%lu win32=%lu "
               "secondary_error=%lu measurement_complete=%d\n",
               i == 0, (unsigned long)wait, (unsigned long)exit_code, queried,
               (unsigned long)attacker.reply.opened,
               (unsigned long)attacker.reply.error,
               (unsigned long)attacker.reply.secondary_error, effect);
      }
      BOOL ended = attacker.complete && release_run(&attacker);
      BOOL clean_a = dispose_run(&attacker), clean_t = dispose_run(&target);
      good = good && attempted && effect && ended && clean_a && clean_t;
      if (s->blocked)
        break;
    }
    if (kind == 1 && good && s->backend == SEC5_RESTRICTED_DIAGNOSTIC)
      observation(s, 8, actual_allowed, sandbox_error,
                  "PROCESS_TERMINATE; fresh ordinary user target with default "
                  "DACL; parent verifies exit code 37 or live denied target");
    else
      result(s,
             kind == 0   ? 7
             : kind == 1 ? 8
                         : 29,
             good,
             kind == 0
                 ? "OpenProcess(PROCESS_VM_WRITE) and VM_WRITE|VM_OPERATION; "
                   "parent ReadProcessMemory checks target nonce"
             : kind == 2
                 ? "ordinary QUERY_LIMITED positive; AppContainer denied 5 and "
                   "target live"
                 : "OpenProcess(PROCESS_TERMINATE); parent waits on own medium "
                   "target; controls use fresh targets");
    if (s->blocked)
      break;
  }
}

static HANDLE session_object(suite *s, unsigned op, const WCHAR *name,
                             BOOL authorized) {
  PSECURITY_DESCRIPTOR sd = NULL;
  if (!make_sd(s, authorized, authorized ? 0 : 1, FALSE, &sd))
    return NULL;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), sd, FALSE};
  HANDLE object = NULL;
  if (op == OP_EVENT)
    object = CreateEventW(&sa, TRUE, FALSE, name);
  else if (op == OP_MUTEX)
    object = CreateMutexW(&sa, FALSE, name);
  else
    object = CreateNamedPipeW(
        name, PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT |
            PIPE_REJECT_REMOTE_CLIENTS,
        1, 1024, 1024, WAIT_MS, &sa);
  DWORD error = GetLastError();
  LocalFree(sd);
  if (object == INVALID_HANDLE_VALUE)
    object = NULL;
  if (object && error == ERROR_ALREADY_EXISTS) {
    CloseHandle(object);
    object = NULL;
    error = ERROR_ALREADY_EXISTS;
  }
  if (!object)
    api_error("create unique session fixture", error);
  return object;
}
static BOOL pipe_effect(HANDLE pipe, const BYTE *expected, BOOL *connected) {
  BOOL connection = ConnectNamedPipe(pipe, NULL);
  DWORD error = connection ? 0 : GetLastError();
  *connected =
      connection || error == ERROR_PIPE_CONNECTED || error == ERROR_NO_DATA;
  BYTE received[16];
  DWORD count = 0;
  BOOL bytes = read_deadline(pipe, received, sizeof(received));
  if (bytes) {
    *connected = TRUE;
    count = sizeof(received);
  }
  printf("NAMED_PIPE connected=%d bytes=%lu connect_error=%lu\n", *connected,
         (unsigned long)count, (unsigned long)error);
  return bytes && !memcmp(received, expected, sizeof(received));
}
static BOOL pipe_listening(HANDLE pipe, const char *phase) {
  BOOL connected = ConnectNamedPipe(pipe, NULL);
  DWORD error = connected ? 0 : GetLastError();
  printf("NAMED_PIPE phase=%s connect_result=%d connect_error=%lu "
         "listening_without_client=%d\n",
         phase, connected, (unsigned long)error,
         !connected && error == ERROR_PIPE_LISTENING);
  return !connected && error == ERROR_PIPE_LISTENING;
}
static void session_cases(suite *s) {
  for (unsigned kind = 0; kind < 3; ++kind) {
    unsigned op = kind == 0 ? OP_EVENT : kind == 1 ? OP_MUTEX : OP_PIPE;
    WCHAR name[512];
    if (!fmt(name, 512,
             kind == 2 ? L"\\\\.\\pipe\\DevAgents-SEC5-%ls-%u"
                       : L"Local\\DevAgents-SEC5-%ls-%u",
             s->guid, kind)) {
      result(s, 9 + kind, FALSE, "name overflow");
      continue;
    }
    HANDLE object = session_object(s, op, name, FALSE);
    BOOL control_ok = object != NULL, actual_allowed = FALSE, measured = FALSE;
    DWORD sandbox_error = ERROR_GEN_FAILURE;
    snapshot original = {0};
    if (object)
      control_ok = snapshot_take(&original, object, SE_KERNEL_OBJECT, FALSE);
    for (unsigned i = 0; object && i < 2; ++i) {
      run r = {0};
      if (kind == 2 && i == 1)
        control_ok = pipe_listening(object, "before-isolated") && control_ok;
      BOOL attempted = control_ok && probe(s, &r, i == 0, op, name, 0, 0);
      BOOL effect = FALSE, observed = FALSE;
      if (attempted && kind == 0) {
        DWORD wait = WaitForSingleObject(object, 0);
        effect = wait == WAIT_OBJECT_0;
        observed = wait == WAIT_OBJECT_0 || wait == WAIT_TIMEOUT;
      } else if (attempted && kind == 1) {
        DWORD wait = WaitForSingleObject(object, 0);
        effect = wait == WAIT_TIMEOUT;
        observed = wait == WAIT_TIMEOUT || wait == WAIT_OBJECT_0 ||
                   wait == WAIT_ABANDONED;
        if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
          if (!ReleaseMutex(object))
            observed = FALSE;
        }
        printf("MUTEX parent_wait_while_child_holds=%lu\n",
               (unsigned long)wait);
      } else if (attempted) {
        BOOL connected = FALSE;
        /* PIPE_NOWAIT: denied opens are measured without waiting for
           bytes which cannot arrive. Successful opens need real data. */
        if (r.reply.opened)
          effect = pipe_effect(object, r.nonce, &connected);
        else
          observed = pipe_listening(object, "after-denied-open");
        observed = observed || effect;
      }
      BOOL reply_matches =
          effect
              ? (r.reply.opened && !r.reply.error && !r.reply.secondary_error)
              : (!r.reply.opened && (r.reply.error == ERROR_ACCESS_DENIED ||
                                     (s->runtime_matrix && kind < 2 &&
                                      r.reply.error == ERROR_FILE_NOT_FOUND)));
      BOOL ended = r.complete && release_run(&r);
      if (kind == 1 && object && ended) {
        DWORD post = WaitForSingleObject(object, 0);
        BOOL released = post == WAIT_OBJECT_0;
        if (post == WAIT_OBJECT_0 || post == WAIT_ABANDONED) {
          if (!ReleaseMutex(object))
            released = FALSE;
        }
        printf("MUTEX parent_wait_after_child_release=%lu\n",
               (unsigned long)post);
        ended = ended && released;
      }
      BOOL clean = dispose_run(&r);
      BOOL descriptor_equal = original.sd && snapshot_equal(&original);
      printf("SESSION_MEASUREMENT kind=%u ordinary=%d attempted=%d effect=%d "
             "observed=%d reply_matches=%d ended=%d clean=%d snap_equal=%d "
             "control_ok_before=%d opened=%lu win32=%lu secondary_error=%lu\n",
             kind, i == 0, attempted, effect, observed, reply_matches, ended,
             clean, descriptor_equal, control_ok, (unsigned long)r.reply.opened,
             (unsigned long)r.reply.error,
             (unsigned long)r.reply.secondary_error);
      if (i == 0)
        control_ok = control_ok && attempted && effect && observed &&
                     reply_matches && ended && clean && descriptor_equal;
      else {
        measured = attempted && observed && reply_matches && ended && clean &&
                   descriptor_equal;
        actual_allowed = effect;
        sandbox_error = r.reply.error;
      }
      if (kind == 0 && !ResetEvent(object))
        control_ok = FALSE;
      if (kind == 2 && r.reply.opened && !DisconnectNamedPipe(object)) {
        api_error("DisconnectNamedPipe", GetLastError());
        control_ok = FALSE;
      }
      if (s->blocked)
        break;
    }
    if (original.sd)
      LocalFree(original.sd);
    if (object)
      CloseHandle(object);
    if (control_ok && measured && s->runtime_matrix && kind < 2)
      result(s, 9 + kind, !actual_allowed,
             "ordinary object alive; positive control; AppContainer cannot "
             "interfere");
    else if (control_ok && measured)
      observation(
          s, 9 + kind, actual_allowed, sandbox_error,
          kind == 0 ? "EVENT_MODIFY_STATE; parent signal"
          : kind == 1
              ? "SYNCHRONIZE|MUTEX_MODIFY_STATE; parent wait and child release"
              : "GENERIC_WRITE; server connection and exact nonce");
    else
      result(s, 9 + kind, FALSE,
             "control/effect/attempt incomplete; no invented session outcome");
    if (s->blocked)
      return;
  }
  if (s->runtime_matrix) {
    run r = {0};
    BOOL attempted = probe(s, &r, FALSE, OP_HANDLES, L"-", 0, 0);
    BOOL effect = attempted && !r.reply.secondary_error &&
                  WaitForSingleObject(r.witness, 0) == WAIT_OBJECT_0;
    BOOL ended = r.complete && release_run(&r);
    BOOL cleaned = dispose_run(&r);
    result(s, 12, effect && ended && cleaned,
           "authorized event via exact inherited handle; parent verifies "
           "signal; no global IPC grant");
    return;
  }
  BOOL authorized = TRUE;
  for (unsigned kind = 0; kind < 2; ++kind) {
    unsigned op = kind == 0 ? OP_EVENT : OP_PIPE;
    WCHAR name[512];
    if (!fmt(name, 512,
             kind ? L"\\\\.\\pipe\\DevAgents-SEC5-%ls-authorized"
                  : L"Local\\DevAgents-SEC5-%ls-authorized",
             s->guid)) {
      authorized = FALSE;
      break;
    }
    HANDLE object = session_object(s, op, name, TRUE);
    run r = {0};
    BOOL attempted = object && probe(s, &r, FALSE, op, name, 0, 0);
    BOOL effect = FALSE, connected = FALSE;
    if (attempted)
      effect = kind ? pipe_effect(object, r.nonce, &connected)
                    : WaitForSingleObject(object, 0) == WAIT_OBJECT_0;
    BOOL ended = r.complete && release_run(&r);
    BOOL cleaned = dispose_run(&r);
    authorized = authorized && attempted && effect && ended && cleaned;
    if (object)
      CloseHandle(object);
    if (s->blocked)
      break;
  }
  result(s, 12, authorized,
         "new lease event and named pipe with explicit low SD; parent verifies "
         "signal/bytes");
}
static BOOL acl_has(PACL acl, PSID sid, DWORD rights) {
  if (!acl)
    return FALSE;
  for (DWORD i = 0; i < acl->AceCount; ++i) {
    ACCESS_ALLOWED_ACE *ace = NULL;
    if (!GetAce(acl, i, (void **)&ace))
      return FALSE;
    if (ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
        EqualSid(&ace->SidStart, sid) && (ace->Mask & rights) == rights)
      return TRUE;
  }
  return FALSE;
}
static void default_dacl_case(suite *s) {
  WCHAR name[512];
  run creator = {0}, other = {0};
  BOOL token_default_applied = FALSE, actual_allowed = FALSE;
  DWORD sandbox_error = ERROR_GEN_FAILURE;
  BOOL good = fmt(name, 512, L"Local\\DevAgents-SEC5-%ls-created", s->guid) &&
              probe(s, &creator, FALSE, OP_DEFAULT, name, 0, 0) &&
              creator.reply.opened && !creator.reply.error;
  HANDLE event =
      good ? OpenEventW(EVENT_MODIFY_STATE | READ_CONTROL | SYNCHRONIZE, FALSE,
                        name)
           : NULL;
  snapshot descriptor = {0};
  if (event) {
    good = snapshot_take(&descriptor, event, SE_KERNEL_OBJECT, FALSE);
    PACL acl = NULL;
    BOOL present, def;
    good = good &&
           GetSecurityDescriptorDacl(descriptor.sd, &present, &acl, &def) &&
           present && acl && IsValidAcl(acl);
    token_default_applied = good &&
                            acl->AceCount == s->default_dacl->AceCount &&
                            acl_has(acl, s->lease, EVENT_MODIFY_STATE);
    GENERIC_MAPPING mapping = {READ_CONTROL | SYNCHRONIZE,
                               READ_CONTROL | EVENT_MODIFY_STATE,
                               READ_CONTROL | SYNCHRONIZE, EVENT_ALL_ACCESS};
    for (DWORD i = 0; token_default_applied && i < acl->AceCount; ++i) {
      ACCESS_ALLOWED_ACE *effective = NULL, *requested = NULL;
      BOOL queried = GetAce(acl, i, (void **)&effective) &&
                     GetAce(s->default_dacl, i, (void **)&requested);
      good = good && queried;
      token_default_applied =
          queried && effective->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
          requested->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
          effective->Header.AceFlags == requested->Header.AceFlags;
      if (token_default_applied) {
        DWORD a = effective->Mask, b = requested->Mask;
        MapGenericMask(&a, &mapping);
        MapGenericMask(&b, &mapping);
        token_default_applied =
            a == b && EqualSid(&effective->SidStart, &requested->SidStart);
      }
    }
    LPWSTR sddl = NULL;
    BOOL converted =
        good && ConvertSecurityDescriptorToStringSecurityDescriptorW(
                    descriptor.sd, SDDL_REVISION_1, SD_INFO, &sddl, NULL);
    good = good && converted;
    if (converted)
      printf("CHILD_NAMED_OBJECT name=%ls token_default_applied=%d SDDL=%ls\n",
             name, token_default_applied, sddl);
    if (sddl)
      LocalFree(sddl);
  } else
    good = FALSE;
  /* Retain the event in the parent, then empty its creator's Job before any
     executable descriptor restoration. The named fixture remains identical. */
  BOOL creator_ended = creator.complete && release_run(&creator),
       creator_cleaned = dispose_run(&creator);
  if (!good || !creator_ended || !creator_cleaned) {
    if (descriptor.sd)
      LocalFree(descriptor.sd);
    if (event)
      CloseHandle(event);
    result(s, 13, FALSE,
           "new object creation/descriptor failed; no preexisting named object "
           "adopted or modified");
    return;
  }
  run ordinary = {0};
  BOOL positive = event && probe(s, &ordinary, TRUE, OP_EVENT, name, 0, 0) &&
                  ordinary.reply.opened && !ordinary.reply.error &&
                  !ordinary.reply.secondary_error &&
                  WaitForSingleObject(event, 0) == WAIT_OBJECT_0;
  BOOL ordinary_ended = ordinary.complete && release_run(&ordinary),
       ordinary_cleaned = dispose_run(&ordinary);
  good = good && creator_ended && creator_cleaned && positive &&
         ordinary_ended && ordinary_cleaned && ResetEvent(event);
  PSID saved = s->lease;
  WCHAR text[256];
  BOOL saved_text = fmt(text, 256, L"%ls", s->sid_text);
  PSID second_lease = NULL;
  DWORD random[4];
  PSECURITY_DESCRIPTOR other_sd = NULL;
  PACL saved_acl = s->default_dacl;
  if (!saved_text || !random_bytes(random, sizeof(random)) ||
      !fmt(s->sid_text, 256, L"S-1-5-21-%lu-%lu-%lu-%lu",
           (unsigned long)random[0], (unsigned long)random[1],
           (unsigned long)random[2], (unsigned long)random[3]) ||
      !ConvertStringSidToSidW(s->sid_text, &second_lease) ||
      EqualSid(saved, second_lease))
    good = FALSE;
  if (second_lease) {
    s->lease = second_lease;
    BOOL present, def;
    /* The executable needs the second lease's read/execute ACE for this
       independent-token probe. Extend only the private executable copy. */
    snapshot binary = {0};
    HANDLE binary_security = CreateFileW(
        s->child, READ_CONTROL | WRITE_DAC | WRITE_OWNER, FILE_SHARE_READ, NULL,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    BOOL prepared =
        binary_security != INVALID_HANDLE_VALUE &&
        snapshot_take(&binary, binary_security, SE_FILE_OBJECT, TRUE);
    PACL extended = NULL;
    if (prepared) {
      PACL old = NULL;
      prepared = GetSecurityDescriptorDacl(binary.sd, &present, &old, &def);
      EXPLICIT_ACCESSW entry = {0};
      entry.grfAccessPermissions = FILE_GENERIC_READ | FILE_GENERIC_EXECUTE;
      entry.grfAccessMode = GRANT_ACCESS;
      entry.grfInheritance = NO_INHERITANCE;
      entry.Trustee.TrusteeForm = TRUSTEE_IS_SID;
      entry.Trustee.TrusteeType = TRUSTEE_IS_UNKNOWN;
      entry.Trustee.ptstrName = (LPWSTR)second_lease;
      if (prepared)
        prepared = SetEntriesInAclW(1, &entry, old, &extended) == ERROR_SUCCESS;
      if (prepared) {
        SECURITY_DESCRIPTOR updated;
        prepared = InitializeSecurityDescriptor(&updated,
                                                SECURITY_DESCRIPTOR_REVISION) &&
                   SetSecurityDescriptorDacl(&updated, TRUE, extended, FALSE) &&
                   SetSecurityDescriptorControl(&updated, SE_DACL_PROTECTED,
                                                SE_DACL_PROTECTED) &&
                   SetKernelObjectSecurity(binary_security,
                                           DACL_SECURITY_INFORMATION, &updated);
      }
    }
    if (good && make_default_sd(s, &other_sd) &&
        GetSecurityDescriptorDacl(other_sd, &present, &s->default_dacl, &def) &&
        present && s->default_dacl && prepared) {
      BOOL attempted = probe(s, &other, FALSE, OP_EVENT, name, 0, 0);
      DWORD wait = event ? WaitForSingleObject(event, 0) : WAIT_FAILED;
      BOOL allowed = wait == WAIT_OBJECT_0 && other.reply.opened &&
                     !other.reply.error && !other.reply.secondary_error;
      BOOL denied = wait == WAIT_TIMEOUT && !other.reply.opened &&
                    other.reply.error == ERROR_ACCESS_DENIED &&
                    !other.reply.secondary_error;
      BOOL ended = other.complete && release_run(&other);
      BOOL cleaned = dispose_run(&other);
      BOOL descriptor_equal = snapshot_equal(&descriptor);
      good = good && attempted && (allowed || denied) && ended && cleaned &&
             descriptor_equal;
      actual_allowed = allowed;
      sandbox_error = other.reply.error;
      printf("CHILD_NAMED_OBJECT second_lease=%ls ordinary_control=%d "
             "attempted=%d parent_wait=%lu opened=%lu win32=%lu "
             "secondary_error=%lu descriptor_equal=%d ended=%d cleanup=%d\n",
             s->sid_text, positive, attempted, (unsigned long)wait,
             (unsigned long)other.reply.opened,
             (unsigned long)other.reply.error,
             (unsigned long)other.reply.secondary_error, descriptor_equal,
             ended, cleaned);
    } else
      good = FALSE;
    if (binary.sd) {
      BOOL restored = restore(&binary);
      printf("CHILD_NAMED_OBJECT executable_exact_restore=%d\n", restored);
      if (!restored) {
        good = FALSE;
        s->blocked = TRUE;
      }
    }
    if (extended)
      LocalFree(extended);
    snapshot_dispose(&binary);
  }
  s->lease = saved;
  s->default_dacl = saved_acl;
  if (saved_text && !fmt(s->sid_text, 256, L"%ls", text))
    good = FALSE;
  if (other_sd)
    LocalFree(other_sd);
  if (second_lease)
    LocalFree(second_lease);
  if (descriptor.sd)
    LocalFree(descriptor.sd);
  if (event)
    CloseHandle(event);
  if (good)
    observation(s, 13, actual_allowed, sandbox_error,
                "EVENT_MODIFY_STATE; child creates named event with NULL SD; "
                "parent records actual SDDL and token_default_applied; "
                "ordinary control and second lease signal measurement");
  else
    result(s, 13, FALSE,
           "named event descriptor/control/cross-lease measurement or exact "
           "private executable restoration incomplete");
}
static BOOL duplicate_event(run *creator, HANDLE *event, WCHAR *full_name) {
  *event = NULL;
  if (!creator->reply.opened || !creator->reply.handle ||
      !DuplicateHandle(creator->process.pi.hProcess,
                       (HANDLE)creator->reply.handle, GetCurrentProcess(),
                       event, 0, FALSE, DUPLICATE_SAME_ACCESS))
    return FALSE;
  ULONG size = 0;
  NTSTATUS status =
      NtQueryObject(*event, ObjectNameInformation, NULL, 0, &size);
  DWORD error = RtlNtStatusToDosError(status);
  if (!size || (error != ERROR_INSUFFICIENT_BUFFER &&
                error != ERROR_MORE_DATA && error != ERROR_BAD_LENGTH))
    return cycle_api_fail(
        "NtQueryObject", "name size query",
        status >= 0 || (!size &&
                        (error == ERROR_INSUFFICIENT_BUFFER ||
                         error == ERROR_MORE_DATA || error == ERROR_BAD_LENGTH))
            ? ERROR_INVALID_DATA
            : error);
  for (DWORD attempt = 0; attempt < 8 && size <= 16 * 1024 * 1024; ++attempt) {
    ULONG capacity = size;
    void *buffer = calloc(1, capacity);
    if (!buffer)
      return cycle_api_fail("calloc", "NtQueryObject name",
                            ERROR_NOT_ENOUGH_MEMORY);
    status =
        NtQueryObject(*event, ObjectNameInformation, buffer, capacity, &size);
    error = RtlNtStatusToDosError(status);
    if (status >= 0) {
      UNICODE_STRING *name = buffer;
      ULONG_PTR start = (ULONG_PTR)buffer, text = (ULONG_PTR)name->Buffer;
      BOOL good = capacity >= sizeof(*name) && size <= capacity &&
                  name->Buffer && !(name->Length % sizeof(WCHAR)) &&
                  name->Length / sizeof(WCHAR) < CAP && text >= start &&
                  text - start <= capacity &&
                  name->Length <= capacity - (text - start);
      if (good) {
        memcpy(full_name, name->Buffer, name->Length);
        full_name[name->Length / sizeof(WCHAR)] = 0;
        printf("EVENT_NATIVE_NAME=%ls\n", full_name);
      }
      free(buffer);
      if (!good)
        return cycle_api_fail("NtQueryObject", "name bounds",
                              ERROR_INVALID_DATA);
      SetLastError(ERROR_SUCCESS);
      return TRUE;
    }
    free(buffer);
    if (size <= capacity ||
        (error != ERROR_INSUFFICIENT_BUFFER && error != ERROR_MORE_DATA &&
         error != ERROR_BAD_LENGTH))
      return cycle_api_fail("NtQueryObject", "name buffer", error);
  }
  return cycle_api_fail("NtQueryObject", "name growth limit",
                        ERROR_INSUFFICIENT_BUFFER);
}
static BOOL appcontainer_cross_lease_case(suite *s) {
  suite b = *s;
  b.lease = NULL;
  b.profile_created = FALSE;
  b.profile_path = NULL;
  b.profile[0] = 0;
  b.private_local[0] = 0;
  b.private_temp[0] = 0;
  b.unsafe_cleanup = FALSE;
  b.blocked = FALSE;
  snapshot directory = {0}, executable = {0}, namespace_root = {0};
  WCHAR name[512], own_name[512], full[CAP], own_full[CAP];
  run a = {0}, own = {0}, control = {0}, attack = {0};
  HANDLE event = NULL, own_event = NULL;
  PSECURITY_DESCRIPTOR sd = NULL, peer_default = NULL;
  BOOL good =
      snapshot_take(&namespace_root, s->root_sd.handle, SE_FILE_OBJECT, TRUE) &&
      create_profile(&b) && !EqualSid(s->lease, b.lease) &&
      fmt(b.dest, CAP, L"%ls\\second-order", s->root) &&
      create_dir(&b, b.dest, FALSE, -1, &directory) &&
      grant_package(directory.handle, b.lease, 0x001201ff, TRUE) &&
      grant_package(s->root_sd.handle, b.lease,
                    FILE_GENERIC_READ | FILE_GENERIC_EXECUTE, FALSE);
  if (good && s->active_capability) {
    BOOL present = FALSE, def = FALSE;
    good = runtime_prepare_temp(&b) && make_default_sd(&b, &peer_default) &&
           GetSecurityDescriptorDacl(peer_default, &present, &b.default_dacl,
                                     &def) &&
           present && b.default_dacl;
  }
  HANDLE security = CreateFileW(
      s->child, READ_CONTROL | WRITE_DAC | WRITE_OWNER, FILE_SHARE_READ, NULL,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  printf("CROSS_LEASE_EXECUTABLE_CAPTURE path=%ls handle=%p "
         "access=READ_CONTROL|WRITE_DAC|WRITE_OWNER\n",
         s->child, security);
  good = good && security != INVALID_HANDLE_VALUE &&
         snapshot_take(&executable, security, SE_FILE_OBJECT, TRUE) &&
         grant_package(security, b.lease,
                       FILE_GENERIC_READ | FILE_GENERIC_EXECUTE, FALSE);
  if (!executable.handle && security != INVALID_HANDLE_VALUE)
    CloseHandle(security);
  good = good && fmt(name, 512, L"Local\\SEC5-A-%ls", s->guid) &&
         fmt(own_name, 512, L"Local\\SEC5-B-%ls", s->guid) &&
         probe(s, &a, FALSE, OP_DEFAULT, name, 0, 0) &&
         duplicate_event(&a, &event, full) && kernel_sd(event, SD_INFO, &sd) &&
         probe(&b, &own, FALSE, OP_DEFAULT, own_name, 0, 0) &&
         duplicate_event(&own, &own_event, own_full);
  if (sd) {
    LPWSTR text = NULL;
    if (ConvertSecurityDescriptorToStringSecurityDescriptorW(
            sd, SDDL_REVISION_1, SD_INFO, &text, NULL)) {
      printf("CROSS_LEASE_EVENT_A_SDDL=%ls\n", text);
      LocalFree(text);
    } else
      good = FALSE;
  }
  /* Both containers stay alive. Each container can signal its own live event.
   */
  if (good) {
    good = probe(s, &control, FALSE, OP_EVENT, name, 0, 0) &&
           control.reply.opened && !control.reply.secondary_error &&
           WaitForSingleObject(event, 0) == WAIT_OBJECT_0;
    BOOL ended = control.complete && release_run(&control);
    BOOL clean = dispose_run(&control);
    good = good && ended && clean && ResetEvent(event);
    good = good && probe(s, &control, FALSE, OP_EVENT_FULL, full, 0, 0) &&
           control.reply.opened && !control.reply.secondary_error &&
           WaitForSingleObject(event, 0) == WAIT_OBJECT_0;
    ended = control.complete && release_run(&control);
    clean = dispose_run(&control);
    good = good && ended && clean && ResetEvent(event);
    good = good && probe(&b, &control, FALSE, OP_EVENT, own_name, 0, 0) &&
           control.reply.opened && !control.reply.secondary_error &&
           WaitForSingleObject(own_event, 0) == WAIT_OBJECT_0;
    ended = control.complete && release_run(&control);
    clean = dispose_run(&control);
    good = good && ended && clean && ResetEvent(own_event);
  }
  PSID saved = b.lease;
  if (s->mutation == SEC5_REUSE_PROFILE) {
    b.lease = s->lease;
    good = grant_package(directory.handle, s->lease, 0x001201ff, TRUE) && good;
  }
  BOOL peers_ready =
      good && WaitForSingleObject(a.process.pi.hProcess, 0) == WAIT_TIMEOUT &&
      WaitForSingleObject(own.process.pi.hProcess, 0) == WAIT_TIMEOUT;
  good = good && peers_ready;
  for (unsigned attempt = 0; peers_ready && attempt < 2; ++attempt) {
    BOOL alive =
        WaitForSingleObject(a.process.pi.hProcess, 0) == WAIT_TIMEOUT &&
        WaitForSingleObject(own.process.pi.hProcess, 0) == WAIT_TIMEOUT;
    BOOL tried =
        alive && probe(&b, &attack, FALSE, attempt ? OP_EVENT_FULL : OP_EVENT,
                       attempt ? full : name, 0, 0);
    BOOL denied = tried && !attack.reply.opened &&
                  !attack.reply.secondary_error &&
                  (attack.reply.error == ERROR_ACCESS_DENIED ||
                   attack.reply.error == ERROR_FILE_NOT_FOUND ||
                   attack.reply.error == ERROR_PATH_NOT_FOUND) &&
                  WaitForSingleObject(event, 0) == WAIT_TIMEOUT;
    PSECURITY_DESCRIPTOR after = NULL;
    BOOL intact =
        kernel_sd(event, SD_INFO, &after) && descriptor_equal(sd, after);
    if (after)
      LocalFree(after);
    printf("CROSS_LEASE attempt=%s barrier=%d both_alive=%d error=%lu "
           "A_unchanged=%d "
           "denied=%d\n",
           attempt ? "full-namespace" : "relative", tried, alive,
           (unsigned long)attack.reply.error, intact, denied);
    BOOL ended = attack.complete && release_run(&attack),
         clean = dispose_run(&attack);
    good = good && denied && intact && ended && clean;
    if (!ResetEvent(event))
      good = FALSE;
  }
  b.lease = saved;
  if (s->active_capability)
    good = runtime_other_order(s, &b, &a, &own) && good;
  BOOL a_end = a.complete && release_run(&a),
       b_end = own.complete && release_run(&own);
  BOOL a_clean = dispose_run(&a), b_clean = dispose_run(&own);
  close_handle(&event);
  close_handle(&own_event);
  if (sd)
    LocalFree(sd);
  good = good && a_end && b_end && a_clean && b_clean;
  BOOL restored = TRUE;
  if (!b.unsafe_cleanup && !s->unsafe_cleanup) {
    if (executable.sd) {
      printf(
          "CROSS_LEASE_RESTORE object=private-executable path=%ls handle=%p\n",
          s->child, executable.handle);
      restored = restore(&executable);
    }
    if (directory.sd) {
      printf("CROSS_LEASE_RESTORE object=second-order path=%ls handle=%p\n",
             b.dest, directory.handle);
      restored = restore(&directory) && restored;
    }
    if (namespace_root.sd) {
      printf("CROSS_LEASE_RESTORE object=fixture-root path=%ls handle=%p\n",
             s->root, namespace_root.handle);
      restored = restore(&namespace_root) && restored;
    }
    if (b.profile_created && restored) {
      HRESULT hr = DeleteAppContainerProfile(b.profile);
      BOOL absent = storage_absent(b.profile_path);
      printf("CROSS_LEASE_PROFILE_DELETE HRESULT=0x%08lx storage_absent=%d\n",
             (unsigned long)hr, absent);
      restored = SUCCEEDED(hr) && absent && restored;
    }
  } else {
    restored = FALSE;
    s->unsafe_cleanup = TRUE;
  }
  if (!restored) {
    s->blocked = TRUE;
    s->unsafe_cleanup = TRUE;
    printf("CROSS_LEASE_CLEANUP BLOCKED original descriptors/profile not "
           "restored; moniker=%ls\n",
           b.profile);
  }
  if (namespace_root.sd)
    LocalFree(namespace_root.sd); /* Borrowed root pin. */
  snapshot_dispose(&executable);
  snapshot_dispose(&directory);
  if (b.profile_path)
    CoTaskMemFree(b.profile_path);
  if (b.lease)
    FreeSid(b.lease);
  if (peer_default)
    LocalFree(peer_default);
  return good && restored;
}
static void appcontainer_cross_lease(suite *s) {
  /* No root, executable pin, profile or cleanup flag is shared with later
     measurements. A retained cross-lease fixture still fails this case. */
  suite isolated = {0};
  isolated.backend = s->backend;
  isolated.mutation = s->mutation;
  BOOL prepared = fmt(isolated.user_text, 256, L"%ls", s->user_text) &&
                  setup(&isolated, s->original_child);
  if (!prepared)
    api_error("cross-lease isolated fixture preparation", GetLastError());
  printf("CROSS_LEASE_FIXTURE isolated=1 root=%ls main_root=%ls\n",
         isolated.root, s->root);
  BOOL measured = prepared && appcontainer_cross_lease_case(&isolated);
  BOOL cleaned = finish(&isolated);
  s->isolated_cleanup_failed = !cleaned;
  printf("CROSS_LEASE_FINAL measurement=%d cleanup=%d "
         "main_fixture_affected=0 independent_cases_continue=1\n",
         measured, cleaned);
  result(s, 13, measured && cleaned,
         "isolated fixture; A/B alive with distinct package SIDs; own-event "
         "positives; relative and actual NT namespace denied; parent state/SD "
         "unchanged; exact cleanup required");
}
static BOOL duplicate_station(run *r, uintptr_t value, HWINSTA expected) {
  /* Zig's import libraries omit this KernelBase export. Use the actual
     Windows API with the same handles/access, and fail if unavailable. */
  typedef BOOL(WINAPI * compare_handles_fn)(HANDLE, HANDLE);
  HMODULE kernelbase = GetModuleHandleW(L"KernelBase.dll");
  compare_handles_fn compare_handles =
      kernelbase ? (compare_handles_fn)GetProcAddress(kernelbase,
                                                      "CompareObjectHandles")
                 : NULL;
  if (!compare_handles) {
    api_error("CompareObjectHandles resolve", GetLastError());
    return FALSE;
  }
  HANDLE copy = NULL;
  if (!value || !DuplicateHandle(r->process.pi.hProcess, (HANDLE)value,
                                 GetCurrentProcess(), &copy, 0, FALSE,
                                 DUPLICATE_SAME_ACCESS)) {
    printf("WINSTA_HANDLE duplicate value=%llu win32=%lu\n",
           (unsigned long long)value, (unsigned long)GetLastError());
    return FALSE;
  }
  BOOL same = compare_handles(copy, (HANDLE)expected);
  DWORD compare_error = same ? 0 : GetLastError();
  BOOL good = same;
  BOOL closed = CloseWindowStation((HWINSTA)copy);
  printf(
      "WINSTA_HANDLE same_object_as_parent_WinSta0=%d "
      "duplicate_same_access=1 compare_error=%lu closed=%d close_error=%lu\n",
      same, (unsigned long)compare_error, closed,
      (unsigned long)(closed ? 0 : GetLastError()));
  if (!closed)
    good = FALSE;
  return good;
}
static void winsta_case(suite *s) {
  HWINSTA expected =
      OpenWindowStationW(L"WinSta0", FALSE, WINSTA_READATTRIBUTES);
  DWORD parent_error = expected ? 0 : GetLastError();
  printf("WINSTA_PARENT reference_opened=%d win32=%lu "
         "mask=WINSTA_READATTRIBUTES\n",
         expected != NULL, (unsigned long)parent_error);
  BOOL controls = expected != NULL, measured = TRUE;
  BOOL actual[2] = {FALSE, FALSE};
  DWORD errors[2] = {0, 0};
  for (unsigned i = 0; i < 2; ++i) {
    run r = {0};
    BOOL attempted = expected && probe(s, &r, i == 0, OP_WINSTA, L"-", 0, 0);
    BOOL first = attempted && r.reply.handle &&
                 duplicate_station(&r, r.reply.handle, expected);
    BOOL second = attempted && r.reply.second_handle &&
                  duplicate_station(&r, r.reply.second_handle, expected);
    BOOL verified = attempted &&
                    ((first && r.reply.opened && !r.reply.error) ||
                     (!r.reply.handle && !r.reply.opened &&
                      r.reply.error == ERROR_ACCESS_DENIED)) &&
                    ((second && !r.reply.secondary_error) ||
                     (!r.reply.second_handle &&
                      r.reply.secondary_error == ERROR_ACCESS_DENIED));
    BOOL ended = r.complete && release_run(&r);
    BOOL cleaned = dispose_run(&r);
    printf("WINSTA_MEASUREMENT ordinary=%d attempted=%d readattributes=%d "
           "accessclipboard=%d read_win32=%lu clipboard_win32=%lu "
           "verified=%d ended=%d cleanup=%d\n",
           i == 0, attempted, first, second, (unsigned long)r.reply.error,
           (unsigned long)r.reply.secondary_error, verified, ended, cleaned);
    if (i == 0)
      controls = controls && first && second && verified && ended && cleaned;
    else {
      measured = verified && ended && cleaned;
      actual[0] = first;
      actual[1] = second;
      errors[0] = r.reply.error;
      errors[1] = r.reply.secondary_error;
    }
  }
  if (expected && !CloseWindowStation(expected)) {
    api_error("CloseWindowStation(parent reference)", GetLastError());
    measured = FALSE;
  }
  if (controls && measured) {
    printf("WINSTA mask=WINSTA_ACCESSCLIPBOARD result=%s win32=%lu; no "
           "clipboard use\n",
           actual[1] ? "ALLOWED" : "DENIED", (unsigned long)errors[1]);
    observation(s, 14, actual[0], errors[0],
                "WINSTA_READATTRIBUTES; both duplicated handles compared "
                "against parent's WinSta0 via CompareObjectHandles; "
                "WINSTA_ACCESSCLIPBOARD separately recorded, no clipboard use");
  } else
    result(s, 14, FALSE,
           "WinSta0 control/handle duplication incomplete; no invented access "
           "result");
}
static void handles_case(suite *s) {
  BOOL good = TRUE;
  for (unsigned i = 0; i < 2; ++i) {
    run r = {0};
    BOOL attempted = probe(s, &r, i == 0, OP_HANDLES, L"-", 0, 0);
    BOOL witness =
        r.witness && WaitForSingleObject(r.witness, 0) == WAIT_OBJECT_0;
    BOOL signaled =
        r.excluded && WaitForSingleObject(r.excluded, 0) == WAIT_OBJECT_0;
    BOOL ended = r.complete && release_run(&r);
    BOOL cleaned = dispose_run(&r);
    good = good && attempted && witness && (i == 0 ? signaled : !signaled) &&
           ended && cleaned;
  }
  result(s, 20, good,
         "extra inheritable event excluded, permitted witness signaled; "
         "ordinary general-inheritance control signals same extra event");
}
static void zero_handles_case(suite *s) {
  run r = {0};
  r.owner = s;
  BOOL before_ok = snapshot_before(&r);
  WCHAR command[CAP * 2];
  WCHAR *env = environment(s->dest,
                           s->backend == SEC5_APPCONTAINER &&
                               s->mutation != SEC5_NO_APPCONTAINER,
                           FALSE, NULL);
  sec5_request request = {0};
  request.executable = s->child;
  request.executable_pin = s->child_pin;
  request.command_line = command;
  request.cwd = s->dest;
  request.environment = env;
  request.backend = s->backend;
  request.lease_sid = s->lease;
  request.default_dacl = s->default_dacl;
  request.mutation = s->mutation;
  request.observe_suspended = observe_token;
  request.observer_context = s;
  BOOL launched = before_ok && env &&
                  fmt(command, CAP * 2, L"\"%ls\" zero", s->child) &&
                  sec5_launch_fixture(&request, &r.process);
  if (launched)
    pin_run_consoles(&r);
  DWORD code = STILL_ACTIVE;
  BOOL exited =
      launched && r.process.stage == SEC5_READY && r.process.resumed &&
      WaitForSingleObject(r.process.pi.hProcess, WAIT_MS) == WAIT_OBJECT_0 &&
      GetExitCodeProcess(r.process.pi.hProcess, &code) && code == 0;
  if (!launched && r.process.error) {
    launch_error(&request, &r.process);
    if (r.process.stage == SEC5_CREATE)
      s->blocked = TRUE;
  }
  free(env);
  BOOL cleaned = dispose_run(&r);
  result(s, 28, exited && cleaned && s->token_ok,
         "zero inherited handles; effective token and Job; AppContainer "
         "retains SECURITY_CAPABILITIES without HANDLE_LIST/stdio");
}
static BOOL failure_one(suite *s) {
  WCHAR path[CAP], arguments[CAP * 2];
  static const BYTE marker[] = "FIRST_ACT";
  run ordinary = {0}, failed = {0};
  packet first = {0};
  HANDLE ordinary_grandchild = NULL, escaped = NULL;
  BOOL paths = fmt(path, CAP, L"%ls\\first-act.bin", s->dest) &&
               fmt(arguments, CAP * 2, L"act %u \"%ls\" 0 0", OP_EARLY, path);
  BOOL control =
      paths && launch_run(s, &ordinary, TRUE, s->child, arguments, FALSE) &&
      WaitForSingleObject(ordinary.witness, WAIT_MS) == WAIT_OBJECT_0 &&
      file_bytes(path, marker, sizeof(marker), FALSE) &&
      read_deadline(ordinary.out_read, &first, sizeof(first)) &&
      first.pid == ordinary.process.pi.dwProcessId &&
      observed_descendant(&first, ordinary.process.pi.hProcess,
                          ordinary.process.creation_time, &ordinary_grandchild);
  BOOL cleaned_control = dispose_run(&ordinary);
  BOOL control_tree_cleaned = wait_observed(ordinary_grandchild);
  BOOL removed = DeleteFileW(path);
  BOOL launched = control && removed &&
                  launch_run(s, &failed, FALSE, s->child, arguments, TRUE);
  BOOL no_process =
      !failed.process.pi.hProcess ||
      WaitForSingleObject(failed.process.pi.hProcess, 0) == WAIT_OBJECT_0;
  BOOL no_marker = GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES &&
                   GetLastError() == ERROR_FILE_NOT_FOUND;
  BOOL seeded = !launched &&
                failed.process.stage ==
                    (s->failure_stage ? s->failure_stage : SEC5_SEEDED) &&
                failed.process.error == ERROR_CANCELLED &&
                !failed.process.resumed;
  if (!no_marker && failed.out_read &&
      read_deadline(failed.out_read, &first, sizeof(first)) &&
      first.pid == failed.process.pi.dwProcessId &&
      observed_descendant(&first, failed.process.pi.hProcess,
                          failed.process.creation_time, &escaped)) {
    BOOL member = FALSE;
    if (!IsProcessInJob(escaped, failed.process.job, &member))
      api_error("IsProcessInJob(early descendant)", GetLastError());
    printf("RESUME_FIRST real_grandchild=%lu outside_sec5_job=%d live=%d\n",
           (unsigned long)first.descendant, !member,
           WaitForSingleObject(escaped, 0) == WAIT_TIMEOUT);
  }
  BOOL cleaned = dispose_run(&failed);
  BOOL escaped_cleaned = wait_observed(escaped);
  BOOL good = control && cleaned_control && control_tree_cleaned && seeded &&
              no_process && no_marker && escaped_cleaned && cleaned;
  printf(
      "FAIL_BEFORE_RESUME requested_stage=%u actual_stage=%u error=%lu "
      "cleanup_error=%lu resumed=%d marker_absent=%d child_dead=%d good=%d\n",
      s->failure_stage, failed.process.stage,
      (unsigned long)failed.process.error,
      (unsigned long)failed.process.cleanup_error, failed.process.resumed,
      no_marker, no_process, good);
  if (!no_marker && !DeleteFileW(path))
    api_error("DeleteFileW(first-act fixture)", GetLastError());
  return good;
}
static void failure_case(suite *s) {
  const enum sec5_stage stages[] = {SEC5_TOKEN, SEC5_ATTRIBUTES, SEC5_ASSIGN,
                                    SEC5_SEEDED};
  BOOL good = TRUE;
  unsigned count = s->backend == SEC5_APPCONTAINER ? 4 : 1;
  for (unsigned i = 0; i < count; ++i) {
    s->failure_stage =
        s->backend == SEC5_APPCONTAINER ? stages[i] : SEC5_SEEDED;
    BOOL measured = failure_one(s);
    good = good && measured;
    if (s->blocked)
      break;
  }
  s->failure_stage = 0;
  result(s, 21, good,
         "ordinary first-act control; token/ACL/Job/final preparation "
         "cancellation before Resume; error and cleanup explicit; no marker or "
         "live child");
}
static void job_cases(suite *s) {
  for (unsigned kind = 0; kind < 2; ++kind) {
    BOOL good = TRUE;
    for (unsigned i = 0; i < 2; ++i) {
      run r = {0};
      unsigned op = kind == 0 ? OP_BREAKAWAY : OP_TREE;
      BOOL attempted = probe(s, &r, i == 0, op, L"-", 0, 0);
      descendant_measurement descendants = {0};
      BOOL parental =
          measure_descendants(&r, r.process.job, &descendants, FALSE);
      HANDLE grandchild = NULL;
      BOOL identified =
               observed_descendant(&r.reply, r.process.pi.hProcess,
                                   r.process.creation_time, &grandchild),
           member = FALSE;
      if (identified && i == 1 &&
          !IsProcessInJob(grandchild, r.process.job, &member))
        good = FALSE;
      BOOL expected =
          i == 0 ? identified
          : kind == 0
              ? (parental && !descendants.outside && descendants.others == 0 &&
                 r.reply.error == ERROR_ACCESS_DENIED && !r.reply.opened)
              : (identified && member &&
                 (s->backend != SEC5_APPCONTAINER ||
                  appcontainer_token(grandchild, s->lease, TRUE)) &&
                 r.reply.opened && !r.reply.secondary_error && parental &&
                 !descendants.outside && descendants.others == 1 &&
                 descendants.others_identified);
      printf("JOB_PARENT snapshot_before_after=%d descendants=%u outside=%u "
             "consoles=%u others=%u others_identified=%d "
             "child_message_error=%lu\n",
             parental, descendants.count, descendants.outside,
             descendants.consoles, descendants.others,
             descendants.others_identified, (unsigned long)r.reply.error);
      printf("JOB ordinary=%u op=%u actual_grandchild=%lu time_verified=%d "
             "member_exact_job=%d\n",
             i == 0, op, (unsigned long)r.reply.descendant, identified, member);
      BOOL ended = r.complete && release_run(&r);
      BOOL killed = wait_observed(grandchild);
      BOOL cleaned = dispose_run(&r);
      good = good && attempted && expected && killed && ended && cleaned;
      if (s->blocked)
        break;
    }
    result(s, kind == 0 ? 16 : 17, good,
           kind == 0 ? "ordinary CREATE_BREAKAWAY_FROM_JOB control; parent "
                       "identifies real escaped child if mutation succeeds"
                     : "real normal grandchild; parent opens PID+creation-time "
                       "and queries exact SEC5 Job");
    if (s->blocked)
      break;
  }
}
static void inheritance_case(suite *s) {
  WCHAR file[CAP], directory[CAP], existing[CAP];
  snapshot preexisting = {0};
  PSECURITY_DESCRIPTOR sd = NULL;
  BOOL paths = fmt(file, CAP, L"%ls\\inherited.bin", s->dest) &&
               fmt(directory, CAP, L"%ls\\inherited-dir", s->dest) &&
               fmt(existing, CAP, L"%ls\\protected-medium", s->dest);
  BOOL good = paths && create_dir(s, existing, FALSE, 1, &preexisting);
  for (unsigned i = 0; i < 2; ++i) {
    run r = {0};
    BOOL attempted = good && probe(s, &r, i == 0, OP_INHERIT, s->dest, 0, 0);
    HANDLE fh =
        CreateFileW(file, READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
                    NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    HANDLE dh = open_dir(directory, READ_CONTROL | FILE_READ_ATTRIBUTES);
    BOOL labels = fh != INVALID_HANDLE_VALUE && dh != INVALID_HANDLE_VALUE &&
                  label_is(fh, SE_FILE_OBJECT, SECURITY_MANDATORY_LOW_RID) &&
                  label_is(dh, SE_FILE_OBJECT, SECURITY_MANDATORY_LOW_RID) &&
                  snapshot_equal(&preexisting) &&
                  label_is(preexisting.handle, SE_FILE_OBJECT,
                           SECURITY_MANDATORY_MEDIUM_RID);
    PACL acl = NULL;
    if (fh != INVALID_HANDLE_VALUE) {
      BOOL present, def;
      BOOL read = kernel_sd(fh, DACL_SECURITY_INFORMATION, &sd) &&
                  GetSecurityDescriptorDacl(sd, &present, &acl, &def);
      labels = labels && read && present &&
               acl_has(acl, s->lease, FILE_GENERIC_WRITE);
      if (sd)
        LocalFree(sd);
      sd = NULL;
      CloseHandle(fh);
    }
    if (dh != INVALID_HANDLE_VALUE)
      CloseHandle(dh);
    BOOL content = file_bytes(file, r.nonce, sizeof(r.nonce), FALSE);
    BOOL ended = r.complete && release_run(&r);
    BOOL cleaned = dispose_run(&r);
    good = good && attempted && labels && content && ended && cleaned;
    if (!DeleteFileW(file) || !RemoveDirectoryW(directory))
      good = FALSE;
  }
  snapshot_dispose(&preexisting);
  if (paths && !RemoveDirectoryW(existing))
    good = FALSE;
  result(s, 24, good,
         "parent reads OI/CI low label and lease DACL on new file/dir; "
         "preexisting protected medium object stays unchanged");
}
static void security_case(suite *s) {
  snapshot prepared = {0};
  BOOL good = snapshot_take(&prepared, s->dest_sd.handle, SE_FILE_OBJECT, TRUE);
  for (unsigned i = 0; i < 2; ++i) {
    run r = {0};
    BOOL attempted = good && probe(s, &r, i == 0, OP_WIDEN, s->dest, 0, 0);
    BOOL identical = prepared.sd && snapshot_equal(&prepared);
    BOOL expected =
        i == 0 ? (!identical && r.reply.opened && !r.reply.secondary_error)
               : (identical && !r.reply.opened &&
                  r.reply.error == ERROR_ACCESS_DENIED);
    BOOL ended = r.complete && release_run(&r);
    BOOL cleaned = dispose_run(&r);
    BOOL restored = prepared.sd && restore(&prepared);
    if (!restored)
      s->blocked = TRUE;
    good = good && attempted && expected && ended && cleaned && restored;
  }
  if (prepared.sd)
    LocalFree(prepared.sd);
  result(s, 25, good,
         "ordinary control widens own fixture DACL/label then exact restore; S "
         "WRITE_DAC|WRITE_OWNER denied, SD unchanged; OWNER RIGHTS present");
}

typedef struct broker_packet {
  DWORD magic, error, stage, child_pid, grandchild_pid;
  BYTE nonce[16];
  FILETIME child_time, grandchild_time;
  uintptr_t inner_job, outer_job;
  BOOL suspended_token_checked;
} broker_packet;

static int broker_main(int argc, WCHAR **argv) {
  if (argc != 10)
    return 110;
  unsigned mode = (unsigned)wcstoul(argv[2], NULL, 10);
  suite s = {0};
  /* stdout is the binary broker_packet channel; parent logs token evidence. */
  s.quiet_tokens = TRUE;
  broker_packet reply = {0};
  HANDLE outer = NULL, in_read = NULL, in_write = NULL, out_read = NULL,
         out_write = NULL;
  HANDLE err_read = NULL, err_write = NULL, pin = NULL;
  sec5_result child = {0};
  WCHAR *env = NULL;
  WCHAR command[CAP * 2];
  BOOL present, def;
  reply.magic = MAGIC;
  s.backend = !wcsncmp(argv[7], L"appcontainer", 12)
                  ? SEC5_APPCONTAINER
                  : SEC5_RESTRICTED_DIAGNOSTIC;
  s.mutation = !wcscmp(argv[7], L"appcontainer-no-job-kill") ? SEC5_NO_JOB_KILL
                                                             : SEC5_BASELINE;
  if (!child_read(GetStdHandle(STD_INPUT_HANDLE), reply.nonce,
                  sizeof(reply.nonce)))
    return 109;
  if (!fmt(s.child, CAP, L"%ls", argv[3]) ||
      !fmt(s.dest, CAP, L"%ls", argv[4]) ||
      !fmt(s.sid_text, 256, L"%ls", argv[5]) ||
      !fmt(s.user_text, 256, L"%ls", argv[6]) ||
      !ConvertStringSidToSidW(s.sid_text, &s.lease) ||
      !ConvertStringSidToSidW(s.user_text, &s.user) ||
      !make_default_sd(&s, &s.default_sd) ||
      !GetSecurityDescriptorDacl(s.default_sd, &present, &s.default_dacl, &def))
    goto failed;
  if (mode == 2) {
    outer = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!outer ||
        !SetInformationJobObject(outer, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits)) ||
        !AssignProcessToJobObject(outer, GetCurrentProcess()))
      goto failed;
  }
  if (!make_pipe(&in_read, &in_write, FALSE) ||
      !make_pipe(&out_read, &out_write, TRUE) ||
      !make_pipe(&err_read, &err_write, TRUE))
    goto failed;
  env = environment(s.dest,
                    s.backend == SEC5_APPCONTAINER &&
                        s.mutation != SEC5_NO_APPCONTAINER,
                    FALSE, NULL);
  if (!env)
    goto failed;
  pin = CreateFileW(s.child, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (pin == INVALID_HANDLE_VALUE ||
      !fmt(command, CAP * 2, L"\"%ls\" act %u \"-\" 0 0 0 0", s.child, OP_TREE))
    goto failed;
  HANDLE handles[] = {in_read, out_write, err_write};
  sec5_request request = {0};
  request.executable = s.child;
  request.executable_pin = pin;
  request.command_line = command;
  request.cwd = s.dest;
  request.environment = env;
  request.backend = s.backend;
  request.lease_sid = s.lease;
  request.default_dacl = s.default_dacl;
  request.handles = handles;
  request.handle_count = 3;
  request.mutation = s.mutation;
  request.observe_suspended = observe_token;
  request.observer_context = &s;
  request.stdin_handle = in_read;
  request.stdout_handle = out_write;
  request.stderr_handle = err_write;
  if (!sec5_launch_fixture(&request, &child)) {
    reply.error = child.error;
    reply.stage = child.stage;
    goto report;
  }
  CloseHandle(in_read);
  in_read = NULL;
  CloseHandle(out_write);
  out_write = NULL;
  CloseHandle(err_write);
  err_write = NULL;
  packet tree;
  if (!write_all(in_write, reply.nonce, sizeof(reply.nonce)) ||
      !read_deadline(out_read, &tree, sizeof(tree)) || tree.magic != MAGIC ||
      tree.pid != child.pi.dwProcessId || tree.operation != OP_TREE ||
      !tree.descendant || memcmp(tree.nonce, reply.nonce, sizeof(reply.nonce)))
    goto failed;
  reply.suspended_token_checked = s.token_ok;
  reply.child_pid = child.pi.dwProcessId;
  reply.child_time = child.creation_time;
  reply.grandchild_pid = tree.descendant;
  reply.grandchild_time = tree.descendant_time;
  reply.inner_job = (uintptr_t)child.job;
  reply.outer_job = (uintptr_t)outer;
  goto report;
failed:
  reply.error = GetLastError();
  if (!reply.error)
    reply.error = ERROR_GEN_FAILURE;
report:
  if (reply.error)
    fprintf(stderr, "BROKER_LAUNCH_FAILED stage=%lu WIN32=%lu exit=105\n",
            (unsigned long)reply.stage, (unsigned long)reply.error);
  if (!write_all(GetStdHandle(STD_OUTPUT_HANDLE), &reply, sizeof(reply)))
    return 108;
  /* Failure packets need no parent release; stdout remains binary only. */
  if (!reply.error)
    child_wait();
  if (!reply.error && mode == 1)
    TerminateProcess(GetCurrentProcess(),
                     91); /* Deliberate own broker crash. */
  /* Parent has process handles, never a Job handle for close/crash variants. */
  if (child.job && !CloseHandle(child.job))
    return 107;
  child.job = NULL;
  if (child.pi.hProcess &&
      WaitForSingleObject(child.pi.hProcess, WAIT_MS) != WAIT_OBJECT_0)
    return 106;
  close_handle(&child.pi.hThread);
  close_handle(&child.pi.hProcess);
  close_handle(&in_read);
  close_handle(&in_write);
  close_handle(&out_read);
  close_handle(&out_write);
  close_handle(&err_read);
  close_handle(&err_write);
  close_handle(&pin);
  if (s.default_sd)
    LocalFree(s.default_sd);
  if (s.lease)
    LocalFree(s.lease);
  if (s.user)
    LocalFree(s.user);
  free(env);
  /* Closing the outer job containing this broker terminates the broker.
     Let normal process exit close it instead. */
  return reply.error ? 105 : 0;
}
static BOOL identified_pid(DWORD pid, FILETIME time, DWORD parent,
                           HANDLE parent_pin, FILETIME parent_birth,
                           HANDLE *process) {
  packet p = {0};
  p.descendant = pid;
  p.descendant_time = time;
  p.pid = parent;
  return observed_descendant(&p, parent_pin, parent_birth, process);
}
static void broker_cases(suite *s) {
  BOOL close_ok = TRUE, nested_ok = TRUE;
  for (unsigned mode = 0; mode < 3; ++mode) {
    WCHAR args[CAP * 3];
    run broker = {0};
    broker_packet reply = {0};
    HANDLE child = NULL, grandchild = NULL, inner = NULL, outer = NULL;
    BOOL prepared =
        fmt(args, CAP * 3, L"broker %u \"%ls\" \"%ls\" \"%ls\" \"%ls\" %ls",
            mode, s->child, s->dest, s->sid_text, s->user_text,
            s->backend == SEC5_APPCONTAINER
                ? (s->mutation == SEC5_NO_JOB_KILL ? L"appcontainer-no-job-kill"
                                                   : L"appcontainer")
                : L"restricted");
    BOOL started =
        prepared && launch_run(s, &broker, TRUE, s->child, args, FALSE);
    BOOL exchange_ok =
        started &&
        write_all(broker.in_write, broker.nonce, sizeof(broker.nonce)) &&
        read_deadline(broker.out_read, &reply, sizeof(reply)) &&
        reply.magic == MAGIC &&
        !memcmp(reply.nonce, broker.nonce, sizeof(reply.nonce));
    if (exchange_ok && reply.error) {
      api_error("broker governed launch", reply.error);
      if (reply.stage == SEC5_CREATE)
        s->blocked = TRUE;
    }
    BOOL owned =
        exchange_ok && !reply.error && reply.suspended_token_checked &&
        identified_pid(
            reply.child_pid, reply.child_time, broker.process.pi.dwProcessId,
            broker.process.pi.hProcess, broker.process.creation_time, &child) &&
        identified_pid(reply.grandchild_pid, reply.grandchild_time,
                       reply.child_pid, child, reply.child_time, &grandchild);
    BOOL live = owned &&
                (s->backend != SEC5_APPCONTAINER ||
                 (appcontainer_token(child, s->lease, TRUE) &&
                  appcontainer_token(grandchild, s->lease, TRUE))) &&
                WaitForSingleObject(child, 0) == WAIT_TIMEOUT &&
                WaitForSingleObject(grandchild, 0) == WAIT_TIMEOUT;
    BOOL membership = TRUE;
    if (mode == 2) {
      membership = live &&
                   DuplicateHandle(broker.process.pi.hProcess,
                                   (HANDLE)reply.inner_job, GetCurrentProcess(),
                                   &inner, 0, FALSE, DUPLICATE_SAME_ACCESS) &&
                   DuplicateHandle(broker.process.pi.hProcess,
                                   (HANDLE)reply.outer_job, GetCurrentProcess(),
                                   &outer, 0, FALSE, DUPLICATE_SAME_ACCESS);
      BOOL a = FALSE, b = FALSE, c = FALSE, d = FALSE;
      membership = membership && IsProcessInJob(child, inner, &a) &&
                   IsProcessInJob(child, outer, &b) &&
                   IsProcessInJob(grandchild, inner, &c) &&
                   IsProcessInJob(grandchild, outer, &d) && a && b && c && d;
      /* Do not keep the last Job handle alive when the broker exits. */
      close_handle(&inner);
      close_handle(&outer);
    }
    BYTE release = 1;
    BOOL exited = exchange_ok && write_all(broker.in_write, &release, 1) &&
                  WaitForSingleObject(broker.process.pi.hProcess, WAIT_MS) ==
                      WAIT_OBJECT_0;
    BOOL dead = owned && WaitForSingleObject(child, WAIT_MS) == WAIT_OBJECT_0 &&
                WaitForSingleObject(grandchild, WAIT_MS) == WAIT_OBJECT_0;
    DWORD exit_code = 0;
    BOOL status = GetExitCodeProcess(broker.process.pi.hProcess, &exit_code) &&
                  (mode == 1 ? exit_code == 91 : exit_code == 0);
    printf("BROKER mode=%u live_before=%d broker_exit=%lu children_dead=%d "
           "parent_job_handles=%s nested_membership=%d "
           "suspended_token_checked=%d\n",
           mode, live, (unsigned long)exit_code, dead,
           mode == 2 ? "duplicated then closed" : "NONE", membership,
           reply.suspended_token_checked);
    BOOL clean = dispose_run(&broker);
    BOOL clean_child = wait_observed(child),
         clean_grandchild = wait_observed(grandchild);
    BOOL good = started && exchange_ok && live && membership && exited &&
                dead && status && clean && clean_child && clean_grandchild;
    if (mode == 2)
      nested_ok = good;
    else
      close_ok = close_ok && good;
    if (s->blocked)
      break;
  }
  result(s, 18, nested_ok,
         "separate broker enters outer Job; parent independently queries "
         "child/grandchild in inner and outer Jobs");
  result(s, 19, close_ok,
         "sole broker Job handle; normal close and own crash; parent retains "
         "only PID+time-verified process handles, observes both deaths");
}

static void inline_case(suite *s, BOOL python) {
  unsigned id = python ? 27 : 26;
  WCHAR executable[CAP], arguments[CAP * 3], marker[CAP];
  const WCHAR *program = python ? L"python.exe" : L"node.exe";
  DWORD size = SearchPathW(NULL, program, NULL, CAP, executable, NULL);
  printf("RUNTIME_SEARCH name=%ls result=%lu path=%ls\n", program,
         (unsigned long)size, size && size < CAP ? executable : L"ABSENT");
  if (!size) {
    if (!s->allow_missing_runtimes) {
      result(s, id, FALSE,
             "required runtime missing; omission requires explicit "
             "-AllowMissingRuntimes");
      return;
    }
    printf("%s | SKIPPED | runtime not installed/resolvable; no download\n",
           names[id]);
    ++s->skipped;
    return;
  }
  if (size >= CAP || !fmt(marker, CAP, L"%ls\\%ls.bin", s->dest,
                          python ? L"python" : L"node")) {
    result(s, id, FALSE, "runtime/path overflow");
    return;
  }
  /* Constant inline code authored by this fixture. Relative paths and cwd
     are fixed by the parent; no user-supplied script is dispatched. */
  const WCHAR *script =
      python ? L"-B -c \"from pathlib import Path; "
               L"Path('python.bin').write_bytes(b'SEC5_INLINE'); exec('try:\\n "
               L"Path(\\'../medium/"
               L"python-out.bin\\').write_bytes(b\\'OUT\\')\\nexcept "
               L"PermissionError:\\n pass')\""
             : L"-e \"const "
               L"f=require('fs');f.writeFileSync('node.bin','SEC5_INLINE');try{"
               L"f.writeFileSync('../medium/"
               L"node-out.bin','OUT')}catch(e){if(e.code!=='EACCES'&&e.code!=='"
               L"EPERM')throw e}\"";
  if (!fmt(arguments, CAP * 3, L"%ls", script)) {
    result(s, id, FALSE, "inline argument overflow");
    return;
  }
  WCHAR outside[CAP];
  if (!fmt(outside, CAP, L"%ls\\%ls-out.bin", s->medium,
           python ? L"python" : L"node")) {
    result(s, id, FALSE, "outside fixture overflow");
    return;
  }
  static const BYTE bytes[] = "SEC5_INLINE";
  BOOL good = TRUE;
  for (unsigned i = 0; i < 2; ++i) {
    run r = {0};
    BOOL launched = launch_run(s, &r, i == 0, executable, arguments, FALSE);
    BOOL exited = launched && WaitForSingleObject(r.process.pi.hProcess,
                                                  WAIT_MS) == WAIT_OBJECT_0;
    DWORD exit_code = 0;
    BOOL code = exited &&
                GetExitCodeProcess(r.process.pi.hProcess, &exit_code) &&
                exit_code == 0;
    BOOL content = file_bytes(marker, bytes, sizeof(bytes) - 1, FALSE);
    BOOL outside_exists =
        GetFileAttributesW(outside) != INVALID_FILE_ATTRIBUTES;
    BOOL clean = dispose_run(&r);
    good = good && code && content &&
           (i == 0 ? outside_exists : !outside_exists) && clean;
    printf("INLINE runtime=%ls ordinary=%u exit=%lu marker_correct=%d "
           "outside_fixture_written=%d\n",
           program, i == 0, (unsigned long)exit_code, content, outside_exists);
    if (content && !DeleteFileW(marker))
      good = FALSE;
    if (outside_exists && !DeleteFileW(outside))
      good = FALSE;
    if (s->blocked)
      break;
  }
  result(
      s, id, good,
      "real pinned interpreter; fixed inline bytes; parent checks destination "
      "contents and medium exterior fixture; ordinary positive control");
}

int sec5_child_main(void) {
  int argc = 0;
  WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv || argc < 2) {
    if (argv)
      LocalFree(argv);
    return 104;
  }
  int code = 103;
  if (!wcscmp(argv[1], L"cycle-child") || !wcscmp(argv[1], L"cycle-grand"))
    code = cycle_child(argc, argv);
  else if (!wcscmp(argv[1], L"linger"))
    Sleep(INFINITE);
  else if (!wcscmp(argv[1], L"zero"))
    code = 0;
  else if (!wcscmp(argv[1], L"act"))
    code = child_act(argc, argv);
  else if (!wcscmp(argv[1], L"broker"))
    code = broker_main(argc, argv);
  else if (!wcscmp(argv[1], L"target")) {
    BYTE *memory =
        VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    packet reply = {0};
    reply.magic = MAGIC;
    reply.pid = GetCurrentProcessId();
    reply.address = (uintptr_t)memory;
    if (!memory || !random_bytes(reply.nonce, sizeof(reply.nonce)))
      code = 102;
    else {
      memcpy(memory, reply.nonce, sizeof(reply.nonce));
      if (!write_all(GetStdHandle(STD_OUTPUT_HANDLE), &reply, sizeof(reply)))
        code = 101;
      else
        Sleep(INFINITE);
    }
    if (memory)
      VirtualFree(memory, 0, MEM_RELEASE);
  }
  LocalFree(argv);
  return code;
}
static BOOL mutation_parse(const WCHAR *name, enum sec5_mutation *mutation) {
  static const WCHAR *const options[] = {L"baseline",
                                         L"no-il",
                                         L"no-sid",
                                         L"no-write-restricted",
                                         L"breakaway-ok",
                                         L"no-handle-list",
                                         L"resume-first",
                                         L"restore-auto-inherit",
                                         L"no-appcontainer",
                                         L"reuse-profile",
                                         L"exterior-grant",
                                         L"no-job-kill",
                                         L"dest-rx-only",
                                         L"merge-stderr",
                                         L"no-runtime-capability",
                                         L"runtime-write",
                                         L"internet-client"};
  for (unsigned i = 0; i < sizeof(options) / sizeof(options[0]); ++i)
    if (!wcscmp(name, options[i])) {
      *mutation = (enum sec5_mutation)i;
      return TRUE;
    }
  return FALSE;
}
/* Operator recovery of the two named R1/R1B fixtures only. These constants come
   from orq-p1v3-r1[-b]-baseline-20261013.txt, not a prefix scan or production
   journal. No arbitrary root/moniker is accepted by this command. */
typedef struct recovery_fixture {
  const WCHAR *root_name, *profiles[2], *sid_text[2];
} recovery_fixture;
static HANDLE recovery_open(HANDLE parent, const WCHAR *name, BOOL directory) {
  union {
    ULONGLONG alignment;
    BYTE bytes[sizeof(FILE_ID_BOTH_DIR_INFO) + CAP * sizeof(WCHAR)];
  } buffer = {0};
  size_t length = wcslen(name);
  if (!length || length >= CAP || wcspbrk(name, L"\\/:")) {
    SetLastError(ERROR_INVALID_NAME);
    return INVALID_HANDLE_VALUE;
  }
  FILE_ID_BOTH_DIR_INFO *entry = (FILE_ID_BOTH_DIR_INFO *)buffer.bytes;
  entry->FileNameLength = (DWORD)(length * sizeof(WCHAR));
  entry->FileAttributes = directory ? FILE_ATTRIBUTE_DIRECTORY : 0;
  memcpy(entry->FileName, name, entry->FileNameLength);
  return open_cleanup_child(parent, entry,
                            READ_CONTROL | WRITE_DAC | WRITE_OWNER);
}
static BOOL recovery_owned(const snapshot *snap, suite *s, PSID second) {
  PSID owner = NULL, group = NULL;
  PACL dacl = NULL, sacl = NULL;
  BOOL present, def;
  if (!GetSecurityDescriptorOwner(snap->sd, &owner, &def) ||
      !GetSecurityDescriptorGroup(snap->sd, &group, &def) ||
      !sid_equal(owner, s->user) || !sid_equal(group, s->user) ||
      !GetSecurityDescriptorDacl(snap->sd, &present, &dacl, &def) || !present ||
      !dacl || !IsValidAcl(dacl) || !dacl->AceCount)
    return FALSE;
  BYTE system_bytes[SECURITY_MAX_SID_SIZE], owner_bytes[SECURITY_MAX_SID_SIZE];
  DWORD system_size = sizeof(system_bytes), owner_size = sizeof(owner_bytes);
  if (!CreateWellKnownSid(WinLocalSystemSid, NULL, system_bytes,
                          &system_size) ||
      !CreateWellKnownSid(WinCreatorOwnerRightsSid, NULL, owner_bytes,
                          &owner_size))
    return FALSE;
  BOOL user_access = FALSE;
  for (DWORD i = 0; i < dacl->AceCount; ++i) {
    ACCESS_ALLOWED_ACE *ace = NULL;
    if (!GetAce(dacl, i, (void **)&ace) ||
        ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE ||
        ace->Header.AceSize <
            offsetof(ACCESS_ALLOWED_ACE, SidStart) + sizeof(SID))
      return FALSE;
    PSID trustee = &ace->SidStart;
    if (GetSidLengthRequired(((SID *)trustee)->SubAuthorityCount) >
            ace->Header.AceSize - offsetof(ACCESS_ALLOWED_ACE, SidStart) ||
        !IsValidSid(trustee))
      return FALSE;
    BOOL user = sid_equal(trustee, s->user);
    if (user || sid_equal(trustee, system_bytes)) {
      if (ace->Mask != FILE_ALL_ACCESS)
        return FALSE;
      user_access = user_access || user;
    } else if (sid_equal(trustee, owner_bytes)) {
      if (ace->Mask != READ_CONTROL)
        return FALSE;
    } else if (sid_equal(trustee, s->lease) ||
               (second && sid_equal(trustee, second))) {
      if (ace->Mask != (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE) &&
          ace->Mask != 0x001201ff)
        return FALSE;
    } else
      return FALSE;
  }
  if (!GetSecurityDescriptorSacl(snap->sd, &present, &sacl, &def))
    return FALSE;
  if (present && sacl) {
    DWORD index = 0;
    ACE_HEADER *other = NULL;
    if (!next_sacl_ace(sacl, &index, FALSE, &other) || other)
      return FALSE;
  }
  return user_access;
}
/* Saved SDDL from orq-p1v3-r1b-baseline-20261013.txt: lines 12,15-17,
   110-111 (R1 has the same directory descriptors, lines 12,15-17).
   Use mapped FA, not the pre-creation GA template. The private executable's
   saved descriptor already contains package A, before the package B grant. */
static BOOL recovery_original(suite *s, BOOL directory, int il,
                              PSECURITY_DESCRIPTOR *sd) {
  WCHAR text[2048], label[128] = L"", package[512] = L"";
  const WCHAR *inherit = directory ? L"OICI" : L"";
  if (il >= 0 &&
      !fmt(label, 128, L"S:AI(ML;OICI;NW;;;%ls)", il == 0 ? L"LW" : L"ME"))
    return FALSE;
  if (!directory && !fmt(package, 512, L"(A;;0x1200a9;;;%ls)", s->sid_text))
    return FALSE;
  return fmt(text, 2048,
             L"O:%lsG:%lsD:P(A;%ls;FA;;;%ls)(A;%ls;FA;;;SY)(A;%ls;RC;;;OW)%ls%"
             L"ls",
             s->user_text, s->user_text, inherit, s->user_text, inherit,
             inherit, package, label) &&
         ConvertStringSecurityDescriptorToSecurityDescriptorW(
             text, SDDL_REVISION_1, sd, NULL);
}
static BOOL recovery_remove_packages(const snapshot *snap, suite *s,
                                     PSID second) {
  PSECURITY_DESCRIPTOR current = NULL;
  PACL acl = NULL, clean = NULL, actual_acl = NULL;
  BOOL present, def;
  SECURITY_DESCRIPTOR descriptor;
  SECURITY_DESCRIPTOR_CONTROL control;
  DWORD revision, removed = 0;
  BOOL good = identity_matches(snap->handle, &snap->identity, NULL) &&
              kernel_sd(snap->handle, SD_INFO, &current) &&
              GetSecurityDescriptorDacl(current, &present, &acl, &def) &&
              present && acl && IsValidAcl(acl);
  if (good) {
    clean = LocalAlloc(LMEM_FIXED, acl->AclSize);
    good = clean && InitializeAcl(clean, acl->AclSize, acl->AclRevision);
  }
  for (DWORD i = 0; good && i < acl->AceCount; ++i) {
    ACCESS_ALLOWED_ACE *ace = NULL;
    good = GetAce(acl, i, (void **)&ace) &&
           ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE;
    if (!good)
      break;
    if (sid_equal(&ace->SidStart, s->lease) ||
        (second && sid_equal(&ace->SidStart, second)))
      ++removed;
    else
      good =
          AddAce(clean, acl->AclRevision, MAXDWORD, ace, ace->Header.AceSize);
  }
  if (good && removed)
    good = GetSecurityDescriptorControl(current, &control, &revision) &&
           InitializeSecurityDescriptor(&descriptor,
                                        SECURITY_DESCRIPTOR_REVISION) &&
           SetSecurityDescriptorDacl(&descriptor, TRUE, clean, FALSE) &&
           SetSecurityDescriptorControl(
               &descriptor,
               SE_DACL_PROTECTED | SE_DACL_AUTO_INHERITED |
                   SE_DACL_AUTO_INHERIT_REQ,
               control & (SE_DACL_PROTECTED | SE_DACL_AUTO_INHERITED |
                          SE_DACL_AUTO_INHERIT_REQ)) &&
           SetKernelObjectSecurity(snap->handle, DACL_SECURITY_INFORMATION,
                                   &descriptor);
  PSECURITY_DESCRIPTOR actual = NULL;
  if (good)
    good = kernel_sd(snap->handle, DACL_SECURITY_INFORMATION, &actual) &&
           GetSecurityDescriptorDacl(actual, &present, &actual_acl, &def) &&
           present && dacl_equal(clean, actual_acl);
  printf("RECOVERY_PACKAGE_ACES removed=%lu exact_remaining_dacl=%d\n",
         (unsigned long)removed, good);
  if (actual)
    LocalFree(actual);
  if (clean)
    LocalFree(clean);
  if (current)
    LocalFree(current);
  return good;
}
static BOOL recovery_restore(HANDLE parent, const WCHAR *name, BOOL directory,
                             int il, suite *s, PSID second) {
  HANDLE object = recovery_open(parent, name, directory);
  if (object == INVALID_HANDLE_VALUE) {
    DWORD error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
  }
  snapshot captured = {0}, original = {0};
  BOOL good = snapshot_take(&captured, object, SE_FILE_OBJECT, TRUE) &&
              identity_matches(object, &captured.identity, NULL) &&
              recovery_owned(&captured, s, second);
  original = captured;
  original.sd = NULL;
  if (good)
    good = recovery_original(s, directory, il, &original.sd);
  if (good) {
    original.length = GetSecurityDescriptorLength(original.sd);
    good = recovery_remove_packages(&captured, s, second) && restore(&original);
  }
  printf("RECOVERY_RESTORE name=%ls original_descriptor_exact=%d\n", name,
         good);
  /* The saved executable includes A. Prove exact restoration first, then
     revoke its recorded creation grant before removing the private copy. */
  if (good && !directory)
    good = recovery_remove_packages(&captured, s, second);
  if (original.sd)
    LocalFree(original.sd);
  snapshot_dispose(&captured);
  return good;
}
static BOOL recovery_quiescent(void) {
  HANDLE processes = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (processes == INVALID_HANDLE_VALUE)
    return FALSE;
  PROCESSENTRY32W entry = {0};
  entry.dwSize = sizeof(entry);
  BOOL good = Process32FirstW(processes, &entry);
  if (good) {
    do {
      /* All children/targets/brokers in these two baseline logs use this
         private executable. Never terminate a PID found during recovery. */
      if (!_wcsicmp(entry.szExeFile, L"sec5-child.exe") ||
          (!_wcsicmp(entry.szExeFile, L"sec5-os.exe") &&
           entry.th32ProcessID != GetCurrentProcessId())) {
        printf("RECOVERY_BLOCKED live_fixture pid=%lu image=%ls\n",
               (unsigned long)entry.th32ProcessID, entry.szExeFile);
        good = FALSE;
        break;
      }
    } while (Process32NextW(processes, &entry));
    if (good && GetLastError() != ERROR_NO_MORE_FILES)
      good = FALSE;
  }
  CloseHandle(processes);
  return good;
}
static BOOL recover_fixture(suite *s, HANDLE base,
                            const recovery_fixture *fixture) {
  PSID packages[2] = {NULL};
  BOOL good = TRUE;
  for (unsigned i = 0; good && i < 2 && fixture->profiles[i]; ++i) {
    HRESULT hr = DeriveAppContainerSidFromAppContainerName(fixture->profiles[i],
                                                           &packages[i]);
    PSID recorded = NULL;
    good = SUCCEEDED(hr) &&
           ConvertStringSidToSidW(fixture->sid_text[i], &recorded) &&
           sid_equal(packages[i], recorded);
    if (recorded)
      LocalFree(recorded);
    printf("RECOVERY_PROFILE_ID moniker=%ls recorded_sid_match=%d\n",
           fixture->profiles[i], good);
  }
  HANDLE root = good ? recovery_open(base, fixture->root_name, TRUE)
                     : INVALID_HANDLE_VALUE;
  DWORD error = GetLastError();
  snapshot captured = {0}, original = {0};
  s->lease = packages[0];
  if (root != INVALID_HANDLE_VALUE) {
    good = snapshot_take(&captured, root, SE_FILE_OBJECT, TRUE) &&
           identity_matches(root, &captured.identity, NULL) &&
           recovery_owned(&captured, s, packages[1]) &&
           fmt(s->sid_text, 256, L"%ls", fixture->sid_text[0]);
    const WCHAR *directories[] = {L"prepared", L"medium", L"foreign-low",
                                  L"second-order"};
    const int labels[] = {-1, 1, 0, -1};
    for (unsigned i = 0; good && i < 4; ++i)
      good = recovery_restore(root, directories[i], TRUE, labels[i], s,
                              packages[1]);
    if (good)
      good =
          recovery_restore(root, L"sec5-child.exe", FALSE, -1, s, packages[1]);
    original = captured;
    original.sd = NULL;
    if (good)
      good = recovery_original(s, TRUE, -1, &original.sd);
    if (good) {
      original.length = GetSecurityDescriptorLength(original.sd);
      good = recovery_remove_packages(&captured, s, packages[1]) &&
             restore(&original) && cleanup_tree(root, &captured.identity, 0);
    }
    if (original.sd)
      LocalFree(original.sd);
    snapshot_dispose(&captured);
  } else
    good = good &&
           (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND);
  printf("RECOVERY_TREE root=%ls restored_and_removed_or_absent=%d\n",
         fixture->root_name, good);
  for (unsigned i = 0; good && i < 2 && fixture->profiles[i]; ++i) {
    LPWSTR path = NULL;
    WCHAR recorded_path[CAP];
    good = fmt(recorded_path, CAP,
               L"C:\\Workspace\\Usuario\\AppData\\Local\\Packages\\%ls\\AC",
               fixture->profiles[i]);
    if (!good)
      break;
    HRESULT storage = GetAppContainerFolderPath(fixture->sid_text[i], &path);
    /* An already deleted profile need not resolve through this API. Its exact
       storage path is also in the baseline log; absence permits an idempotent
       DeleteAppContainerProfile, without guessing from an arbitrary HRESULT. */
    good = SUCCEEDED(storage) ? path && !_wcsicmp(path, recorded_path)
                              : storage_absent(recorded_path);
    HRESULT hr = good ? DeleteAppContainerProfile(fixture->profiles[i])
                      : HRESULT_FROM_WIN32(ERROR_FILE_INVALID);
    good = good && SUCCEEDED(hr) && storage_absent(recorded_path);
    printf("RECOVERY_PROFILE_DELETE moniker=%ls HRESULT=0x%08lx "
           "STORAGE_HRESULT=0x%08lx storage_absent=%d\n",
           fixture->profiles[i], (unsigned long)hr, (unsigned long)storage,
           good);
    if (path)
      CoTaskMemFree(path);
  }
  s->lease = NULL;
  for (unsigned i = 0; i < 2; ++i)
    if (packages[i])
      FreeSid(packages[i]);
  return good;
}
static int recover_r1_fixtures(void) {
  static const recovery_fixture fixtures[] = {
      {L".sec5-fixture-f291ee5c-0738-45ef-b487-0ce8336a99cb",
       {L"DevAgents.Sec5.31d073d04b076121d09153ba19ab9ecf",
        L"DevAgents.Sec5.a2c26bf9744fa118b6b2a2e0acd6c1f4"},
       {L"S-1-15-2-1157686991-2242244850-4273739641-958867081-3158553874-"
        L"2403606748-562490654",
        L"S-1-15-2-354533319-2237745323-1529385888-3578914532-1066142575-"
        L"3996447966-1072929744"}},
      {L".sec5-fixture-597f593a-15b1-41f3-b7cf-9c5fae3a4b44",
       {L"DevAgents.Sec5.dc21081a01f59fd5c1f92abc8c92df83", NULL},
       {L"S-1-15-2-2931392019-3038287228-3093103220-4120403695-728956409-"
        L"2897280940-714079329",
        NULL}}};
  suite s = {0};
  if (!parent_representative(&s) ||
      wcscmp(s.user_text, L"S-1-5-21-3357080530-2067231091-733135328-1001") ||
      !ConvertStringSidToSidW(s.user_text, &s.user) || !recovery_quiescent()) {
    if (s.user)
      LocalFree(s.user);
    printf("RECOVERY_BLOCKED owner/environment/live fixture mismatch\n");
    return 78;
  }
  HANDLE base = open_dir(
      L"C:\\Workspace\\Usuario\\Desktop\\Proyectos\\DevAgents-wt\\sec-os",
      FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES);
  FILE_ID_INFO identity;
  BOOL good = base != INVALID_HANDLE_VALUE &&
              GetFileInformationByHandleEx(base, FileIdInfo, &identity,
                                           sizeof(identity)) &&
              identity_matches(base, &identity, NULL);
  for (unsigned i = 0; good && i < sizeof(fixtures) / sizeof(fixtures[0]); ++i)
    good = recover_fixture(&s, base, &fixtures[i]);
  close_handle(&base);
  LocalFree(s.user);
  printf("RECOVERY_SUMMARY success=%d scope=R1-R1B-exact-allowlist "
         "production_journal=NOT_VERIFIED\n",
         good);
  return good ? 0 : 78;
}
#include "sec5_cycle.inc"
#include "sec5_runtime.inc"

int sec5_suite_main(void) {
  int argc = 0;
  WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv && argc >= 2 && !wcsncmp(argv[1], L"cycle-", 6)) {
    int code = cycle_dispatch(argc, argv, FALSE);
    LocalFree(argv);
    return code;
  }
  if (argv && argc == 2 && !wcscmp(argv[1], L"recover")) {
    LocalFree(argv);
    return recover_r1_fixtures();
  }
  suite s = {0};
  s.backend = SEC5_APPCONTAINER;
  BOOL valid = argv && argc >= 2 && argc <= 6;
  BOOL mutation_seen = FALSE;
  for (int i = 2; valid && i < argc; ++i) {
    if (!wcscmp(argv[i], L"-RestrictedDiagnostic"))
      s.backend = SEC5_RESTRICTED_DIAGNOSTIC;
    else if (!wcscmp(argv[i], L"-AllowMissingRuntimes"))
      s.allow_missing_runtimes = TRUE;
    else if (!wcscmp(argv[i], L"-RuntimeMatrix"))
      s.runtime_matrix = TRUE;
    else if (!mutation_seen && mutation_parse(argv[i], &s.mutation))
      mutation_seen = TRUE;
    else
      valid = FALSE;
  }
  if (s.backend == SEC5_APPCONTAINER &&
      (s.mutation == SEC5_NO_IL || s.mutation == SEC5_NO_SID ||
       s.mutation == SEC5_NO_WRITE_RESTRICTED ||
       s.mutation == SEC5_RESTORE_AUTO_INHERIT))
    valid = FALSE;
  if (s.backend == SEC5_RESTRICTED_DIAGNOSTIC &&
      s.mutation > SEC5_RESTORE_AUTO_INHERIT)
    valid = FALSE;
  if ((s.runtime_matrix &&
       (s.backend != SEC5_APPCONTAINER || s.allow_missing_runtimes)) ||
      (!s.runtime_matrix && s.mutation >= SEC5_NO_RUNTIME_CAPABILITY))
    valid = FALSE;
  if (!valid) {
    fprintf(
        stderr,
        "usage: sec5-os recover | <absolute-sec5-child.exe> [mutation] "
        "[-RestrictedDiagnostic] [-AllowMissingRuntimes] [-RuntimeMatrix]\n");
    if (argv)
      LocalFree(argv);
    return 2;
  }
  printf("SEC5 backend=%s round=%u mutation=%u fixture-only; "
         "profile-recovery/production NOT VERIFIED\n",
         s.backend == SEC5_APPCONTAINER ? "appcontainer"
                                        : "restricted-diagnostic",
         s.runtime_matrix ? 2u : 1u, s.mutation);
  if (!parent_representative(&s)) {
    LocalFree(argv);
    return 77;
  }
  BOOL prepared = setup(&s, argv[1]);
  LocalFree(argv);
  if (!prepared) {
    api_error("SEC5 fixture preparation", GetLastError());
    s.blocked = TRUE;
  } else if (s.mutation == SEC5_RESUME_FIRST) {
    failure_case(&s);
  } else if (s.backend == SEC5_APPCONTAINER) {
    stdio_and_token(&s);
    if (!s.blocked)
      file_case(&s, 30, s.medium, FALSE);
    if (!s.blocked)
      file_case(&s, 4, s.dest, TRUE);
    if (!s.blocked)
      read_case(&s);
    if (!s.blocked)
      process_cases(&s);
    if (!s.blocked)
      appcontainer_cross_lease(&s);
    if (!s.blocked)
      handles_case(&s);
    if (!s.blocked)
      zero_handles_case(&s);
    if (!s.blocked)
      failure_case(&s);
    if (!s.blocked)
      job_cases(&s);
    if (!s.blocked)
      broker_cases(&s);
    if (s.runtime_matrix && !s.blocked) {
      runtime_mic_case(&s);
      file_case(&s, 3, s.foreign, FALSE);
      registry_case(&s);
      session_cases(&s);
      winsta_case(&s);
      label_roundtrip(&s);
      runtime_no_write_owner_case(&s);
      runtime_inheritance_case(&s);
      security_case(&s);
      runtime_matrix_cases(&s);
    }
  } else {
    stdio_and_token(&s);
    if (!s.blocked)
      file_case(&s, 2, s.medium, FALSE);
    if (!s.blocked)
      file_case(&s, 3, s.foreign, FALSE);
    if (!s.blocked)
      file_case(&s, 4, s.dest, TRUE);
    if (!s.blocked)
      read_case(&s);
    if (!s.blocked)
      registry_case(&s);
    if (!s.blocked)
      process_cases(&s);
    if (!s.blocked)
      session_cases(&s);
    if (!s.blocked)
      default_dacl_case(&s);
    if (!s.blocked)
      winsta_case(&s);
    if (!s.blocked)
      handles_case(&s);
    if (!s.blocked)
      zero_handles_case(&s);
    if (!s.blocked)
      failure_case(&s);
    if (!s.blocked)
      job_cases(&s);
    if (!s.blocked)
      broker_cases(&s);
    if (!s.blocked)
      inheritance_case(&s);
    if (!s.blocked)
      security_case(&s);
    if (!s.blocked)
      inline_case(&s, FALSE);
    if (!s.blocked)
      inline_case(&s, TRUE);
  }
  BOOL cleaned = finish(&s);
  cleaned = cleaned && !s.isolated_cleanup_failed;
  s.labels_restored = s.labels_restored && !s.isolated_cleanup_failed;
  const unsigned app_required[] = {0,  1,  4,  5,  7,  8,  13, 15, 16,
                                   17, 18, 19, 20, 21, 28, 29, 30};
  unsigned required =
      s.backend == SEC5_APPCONTAINER
          ? (s.runtime_matrix ? 39u
                              : sizeof(app_required) / sizeof(app_required[0]))
          : 29;
  unsigned measured = 0, total = sizeof(names) / sizeof(names[0]);
  for (unsigned id = 0; id < total; ++id) {
    BOOL needed =
        s.backend == SEC5_RESTRICTED_DIAGNOSTIC ? id < 29 : s.runtime_matrix;
    if (s.backend == SEC5_APPCONTAINER && !s.runtime_matrix)
      for (unsigned i = 0; i < required; ++i)
        if (app_required[i] == id)
          needed = TRUE;
    if (s.mutation == SEC5_RESUME_FIRST)
      needed = id == 21;
    if (needed && s.reported[id])
      ++measured;
    if (!s.reported[id]) {
      ++s.unverified;
      printf("%s | NO VERIFICADO | %s\n", names[id],
             needed ? "required measurement missing; gate blocked"
                    : "outside round/backend scope");
    }
  }
  if (s.mutation == SEC5_RESUME_FIRST)
    required = 1;
  BOOL complete = measured == required;
  printf("SEC5 ACCOUNTING passed=%u failed=%u observed=%u counted=%u names=%u "
         "unverified=%u required=%u measured=%u complete=%d scope=%s\n",
         s.passed, s.failed, s.observed,
         s.passed + s.failed + s.observed + s.unverified, total, s.unverified,
         required, measured, complete,
         s.mutation == SEC5_RESUME_FIRST  ? "resume-first-only"
         : s.runtime_matrix               ? "appcontainer-r2"
         : s.backend == SEC5_APPCONTAINER ? "appcontainer-r1"
                                          : "full");
  BOOL gate_failed = s.failed || !complete || s.skipped || !cleaned;
  printf("SEC5 SUMMARY verdict=%s backend=%s passed=%u failed=%u observed=%u "
         "skipped=%u exact_label_restore=%d cleanup=%d\n",
         s.blocked                        ? "BLOCKED"
         : gate_failed                    ? "FAIL"
         : s.runtime_matrix               ? "R2_MEASURED"
         : s.backend == SEC5_APPCONTAINER ? "R1_MEASURED"
                                          : "VIABLE_WITH_CONDITIONS",
         s.backend == SEC5_APPCONTAINER ? "appcontainer"
                                        : "restricted-diagnostic",
         s.passed, s.failed, s.observed, s.skipped, s.labels_restored, cleaned);
  return s.blocked ? 78 : gate_failed ? 1 : 0;
}
