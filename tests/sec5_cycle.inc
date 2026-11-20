/* R3 only: durable fixture leases. No product databases or profile sweeps. */
#define CYCLE_VERSION 2u
#define CYCLE_SD_MAX 4096u
#define CYCLE_OBJECTS 3u
#define CYCLE_CRASH 86u
enum cycle_event {
  CY_PROFILE_INTENT = 1,
  CY_PROFILE_CREATED,
  CY_PREPARE_INTENT,
  CY_PREPARE_ACK,
  CY_SPAWN_INTENT,
  CY_ASSIGNED,
  CY_RUN_INTENT,
  CY_RUNNING,
  CY_TREE_CLOSED,
  CY_RESTORE_INTENT,
  CY_RESTORE_ACK,
  CY_DELETE_INTENT,
  CY_DELETE_RETRY,
  CY_FINAL,
  CY_COLLISION,
  CY_MUTATION_REPAIRED,
  CY_JOB_WITNESS,
  CY_ORPHAN_STORAGE
};
typedef struct cycle_object {
  FILE_ID_INFO id;
  FILETIME birth;
  DWORD attributes, original_length, prepared_length;
  BYTE original[CYCLE_SD_MAX], prepared[CYCLE_SD_MAX];
} cycle_object;
typedef struct cycle_profile_record {
  FILE_ID_INFO id;
  FILETIME birth;
  WCHAR path[CAP];
} cycle_profile_record;
typedef struct cycle_manifest {
  DWORD version, scenario, broker_pid;
  FILETIME broker_birth;
  LARGE_INTEGER boot_time;
  BYTE lease[16];
  WCHAR owner[256], moniker[64], sid[256], volume_guid[128];
  DWORD sid_length;
  BYTE package_sid[SECURITY_MAX_SID_SIZE];
  WCHAR job[128], ready[128], release[128], stop[128];
  WCHAR root[CAP];
  FILE_ID_INFO control_id, journal_id, catalog_id;
  FILETIME control_birth, journal_birth, catalog_birth;
  DWORD control_length;
  BYTE control_sd[CYCLE_SD_MAX];
  DWORD journal_length, catalog_length;
  BYTE journal_sd[CYCLE_SD_MAX], catalog_sd[CYCLE_SD_MAX];
  DWORD job_length;
  BYTE job_sd[CYCLE_SD_MAX];
  DWORD event_length;
  BYTE event_sd[CYCLE_SD_MAX];
  cycle_object objects[CYCLE_OBJECTS];
} cycle_manifest;
typedef struct cycle_record {
  DWORD length, version, sequence, type, index, payload_length;
  BYTE previous[32], digest[32];
} cycle_record;
typedef struct cycle_catalog {
  DWORD version, length;
  FILE_ID_INFO root_id, control_id, journal_id;
  BYTE lease[16], manifest_hash[32], digest[32];
} cycle_catalog;
typedef struct cycle_state {
  suite s;
  cycle_manifest m;
  HANDLE root, control, journal, catalog, job, ready, release, stop;
  HANDLE objects[CYCLE_OBJECTS];
  HANDLE holder;
  DWORD sequence, last, prepared, restored;
  BOOL intention, closed, final, collision, repaired, retry, spawned, assigned,
      running_intent;
  DWORD acknowledged;
  DWORD assigned_pid;
  FILETIME assigned_birth;
  DWORD witness_pid;
  FILETIME witness_birth;
  HANDLE ancestors[64];
  DWORD ancestor_count;
  BYTE digest[32];
  WCHAR base[CAP], path[CAP];
  LPWSTR profile_path;
  FILE_ID_INFO profile_id;
  FILETIME profile_birth;
  BOOL profile_known, profile_lookup_absent;
  DWORD live_fixtures, live_consoles, live_active;
  BOOL live_certified;
} cycle_state;
static const WCHAR *const cycle_names[] = {
    L"intent",   L"create",    L"grant-root", L"grant-dest", L"grant-exe",
    L"resume",   L"alive",     L"closed",     L"retry",      L"corrupt",
    L"identity", L"no-intent", L"clean-live", L"active",     L"foreign"};
static const WCHAR *const cycle_children[] = {L"", L"dest", L"sec5-child.exe"};
static BOOL cycle_reconcile(cycle_state *);
static BOOL cycle_dest_empty(cycle_state *);
static HANDLE cycle_open(const WCHAR *, BOOL, DWORD);
static BOOL cycle_markers(cycle_state *);

static BOOL cycle_check(BOOL actual, const char *check, const char *function,
                        int line) {
  if (actual)
    return TRUE;
  DWORD error = GetLastError();
  if (!error)
    error = ERROR_INVALID_DATA;
  printf("CYCLE_CHECK_FAIL check=%s expected=true obtained=false "
         "function=%s file=tests/sec5_cycle.inc line=%d win32=%lu\n",
         check, function, line, error);
  SetLastError(error);
  return FALSE;
}
#define CYCLE_CHECK(expression)                                                \
  cycle_check(!!(expression), #expression, __func__, __LINE__)
static BOOL cycle_value(ULONGLONG obtained, ULONGLONG expected,
                        const char *check, const char *function, int line) {
  if (obtained == expected)
    return TRUE;
  printf("CYCLE_VALUE_FAIL check=%s expected=%llu obtained=%llu "
         "function=%s file=tests/sec5_cycle.inc line=%d\n",
         check, expected, obtained, function, line);
  SetLastError(ERROR_INVALID_DATA);
  return FALSE;
}
#define CYCLE_VALUE(obtained, expected)                                        \
  cycle_value((ULONGLONG)(obtained), (ULONGLONG)(expected), #obtained,         \
              __func__, __LINE__)

static BOOL cycle_api_fail(const char *api, const char *parameter,
                           DWORD error) {
  if (!error)
    error = ERROR_INVALID_DATA;
  printf("CYCLE_API_FAIL api=%s parameter=%s expected=success obtained=failure "
         "win32=%lu\n",
         api, parameter, error);
  SetLastError(error);
  return FALSE;
}

static BOOL cycle_nt_check(NTSTATUS status, const char *api) {
  return status >= 0 ||
         cycle_api_fail(api, "NTSTATUS", RtlNtStatusToDosError(status));
}
static BOOL cycle_hash(const void *bytes, DWORD length, BYTE out[32]) {
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_HASH_HANDLE hash = NULL;
  BOOL good =
      cycle_nt_check(
          BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0),
          "BCryptOpenAlgorithmProvider") &&
      cycle_nt_check(BCryptCreateHash(alg, &hash, NULL, 0, NULL, 0, 0),
                     "BCryptCreateHash") &&
      cycle_nt_check(BCryptHashData(hash, (PUCHAR)bytes, length, 0),
                     "BCryptHashData") &&
      cycle_nt_check(BCryptFinishHash(hash, out, 32, 0), "BCryptFinishHash");
  DWORD error = good ? ERROR_SUCCESS : GetLastError();
  if (hash)
    BCryptDestroyHash(hash);
  if (alg)
    BCryptCloseAlgorithmProvider(alg, 0);
  SetLastError(error);
  return good;
}
static BOOL cycle_seek(HANDLE h, LONGLONG offset, DWORD origin) {
  LARGE_INTEGER position;
  position.QuadPart = offset;
  return checked_api(SetFilePointerEx(h, position, NULL, origin),
                     "SetFilePointerEx", "journal position");
}
static BOOL cycle_read(HANDLE h, void *data, DWORD size) {
  DWORD got = 0;
  return CYCLE_CHECK(ReadFile(h, data, size, &got, NULL)) &&
         CYCLE_VALUE(got, size);
}
static BOOL cycle_identity(HANDLE h, FILE_ID_INFO *id, FILETIME *birth) {
  BY_HANDLE_FILE_INFORMATION info;
  return CYCLE_CHECK(GetFileInformationByHandle(h, &info)) &&
         CYCLE_CHECK(!(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) &&
         CYCLE_VALUE(info.nNumberOfLinks, 1) &&
         CYCLE_CHECK(
             GetFileInformationByHandleEx(h, FileIdInfo, id, sizeof(*id))) &&
         CYCLE_CHECK(((*birth = info.ftCreationTime), TRUE));
}
static BOOL cycle_same(HANDLE h, const FILE_ID_INFO *id,
                       const FILETIME *birth) {
  FILE_ID_INFO actual;
  FILETIME created;
  return CYCLE_CHECK(cycle_identity(h, &actual, &created)) &&
         CYCLE_CHECK(actual.VolumeSerialNumber == id->VolumeSerialNumber) &&
         CYCLE_CHECK(
             !memcmp(&actual.FileId, &id->FileId, sizeof(id->FileId))) &&
         CYCLE_CHECK(!memcmp(&created, birth, sizeof(created)));
}
static BOOL cycle_profile_path(cycle_state *c, const WCHAR *path) {
  size_t n = wcslen(path);
  if (!CYCLE_CHECK(!(n < 3)) || !CYCLE_CHECK(!(n >= CAP)) ||
      !CYCLE_CHECK(!(path[1] != L':')) || !CYCLE_CHECK(!(path[2] != L'\\')))
    return FALSE;
  WCHAR *copy = CoTaskMemAlloc((n + 1) * sizeof(WCHAR));
  if (!CYCLE_CHECK(copy))
    return FALSE;
  memcpy(copy, path, (n + 1) * sizeof(WCHAR));
  if (c->profile_path)
    CoTaskMemFree(c->profile_path);
  c->profile_path = copy;
  return TRUE;
}
static BOOL cycle_profile_lookup(cycle_state *c) {
  if (c->profile_path)
    return TRUE;
  HRESULT hr = GetAppContainerFolderPath(c->m.sid, &c->profile_path);
  c->profile_lookup_absent = hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
                             hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND);
  printf("PROFILE_LOOKUP HRESULT=0x%08lx known_absent=%d\n", (unsigned long)hr,
         c->profile_lookup_absent);
  return CYCLE_CHECK((SUCCEEDED(hr) && c->profile_path) ||
                     c->profile_lookup_absent);
}
static BOOL cycle_storage_absent(cycle_state *c) {
  return c->profile_path ? storage_absent(c->profile_path)
                         : c->profile_lookup_absent;
}
static BOOL cycle_profile_owned(cycle_state *c, HANDLE h) {
  /* Durable DOS path is < CAP; the canonical handle path adds four WCHARs. */
  WCHAR final[CAP + 4];
  PSECURITY_DESCRIPTOR sd = NULL;
  PSID owner = NULL;
  BOOL def = FALSE;
  DWORD length = GetFinalPathNameByHandleW(
      h, final, CAP + 4, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!length || length >= CAP + 4)
    return cycle_api_fail("GetFinalPathNameByHandleW",
                          "canonical path capacity",
                          length ? ERROR_INSUFFICIENT_BUFFER : GetLastError());
  BOOL good =
      CYCLE_CHECK(length > 4) && CYCLE_CHECK(length < CAP + 4) &&
      CYCLE_CHECK(!wcsncmp(final, L"\\\\?\\", 4)) &&
      CYCLE_CHECK(!_wcsicmp(final + 4, c->profile_path)) &&
      CYCLE_CHECK(kernel_sd(
          h, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &sd)) &&
      CYCLE_CHECK(GetSecurityDescriptorOwner(sd, &owner, &def)) &&
      CYCLE_CHECK(sid_equal(owner, c->s.user));
  PACL acl = NULL;
  BOOL present = FALSE, package = FALSE;
  good = good &&
         CYCLE_CHECK(GetSecurityDescriptorDacl(sd, &present, &acl, &def)) &&
         CYCLE_CHECK(present) && CYCLE_CHECK(acl) &&
         CYCLE_CHECK(IsValidAcl(acl));
  for (DWORD i = 0; good && i < acl->AceCount; ++i) {
    ACCESS_ALLOWED_ACE *ace = NULL;
    good = CYCLE_CHECK(GetAce(acl, i, (void **)&ace));
    if (good && ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
        ace->Header.AceSize >=
            offsetof(ACCESS_ALLOWED_ACE, SidStart) + sizeof(SID)) {
      PSID sid = &ace->SidStart;
      good =
          CYCLE_CHECK(GetSidLengthRequired(((SID *)sid)->SubAuthorityCount) <=
                      ace->Header.AceSize -
                          offsetof(ACCESS_ALLOWED_ACE, SidStart)) &&
          CYCLE_CHECK(IsValidSid(sid));
      if (good && EqualSid(sid, c->s.lease))
        package = TRUE;
    }
  }
  if (sd)
    LocalFree(sd);
  printf("PROFILE_STORAGE_BINDING canonical_path_owner=%d package_sid_ace=%d\n",
         good, package);
  return good && CYCLE_CHECK(package);
}
static BOOL cycle_profile_snapshot(cycle_state *c,
                                   cycle_profile_record *record) {
  if (!CYCLE_CHECK(cycle_profile_lookup(c)) ||
      !CYCLE_CHECK(!(cycle_storage_absent(c))) || !CYCLE_CHECK(c->profile_path))
    return FALSE;
  HANDLE h = cycle_open(c->profile_path, TRUE, 0);
  BOOL good = CYCLE_CHECK(h != INVALID_HANDLE_VALUE) &&
              CYCLE_CHECK(cycle_identity(h, &record->id, &record->birth)) &&
              CYCLE_CHECK(cycle_profile_owned(c, h)) &&
              CYCLE_CHECK(fmt(record->path, CAP, L"%ls", c->profile_path));
  close_handle(&h);
  return CYCLE_CHECK(good);
}
static BOOL cycle_sd(HANDLE h, BYTE *bytes, DWORD *length) {
  PSECURITY_DESCRIPTOR sd = NULL;
  if (!CYCLE_CHECK(kernel_sd(h, SD_INFO, &sd)))
    return FALSE;
  *length = GetSecurityDescriptorLength(sd);
  BOOL good = CYCLE_CHECK(*length) && CYCLE_CHECK(*length <= CYCLE_SD_MAX);
  if (good)
    memcpy(bytes, sd, *length);
  LocalFree(sd);
  if (!good)
    return cycle_api_fail("GetSecurityDescriptorLength", "durable SD capacity",
                          ERROR_INSUFFICIENT_BUFFER);
  return CYCLE_CHECK(good);
}
static BOOL cycle_sd_compare(HANDLE h, const BYTE *bytes, DWORD length,
                             BOOL report) {
  PSECURITY_DESCRIPTOR actual = NULL;
  if (!length || length > CYCLE_SD_MAX ||
      !IsValidSecurityDescriptor((PSECURITY_DESCRIPTOR)bytes) ||
      GetSecurityDescriptorLength((PSECURITY_DESCRIPTOR)bytes) != length)
    return cycle_api_fail("GetSecurityDescriptorLength", "recorded length",
                          ERROR_INVALID_SECURITY_DESCR);
  if (!CYCLE_CHECK(kernel_sd(h, SD_INFO, &actual)))
    return FALSE;
  BOOL good = descriptor_compare((PSECURITY_DESCRIPTOR)bytes, actual, report);
  if (report)
    good = CYCLE_CHECK(good);
  DWORD error = good ? ERROR_SUCCESS : GetLastError();
  LocalFree(actual);
  if (!good && report)
    return cycle_api_fail("descriptor_equal", "readback SD", error);
  SetLastError(error);
  return good;
}
static BOOL cycle_sd_equal(HANDLE h, const BYTE *bytes, DWORD length) {
  return cycle_sd_compare(h, bytes, length, TRUE);
}
static BOOL cycle_prepared_compare(HANDLE h, const cycle_object *o,
                                   BOOL report) {
  if (!o->prepared_length || o->prepared_length > CYCLE_SD_MAX ||
      !IsValidSecurityDescriptor((PSECURITY_DESCRIPTOR)o->prepared))
    return cycle_api_fail("IsValidSecurityDescriptor", "prepared SD",
                          ERROR_INVALID_SECURITY_DESCR);
  DWORD length = GetSecurityDescriptorLength((PSECURITY_DESCRIPTOR)o->prepared);
  if (!length || length > o->prepared_length)
    return cycle_api_fail("GetSecurityDescriptorLength", "prepared SD bounds",
                          ERROR_INVALID_SECURITY_DESCR);
  if (length != o->prepared_length) {
    /* R3/R3B persisted capacity, not used bytes. Only authenticated old plans
       with this exact capacity and zero padding are accepted; no journal edit.
     */
    if (o->prepared_length != CYCLE_SD_MAX)
      return cycle_api_fail("GetSecurityDescriptorLength", "prepared length",
                            ERROR_INVALID_SECURITY_DESCR);
    for (DWORD i = length; i < o->prepared_length; ++i)
      if (o->prepared[i])
        return cycle_api_fail("GetSecurityDescriptorLength", "prepared padding",
                              ERROR_INVALID_SECURITY_DESCR);
    printf("CYCLE_SD_LEGACY_LENGTH recorded=%lu actual=%lu zero_padding=1\n",
           o->prepared_length, length);
  }
  return cycle_sd_compare(h, o->prepared, length, report);
}
static BOOL cycle_prepared_equal(HANDLE h, const cycle_object *o) {
  return CYCLE_CHECK(cycle_prepared_compare(h, o, TRUE));
}
static HANDLE cycle_open(const WCHAR *path, BOOL directory, DWORD access) {
  return CreateFileW(path, access | READ_CONTROL | FILE_READ_ATTRIBUTES,
                     FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                     FILE_FLAG_OPEN_REPARSE_POINT |
                         (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0),
                     NULL);
}
static HANDLE cycle_relative(HANDLE parent, const WCHAR *name, BOOL directory,
                             DWORD access) {
  union {
    ULONGLONG alignment;
    BYTE bytes[sizeof(FILE_ID_BOTH_DIR_INFO) + 256];
  } buffer = {0};
  size_t n = wcslen(name);
  if (!n || n > 100 || wcspbrk(name, L"\\/:"))
    return INVALID_HANDLE_VALUE;
  FILE_ID_BOTH_DIR_INFO *entry = (FILE_ID_BOTH_DIR_INFO *)buffer.bytes;
  entry->FileAttributes = directory ? FILE_ATTRIBUTE_DIRECTORY : 0;
  entry->FileNameLength = (DWORD)(n * sizeof(WCHAR));
  memcpy(entry->FileName, name, entry->FileNameLength);
  typedef NTSTATUS(NTAPI * open_fn)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES,
                                    PIO_STATUS_BLOCK, ULONG, ULONG);
  open_fn open = (open_fn)(uintptr_t)GetProcAddress(
      GetModuleHandleW(L"ntdll.dll"), "NtOpenFile");
  if (!open)
    return INVALID_HANDLE_VALUE;
  UNICODE_STRING text = {(USHORT)entry->FileNameLength,
                         (USHORT)entry->FileNameLength,
                         (WCHAR *)entry->FileName};
  OBJECT_ATTRIBUTES oa = {0};
  oa.Length = sizeof(oa);
  oa.RootDirectory = parent;
  oa.ObjectName = &text;
  oa.Attributes = OBJ_CASE_INSENSITIVE;
  IO_STATUS_BLOCK io = {0};
  HANDLE h = NULL;
  NTSTATUS status =
      open(&h,
           access | READ_CONTROL | FILE_READ_ATTRIBUTES | SYNCHRONIZE |
               (directory ? FILE_LIST_DIRECTORY : FILE_READ_DATA),
           &oa, &io, FILE_SHARE_READ | FILE_SHARE_WRITE,
           FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT |
               (directory ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE));
  if (status < 0) {
    SetLastError(RtlNtStatusToDosError(status));
    return INVALID_HANDLE_VALUE;
  }
  return h;
}
static BOOL cycle_scenario(const WCHAR *name, DWORD *out) {
  for (DWORD i = 0; i < sizeof(cycle_names) / sizeof(cycle_names[0]); ++i)
    if (!wcscmp(name, cycle_names[i])) {
      *out = i;
      return TRUE;
    }
  return FALSE;
}
static BOOL cycle_paths(cycle_state *c, DWORD scenario) {
  WCHAR exe[CAP], *slash;
  if (!CYCLE_CHECK(
          !(scenario >= sizeof(cycle_names) / sizeof(cycle_names[0]))) ||
      !CYCLE_CHECK(bounded_text(GetModuleFileNameW(NULL, exe, CAP), CAP,
                                "GetModuleFileNameW")) ||
      !CYCLE_CHECK((slash = wcsrchr(exe, L'\\'))))
    return FALSE;
  *slash = 0;
  if (!CYCLE_CHECK((slash = wcsrchr(exe, L'\\'))))
    return FALSE;
  *slash = 0;
  if (!CYCLE_CHECK((slash = wcsrchr(exe, L'\\'))))
    return FALSE;
  *slash =
      0; /* installed worktree/zig-out/bin only; no arbitrary fixture base */
  if (!CYCLE_CHECK(fmt(c->base, CAP, L"%ls", exe)) ||
      !CYCLE_CHECK(fmt(c->path, CAP, L"%ls\\.sec5-r3-%ls-20261013", exe,
                       cycle_names[scenario])) ||
      !CYCLE_CHECK(!(wcslen(exe) < 3)) || !CYCLE_CHECK(!(exe[1] != L':')) ||
      !CYCLE_CHECK(!(exe[2] != L'\\')))
    return FALSE;
  /* Pin all existing named ancestors, no reparse or DELETE sharing. */
  for (size_t n = 3; n <= wcslen(exe); ++n) {
    if (exe[n] && exe[n] != L'\\')
      continue;
    WCHAR saved = exe[n];
    exe[n] = 0;
    HANDLE h = cycle_open(exe, TRUE, 0);
    exe[n] = saved;
    BY_HANDLE_FILE_INFORMATION info;
    BOOL good =
        CYCLE_CHECK(h != INVALID_HANDLE_VALUE) &&
        CYCLE_CHECK(GetFileInformationByHandle(h, &info)) &&
        CYCLE_CHECK(!(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) &&
        CYCLE_CHECK(c->ancestor_count < 64);
    if (!good) {
      close_handle(&h);
      return cycle_check(FALSE,
                         "ancestor pin: open, attributes, no reparse, capacity",
                         __func__, __LINE__);
    }
    c->ancestors[c->ancestor_count++] = h;
  }
  return TRUE;
}
static void cycle_crash(const char *boundary) {
  printf("CYCLE_CRASH boundary=%s exit=%u\n", boundary, CYCLE_CRASH);
  fflush(stdout);
  if (!TerminateProcess(GetCurrentProcess(), CYCLE_CRASH))
    ExitProcess(87);
  ExitProcess(87);
}
static BOOL cycle_append(cycle_state *c, DWORD type, DWORD index,
                         const void *payload, DWORD length) {
  if (length > sizeof(cycle_manifest))
    return cycle_api_fail("cycle_append", "payload length", ERROR_INVALID_DATA);
  cycle_record r = {0};
  r.length = sizeof(r) + length;
  r.version = CYCLE_VERSION;
  r.sequence = c->sequence + 1;
  r.type = type;
  r.index = index;
  r.payload_length = length;
  memcpy(r.previous, c->digest, 32);
  BYTE *bytes = calloc(1, r.length);
  if (!bytes)
    return cycle_api_fail("calloc", "journal record", ERROR_NOT_ENOUGH_MEMORY);
  memcpy(bytes, &r, sizeof(r));
  if (length)
    memcpy(bytes + sizeof(r), payload, length);
  BOOL good = cycle_hash(bytes, r.length, r.digest);
  memcpy(bytes, &r, sizeof(r));
  if (good)
    good = cycle_seek(c->journal, 0, FILE_END);
  DWORD written = 0;
  if (good)
    good = checked_api(WriteFile(c->journal, bytes, r.length, &written, NULL),
                       "WriteFile", "journal record");
  if (good && written != r.length)
    good =
        cycle_api_fail("WriteFile", "journal short write", ERROR_WRITE_FAULT);
  if (good)
    good = checked_api(FlushFileBuffers(c->journal), "FlushFileBuffers",
                       "journal record");
  DWORD error = good ? ERROR_SUCCESS : GetLastError();
  free(bytes);
  if (!good) {
    SetLastError(error);
    return FALSE;
  }
  c->sequence = r.sequence;
  c->last = type;
  memcpy(c->digest, r.digest, 32);
  printf("JOURNAL_DURABLE seq=%lu type=%lu index=%lu bytes=%lu\n", r.sequence,
         type, index, r.length);
  fflush(stdout);
  return TRUE;
}
static BOOL cycle_journal_reject(const char *cause, const char *source,
                                 const char *stage) {
  DWORD error = GetLastError();
  printf("CYCLE_JOURNAL_REJECT cause=%s source=%s stage=%s "
         "expected=valid obtained=invalid\n",
         cause, source, stage);
  SetLastError(error);
  return FALSE;
}
static BOOL cycle_parse(cycle_state *c) {
  LARGE_INTEGER size;
  if (!GetFileSizeEx(c->journal, &size))
    return cycle_journal_reject("parse", "journal", "size-query");
  if (size.QuadPart <= 0 || size.QuadPart > 1024 * 1024)
    return cycle_journal_reject("size", "journal", "file");
  if (!cycle_seek(c->journal, 0, FILE_BEGIN))
    return cycle_journal_reject("parse", "journal", "seek");
  LONGLONG offset = 0;
  while (offset < size.QuadPart) {
    cycle_record r;
    if (size.QuadPart - offset < (LONGLONG)sizeof(r))
      return cycle_journal_reject("size", "journal", "record-header");
    if (!cycle_read(c->journal, &r, sizeof(r)))
      return cycle_journal_reject("parse", "journal", "record-read");
    if (r.version != CYCLE_VERSION)
      return cycle_journal_reject("version", "journal", "record");
    if (r.sequence != c->sequence + 1)
      return cycle_journal_reject("parse", "journal", "sequence");
    if (r.length != sizeof(r) + r.payload_length ||
        r.payload_length > sizeof(cycle_manifest) ||
        r.length > size.QuadPart - offset)
      return cycle_journal_reject("size", "journal", "record");
    if (memcmp(r.previous, c->digest, 32) || r.type < CY_PROFILE_INTENT ||
        r.type > CY_ORPHAN_STORAGE || c->final)
      return cycle_journal_reject("parse", "journal", "record-chain");
    BYTE *bytes = calloc(1, r.length);
    if (!bytes)
      return cycle_journal_reject("parse", "journal", "allocation");
    memcpy(bytes, &r, sizeof(r));
    memset(((cycle_record *)bytes)->digest, 0, 32);
    BYTE hash[32];
    BOOL good = (!r.payload_length ||
                 cycle_read(c->journal, bytes + sizeof(r), r.payload_length)) &&
                cycle_hash(bytes, r.length, hash);
    if (good && memcmp(hash, r.digest, 32)) {
      free(bytes);
      return cycle_journal_reject("digest", "journal", "record-digest");
    }
    if (good && r.sequence == 1) {
      good = r.type == CY_PROFILE_INTENT && r.payload_length == sizeof(c->m);
      if (good) {
        memcpy(&c->m, bytes + sizeof(r), sizeof(c->m));
        c->intention = TRUE;
      }
    } else if (good && r.type == CY_JOB_WITNESS) {
      struct {
        DWORD pid;
        FILETIME birth;
      } witness;
      good = r.payload_length == sizeof(witness) && !c->witness_pid &&
             !c->spawned && !c->closed;
      if (good) {
        memcpy(&witness, bytes + sizeof(r), sizeof(witness));
        good = witness.pid &&
               (witness.birth.dwLowDateTime || witness.birth.dwHighDateTime);
        if (good) {
          c->witness_pid = witness.pid;
          c->witness_birth = witness.birth;
        }
      }
    } else if (good &&
               (r.type == CY_PROFILE_CREATED || r.type == CY_ORPHAN_STORAGE)) {
      cycle_profile_record storage;
      good = r.payload_length == sizeof(storage) && c->witness_pid &&
             !c->profile_known && !c->prepared &&
             (r.type == CY_PROFILE_CREATED ? !c->closed : c->closed);
      if (good) {
        memcpy(&storage, bytes + sizeof(r), sizeof(storage));
        good =
            storage.path[CAP - 1] == 0 && cycle_profile_path(c, storage.path);
      }
      if (good) {
        c->profile_id = storage.id;
        c->profile_birth = storage.birth;
        c->profile_known = TRUE;
      }
    } else if (good && r.type == CY_PREPARE_INTENT) {
      good = r.index < CYCLE_OBJECTS && !c->closed && c->profile_known &&
             !c->spawned && r.payload_length == sizeof(cycle_object) &&
             !(c->prepared & (1u << r.index));
      if (good) {
        good = !memcmp(&c->m.objects[r.index], bytes + sizeof(r),
                       sizeof(cycle_object));
      }
      if (good) {
        c->prepared |= 1u << r.index;
      }
    } else if (good && r.type == CY_PREPARE_ACK) {
      good = !r.payload_length && r.index < CYCLE_OBJECTS &&
             (c->prepared & (1u << r.index)) && !c->spawned && !c->closed;
      if (good)
        c->acknowledged |= 1u << r.index;
    } else if (good && r.type == CY_SPAWN_INTENT) {
      good = !r.payload_length && !c->spawned && !c->closed &&
             c->acknowledged == 7;
      if (good)
        c->spawned = TRUE;
    } else if (good && r.type == CY_ASSIGNED) {
      struct {
        DWORD pid;
        FILETIME birth;
      } process;
      good = r.payload_length == sizeof(process) && c->spawned &&
             !c->assigned && !c->closed;
      if (good) {
        memcpy(&process, bytes + sizeof(r), sizeof(process));
        good = process.pid != 0 &&
               (process.birth.dwLowDateTime || process.birth.dwHighDateTime);
        c->assigned = good;
        if (good) {
          c->assigned_pid = process.pid;
          c->assigned_birth = process.birth;
        }
      }
    } else if (good && r.type == CY_RUN_INTENT) {
      good =
          !r.payload_length && c->assigned && !c->running_intent && !c->closed;
      if (good)
        c->running_intent = TRUE;
    } else if (good && r.type == CY_RUNNING) {
      good = !r.payload_length && c->running_intent && !c->closed;
    } else if (good && r.type == CY_TREE_CLOSED) {
      good = !r.payload_length && !c->closed && (!c->spawned || c->assigned);
      if (good)
        c->closed = TRUE;
    } else if (good && r.type == CY_RESTORE_INTENT) {
      good = !r.payload_length && (c->closed || c->m.scenario == 12) &&
             r.index < CYCLE_OBJECTS;
    } else if (good && r.type == CY_RESTORE_ACK) {
      good = !r.payload_length && c->closed && r.index < CYCLE_OBJECTS;
      if (good)
        c->restored |= 1u << r.index;
    } else if (good && r.type == CY_DELETE_INTENT) {
      good = !r.payload_length && c->closed && c->restored == 7;
    } else if (good && r.type == CY_FINAL) {
      good = !r.payload_length && c->closed && c->restored == 7 &&
             c->last == CY_DELETE_INTENT;
      c->final = good;
    } else if (good && r.type == CY_COLLISION) {
      good = r.payload_length == sizeof(HRESULT) && !c->profile_known;
      c->collision = good;
    } else if (good && r.type == CY_MUTATION_REPAIRED) {
      good = !r.payload_length && c->m.scenario == 12;
      c->repaired = good;
    } else if (good && r.type == CY_DELETE_RETRY) {
      good = r.payload_length == sizeof(HRESULT) && c->last == CY_DELETE_INTENT;
      c->retry = good;
    } else if (good && r.sequence != 1)
      good = FALSE;
    free(bytes);
    if (!good)
      return cycle_journal_reject("parse", "journal", "record-content");
    c->sequence = r.sequence;
    c->last = r.type;
    memcpy(c->digest, r.digest, 32);
    offset += r.length;
  }
  if (!c->intention || offset != size.QuadPart)
    return cycle_journal_reject("parse", "journal", "intent-or-offset");
  return TRUE;
}
static BOOL cycle_catalog_write(cycle_state *c) {
  cycle_catalog cat = {0};
  cat.version = CYCLE_VERSION;
  cat.length = sizeof(cat);
  cat.root_id = c->m.objects[0].id;
  cat.control_id = c->m.control_id;
  cat.journal_id = c->m.journal_id;
  memcpy(cat.lease, c->m.lease, 16);
  BYTE reserved = 0;
  return CYCLE_CHECK(cycle_hash(&c->m, sizeof(c->m), cat.manifest_hash)) &&
         CYCLE_CHECK(cycle_hash(&cat, sizeof(cat), cat.digest)) &&
         CYCLE_CHECK(cycle_seek(c->catalog, 0, FILE_BEGIN)) &&
         CYCLE_CHECK(write_all(c->catalog, &reserved, 1)) &&
         CYCLE_CHECK(write_all(c->catalog, &cat, sizeof(cat))) &&
         CYCLE_CHECK(FlushFileBuffers(c->catalog));
}
static BOOL cycle_owned(cycle_state *c, HANDLE h, BOOL directory) {
  snapshot snap = {0};
  BOOL good = snapshot_take(&snap, h, SE_FILE_OBJECT, TRUE) &&
              recovery_owned(&snap, &c->s, NULL) &&
              label_is(h, SE_FILE_OBJECT, SECURITY_MANDATORY_MEDIUM_RID);
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  good = good && GetSecurityDescriptorControl(snap.sd, &control, &revision) &&
         (control & SE_DACL_PROTECTED);
  if (good) {
    PSECURITY_DESCRIPTOR expected = NULL;
    good = make_sd(&c->s, FALSE, 1, directory, &expected);
    /* mapped GA versus FA is compared through explicit ACE validation above */
    if (expected)
      LocalFree(expected);
  }
  if (snap.sd)
    LocalFree(snap.sd);
  return good;
}
static BOOL cycle_lock(cycle_state *c) {
  OVERLAPPED ov = {0};
  BOOL good = LockFileEx(c->catalog,
                         LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0,
                         1, 0, &ov);
  if (!good)
    printf("RECOVERY_BLOCKED reason=LeaseBusy win32=%lu\n", GetLastError());
  return good;
}
static BOOL cycle_user(cycle_state *c) {
  c->s.backend = SEC5_APPCONTAINER;
  return CYCLE_CHECK(parent_representative(&c->s)) &&
         CYCLE_CHECK(ConvertStringSidToSidW(c->s.user_text, &c->s.user));
}
static BOOL cycle_boot(LARGE_INTEGER *out) {
  SYSTEM_TIMEOFDAY_INFORMATION info = {0};
  ULONG length = 0;
  NTSTATUS status = NtQuerySystemInformation(SystemTimeOfDayInformation, &info,
                                             sizeof(info), &length);
  if (!CYCLE_CHECK(cycle_nt_check(status, "NtQuerySystemInformation")))
    return FALSE;
  *out = info.BootTime;
  return CYCLE_CHECK(length >= sizeof(info.BootTime)) &&
         CYCLE_CHECK(out->QuadPart != 0);
}
static void cycle_close(cycle_state *c) {
  for (DWORD i = 1; i < CYCLE_OBJECTS; ++i)
    close_handle(&c->objects[i]);
  close_handle(&c->journal);
  close_handle(&c->catalog);
  close_handle(&c->control);
  close_handle(&c->root);
  close_handle(&c->job);
  close_handle(&c->ready);
  close_handle(&c->release);
  close_handle(&c->stop);
  close_handle(&c->holder);
  if (c->profile_path)
    CoTaskMemFree(c->profile_path);
  if (c->s.lease)
    FreeSid(c->s.lease);
  if (c->s.user)
    LocalFree(c->s.user);
  for (DWORD i = c->ancestor_count; i-- > 0;)
    close_handle(&c->ancestors[i]);
}
static BOOL cycle_load(cycle_state *c, DWORD scenario, BOOL lock) {
  if (!cycle_paths(c, scenario) || !cycle_user(c))
    return FALSE;
  c->root = cycle_open(c->path, TRUE, WRITE_DAC | WRITE_OWNER);
  if (c->root == INVALID_HANDLE_VALUE)
    return FALSE;
  c->objects[0] = c->root;
  c->control = cycle_relative(c->root, L"control", TRUE, 0);
  if (c->control == INVALID_HANDLE_VALUE || !cycle_owned(c, c->control, TRUE))
    return FALSE;
  c->catalog =
      cycle_relative(c->control, L"catalog.bin", FALSE, FILE_WRITE_DATA);
  c->journal =
      cycle_relative(c->control, L"journal.bin", FALSE, FILE_WRITE_DATA);
  if (c->catalog == INVALID_HANDLE_VALUE ||
      c->journal == INVALID_HANDLE_VALUE ||
      !cycle_owned(c, c->catalog, FALSE) ||
      !cycle_owned(c, c->journal, FALSE) || (lock && !cycle_lock(c)))
    return FALSE;
  cycle_catalog cat;
  LARGE_INTEGER size;
  BYTE digest[32];
  if (!GetFileSizeEx(c->catalog, &size))
    return cycle_journal_reject("parse", "catalog", "size-query");
  if (size.QuadPart != sizeof(cat) + 1)
    return cycle_journal_reject("size", "catalog", "file");
  if (!cycle_seek(c->catalog, 1, FILE_BEGIN) ||
      !cycle_read(c->catalog, &cat, sizeof(cat)))
    return cycle_journal_reject("parse", "catalog", "read");
  memcpy(digest, cat.digest, 32);
  memset(cat.digest, 0, 32);
  BYTE hash[32];
  BOOL valid;
  if (cat.version != CYCLE_VERSION)
    valid = cycle_journal_reject("version", "catalog", "header");
  else if (cat.length != sizeof(cat))
    valid = cycle_journal_reject("size", "catalog", "header");
  else if (!cycle_hash(&cat, sizeof(cat), hash))
    valid = cycle_journal_reject("parse", "catalog", "hash");
  else if (memcmp(hash, digest, 32))
    valid = cycle_journal_reject("digest", "catalog", "catalog-digest");
  else
    valid = cycle_parse(c);
  if (!valid) {
    if (size.QuadPart == sizeof(cat) + 1) {
      LARGE_INTEGER journal_size;
      if (GetFileSizeEx(c->journal, &journal_size) && !journal_size.QuadPart)
        printf("SEC5 C3.1 durable profile intent | FAIL | mutation=no-intent "
               "recovery refuses unjournaled profile\n");
    }
    printf("RECOVERY_BLOCKED reason=JournalCorruptOrMissingIntent\n");
    return FALSE;
  }
  cycle_manifest initial;
  if (!cycle_seek(c->journal, sizeof(cycle_record), FILE_BEGIN) ||
      !cycle_read(c->journal, &initial, sizeof(initial)) ||
      !cycle_hash(&initial, sizeof(initial), hash) ||
      memcmp(hash, cat.manifest_hash, 32) || c->m.version != CYCLE_VERSION ||
      c->m.scenario != scenario || wcscmp(c->m.owner, c->s.user_text) ||
      wcscmp(c->m.root, c->path) || memcmp(c->m.lease, cat.lease, 16) ||
      memcmp(&cat.root_id, &c->m.objects[0].id, sizeof(cat.root_id)) ||
      memcmp(&cat.control_id, &c->m.control_id, sizeof(cat.control_id)) ||
      memcmp(&cat.journal_id, &c->m.journal_id, sizeof(cat.journal_id)) ||
      !cycle_same(c->root, &c->m.objects[0].id, &c->m.objects[0].birth) ||
      !cycle_same(c->control, &c->m.control_id, &c->m.control_birth) ||
      !cycle_same(c->journal, &c->m.journal_id, &c->m.journal_birth) ||
      !cycle_same(c->catalog, &c->m.catalog_id, &c->m.catalog_birth) ||
      !cycle_sd_equal(c->control, c->m.control_sd, c->m.control_length) ||
      !cycle_sd_equal(c->journal, c->m.journal_sd, c->m.journal_length) ||
      !cycle_sd_equal(c->catalog, c->m.catalog_sd, c->m.catalog_length)) {
    printf("RECOVERY_BLOCKED reason=CatalogOrControlIdentity\n");
    return FALSE;
  }
  WCHAR volume[CAP], guid[128], filesystem[64];
  DWORD serial, flags;
  LARGE_INTEGER boot;
  if (!cycle_boot(&boot) || boot.QuadPart != c->m.boot_time.QuadPart) {
    printf("RECOVERY_BLOCKED reason=BootIdentityChangedOrUnavailable\n");
    return FALSE;
  }
  printf("BOOT_IDENTITY same=1 value=%lld\n", boot.QuadPart);
  if (!GetVolumePathNameW(c->base, volume, CAP) ||
      !GetVolumeNameForVolumeMountPointW(volume, guid, 128) ||
      wcscmp(guid, c->m.volume_guid) ||
      !GetVolumeInformationW(volume, NULL, 0, &serial, NULL, &flags, filesystem,
                             64) ||
      wcscmp(filesystem, L"NTFS") || !(flags & FILE_PERSISTENT_ACLS)) {
    printf("RECOVERY_BLOCKED reason=VolumeIdentityOrFilesystem\n");
    return FALSE;
  }
  WCHAR expected[64];
  DWORD random[4];
  memcpy(random, c->m.lease, 16);
  if (!fmt(expected, 64, L"DevAgents.Sec5.%08lx%08lx%08lx%08lx", random[0],
           random[1], random[2], random[3]) ||
      wcscmp(expected, c->m.moniker) ||
      FAILED(
          DeriveAppContainerSidFromAppContainerName(c->m.moniker, &c->s.lease)))
    return FALSE;
  LPWSTR text = NULL;
  BOOL good = ConvertSidToStringSidW(c->s.lease, &text) &&
              !wcscmp(text, c->m.sid) &&
              c->m.sid_length <= sizeof(c->m.package_sid) &&
              IsValidSid(c->m.package_sid) &&
              GetLengthSid(c->m.package_sid) == c->m.sid_length &&
              EqualSid(c->s.lease, c->m.package_sid);
  if (text)
    LocalFree(text);
  for (DWORD i = 0; good && i < CYCLE_OBJECTS; ++i) {
    if (i)
      c->objects[i] = cycle_relative(c->root, cycle_children[i], i == 1,
                                     WRITE_DAC | WRITE_OWNER);
    cycle_object *o = &c->m.objects[i];
    good = c->objects[i] != INVALID_HANDLE_VALUE &&
           cycle_same(c->objects[i], &o->id, &o->birth);
    if (good) {
      BOOL known = cycle_sd_compare(c->objects[i], o->original,
                                    o->original_length, FALSE) ||
                   ((c->prepared & (1u << i)) &&
                    cycle_prepared_compare(c->objects[i], o, FALSE));
      if (!known) {
        cycle_sd_equal(c->objects[i], o->original, o->original_length);
        if (c->prepared & (1u << i))
          cycle_prepared_equal(c->objects[i], o);
      }
      good = CYCLE_CHECK(known);
    }
    printf("RECOVERY_IDENTITY object=%lu same_identity_and_known_sd=%d\n", i,
           good);
  }
  if (!good) {
    printf("RECOVERY_BLOCKED reason=FixtureIdentityOrDescriptor\n");
    return FALSE;
  }
  /* The holder is started before the profile API call and before its own ACK.
     It only authenticates the files/Job; it must not require a profile lookup.
   */
  BOOL inspect_profile = c->profile_known || c->witness_pid != 0;
  if (inspect_profile && !cycle_profile_lookup(c))
    return FALSE;
  if (inspect_profile && !cycle_storage_absent(c)) {
    HANDLE storage = cycle_open(c->profile_path, TRUE, 0);
    FILE_ID_INFO id;
    FILETIME birth;
    good = storage != INVALID_HANDLE_VALUE &&
           cycle_identity(storage, &id, &birth) &&
           cycle_profile_owned(c, storage) &&
           (!c->profile_known ||
            cycle_same(storage, &c->profile_id, &c->profile_birth));
    close_handle(&storage);
  }
  printf("CYCLE_MANIFEST scenario=%ls moniker=%ls sid=%ls seq=%lu closed=%d "
         "final=%d profile_identity=%d\n",
         cycle_names[scenario], c->m.moniker, c->m.sid, c->sequence, c->closed,
         c->final, good);
  return good && !c->collision;
}
static BOOL cycle_job_valid(cycle_state *c, HANDLE job) {
  PSECURITY_DESCRIPTOR actual = NULL;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  BOOL good =
      CYCLE_CHECK(kernel_sd(job, SD_INFO, &actual)) &&
      CYCLE_CHECK(descriptor_equal(c->m.job_sd, actual)) &&
      CYCLE_CHECK(checked_api(
          QueryInformationJobObject(job, JobObjectExtendedLimitInformation,
                                    &limits, sizeof(limits), NULL),
          "QueryInformationJobObject", "fixed extended limits")) &&
      CYCLE_CHECK(limits.BasicLimitInformation.LimitFlags ==
                  (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
                   JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION));
  if (actual)
    LocalFree(actual);
  return CYCLE_CHECK(good);
}
static BOOL cycle_empty(HANDLE job, DWORD *count) {
  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {0};
  BOOL good = checked_api(
      QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &info,
                                sizeof(info), NULL),
      "QueryInformationJobObject", "fixed accounting");
  if (good)
    *count = info.ActiveProcesses;
  return good;
}
static BOOL cycle_witness_alive(cycle_state *c) {
  HANDLE process =
      c->witness_pid
          ? OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE,
                        c->witness_pid)
          : NULL;
  FILETIME birth, exit, kernel, user;
  BOOL good =
      CYCLE_CHECK(process) &&
      CYCLE_CHECK(GetProcessTimes(process, &birth, &exit, &kernel, &user)) &&
      CYCLE_CHECK(!memcmp(&birth, &c->witness_birth, sizeof(birth))) &&
      CYCLE_CHECK(WaitForSingleObject(process, 0) == WAIT_TIMEOUT);
  printf("JOB_CONTINUITY witness_pid=%lu birth_alive=%d\n", c->witness_pid,
         good);
  close_handle(&process);
  return CYCLE_CHECK(good);
}
static BOOL cycle_close_tree(cycle_state *c) {
  if (c->closed) {
    HANDLE job =
        OpenJobObjectW(JOB_OBJECT_QUERY | READ_CONTROL, FALSE, c->m.job);
    DWORD error = GetLastError(), active = 0;
    BOOL good = job ? CYCLE_CHECK(cycle_witness_alive(c)) &&
                          CYCLE_CHECK(cycle_job_valid(c, job)) &&
                          CYCLE_CHECK(cycle_empty(job, &active)) &&
                          CYCLE_CHECK(!active)
                    : CYCLE_CHECK(c->final && error == ERROR_FILE_NOT_FOUND);
    printf("TREE_EMPTY active=%lu verified=%d durable_closed=1 job_absent=%d "
           "final=%d win32=%lu\n",
           active, good, job == NULL, c->final, job ? 0 : error);
    close_handle(&job);
    return CYCLE_CHECK(good);
  }
  if (c->spawned && !c->assigned) {
    printf("RECOVERY_BLOCKED reason=SpawnIntentWithoutCertifiedAssignment "
           "no-PID-absence-inference\n");
    return cycle_check(FALSE, "spawned requires durable assignment", __func__,
                       __LINE__);
  }
  if (!cycle_witness_alive(c)) {
    printf("RECOVERY_BLOCKED reason=JobContinuityUncertified\n");
    return cycle_check(FALSE, "cycle_witness_alive(c)", __func__, __LINE__);
  }
  if (!c->job)
    c->job =
        OpenJobObjectW(JOB_OBJECT_QUERY | JOB_OBJECT_TERMINATE | READ_CONTROL,
                       FALSE, c->m.job);
  if (!c->job || !cycle_job_valid(c, c->job)) {
    printf("RECOVERY_BLOCKED reason=TreeUncertified job_open_error=%lu\n",
           GetLastError());
    return cycle_check(FALSE, "named Job open and cycle_job_valid(c, c->job)",
                       __func__, __LINE__);
  }
  DWORD active = 0;
  if (!CYCLE_CHECK(cycle_empty(c->job, &active)))
    return FALSE;
  printf("TREE_BEFORE active=%lu\n", active);
  if (!CYCLE_CHECK(TerminateJobObject(c->job, 126)))
    return FALSE;
  ULONGLONG end = GetTickCount64() + WAIT_MS;
  do {
    if (!CYCLE_CHECK(cycle_empty(c->job, &active)))
      return FALSE;
    if (!active)
      break;
    Sleep(10);
  } while (GetTickCount64() < end);
  printf("TREE_EMPTY active=%lu verified=%d\n", active, active == 0);
  if (!CYCLE_CHECK(!(active)) ||
      !CYCLE_CHECK(cycle_append(c, CY_TREE_CLOSED, 0, NULL, 0)))
    return FALSE;
  c->closed = TRUE;
  return TRUE;
}
static BOOL cycle_restore(cycle_state *c) {
  if (!c->closed)
    return FALSE;
  for (DWORD i = CYCLE_OBJECTS; i-- > 0;) {
    cycle_object *o = &c->m.objects[i];
    if (!cycle_same(c->objects[i], &o->id, &o->birth) ||
        !cycle_append(c, CY_RESTORE_INTENT, i, NULL, 0))
      return FALSE;
    /* This is a restore decision, not the definitive readback assertion. */
    BOOL equal =
        cycle_sd_compare(c->objects[i], o->original, o->original_length, FALSE);
    snapshot snap = {c->objects[i],      SE_FILE_OBJECT, o->original,
                     o->original_length, o->id,          TRUE};
    if ((!equal && !restore(&snap)) || !snapshot_equal(&snap) ||
        !cycle_append(c, CY_RESTORE_ACK, i, NULL, 0))
      return FALSE;
    printf("CYCLE_RESTORED object=%lu identity=1 sd=1 control=1 "
           "package_ace_residue=0\n",
           i);
  }
  return TRUE;
}
static BOOL cycle_signal(cycle_state *c, const WCHAR *name) {
  HANDLE event = OpenEventW(EVENT_MODIFY_STATE | READ_CONTROL, FALSE, name);
  if (!event)
    return FALSE;
  PSECURITY_DESCRIPTOR sd = NULL;
  BOOL good = kernel_sd(event, SD_INFO, &sd) &&
              descriptor_equal(c->m.event_sd, sd) && SetEvent(event);
  if (sd)
    LocalFree(sd);
  close_handle(&event);
  return good;
}
static HRESULT cycle_delete_profile(const WCHAR *moniker) {
  ULONGLONG started = GetTickCount64(), deadline = started + WAIT_MS;
  DWORD attempts = 0;
  BOOL retrying = FALSE;
  for (;;) {
    ++attempts;
    HRESULT hr = DeleteAppContainerProfile(moniker);
    BOOL retry = hr == HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION) &&
                 GetTickCount64() < deadline;
    if (!retry) {
      if (retrying)
        printf("CYCLE_PROFILE_SHARING phase=end attempts=%lu elapsed_ms=%llu "
               "win32=%ld HRESULT=0x%08lx\n",
               attempts, GetTickCount64() - started,
               HRESULT_FACILITY(hr) == FACILITY_WIN32
                   ? (long)HRESULT_CODE(hr)
                   : (SUCCEEDED(hr) ? 0L : -1L),
               (unsigned long)hr);
      return hr;
    }
    if (!retrying) {
      printf("CYCLE_PROFILE_SHARING phase=begin win32=%lu\n",
             (unsigned long)ERROR_SHARING_VIOLATION);
      retrying = TRUE;
    }
    Sleep(10);
  }
}
static HRESULT cycle_profile_delete(cycle_state *c, BOOL obstacle,
                                    BOOL allow_seed, BOOL *seeded) {
  ULONGLONG before = GetTickCount64();
  HRESULT actual = cycle_delete_profile(c->m.moniker);
  BOOL absent = cycle_storage_absent(c);
  printf("PROFILE_DELETE HRESULT=0x%08lx latency_ms=%llu storage_absent=%d "
         "own_handle_obstacle=%d\n",
         (unsigned long)actual, GetTickCount64() - before, absent, obstacle);
  /* False-negative API result seam: retain the real OS outcome above, then
     force the caller down the documented retry path when the OS did delete
     despite the held handle. No invented OS error is reported as real. */
  *seeded = allow_seed && SUCCEEDED(actual) && absent;
  HRESULT returned = *seeded ? E_ACCESSDENIED : actual;
  printf("PROFILE_DELETE_API_RESULT HRESULT=0x%08lx seeded_api_failure=%d\n",
         (unsigned long)returned, *seeded);
  return returned;
}
static int cycle_recover(DWORD scenario) {
  cycle_state *c = calloc(1, sizeof(*c));
  if (!c)
    return 1;
  int code = 1;
  if (!cycle_load(c, scenario, TRUE))
    goto done;
  if (c->final) {
    BOOL good =
        cycle_close_tree(c) && cycle_storage_absent(c) && cycle_dest_empty(c);
    for (DWORD i = 0; good && i < CYCLE_OBJECTS; ++i)
      good = cycle_sd_equal(c->objects[i], c->m.objects[i].original,
                            c->m.objects[i].original_length);
    printf("SEC5 APPCONTAINER orphan profile recovered | %s | idempotent=1 "
           "tree_closed=%d storage_absent=%d\n",
           good ? "PASS" : "FAIL", c->closed, cycle_storage_absent(c));
    code = good ? 0 : 1;
    goto done;
  }
  if (scenario == 12 && !c->closed && !c->repaired) {
    /* Defect: attempt the forbidden transition while a deterministic child is
       live. The independent guard measures the tree before accepting any
       cleanup. */
    c->job = OpenJobObjectW(JOB_OBJECT_QUERY | READ_CONTROL, FALSE, c->m.job);
    BOOL live = c->job && cycle_witness_alive(c) &&
                cycle_job_valid(c, c->job) && cycle_markers(c);
    BOOL setter = FALSE;
    if (live && cycle_append(c, CY_RESTORE_INTENT, 0, NULL, 0)) {
      cycle_object *o = &c->m.objects[0];
      snapshot snap = {c->objects[0],      SE_FILE_OBJECT, o->original,
                       o->original_length, o->id,          TRUE};
      setter = restore(&snap);
    }
    close_handle(&c->job);
    printf("MUTATION_SETTER_BEFORE_TREE_EMPTY setter=%d live=%d\n", setter,
           live);
    printf("SEC5 C3.1 cleanup requires empty tree | %s | mutation=clean-live "
           "fixtures=%lu consoles=%lu active=%lu certified=%d\n",
           live ? "FAIL" : "UNVERIFIED", c->live_fixtures, c->live_consoles,
           c->live_active, c->live_certified);
    code = 91;
    goto done;
  }
  if (!cycle_close_tree(c))
    goto done;
  if (!c->profile_known && !cycle_storage_absent(c)) {
    cycle_profile_record record = {0};
    if (!cycle_profile_snapshot(c, &record) ||
        !cycle_append(c, CY_ORPHAN_STORAGE, 0, &record, sizeof(record)))
      goto done;
    c->profile_known = TRUE;
    c->profile_id = record.id;
    c->profile_birth = record.birth;
  }
  if (!cycle_reconcile(c) || !cycle_restore(c) ||
      !cycle_append(c, CY_DELETE_INTENT, 0, NULL, 0))
    goto done;
  HANDLE obstacle = NULL;
  BOOL first_retry = scenario == 8 && !c->retry;
  if (first_retry && !cycle_storage_absent(c)) {
    WCHAR file[CAP];
    if (!fmt(file, CAP, L"%ls\\sec5-r3-delete-obstacle.bin", c->profile_path))
      goto done;
    obstacle =
        CreateFileW(file, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                    OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (obstacle == INVALID_HANDLE_VALUE)
      goto done;
  }
  BOOL seeded = FALSE;
  HRESULT hr = cycle_profile_delete(c, obstacle != NULL, first_retry, &seeded);
  BOOL absent = cycle_storage_absent(c);
  close_handle(&obstacle);
  if (first_retry) {
    HRESULT retry_hr = hr;
    printf("PROFILE_DELETE_RETRY HRESULT=0x%08lx seeded_api_failure=%d "
           "os_deleted_with_handle=%d\n",
           (unsigned long)retry_hr, seeded, seeded);
    if (!cycle_append(c, CY_DELETE_RETRY, 0, &retry_hr, sizeof(retry_hr)))
      goto done;
    printf("SEC5 APPCONTAINER profile delete retry | RETRY_PENDING | journal "
           "retained; close own handle; explicit second recovery\n");
    code = 75;
    goto done;
  }
  if (FAILED(hr) || !absent) {
    if (!cycle_append(c, CY_DELETE_RETRY, 0, &hr, sizeof(hr)))
      goto done;
    code = 75;
    goto done;
  }
  if (!cycle_append(c, CY_FINAL, 0, NULL, 0))
    goto done;
  if (!cycle_signal(c, c->m.release))
    goto done;
  printf("SEC5 APPCONTAINER orphan profile recovered | PASS | tree_empty=1 "
         "originals=3/3 profile_absent=1 "
         "residues=journal+catalog+original-fixtures\n");
  if (scenario == 8)
    printf("SEC5 APPCONTAINER profile delete retry | PASS | second API call "
           "idempotent; HRESULT and residue measured\n");
  code = 0;
done:
  if (code == 1)
    printf("RECOVERY_BLOCKED win32=%lu root retained; inspect durable "
           "transition before retry\n",
           GetLastError());
  cycle_close(c);
  free(c);
  return code;
}

static BOOL cycle_create_file(cycle_state *c, const WCHAR *name,
                              const void *data, DWORD size, HANDLE *out) {
  WCHAR path[CAP];
  PSECURITY_DESCRIPTOR sd = NULL;
  if (!CYCLE_CHECK(fmt(path, CAP, L"%ls\\control\\%ls", c->path, name)) ||
      !CYCLE_CHECK(make_sd(&c->s, FALSE, 1, FALSE, &sd)))
    return FALSE;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), sd, FALSE};
  *out = CreateFileW(
      path,
      GENERIC_READ | GENERIC_WRITE | READ_CONTROL | WRITE_DAC | WRITE_OWNER,
      FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, CREATE_NEW,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, NULL);
  LocalFree(sd);
  return CYCLE_CHECK(*out != INVALID_HANDLE_VALUE) &&
         CYCLE_CHECK((!size || write_all(*out, data, size))) &&
         CYCLE_CHECK(FlushFileBuffers(*out));
}
static BOOL cycle_directory(cycle_state *c, const WCHAR *path, int il,
                            HANDLE *out) {
  PSECURITY_DESCRIPTOR sd = NULL;
  if (!CYCLE_CHECK(make_sd(&c->s, FALSE, il, TRUE, &sd)))
    return FALSE;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), sd, FALSE};
  BOOL good = CYCLE_CHECK(CreateDirectoryW(path, &sa));
  LocalFree(sd);
  if (!CYCLE_CHECK(good))
    return FALSE;
  *out = cycle_open(path, TRUE, WRITE_DAC | WRITE_OWNER);
  return CYCLE_CHECK(*out != INVALID_HANDLE_VALUE);
}
static BOOL cycle_grant_plan(cycle_state *c, DWORD index) {
  cycle_object *o = &c->m.objects[index];
  PSECURITY_DESCRIPTOR original = o->original;
  PSID owner = NULL, group = NULL;
  PACL dacl = NULL, sacl = NULL, updated = NULL;
  BOOL dp, sp, od, gd, dd, sd;
  SECURITY_DESCRIPTOR_CONTROL control;
  DWORD revision;
  if (!CYCLE_CHECK(
          checked_api(GetSecurityDescriptorOwner(original, &owner, &od),
                      "GetSecurityDescriptorOwner", "plan original")) ||
      !CYCLE_CHECK(
          checked_api(GetSecurityDescriptorGroup(original, &group, &gd),
                      "GetSecurityDescriptorGroup", "plan original")) ||
      !CYCLE_CHECK(
          checked_api(GetSecurityDescriptorDacl(original, &dp, &dacl, &dd),
                      "GetSecurityDescriptorDacl", "plan original")) ||
      !CYCLE_CHECK(
          checked_api(GetSecurityDescriptorSacl(original, &sp, &sacl, &sd),
                      "GetSecurityDescriptorSacl", "plan original")) ||
      !CYCLE_CHECK(checked_api(
          GetSecurityDescriptorControl(original, &control, &revision),
          "GetSecurityDescriptorControl", "plan original")))
    return FALSE;
  if (!dp || !dacl)
    return cycle_api_fail("GetSecurityDescriptorDacl", "missing plan DACL",
                          ERROR_INVALID_SECURITY_DESCR);
  EXPLICIT_ACCESSW grant = {0};
  grant.grfAccessPermissions =
      index == 1 ? 0x001201ff : FILE_GENERIC_READ | FILE_GENERIC_EXECUTE;
  grant.grfAccessMode = GRANT_ACCESS;
  grant.grfInheritance = NO_INHERITANCE;
  grant.Trustee.TrusteeForm = TRUSTEE_IS_SID;
  grant.Trustee.ptstrName = (LPWSTR)c->s.lease;
  SECURITY_DESCRIPTOR absolute;
  DWORD error = SetEntriesInAclW(1, &grant, dacl, &updated);
  if (error != ERROR_SUCCESS)
    return cycle_api_fail("SetEntriesInAclW", "pListOfExplicitEntries/pOldAcl",
                          error);
  BOOL good =
      CYCLE_CHECK(checked_api(
          InitializeSecurityDescriptor(&absolute, SECURITY_DESCRIPTOR_REVISION),
          "InitializeSecurityDescriptor", "plan absolute")) &&
      CYCLE_CHECK(checked_api(SetSecurityDescriptorOwner(&absolute, owner, od),
                              "SetSecurityDescriptorOwner", "plan absolute")) &&
      CYCLE_CHECK(checked_api(SetSecurityDescriptorGroup(&absolute, group, gd),
                              "SetSecurityDescriptorGroup", "plan absolute")) &&
      CYCLE_CHECK(
          checked_api(SetSecurityDescriptorDacl(&absolute, dp, updated, dd),
                      "SetSecurityDescriptorDacl", "plan absolute")) &&
      CYCLE_CHECK(
          checked_api(SetSecurityDescriptorSacl(&absolute, sp, sacl, sd),
                      "SetSecurityDescriptorSacl", "plan absolute"));
  /* PRESENT/DEFAULTED are set by the component setters above. Passing them
     as ControlBitsToSet makes SetSecurityDescriptorControl fail with 87. */
  const SECURITY_DESCRIPTOR_CONTROL mask =
      SE_DACL_PROTECTED | SE_DACL_AUTO_INHERITED | SE_DACL_AUTO_INHERIT_REQ |
      SE_SACL_PROTECTED | SE_SACL_AUTO_INHERITED | SE_SACL_AUTO_INHERIT_REQ;
  SECURITY_DESCRIPTOR_CONTROL requested = control & mask;
  if (good) {
    printf("CYCLE_SD_CONTROL object=%lu original=0x%04x "
           "ControlBitsOfInterest=0x%04x ControlBitsToSet=0x%04x\n",
           index, control, mask, requested);
    good =
        CYCLE_CHECK(SetSecurityDescriptorControl(&absolute, mask, requested));
    if (!good)
      cycle_api_fail("SetSecurityDescriptorControl", "ControlBitsToSet",
                     GetLastError());
  }
  DWORD required = 0;
  if (good) {
    BOOL queried = MakeSelfRelativeSD(&absolute, NULL, &required);
    error = GetLastError();
    if (queried || error != ERROR_INSUFFICIENT_BUFFER || !required)
      good = cycle_api_fail(
          "MakeSelfRelativeSD", "size query",
          queried || (error == ERROR_INSUFFICIENT_BUFFER && !required)
              ? ERROR_INVALID_DATA
              : error);
    else if (required > sizeof(o->prepared))
      good = cycle_api_fail("MakeSelfRelativeSD", "durable SD capacity",
                            ERROR_INSUFFICIENT_BUFFER);
  }
  if (good) {
    DWORD capacity = required;
    if (!MakeSelfRelativeSD(&absolute, o->prepared, &capacity))
      good =
          cycle_api_fail("MakeSelfRelativeSD", "prepared SD", GetLastError());
    else {
      o->prepared_length = GetSecurityDescriptorLength(o->prepared);
      good = CYCLE_CHECK(o->prepared_length) &&
             CYCLE_CHECK(o->prepared_length <= required);
      if (!good)
        cycle_api_fail("GetSecurityDescriptorLength", "prepared SD bounds",
                       ERROR_INVALID_SECURITY_DESCR);
      printf("CYCLE_SD_SIZE object=%lu required=%lu reserved=%zu actual=%lu\n",
             index, required, sizeof(o->prepared), o->prepared_length);
    }
  }
  error = good ? ERROR_SUCCESS : GetLastError();
  if (updated)
    LocalFree(updated);
  if (!good)
    SetLastError(error);
  return CYCLE_CHECK(good);
}
static BOOL cycle_named_sd(cycle_state *c, BOOL job,
                           PSECURITY_DESCRIPTOR *out) {
  WCHAR sddl[1024];
  DWORD mask = job ? JOB_OBJECT_ALL_ACCESS : EVENT_ALL_ACCESS;
  return CYCLE_CHECK(fmt(
             sddl, 1024,
             L"O:%lsG:%lsD:P(A;;0x%08lx;;;%ls)(A;;0x%08lx;;;SY)(A;;RC;;;OW)S:("
             L"ML;;NW;;;ME)",
             c->s.user_text, c->s.user_text, mask, c->s.user_text, mask)) &&
         CYCLE_CHECK(ConvertStringSecurityDescriptorToSecurityDescriptorW(
             sddl, SDDL_REVISION_1, out, NULL));
}
static BOOL cycle_named_objects(cycle_state *c) {
  PSECURITY_DESCRIPTOR sd = NULL;
  if (!CYCLE_CHECK(cycle_named_sd(c, TRUE, &sd)))
    return FALSE;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), sd, FALSE};
  SetLastError(ERROR_SUCCESS);
  c->job = CreateJobObjectW(&sa, c->m.job);
  BOOL good = CYCLE_CHECK(c->job) &&
              CYCLE_CHECK(GetLastError() != ERROR_ALREADY_EXISTS);
  LocalFree(sd);
  sd = NULL;
  good = good && CYCLE_CHECK(cycle_named_sd(c, FALSE, &sd));
  sa.lpSecurityDescriptor = sd;
  if (good) {
    SetLastError(0);
    c->ready = CreateEventW(&sa, TRUE, FALSE, c->m.ready);
    good = CYCLE_CHECK(c->ready) &&
           CYCLE_CHECK(GetLastError() != ERROR_ALREADY_EXISTS);
  }
  if (good) {
    SetLastError(0);
    c->release = CreateEventW(&sa, TRUE, FALSE, c->m.release);
    good = CYCLE_CHECK(c->release) &&
           CYCLE_CHECK(GetLastError() != ERROR_ALREADY_EXISTS);
  }
  if (good) {
    SetLastError(0);
    c->stop = CreateEventW(&sa, TRUE, FALSE, c->m.stop);
    good = CYCLE_CHECK(c->stop) &&
           CYCLE_CHECK(GetLastError() != ERROR_ALREADY_EXISTS);
  }
  LocalFree(sd);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
      JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
  return good &&
         CYCLE_CHECK(SetInformationJobObject(c->job,
                                             JobObjectExtendedLimitInformation,
                                             &limits, sizeof(limits))) &&
         CYCLE_CHECK(cycle_sd(c->job, c->m.job_sd, &c->m.job_length)) &&
         CYCLE_CHECK(cycle_sd(c->ready, c->m.event_sd, &c->m.event_length));
}
static BOOL cycle_holder_start(cycle_state *c) {
  WCHAR exe[CAP], command[CAP * 2];
  if (!CYCLE_CHECK(bounded_text(GetModuleFileNameW(NULL, exe, CAP), CAP,
                                "GetModuleFileNameW")) ||
      !CYCLE_CHECK(fmt(command, CAP * 2, L"\"%ls\" cycle-hold %ls", exe,
                       cycle_names[c->m.scenario])))
    return FALSE;
  STARTUPINFOW si = {0};
  PROCESS_INFORMATION pi = {0};
  si.cb = sizeof(si);
  BOOL good =
      CYCLE_CHECK(CreateProcessW(exe, command, NULL, NULL, FALSE,
                                 CREATE_NO_WINDOW, NULL, c->base, &si, &pi));
  if (!CYCLE_CHECK(good))
    return FALSE;
  c->holder = pi.hProcess;
  close_handle(&pi.hThread);
  HANDLE waits[] = {c->ready, c->holder};
  good = CYCLE_CHECK(WaitForMultipleObjects(2, waits, FALSE, WAIT_MS) ==
                     WAIT_OBJECT_0);
  if (good) {
    struct {
      DWORD pid;
      FILETIME birth;
    } witness = {0};
    FILETIME exit, kernel, user;
    witness.pid = pi.dwProcessId;
    good = CYCLE_CHECK(GetProcessTimes(c->holder, &witness.birth, &exit,
                                       &kernel, &user)) &&
           CYCLE_CHECK(
               cycle_append(c, CY_JOB_WITNESS, 0, &witness, sizeof(witness)));
    if (good) {
      c->witness_pid = witness.pid;
      c->witness_birth = witness.birth;
    }
  }
  if (!good)
    printf("HOLDER_START failed win32=%lu\n", GetLastError());
  return CYCLE_CHECK(good);
}
static int cycle_holder(DWORD scenario) {
  cycle_state *c = calloc(1, sizeof(*c));
  if (!c)
    return 1;
  BOOL good = cycle_load(c, scenario, FALSE);
  if (good) {
    c->job = OpenJobObjectW(JOB_OBJECT_QUERY | READ_CONTROL, FALSE, c->m.job);
    c->release = OpenEventW(SYNCHRONIZE | READ_CONTROL, FALSE, c->m.release);
    good = c->job && c->release && cycle_job_valid(c, c->job) &&
           cycle_signal(c, c->m.ready);
  }
  /* Release all files. Only the non-inherited Job/event handles survive. This
     medium witness lets recovery QUERY the real tree even after broker crash.
   */
  for (DWORD i = 1; i < CYCLE_OBJECTS; ++i)
    close_handle(&c->objects[i]);
  close_handle(&c->journal);
  close_handle(&c->catalog);
  close_handle(&c->control);
  close_handle(&c->root);
  if (good)
    good = WaitForSingleObject(c->release, INFINITE) == WAIT_OBJECT_0;
  cycle_close(c);
  free(c);
  return good ? 0 : 1;
}
static BOOL cycle_prepare(cycle_state *c, DWORD scenario, const WCHAR *child) {
  if (!CYCLE_CHECK(cycle_paths(c, scenario)) || !CYCLE_CHECK(cycle_user(c)))
    return FALSE;
  c->m.version = CYCLE_VERSION;
  c->m.scenario = scenario;
  c->m.broker_pid = GetCurrentProcessId();
  FILETIME exit, kernel, user;
  if (!CYCLE_CHECK(cycle_boot(&c->m.boot_time)) ||
      !CYCLE_CHECK(GetProcessTimes(GetCurrentProcess(), &c->m.broker_birth,
                                   &exit, &kernel, &user)) ||
      !CYCLE_CHECK(random_bytes(c->m.lease, 16)) ||
      !CYCLE_CHECK(fmt(c->m.owner, 256, L"%ls", c->s.user_text)) ||
      !CYCLE_CHECK(fmt(c->m.root, CAP, L"%ls", c->path)))
    return FALSE;
  DWORD random[4];
  memcpy(random, c->m.lease, 16);
  if (!CYCLE_CHECK(fmt(c->m.moniker, 64, L"DevAgents.Sec5.%08lx%08lx%08lx%08lx",
                       random[0], random[1], random[2], random[3])) ||
      !CYCLE_CHECK(
          fmt(c->m.job, 128, L"Local\\Sec5.R3.Job.%ls", c->m.moniker)) ||
      !CYCLE_CHECK(
          fmt(c->m.ready, 128, L"Local\\Sec5.R3.Ready.%ls", c->m.moniker)) ||
      !CYCLE_CHECK(fmt(c->m.release, 128, L"Local\\Sec5.R3.Release.%ls",
                       c->m.moniker)) ||
      !CYCLE_CHECK(
          fmt(c->m.stop, 128, L"Local\\Sec5.R3.Stop.%ls", c->m.moniker)) ||
      !CYCLE_CHECK(!(FAILED(DeriveAppContainerSidFromAppContainerName(
          c->m.moniker, &c->s.lease)))))
    return FALSE;
  LPWSTR text = NULL;
  BOOL good = CYCLE_CHECK(ConvertSidToStringSidW(c->s.lease, &text)) &&
              CYCLE_CHECK(fmt(c->m.sid, 256, L"%ls", text)) &&
              CYCLE_CHECK(fmt(c->s.sid_text, 256, L"%ls", text));
  if (text)
    LocalFree(text);
  if (!CYCLE_CHECK(good))
    return FALSE;
  c->m.sid_length = GetLengthSid(c->s.lease);
  if (!CYCLE_CHECK(!(c->m.sid_length > sizeof(c->m.package_sid))) ||
      !CYCLE_CHECK(
          CopySid(sizeof(c->m.package_sid), c->m.package_sid, c->s.lease)))
    return FALSE;
  WCHAR volume[CAP], fs[64];
  DWORD serial, flags;
  if (!CYCLE_CHECK(GetVolumePathNameW(c->base, volume, CAP)) ||
      !CYCLE_CHECK(
          GetVolumeNameForVolumeMountPointW(volume, c->m.volume_guid, 128)) ||
      !CYCLE_CHECK(GetVolumeInformationW(volume, NULL, 0, &serial, NULL, &flags,
                                         fs, 64)) ||
      !CYCLE_CHECK(!(wcscmp(fs, L"NTFS"))) ||
      !CYCLE_CHECK((flags & FILE_PERSISTENT_ACLS)))
    return FALSE;
  if (!CYCLE_CHECK(cycle_directory(c, c->path, 1, &c->root)))
    return FALSE;
  c->objects[0] = c->root;
  WCHAR path[CAP];
  if (!CYCLE_CHECK(fmt(path, CAP, L"%ls\\control", c->path)) ||
      !CYCLE_CHECK(cycle_directory(c, path, 1, &c->control)) ||
      !CYCLE_CHECK(fmt(path, CAP, L"%ls\\dest", c->path)) ||
      !CYCLE_CHECK(cycle_directory(c, path, 0, &c->objects[1])) ||
      !CYCLE_CHECK(fmt(c->s.child, CAP, L"%ls\\sec5-child.exe", c->path)))
    return FALSE;
  /* Copy bytes using the existing fixture helper, then set the ordinary-only
     original before any package concession or profile API call. */
  WCHAR saved_sid[256];
  memcpy(saved_sid, c->s.sid_text, sizeof(saved_sid));
  fmt(c->s.sid_text, 256, L"%ls", c->s.user_text);
  good = CYCLE_CHECK(copy_private_child(&c->s, child));
  memcpy(c->s.sid_text, saved_sid, sizeof(saved_sid));
  if (!CYCLE_CHECK(good))
    return FALSE;
  c->objects[2] =
      cycle_open(c->s.child, FALSE, WRITE_DAC | WRITE_OWNER | GENERIC_READ);
  PSECURITY_DESCRIPTOR original = NULL;
  good = CYCLE_CHECK(c->objects[2] != INVALID_HANDLE_VALUE) &&
         CYCLE_CHECK(make_sd(&c->s, FALSE, 1, FALSE, &original)) &&
         CYCLE_CHECK(set_sd(c->objects[2], SE_FILE_OBJECT, original, TRUE));
  if (original)
    LocalFree(original);
  if (!CYCLE_CHECK(good))
    return FALSE;
  for (DWORD i = 0; i < CYCLE_OBJECTS; ++i) {
    cycle_object *o = &c->m.objects[i];
    BY_HANDLE_FILE_INFORMATION info;
    if (!CYCLE_CHECK(cycle_identity(c->objects[i], &o->id, &o->birth)) ||
        !CYCLE_CHECK(GetFileInformationByHandle(c->objects[i], &info)) ||
        !CYCLE_CHECK(
            cycle_sd(c->objects[i], o->original, &o->original_length)) ||
        !CYCLE_CHECK(cycle_grant_plan(c, i)))
      return FALSE;
    o->attributes = info.dwFileAttributes;
  }
  if (!CYCLE_CHECK(
          cycle_identity(c->control, &c->m.control_id, &c->m.control_birth)) ||
      !CYCLE_CHECK(
          cycle_sd(c->control, c->m.control_sd, &c->m.control_length)) ||
      !CYCLE_CHECK(cycle_named_objects(c)) ||
      !CYCLE_CHECK(
          cycle_create_file(c, L"journal.bin", NULL, 0, &c->journal)) ||
      !CYCLE_CHECK(
          cycle_identity(c->journal, &c->m.journal_id, &c->m.journal_birth)) ||
      !CYCLE_CHECK(
          cycle_create_file(c, L"catalog.bin", NULL, 0, &c->catalog)) ||
      !CYCLE_CHECK(
          cycle_identity(c->catalog, &c->m.catalog_id, &c->m.catalog_birth)) ||
      !CYCLE_CHECK(
          cycle_sd(c->journal, c->m.journal_sd, &c->m.journal_length)) ||
      !CYCLE_CHECK(
          cycle_sd(c->catalog, c->m.catalog_sd, &c->m.catalog_length)) ||
      !CYCLE_CHECK(cycle_lock(c)))
    return FALSE;
  HANDLE seed = NULL;
  good = CYCLE_CHECK(
      cycle_create_file(c, L"seed.bin", &c->m, sizeof(c->m), &seed));
  close_handle(&seed);
  if (!CYCLE_CHECK(good))
    return FALSE;
  /* no-intent mutates only this precondition. The seed is diagnostic rescue
     data, never treated as a PROFILE_INTENT by normal recovery. */
  if (scenario != 11 &&
      !CYCLE_CHECK(cycle_append(c, CY_PROFILE_INTENT, 0, &c->m, sizeof(c->m))))
    return FALSE;
  if (!CYCLE_CHECK(cycle_catalog_write(c)))
    return FALSE;
  if (scenario != 11 && !CYCLE_CHECK(cycle_holder_start(c)))
    return FALSE;
  /* Mutation needs a holder too; it uses the saved seed solely as a witness,
     and recovery must still reject the absent intention. */
  return TRUE;
}
static int cycle_lifecycle(enum sec5_stage stage, HANDLE process, HANDLE job,
                           void *context) {
  cycle_state *c = context;
  if (stage == SEC5_OBSERVE) {
    if (!CYCLE_CHECK(appcontainer_token_cap(process, c->s.lease, NULL, TRUE)) ||
        !CYCLE_CHECK(job_owns(job, process)))
      return 0;
    struct {
      DWORD pid;
      FILETIME birth;
    } identity = {0};
    FILETIME exit, kernel, user;
    identity.pid = GetProcessId(process);
    if (!CYCLE_CHECK(
            GetProcessTimes(process, &identity.birth, &exit, &kernel, &user)))
      return 0;
    c->assigned_pid = identity.pid;
    c->assigned_birth = identity.birth;
    return CYCLE_CHECK(
               cycle_append(c, CY_ASSIGNED, 0, &identity, sizeof(identity))) &&
           CYCLE_CHECK(cycle_append(c, CY_RUN_INTENT, 0, NULL, 0));
  }
  if (stage == SEC5_RESUME) {
    if (c->m.scenario == 5)
      cycle_crash("Resume-before-ACK");
    return CYCLE_CHECK(cycle_append(c, CY_RUNNING, 0, NULL, 0));
  }
  printf("CYCLE_LIFECYCLE_STAGE expected=%u|%u obtained=%u\n", SEC5_OBSERVE,
         SEC5_RESUME, stage);
  return cycle_check(FALSE, "supported lifecycle stage", __func__, __LINE__);
}
typedef struct cycle_marker {
  DWORD magic, pid;
  FILETIME birth;
  BYTE lease[16];
} cycle_marker;
static BOOL cycle_marker_lease(const WCHAR *moniker, BYTE lease[16]) {
  static const WCHAR prefix[] = L"DevAgents.Sec5.";
  const size_t prefix_length = sizeof(prefix) / sizeof(prefix[0]) - 1;
  if (wcslen(moniker) != prefix_length + 32 ||
      wcsncmp(moniker, prefix, prefix_length))
    return FALSE;
  DWORD random[4];
  for (DWORD i = 0; i < 4; ++i) {
    WCHAR piece[9], *end;
    memcpy(piece, moniker + prefix_length + i * 8, 8 * sizeof(WCHAR));
    piece[8] = 0;
    random[i] = wcstoul(piece, &end, 16);
    if (*end)
      return FALSE;
  }
  memcpy(lease, random, 16);
  return TRUE;
}
static BOOL cycle_marker_fail(const char *api, const WCHAR *path, DWORD error) {
  if (!error)
    error = ERROR_INVALID_DATA;
  printf("CYCLE_MARKER_FAIL api=%s path=%ls win32=%lu\n", api, path, error);
  fflush(stdout);
  SetLastError(error);
  return FALSE;
}
static int cycle_child(int argc, WCHAR **argv) {
  if (argc != 5 ||
      (wcscmp(argv[1], L"cycle-child") && wcscmp(argv[1], L"cycle-grand")))
    return 2;
  cycle_marker marker = {0};
  marker.magic = MAGIC;
  marker.pid = GetCurrentProcessId();
  if (!cycle_marker_lease(argv[4], marker.lease)) {
    cycle_marker_fail("cycle_marker_lease", argv[2], ERROR_INVALID_DATA);
    return 2;
  }
  FILETIME exit, kernel, user;
  if (!GetProcessTimes(GetCurrentProcess(), &marker.birth, &exit, &kernel,
                       &user)) {
    cycle_marker_fail("GetProcessTimes", argv[2], GetLastError());
    return 1;
  }
  WCHAR path[CAP];
  BOOL grand = !wcscmp(argv[1], L"cycle-grand");
  if (!fmt(path, CAP, L"%ls\\%ls.bin", argv[2], grand ? L"grand" : L"child"))
    return 1;
  /* Publishing child.bin also acknowledges successful grandchild creation.
     Readers can pin the grandchild before waiting for its marker. */
  if (!grand) {
    WCHAR command[CAP * 3];
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    si.cb = sizeof(si);
    if (!fmt(command, CAP * 3, L"\"%ls\" cycle-grand \"%ls\" \"%ls\" %ls",
             argv[3], argv[2], argv[3], argv[4]) ||
        !CreateProcessW(argv[3], command, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                        NULL, argv[2], &si, &pi)) {
      cycle_marker_fail("CreateProcessW(cycle-grand)", argv[3], GetLastError());
      return 1;
    }
    close_handle(&pi.hThread);
    close_handle(&pi.hProcess);
  }
  /* Exclusive until flush and close: the broker must not read partial bytes. */
  HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                            FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (file == INVALID_HANDLE_VALUE) {
    cycle_marker_fail("CreateFileW(CREATE_NEW)", path, GetLastError());
    return 1;
  }
  DWORD written = 0;
  BOOL good = WriteFile(file, &marker, sizeof(marker), &written, NULL);
  if (!good || written != sizeof(marker)) {
    cycle_marker_fail("WriteFile", path,
                      good ? ERROR_WRITE_FAULT : GetLastError());
    close_handle(&file);
    return 1;
  }
  if (!FlushFileBuffers(file)) {
    cycle_marker_fail("FlushFileBuffers", path, GetLastError());
    close_handle(&file);
    return 1;
  }
  close_handle(&file);
  Sleep(INFINITE);
  return 1;
}
static BOOL cycle_live_tree(cycle_state *c, const cycle_marker markers[2]) {
  /* Windows can add one console host per fixture process, even with
     CREATE_NO_WINDOW. Count the two certified fixtures separately, and reject
     every other member unless it is the system console host bound to one of
     those still-pinned parents. Recovery continues to terminate the whole Job.
   */
  union {
    ULONG_PTR alignment;
    BYTE bytes[sizeof(JOBOBJECT_BASIC_PROCESS_ID_LIST) + 4 * sizeof(ULONG_PTR)];
  } buffer = {0};
  JOBOBJECT_BASIC_PROCESS_ID_LIST *list = (void *)buffer.bytes;
  BOOL good = checked_api(
      QueryInformationJobObject(c->job, JobObjectBasicProcessIdList, list,
                                sizeof(buffer), NULL),
      "QueryInformationJobObject", "live tree process list (at most 4)");
  printf("CYCLE_TREE_COUNT expected_fixtures=2 expected_total=2..4 "
         "assigned=%lu listed=%lu queried=%d\n",
         list->NumberOfAssignedProcesses, list->NumberOfProcessIdsInList, good);
  good = good && CYCLE_CHECK(list->NumberOfAssignedProcesses >= 2) &&
         CYCLE_CHECK(list->NumberOfAssignedProcesses <= 4) &&
         CYCLE_VALUE(list->NumberOfProcessIdsInList,
                     list->NumberOfAssignedProcesses) &&
         CYCLE_CHECK(markers[0].pid != markers[1].pid);
  HANDLE parents[2] = {NULL, NULL};
  BOOL found[2] = {FALSE, FALSE}, consoles[2] = {FALSE, FALSE};
  WCHAR windows[CAP], console[CAP], expected_console[CAP];
  good =
      good &&
      CYCLE_CHECK(bounded_text(GetWindowsDirectoryW(windows, CAP), CAP,
                               "GetWindowsDirectoryW")) &&
      CYCLE_CHECK(fmt(console, CAP, L"%ls\\System32\\conhost.exe", windows)) &&
      CYCLE_CHECK(normalized_path(console, expected_console));
  for (DWORD i = 0; good && i < 2; ++i) {
    parents[i] = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                             FALSE, markers[i].pid);
    FILETIME birth, exit, kernel, user;
    good = CYCLE_CHECK(parents[i] != NULL) &&
           CYCLE_CHECK(
               GetProcessTimes(parents[i], &birth, &exit, &kernel, &user)) &&
           CYCLE_CHECK(!memcmp(&birth, &markers[i].birth, sizeof(birth))) &&
           CYCLE_CHECK(WaitForSingleObject(parents[i], 0) == WAIT_TIMEOUT) &&
           CYCLE_CHECK(job_owns(c->job, parents[i]));
  }
  sec5_process_table snapshot = {0};
  good = good && CYCLE_CHECK(sec5_process_snapshot(&snapshot));
  for (DWORD i = 0; good && i < list->NumberOfProcessIdsInList; ++i) {
    ULONG_PTR pid = list->ProcessIdList[i];
    if (pid == markers[0].pid || pid == markers[1].pid) {
      DWORD parent = pid == markers[0].pid ? 0 : 1;
      good = CYCLE_CHECK(!found[parent]);
      found[parent] = TRUE;
      continue;
    }
    good = CYCLE_CHECK(pid != 0 && pid <= MAXDWORD);
    const sec5_process_entry *entry = NULL;
    for (unsigned row = 0; good && row < snapshot.count; ++row)
      if (snapshot.entries[row].pid == pid)
        entry = &snapshot.entries[row];
    good = good && CYCLE_CHECK(entry != NULL);
    if (!good)
      break;
    good = CYCLE_CHECK(entry->parent == markers[0].pid ||
                       entry->parent == markers[1].pid);
    DWORD parent = entry->parent == markers[0].pid ? 0 : 1;
    FILETIME parent_birth, parent_exit, parent_kernel, parent_user;
    good = good &&
           CYCLE_CHECK(GetProcessTimes(parents[parent], &parent_birth,
                                       &parent_exit, &parent_kernel,
                                       &parent_user)) &&
           CYCLE_CHECK(sec5_same_instance(GetProcessId(parents[parent]),
                                          parent_birth, markers[parent].pid,
                                          markers[parent].birth));
    int classification =
        good ? sec5_descendant_classify(entry->parent, entry->birth,
                                        markers[parent].pid, parent_birth,
                                        parent_exit, TRUE)
             : -1;
    if (classification == 0)
      printf("DESCENDANT_DISCARD pid=%lu parent=%lu "
             "reason=outside_parent_lifetime opened=0 scope=cycle-live-job\n",
             entry->pid, entry->parent);
    /* Every listed Job member must still be accounted for; a discarded
       temporal candidate cannot certify this exact live-tree inventory. */
    good = good && CYCLE_CHECK(classification == 1);
    HANDLE process =
        good ? OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                           FALSE, (DWORD)pid)
             : NULL;
    WCHAR image[CAP] = {0}, normalized[CAP] = {0};
    DWORD length = CAP;
    FILETIME birth, exit, kernel, user;
    good =
        good && CYCLE_CHECK(!consoles[parent]) &&
        CYCLE_CHECK(process != NULL) &&
        CYCLE_CHECK(QueryFullProcessImageNameW(process, 0, image, &length)) &&
        CYCLE_CHECK(normalized_path(image, normalized)) &&
        CYCLE_CHECK(!wcscmp(normalized, expected_console)) &&
        CYCLE_CHECK(GetProcessTimes(process, &birth, &exit, &kernel, &user)) &&
        CYCLE_CHECK(sec5_same_instance(GetProcessId(process), birth, entry->pid,
                                       entry->birth)) &&
        CYCLE_CHECK(CompareFileTime(&birth, &markers[parent].birth) >= 0) &&
        CYCLE_CHECK(WaitForSingleObject(process, 0) == WAIT_TIMEOUT) &&
        CYCLE_CHECK(job_owns(c->job, process));
    printf("CYCLE_CONSOLE_MEMBER pid=%llu parent=%lu expected_parent=%lu|%lu "
           "expected_image=%ls obtained_image=%ls certified=%d\n",
           (unsigned long long)pid, entry->parent, markers[0].pid,
           markers[1].pid, expected_console,
           normalized[0] ? normalized : L"unavailable", good);
    DWORD error = GetLastError();
    close_handle(&process);
    SetLastError(error);
    if (good)
      consoles[parent] = TRUE;
  }
  DWORD active = 0;
  BOOL accounting_queried = FALSE;
  good = good && CYCLE_CHECK(found[0] && found[1]);
  if (good) {
    accounting_queried = cycle_empty(c->job, &active);
    good = CYCLE_CHECK(accounting_queried) &&
           CYCLE_VALUE(active, list->NumberOfProcessIdsInList);
  }
  printf("CYCLE_LIVE_TREE fixtures=%u consoles=%u active=%lu "
         "accounting_queried=%d certified=%d\n",
         (unsigned)(found[0] + found[1]), (unsigned)(consoles[0] + consoles[1]),
         active, accounting_queried, good);
  c->live_fixtures = (DWORD)(found[0] + found[1]);
  c->live_consoles = (DWORD)(consoles[0] + consoles[1]);
  c->live_active = active;
  c->live_certified = good;
  DWORD error = GetLastError();
  free(snapshot.entries);
  close_handle(&parents[0]);
  close_handle(&parents[1]);
  SetLastError(error);
  return good;
}
/* Pin the expected grandchild independently of bytes in an incomplete marker.
   child.bin is published only after CreateProcessW(cycle-grand) succeeds. */
static HANDLE cycle_grand_pin(cycle_state *c, const cycle_marker *parent,
                              HANDLE parent_process) {
  FILETIME parent_birth, parent_exit, kernel, user;
  if (!GetProcessTimes(parent_process, &parent_birth, &parent_exit, &kernel,
                       &user) ||
      !sec5_same_instance(GetProcessId(parent_process), parent_birth,
                          parent->pid, parent->birth))
    return NULL;
  sec5_process_table snapshot;
  if (!sec5_process_snapshot(&snapshot))
    return NULL;
  HANDLE found = NULL;
  WCHAR image_path[CAP], expected[CAP];
  BOOL good = fmt(image_path, CAP, L"%ls\\sec5-child.exe", c->path) &&
              normalized_path(image_path, expected);
  for (unsigned row = 0; good && row < snapshot.count; ++row) {
    const sec5_process_entry *entry = &snapshot.entries[row];
    if (entry->parent == parent->pid) {
      int classification =
          sec5_descendant_classify(entry->parent, entry->birth, parent->pid,
                                   parent_birth, parent_exit, TRUE);
      if (classification == 0) {
        printf("DESCENDANT_DISCARD pid=%lu parent=%lu "
               "reason=outside_parent_lifetime opened=0 scope=cycle-grand\n",
               entry->pid, entry->parent);
        continue;
      }
      if (classification < 0) {
        good = FALSE;
        SetLastError(ERROR_INVALID_DATA);
        break;
      }
      HANDLE process = OpenProcess(
          PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, entry->pid);
      WCHAR image[CAP], normalized[CAP];
      DWORD length = CAP;
      FILETIME birth, exit, process_kernel, process_user;
      good = process &&
             GetProcessTimes(process, &birth, &exit, &process_kernel,
                             &process_user) &&
             sec5_same_instance(GetProcessId(process), birth, entry->pid,
                                entry->birth) &&
             QueryFullProcessImageNameW(process, 0, image, &length) &&
             normalized_path(image, normalized);
      if (good && !wcscmp(normalized, expected)) {
        good = CYCLE_CHECK(!found) &&
               CYCLE_CHECK(CompareFileTime(&birth, &parent->birth) >= 0) &&
               CYCLE_CHECK(WaitForSingleObject(process, 0) == WAIT_TIMEOUT) &&
               CYCLE_CHECK(job_owns(c->job, process)) &&
               CYCLE_CHECK(
                   appcontainer_token_cap(process, c->s.lease, NULL, FALSE));
        if (good) {
          found = process;
          process = NULL;
        }
      }
      DWORD error = GetLastError();
      close_handle(&process);
      SetLastError(error);
    }
  }
  DWORD error = good ? ERROR_SUCCESS : GetLastError();
  free(snapshot.entries);
  if (!good || !found) {
    close_handle(&found);
    SetLastError(error ? error : ERROR_PROCESS_ABORTED);
  }
  return found;
}
static BOOL cycle_marker_wait(cycle_state *c, DWORD child, HANDLE process,
                              const FILETIME *birth, cycle_marker *marker) {
  WCHAR path[CAP];
  if (!CYCLE_CHECK(fmt(path, CAP, L"%ls\\dest\\%ls.bin", c->path,
                       child ? L"grand" : L"child")))
    return FALSE;
  ULONGLONG started = GetTickCount64(), deadline = started + WAIT_MS;
  DWORD attempts = 0, error = ERROR_SUCCESS;
  const char *api = "marker deadline";
  BOOL good = FALSE;
  printf("CYCLE_MARKER_WAIT child=%lu phase=begin deadline_ms=%u\n", child,
         WAIT_MS);
  fflush(stdout);
  for (;;) {
    if (attempts && GetTickCount64() >= deadline) {
      api = "marker deadline";
      error = ERROR_TIMEOUT;
      break;
    }
    ++attempts;
    DWORD wait = WaitForSingleObject(process, 0);
    if (wait != WAIT_TIMEOUT) {
      api = "WaitForSingleObject(marker process)";
      error = wait == WAIT_FAILED ? GetLastError() : ERROR_PROCESS_ABORTED;
      break;
    }
    /* Deny writes while reading; an exclusive writer must flush and close
       first. No temporary names outside the durable fixed-artifact plan are
       added. */
    HANDLE file =
        CreateFileW(path, GENERIC_READ | READ_CONTROL | FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ, NULL, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    BOOL pending = FALSE;
    if (file == INVALID_HANDLE_VALUE) {
      api = "CreateFileW(OPEN_EXISTING marker)";
      error = GetLastError();
      pending = error == ERROR_FILE_NOT_FOUND ||
                error == ERROR_PATH_NOT_FOUND ||
                error == ERROR_SHARING_VIOLATION;
    } else {
      FILE_ID_INFO id;
      FILETIME created;
      LARGE_INTEGER size = {0};
      DWORD got = 0;
      api = "marker file identity/size";
      good = cycle_identity(file, &id, &created) && GetFileSizeEx(file, &size);
      error = good ? ERROR_SUCCESS : GetLastError();
      if (good &&
          (size.QuadPart < 0 || size.QuadPart > (LONGLONG)sizeof(*marker))) {
        good = FALSE;
        error = ERROR_INVALID_DATA;
      } else if (good && size.QuadPart < (LONGLONG)sizeof(*marker)) {
        good = FALSE;
        pending = TRUE;
        error = ERROR_HANDLE_EOF;
      } else if (good) {
        api = "ReadFile(marker)";
        good = ReadFile(file, marker, sizeof(*marker), &got, NULL);
        error = good ? ERROR_SUCCESS : GetLastError();
        if ((good && got < sizeof(*marker)) ||
            (!good && error == ERROR_HANDLE_EOF)) {
          good = FALSE;
          pending = TRUE;
          error = ERROR_HANDLE_EOF;
        } else if (good) {
          api = "marker nonce/PID/birth/Job/token";
          good = CYCLE_VALUE(marker->magic, MAGIC) &&
                 CYCLE_CHECK(!memcmp(marker->lease, c->m.lease, 16)) &&
                 CYCLE_VALUE(marker->pid, GetProcessId(process)) &&
                 CYCLE_CHECK(!memcmp(&marker->birth, birth, sizeof(*birth))) &&
                 CYCLE_CHECK(WaitForSingleObject(process, 0) == WAIT_TIMEOUT) &&
                 CYCLE_CHECK(job_owns(c->job, process)) &&
                 CYCLE_CHECK(
                     appcontainer_token_cap(process, c->s.lease, NULL, TRUE));
          error = good ? ERROR_SUCCESS : ERROR_INVALID_DATA;
        }
      }
      close_handle(&file);
    }
    if (good || !pending)
      break;
    /* A short/missing marker never substitutes for evidence of a live process.
     */
    DWORD alive = WaitForSingleObject(process, 0);
    if (alive != WAIT_TIMEOUT) {
      api = "WaitForSingleObject(incomplete marker process)";
      error = alive == WAIT_FAILED ? GetLastError() : ERROR_PROCESS_ABORTED;
      break;
    }
    ULONGLONG now = GetTickCount64();
    if (now >= deadline) {
      api = "marker deadline";
      error = ERROR_TIMEOUT;
      break;
    }
    Sleep((DWORD)((deadline - now) < 10 ? (deadline - now) : 10));
  }
  printf("CYCLE_MARKER_WAIT child=%lu phase=end attempts=%lu elapsed_ms=%llu "
         "result=%s win32=%lu\n",
         child, attempts, GetTickCount64() - started, good ? "valid" : "failed",
         error);
  printf("CYCLE_LIVE_MARKER child=%lu nonce_magic=%d pid_birth_job_token=%d\n",
         child,
         marker->magic == MAGIC && !memcmp(marker->lease, c->m.lease, 16),
         good);
  fflush(stdout);
  return good || cycle_marker_fail(api, path, error);
}
static BOOL cycle_markers(cycle_state *c) {
  c->live_fixtures = c->live_consoles = c->live_active = 0;
  c->live_certified = FALSE;
  cycle_marker markers[2] = {0};
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                               FALSE, c->assigned_pid);
  FILETIME birth, exit, kernel, user;
  BOOL good =
      CYCLE_CHECK(process) &&
      CYCLE_CHECK(GetProcessTimes(process, &birth, &exit, &kernel, &user)) &&
      CYCLE_CHECK(!memcmp(&birth, &c->assigned_birth, sizeof(birth))) &&
      CYCLE_CHECK(job_owns(c->job, process)) &&
      CYCLE_CHECK(appcontainer_token_cap(process, c->s.lease, NULL, FALSE)) &&
      cycle_marker_wait(c, 0, process, &birth, &markers[0]);
  HANDLE grand = good ? cycle_grand_pin(c, &markers[0], process) : NULL;
  if (good && !grand)
    good = cycle_marker_fail(
        "grandchild absent/dead/invalid after child publication", c->path,
        GetLastError());
  if (good)
    good = CYCLE_CHECK(GetProcessTimes(grand, &birth, &exit, &kernel, &user)) &&
           cycle_marker_wait(c, 1, grand, &birth, &markers[1]);
  if (good)
    good = CYCLE_CHECK(cycle_live_tree(c, markers));
  DWORD error = good ? ERROR_SUCCESS : GetLastError();
  close_handle(&grand);
  close_handle(&process);
  SetLastError(error);
  return good;
}
static BOOL cycle_dest_empty(cycle_state *c) {
  BYTE data[4096];
  FILE_INFO_BY_HANDLE_CLASS kind = FileIdBothDirectoryRestartInfo;
  for (;;) {
    if (!GetFileInformationByHandleEx(c->objects[1], kind, data, sizeof(data)))
      return GetLastError() == ERROR_NO_MORE_FILES;
    kind = FileIdBothDirectoryInfo;
    for (DWORD offset = 0;;) {
      FILE_ID_BOTH_DIR_INFO *e = (FILE_ID_BOTH_DIR_INFO *)(data + offset);
      BOOL dot = e->FileNameLength == sizeof(WCHAR) && e->FileName[0] == L'.';
      BOOL dots = e->FileNameLength == 2 * sizeof(WCHAR) &&
                  e->FileName[0] == L'.' && e->FileName[1] == L'.';
      if (!dot && !dots)
        return FALSE;
      if (!e->NextEntryOffset)
        break;
      if (e->NextEntryOffset > sizeof(data) - offset)
        return FALSE;
      offset += e->NextEntryOffset;
    }
  }
}
static BOOL cycle_reconcile(cycle_state *c) {
  if (!c->closed)
    return FALSE;
  for (DWORD i = 0; i < 2; ++i) {
    const WCHAR *name = i ? L"grand.bin" : L"child.bin";
    /* ActiveProcesses=0 precedes release of a dying member's file handles.
       Retry only sharing violations, including after a durable TREE_CLOSED.
       Both opening and disposition share one deadline per fixed artifact. */
    ULONGLONG started = GetTickCount64(), deadline = started + WAIT_MS;
    DWORD attempts = 0;
    BOOL retrying = FALSE;
    HANDLE h;
    for (;;) {
      ++attempts;
      h = cycle_relative(c->objects[1], name, FALSE, DELETE);
      if (h != INVALID_HANDLE_VALUE)
        break;
      DWORD error = GetLastError();
      BOOL retry =
          error == ERROR_SHARING_VIOLATION && GetTickCount64() < deadline;
      if (!retry) {
        SetLastError(error);
        break;
      }
      if (!retrying) {
        printf("CYCLE_ARTIFACT_OPEN name=%ls phase=begin win32=%lu\n", name,
               error);
        retrying = TRUE;
      }
      Sleep(10);
    }
    DWORD open_error =
        h == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
    if (retrying)
      printf("CYCLE_ARTIFACT_OPEN name=%ls phase=end attempts=%lu "
             "elapsed_ms=%llu win32=%lu\n",
             name, attempts, GetTickCount64() - started, open_error);
    SetLastError(open_error);
    if (h == INVALID_HANDLE_VALUE) {
      DWORD error = GetLastError();
      if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
        continue;
      return cycle_api_fail("NtOpenFile", "fixed artifact DELETE", error);
    }
    FILE_ID_INFO id;
    FILETIME birth;
    LARGE_INTEGER size = {0};
    cycle_marker marker = {0};
    BOOL good = cycle_identity(h, &id, &birth) && GetFileSizeEx(h, &size) &&
                size.QuadPart >= 0 && size.QuadPart <= (LONGLONG)sizeof(marker);
    if (good && size.QuadPart == sizeof(marker))
      good = cycle_read(h, &marker, sizeof(marker)) && marker.magic == MAGIC &&
             !memcmp(marker.lease, c->m.lease, 16);
    /* A crash immediately after Resume can leave a partial creation. The
       durable fixed new-object plan permits these two names only, after real
       Job emptiness; a full marker must bind to this lease. */
    good = good && cycle_same(h, &id, &birth);
    if (good) {
      attempts = 0;
      retrying = FALSE;
      for (;;) {
        ++attempts;
        good = dispose_file(h, &id);
        if (good)
          break;
        DWORD error = GetLastError();
        BOOL retry =
            error == ERROR_SHARING_VIOLATION && GetTickCount64() < deadline;
        if (!retry) {
          SetLastError(error);
          break;
        }
        if (!retrying) {
          printf("CYCLE_ARTIFACT_DISPOSE name=%ls phase=begin win32=%lu\n",
                 name, error);
          retrying = TRUE;
        }
        Sleep(10);
      }
      DWORD dispose_error = good ? ERROR_SUCCESS : GetLastError();
      if (retrying)
        printf("CYCLE_ARTIFACT_DISPOSE name=%ls phase=end attempts=%lu "
               "elapsed_ms=%llu win32=%lu\n",
               name, attempts, GetTickCount64() - started, dispose_error);
      SetLastError(dispose_error);
    }
    DWORD error = good ? ERROR_SUCCESS : GetLastError();
    printf("CYCLE_ARTIFACT name=%ls bytes=%lld partial=%d removed=%d\n",
           i ? L"grand.bin" : L"child.bin", size.QuadPart,
           size.QuadPart < (LONGLONG)sizeof(marker), good);
    close_handle(&h);
    SetLastError(error);
    if (!good)
      return FALSE;
  }
  BOOL empty = cycle_dest_empty(c);
  printf("CYCLE_DEST_EMPTY verified=%d new_object_residue=%d\n", empty, !empty);
  return empty;
}
static int cycle_broker(DWORD scenario, const WCHAR *child) {
  cycle_state *c = calloc(1, sizeof(*c));
  if (!c) {
    cycle_api_fail("calloc", "cycle_broker state", ERROR_NOT_ENOUGH_MEMORY);
    return 1;
  }
  int code = 1;
  /* CommandLineToArgvW removes the Start-Process transport quotes. Paths
     supplied with the PowerShell call operator have the same parsed form. */
  BOOL quoted = wcschr(child, L'"') != NULL;
  printf("CYCLE_BROKER_INPUT scenario=%ls child=%ls embedded_quote=%d\n",
         cycle_names[scenario], child, quoted);
  if (quoted || wcslen(child) < 3 || child[1] != L':' || child[2] != L'\\') {
    cycle_api_fail("cycle-broker", "child (absolute path without quotes)",
                   ERROR_INVALID_NAME);
    goto done;
  }
  if (!CYCLE_CHECK(cycle_prepare(c, scenario, child)))
    goto done;
  if (scenario == 0)
    cycle_crash("durable-profile-intent");
  ULONGLONG before = GetTickCount64();
  PSID actual = NULL;
  HRESULT hr = CreateAppContainerProfile(
      c->m.moniker, c->m.moniker, L"SEC5 R3 own fixture", NULL, 0, &actual);
  printf("PROFILE_CREATE moniker=%ls HRESULT=0x%08lx latency_ms=%llu\n",
         c->m.moniker, (unsigned long)hr, GetTickCount64() - before);
  fflush(stdout);
  if (FAILED(hr)) {
    cycle_append(c, CY_COLLISION, 0, &hr, sizeof(hr));
    cycle_api_fail("CreateAppContainerProfile", "expected successful HRESULT",
                   HRESULT_FACILITY(hr) == FACILITY_WIN32 ? HRESULT_CODE(hr)
                                                          : ERROR_GEN_FAILURE);
    goto done;
  }
  BOOL sid_match =
      CYCLE_CHECK(actual != NULL) && CYCLE_CHECK(EqualSid(actual, c->s.lease));
  FreeSid(actual);
  if (!sid_match)
    goto done;
  if (scenario == 1 || scenario == 11)
    cycle_crash(scenario == 1 ? "create-before-ACK" : "mutation-no-intent");
  cycle_profile_record identity = {0};
  BOOL good = CYCLE_CHECK(cycle_profile_snapshot(c, &identity));
  if (!good || !CYCLE_CHECK(cycle_append(c, CY_PROFILE_CREATED, 0, &identity,
                                         sizeof(identity))))
    goto done;
  for (DWORD i = 0; i < CYCLE_OBJECTS; ++i) {
    cycle_object *o = &c->m.objects[i];
    if (!CYCLE_CHECK(cycle_append(c, CY_PREPARE_INTENT, i, o, sizeof(*o))) ||
        !CYCLE_CHECK(grant_package(
            c->objects[i], c->s.lease,
            i == 1 ? 0x001201ff : FILE_GENERIC_READ | FILE_GENERIC_EXECUTE,
            FALSE)) ||
        !CYCLE_CHECK(cycle_prepared_equal(c->objects[i], o)))
      goto done;
    if (scenario == i + 2)
      cycle_crash(i == 0   ? "concession-root-before-ACK"
                  : i == 1 ? "concession-dest-before-ACK"
                           : "concession-exe-before-ACK");
    if (!CYCLE_CHECK(cycle_append(c, CY_PREPARE_ACK, i, NULL, 0)))
      goto done;
  }
  if (scenario == 8 || scenario == 9 || scenario == 10 || scenario == 14)
    cycle_crash("profile-prepared-no-tree");
  WCHAR command[CAP * 3], dest[CAP], windows[CAP], environment[CAP * 4];
  if (!CYCLE_CHECK(fmt(dest, CAP, L"%ls\\dest", c->path)) ||
      !CYCLE_CHECK(bounded_text(GetWindowsDirectoryW(windows, CAP), CAP,
                                "GetWindowsDirectoryW")) ||
      !CYCLE_CHECK(fmt(command, CAP * 3,
                       L"\"%ls\" cycle-child \"%ls\" \"%ls\" %ls", c->s.child,
                       dest, c->s.child, c->m.moniker)))
    goto done;
  int count =
      _snwprintf(environment, CAP * 4,
                 L"SystemRoot=%ls%cTEMP=%ls%cTMP=%ls%cLOCALAPPDATA=%ls%c%c",
                 windows, 0, dest, 0, dest, 0, c->profile_path, 0, 0);
  printf("CYCLE_ENVIRONMENT_SIZE expected=1..%u obtained=%d\n", CAP * 4 - 1,
         count);
  if (!CYCLE_CHECK(count > 0 && count < CAP * 4) ||
      !CYCLE_CHECK(cycle_append(c, CY_SPAWN_INTENT, 0, NULL, 0)))
    goto done;
  sec5_request request = {0};
  sec5_result launched = {0};
  request.executable = c->s.child;
  request.executable_pin = c->objects[2];
  request.command_line = command;
  request.cwd = dest;
  request.environment = environment;
  request.lease_sid = c->s.lease;
  request.backend = SEC5_APPCONTAINER;
  request.recovery_job = c->job;
  request.observe_suspended = observe_token;
  request.observer_context = &c->s;
  /* Lifecycle needs the durable context; token observer uses its suite first
   * field. */
  request.observer_context = c;
  request.lifecycle = cycle_lifecycle;
  if (!sec5_launch_fixture(&request, &launched)) {
    api_error("CYCLE launch", launched.error);
    SetLastError(launched.error ? launched.error : ERROR_GEN_FAILURE);
    close_handle(&launched.pi.hThread);
    close_handle(&launched.pi.hProcess);
    goto done;
  }
  close_handle(&launched.pi.hThread);
  BOOL markers = cycle_markers(c);
  DWORD marker_error = markers ? ERROR_SUCCESS : GetLastError();
  if (!markers) {
    DWORD child_exit = STILL_ACTIVE;
    BOOL queried = GetExitCodeProcess(launched.pi.hProcess, &child_exit);
    printf("CYCLE_MARKER_CHILD api=GetExitCodeProcess path=%ls queried=%d "
           "exit=%lu win32=%lu\n",
           c->s.child, queried, child_exit,
           queried ? ERROR_SUCCESS : GetLastError());
  }
  close_handle(&launched.pi.hProcess);
  if (!markers) {
    SetLastError(marker_error);
    goto done;
  }
  if (scenario == 6 || scenario == 12)
    cycle_crash("live-tree-child-and-grandchild");
  if (scenario == 13) {
    printf("CYCLE_ACTIVE_READY fixtures=%lu consoles=%lu active=%lu "
           "certified=%d journal_lock=held\n",
           c->live_fixtures, c->live_consoles, c->live_active,
           c->live_certified);
    fflush(stdout);
    DWORD wait = WaitForSingleObject(c->stop, INFINITE);
    if (wait == WAIT_FAILED)
      cycle_api_fail("WaitForSingleObject", "active owner stop",
                     GetLastError());
    if (!CYCLE_VALUE(wait, WAIT_OBJECT_0))
      goto done;
    cycle_crash("active-order-owner-stopped");
  }
  if (!CYCLE_CHECK(cycle_close_tree(c)))
    goto done;
  if (scenario == 7)
    cycle_crash("durable-tree-closed");
  code = 0;
done:
  if (code) {
    if (!GetLastError())
      cycle_api_fail("cycle_broker", "result expected=0 obtained=1",
                     ERROR_GEN_FAILURE);
    printf("CYCLE_BROKER_FAIL win32=%lu no automatic sweep; explicit recovery "
           "only\n",
           GetLastError());
  }
  cycle_close(c);
  free(c);
  return code;
}

static int cycle_inspect(DWORD scenario) {
  cycle_state *c = calloc(1, sizeof(*c));
  if (!c)
    return 1;
  BOOL good = CYCLE_CHECK(cycle_load(c, scenario, FALSE));
  if (good && scenario == 13 && !c->closed) {
    c->job = OpenJobObjectW(JOB_OBJECT_QUERY | READ_CONTROL, FALSE, c->m.job);
    good = CYCLE_CHECK(c->job) && CYCLE_CHECK(cycle_witness_alive(c)) &&
           CYCLE_CHECK(cycle_job_valid(c, c->job)) &&
           CYCLE_CHECK(cycle_markers(c));
    printf("CYCLE_ACTIVE_INSPECT fixtures=%lu consoles=%lu active=%lu "
           "certified=%d unchanged_live_tree=%d\n",
           c->live_fixtures, c->live_consoles, c->live_active,
           c->live_certified, good);
  }
  BYTE hashes[CYCLE_OBJECTS + 2][32] = {{0}};
  for (DWORD i = 0; good && i < CYCLE_OBJECTS; ++i) {
    BYTE sd[CYCLE_SD_MAX];
    DWORD length = 0;
    good = CYCLE_CHECK(cycle_sd(c->objects[i], sd, &length)) &&
           CYCLE_CHECK(cycle_hash(sd, length, hashes[i]));
  }
  BOOL absent = good && cycle_storage_absent(c);
  if (good) {
    good = CYCLE_CHECK(
        hash_file_digest(c->objects[2], "R3 private executable", hashes[3]));
    struct {
      BOOL absent;
      FILE_ID_INFO id;
      FILETIME birth;
    } profile = {0};
    profile.absent = absent;
    if (!absent) {
      HANDLE h = cycle_open(c->profile_path, TRUE, 0);
      good = good && CYCLE_CHECK(h != INVALID_HANDLE_VALUE) &&
             CYCLE_CHECK(cycle_identity(h, &profile.id, &profile.birth));
      close_handle(&h);
    }
    good =
        good && CYCLE_CHECK(cycle_hash(&profile, sizeof(profile), hashes[4]));
  }
  if (good) {
    BYTE control[CYCLE_SD_MAX], control_hash[32] = {0}, digest[32];
    DWORD length = 0;
    BYTE all_hashes[sizeof(hashes) + 32];
    good = CYCLE_CHECK(cycle_sd(c->control, control, &length)) &&
           CYCLE_CHECK(cycle_hash(control, length, control_hash));
    memcpy(all_hashes, hashes, sizeof(hashes));
    memcpy(all_hashes + sizeof(hashes), control_hash, 32);
    good =
        good && CYCLE_CHECK(cycle_hash(all_hashes, sizeof(all_hashes), digest));
    printf("CYCLE_FINGERPRINT scenario=%ls SHA256=", cycle_names[scenario]);
    for (DWORD i = 0; i < 32; ++i)
      printf("%02x", digest[i]);
    printf(" profile_absent=%d final=%d identities=3/3\n", absent, c->final);
  }
  cycle_close(c);
  free(c);
  return good ? 0 : 1;
}
static BOOL cycle_seed_load(cycle_state *c, DWORD scenario, BOOL lock) {
  /* Diagnostic witness only. This seed never authorizes normal recovery. */
  BOOL good = cycle_paths(c, scenario) && cycle_user(c);
  if (good) {
    c->root = cycle_open(c->path, TRUE, WRITE_DAC | WRITE_OWNER);
    good = c->root != INVALID_HANDLE_VALUE;
  }
  if (good) {
    c->control = cycle_relative(c->root, L"control", TRUE, 0);
    good =
        c->control != INVALID_HANDLE_VALUE && cycle_owned(c, c->control, TRUE);
  }
  if (good) {
    c->catalog =
        cycle_relative(c->control, L"catalog.bin", FALSE, FILE_WRITE_DATA);
    c->journal =
        cycle_relative(c->control, L"journal.bin", FALSE, FILE_WRITE_DATA);
    good = c->catalog != INVALID_HANDLE_VALUE &&
           c->journal != INVALID_HANDLE_VALUE &&
           cycle_owned(c, c->catalog, FALSE) &&
           cycle_owned(c, c->journal, FALSE) && (!lock || cycle_lock(c));
  }
  HANDLE seed = good ? cycle_relative(c->control, L"seed.bin", FALSE, 0)
                     : INVALID_HANDLE_VALUE;
  cycle_catalog cat = {0};
  BYTE hash[32], digest[32];
  if (good)
    good = seed != INVALID_HANDLE_VALUE && cycle_owned(c, seed, FALSE) &&
           cycle_read(seed, &c->m, sizeof(c->m)) &&
           cycle_seek(c->catalog, 1, FILE_BEGIN) &&
           cycle_read(c->catalog, &cat, sizeof(cat));
  close_handle(&seed);
  if (good) {
    memcpy(digest, cat.digest, 32);
    memset(cat.digest, 0, 32);
    good = cat.version == CYCLE_VERSION && cat.length == sizeof(cat) &&
           cycle_hash(&cat, sizeof(cat), hash) && !memcmp(hash, digest, 32) &&
           cycle_hash(&c->m, sizeof(c->m), hash) &&
           !memcmp(hash, cat.manifest_hash, 32) && c->m.scenario == scenario &&
           !wcscmp(c->m.owner, c->s.user_text) &&
           cycle_same(c->root, &c->m.objects[0].id, &c->m.objects[0].birth) &&
           cycle_same(c->control, &c->m.control_id, &c->m.control_birth) &&
           cycle_same(c->journal, &c->m.journal_id, &c->m.journal_birth);
    good =
        good && cycle_same(c->catalog, &c->m.catalog_id, &c->m.catalog_birth);
  }
  return good;
}
static int cycle_witness(DWORD scenario) {
  cycle_state *c = calloc(1, sizeof(*c));
  if (!c)
    return 1;
  BOOL good = cycle_seed_load(c, scenario, FALSE);
  const WCHAR *names[] = {L"",
                          L"dest",
                          L"sec5-child.exe",
                          L"control",
                          L"journal.bin",
                          L"seed.bin",
                          L"dest.original"};
  BYTE hashes[9][32] = {{0}};
  for (DWORD i = 0; good && i < 7; ++i) {
    BOOL directory = i == 0 || i == 1 || i == 3 || i == 6;
    HANDLE h = i == 0 ? c->root
                      : cycle_relative(i == 4 || i == 5 ? c->control : c->root,
                                       names[i], directory, 0);
    if (i == 6 && h == INVALID_HANDLE_VALUE &&
        GetLastError() == ERROR_FILE_NOT_FOUND)
      continue;
    struct {
      FILE_ID_INFO id;
      FILETIME birth;
      DWORD attributes, length;
      BYTE sd[CYCLE_SD_MAX], contents[32];
    } item = {0};
    BY_HANDLE_FILE_INFORMATION info;
    good = h != INVALID_HANDLE_VALUE &&
           cycle_identity(h, &item.id, &item.birth) &&
           GetFileInformationByHandle(h, &info) &&
           cycle_sd(h, item.sd, &item.length);
    if (good)
      item.attributes = info.dwFileAttributes;
    if (good && !directory)
      good = hash_file_digest(h, "R3 raw witness", item.contents);
    if (good)
      good = cycle_hash(&item, sizeof(item), hashes[i]);
    if (i)
      close_handle(&h);
  }
  cycle_catalog cat;
  if (good)
    good = cycle_seek(c->catalog, 1, FILE_BEGIN) &&
           cycle_read(c->catalog, &cat, sizeof(cat)) &&
           cycle_hash(&cat, sizeof(cat), hashes[7]);
  LPWSTR profile = NULL;
  struct {
    BOOL absent;
    FILE_ID_INFO id;
    FILETIME birth;
    DWORD length;
    BYTE sd[CYCLE_SD_MAX];
  } storage = {0};
  if (good)
    good = SUCCEEDED(GetAppContainerFolderPath(c->m.sid, &profile)) && profile;
  if (good) {
    storage.absent = storage_absent(profile);
    if (!storage.absent) {
      HANDLE h = cycle_open(profile, TRUE, 0);
      good = h != INVALID_HANDLE_VALUE &&
             cycle_identity(h, &storage.id, &storage.birth) &&
             cycle_sd(h, storage.sd, &storage.length);
      close_handle(&h);
    }
    good = good && cycle_hash(&storage, sizeof(storage), hashes[8]);
  }
  if (profile)
    CoTaskMemFree(profile);
  if (good) {
    BYTE digest[32];
    good = cycle_hash(hashes, sizeof(hashes), digest);
    if (good) {
      printf("CYCLE_WITNESS scenario=%ls SHA256=", cycle_names[scenario]);
      for (DWORD i = 0; i < 32; ++i)
        printf("%02x", digest[i]);
      printf(" objects=identity+birth+attributes+SD+bytes "
             "control+journal+catalog=1 profile_absent=%d\n",
             storage.absent);
    }
  }
  cycle_close(c);
  free(c);
  return good ? 0 : 1;
}
typedef struct cycle_foreign_record {
  DWORD version;
  WCHAR moniker[64], sid[256], owner[256];
  FILE_ID_INFO id;
  FILETIME birth;
  BYTE digest[32];
} cycle_foreign_record;
static int cycle_foreign(DWORD scenario, BOOL create, BOOL remove) {
  if (scenario != 14)
    return 2;
  cycle_state *c = calloc(1, sizeof(*c));
  if (!c)
    return 1;
  BOOL good = CYCLE_CHECK(cycle_load(c, scenario, TRUE));
  cycle_foreign_record record = {0};
  HANDLE file = INVALID_HANDLE_VALUE;
  LPWSTR path = NULL;
  PSID sid = NULL;
  if (good && create) {
    DWORD random[4];
    record.version = CYCLE_VERSION;
    good = CYCLE_CHECK(random_bytes(random, sizeof(random))) &&
           CYCLE_CHECK(fmt(record.moniker, 64,
                           L"DevAgents.Sec5.%08lx%08lx%08lx%08lx", random[0],
                           random[1], random[2], random[3])) &&
           CYCLE_CHECK(fmt(record.owner, 256, L"%ls", c->s.user_text)) &&
           CYCLE_CHECK(SUCCEEDED(DeriveAppContainerSidFromAppContainerName(
               record.moniker, &sid)));
    LPWSTR text = NULL;
    good = good && CYCLE_CHECK(ConvertSidToStringSidW(sid, &text)) &&
           CYCLE_CHECK(fmt(record.sid, 256, L"%ls", text));
    if (text)
      LocalFree(text);
    good = good &&
           CYCLE_CHECK(cycle_hash(&record, sizeof(record), record.digest)) &&
           CYCLE_CHECK(cycle_create_file(c, L"foreign.bin", &record,
                                         sizeof(record), &file));
    PSID actual = NULL;
    ULONGLONG before = GetTickCount64();
    HRESULT hr =
        good ? CreateAppContainerProfile(
                   record.moniker, record.moniker,
                   L"SEC5 R3 foreign fixture; excluded from lease journal",
                   NULL, 0, &actual)
             : E_FAIL;
    printf("FOREIGN_CREATE HRESULT=0x%08lx latency_ms=%llu "
           "outside_lease_journal=1\n",
           (unsigned long)hr, GetTickCount64() - before);
    good =
        good && CYCLE_CHECK(SUCCEEDED(hr)) &&
        CYCLE_CHECK(EqualSid(actual, sid)) &&
        CYCLE_CHECK(SUCCEEDED(GetAppContainerFolderPath(record.sid, &path))) &&
        CYCLE_CHECK(path);
    if (actual)
      FreeSid(actual);
    HANDLE storage = good ? cycle_open(path, TRUE, 0) : INVALID_HANDLE_VALUE;
    good = good && CYCLE_CHECK(storage != INVALID_HANDLE_VALUE) &&
           CYCLE_CHECK(cycle_identity(storage, &record.id, &record.birth));
    close_handle(&storage);
    memset(record.digest, 0, sizeof(record.digest));
    good = good &&
           CYCLE_CHECK(cycle_hash(&record, sizeof(record), record.digest)) &&
           CYCLE_CHECK(cycle_seek(file, 0, FILE_BEGIN)) &&
           CYCLE_CHECK(write_all(file, &record, sizeof(record))) &&
           CYCLE_CHECK(FlushFileBuffers(file));
  } else if (good) {
    file = cycle_relative(c->control, L"foreign.bin", FALSE, 0);
    LARGE_INTEGER size;
    BYTE digest[32], hash[32];
    good = CYCLE_CHECK(file != INVALID_HANDLE_VALUE) &&
           CYCLE_CHECK(cycle_owned(c, file, FALSE)) &&
           CYCLE_CHECK(GetFileSizeEx(file, &size)) &&
           CYCLE_CHECK(size.QuadPart == sizeof(record)) &&
           CYCLE_CHECK(cycle_read(file, &record, sizeof(record)));
    if (good) {
      memcpy(digest, record.digest, 32);
      memset(record.digest, 0, 32);
      good = CYCLE_CHECK(record.version == CYCLE_VERSION) &&
             CYCLE_CHECK(record.moniker[63] == 0) &&
             CYCLE_CHECK(record.sid[255] == 0) &&
             CYCLE_CHECK(record.owner[255] == 0) &&
             CYCLE_CHECK(!wcscmp(record.owner, c->s.user_text)) &&
             CYCLE_CHECK(wcscmp(record.moniker, c->m.moniker)) &&
             CYCLE_CHECK(cycle_hash(&record, sizeof(record), hash)) &&
             CYCLE_CHECK(!memcmp(hash, digest, 32)) &&
             CYCLE_CHECK(SUCCEEDED(DeriveAppContainerSidFromAppContainerName(
                 record.moniker, &sid)));
      LPWSTR text = NULL;
      good = good && CYCLE_CHECK(ConvertSidToStringSidW(sid, &text)) &&
             CYCLE_CHECK(!wcscmp(text, record.sid));
      if (text)
        LocalFree(text);
      good = good &&
             CYCLE_CHECK(
                 SUCCEEDED(GetAppContainerFolderPath(record.sid, &path))) &&
             CYCLE_CHECK(!storage_absent(path));
      HANDLE storage = good ? cycle_open(path, TRUE, 0) : INVALID_HANDLE_VALUE;
      good = good && CYCLE_CHECK(storage != INVALID_HANDLE_VALUE) &&
             CYCLE_CHECK(cycle_same(storage, &record.id, &record.birth));
      BYTE sd[CYCLE_SD_MAX];
      DWORD length = 0;
      good = good && CYCLE_CHECK(cycle_sd(storage, sd, &length)) &&
             CYCLE_CHECK(cycle_hash(sd, length, hash));
      if (good) {
        printf("FOREIGN_WITNESS SHA256=");
        for (DWORD i = 0; i < 32; ++i)
          printf("%02x", hash[i]);
        printf(" profile_identity=1 present=1 outside_lease_journal=1\n");
      }
      close_handle(&storage);
      if (good && remove) {
        ULONGLONG before = GetTickCount64();
        HRESULT hr = cycle_delete_profile(record.moniker);
        good = CYCLE_CHECK(SUCCEEDED(hr)) && CYCLE_CHECK(storage_absent(path));
        printf("FOREIGN_DELETE_EXPLICIT HRESULT=0x%08lx latency_ms=%llu "
               "storage_absent=%d\n",
               (unsigned long)hr, GetTickCount64() - before, good);
      }
    }
  }
  printf("FOREIGN_FIXTURE success=%d action=%s\n", good,
         create   ? "create"
         : remove ? "explicit-owner-delete"
                  : "inspect");
  close_handle(&file);
  if (path)
    CoTaskMemFree(path);
  if (sid)
    FreeSid(sid);
  cycle_close(c);
  free(c);
  return good ? 0 : 1;
}
static int cycle_tamper(DWORD scenario, BOOL repair) {
  /* Test-only mutations; exact named fixtures, original bytes retained. Normal
     recovery never invokes this path or accepts a diagnostic seed as intent. */
  cycle_state *c = calloc(1, sizeof(*c));
  if (!c)
    return 1;
  BOOL good = cycle_seed_load(c, scenario, TRUE);
  if (good && scenario == 9) {
    /* Flip one digest byte in the last record; the same action restores bytes.
       Keep the corrupt output/hash in evidence; never truncate the journal. */
    LARGE_INTEGER size;
    BYTE byte;
    good = GetFileSizeEx(c->journal, &size) &&
           size.QuadPart > (LONGLONG)sizeof(cycle_record) &&
           cycle_seek(c->journal, -1, FILE_END) &&
           cycle_read(c->journal, &byte, 1);
    if (good) {
      byte ^= 0x80;
      good = cycle_seek(c->journal, -1, FILE_END) &&
             write_all(c->journal, &byte, 1) && FlushFileBuffers(c->journal);
    }
  } else if (good && scenario == 10) {
    WCHAR old[CAP], saved[CAP];
    good = fmt(old, CAP, L"%ls\\dest", c->path) &&
           fmt(saved, CAP, L"%ls\\dest.original", c->path);
    if (good && !repair) {
      good = MoveFileExW(old, saved, 0);
      HANDLE replacement = NULL;
      if (good)
        good = cycle_directory(c, old, 0, &replacement);
      close_handle(&replacement);
    } else if (good) {
      HANDLE replacement = cycle_relative(c->root, L"dest", TRUE, DELETE);
      FILE_ID_INFO id;
      FILETIME birth;
      good =
          replacement != INVALID_HANDLE_VALUE &&
          cycle_identity(replacement, &id, &birth) &&
          memcmp(&id.FileId, &c->m.objects[1].id.FileId, sizeof(id.FileId)) &&
          dispose_file(replacement, &id);
      close_handle(&replacement);
      if (good)
        good = MoveFileExW(saved, old, 0);
    }
  } else if (good && scenario == 11 && repair) {
    LARGE_INTEGER size;
    cycle_manifest original = c->m;
    good = GetFileSizeEx(c->journal, &size) && size.QuadPart == 0 &&
           cycle_named_objects(c) &&
           !memcmp(&original, &c->m, sizeof(original)) &&
           cycle_append(c, CY_PROFILE_INTENT, 0, &c->m, sizeof(c->m)) &&
           cycle_holder_start(c) && cycle_close_tree(c);
    printf("TEST_REPAIR_NO_INTENT fixture=never-spawned explicit-rescue=1 "
           "normal-recovery-rejected=1\n");
  } else if (good && scenario == 12 && repair) {
    good = cycle_parse(c) && cycle_append(c, CY_MUTATION_REPAIRED, 0, NULL, 0);
  } else
    good = FALSE;
  printf("CYCLE_TEST_%s scenario=%ls success=%d\n",
         repair ? "REPAIR" : "TAMPER", cycle_names[scenario], good);
  cycle_close(c);
  free(c);
  return good ? 0 : 1;
}
static int cycle_release_active(DWORD scenario) {
  if (scenario != 13)
    return 2;
  cycle_state *c = calloc(1, sizeof(*c));
  if (!c)
    return 1;
  BOOL good = cycle_load(c, scenario, FALSE) && cycle_signal(c, c->m.stop);
  cycle_close(c);
  free(c);
  return good ? 0 : 1;
}
static int cycle_dispatch(int argc, WCHAR **argv, BOOL recovery_only) {
  DWORD scenario;
  if (argc < 3 || !cycle_scenario(argv[2], &scenario))
    return 2;
  if (!wcscmp(argv[1], L"cycle-recover") && argc == 3)
    return cycle_recover(scenario);
  if (recovery_only)
    return 2;
  if (!wcscmp(argv[1], L"cycle-broker") && argc == 4)
    return cycle_broker(scenario, argv[3]);
  if (!wcscmp(argv[1], L"cycle-hold") && argc == 3)
    return cycle_holder(scenario);
  if (!wcscmp(argv[1], L"cycle-inspect") && argc == 3)
    return cycle_inspect(scenario);
  if (!wcscmp(argv[1], L"cycle-witness") && argc == 3)
    return cycle_witness(scenario);
  if (!wcscmp(argv[1], L"cycle-foreign-start") && argc == 3)
    return cycle_foreign(scenario, TRUE, FALSE);
  if (!wcscmp(argv[1], L"cycle-foreign-inspect") && argc == 3)
    return cycle_foreign(scenario, FALSE, FALSE);
  if (!wcscmp(argv[1], L"cycle-foreign-finish") && argc == 3)
    return cycle_foreign(scenario, FALSE, TRUE);
  if (!wcscmp(argv[1], L"cycle-tamper") && argc == 3)
    return cycle_tamper(scenario, FALSE);
  if (!wcscmp(argv[1], L"cycle-repair") && argc == 3)
    return cycle_tamper(scenario, TRUE);
  if (!wcscmp(argv[1], L"cycle-release") && argc == 3)
    return cycle_release_active(scenario);
  return 2;
}
int sec5_recover_main(void) {
  int argc = 0;
  WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  int code = argv ? cycle_dispatch(argc, argv, TRUE) : 2;
  if (argv)
    LocalFree(argv);
  return code;
}
