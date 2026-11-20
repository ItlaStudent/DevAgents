/* R2 private fixture implementation, included in sec5_fixture.c. No product
   imports. ACLs are changed only in the fixed, operator-prepared copy tree. */
typedef BOOL(WINAPI *runtime_derive_fn)(LPCWSTR, PSID **, DWORD *, PSID **,
                                        DWORD *);
typedef struct runtime_object {
  snapshot before, granted;
  WCHAR *path;
  BYTE digest[32];
  BOOL directory;
  struct runtime_object *next;
} runtime_object;
typedef struct runtime_tree {
  runtime_object *objects;
  HANDLE guards[128];
  unsigned guard_count, object_count;
  WCHAR base[CAP], roots[2][CAP], executables[2][CAP], witnesses[2][CAP];
} runtime_tree;

static void child_runtime_exec(packet *reply, const WCHAR *exe, BOOL python) {
  WCHAR command[CAP * 2];
  BOOL formatted =
      python
          ? fmt(command, CAP * 2,
                L"\"%ls\" -I -B -c \"import pathlib,json,sqlite3,sys; "
                L"exec(pathlib.Path(sys.executable).with_name('sec5_runtime.py'"
                L").read_text())\"",
                exe)
          : fmt(command, CAP * 2,
                L"\"%ls\" -e \"const "
                L"f=require('fs'),p=require('path');eval(f.readFileSync(p.join("
                L"p.dirname(process.execPath),'sec5_runtime.js'),'utf8'))\"",
                exe);
  STARTUPINFOW si = {0};
  PROCESS_INFORMATION pi = {0};
  si.cb = sizeof(si);
  BOOL created =
      formatted &&
      CreateProcessW(exe, command, NULL, NULL, FALSE,
                     CREATE_NO_WINDOW | CREATE_SUSPENDED, NULL, NULL, &si, &pi);
  reply->opened = created;
  reply->error = created ? 0 : GetLastError();
  if (created) {
    BOOL resumed = ResumeThread(pi.hThread) == 1;
    DWORD waited =
        resumed ? WaitForSingleObject(pi.hProcess, WAIT_MS) : WAIT_FAILED;
    DWORD code = STILL_ACTIVE;
    if (waited != WAIT_OBJECT_0) {
      reply->error = waited == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError();
      if (!TerminateProcess(pi.hProcess, 124) ||
          WaitForSingleObject(pi.hProcess, WAIT_MS) != WAIT_OBJECT_0)
        reply->error = ERROR_PROCESS_ABORTED;
    }
    if (!GetExitCodeProcess(pi.hProcess, &code))
      reply->error = GetLastError();
    reply->secondary_error = code;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
}

static BOOL runtime_capability(suite *s) {
  HMODULE library =
      LoadLibraryExW(L"kernelbase.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
  runtime_derive_fn derive = library
                                 ? (runtime_derive_fn)GetProcAddress(
                                       library, "DeriveCapabilitySidsFromName")
                                 : NULL;
  PSID *groups = NULL, *caps = NULL;
  DWORD group_count = 0, cap_count = 0;
  BOOL good =
      derive &&
      derive(L"devAgentsRuntime", &groups, &group_count, &caps, &cap_count) &&
      cap_count == 1;
  if (good) {
    DWORD size = GetLengthSid(caps[0]);
    s->runtime_capability = LocalAlloc(LMEM_FIXED, size);
    good =
        s->runtime_capability && CopySid(size, s->runtime_capability, caps[0]);
  }
  LPWSTR text = NULL;
  if (good && ConvertSidToStringSidW(s->runtime_capability, &text)) {
    printf("RUNTIME_CAPABILITY name=devAgentsRuntime SID=%ls count=1 "
           "data_IPC_grants=0\n",
           text);
    LocalFree(text);
  } else
    good = FALSE;
  for (DWORD i = 0; i < group_count; ++i)
    LocalFree(groups[i]);
  for (DWORD i = 0; i < cap_count; ++i)
    LocalFree(caps[i]);
  if (groups)
    LocalFree(groups);
  if (caps)
    LocalFree(caps);
  if (library)
    FreeLibrary(library);
  return good;
}

static BOOL runtime_guard(runtime_tree *tree) {
  WCHAR cwd[CAP], part[CAP], final[CAP], expected[CAP];
  if (!GetCurrentDirectoryW(CAP, cwd) ||
      !fmt(tree->base, CAP, L"%ls\\.sec5-r2-runtimes-20261013", cwd))
    return FALSE;
  size_t length = wcslen(tree->base);
  for (size_t i = 3; i <= length; ++i) {
    if (i != 3 && i != length && tree->base[i] != L'\\')
      continue;
    if (tree->guard_count == 128)
      return FALSE;
    memcpy(part, tree->base, i * sizeof(WCHAR));
    part[i] = 0;
    HANDLE h = CreateFileW(
        part, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (h == INVALID_HANDLE_VALUE)
      return FALSE;
    tree->guards[tree->guard_count++] = h;
    BY_HANDLE_FILE_INFORMATION info;
    DWORD n = GetFinalPathNameByHandleW(h, final, CAP,
                                        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!GetFileInformationByHandle(h, &info) ||
        !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) || !n ||
        n >= CAP || !fmt(expected, CAP, L"\\\\?\\%ls", part) ||
        _wcsicmp(final, expected))
      return FALSE;
  }
  return TRUE;
}

static BOOL runtime_private_acl(suite *s, PSECURITY_DESCRIPTOR sd) {
  PACL acl = NULL;
  BOOL present = FALSE, def = FALSE;
  PSID owner_rights = NULL, system = NULL, admins = NULL;
  BOOL good = GetSecurityDescriptorDacl(sd, &present, &acl, &def) && present &&
              acl && ConvertStringSidToSidW(L"S-1-3-4", &owner_rights) &&
              ConvertStringSidToSidW(L"S-1-5-18", &system) &&
              ConvertStringSidToSidW(L"S-1-5-32-544", &admins);
  for (DWORD i = 0; good && i < acl->AceCount; ++i) {
    ACCESS_ALLOWED_ACE *ace = NULL;
    good = GetAce(acl, i, (void **)&ace) &&
           ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE;
    if (good) {
      PSID sid = &ace->SidStart;
      good = EqualSid(sid, s->user) || EqualSid(sid, owner_rights) ||
             EqualSid(sid, system) || EqualSid(sid, admins);
    }
  }
  if (owner_rights)
    LocalFree(owner_rights);
  if (system)
    LocalFree(system);
  if (admins)
    LocalFree(admins);
  return good;
}

static BOOL runtime_capture(suite *s, runtime_tree *tree, const WCHAR *path) {
  if (tree->object_count >= 65536)
    return FALSE;
  HANDLE h = CreateFileW(
      path, GENERIC_READ | WRITE_DAC, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      NULL);
  if (h == INVALID_HANDLE_VALUE)
    return FALSE;
  BY_HANDLE_FILE_INFORMATION info;
  WCHAR final[CAP], expected[CAP];
  DWORD n = GetFinalPathNameByHandleW(h, final, CAP,
                                      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  BOOL physical = GetFileInformationByHandle(h, &info) &&
                  !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
                  ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
                   info.nNumberOfLinks == 1) &&
                  n && n < CAP && fmt(expected, CAP, L"\\\\?\\%ls", path) &&
                  !_wcsicmp(final, expected) &&
                  !_wcsnicmp(path, tree->base, wcslen(tree->base)) &&
                  path[wcslen(tree->base)] == L'\\';
  runtime_object *e = physical ? calloc(1, sizeof(*e)) : NULL;
  if (!e) {
    CloseHandle(h);
    return FALSE;
  }
  e->path = _wcsdup(path);
  e->directory = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  e->next = tree->objects;
  tree->objects = e;
  ++tree->object_count;
  printf("RUNTIME_INVENTORY path=%ls handle=%p directory=%d links=%lu\n", path,
         h, e->directory, (unsigned long)info.nNumberOfLinks);
  if (!e->path || !snapshot_take(&e->before, h, SE_FILE_OBJECT, TRUE) ||
      !runtime_private_acl(s, e->before.sd)) {
    if (!e->before.handle)
      e->before.handle = h;
    return FALSE;
  }
  if (!e->directory)
    return hash_file_digest(h, "runtime-before", e->digest);
  WCHAR pattern[CAP];
  if (!fmt(pattern, CAP, L"%ls\\*", path))
    return FALSE;
  WIN32_FIND_DATAW data;
  HANDLE find = FindFirstFileW(pattern, &data);
  if (find == INVALID_HANDLE_VALUE)
    return GetLastError() == ERROR_FILE_NOT_FOUND;
  BOOL good = TRUE;
  do {
    if (!wcscmp(data.cFileName, L".") || !wcscmp(data.cFileName, L".."))
      continue;
    WCHAR child[CAP];
    good = fmt(child, CAP, L"%ls\\%ls", path, data.cFileName) &&
           runtime_capture(s, tree, child);
    if (!good)
      break;
  } while (FindNextFileW(find, &data));
  if (good && GetLastError() != ERROR_NO_MORE_FILES)
    good = FALSE;
  if (!FindClose(find))
    good = FALSE;
  return good;
}

static BOOL runtime_grant(runtime_tree *tree, PSID sid, BOOL writable) {
  DWORD rights = FILE_GENERIC_READ | FILE_GENERIC_EXECUTE |
                 (writable ? FILE_GENERIC_WRITE : 0);
  BOOL good = TRUE;
  for (runtime_object *e = tree->objects; e; e = e->next) {
    /* No inheritable ACE: every inventoried object, including protected
       children, receives exactly one RX grant. Preserve controls, label and
       ownership. */
    if (!grant_package(e->before.handle, sid, rights, FALSE) ||
        !snapshot_take(&e->granted, e->before.handle, SE_FILE_OBJECT, TRUE)) {
      api_error("runtime grant/readback", GetLastError());
      good = FALSE;
      break;
    }
    printf("RUNTIME_GRANT path=%ls rights=0x%08lx same_object=1\n", e->path,
           (unsigned long)rights);
  }
  return good;
}

static BOOL runtime_unchanged(runtime_tree *tree, BOOL original) {
  BOOL good = TRUE;
  for (runtime_object *e = tree->objects; e; e = e->next) {
    BYTE digest[32];
    const snapshot *reference = original ? &e->before : &e->granted;
    PSECURITY_DESCRIPTOR actual = NULL;
    SECURITY_DESCRIPTOR_CONTROL old_control = 0, new_control = 0;
    DWORD revision = 0;
    BOOL equal =
        reference->sd && snapshot_equal(reference) &&
        kernel_sd(reference->handle, SD_INFO, &actual) &&
        GetSecurityDescriptorControl(reference->sd, &old_control, &revision) &&
        GetSecurityDescriptorControl(actual, &new_control, &revision) &&
        old_control == new_control;
    printf("RUNTIME_CONTROL path=%ls before=0x%04x after=0x%04x equal=%d\n",
           e->path, old_control, new_control, equal);
    if (actual)
      LocalFree(actual);
    if (!e->directory) {
      printf("RUNTIME_HASH_AFTER path=%ls\n", e->path);
      equal = hash_file_digest(e->before.handle, "runtime-after", digest) &&
              !memcmp(digest, e->digest, sizeof(digest)) && equal;
    }
    printf("RUNTIME_INTACT path=%ls original=%d identity_SD_control_hash=%d\n",
           e->path, original, equal);
    good = equal && good;
  }
  return good;
}

static BOOL runtime_restore(runtime_tree *tree) {
  BOOL good = TRUE;
  for (runtime_object *e = tree->objects; e; e = e->next) {
    if (!e->before.sd) {
      good = FALSE;
      continue;
    }
    PACL acl = NULL;
    BOOL present = FALSE, def = FALSE;
    SECURITY_DESCRIPTOR_CONTROL control;
    DWORD revision;
    BOOL restored =
        identity_matches(e->before.handle, &e->before.identity, NULL) &&
        GetSecurityDescriptorDacl(e->before.sd, &present, &acl, &def) &&
        present && acl &&
        GetSecurityDescriptorControl(e->before.sd, &control, &revision) &&
        set_dacl(e->before.handle, acl, def, control) &&
        snapshot_equal(&e->before);
    printf("RUNTIME_RESTORE path=%ls same_object=1 SD_DACL_control_equal=%d\n",
           e->path, restored);
    good = restored && good;
  }
  return good;
}

static void runtime_dispose(runtime_tree *tree) {
  while (tree->objects) {
    runtime_object *e = tree->objects;
    tree->objects = e->next;
    if (e->granted.sd)
      LocalFree(e->granted.sd); /* Borrowed before.handle. */
    snapshot_dispose(&e->before);
    free(e->path);
    free(e);
  }
  while (tree->guard_count)
    close_handle(&tree->guards[--tree->guard_count]);
}

static BOOL runtime_read_probe(suite *s, const WCHAR *path, BOOL allowed,
                               BOOL ordinary) {
  BYTE expected[16];
  DWORD done = 0;
  HANDLE file =
      CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                  OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  BOOL known = file != INVALID_HANDLE_VALUE &&
               ReadFile(file, expected, sizeof(expected), &done, NULL) &&
               done == sizeof(expected);
  if (file != INVALID_HANDLE_VALUE)
    CloseHandle(file);
  run r = {0};
  BOOL tried = known && probe(s, &r, ordinary, OP_READ, path, 0, 0);
  BOOL effect = allowed
                    ? (r.reply.opened && !r.reply.error &&
                       !memcmp(expected, r.reply.read_bytes, sizeof(expected)))
                    : (!r.reply.opened && r.reply.error == ERROR_ACCESS_DENIED);
  BOOL ended = r.complete && release_run(&r);
  BOOL cleaned = dispose_run(&r);
  printf(
      "RUNTIME_READ path=%ls ordinary=%d capability=%d attempted=%d opened=%lu "
      "error=%lu expected_allowed=%d bytes_or_denial=%d cleanup=%d\n",
      path, ordinary, s->active_capability != NULL, tried,
      (unsigned long)r.reply.opened, (unsigned long)r.reply.error, allowed,
      effect, cleaned);
  return tried && effect && ended && cleaned;
}

static BOOL runtime_output(run *r, const char *expected, const WCHAR *exe,
                           BOOL python) {
  BYTE output[4096];
  BYTE errors[CAP * 4];
  DWORD used = 0, error_used = 0;
  ULONGLONG deadline = GetTickCount64() + WAIT_MS;
  BOOL eof = FALSE, error_eof = FALSE, exited = FALSE, good = TRUE;
  DWORD code = STILL_ACTIVE;
  while (good && GetTickCount64() < deadline && !(eof && error_eof && exited)) {
    DWORD available = 0;
    if (!PeekNamedPipe(r->out_read, NULL, 0, NULL, &available, NULL)) {
      if (GetLastError() == ERROR_BROKEN_PIPE)
        eof = TRUE;
      else
        good = FALSE;
    } else if (available) {
      DWORD got = 0;
      if (available > sizeof(output) - used ||
          !ReadFile(r->out_read, output + used, available, &got, NULL) ||
          got != available)
        good = FALSE;
      else
        used += got;
    }
    available = 0;
    if (!PeekNamedPipe(r->err_read, NULL, 0, NULL, &available, NULL)) {
      if (GetLastError() == ERROR_BROKEN_PIPE)
        error_eof = TRUE;
      else
        good = FALSE;
    } else if (available) {
      DWORD got = 0;
      if (available > sizeof(errors) - error_used ||
          !ReadFile(r->err_read, errors + error_used, available, &got, NULL) ||
          got != available)
        good = FALSE;
      else
        error_used += got;
    }
    exited = WaitForSingleObject(r->process.pi.hProcess, 0) == WAIT_OBJECT_0;
    Sleep(2);
  }
  good = good && eof && exited &&
         GetExitCodeProcess(r->process.pi.hProcess, &code) && code == 0 &&
         used == strlen(expected) && !memcmp(output, expected, used);
  char utf8[CAP * 4], warning[CAP * 4 + 128];
  BOOL known_warning = FALSE;
  if (python && !r->ordinary &&
      WideCharToMultiByte(CP_UTF8, 0, exe, -1, utf8, sizeof(utf8), NULL, NULL) >
          0) {
    int n = snprintf(warning, sizeof(warning),
                     "Failed to find real location of %s\n", utf8);
    known_warning = n > 0 && (size_t)n < sizeof(warning) &&
                    error_used == (DWORD)n &&
                    !memcmp(errors, warning, error_used);
  }
  BOOL stderr_valid = error_eof && (!error_used || known_warning);
  printf("RUNTIME_OUTPUT pid=%lu exit=0x%08lx bytes=%lu exact=%d stdout_EOF=%d "
         "stderr_EOF=%d stderr_bytes=%lu known_getpath_warning=%d\n",
         (unsigned long)r->process.pi.dwProcessId, (unsigned long)code,
         (unsigned long)used, good, eof, error_eof, (unsigned long)error_used,
         known_warning);
  if (used) {
    printf("RUNTIME_STDOUT=");
    fwrite(output, 1, used, stdout);
    printf("\n");
  }
  if (error_used) {
    printf("RUNTIME_STDERR=");
    fwrite(errors, 1, error_used, stdout);
    printf("\n");
  }
  if (known_warning)
    printf("PYTHON_GETPATH | OBSERVED | exact pinned-path warning; "
           "cause=CPython-3.14 getpath realpath/MountManager as measured in "
           "orq-pre-r1e-python-run-20261011.txt; no extra capability or "
           "fallback\n");
  return good && stderr_valid;
}

static BOOL runtime_execute(suite *s, const WCHAR *exe, BOOL python,
                            BOOL ordinary) {
  WCHAR args[CAP];
  char expected[128];
  BYTE nonce[16];
  if (!random_bytes(nonce, sizeof(nonce)))
    return FALSE;
  char hex[33];
  for (unsigned i = 0; i < 16; ++i)
    snprintf(hex + i * 2, 3, "%02x", nonce[i]);
  snprintf(expected, sizeof(expected),
           python ? "SEC5_RUNTIME_%s\r\n" : "SEC5_RUNTIME_%s\n", hex);
  /* Scripts live inside the inventoried RX runtime, making Node's single-file
     loader discriminating as well. Python exercises actual stdlib + SQLite DLL.
   */
  BOOL formatted =
      python
          ? fmt(args, CAP,
                L"-I -B -c \"import pathlib,json,sqlite3,sys,os; "
                L"exec(pathlib.Path(sys.executable).with_name('sec5_runtime.py'"
                L").read_text()); n=bytes.fromhex('%hs'); "
                L"pathlib.Path('python.bin').write_bytes(n); "
                L"(pathlib.Path(os.environ['TEMP'])/"
                L"'python-cache.bin').write_bytes(n); exec('try:\\n "
                L"pathlib.Path(\\'../medium/"
                L"python-out.bin\\').write_bytes(n)\\nexcept "
                L"PermissionError:\\n pass'); "
                L"sys.stdout.write('SEC5_RUNTIME_%hs\\n')\"",
                hex, hex)
          : fmt(args, CAP,
                L"-e \"const "
                L"f=require('fs'),p=require('path');eval(f.readFileSync(p.join("
                L"p.dirname(process.execPath),'sec5_runtime.js'),'utf8'));"
                L"const "
                L"n=Buffer.from('%hs','hex');f.writeFileSync('node.bin',n);f."
                L"writeFileSync(p.join(process.env.TEMP,'node-cache.bin'),n);"
                L"try{f.writeFileSync('../medium/"
                L"node-out.bin',n)}catch(e){if(e.code!=='EACCES'&&e.code!=='"
                L"EPERM')throw e}process.stdout.write('SEC5_RUNTIME_%hs\\n')\"",
                hex, hex);
  run r = {0};
  BOOL launched = formatted && launch_run(s, &r, ordinary, exe, args, FALSE);
  close_handle(&r.in_write); /* Interpreter stdin receives EOF. */
  BOOL exact = launched && runtime_output(&r, expected, exe, python);
  BOOL cleaned = dispose_run(&r);
  WCHAR marker[CAP], cache[CAP], outside[CAP];
  BOOL paths = fmt(marker, CAP, L"%ls\\%ls.bin", s->dest,
                   python ? L"python" : L"node") &&
               fmt(cache, CAP, L"%ls\\%ls-cache.bin", s->private_temp,
                   python ? L"python" : L"node") &&
               fmt(outside, CAP, L"%ls\\%ls-out.bin", s->medium,
                   python ? L"python" : L"node");
  BOOL bytes = paths && file_bytes(marker, nonce, 16, FALSE) &&
               file_bytes(cache, nonce, 16, FALSE);
  BOOL exterior_exists =
      paths && GetFileAttributesW(outside) != INVALID_FILE_ATTRIBUTES;
  BOOL exterior =
      ordinary ? (exterior_exists && file_bytes(outside, nonce, 16, FALSE))
               : !exterior_exists;
  printf("RUNTIME_INLINE runtime=%s ordinary=%d destination_nonce=%d "
         "private_cache_nonce=%d exterior_written=%d\n",
         python ? "PYTHON" : "NODE", ordinary, bytes, bytes, exterior_exists);
  if (paths) {
    const WCHAR *files[] = {marker, cache, outside};
    for (unsigned i = 0; i < 3; ++i)
      if (GetFileAttributesW(files[i]) != INVALID_FILE_ATTRIBUTES &&
          !DeleteFileW(files[i]))
        cleaned = FALSE;
  }
  return exact && cleaned && bytes && exterior;
}

static BOOL runtime_write_probe(suite *s, const WCHAR *path, BOOL create) {
  run r = {0};
  BOOL tried =
      probe(s, &r, FALSE, create ? OP_WRITE : OP_RUNTIME_WRITE, path, 0, 0);
  BOOL denied =
      tried && !r.reply.opened && r.reply.error == ERROR_ACCESS_DENIED;
  BOOL ended = r.complete && release_run(&r);
  BOOL cleaned = dispose_run(&r);
  printf("RUNTIME_WRITE path=%ls create=%d attempted=%d opened=%lu error=%lu "
         "secondary=%lu denied=%d\n",
         path, create, tried, (unsigned long)r.reply.opened,
         (unsigned long)r.reply.error, (unsigned long)r.reply.secondary_error,
         denied);
  if (create && GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES &&
      !DeleteFileW(path))
    cleaned = FALSE;
  return denied && ended && cleaned;
}

static void child_private_registry(packet *reply, const WCHAR *object,
                                   BOOL read) {
  HKEY root = NULL, key = NULL;
  if (read) {
    UNICODE_STRING name = {(USHORT)(wcslen(object) * sizeof(WCHAR)),
                           (USHORT)(wcslen(object) * sizeof(WCHAR)),
                           (PWSTR)object};
    OBJECT_ATTRIBUTES attributes;
    InitializeObjectAttributes(&attributes, &name, OBJ_CASE_INSENSITIVE, NULL,
                               NULL);
    typedef NTSTATUS(NTAPI * open_key_fn)(PHANDLE, ACCESS_MASK,
                                          POBJECT_ATTRIBUTES);
    open_key_fn open_key = (open_key_fn)GetProcAddress(
        GetModuleHandleW(L"ntdll.dll"), "NtOpenKey");
    NTSTATUS status =
        open_key ? open_key((HANDLE *)&key, KEY_QUERY_VALUE, &attributes)
                 : (NTSTATUS)0xc000007au;
    reply->opened = status >= 0;
    reply->error = status >= 0 ? 0 : RtlNtStatusToDosError(status);
  } else {
    HRESULT hr = GetAppContainerRegistryLocation(KEY_ALL_ACCESS, &root);
    reply->error = SUCCEEDED(hr) ? 0 : HRESULT_CODE(hr);
    if (SUCCEEDED(hr)) {
      DWORD disposition = 0;
      LSTATUS status =
          RegCreateKeyExW(root, object, 0, NULL, REG_OPTION_VOLATILE,
                          KEY_ALL_ACCESS, NULL, &key, &disposition);
      reply->error = (DWORD)status;
      reply->opened =
          status == ERROR_SUCCESS && disposition == REG_CREATED_NEW_KEY;
      if (reply->opened)
        reply->secondary_error = (DWORD)RegSetValueExW(
            key, L"nonce", 0, REG_BINARY, reply->nonce, sizeof(reply->nonce));
    }
  }
  if (key)
    RegCloseKey(key);
  if (root)
    RegCloseKey(root);
}

/* Controlled TCP responder protocol: C + 16 nonce bytes -> exact 16 bytes;
   Q -> uint32 little-endian connection/request count. No DNS/timeouts as PASS.
 */
static void child_network(packet *reply, const WCHAR *endpoint, unsigned mode) {
  BOOL query = mode == 1;
  char ascii[128];
  if (WideCharToMultiByte(CP_UTF8, 0, endpoint, -1, ascii, sizeof(ascii), NULL,
                          NULL) <= 0) {
    reply->error = ERROR_INVALID_PARAMETER;
    return;
  }
  char *colon = strrchr(ascii, ':');
  if (!colon) {
    reply->error = ERROR_INVALID_PARAMETER;
    return;
  }
  *colon++ = 0;
  char *end = NULL;
  unsigned long port = strtoul(colon, &end, 10);
  struct sockaddr_in address = {0};
  address.sin_family = AF_INET;
  address.sin_port = htons((u_short)port);
  if (!port || port > 65535 || !end || *end ||
      InetPtonA(AF_INET, ascii, &address.sin_addr) != 1) {
    reply->error = ERROR_INVALID_PARAMETER;
    return;
  }
  WSADATA data;
  int started = WSAStartup(MAKEWORD(2, 2), &data);
  if (started) {
    reply->error = (DWORD)started;
    return;
  }
  SOCKET socket_handle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (socket_handle == INVALID_SOCKET) {
    reply->error = (DWORD)WSAGetLastError();
    WSACleanup();
    return;
  }
  u_long nonblocking = 1;
  BOOL good = ioctlsocket(socket_handle, FIONBIO, &nonblocking) == 0;
  int connected = good ? connect(socket_handle, (struct sockaddr *)&address,
                                 sizeof(address))
                       : SOCKET_ERROR;
  int error = connected == 0 ? 0 : WSAGetLastError();
  if (good && connected && error == WSAEWOULDBLOCK) {
    fd_set write_set, error_set;
    FD_ZERO(&write_set);
    FD_ZERO(&error_set);
    FD_SET(socket_handle, &write_set);
    FD_SET(socket_handle, &error_set);
    struct timeval timeout = {3, 0};
    int ready = select(0, NULL, &write_set, &error_set, &timeout);
    int size = sizeof(error);
    if (ready <= 0 ||
        getsockopt(socket_handle, SOL_SOCKET, SO_ERROR, (char *)&error, &size))
      error = ready == 0 ? WSAETIMEDOUT : WSAGetLastError();
  }
  reply->error = (DWORD)error;
  reply->opened = good && !error;
  if (reply->opened && mode != 2) {
    nonblocking = 0;
    DWORD timeout = 3000;
    good = ioctlsocket(socket_handle, FIONBIO, &nonblocking) == 0 &&
           setsockopt(socket_handle, SOL_SOCKET, SO_RCVTIMEO, (char *)&timeout,
                      sizeof(timeout)) == 0 &&
           setsockopt(socket_handle, SOL_SOCKET, SO_SNDTIMEO, (char *)&timeout,
                      sizeof(timeout)) == 0;
    BYTE message[17], received[16];
    message[0] = query ? 'Q' : 'C';
    memcpy(message + 1, reply->nonce, sizeof(reply->nonce));
    int size = query ? 1 : 17, sent = 0, got = 0, wanted = query ? 4 : 16;
    while (good && sent < size) {
      int n = send(socket_handle, (char *)message + sent, size - sent, 0);
      if (n <= 0)
        good = FALSE;
      else
        sent += n;
    }
    while (good && got < wanted) {
      int n = recv(socket_handle, (char *)received + got, wanted - got, 0);
      if (n <= 0)
        good = FALSE;
      else
        got += n;
    }
    if (good && query) {
      DWORD count;
      memcpy(&count, received, 4);
      reply->address = count;
    } else if (good) {
      memcpy(reply->read_bytes, received, 16);
      good = !memcmp(received, reply->nonce, 16);
    }
    if (!good)
      reply->secondary_error =
          (DWORD)(WSAGetLastError() ? WSAGetLastError() : WSAEINVAL);
  }
  closesocket(socket_handle);
  WSACleanup();
}

static BOOL runtime_network_probe(suite *s, const WCHAR *endpoint,
                                  BOOL ordinary, BOOL query, DWORD *count) {
  run r = {0};
  BOOL tried = probe(s, &r, ordinary, OP_NETWORK, endpoint, 0, query);
  BOOL effect =
      ordinary
          ? (r.reply.opened && !r.reply.error && !r.reply.secondary_error &&
             (query || !memcmp(r.nonce, r.reply.read_bytes, 16)))
          : (!r.reply.opened && !r.reply.secondary_error &&
             (r.reply.error == WSAEACCES || r.reply.error == WSAETIMEDOUT));
  if (count && tried && effect)
    *count = (DWORD)r.reply.address;
  BOOL ended = r.complete && release_run(&r);
  BOOL clean = dispose_run(&r);
  printf("NETWORK endpoint=%ls ordinary=%d query=%d attempted=%d opened=%lu "
         "WSA=%lu secondary=%lu effect=%d count=%llu\n",
         endpoint, ordinary, query, tried, (unsigned long)r.reply.opened,
         (unsigned long)r.reply.error, (unsigned long)r.reply.secondary_error,
         effect, (unsigned long long)r.reply.address);
  return tried && effect && ended && clean;
}

/* The broker resolves once and connects under its own ordinary token. All
   three connects use this exact IPv4; mode 2 never sends application bytes. */
static BOOL runtime_external_connect(suite *s, const WCHAR *configured) {
  WCHAR endpoint[128] = {0};
  BOOL configured_ok = !wcscmp(configured, L"git.4stra.dev:443");
  WSADATA data;
  int dns_error = configured_ok ? WSAStartup(MAKEWORD(2, 2), &data) : WSAEINVAL;
  ADDRINFOW hints = {0}, *addresses = NULL;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  BOOL started = configured_ok && !dns_error;
  if (started)
    dns_error = GetAddrInfoW(L"git.4stra.dev", L"443", &hints, &addresses);
  BOOL resolved = FALSE, all_logged = TRUE;
  unsigned resolved_count = 0, global_count = 0;
  for (ADDRINFOW *row = addresses; !dns_error && row; row = row->ai_next) {
    WCHAR ip[64] = {0};
    BOOL global = FALSE, valid = FALSE;
    if (row->ai_addr && row->ai_family == AF_INET &&
        row->ai_addrlen >= sizeof(struct sockaddr_in)) {
      const struct sockaddr_in *address = (const void *)row->ai_addr;
      valid = InetNtopW(AF_INET, &address->sin_addr, ip, 64) != NULL;
      global = valid && sec5_global_ipv4(ntohl(address->sin_addr.s_addr));
      if (global) {
        ++global_count;
        if (!resolved)
          resolved = fmt(endpoint, 128, L"%ls:443", ip);
      }
    } else if (row->ai_addr && row->ai_family == AF_INET6 &&
               row->ai_addrlen >= sizeof(struct sockaddr_in6)) {
      const struct sockaddr_in6 *address = (const void *)row->ai_addr;
      valid = InetNtopW(AF_INET6, &address->sin6_addr, ip, 64) != NULL;
    }
    ++resolved_count;
    all_logged = all_logged && valid;
    printf("NETWORK_DNS_ADDRESS index=%u family=%d address=%ls valid=%d "
           "global_ipv4=%d eligible=%d\n",
           resolved_count, row->ai_family, valid ? ip : L"INVALID", valid,
           global, row->ai_family == AF_INET && global);
  }
  resolved = resolved && all_logged;
  if (!dns_error && !resolved)
    dns_error = WSAEINVAL;
  if (addresses)
    FreeAddrInfoW(addresses);
  if (started)
    WSACleanup();
  printf("NETWORK_DNS configured=%ls ipv4_endpoint=%ls resolved=%d WSA=%d\n",
         configured, endpoint, resolved, dns_error);
  printf("NETWORK_SCOPE resolved_addresses=%u global_ipv4_addresses=%u "
         "measured=selected_global_ipv4_tcp_only domain_ownership=NOT_VERIFIED "
         "tls_http=NOT_MEASURED registry=IANA-20261014\n",
         resolved_count, global_count);
  packet before = {0}, after = {0};
  run r = {0};
  if (resolved)
    child_network(&before, endpoint, 2);
  BOOL first =
      resolved && before.opened && !before.error && !before.secondary_error;
  BOOL tried = first && probe(s, &r, FALSE, OP_NETWORK, endpoint, 0, 2);
  /* No other network operation intervenes between these controls and probe. */
  if (first)
    child_network(&after, endpoint, 2);
  BOOL last = first && after.opened && !after.error && !after.secondary_error;
  BOOL rejected = tried && !r.reply.opened && !r.reply.secondary_error &&
                  (r.reply.error == WSAEACCES || r.reply.error == WSAETIMEDOUT);
  BOOL ended = r.complete && release_run(&r);
  BOOL clean = dispose_run(&r);
  BOOL good = first && last && rejected && ended && clean;
  printf("NETWORK_CONNECT endpoint=%ls broker_pid=%lu control_before=%d "
         "before_WSA=%lu attempted=%d opened=%lu child_WSA=%lu secondary=%lu "
         "control_after=%d after_WSA=%lu denied=%d ended=%d cleanup=%d\n",
         endpoint, (unsigned long)GetCurrentProcessId(), first,
         (unsigned long)before.error, tried, (unsigned long)r.reply.opened,
         (unsigned long)r.reply.error, (unsigned long)r.reply.secondary_error,
         last, (unsigned long)after.error, good, ended, clean);
  printf("NETWORK_ENDPOINT kind=SEC5_NET_EXTERNAL mode=connect status=%s "
         "reason=%s\n",
         good ? "PASS" : "FAIL",
         !configured_ok    ? "expected_git.4stra.dev:443"
         : !resolved       ? "dns_or_public_ipv4_failed"
         : !first || !last ? "broker_tcp_control_failed"
         : !good           ? "child_denial_or_lifecycle_failed"
                           : "broker_tcp_before_after_child_10013_or_10060");
  return good;
}

static void runtime_network_case(suite *s) {
  const WCHAR *variables[] = {L"SEC5_NET_EXTERNAL", L"SEC5_NET_LAN",
                              L"SEC5_NET_LOOPBACK"};
  BOOL good = TRUE;
  PSID saved_capability = s->active_capability;
  s->active_capability = NULL; /* Network baseline has zero capabilities. */
  BYTE internet_sid[SECURITY_MAX_SID_SIZE];
  DWORD internet_size = sizeof(internet_sid);
  if (s->mutation == SEC5_INTERNET_CLIENT) {
    if (!CreateWellKnownSid(WinCapabilityInternetClientSid, NULL, internet_sid,
                            &internet_size)) {
      api_error("CreateWellKnownSid(internetClient)", GetLastError());
      s->active_capability = saved_capability;
      result(s, 37, FALSE, "internet-client SID creation failed; no fallback");
      return;
    }
    s->active_capability = internet_sid;
  }
  for (unsigned i = 0; i < 3; ++i) {
    WCHAR endpoint[128];
    DWORD n = GetEnvironmentVariableW(variables[i], endpoint, 128), before = 0,
          after = 0;
    BOOL present = n && n < 128;
    if (i == 0) {
      WCHAR mode[32] = {0};
      DWORD mode_size =
          GetEnvironmentVariableW(L"SEC5_NET_EXTERNAL_MODE", mode, 32);
      if (mode_size && mode_size < 32 && !wcscmp(mode, L"connect")) {
        BOOL external = present && runtime_external_connect(s, endpoint);
        if (!present)
          printf("NETWORK_ENDPOINT kind=SEC5_NET_EXTERNAL mode=connect "
                 "status=FAIL "
                 "reason=endpoint_missing_not_measured\n");
        good = external && good;
        continue;
      }
      if (mode_size && (mode_size >= 32 || wcscmp(mode, L"echo"))) {
        printf("NETWORK_ENDPOINT kind=SEC5_NET_EXTERNAL status=FAIL "
               "reason=invalid_mode\n");
        good = FALSE;
        continue;
      }
    }
    unsigned octets[4] = {0}, port = 0;
    int consumed = 0;
    BOOL parsed = present &&
                  swscanf(endpoint, L"%u.%u.%u.%u:%u%n", &octets[0], &octets[1],
                          &octets[2], &octets[3], &port, &consumed) == 5 &&
                  endpoint[consumed] == 0 && octets[0] <= 255 &&
                  octets[1] <= 255 && octets[2] <= 255 && octets[3] <= 255 &&
                  port && port <= 65535;
    BOOL private_address =
        octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
    BOOL public_address =
        octets[0] && octets[0] < 224 && octets[0] != 127 && !private_address &&
        !(octets[0] == 169 && octets[1] == 254) &&
        !(octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127) &&
        !(octets[0] == 192 && octets[1] == 0) &&
        !(octets[0] == 198 && (octets[1] == 18 || octets[1] == 19 ||
                               (octets[1] == 51 && octets[2] == 100))) &&
        !(octets[0] == 203 && octets[1] == 0 && octets[2] == 113);
    BOOL kind_matches = parsed && (i == 0   ? public_address
                                   : i == 1 ? private_address
                                            : octets[0] == 127);
    BOOL control = present && kind_matches &&
                   runtime_network_probe(s, endpoint, TRUE, FALSE, NULL);
    BOOL first =
        control && runtime_network_probe(s, endpoint, TRUE, TRUE, &before);
    BOOL rejected =
        first && runtime_network_probe(s, endpoint, FALSE, FALSE, NULL);
    BOOL last = first && runtime_network_probe(s, endpoint, TRUE, TRUE, &after);
    BOOL no_request = first && last && before == after;
    BOOL denied = control && rejected && no_request;
    printf("NETWORK_SERVER kind=%ls endpoint_present=%d "
           "address_kind_matches=%d control=%d denied=%d requests_before=%lu "
           "requests_after=%lu no_request=%d\n",
           variables[i], present, kind_matches, control, denied,
           (unsigned long)before, (unsigned long)after, no_request);
    printf("NETWORK_ENDPOINT kind=%ls status=%s reason=%s\n", variables[i],
           denied ? "PASS" : "FAIL",
           !present ? "endpoint_missing_not_measured"
           : denied
               ? "ordinary_echo_positive_rejected_10013_or_10060_no_request"
               : "control_error_rejection_error_or_server_counter_changed");
    good = present && control && denied && first && last && before == after &&
           good;
  }
  s->active_capability = saved_capability;
  result(s, 37, good,
         "external explicit connect mode with broker TCP controls or "
         "controlled echo; "
         "LAN/loopback nonce echo and unchanged server counter; zero child "
         "capabilities; "
         "only WSAEACCES/WSAETIMEDOUT with positive controls; "
         "SEC5_NET_EXTERNAL missing blocks independently of LAN/loopback");
}

static BOOL runtime_registry_parent(run *r, const WCHAR *leaf, HKEY *key) {
  HANDLE token = NULL;
  HKEY root = NULL;
  BOOL impersonated = OpenProcessToken(r->process.pi.hProcess,
                                       TOKEN_QUERY | TOKEN_DUPLICATE, &token) &&
                      ImpersonateLoggedOnUser(token);
  HRESULT hr = impersonated ? GetAppContainerRegistryLocation(KEY_READ, &root)
                            : E_ACCESSDENIED;
  LSTATUS status = SUCCEEDED(hr)
                       ? RegOpenKeyExW(root, leaf, 0, KEY_READ | DELETE, key)
                       : ERROR_ACCESS_DENIED;
  BOOL reverted = !impersonated || RevertToSelf();
  if (!reverted) {
    api_error("RevertToSelf", GetLastError());
    ExitProcess(79);
  }
  if (root)
    RegCloseKey(root);
  if (token)
    CloseHandle(token);
  printf("PRIVATE_REGISTRY_PARENT HRESULT=0x%08lx open=%ld reverted=%d\n",
         (unsigned long)hr, (long)status, reverted);
  return impersonated && SUCCEEDED(hr) && !status && reverted;
}

static BOOL runtime_registry_name(HKEY key, WCHAR *name) {
  typedef NTSTATUS(NTAPI * query_key_fn)(HANDLE, int, void *, ULONG, ULONG *);
  query_key_fn query = (query_key_fn)GetProcAddress(
      GetModuleHandleW(L"ntdll.dll"), "NtQueryKey");
  BYTE data[sizeof(ULONG) + CAP * sizeof(WCHAR)];
  ULONG length = 0;
  NTSTATUS status = query ? query(key, 3 /* KeyNameInformation */, data,
                                  sizeof(data), &length)
                          : (NTSTATUS)0xc000007au;
  if (status < 0 || length < sizeof(ULONG))
    return FALSE;
  ULONG bytes;
  memcpy(&bytes, data, sizeof(bytes));
  if (bytes % sizeof(WCHAR) || bytes >= CAP * sizeof(WCHAR) ||
      bytes > length - sizeof(ULONG))
    return FALSE;
  memcpy(name, data + sizeof(ULONG), bytes);
  name[bytes / sizeof(WCHAR)] = 0;
  printf("PRIVATE_REGISTRY_NT_NAME=%ls\n", name);
  return TRUE;
}

static void runtime_registry_case(suite *s) {
  suite b = {0};
  b.backend = SEC5_APPCONTAINER;
  b.runtime_matrix = TRUE;
  b.private_environment = TRUE;
  b.active_capability = s->active_capability;
  b.mutation = s->mutation;
  run a = {0}, other = {0};
  HKEY key = NULL;
  WCHAR leaf[256], name[CAP];
  BOOL ready = fmt(b.user_text, 256, L"%ls", s->user_text) &&
               setup(&b, s->original_child);
  BOOL good = ready && fmt(leaf, 256, L"SEC5-%ls", s->guid) &&
              probe(s, &a, FALSE, OP_PRIVATE_REG, leaf, 0, 0) &&
              a.reply.opened && !a.reply.error && !a.reply.secondary_error &&
              runtime_registry_parent(&a, leaf, &key) &&
              runtime_registry_name(key, name);
  BYTE nonce[16];
  DWORD size = sizeof(nonce), type = 0;
  good = good && !RegQueryValueExW(key, L"nonce", NULL, &type, nonce, &size) &&
         type == REG_BINARY && size == sizeof(nonce) &&
         !memcmp(nonce, a.nonce, size);
  BOOL denied = good && probe(&b, &other, FALSE, OP_REG_READ, name, 0, 0) &&
                !other.reply.opened &&
                (other.reply.error == ERROR_ACCESS_DENIED ||
                 other.reply.error == ERROR_FILE_NOT_FOUND);
  BOOL b_end = other.complete && release_run(&other),
       b_clean = dispose_run(&other);
  BOOL a_end = a.complete && release_run(&a), a_clean = dispose_run(&a);
  if (key) {
    LSTATUS deletion = delete_key_by_handle(key);
    printf("PRIVATE_REGISTRY_DELETE status=%ld\n", (long)deletion);
    good = deletion == ERROR_SUCCESS && good;
    RegCloseKey(key);
  }
  BOOL exterior = RegQueryValueExW(s->key, L"nonce", NULL, NULL, NULL, &size) ==
                  ERROR_FILE_NOT_FOUND;
  BOOL cleaned = finish(&b);
  if (!cleaned)
    s->isolated_cleanup_failed = TRUE;
  result(
      s, 36,
      good && denied && a_end && a_clean && b_end && b_clean && exterior &&
          cleaned,
      "child GetAppContainerRegistryLocation nonce; parent reads exact store "
      "via own child token; B full NT key denied; exterior HKCU unchanged");
}

static void runtime_system_case(suite *s, runtime_tree *tree) {
  WCHAR system[CAP], path[CAP];
  BOOL good = GetSystemDirectoryW(system, CAP) &&
              fmt(path, CAP, L"%ls\\kernel32.dll", system);
  HANDLE file =
      good ? CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                         OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL)
           : INVALID_HANDLE_VALUE;
  good = file != INVALID_HANDLE_VALUE &&
         hash_file(file, "fixed-System32-kernel32") && good;
  if (file != INVALID_HANDLE_VALUE)
    CloseHandle(file);
  good = good && runtime_read_probe(s, path, TRUE, TRUE) &&
         runtime_read_probe(s, path, TRUE, FALSE);
  for (unsigned i = 0; i < 2; ++i)
    good = runtime_read_probe(s, tree->witnesses[i], TRUE, FALSE) && good;
  good = runtime_read_probe(s, s->read_file, FALSE, FALSE) && good;
  result(s, 38, good,
         "fixed System32 image hash/first bytes + runtime RX positive; private "
         "user-only nonce denied; no system writes");
}

static void runtime_mic_case(suite *s) {
  snapshot original = {0};
  BOOL good =
      snapshot_take(&original, s->medium_sd.handle, SE_FILE_OBJECT, TRUE);
  BOOL allowed[2] = {FALSE, FALSE};
  DWORD errors[2] = {0, 0};
  WCHAR path[CAP];
  good = good && fmt(path, CAP, L"%ls\\mic-observation.bin", s->medium);
  for (unsigned i = 0; i < 2; ++i) {
    if (i == 1)
      good = grant_package(original.handle, s->lease, 0x001201ff, TRUE) && good;
    BOOL medium_label = good && label_is(original.handle, SE_FILE_OBJECT,
                                         SECURITY_MANDATORY_MEDIUM_RID);
    run control = {0};
    BOOL control_attempted =
        good && probe(s, &control, TRUE, OP_WRITE, path, 0, 0);
    BOOL control_effect =
        control_attempted && control.reply.opened && !control.reply.error &&
        file_bytes(path, control.nonce, sizeof(control.nonce), FALSE);
    BOOL control_ended = control.complete && release_run(&control);
    BOOL control_cleaned = dispose_run(&control);
    BOOL control_removed = control_effect && DeleteFileW(path);
    BOOL positive = control_effect && control_ended && control_cleaned &&
                    control_removed && storage_absent(path);
    run r = {0};
    BOOL attempted =
        good && positive && probe(s, &r, FALSE, OP_WRITE, path, 0, 0);
    BOOL exists = GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
    BOOL effect = exists && file_bytes(path, r.nonce, sizeof(r.nonce), FALSE);
    allowed[i] = effect;
    errors[i] = r.reply.error;
    BOOL observed = medium_label && positive && attempted &&
                    !r.reply.secondary_error &&
                    (effect ? (r.reply.opened && !r.reply.error)
                            : (storage_absent(path) && !r.reply.opened &&
                               (r.reply.error == ERROR_ACCESS_DENIED ||
                                r.reply.error == ERROR_PRIVILEGE_NOT_HELD)));
    BOOL ended = r.complete && release_run(&r), cleaned = dispose_run(&r);
    if (exists && !DeleteFileW(path))
      cleaned = FALSE;
    printf("MIC_OBSERVATION explicit_package_grant=%u medium_label=%d "
           "ordinary_control=%d attempted=%d effect=%d error=%lu "
           "create_inherited_label_privilege_denied=%d observed=%d "
           "ended=%d cleaned=%d\n",
           i, medium_label, positive, attempted, effect,
           (unsigned long)r.reply.error,
           attempted && r.reply.error == ERROR_PRIVILEGE_NOT_HELD, observed,
           ended, cleaned);
    good = observed && ended && cleaned && good;
  }
  BOOL restored = original.sd && restore(&original);
  if (original.sd)
    LocalFree(original.sd);
  if (good && restored)
    observation(s, 2, allowed[1], errors[1],
                "medium CREATE_ALWAYS with/without package ACE; ordinary nonce "
                "controls + measured effect/absence; denial 5 or inherited "
                "label privilege 1314 recorded; no MIC isolation promise");
  else
    result(s, 2, FALSE,
           "medium with/without package ACE observation incomplete");
}

static void runtime_inheritance_case(suite *s) {
  WCHAR existing[CAP], file[CAP], directory[CAP];
  snapshot before = {0};
  BOOL good = fmt(existing, CAP, L"%ls\\r2-protected", s->dest) &&
              fmt(file, CAP, L"%ls\\inherited.bin", s->dest) &&
              fmt(directory, CAP, L"%ls\\inherited-dir", s->dest) &&
              create_dir(s, existing, FALSE, 1, &before);
  run r = {0};
  BOOL tried = good && probe(s, &r, FALSE, OP_INHERIT, s->dest, 0, 0);
  HANDLE f = CreateFileW(file, READ_CONTROL, FILE_SHARE_READ, NULL,
                         OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  HANDLE d = open_dir(directory, READ_CONTROL);
  PSECURITY_DESCRIPTOR file_sd = NULL, dir_sd = NULL;
  BOOL observed = tried && r.reply.opened && !r.reply.error &&
                  !r.reply.secondary_error && f != INVALID_HANDLE_VALUE &&
                  d != INVALID_HANDLE_VALUE &&
                  kernel_sd(f, SD_INFO, &file_sd) &&
                  kernel_sd(d, SD_INFO, &dir_sd) && snapshot_equal(&before) &&
                  file_bytes(file, r.nonce, sizeof(r.nonce), FALSE);
  if (observed) {
    PSECURITY_DESCRIPTOR descriptors[] = {file_sd, dir_sd};
    for (unsigned i = 0; i < 2; ++i) {
      LPWSTR text = NULL;
      PACL acl = NULL;
      BOOL present = FALSE, def = FALSE;
      BOOL got =
          ConvertSecurityDescriptorToStringSecurityDescriptorW(
              descriptors[i], SDDL_REVISION_1, SD_INFO, &text, NULL) &&
          GetSecurityDescriptorDacl(descriptors[i], &present, &acl, &def) &&
          present && acl_has(acl, s->lease, FILE_GENERIC_WRITE);
      printf("INHERITANCE_R2 object=%s SDDL=%ls package_write=%d\n",
             i ? "directory" : "file", text ? text : L"UNAVAILABLE", got);
      observed = got && observed;
      if (text)
        LocalFree(text);
    }
  }
  if (file_sd)
    LocalFree(file_sd);
  if (dir_sd)
    LocalFree(dir_sd);
  if (f != INVALID_HANDLE_VALUE)
    CloseHandle(f);
  if (d != INVALID_HANDLE_VALUE)
    CloseHandle(d);
  BOOL ended = r.complete && release_run(&r), clean = dispose_run(&r);
  snapshot_dispose(&before);
  BOOL removed = DeleteFileW(file) && RemoveDirectoryW(directory) &&
                 RemoveDirectoryW(existing);
  if (good && observed && ended && clean && removed)
    observation(s, 24, TRUE, 0,
                "actual file/subdirectory SD + package inherited ACE; "
                "protected medium object intact; no recursive relabel");
  else
    result(s, 24, FALSE, "inheritance observation incomplete");
}

static BOOL runtime_prepare_temp(suite *s) {
  WCHAR path[CAP];
  if (!fmt(s->private_local, CAP, L"%ls\\runtime-temp", s->dest) ||
      !fmt(s->private_temp, CAP, L"%ls\\Packages\\%ls\\AC\\Temp",
           s->private_local, s->profile))
    return FALSE;
  /* CreateProcessW reroutes LOCALAPPDATA/TEMP/TMP for an AppContainer. Prepare
     that exact path under the private base; ordinary controls and caches use
     the same final Temp directory. Never grant the shared runtime capability.
   */
  const WCHAR *formats[] = {L"%ls", L"%ls\\Packages", L"%ls\\Packages\\%ls",
                            L"%ls\\Packages\\%ls\\AC",
                            L"%ls\\Packages\\%ls\\AC\\Temp"};
  for (unsigned i = 0; i < 5; ++i) {
    if (!fmt(path, CAP, formats[i], s->private_local, s->profile) ||
        !CreateDirectoryW(path, NULL))
      return FALSE;
  }
  HANDLE directory = open_dir(s->private_temp, READ_CONTROL);
  PSECURITY_DESCRIPTOR sd = NULL;
  PACL acl = NULL;
  BOOL present = FALSE, def = FALSE;
  BOOL good = directory != INVALID_HANDLE_VALUE &&
              kernel_sd(directory, DACL_SECURITY_INFORMATION, &sd) &&
              GetSecurityDescriptorDacl(sd, &present, &acl, &def) && present &&
              acl && acl_has(acl, s->lease, FILE_GENERIC_WRITE);
  unsigned package_aces = 0;
  for (DWORD i = 0; good && i < acl->AceCount; ++i) {
    ACCESS_ALLOWED_ACE *ace = NULL;
    good = GetAce(acl, i, (void **)&ace) &&
           ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE;
    if (good) {
      PSID sid = &ace->SidStart;
      if (*GetSidSubAuthorityCount(sid) &&
          GetSidIdentifierAuthority(sid)->Value[5] == 15) {
        ++package_aces;
        good = EqualSid(sid, s->lease);
      }
    }
  }
  good = good && package_aces == 1;
  printf("RUNTIME_TEMP base=%ls effective_temp=%ls directory_exists=%d "
         "package_only=%d package_aces=%u\n",
         s->private_local, s->private_temp, directory != INVALID_HANDLE_VALUE,
         good, package_aces);
  if (sd)
    LocalFree(sd);
  if (directory != INVALID_HANDLE_VALUE)
    CloseHandle(directory);
  return good;
}

static BOOL runtime_other_order(suite *s, suite *b, run *a, run *own) {
  BOOL good = *b->private_temp &&
              GetFileAttributesW(b->private_temp) != INVALID_FILE_ATTRIBUTES &&
              appcontainer_token_cap(a->process.pi.hProcess, s->lease,
                                     s->active_capability, TRUE) &&
              appcontainer_token_cap(own->process.pi.hProcess, b->lease,
                                     s->active_capability, TRUE);
  run own_query = {0};
  BOOL queried = probe(b, &own_query, FALSE, OP_QUERY, L"-",
                       own->process.pi.dwProcessId, 0) &&
                 own_query.reply.opened && !own_query.reply.error;
  BOOL query_end = own_query.complete && release_run(&own_query),
       query_clean = dispose_run(&own_query);
  printf("OTHER_ORDER_OWN_PROCESS query_positive=%d\n", queried);
  good = queried && query_end && query_clean && good;
  for (unsigned i = 0; i < 2; ++i) {
    HANDLE process = i ? own->process.pi.hProcess : a->process.pi.hProcess;
    PSECURITY_DESCRIPTOR sd = NULL;
    LPWSTR text = NULL;
    BOOL present = FALSE, def = FALSE, capability_ace = FALSE;
    PACL acl = NULL;
    BOOL inspected = kernel_sd(process, SD_INFO, &sd) &&
                     GetSecurityDescriptorDacl(sd, &present, &acl, &def) &&
                     present && acl;
    for (DWORD j = 0; inspected && j < acl->AceCount; ++j) {
      ACCESS_ALLOWED_ACE *ace = NULL;
      if (!GetAce(acl, j, (void **)&ace)) {
        inspected = FALSE;
        break;
      }
      if (ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
          EqualSid(&ace->SidStart, s->active_capability))
        capability_ace = TRUE;
    }
    if (inspected)
      inspected = ConvertSecurityDescriptorToStringSecurityDescriptorW(
          sd, SDDL_REVISION_1, SD_INFO, &text, NULL);
    printf("OTHER_ORDER_PROCESS_SD order=%s inspected=%d "
           "runtime_capability_ACE=%d SDDL=%ls\n",
           i ? "B" : "A", inspected, capability_ace,
           text ? text : L"UNAVAILABLE");
    good = inspected && !capability_ace && good;
    if (text)
      LocalFree(text);
    if (sd)
      LocalFree(sd);
  }
  for (unsigned i = 0; i < 2; ++i) {
    good = runtime_read_probe(s, s->shared_runtime[i], TRUE, FALSE) && good;
    good = runtime_read_probe(b, s->shared_runtime[i], TRUE, FALSE) && good;
    WCHAR exe[CAP];
    if (!fmt(exe, CAP, L"%ls", s->shared_runtime[i])) {
      good = FALSE;
      continue;
    }
    WCHAR *leaf = wcsrchr(exe, L'\\');
    BOOL path = leaf && fmt(leaf + 1, CAP - (size_t)(leaf + 1 - exe), L"%ls",
                            i ? L"python.exe" : L"node.exe");
    good = path && runtime_execute(b, exe, i != 0, FALSE) && good;
  }
  const WCHAR *directories[] = {s->dest, s->private_temp, s->profile_path};
  for (unsigned i = 0; i < 3; ++i) {
    WCHAR file[CAP], create[CAP];
    BYTE nonce[16];
    snapshot original = {0};
    BOOL paths = directories[i] &&
                 fmt(file, CAP, L"%ls\\r2-other-order.bin", directories[i]) &&
                 fmt(create, CAP, L"%ls\\r2-other-create.bin", directories[i]);
    BOOL positive =
        paths && random_bytes(nonce, 16) && file_bytes(file, nonce, 16, TRUE);
    HANDLE h =
        positive
            ? CreateFileW(file, GENERIC_READ | WRITE_DAC | WRITE_OWNER,
                          FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                          OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL)
            : INVALID_HANDLE_VALUE;
    BOOL captured = h != INVALID_HANDLE_VALUE &&
                    snapshot_take(&original, h, SE_FILE_OBJECT, TRUE);
    if (!original.handle && h != INVALID_HANDLE_VALUE)
      CloseHandle(h);
    BOOL own_read = captured && runtime_read_probe(s, file, TRUE, FALSE);
    BOOL other_read = captured && runtime_read_probe(b, file, FALSE, FALSE);
    BOOL other_write = captured && runtime_write_probe(b, file, FALSE);
    BOOL other_create = captured && runtime_write_probe(b, create, TRUE);
    BOOL intact = captured && snapshot_equal(&original) &&
                  file_bytes(file, nonce, 16, FALSE);
    printf("OTHER_ORDER_STORAGE kind=%s A_positive=%d B_read_denied=%d "
           "B_write_denied=%d B_create_denied=%d nonce_SD_identity_intact=%d\n",
           i == 0   ? "destination"
           : i == 1 ? "temp"
                    : "profile",
           own_read, other_read, other_write, other_create, intact);
    snapshot_dispose(&original);
    BOOL removed = paths && DeleteFileW(file);
    good = positive && own_read && other_read && other_write && other_create &&
           intact && removed && good;
  }
  const unsigned operations[] = {OP_QUERY, OP_VM, OP_TERMINATE};
  for (unsigned i = 0; i < 3; ++i) {
    run attack = {0};
    BOOL alive =
        WaitForSingleObject(a->process.pi.hProcess, 0) == WAIT_TIMEOUT &&
        WaitForSingleObject(own->process.pi.hProcess, 0) == WAIT_TIMEOUT;
    BOOL attempted = alive && probe(b, &attack, FALSE, operations[i], L"-",
                                    a->process.pi.dwProcessId, 0);
    BOOL denied =
        attempted && !attack.reply.opened &&
        attack.reply.error == ERROR_ACCESS_DENIED &&
        (operations[i] != OP_VM ||
         attack.reply.secondary_error == ERROR_ACCESS_DENIED) &&
        WaitForSingleObject(a->process.pi.hProcess, 0) == WAIT_TIMEOUT;
    BOOL ended = attack.complete && release_run(&attack),
         cleaned = dispose_run(&attack);
    printf("OTHER_ORDER_PROCESS op=%u attempted=%d error=%lu denied=%d "
           "both_alive_before=%d A_alive_after=%d\n",
           operations[i], attempted, (unsigned long)attack.reply.error, denied,
           alive,
           WaitForSingleObject(a->process.pi.hProcess, 0) == WAIT_TIMEOUT);
    good = denied && ended && cleaned && good;
  }
  return good;
}

static void runtime_no_write_owner_case(suite *s) {
  PSECURITY_DESCRIPTOR low = NULL;
  HANDLE reduced = open_dir(s->dest, READ_CONTROL | FILE_READ_ATTRIBUTES);
  snapshot before = {0};
  BOOL prepared =
      snapshot_take(&before, s->dest_sd.handle, SE_FILE_OBJECT, TRUE) &&
      reduced != INVALID_HANDLE_VALUE && make_sd(s, FALSE, 0, TRUE, &low);
  BOOL set = prepared &&
             SetKernelObjectSecurity(reduced, LABEL_SECURITY_INFORMATION, low);
  DWORD error = !prepared || !set ? GetLastError() : ERROR_SUCCESS;
  BOOL unchanged = prepared && snapshot_equal(&before);
  BOOL good = prepared && !set && error == ERROR_ACCESS_DENIED && unchanged;
  printf("LABEL_NEGATIVE_CONTROL api=SetKernelObjectSecurity "
         "info=0x%08lx missing_WRITE_OWNER=1 attempted=%d setter_succeeded=%d "
         "WIN32=%lu expected_access_denied=%d SD_unchanged=%d\n",
         (unsigned long)LABEL_SECURITY_INFORMATION, prepared, set,
         (unsigned long)error, good, unchanged);
  if (reduced != INVALID_HANDLE_VALUE)
    CloseHandle(reduced);
  if (low)
    LocalFree(low);
  if (before.sd)
    LocalFree(before.sd);
  result(s, 23, good,
         "expected negative control: LABEL without WRITE_OWNER denied Win32 5; "
         "original SD unchanged");
}

static void runtime_matrix_cases(suite *s) {
  runtime_tree tree = {0};
  BOOL captured = runtime_capability(s) && runtime_guard(&tree);
  for (unsigned i = 0; captured && i < 2; ++i) {
    captured = fmt(tree.roots[i], CAP, L"%ls\\%ls", tree.base,
                   i ? L"python" : L"node") &&
               fmt(tree.executables[i], CAP, L"%ls\\%ls", tree.roots[i],
                   i ? L"python.exe" : L"node.exe") &&
               fmt(tree.witnesses[i], CAP, L"%ls\\%ls", tree.roots[i],
                   i ? L"python314.dll" : L"sec5_runtime.js") &&
               fmt(s->shared_runtime[i], CAP, L"%ls", tree.witnesses[i]) &&
               runtime_capture(s, &tree, tree.roots[i]);
  }
  printf("RUNTIME_CAPTURE complete=%d objects=%u copies_only=1\n", captured,
         tree.object_count);
  BOOL grant = captured && runtime_grant(&tree, s->runtime_capability,
                                         s->mutation == SEC5_RUNTIME_WRITE);
  BOOL temp_ready = grant && runtime_prepare_temp(s);
  if (!captured || !grant || !temp_ready) {
    api_error("runtime preparation blocked", GetLastError());
    result(s, 26, FALSE, "private Node runtime preparation incomplete");
    result(s, 27, FALSE, "private Python runtime preparation incomplete");
    for (unsigned id = 31; id < 39; ++id)
      result(s, id, FALSE,
             "private runtime/capability preparation incomplete; no runtime "
             "dispatched");
    BOOL restored = !captured || runtime_restore(&tree);
    if (!restored)
      s->isolated_cleanup_failed = TRUE;
    runtime_dispose(&tree);
    if (s->runtime_capability)
      LocalFree(s->runtime_capability);
    s->runtime_capability = NULL;
    return;
  }
  BOOL ordinary = grant;
  s->private_environment = TRUE;
  for (unsigned i = 0; i < 2; ++i)
    ordinary = ordinary &&
               runtime_execute(s, tree.executables[i], i != 0, TRUE) &&
               runtime_read_probe(s, tree.witnesses[i], TRUE, TRUE);
  s->active_capability = s->runtime_capability;
  BOOL allowed = ordinary;
  for (unsigned i = 0; i < 2; ++i) {
    BOOL executed =
        ordinary && runtime_execute(s, tree.executables[i], i != 0, FALSE);
    BOOL read =
        ordinary && runtime_read_probe(s, tree.witnesses[i], TRUE, FALSE);
    printf("RUNTIME_POSITIVE runtime=%s ordinary_control=%d executed=%d "
           "RX_read=%d\n",
           i ? "PYTHON" : "NODE", ordinary, executed, read);
    result(s, i ? 27 : 26, executed && read,
           "private hash-pinned runtime; devAgentsRuntime; inline nonce "
           "stdout; real imports; private temp/cache");
    allowed = executed && read && allowed;
  }
  result(s, 31, allowed,
         "both private runtimes; one common RX SID; effective capability token "
         "and Job before Resume; exact nonce bytes + exit 0 + EOF");
  BOOL immutable = grant;
  for (unsigned i = 0; i < 2; ++i) {
    WCHAR create[CAP];
    BOOL paths =
        fmt(create, CAP, L"%ls\\sec5-write-attempt.bin", tree.roots[i]);
    immutable = paths && runtime_write_probe(s, tree.executables[i], FALSE) &&
                immutable;
    immutable = runtime_write_probe(s, tree.witnesses[i], FALSE) && immutable;
    immutable = paths && runtime_write_probe(s, create, TRUE) && immutable;
  }
  immutable = grant && runtime_unchanged(&tree, FALSE) && immutable;
  result(s, 33, immutable,
         "EXE/DLL/script overwrite + create denied 5; hashes/identity/granted "
         "SD/control unchanged; write mutation must fail");

  suite b = {0};
  b.backend = SEC5_APPCONTAINER;
  b.runtime_matrix = TRUE;
  b.private_environment = TRUE;
  b.mutation = s->mutation;
  BOOL other = grant && fmt(b.user_text, 256, L"%ls", s->user_text) &&
               setup(&b, s->original_child) && runtime_prepare_temp(&b);
  BOOL without = other && !EqualSid(s->lease, b.lease);
  /* Native testigo can start from its own package grant and diagnose Python's
     loader dependency even if python.exe never initializes stderr. */
  for (unsigned i = 0; i < 2; ++i) {
    BOOL deny =
        other && runtime_read_probe(&b, tree.witnesses[i], FALSE, FALSE);
    BOOL executable_deny =
        other && runtime_read_probe(&b, tree.executables[i], FALSE, FALSE);
    run attempt = {0};
    BOOL executed = other && probe(&b, &attempt, FALSE, OP_RUNTIME_EXEC,
                                   tree.executables[i], i, 0);
    BOOL diagnosed =
        executed && ((!attempt.reply.opened &&
                      attempt.reply.error == ERROR_ACCESS_DENIED) ||
                     (attempt.reply.opened && !attempt.reply.error &&
                      attempt.reply.secondary_error != 0 &&
                      attempt.reply.secondary_error != STILL_ACTIVE && deny));
    printf("RUNTIME_EXEC_NEGATIVE runtime=%s attempted=%d created=%lu "
           "create_error=%lu exit=0x%08lx dependency_diagnosis=%d\n",
           i ? "PYTHON" : "NODE", executed, (unsigned long)attempt.reply.opened,
           (unsigned long)attempt.reply.error,
           (unsigned long)attempt.reply.secondary_error, diagnosed);
    BOOL attempt_end = attempt.complete && release_run(&attempt),
         attempt_clean = dispose_run(&attempt);
    printf("RUNTIME_NEGATIVE runtime=%s distinct_profile=%d "
           "dependency_access_denied_5=%d executable_access_denied_5=%d "
           "loader_diagnostic=%s\n",
           i ? "PYTHON" : "NODE", other && !EqualSid(s->lease, b.lease), deny,
           executable_deny,
           i ? "python314.dll-native-access-check"
             : "runtime-script-native-access-check");
    without = deny && executable_deny && diagnosed && attempt_end &&
              attempt_clean && without;
  }
  const WCHAR *python_dependencies[] = {
      L"Lib\\json\\__init__.py", L"DLLs\\_sqlite3.pyd", L"sec5_runtime.py"};
  for (unsigned i = 0; i < 3; ++i) {
    WCHAR dependency[CAP];
    BOOL path = fmt(dependency, CAP, L"%ls\\%ls", tree.roots[1],
                    python_dependencies[i]);
    BOOL control =
        other && path && runtime_read_probe(s, dependency, TRUE, TRUE);
    BOOL positive =
        other && path && runtime_read_probe(s, dependency, TRUE, FALSE);
    BOOL negative =
        other && path && runtime_read_probe(&b, dependency, FALSE, FALSE);
    without = control && positive && negative && without;
  }
  result(s, 32, ordinary && grant && without,
         "profile B without capability; same persistently RX-granted private "
         "copies; EXE and dependency denied 5 with named native diagnosis; no "
         "opaque 0xC0000142 accepted");
  BOOL b_clean = finish(&b);
  if (!b_clean)
    s->isolated_cleanup_failed = TRUE;
  if (grant && !s->blocked) {
    runtime_registry_case(s);
    runtime_network_case(s);
    runtime_system_case(s, &tree);
    /* Existing cross-lease fixture is expanded only with an active capability.
     */
    BOOL separate = appcontainer_cross_lease_case(s);
    result(s, 35, separate,
           "A/B concurrent, same runtime RX, distinct SID, "
           "destinations/temp/profile/namespace/processes isolated; parent "
           "exact effects");
  }
  s->active_capability = NULL;
  BOOL restored = captured && runtime_restore(&tree);
  BOOL intact = restored && runtime_unchanged(&tree, TRUE);
  s->active_capability = s->runtime_capability;
  BOOL revoked = restored;
  for (unsigned i = 0; i < 2; ++i)
    revoked = restored &&
              runtime_read_probe(s, tree.witnesses[i], FALSE, FALSE) && revoked;
  s->active_capability = NULL;
  result(s, 34, grant && restored && intact && revoked && b_clean,
         "RX reverted through retained handles on identical objects; full "
         "SD/DACL/control/hash equality; with-capability read denied after "
         "revoke");
  if (!restored) {
    s->isolated_cleanup_failed = TRUE;
    printf("RUNTIME_CLEANUP BLOCKED retained private copies; do not reuse; "
           "operator removal required\n");
  }
  runtime_dispose(&tree);
  if (s->runtime_capability)
    LocalFree(s->runtime_capability);
  s->runtime_capability = NULL;
  s->private_environment = FALSE;
}
