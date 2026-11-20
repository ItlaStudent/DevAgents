#ifndef BEATS_SEC5_LAUNCH_H
#define BEATS_SEC5_LAUNCH_H
/* Private P1 fixture ABI. Not exported by the product DLL. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#define _UNICODE
#endif
#include <aclapi.h>
#include <sddl.h>
#include <userenv.h>
#include <windows.h>

enum sec5_mutation {
  SEC5_BASELINE = 0,
  SEC5_NO_IL,
  SEC5_NO_SID,
  SEC5_NO_WRITE_RESTRICTED,
  SEC5_BREAKAWAY_OK,
  SEC5_NO_HANDLE_LIST,
  SEC5_RESUME_FIRST,
  SEC5_RESTORE_AUTO_INHERIT,
  SEC5_NO_APPCONTAINER,
  SEC5_REUSE_PROFILE,
  SEC5_EXTERIOR_GRANT,
  SEC5_NO_JOB_KILL,
  SEC5_DEST_RX_ONLY,
  SEC5_MERGE_STDERR,
  SEC5_NO_RUNTIME_CAPABILITY,
  SEC5_RUNTIME_WRITE,
  SEC5_INTERNET_CLIENT
};
enum sec5_backend { SEC5_RESTRICTED_DIAGNOSTIC = 0, SEC5_APPCONTAINER };
enum sec5_stage {
  SEC5_INPUT = 1,
  SEC5_TOKEN,
  SEC5_INTEGRITY,
  SEC5_POLICY,
  SEC5_JOB,
  SEC5_ATTRIBUTES,
  SEC5_CREATE,
  SEC5_ASSIGN,
  SEC5_OBSERVE,
  SEC5_SEEDED,
  SEC5_RESUME,
  SEC5_READY
};
typedef struct sec5_request {
  const WCHAR *executable;
  HANDLE
  executable_pin; /* Read-only, no WRITE/DELETE sharing; fixture-owned. */
  WCHAR *command_line;
  const WCHAR *cwd;
  const WCHAR *environment; /* Explicit double-NUL-terminated Unicode block. */
  PSID lease_sid;
  PSID
      runtime_capability; /* Optional devAgentsRuntime SID; RX runtimes only. */
  enum sec5_backend backend;
  PACL default_dacl;
  HANDLE *handles;
  DWORD handle_count;
  HANDLE stdin_handle, stdout_handle, stderr_handle;
  enum sec5_mutation mutation;
  BOOL fail_before_resume;
  enum sec5_stage fail_stage; /* Fixture-only cancellation boundary. */
  HANDLE harness_job; /* Fixture-owned outer containment, never inherited. */
  HANDLE
  early_event; /* Only the resume-order mutation waits on this witness. */
  int (*observe_suspended)(HANDLE, HANDLE, void *);
  void *observer_context;
  HANDLE recovery_job; /* R3 fixture-owned named Job, never inherited. */
  int (*lifecycle)(enum sec5_stage, HANDLE, HANDLE, void *);
} sec5_request;

typedef struct sec5_result {
  PROCESS_INFORMATION pi;
  HANDLE job;
  DWORD error, cleanup_error;
  enum sec5_stage stage;
  BOOL resumed;
  FILETIME creation_time;
} sec5_result;

int sec5_launch_fixture(const sec5_request *, sec5_result *);
#endif
